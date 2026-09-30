# Decisions

Every design choice behind Focus, with why and where it lives. Change one only with a new entry that supersedes it.

The Source column names the code (file and symbol) that carries the choice, and the wiki page that explains it
when there is one.

## Foundations
| # | Decision | Why | Source |
|---|---|---|---|
| F-1 | FocusCore imports CoreGraphics under `#if canImport(CoreGraphics)` and uses its native geometry conformances | Hand-written `CGPoint`/`CGRect` conformances were 130 lines of code the platform already ships | `Sources/FocusCore/Calibration.swift`, `FocusEngine.swift` (imports) |
| F-2 | The RBF input is the raw BlazeGaze point alone, no head-pose features | BlazeGaze already folds head pose into its output; revisit only if accuracy tests show head-movement error | `Sources/FocusCore/Calibration.swift` (`DisplayCalibration.map`); [Calibration-and-learning](Calibration-and-learning.md) |
| F-3 | `DisplayCalibration.map` rebuilds the RBF on every access; `FocusEngine` caches the maps | Keeps the calibration value type trivial and puts the one hot path's cache where it is used | `Sources/FocusCore/Calibration.swift` (`map`), `FocusEngine.swift` |
| F-4 | New persisted fields are optional or decoded with `decodeIfPresent`; `FocusSettings` gets a tolerant `init(from:)` | Synthesised `Decodable` fails on a missing key, which would mark every older setup file as broken | `Sources/FocusCore/Settings.swift`, `AppSettings.swift`, `Calibration.swift` (`init(from:)`) |
| F-5 | `FocusEngine` lives in exactly one isolation domain and is never `@unchecked Sendable` (see E-5) | A mutable engine shared across domains races silently; the compiler should prove confinement | `Sources/FocusCore/FocusEngine.swift` (`FocusEngine`); [Architecture](Architecture.md) |
| F-6 | Identical monitors with the same non-zero serial fall back to position for their display key | Two such monitors would otherwise share one `DisplayFingerprint.key` and one calibration | `Sources/FocusCore/Setup.swift` (`DisplayFingerprint.key`); [Setups](Setups.md) |

## Gaze
| # | Decision | Why | Source |
|---|---|---|---|
| G-1 | Vendor 8 MacGaze files at commit `3884a8c` behind a small `GazeTracker` wrapper | The pipeline was already validated upstream; a pinned copy with a "Modified:" header keeps diffs auditable | `Sources/GazeKit/GazeTracker.swift`; [Gaze-pipeline](Gaze-pipeline.md) |
| G-2 | GazeKit neither smooths nor clamps; `raw` is BlazeGaze's untouched output | Calibration, median and dwell live in FocusCore, where they are pure and unit-tested | `Sources/FocusCore/GazeSample.swift` (`GazeSample.raw`); [Gaze-pipeline](Gaze-pipeline.md) |
| G-3 | The two compiled CoreML models (~3.2 MB) are committed as SwiftPM resources | Builds work offline and never depend on a conversion step or a download | `Package.swift` (GazeKit resources) |
| G-4 | `GazeSample.time` is host monotonic seconds (the `CACurrentMediaTime()` base) | Samples, key times and click times must compare on one clock for guards and calibration | `Sources/FocusCore/GazeSample.swift` (`time`); [Architecture](Architecture.md) |
| G-5 | Frame streams use `bufferingNewest(1)`; frames are never written to disk | A slow consumer drops frames instead of building up lag; privacy needs no image persistence | `Sources/GazeKit/CameraCapture.swift`, `GazeTracker.swift` (`bufferingNewest`) |
| G-6 | No face yields `GazeSample(raw: .nan, pose: NaN, confidence: 0)` | Consumers never block, "Waiting to see your face" has data, and a pending dwell resets | `Sources/GazeKit/GazeTracker.swift` (`process(pixelBuffer:time:)`) |
| G-7 | `GazeSource.stop()` is never called on the MainActor | It blocks on `sessionQueue.sync`; on the main thread that freezes the UI | `Sources/GazeKit/GazeTracker.swift` (`stop()`) |
| G-8 | The video-replay trajectory test is a bench, not a unit test | It needs recorded traces and timing, which belong in `focus-bench` | `Sources/FocusBench/EngineBench.swift`; [Benches](Benches.md) |
| G-9 | Won't fix: raw enum token in the `focus-gaze` camera error message | Developer-only CLI; the message is still actionable | `Tools/focus-gaze/main.swift` |
| G-10 | Won't fix: "pas assez d'images" shown when the pose is NaN | Developer-only CLI; the retry advice is the same | `Tools/focus-gaze/main.swift` |
| G-11 | Won't fix: `probe` and `screens` keep separate capture functions | Sharing them saves a few lines in a spike tool and couples two commands | `Tools/focus-gaze/main.swift` |

