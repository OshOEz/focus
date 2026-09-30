// Vendored from AACTools/MacGaze @3884a8c (MIT). Modified: removed dead `lastConfigurationError`; `frames` now uses `.bufferingNewest(1)`; timestamp uses the sample's presentation time directly; camera lookup falls back to `DiscoverySession`; the frame-rate lock only applies when the active format supports it; host-clock conversion; 15 fps cap (minimum frame duration only); start() never prompts (checkAuthorized/requestAccess); stop() finishes frames; session reconfigured only on device change, restartable and resilient to a partially-failed configuration; device choice by uniqueID with built-in fallback; interruption, runtime-error and connect/disconnect recovery.
import Foundation
import AVFoundation
import CoreVideo

/// Errors surfaced by `CameraCapture`.
public enum CameraCaptureError: Error, LocalizedError {
    case noCameraAvailable
    case authorizationNotDetermined
    case authorizationDenied
    case authorizationRestricted
    case sessionConfigurationFailed(String)
    case notRunning

    public var errorDescription: String? {
        switch self {
        case .noCameraAvailable:           return "No camera device is available."
        case .authorizationNotDetermined:  return "Camera access hasn't been granted yet. Allow it from Focus's onboarding (or run focus-gaze once)."
        case .authorizationDenied:         return "Camera access was denied. Grant permission in System Settings → Privacy & Security → Camera."
        case .authorizationRestricted:     return "Camera access is restricted by device policy."
        case .sessionConfigurationFailed(let msg): return "AVCapture session configuration failed: \(msg)"
        case .notRunning:                  return "Capture session isn't running; call start() first."
        }
    }
}

/// A video device the user can pick. `id` is AVCaptureDevice.uniqueID, stable across reconnects.
public struct CameraDevice: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let isBuiltIn: Bool
    public init(id: String, name: String, isBuiltIn: Bool) { self.id = id; self.name = name; self.isBuiltIn = isBuiltIn }
}

/// Camera health, reported on `CameraCapture`'s session queue — never the main thread, and not
/// necessarily any particular AVFoundation queue either. Hop to the main thread before touching UI.
public enum CameraState: Sendable, Equatable { case running, interrupted, unavailable(String) }

/// Wraps an `AVCaptureSession` streaming 1280×720 32BGRA frames from the
/// FaceTime HD camera.
///
/// Frames are delivered on a dedicated serial dispatch queue (never the
/// main thread) via an `AsyncStream`. The session itself runs on its own
/// queue too — all `AVCaptureSession` mutations are dispatched there to
/// avoid the well-known main-thread-deadlock pitfall.
///
/// Usage:
/// ```swift
/// let camera = CameraCapture()
/// try camera.start()
/// for await frame in camera.frames {
///     // consume frame.pixelBuffer synchronously before next iteration
/// }
/// ```
public final class CameraCapture: @unchecked Sendable {

    /// Configuration knobs exposed for testing + later tuning.
    public struct Configuration: Sendable {
        public var preferredWidth: Int = 1280
        public var preferredHeight: Int = 720
        public var preferredFrameRate: Double = 15
        public var pixelFormat: OSType = kCVPixelFormatType_32BGRA

        public init() {}

        /// The dedicated session queue label (visible in CrashLogs /
        /// Instruments; keep it stable).
        public static let sessionQueueLabel = "macgaze.capture.session"
        /// The dedicated video-output callback queue label.
        public static let videoQueueLabel = "macgaze.capture.video"
    }

    public let configuration: Configuration

    /// Every camera macOS offers (built-in, USB/external, Continuity). Enumeration never prompts.
    public static func devices() -> [CameraDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices.map {
            CameraDevice(id: $0.uniqueID, name: $0.localizedName, isBuiltIn: $0.deviceType == .builtInWideAngleCamera)
        }
    }

