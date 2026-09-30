# Gaze pipeline (GazeKit)

How a camera frame becomes a `GazeSample`, and what happens when the camera misbehaves.

## Stages

1. **Capture** (`CameraCapture`) — `AVCaptureSession` streams 1280×720 32BGRA frames at ≤ 15 fps
   (only the minimum frame duration is set, so low light can still slow the camera down further;
   locking an unsupported rate would raise an uncatchable ObjC exception).
2. **FaceMesh** (`CoreMLFaceMeshLandmarker`) — 468 landmarks via CoreML, routed to the ANE.
3. **Head pose** (`HeadPoseSolver`) — Kabsch alignment on a rigid landmark subset → yaw/pitch.
4. **Eye patch** (`HomographyEyePatchExtractor`) — a homography-warped eye crop from the landmarks.
5. **BlazeGaze** (`BlazeGazeRunner`) — CoreML model, eye patch + head vector + face origin → a raw
   gaze point in normalized image space, before any calibration.

`GazeTracker.process(pixelBuffer:time:)` runs stages 2–5 for one frame and returns a `GazeSample`.

## GazeSample

```swift
public struct GazeSample: Sendable {
    public var time: Double        // seconds, host clock (CACurrentMediaTime base)
    public var raw: CGPoint        // BlazeGaze point before calibration
    public var pose: PoseFeature
    public var confidence: Double  // 0…1
}
```

`time` is the frame's presentation timestamp converted from the capture session's clock to the
host clock (`CMSyncConvertTime`), so it's directly comparable to `CACurrentMediaTime()` — the
session clock is only the host clock by coincidence.

**No-face samples**: when FaceMesh finds fewer than 468 landmarks, the eye-patch homography fails,
or BlazeGaze itself declines, `process` returns `confidence == 0` with `raw` and `pose` set to NaN
instead of throwing or skipping the frame. Consumers keep a heartbeat ("Looking for your face") and
reset any pending dwell, rather than stalling silently.

## Not done here

Smoothing (RBF), calibration and dwell/switch logic all live in FocusCore, which consumes the raw
`GazeSample` stream. GazeKit's job stops at "one frame in, one uncalibrated sample out."

## Lifecycle

- `start()` is restartable: a running session is stopped first, then the camera is (re)configured
  and a fresh `AsyncStream<GazeSample>` is returned. It blocks while the session starts, so callers
  must invoke it off the `MainActor`.
- `stop()` blocks until `AVCaptureSession` has actually stopped — also never call it on the
  `MainActor`.
- The frame loop runs as a `Task.detached`: CoreML inference must never run on the caller's actor
  (typically the `MainActor`).
- `process(pixelBuffer:time:)` is not thread-safe (the landmarker tracks state across frames):
  never call it while the tracker is started.

## Camera choice and fallback

- `CameraCapture.devices()` lists every camera macOS offers (built-in, USB/external, Continuity
  Camera) via `AVCaptureDevice.DiscoverySession`. Enumeration never opens a device, so it never
  triggers a TCC prompt.
- `CameraCapture.pick(_:preferred:)` chooses the camera whose `id` (`AVCaptureDevice.uniqueID`,
  stable across reconnects) matches `preferred`; if that camera isn't present, it falls back to the
  built-in camera, then to whatever's first. This means an unplugged external camera degrades to
  the built-in one instead of leaving tracking off, and switches back once it returns.
- `GazeTracker.cameraID` sets the preferred device for the *next* `start()`; changing it while
  running has no effect until restart.

## Interruption, runtime error and disconnect recovery

`CameraState` reports camera health on `CameraCapture`'s session queue — never the main thread, and
not any particular AVFoundation queue either (every notification handler hops onto it before
reporting, so reports are always in the same order as the session mutations that caused them; hop
to the main thread before touching UI):

```swift
public enum CameraState: Sendable, Equatable { case running, interrupted, unavailable(String) }
```

- **Interruption** (`AVCaptureSession.wasInterruptedNotification`) — another app took the camera, or
  the laptop lid closed. Reported as `.interrupted`; AVFoundation resumes the session by itself, and
  `interruptionEndedNotification` reports `.running`.
- **Runtime error** (`AVCaptureSession.runtimeErrorNotification`) — e.g. a media services reset or a
  busy device. Reported as `.unavailable(reason)`, then a retry is scheduled 2 s later; a failed
  restart posts another runtime error, which schedules the next retry, so this converges without a
  bounded retry counter. The retry also reports `.running` if the session turns out to already be
  running by the time it fires (e.g. it recovered on its own), so a stale `.unavailable` never lingers.
- **Disconnect / connect** (`AVCaptureDevice.was{Dis,}ConnectedNotification`, filtered to video
  devices) — re-runs `pick` against the current device list. A disconnect of some *other* camera is
  ignored; losing the active camera or gaining a new one reconfigures the session and reports
  `.running` (or `.unavailable` if no camera is available, and the next connect notification
  retries). Reconfiguration compares the wired-up input's device by *identity and connectedness*,
  not just `uniqueID`: a replugged camera gets a fresh `AVCaptureDevice` object even though its
  `uniqueID` is unchanged, so a `uniqueID`-only comparison would treat the stale, now-dead input as
  still valid and never reconnect it.
- All reports are gated on "is a camera still wanted" (`wantRunning`, set by `start()`/cleared by
  `stop()`), so nothing reports after `stop()` has been called.

`GazeTracker.onCameraState` forwards `CameraCapture.onStateChange` for the status line ("Camera
off", "no usable camera").

## Privacy

Frames are never written to disk. The frame stream buffers only the newest frame
(`.bufferingNewest(1)`); a slow consumer drops older frames rather than accumulating them.

## Permissions

`CameraCapture.checkAuthorized()` only *checks* `AVCaptureDevice.authorizationStatus` and throws if
access isn't granted — it never prompts. Only human-driven paths (onboarding UI, `focus-gaze`) call
`requestAccess()`, which shows the system dialog. This keeps tests, benches and `focus-gaze cameras`
from ever raising a TCC prompt.

## Model provenance and licences

FaceMesh and BlazeGaze are CoreML models fetched by `scripts/fetch-models.sh`; see
`THIRD_PARTY_NOTICES.md` for provenance and licences.

## Measured cost

Bench group 3 (`focus-bench vision`, release build, `portrait.jpg`, `-c release`): one tracker, 5
warm-up `process` calls, 60 timed — median 6.1 ms, p95 8.3 ms (M-series Mac, 2026-09-30). Both are
well under the 20 ms target (the 15 fps camera gives a frame every 67 ms), so `process` itself is
not the pipeline's latency bottleneck. See `Benches.md` for the full group-3 table.
