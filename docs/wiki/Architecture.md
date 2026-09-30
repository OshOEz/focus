# Architecture

## FocusApp

The `Focus` executable (`Sources/FocusApp`) is a menu bar agent. `AppController` owns every component
and is the only place where their events meet.

```
GazeTracker ──samples──▶ AppController (@MainActor) ◀── StatusItemController (menu commands)
InputMonitor ─activity/clicks─▶ │  World = DisplayProvider + WindowProvider
SystemStateMonitor ─suspend──▶  │  engine.decide(sample, world, input) → FocusAction?
DisplayProvider ─screens changed▶│  or, while calibrating: CalibrationWindowController.add(sample)
                                 ▼
                         FocusActuator.perform(action) ──▶ AX / NSRunningApplication / pointer warp
```

### One state, one status

Everything the menu shows comes from one `AppConditions` value (FocusCore). `AppController` refreshes
its fields from the components and turns it into an `AppStatus` (first match wins, unit-tested):

| Condition (first true wins)        | Status                    | Camera |
|------------------------------------|---------------------------|--------|
| user paused                        | Paused                    | off    |
| locked / asleep / screensaver      | Paused while locked       | off    |
| no camera permission               | Waiting for camera access | off    |
| camera failed or its stream ended  | Can't reach the camera    | retry  |
| calibrating                        | Calibrating…              | on     |
| no Accessibility                   | Waiting for Accessibility access | off |
| no connected display calibrated    | No screen calibrated yet  | off    |
| one display, window focus off      | One screen: …             | off    |
| no face for 1 s                    | Waiting to see your face… | on     |
| click errors drifted on a display  | … may need a new calibration | on     |
| otherwise                          | Active · on …             | on     |

The camera runs only while `AppConditions.wantsCamera` is true, so the camera LED is off whenever its
frames would be thrown away. That is the privacy promise the user can check with their own eyes.
`updateStatus()` re-derives everything and starts or stops the camera; it is called from every event
and from a 1 s timer (permission changes have no notification, so they are polled).

### Threading

- Everything, including `FocusEngine`, lives on the MainActor. The engine is a plain non-Sendable
  class; owning it from one actor is what keeps it safe, not locks.
- CoreML runs in GazeTracker's own detached loop. Only finished `GazeSample`s reach the MainActor,
  through an `AsyncStream` the MainActor task iterates.
- Model loading, `GazeTracker.start()` and `stop()` all block their caller (model compilation,
  `AVCaptureSession` start/stop on its session queue), so they run in detached tasks.
- A camera session is one `Task` whose value is the tracker it opened. Stopping cancels it, waits for
  it to wind down (it may still be opening the camera) and then stops that tracker. The next start
  awaits that stop, so two sessions never overlap.
- `cameraGeneration` is bumped on every stop. When a stream ends, only an end with the current
  generation means "camera lost"; one we stopped ourselves is ignored.
- A lost or failed camera is retried every 3 s, never in a tight loop. CameraCapture also reports
  interruptions (another app took the camera) on its session queue; the handler only hops to the
  MainActor and never calls back into the tracker.
- Every camera start reloads the engine's calibrations, which resets dwell, smoothing and the action
  latch: after a pause or a lock, the first look must be able to switch again.

### Persistence

- `~/Library/Application Support/Focus/settings.json` (`AppSettings`) and `setups/<uuid>.json`.
- `FOCUS_SUPPORT_DIR` replaces that folder. Benches point it at a throwaway directory.
- `AppController.update(_:)` is the only write path for settings: it applies the change to the engine
  and actuator, saves, and re-derives the status.
- What the engine learns from clicks is saved every 5 minutes, on pause, on lock and on quit, not on
  every click.
- Calibrations are keyed by `DisplayFingerprint.uniqueKeys`, so two identical monitors never share one.

### Setups

`SetupResolver` (`Sources/FocusCore/SetupResolver.swift`) matches the live environment (screens, camera,
Wi-Fi name) against saved setups and swaps the engine's calibration; `SetupController`
(`Sources/FocusApp`) drives it from launch, display/camera changes and wake, and builds the Setup ▸ menu.
Full rules and the menu shape are in [Setups](Setups.md).

### Launch modes

- `--selftest` exits before `NSApplication` starts: no UI and no permission prompt.
- `--smoke` is bench mode: no onboarding, hotkey, login item or camera, and no setup writes.
  The status item still appears, so a bench can check that the app starts and stays alive.
- The app never requests a permission at launch. Requests happen only in onboarding, from a button
  a person clicks.