## Architecture
| # | Decision | Why | Source |
|---|---|---|---|
| A-1 | Calibration uses 9 dots per screen (3×3 at x 10/50/90 %, y 12/50/88 %) plus dots on shared edges, 0.6 s travel + 1.0 s hold each; Space starts, Esc cancels | More and better-placed points for the RBF, and the shared edge is where screens get confused | `Sources/FocusCore/CalibrationLayout.swift`, `CalibrationRun.swift` (`travel`, `hold`); [Calibration-and-learning](Calibration-and-learning.md) |
| A-2 | The screen boundary is the "Head turn needed" setting, 30–70 %, default 50 %, not a fixed hysteresis | People sit at different angles, so the boundary must be tunable | `Sources/FocusCore/Settings.swift` (`headTurn`); [Decision-engine](Decision-engine.md) |
| A-3 | Panes and windows wait `typingPause` (3 s, 1–10 s) after a keystroke; screens switch after a fixed 1 s | Reading a neighbour pane must not steal keystrokes, but turning to another screen is a clear intent | `Sources/FocusCore/Settings.swift` (`typingPause`, `screenTypingPause`); [Decision-engine](Decision-engine.md) |
| A-4 | Only Camera and Accessibility are required; key and mouse idle come from `CGEventSource`, no Input Monitoring | One fewer scary permission, and idle times need none | `Sources/FocusMac/InputMonitor.swift`; [Permissions-and-privacy](Permissions-and-privacy.md) |
| A-5 | Camera 1280×720 at ≤ 15 fps | Enough to locate head and eyes at a lower CPU cost | `Sources/GazeKit/CameraCapture.swift` |
| A-6 | One-Euro smoothing on yaw, pitch, face position and gaze point, in FocusCore | Removes jitter at rest without lag on fast turns; pure code stays testable | `Sources/FocusCore/OneEuro.swift` (`OneEuroFilter`); [Gaze-pipeline](Gaze-pipeline.md) |
| A-7 | "Learn from my clicks" is a toggle, default on; recalibrating clears learned points | Users must be able to stop the model changing, and a fresh calibration must start clean | `Sources/FocusCore/FocusEngine.swift`, `SetupResolver.swift`; [Calibration-and-learning](Calibration-and-learning.md) |
| A-8 | The gaze dot overlay is off by default | It is a diagnostic, distracting in daily use | `Sources/FocusCore/AppSettings.swift` (`showGazeDot`) |
| A-9 | Pause hotkey ⇧⌘G, rebindable; the binding must include a modifier, Esc cancels recording | A bare key would fire while typing | `Sources/FocusCore/AppSettings.swift` (`HotKeySpec.default`), `Sources/FocusMac/HotKey.swift` |
| A-10 | Launch at login is a toggle, default on (`SMAppService.mainApp`) | The app is useless unless it is running | `Sources/FocusCore/AppSettings.swift` (`launchAtLogin`), `Sources/FocusApp/AppController.swift` |
| A-11 | Camera choice is a popup of all video devices, "Built-in (default)" first | An external camera that faces you beats the built-in one | `Sources/FocusApp/SettingsView.swift` |
| A-12 | Menu: status line, Pause/Resume, Recalibrate (all / per screen / new display), Settings…, Welcome Guide…, Setups, Quit | Everything reachable without opening a window | `Sources/FocusApp/StatusItemController.swift` |
| A-13 | Every reason for not acting is a named status, from "Active · on <screen>" to "may need a new calibration" | The user can always tell why focus isn't following | `Sources/FocusCore/AppStatus.swift` (`AppStatus`); [Troubleshooting](Troubleshooting.md) |
| A-14 | Onboarding: Welcome → Permissions (polling) → Places → Calibrate → Adjust → Try it → Done, reopenable | The permissions page updates by itself so nobody hunts for a refresh | `Sources/FocusCore/AppStatus.swift` (`OnboardingStep`), `Sources/FocusApp/OnboardingView.swift` |
| A-15 | Notifications: drift on a screen, new display (once per display), layout changed, setup switched, new place | The user learns why tracking got worse without watching the menu | `Sources/FocusCore/NotificationPolicy.swift`, `Sources/FocusApp/Notifier.swift` |
| A-16 | Settings shows a live readout: facing screen, yaw, pitch, tracking state | Lets the user tune "Head turn needed" against real numbers | `Sources/FocusApp/SettingsView.swift`; [Settings](Settings.md) |
| A-17 | Every setting has an ⓘ popover | Sliders with thresholds need an explanation next to them | `Sources/FocusApp/SettingsView.swift` (`info:`); [Settings](Settings.md) |
| A-18 | Minimum macOS is 15, not 14 | BlazeGaze ships as an mlprogram, which needs macOS 15 | `Package.swift` (`platforms`) |
| A-19 | Not built: per-app exclusions, profiles, tmux panes, auto-update, localisation, licensing | Each adds settings and upkeep for a need nobody has shown yet; the core loop comes first | — |
| A-21 | `GazeSource` is the only protocol (real camera + scripted replay) | A protocol pays only where two implementations exist | `Sources/GazeKit/GazeSource.swift` (`GazeSource`) |
| A-22 | No automated run may trigger a TCC prompt; check status and skip with a reason | Benches and tests run unattended and must never block on a human | `scripts/bench.sh` (lint group 0); [Benches](Benches.md) |
| A-24 | The app is signed by a local self-signed identity (`scripts/make-signing-cert.sh`), ad hoc when it is absent | No Developer ID; an ad-hoc signature changes every build and macOS drops Camera/Accessibility with it, a stable identity keeps them | `scripts/build-app.sh`, `scripts/make-signing-cert.sh`; [Architecture](Architecture.md) |