    /// The chosen camera if connected, else the built-in one, else any: an unplugged external
    /// camera falls back instead of leaving tracking off, and switches back when it returns.
    public static func pick(_ devices: [CameraDevice], preferred: String?) -> CameraDevice? {
        devices.first { $0.id == preferred } ?? devices.first(where: \.isBuiltIn) ?? devices.first
    }

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: Configuration.sessionQueueLabel)
    private let videoQueue = DispatchQueue(label: Configuration.videoQueueLabel)
    private let videoOutput = AVCaptureVideoDataOutput()

    private var wantRunning = false        // sessionQueue only
    private var wantedDeviceID: String?    // sessionQueue only
    private var observers: [NSObjectProtocol] = []
    private let stateHandler = HandlerBox()

    private final class HandlerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (@Sendable (CameraState) -> Void)?
        var handler: (@Sendable (CameraState) -> Void)? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// Camera health for the status line ("Camera off / no usable camera"); see `CameraState`'s
    /// doc for the threading rule.
    public var onStateChange: (@Sendable (CameraState) -> Void)? {
        get { stateHandler.handler } set { stateHandler.handler = newValue }
    }
    private func report(_ s: CameraState) { stateHandler.handler?(s) }

    private let errorBox = ErrorBox()

    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ s: String?) { lock.lock(); defer { lock.unlock() }; value = s }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Continuation backing `frames`. Held in a box so the delegate
    /// (which is a separate NSObject) can yield to it.
    private let continuationBox = ContinuationBox()

    private final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<CameraFrame>.Continuation?
        func set(_ c: AsyncStream<CameraFrame>.Continuation) { lock.lock(); defer { lock.unlock() }; continuation = c }
        func clear() { lock.lock(); defer { lock.unlock() }; continuation = nil }
        func yield(_ f: CameraFrame) { lock.lock(); let c = continuation; lock.unlock(); c?.yield(f) }
        func finish() { lock.lock(); let c = continuation; continuation = nil; lock.unlock(); c?.finish() }
    }

    /// Delegate object that owns the sample-buffer callback. Lives for the
    /// lifetime of the session; never accessed cross-actor outside the
    /// video queue.
    private lazy var sampleBufferDelegate = SampleBufferDelegate(
        onSample: { [weak continuationBox] frame in
            continuationBox?.yield(frame)
        },
        syncClock: { [weak self] in self?.session.synchronizationClock }
    )

    private final class SampleBufferDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        let onSample: (CameraFrame) -> Void
        let syncClock: () -> CMClock?

        init(onSample: @escaping (CameraFrame) -> Void, syncClock: @escaping () -> CMClock?) {
            self.onSample = onSample
            self.syncClock = syncClock
        }

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            // Frames are timestamped on the session's clock, which is only the
            // host clock by coincidence. Convert explicitly so `timestampSeconds`
            // is always comparable to `CACurrentMediaTime()`.
            let hostPts: CMTime
            if let sessionClock = syncClock() {
                hostPts = CMSyncConvertTime(pts, from: sessionClock, to: CMClockGetHostTimeClock())
            } else {
                hostPts = pts
            }
            onSample(CameraFrame(pixelBuffer: pixelBuffer, timestampSeconds: CMTimeGetSeconds(hostPts)))
        }
    }

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        let center = NotificationCenter.default
        // Every handler below hops onto `sessionQueue` before touching `wantRunning`/`session`/
        // reporting: notifications post on whatever thread AVFoundation feels like (often not
        // sessionQueue), so without this a late report can race a `start()`/`stop()`/`deviceChanged`
        // that's already run and land out of order (e.g. a stale ".unavailable" after ".running").
        // Each also re-checks `wantRunning` once on sessionQueue, so nothing reports after `stop()`.
        observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] n in
                guard let self else { return }
                let msg = (n.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "runtime error"
                sessionQueue.async {
                    guard self.wantRunning else { return }
                    self.report(.unavailable(msg))
                    self.recover(after: 2)
                }
            },
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
                guard let self else { return }
                // Another app took the camera, or the lid closed; the session resumes by itself.
                sessionQueue.async {
                    guard self.wantRunning else { return }
                    self.report(.interrupted)
                }
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
                guard let self else { return }
                sessionQueue.async {
                    guard self.wantRunning else { return }
                    self.report(.running)
                }
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] n in
                guard let self, let device = n.object as? AVCaptureDevice, device.hasMediaType(.video) else { return }
                let id = device.uniqueID   // pull the Sendable id out; AVCaptureDevice itself isn't Sendable
                sessionQueue.async { self.deviceChanged(disconnected: id) }
            },
            center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil) { [weak self] n in
                guard let self, let device = n.object as? AVCaptureDevice, device.hasMediaType(.video) else { return }
                sessionQueue.async { self.deviceChanged(disconnected: nil) }
            },
        ]
    }

    deinit {
        let center = NotificationCenter.default
        for o in observers { center.removeObserver(o) }
        // No `sessionQueue.sync` here: the observer closures above capture `self` strongly once
        // past their `guard let self`, so the very last strong reference can be released while
        // one of them is running *on* sessionQueue — deinit would then fire there too, and
        // syncing onto the queue you're already executing on deadlocks (crashes). Nothing else
        // can hold `self` once deinit has started, so touching `session` directly is safe.
        if session.isRunning { session.stopRunning() }
        continuationBox.clear()
    }

    // MARK: Lifecycle

    /// Throws unless camera access is already granted. Never prompts: only human-driven paths
    /// (onboarding, focus-gaze) call `requestAccess()`, so tests and benches can't raise a TCC dialog.
    public static func checkAuthorized() throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined: throw CameraCaptureError.authorizationNotDetermined
        case .denied: throw CameraCaptureError.authorizationDenied
        default: throw CameraCaptureError.authorizationRestricted
        }
    }

    /// Shows the system prompt if needed. Human-driven paths only.
    public static func requestAccess() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }

    /// Configure the session and start streaming; restartable. `deviceID` picks a camera by
    /// `AVCaptureDevice.uniqueID` (see `pick`); nil resets the preference to the built-in camera
    /// (or whatever's first) rather than keeping whatever was wanted before.
    ///
    /// Synchronous (never prompts: `checkAuthorized` is sync, and the body is a
    /// `sessionQueue.sync`), so `GazeTracker` can hold a plain lock across its whole `start()`/
    /// `stop()` without ever suspending mid-lock. Still blocks the caller for however long
    /// `AVCaptureSession` takes to configure and start (can be hundreds of ms): call it off the
    /// main actor.
    public func start(deviceID: String? = nil) throws {
        try Self.checkAuthorized()

        // Set up the session on its dedicated queue. Capture any thrown
        // error into `errorBox` so we can rethrow from this async API.
        errorBox.set(nil)
        sessionQueue.sync {
            wantedDeviceID = deviceID
            do {
                try configureSessionLocked()
                if !session.isRunning { session.startRunning() }
                wantRunning = true
                report(.running)
            } catch {
                errorBox.set(error.localizedDescription)
            }
        }
        if let msg = errorBox.get() {
            throw CameraCaptureError.sessionConfigurationFailed(msg)
        }
    }

    public func stop() {
        sessionQueue.sync {
            wantRunning = false
            if session.isRunning { session.stopRunning() }
        }
        continuationBox.finish()
    }

    // MARK: Frame stream

    /// Async stream of camera frames. Single-consumer by design; the consumer
    /// (MacGazeTracker's frame loop) is demand-driven, so it stays fast enough
    /// to keep up with capture and frames never accumulate.
    public var frames: AsyncStream<CameraFrame> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuationBox.set(continuation)
            continuation.onTermination = { [weak self] _ in
                self?.continuationBox.clear()
            }
        }
    }

    // MARK: Device / interruption recovery (sessionQueue only)

    /// Re-picks the device whenever cameras come or go (see `pick`).
    private func deviceChanged(disconnected id: String?) {
        guard wantRunning else { return }
        let current = (session.inputs.first as? AVCaptureDeviceInput)?.device.uniqueID
        if let id, id != current { return }   // some other camera left
        do {
            try configureSessionLocked()
            if !session.isRunning { session.startRunning() }
            report(.running)
        } catch {
            report(.unavailable(error.localizedDescription))   // the next connect retries
        }
    }

    /// Runtime errors (media services reset, device busy) retry every `seconds` while wanted:
    /// a failed restart posts another runtime error, which schedules the next try.
    private func recover(after seconds: Double) {
        sessionQueue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.wantRunning else { return }
            if !self.session.isRunning { self.session.startRunning() }
            // Report `.running` whenever it's actually running by now — including when the
            // session recovered on its own while this retry was waiting — so a stale
            // `.unavailable` never lingers after the camera is back.
            if self.session.isRunning { self.report(.running) }
        }
    }

    // MARK: Session configuration (sessionQueue only)

    private func configureSessionLocked() throws {
        // Defence in depth: `deviceChanged` reaches this from a connect/disconnect notification,
        // off the `start()` call path, so re-check here too rather than trust the caller never to
        // reach a place that could end up prompting.
        try Self.checkAuthorized()
        guard let wanted = Self.pick(Self.devices(), preferred: wantedDeviceID),
              let device = AVCaptureDevice(uniqueID: wanted.id)
        else { throw CameraCaptureError.noCameraAvailable }
        let current = session.inputs.first as? AVCaptureDeviceInput
        // A replugged camera gets a fresh `AVCaptureDevice` object even though its uniqueID is
        // unchanged, so the existing input's device must be compared by identity and connectedness,
        // not just by uniqueID — otherwise a replug matches the stale, now-dead input, this returns
        // early, and `recover`'s `startRunning()` retries forever against a session that's still
        // wired to a camera that's gone for good.
        let needsInput = current.map { $0.device !== device || !$0.device.isConnected } ?? true
        // Fully wired already (plain restart): nothing to do. Checking `outputs` too, not just the
        // input, matters when a previous call added the input but then threw before adding the
        // output (below) — otherwise a same-device retry would return here and wedge forever
        // without ever completing the output side.
        if !needsInput && !session.outputs.isEmpty { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if needsInput {
            if let current { session.removeInput(current) }
            let input = try AVCaptureDeviceInput(device: device)   // authorization was checked by start()
            guard session.canAddInput(input) else {
                throw CameraCaptureError.sessionConfigurationFailed("Cannot add device input")
            }
            session.addInput(input)
            session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        }

        if session.outputs.isEmpty {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(configuration.pixelFormat)
            ]
            guard session.canAddOutput(videoOutput) else {
                throw CameraCaptureError.sessionConfigurationFailed("Cannot add video output")
            }
            session.addOutput(videoOutput)
            videoOutput.setSampleBufferDelegate(sampleBufferDelegate, queue: videoQueue)
        }

        // ≤ 15 fps: enough for head-pose dwell times of 100 ms and up, at a fraction of the CPU. Only the minimum frame duration is set, so the camera may still slow
        // down in low light rather than underexpose. Locking an unsupported rate raises an
        // uncatchable ObjC exception, hence the range check.
        let fps = configuration.preferredFrameRate
        if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }),
           (try? device.lockForConfiguration()) != nil {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(fps))
            device.unlockForConfiguration()
        }
    }
}
