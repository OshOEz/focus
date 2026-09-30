import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import FocusCore

/// Camera → CoreML FaceMesh → head pose → homography eye patch → BlazeGaze, one GazeSample per frame.
/// Mirrors MacGazeControl.runPipeline (CoreML branch) without RBF or smoothing: FocusCore does those.
/// `@unchecked Sendable`: the vendored pipeline types aren't Sendable; `lock` guards the mutable
/// state and `process` only runs on the loop task.
public final class GazeTracker: GazeSource, @unchecked Sendable {
    public enum Failure: Error { case modelMissing(String) }

    private let camera = CameraCapture()
    private let mesh: CoreMLFaceMeshLandmarker
    private let blaze: BlazeGazeRunner
    /// Guards the whole lifecycle: `start()` and `stop()` each hold it start to finish (never
    /// across an `await` — `camera.start()` is synchronous), so the two can never interleave.
    /// A generation counter, bumped on every stop, still exists for `stop(ifGeneration:)`: the
    /// only path that can't just take `lock` head-on, because it runs from a stream's
    /// `onTermination` asynchronously after the stream (and maybe a newer session) already exists.
    private let lock = NSLock()
    private var loop: Task<Void, Never>?
    private var output: AsyncStream<GazeSample>.Continuation?
    private var _cameraID: String?
    private var generation = 0

    /// Camera for the next `start()` (AVCaptureDevice.uniqueID; nil = built-in). Restart to apply.
    public var cameraID: String? {
        get { lock.withLock { _cameraID } }
        set { lock.withLock { _cameraID = newValue } }
    }
    /// Camera health for the status line ("Camera off / no usable camera"); see `CameraState`'s
    /// doc for the threading rule.
    public var onCameraState: (@Sendable (CameraState) -> Void)? {
        get { camera.onStateChange }
        set { camera.onStateChange = newValue }
    }

    public init() throws {
        guard let meshURL = Bundle.module.url(forResource: "face_mesh", withExtension: "mlmodelc") else {
            throw Failure.modelMissing("face_mesh.mlmodelc")
        }
        guard let blazeURL = Bundle.module.url(forResource: "blazegaze", withExtension: "mlmodelc") else {
            throw Failure.modelMissing("blazegaze.mlmodelc")
        }
        mesh = try CoreMLFaceMeshLandmarker(modelURL: meshURL)
        blaze = try BlazeGazeRunner(modelURL: blazeURL)
    }

    /// Starts the camera and returns a fresh stream (single consumer, newest sample only).
    /// Restartable: a running session is stopped first. Throws, without prompting, when camera
    /// access isn't granted.
    ///
    /// Holds `lock` for the whole call — `camera.start()` is synchronous, so this never suspends
    /// while holding it — which serializes `start()` against `stop()` and against any other
    /// `start()`: nothing else can observe or act on `loop`/`output`/the camera mid-setup, so a
    /// concurrent `stop()` can no longer be lost, and two concurrent `start()`s can no longer both
    /// believe they own the session. Blocks the caller for however long the camera takes to start
    /// (can be hundreds of ms): call it off the MainActor.
    public func start() async throws -> AsyncStream<GazeSample> {
        // `withLock`, not `.lock()`/`.unlock()`: the latter are unavailable from an async context
        // (Swift can't otherwise tell whether the caller might `await` mid-lock). `withLock`'s
        // closure argument is synchronous, so the compiler guarantees this body never suspends —
        // matching the "never hold a lock across an await" rule, not just asserting it in a comment.
        try lock.withLock {
            stopLocked()
            let myGeneration = generation
            try camera.start(deviceID: _cameraID)
            let frames = camera.frames
            let (stream, cont) = AsyncStream.makeStream(of: GazeSample.self, bufferingPolicy: .bufferingNewest(1))
            // Detached: CoreML must never run on the caller's actor (often the MainActor).
            let task = Task.detached(priority: .userInitiated) { [self] in
                for await f in frames {
                    if Task.isCancelled { break }
                    cont.yield(process(pixelBuffer: f.pixelBuffer, time: f.timestampSeconds))
                }
                cont.finish()
            }
            cont.onTermination = { [weak self] _ in
                task.cancel()
                // Detached: onTermination can fire on the consumer's executor (e.g. the MainActor,
                // when it breaks out of `for await`), and `stop()` blocks until AVCaptureSession
                // has stopped. Routed through `stop(ifGeneration:)`, which takes `lock` itself, so
                // the check ("is this still the current session?") and the stop are atomic — a
                // bare check-then-call here could race a `start()` that begins between the two.
                Task.detached { [weak self] in
                    self?.stop(ifGeneration: myGeneration)
                }
            }
            loop = task
            output = cont
            return stream
        }
    }