## Engine and macOS layer
| # | Decision | Why | Source |
|---|---|---|---|
| E-1 | The switch threshold is `0.5 + (h − 0.3)/2` of the gap between the two screens' calibration clouds, plus a 0.05 return band | Below 50 % a plain mapping lets both screens claim the same poses; this form can never ping-pong | `Sources/FocusCore/ScreenClassifier.swift` (`threshold`, `returnBand`); [Decision-engine](Decision-engine.md) |
| E-2 | A screen switch focuses the gazed window of the target screen when the map is trusted, else the screen's last window | Lands on what you are reading; the fallback keeps the window you were in | `Sources/FocusCore/FocusEngine.swift`, `TargetResolver.swift` (`window(at:...)`); [Focusing-windows-and-panes](Focusing-windows-and-panes.md) |
| E-3 | Mouse activity comes from `CGEventSource.secondsSinceLastEventType`; NSEvent monitors only report click positions | No extra permission and fewer moving parts than monitoring every mouse event | `Sources/FocusMac/InputMonitor.swift` |
| E-4 | `CameraCapture.start()` never prompts; only `focus-gaze` and onboarding request camera access | A background start must never raise a TCC dialog (A-22) | `Sources/GazeKit/CameraCapture.swift` (`start()`) |
| E-5 | `FocusEngine` is not `@MainActor`; it is a non-Sendable class confined by its owner, the `@MainActor` `AppController` | Swift 6 region checking already confines it; the annotation would push every pure test onto the main actor | `Sources/FocusCore/FocusEngine.swift`, `SetupResolver.swift` (class doc comment) |
| E-6 | `InputActivity` has no single `isQuiet`; callers use `allowsScreenSwitch(at:_:)` and `allowsSameScreen(at:_:)` | Screens and panes have different typing pauses (A-3) | `Sources/FocusCore/FocusEngine.swift` (`InputActivity`) |
| E-7 | `GazeTracker.process(pixelBuffer:time:)` is public and returns a no-face sample instead of nil | The vision bench feeds still images through it (G-6) | `Sources/GazeKit/GazeTracker.swift` (`process(pixelBuffer:time:)`) |
| E-8 | `NotificationPolicy` is the only notification logic; the notified set lives in `AppSettings.notifiedDisplays` | One place decides, so the app can't notify twice for the same display | `Sources/FocusCore/NotificationPolicy.swift`, `AppSettings.swift` (`notifiedDisplays`) |

