# Decisions

Every ruling taken while building Focus, with why and where it came from. Change one only with a new entry that supersedes it.

Sources are relative to `docs/superpowers/`. Tables run oldest plan first. `R-n` rows mirror the numbering of
`plans/2026-09-30-reconciliation.md`, which is binding over plans 3a/3b/4/5 where they disagree.

## Plan 1 — Foundations (2026-09-29)
| # | Decision | Why | Source |
|---|---|---|---|
| P1-1 | FocusCore imports CoreGraphics under `#if canImport(CoreGraphics)` and uses its native geometry conformances | Hand-written `CGPoint`/`CGRect` conformances were 130 lines of code the platform already ships | plans/2026-09-30-plan-1-followups.md §Décisions |
| P1-2 | The RBF input is the raw BlazeGaze point alone, no head-pose features | BlazeGaze already folds head pose into its output; revisit only if accuracy tests show head-movement error | plans/2026-09-30-plan-1-followups.md §Décisions |
| P1-3 | `DisplayCalibration.map` rebuilds the RBF on every access; `FocusEngine` caches the maps | Keeps the calibration value type trivial and puts the one hot path's cache where it is used | plans/2026-09-30-plan-1-followups.md §Décisions |
| P1-4 | New persisted fields are optional or decoded with `decodeIfPresent`; `FocusSettings` gets a tolerant `init(from:)` | Synthesised `Decodable` fails on a missing key, which would mark every older setup file as broken | plans/2026-09-30-plan-1-followups.md §Plan 3 |
| P1-5 | `FocusEngine` lives in exactly one isolation domain and is never `@unchecked Sendable` | A mutable engine shared across domains races silently; the compiler should prove confinement | plans/2026-09-30-plan-1-followups.md §Plan 3 (refined by P3a-6) |
| P1-6 | Identical monitors with the same non-zero serial fall back to position for their display key | Two such monitors would otherwise share one `DisplayFingerprint.key` and one calibration | plans/2026-09-30-plan-1-followups.md §Plan 3 |

## Plan 2 — Gaze (2026-09-30)
| # | Decision | Why | Source |
|---|---|---|---|
| P2-1 | Vendor 8 MacGaze files at commit `3884a8c` behind a small `GazeTracker` wrapper | The pipeline was already validated upstream; a pinned copy with a "Modified:" header keeps diffs auditable | plans/2026-09-30-plan-2-gaze.md §Architecture |
| P2-2 | GazeKit neither smooths nor clamps; `raw` is BlazeGaze's untouched output | Calibration, median and dwell live in FocusCore, where they are pure and unit-tested | plans/2026-09-30-plan-2-gaze.md §Global Constraints |
| P2-3 | The two compiled CoreML models (~3.2 MB) are committed as SwiftPM resources | Builds work offline and never depend on a conversion step or a download | plans/2026-09-30-plan-2-gaze.md §Architecture |
| P2-4 | `GazeSample.time` is host monotonic seconds (the `CACurrentMediaTime()` base) | Samples, key times and click times must compare on one clock for guards and calibration | plans/2026-09-30-plan-2-gaze.md §Global Constraints |
| P2-5 | Frame streams use `bufferingNewest(1)`; frames are never written to disk | A slow consumer drops frames instead of building up lag; privacy needs no image persistence | plans/2026-09-30-plan-2-gaze.md §Global Constraints |
| P2-6 | Camera asks 1280×720 at 30 fps — superseded by A-5 | Upstream default | plans/2026-09-30-plan-2-gaze.md §Global Constraints |
| P2-7 | A frame without a face returns `nil` — superseded by P2-8 | Avoided NaN samples reaching FocusCore | plans/2026-09-30-plan-2-gaze.md §Review Focus |
| P2-8 | No face yields `GazeSample(raw: .nan, pose: NaN, confidence: 0)` | Consumers never block, "Looking for your face" has data, and a pending dwell resets | plans/2026-09-30-plan-1-followups.md §Plan 2 → plan 3 |
| P2-9 | `GazeSource.stop()` is never called on the MainActor | It blocks on `sessionQueue.sync`; on the main thread that freezes the UI | plans/2026-09-30-plan-1-followups.md §Plan 2 → plan 3 |
| P2-10 | Spec §11's video-replay trajectory test becomes a bench, not a unit test | It needs recorded traces and timing, which belong in `focus-bench` | plans/2026-09-30-plan-1-followups.md §Plan 2 → plan 3 |
| P2-11 | Won't fix: raw enum token in the `focus-gaze` camera error message | Developer-only CLI; the message is still actionable | plans/2026-09-30-plan-1-followups.md §Plan 2 → plan 3 |
| P2-12 | Won't fix: "pas assez d'images" shown when the pose is NaN | Developer-only CLI; the retry advice is the same | plans/2026-09-30-plan-1-followups.md §Plan 2 → plan 3 |
| P2-13 | Won't fix: `probe` and `screens` keep separate capture functions | Sharing them saves a few lines in a spike tool and couples two commands | plans/2026-09-30-plan-1-followups.md §Plan 2 → plan 3 |