    /// Stops the camera and finishes the stream. Blocks until AVCaptureSession has stopped:
    /// never call it on the MainActor. Idempotent: safe before `start()`, and safe to call
    /// concurrently from multiple callers (serialized by `lock`).
    public func stop() {
        lock.withLock { stopLocked() }
    }

    /// Stops only if `generation` still matches `expected`, atomically (both the check and the
    /// stop happen under one `lock` hold): used by a stream's `onTermination` so a termination of
    /// an old session can never stop a session a later `start()` has since opened. Not `private`:
    /// needs no camera, so `GazeKitTests` exercises it directly.
    func stop(ifGeneration expected: Int) {
        lock.withLock {
            guard generation == expected else { return }
            stopLocked()
        }
    }

    /// The actual teardown; every path funnels through here. Must run under `lock`.
    private func stopLocked() {
        generation += 1
        loop?.cancel()
        loop = nil
        camera.stop()
        output?.finish()
        output = nil
    }

    /// Test-only window into `generation`, so `GazeKitTests` can assert `stop(ifGeneration:)`'s
    /// guard without a camera. Not `private` for that reason; not meant for app code.
    var debugGeneration: Int { lock.withLock { generation } }

    /// One frame → sample. A frame without a usable face gives a no-face sample (confidence 0,
    /// NaN gaze and pose), so consumers keep a heartbeat ("Looking for your face") and reset any
    /// pending dwell. Not thread-safe (the landmarker tracks across frames): never call while started.
    public func process(pixelBuffer pb: CVPixelBuffer, time: Double) -> GazeSample {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let r = mesh.detect(pixelBuffer: pb), r.landmarks.count >= 468,
              let patch = HomographyEyePatchExtractor.extract(pixelBuffer: pb, landmarks: r.landmarks,
                                                               frameWidth: w, frameHeight: h)
        else { return Self.noFace(time) }
        let pose = HeadPoseSolver.solve(landmarks: r.landmarks, width: w, height: h)
        let origin = MetricFaceOrigin.compute(landmarks: r.landmarks, width: w, height: h)
        guard let raw = blaze.predict(eyePatch: patch, headVector: pose.flatMap { Self.vector($0.headVector) },
                                      faceOrigin3D: Self.vector(origin))
        else { return Self.noFace(time) }
        let xs = r.landmarks.map { $0[0] }, ys = r.landmarks.map { $0[1] }
        let face = PoseFeature(yaw: pose?.yaw ?? .nan, pitch: pose?.pitch ?? .nan,
                               faceX: (xs.min()! + xs.max()!) / 2, faceY: (ys.min()! + ys.max()!) / 2)
        return GazeSample(time: time, raw: raw, pose: face, confidence: r.score)
    }

    static func noFace(_ time: Double) -> GazeSample {
        GazeSample(time: time, raw: CGPoint(x: Double.nan, y: .nan),
                   pose: PoseFeature(yaw: .nan, pitch: .nan, faceX: .nan, faceY: .nan), confidence: 0)
    }

    private static func vector(_ v: [Float]) -> MLMultiArray? {
        guard v.count == 3, let a = try? MLMultiArray(shape: [1, 3], dataType: .float32) else { return nil }
        for i in 0..<3 { a[i] = NSNumber(value: v[i]) }
        return a
    }
}