## App
| # | Decision | Why | Source |
|---|---|---|---|
| UI-1 | Calibration shows one window at a time, on the screen being calibrated | Same data as one window per display, and the user always knows which screen to face | `Sources/FocusApp/CalibrationWindow.swift` |
| UI-2 | The executable target is `Focus` (folder `Sources/FocusApp`) | Binary, product and bundle executable share one name | `Package.swift` |
| UI-3 | `AppSettings` wraps `FocusSettings`; `FocusSettings` holds engine and actuator behaviour only | Engine settings stay pure and benchable; camera, dot, hotkey and login item are app concerns, and one owner per field avoids two sources of truth | `Sources/FocusCore/AppSettings.swift` (`AppSettings.engine`); [Settings](Settings.md) |
| UI-4 | Notification permission is requested at the end of onboarding, by a click, never at launch | A prompt at launch arrives with no context and is often denied | `Sources/FocusApp/Notifier.swift` (`requestAuthorization`) |
| UI-5 | Permission requests happen only in onboarding button actions; status reads are allowed anywhere | Keeps selftest, smoke runs and benches prompt-free (A-22) | `Sources/FocusMac/Permissions.swift`, `Sources/FocusApp/OnboardingView.swift`; [Permissions-and-privacy](Permissions-and-privacy.md) |
| UI-6 | `--smoke` never shows onboarding, registers the login item or hotkey, starts the camera, or writes outside `FOCUS_SUPPORT_DIR` | A bench launch must leave the user's Mac exactly as it found it | `Sources/FocusApp/AppController.swift` (`smoke`); [Benches](Benches.md) |
| UI-7 | `UNUserNotificationCenter` and `SMAppService` are touched only when `Bundle.main.bundleIdentifier != nil` | Both crash or fail outside a `.app` bundle, e.g. `swift run Focus` | `Sources/FocusApp/AppController.swift`, `Notifier.swift` |
| UI-8 | Global CG coordinates everywhere; AppKit conversion only in `nsPoint(fromCG:)` and `nsScreen(forCG:)` | One flip in one place instead of y-axis bugs scattered across views | `Sources/FocusApp/AppController.swift` (`nsPoint(fromCG:)`) |
| UI-9 | The camera runs only while `AppConditions.wantsCamera` is true | The LED is off whenever Focus is paused, locked, uncalibrated or missing a permission | `Sources/FocusCore/AppStatus.swift` (`AppConditions.wantsCamera`) |

## Split panes
| # | Decision | Why | Source |
|---|---|---|---|
| PN-1 | Pane focus only in allow-listed terminals and editors, any `com.jetbrains.` id, plus Xirp (17 ids) | In browsers and chat a region of a page must never steal focus; each listed app exposes its panes in a known way. Xirp's panes accept AX focus | `Sources/FocusCore/PaneApps.swift` (`PaneApps.bundleIDs`); [ax-panes spike](../spikes/ax-panes.md) |
| PN-2 | A pane is the deepest focusable AX element ≥ 200×150 pt, clipped to every ancestor's frame | Electron wraps panes in window-sized focusable groups, and text areas are as tall as the document | `Sources/FocusCore/PaneFinder.swift` (`PaneFinder.panes`); [ax-panes spike](../spikes/ax-panes.md) |
| PN-3 | AX is bounded: 0.25 s global messaging timeout, at most 3000 nodes per walk, small subtrees pruned | A hung app would otherwise freeze the main actor for the default 6 s | `Sources/FocusMac/WindowProvider.swift` (`axTimeout`), `Sources/FocusCore/PaneFinder.swift` (`maxNodes`) |
| PN-4 | Pane lists are cached 2 s, an empty list only 1 s, after setting `AXManualAccessibility` | Electron builds its tree about a second after being asked | `Sources/FocusMac/PaneProvider.swift` |
| PN-5 | AX focus first, verified via `AXFocusedUIElement`; a synthetic centre click only if AX failed, the setting is on, the app is allowed, post access is already granted and the centre is clear | A click is the last resort and must never land on the wrong pane or window | `Sources/FocusMac/FocusActuator.swift`, `Sources/FocusCore/PaneClick.swift` (`point(for:window:world:)`); [Focusing-windows-and-panes](Focusing-windows-and-panes.md) |
| PN-6 | Never request event-posting access; only `CGPreflightPostEventAccess()` is read | A request would raise a TCC prompt (A-22); without the grant the click path is simply skipped | `Sources/FocusMac/Permissions.swift` (`eventPosting`) |
| PN-7 | Synthetic events carry marker `0x464F4355` in `.eventSourceUserData`; `InputMonitor` ignores them | Our own click must not start the mouse pause or become a learned calibration point | `Sources/FocusMac/InputMonitor.swift` (`syntheticMarker`) |
| PN-8 | `PaneProvider` has `element(of:pane:)`, `invalidate()` and `allows` | The actuator needs the AX element, the fixture needs a cache reset, the bench needs a bundle-free allowlist | `Sources/FocusMac/PaneProvider.swift` |
| PN-9 | One pane-click setting, `FocusSettings.syntheticClickFallback` | Two names for one toggle would drift apart | `Sources/FocusCore/Settings.swift` (`syntheticClickFallback`) |
| PN-10 | The pane focuser plugs into `FocusActuator` through `paneFocuser` | One actuator init; panes stay optional | `Sources/FocusMac/FocusActuator.swift` (`paneFocuser`) |