## Architecture (2026-09-30)
| # | Decision | Why | Source |
|---|---|---|---|

## Plan 3a — Engine and FocusMac (2026-09-30)
| # | Decision | Why | Source |
|---|---|---|---|
| P3a-1 | The switch threshold is `0.5 + (h − 0.3)/2` of the gap between the two screens' calibration clouds, plus a 0.05 return band | Below 50 % a plain mapping lets both screens claim the same poses; this form can never ping-pong | plans/2026-09-30-plan-3a-engine-focusmac.md §Rulings |
| P3a-2 | A screen switch focuses the gazed window of the target screen when the map is trusted, else the screen's last window | ; the fallback keeps the pane you were in | plans/…-plan-3a-engine-focusmac.md §Rulings |
| P3a-3 | Mouse activity comes from `CGEventSource.secondsSinceLastEventType`; NSEvent monitors only report click positions | No extra permission and fewer moving parts than monitoring every mouse event | plans/…-plan-3a-engine-focusmac.md §Rulings |
| P3a-4 | Calibration is 9 dots + shared-edge dots at 0.6 s travel + 1.0 s hold, not "5 targets × 2 s" | The architecture's CalibrationController line predates its own delta (A-1) | plans/…-plan-3a-engine-focusmac.md §Rulings |
| P3a-5 | `CameraCapture.start()` never prompts; only `focus-gaze` and onboarding request camera access | A background start must never raise a TCC dialog (A-22) | plans/…-plan-3a-engine-focusmac.md §Rulings |
| P3a-6 | `FocusEngine` is not `@MainActor`; it is a non-Sendable class confined by its owner (supersedes A-23) | Swift 6 region checking already confines it; the annotation would push every pure test onto the main actor | plans/…-plan-3a-engine-focusmac.md §Rulings |
| P3a-7 | FocusMac imports AVFoundation | `Permissions.camera` and the camera list need it; the module table omitted it | plans/…-plan-3a-engine-focusmac.md §Rulings |

## Plan 3b — App (2026-09-30)
| # | Decision | Why | Source |
|---|---|---|---|
| P3b-1 | 9 dots plus edges at ~1.6 s wins over the architecture's "5 targets × 2 s" (same as P3a-4) | The delta is binding over the component sketch | plans/2026-09-30-plan-3b-app.md §Self-review, deviation 1 |
| P3b-2 | Calibration shows one window at a time, on the screen being calibrated | Same data as one window per display, and the user always knows which screen to face | plans/…-plan-3b-app.md §Self-review, deviation 2 |
| P3b-3 | The executable target is `Focus` (folder `Sources/FocusApp`) | Binary, product and bundle executable share one name | plans/…-plan-3b-app.md §Self-review, deviation 3 |
| P3b-4 | `AppSettings` wraps `FocusSettings` instead of adding app-only fields to it | Engine settings stay pure and benchable; camera, dot, hotkey and login item are app concerns | plans/…-plan-3b-app.md §Self-review, deviation 4 |
| P3b-5 | Plan 3b keeps a single setup until plan 5 | Setups are plan 5's feature; a placeholder store would be thrown away | plans/…-plan-3b-app.md §Self-review, deviation 5 |
| P3b-6 | Notification permission is requested at the end of onboarding, by a click, never at launch | A prompt at launch arrives with no context and is often denied | plans/…-plan-3b-app.md §Self-review, deviation 6 |
| P3b-7 | Permission requests happen only in onboarding button actions; status reads are allowed anywhere | Keeps selftest, smoke runs and benches prompt-free (A-22) | plans/…-plan-3b-app.md §Specific constraints |
| P3b-8 | `--smoke` never shows onboarding, registers the login item or hotkey, starts the camera, or writes outside `FOCUS_SUPPORT_DIR` | A bench launch must leave the user's Mac exactly as it found it | plans/…-plan-3b-app.md §Specific constraints |
| P3b-9 | `UNUserNotificationCenter` and `SMAppService` are touched only when `Bundle.main.bundleIdentifier != nil` | Both crash or fail outside a `.app` bundle, e.g. `swift run Focus` | plans/…-plan-3b-app.md §Specific constraints |
| P3b-10 | Global CG coordinates everywhere; AppKit conversion only in `nsPoint(fromCG:)` and `nsScreen(forCG:)` | One flip in one place instead of y-axis bugs scattered across views | plans/…-plan-3b-app.md §Specific constraints |
| P3b-11 | The camera runs only while `AppConditions.wantsCamera` is true | The LED is off whenever Focus is paused, locked, uncalibrated or missing a permission | plans/…-plan-3b-app.md §Specific constraints |

