# Settings

The Settings window (menu bar eye → "Settings…", ⌘,) is `Sources/FocusApp/SettingsView.swift`. Every
control writes through `AppController.update(_:)`, the single write path: it pushes the new values to the
engine and actuator, stops the camera when the camera changes (the next start opens the new device),
registers or unregisters the login item, re-derives the status and saves `settings.json`. Sliders save
once, when the drag ends. While the window is open the pane click fallback is suppressed, so Focus never
clicks into its own window.

## Controls

| Control | Default | Range | What it does | Drives |
|---|---|---|---|---|
| Switch delay | 300 ms | 100-1000 ms, step 50 | How long you must face another display before it takes the keyboard. | `engine.screenDwell` |
| Turn needed to switch | 50 % | 30-70 %, step 5 | Where the border between two displays sits in the gap between their nearest calibration dots. | `engine.headTurn` (`ScreenClassifier`) |
| Follow my eyes between windows and panes | on | toggle | Same-display window focus, plus split panes in allowlisted apps. | `engine.windowFocus` |
| Window and pane delay | 300 ms | 200-1500 ms, step 50 | How long your gaze rests on a window or pane before it gets focus. Disabled when the toggle above is off. | `engine.paneDwell` (also clamped on load) |
| Click a pane that ignores focus requests | on | toggle | Lets the actuator click a pane's centre when AX focus fails verification. Disabled when window focus is off. | `engine.syntheticClickFallback` → `FocusActuator.syntheticClickFallback` |
| Hold focus while I type | on | toggle | Typing holds same-display switches for the typing pause and screen switches for 1 s. | `engine.waitWhileTyping` (`InputActivity.allowsSameScreen` / `allowsScreenSwitch`) |
| Typing pause | 3 s | 1-10 s, step 0.5 | How long after the last key same-display switching waits. Disabled when the toggle above is off. | `engine.typingPause` |
| Learn from my clicks | on | toggle | Each click on the faced display becomes a calibration sample. | `engine.learnFromClicks` (`FocusEngine.recordClick`) |
| Camera | Built-in (default) | built-in + every external/Continuity camera | Which camera GazeKit opens; a saved camera that's unplugged shows "not connected" and GazeKit falls back to the built-in one. | `cameraID` → `GazeTracker.cameraID` at the next camera start |
| Move the pointer with focus | on | toggle | Puts the pointer on the newly focused window after a screen switch. | `moveCursor` → `FocusActuator.moveCursor` |
| Show gaze dot | off | toggle | A red marker at the estimated gaze point. | `showGazeDot` (overlay: plan 3b Task 9) |
| Pause shortcut | ⇧⌘G | any key + ⌘, ⌥ or ⌃ | System-wide pause/resume. Esc cancels recording; a combo another app holds is refused and the old one is kept. | `hotKey` → Carbon `HotKey` (`setHotKey`) |
| Open at login | on | toggle | Registers Focus as a login item. The default is applied once (`loginItemDefaultApplied`), never in `--smoke`/`--selftest` or an unbundled `swift run`. | `launchAtLogin` → `SMAppService.mainApp` |
| Recalibrate All / per display | — | buttons | Starts a calibration run; disabled while calibrating, paused, or without camera access. | `AppController.startCalibration` |
| Right now | — | read-only | Faced display, head yaw and pitch (degrees), status. | `facingKey`, `lastPose`, `status` |

## Fixed constants (not settings)

| Constant | Value | Where / why |
|---|---|---|
| `FocusSettings.screenTypingPause` | 1 s | Screens may switch this soon after a keystroke even while panes wait the typing pause. |
| `mousePause` | 1.5 s | Any mouse activity holds every switch; field exists but has no UI. |
| `CalibrationBuilder.minScreenSeparation` | 0.05 (≈ 3°) | Two displays with closer head poses can't be told apart by head direction; about twice the pose jitter at rest. |

## File and loading

`~/Library/Application Support/Focus/settings.json` (`FOCUS_SUPPORT_DIR` overrides it for benches).
Loading is tolerant: a missing or mistyped key keeps its default (`AppSettings.init(from:)`,
`FocusSettings.init(from:)`), so a file from an older or newer build never resets the other settings. A
file that isn't JSON at all is moved aside as `settings.json.broken` and defaults are used.