## Setups
| # | Decision | Why | Source |
|---|---|---|---|
| S-1 | `SetupResolver` is a FocusCore `@MainActor` class; the app part is `SetupController` | Override, Wi-Fi drop and learned-point rules are fragile and must be unit-tested and benched headlessly | `Sources/FocusCore/SetupResolver.swift`, `Sources/FocusApp/SetupController.swift`; [Setups](Setups.md) |
| S-2 | `EnvironmentFingerprinter.current(displays:cameraID:)` takes the displays as input | A static function can't reach the app's `DisplayProvider` without a second reconfiguration callback | `Sources/FocusMac/EnvironmentFingerprinter.swift` (`current(displays:cameraID:)`) |
| S-3 | `Permissions.requestLocation()` and the Places onboarding step exist | The SSID needs Location | `Sources/FocusMac/Permissions.swift` (`requestLocation`), `Sources/FocusApp/PlacesStep.swift` |
| S-4 | The SSID is polled every 15 s, not observed via `CWEventDelegate` | No delegate or queue hopping; screens and camera already give instant callbacks | `Sources/FocusApp/SetupController.swift` (`timer`) |
| S-5 | A Wi-Fi drop is not an environment change; the last SSID is kept while screens and camera are unchanged | Wake and roaming lose Wi-Fi for a while and must not switch setups or cancel a manual pick | `Sources/FocusCore/SetupResolver.swift` (`isEnvironmentChange`); [Setups](Setups.md) |
| S-6 | An ambiguous match does not pause: the current setup stays if it fits, else the first candidate; picking one records the SSID | Pausing for a tie punishes the common case; the recorded SSID breaks the tie next time | `Sources/FocusCore/SetupResolver.swift`; [Setups](Setups.md) |
| S-7 | Picking a setup whose monitors match but whose geometry differs adopts the new geometry | A resolution or scaling change would otherwise need the same manual pick at every launch | `Sources/FocusCore/SetupResolver.swift`; [Setups](Setups.md) |
| S-8 | No match pauses and posts "New place detected"; a new setup inherits calibrations of identical screens from the last setup with the same camera | With setups every screen-set change is a new place, and unchanged screens keep working | `Sources/FocusCore/SetupResolver.swift`; [Setups](Setups.md) |