## Plan 4 — Split panes (2026-09-30)
| # | Decision | Why | Source |
|---|---|---|---|
| P4-2 | A pane is the deepest focusable AX element ≥ 200×150 pt, clipped to every ancestor's frame | Electron wraps panes in window-sized focusable groups, and text areas are as tall as the document | plans/…-plan-4-panes.md §Review Focus, docs/spikes/ax-panes.md |
| P4-3 | AX is bounded: 0.25 s global messaging timeout, at most 3000 nodes per walk, small subtrees pruned | A hung app would otherwise freeze the main actor for the default 6 s | plans/…-plan-4-panes.md §Global Constraints |
| P4-4 | Pane lists are cached 2 s, an empty list only 1 s, after setting `AXManualAccessibility` | Electron builds its tree about a second after being asked | plans/…-plan-4-panes.md Task 5 |
| P4-5 | AX focus first, verified via `AXFocusedUIElement`; a synthetic centre click only if AX failed, the setting is on, the app is allowed, post access is already granted and the centre is clear | ; a click is the last resort and must never land on the wrong pane or window | plans/…-plan-4-panes.md §Global Constraints |
| P4-6 | Never call `CGRequestPostEventAccess()` | Would raise a TCC prompt (A-22); without the grant the click path is simply skipped | plans/…-plan-4-panes.md §Global Constraints |
| P4-7 | Synthetic events carry marker `0x464F4355` in `.eventSourceUserData`; `InputMonitor` ignores them | Our own click must not start the mouse pause or become a learned calibration point | plans/…-plan-4-panes.md §Global Constraints, reconciliation R10 |
| P4-8 | `PaneProvider` adds `element(of:pane:)`, `invalidate()` and `allows` to the architecture interface | The actuator needs the AX element, the fixture needs a cache reset, the bench needs a bundle-free allowlist | plans/…-plan-4-panes.md §Self-review, reconciliation R10 |

## Plan 5 — Setups and docs (2026-09-30)
| # | Decision | Why | Source |
|---|---|---|---|
| P5-1 | `SetupResolver` is a FocusCore `@MainActor` class; the app part is `SetupController` | Override, Wi-Fi drop and learned-point rules are fragile and must be unit-tested and benched headlessly | plans/2026-09-30-plan-5-setups-docs.md §Rulings 1 |
| P5-2 | `EnvironmentFingerprinter.current(displays:cameraID:)` instead of `current(cameraID:)` | A static function can't reach the app's `DisplayProvider` without a second reconfiguration callback | plans/…-plan-5-setups-docs.md §Rulings 2 |
| P5-3 | `Permissions.requestLocation()` and `Pane.location` are added | The SSID needs Location, which the architecture listed as status only | plans/…-plan-5-setups-docs.md §Rulings 3 |
| P5-4 | The SSID is polled every 15 s, not observed via `CWEventDelegate` | No delegate or queue hopping; screens and camera already give instant callbacks | plans/…-plan-5-setups-docs.md §Rulings 4 |
| P5-5 | A Wi-Fi drop is not an environment change; the last SSID is kept while screens and camera are unchanged | Wake and roaming lose Wi-Fi for a while and must not switch setups or cancel a manual pick | plans/…-plan-5-setups-docs.md §Rulings 5 |
| P5-6 | An ambiguous match does not pause: the current setup stays if it fits, else the first candidate; picking one records the SSID | Pausing for a tie punishes the common case; the recorded SSID breaks the tie next time | plans/…-plan-5-setups-docs.md §Rulings 6 |
| P5-7 | Picking a setup whose monitors match but whose geometry differs adopts the new geometry | A resolution or scaling change would otherwise need the same manual pick at every launch | plans/…-plan-5-setups-docs.md §Rulings 7 |
| P5-8 | No match pauses and posts "New place detected"; a new setup inherits calibrations of identical screens from the last setup with the same camera | Spec §7; with setups every screen-set change is a new place, and unchanged screens keep working | plans/…-plan-5-setups-docs.md §Rulings 8 |
| P5-9 | The delta (9 dots) wins over the architecture's "5 targets × 2 s" line | The architecture contradicts itself; the binding delta table decides (see A-1, P3a-4) | plans/…-plan-5-setups-docs.md §Rulings 9 |

## Hardening rulings found by benches and review (2026-09-30)

These came out of fix rounds and bench findings while merging plans 3a/3b/4, not from a plan's own text; each is a real behaviour change. Sources are the squashed PR that shipped it (`git log --oneline origin/dev`), the file and symbol that carries the ruling in a doc comment, and/or the wiki page that explains the rule — never the agents' local `progress.md` ledgers, which are not committed.

| # | Decision | Why | Source |
|---|---|---|---|
| H-1 | `CameraCapture.start()` is synchronous; `GazeTracker` holds one lifecycle lock across `start`/`stop`, and detached termination stops only its own generation | An async start racing a pause's stop could hang or leave the camera on; a stale start's `stop()` could otherwise kill a newer session | PR #15; `Sources/GazeKit/GazeTracker.swift`, `CameraCapture.swift` (lifecycle-lock doc comments); [Gaze-pipeline §Lifecycle](Gaze-pipeline.md) |
| H-2 | `InputMonitor`'s idle counters read `CGEventSourceStateID.hidSystemState` (hardware only); every synthetic event Focus posts uses a `.privateState` source | Keeps Focus's own clicks and warps from ever being counted as user activity, which would wrongly suppress the typing/mouse guards right after Focus acts | PR #26; `Sources/FocusMac/InputMonitor.swift` (class doc comment); [Permissions-and-privacy §Not needed: Input Monitoring](Permissions-and-privacy.md) |
| H-3 | Focus's synthetic pane click posts at `.cgSessionEventTap`, not `.cghidEventTap` | A HID-tap click was found to reset the real `.hidSystemState` idle counter even from a `.privateState` source; the session tap still delivers the click but leaves that counter untouched | PR #26; `Sources/FocusMac/FocusActuator.swift` (`postMarkedClick` doc comment); [Focusing-windows-and-panes §3](Focusing-windows-and-panes.md) |
| H-4 | Pane-click occluders ignore the Dock's always-on, click-through, full-display window, replacing it with the Dock's real strip (`NSScreen.frame` minus `visibleFrame`); a Dock window only qualifies at `kCGWindowLayer == 20` | Without the carve-out, the Dock's invisible full-screen layer blocked every pane click; matching by bounds alone would also have swallowed Launchpad and Mission Control | PR #26; `Sources/FocusMac/FocusActuator.swift` (`occluders`, `dockStrip` doc comments); [Focusing-windows-and-panes §Split panes](Focusing-windows-and-panes.md) |
| H-5 | The dead band around a narrow screen-to-screen gap widens continuously toward `2.5 × minScreenSeparation` around its midpoint, instead of falling back to raw centroid geometry below a floor | A hard floor only moved the ping-pong cliff to closer bezels; continuous widening keeps the switch boundary at the seam at any spacing | PR #26; `Sources/FocusCore/ScreenClassifier.swift` (`minGap`, `gapFraction` doc comment); [Decision-engine](Decision-engine.md) |
| H-7 | A calibration or learned-clicks save clears its dirty flag only after the write to disk succeeds; failures are logged only, with no status-bar slot | Clearing dirty before saving could silently lose learned calibration on a write error; a UI slot for a rare disk failure wasn't judged worth it for an internal tool | PR #23; `Sources/FocusApp/AppController.swift` (`saveLearned`, the calibration-completion `do`/`catch`) |
| H-8 | Closing the Setup Guide or Settings re-activates whatever app was frontmost before it opened | `NSApp.activate()` during onboarding/calibration/settings was never undone, so keyboard focus stayed on Focus after the window closed | PR #24; `Sources/FocusApp/OnboardingView.swift`, `SettingsView.swift` (`appBeforeOnboarding`/`appBeforeSettings`) |
| H-9 | The gaze-dot overlay is one moving 18×18 click-through panel shared across displays, not one panel per display | Same information on screen, fewer views to keep positioned and in sync | PR #24; `Sources/FocusApp/GazeDot.swift` |
| H-10 | The vision bench's "yaw follows head turn" check is `.skip`, not a loosened threshold, and is instead verified live by `scripts/morning-check.sh` | The check replays one still photo warped in 2-D, which cannot physically turn a head; the failure was in the check's premise, not the pipeline | PR #26; `Sources/FocusBench/VisionBench.swift` (`yawFollowsTurnCheck`) |