## Hardening found by benches and review
| # | Decision | Why | Source |
|---|---|---|---|
| H-1 | `CameraCapture.start()` is synchronous; `GazeTracker` holds one lifecycle lock across `start`/`stop`, and detached termination stops only its own generation | An async start racing a pause's stop could hang or leave the camera on; a stale start's `stop()` could otherwise kill a newer session | `Sources/GazeKit/GazeTracker.swift`, `CameraCapture.swift` (lifecycle-lock doc comments); [Gaze-pipeline](Gaze-pipeline.md) |
| H-2 | `InputMonitor`'s idle counters read `CGEventSourceStateID.hidSystemState` (hardware only); every synthetic event Focus posts uses a `.privateState` source | Keeps Focus's own clicks and warps from ever being counted as user activity, which would wrongly suppress the typing/mouse guards right after Focus acts | `Sources/FocusMac/InputMonitor.swift` (class doc comment); [Permissions-and-privacy](Permissions-and-privacy.md) |
| H-3 | Focus's synthetic pane click posts at `.cgSessionEventTap`, not `.cghidEventTap` | A HID-tap click was found to reset the real `.hidSystemState` idle counter even from a `.privateState` source; the session tap still delivers the click but leaves that counter untouched | `Sources/FocusMac/FocusActuator.swift` (`postMarkedClick` doc comment); [Focusing-windows-and-panes](Focusing-windows-and-panes.md) |
| H-4 | Pane-click occluders ignore the Dock's always-on, click-through, full-display window, replacing it with the Dock's real strip (`NSScreen.frame` minus `visibleFrame`); a Dock window only qualifies at `kCGWindowLayer == 20` | Without the carve-out, the Dock's invisible full-screen layer blocked every pane click; matching by bounds alone would also have swallowed Launchpad and Mission Control | `Sources/FocusMac/FocusActuator.swift` (`occluders`, `dockStrip` doc comments); [Focusing-windows-and-panes](Focusing-windows-and-panes.md) |
| H-5 | The dead band around a narrow screen-to-screen gap widens continuously toward `2.5 × minScreenSeparation` around its midpoint, instead of falling back to raw centroid geometry below a floor | A hard floor only moved the ping-pong cliff to closer bezels; continuous widening keeps the switch boundary at the seam at any spacing | `Sources/FocusCore/ScreenClassifier.swift` (`minGap`, `gapFraction` doc comment); [Decision-engine](Decision-engine.md) |
| H-7 | A calibration or learned-clicks save clears its dirty flag only after the write to disk succeeds; failures are logged only, with no status-bar slot | Clearing dirty before saving could silently lose learned calibration on a write error; a UI slot for a rare disk failure wasn't judged worth it | `Sources/FocusApp/AppController.swift` (`saveLearned`, the calibration-completion `do`/`catch`) |
| H-8 | Closing the Setup Guide or Settings re-activates whatever app was frontmost before it opened | `NSApp.activate()` during onboarding/calibration/settings was never undone, so keyboard focus stayed on Focus after the window closed | `Sources/FocusApp/OnboardingView.swift`, `SettingsView.swift` (`appBeforeOnboarding`/`appBeforeSettings`) |
| H-9 | The gaze-dot overlay is one moving 18×18 click-through panel shared across displays, not one panel per display | Same information on screen, fewer views to keep positioned and in sync | `Sources/FocusApp/GazeDot.swift` |
| H-10 | The vision bench's "yaw follows head turn" check is `.skip`, not a loosened threshold, and is instead verified live by `scripts/morning-check.sh` | The check replays one still photo warped in 2-D, which cannot physically turn a head; the failure was in the check's premise, not the pipeline | `Sources/FocusBench/VisionBench.swift` (`yawFollowsTurnCheck`) |
| H-11 | Off-screen is measured from the box (yaw+pitch only) a screen's own calibration dots span, plus a 0.2 rad margin, instead of distance from the pose centroid; the setting is renamed `offScreenDistance` → `offScreenMargin` (the old saved key is ignored on purpose — it meant something else) | Up to 40 % of the main screen in the laptop-below layout read as "away" measured from the centroid; a close or wide screen's dot box is a better fit than a single point | `Sources/FocusCore/ScreenClassifier.swift` (`distance(_:toBoxOf:)`), `Settings.swift` (`offScreenMargin`); [Decision-engine](Decision-engine.md) |

**Known limit.** H-11 is not a fix for the laptop-below layout's three-screen junction: `screen-choice/laptop-below`
still misclassifies ~2 % of points there (bench rule ≤ 3 %). Changing the seam axis or the re-entry preference
traded one failure mode for another (fixing the corners brought back ping-pong at the seam); a real fix needs a
2-D rule, not a single pose axis per screen pair. `ScreenClassifier.swift`'s `gapFraction` still measures the
switch axis centroid-to-centroid; check the source, not this note, for what ships.

## Setups app and benches
| # | Decision | Why | Source |
|---|---|---|---|
| SA-1 | The `setupSwitched` notice keeps only its latest instance instead of stacking; other setup notices (new place, drift) stay enabled even while a calibration can't start | A queue of stale "now using …" notices was confusing; only the notices that need a calibration should wait for one to be possible | `Sources/FocusApp/Notifier.swift` (`FocusNotice.id`), `StatusItemController.swift` |
| SA-2 | Setup ▸ modals (rename, delete, the Places onboarding step) hand keyboard focus back to whatever app was frontmost before they opened, same as the Setup Guide (H-8) | One consistent rule for every Focus window that borrows focus, instead of one-off exceptions per window | `Sources/FocusApp/SetupController.swift` (`runModal`) |
| BF-1 | Bench `P4.7`'s preparatory click is guarded against a covering window and `skip`s instead of failing when one is present; the pane-fixture is always terminated before the next live-AX group runs | The prep click could land on whatever already covered the target and misreport the result; a leftover fixture process collided with the next group | `Sources/FocusBench/PaneBench.swift` (`coveringWindow`); [Benches](Benches.md) |