**Pending, not yet merged (no PR, no branch pushed):** a screen-junction fix, local branch `fix/laptop-below-close` (not on `origin`), changes off-screen classification from centroid distance to a 0.2 margin past the calibration dots' box measured on yaw/pitch only, changes re-entry to prefer the screen whose dot box contains the pose (centroid only as fallback), and measures the pair switch axis across the shared seam from the facing edge dots instead of centroid-to-centroid — bench found corner poses near a junction landing on the wrong screen, a chunk of a nearby laptop-below screen reading as "away", and a boundary tilted off the seam. Not reflected in `Sources/FocusCore/ScreenClassifier.swift` (still centroid-based) or `Settings.swift` (`offScreenDistance`, unrenamed) until it merges — check those files, not this note, for what ships.

## Setups app and bench follow-up (2026-09-30)

The Setup ▸ menu, the Places onboarding step and the pane/setups benches shipped in PR #31
(`feat/setups-app`) and PR #29 (`feat/bench-followup`), both squash-merged onto `dev`.

| # | Decision | Why | Source |
|---|---|---|---|
| SA-1 | The `setupSwitched` notice keeps only its latest instance instead of stacking; other setup notices (new place, drift) stay enabled even while a calibration can't start | A queue of stale "now using …" notices was confusing; only the notices that need a calibration should wait for one to be possible | PR #31 (`feat/setups-app`); `Sources/FocusApp/Notifier.swift` (`FocusNotice.id`), `StatusItemController.swift` |
| SA-2 | Setup ▸ modals (rename, delete, the Places onboarding step) hand keyboard focus back to whatever app was frontmost before they opened, same as the Setup Guide (H-8) | One consistent rule for every Focus window that borrows focus, instead of one-off exceptions per window | PR #31 (`feat/setups-app`); `Sources/FocusApp/SetupController.swift` (`runModal`) |
| BF-1 | Bench `P4.7`'s preparatory click is guarded against a covering window and `skip`s instead of failing when one is present; the pane-fixture is always terminated before the next live-AX group runs | Audit (PR #29, issue #30) found the prep click could land on whatever already covered the target and misreport the result; a leftover fixture process collided with the next group | PR #29 (`feat/bench-followup`); `Sources/FocusBench/PaneBench.swift` (`coveringWindow`) |

## Cross-plan reconciliation (2026-09-30)
| # | Decision | Why | Source |
|---|---|---|---|
| R-1 | `FocusSettings` holds engine and actuator behaviour only; app-only fields stay in `AppSettings` | Plans 3a and 3b both defined settings; one owner per field avoids two sources of truth | plans/2026-09-30-reconciliation.md R1 |
| R-2 | One pane-click field, `FocusSettings.syntheticClickFallback`; plan 4 adds no `clickToFocusPanes` | Two names for one toggle would drift apart | plans/2026-09-30-reconciliation.md R2 |
| R-3 | `FocusEngine` is owned by the `@MainActor` `AppController` and never marked `@unchecked Sendable` | Applies P3a-6 to the app and plan 5's resolver | plans/2026-09-30-reconciliation.md R3 |
| R-4 | `InputActivity.isQuiet` is removed; callers use `allowsScreenSwitch(at:_:)` and `allowsSameScreen(at:_:)` | Screens and panes now have different typing pauses (A-3) | plans/2026-09-30-reconciliation.md R4 |
| R-5 | `GazeTracker.process(pixelBuffer:time:)` is public and returns a no-face sample instead of nil | The vision bench feeds still images through it; applies P2-8 | plans/2026-09-30-reconciliation.md R5 |
| R-6 | 3a's `NotificationPolicy` is the only notification logic; the notified set lives in `AppSettings.notifiedDisplays` | Plan 3b assumed other names for the same logic | plans/2026-09-30-reconciliation.md R6 |
| R-7 | Plans 3b and 5 consume 3a's `EngineStatus` and `CalibrationLayout` as merged | 3a owns these types; consumers adapt, never duplicate | plans/2026-09-30-reconciliation.md R7 |
| R-8 | Calibration timing: 9 dots + shared edges, 0.6 s travel + 1.0 s hold | Confirms A-1/P3a-4/P5-9 against the already merged `CalibrationRun` | plans/2026-09-30-reconciliation.md R8 |
| R-9 | Plan 5 rulings P5-1 to P5-8 are accepted across plans | The other plans must call the resolver and fingerprinter as plan 5 defines them | plans/2026-09-30-reconciliation.md R9 |
| R-10 | Plan 4's `FocusActuator` adapts to 3a's merged init and plugs in through `paneFocuser` | Merged code wins over plan text; the hook avoids a second actuator init | plans/2026-09-30-reconciliation.md R10 |
