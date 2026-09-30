# Benches

Unattended checks that prove the engine, the gaze pipeline and the macOS glue behave, with numbers.
Everything lives in `Sources/FocusBench` (executable `focus-bench`) and `scripts/bench.sh`.

## Running

```bash
scripts/bench.sh            # ~30 s on an M-series Mac; exit code = number of failed checks
open build/bench/report.md  # the report; raw results in build/bench/{engine,vision,ax}.json, unit.log, lint.txt
```

One group on its own (release: vision timings are only meaningful there):

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build -c release --product focus-bench
.build/release/focus-bench engine --json /tmp/engine.json   # prints one line per check; exit = failures
```

`focus-bench <group> [--json FILE] [--fixtures DIR]` runs a group; `focus-bench report …` merges the JSON
files, the unit-test log and the lint output into `report.md` (bench.sh passes the arguments).

## CI

`.github/workflows/ci.yml` runs on every pull request and on pushes to `dev`, `staging` and `prod`
(macOS runner, newest Xcode): the no-prompt lint, `swift build`, `swift test`, the engine group and
the app bundle. The vision group runs too but cannot fail the build: its timing targets assume Apple
silicon with the Neural Engine, and hosted runners are virtual machines. The live AX group (4) and the
app self-test need Accessibility and a real desktop, so they stay in `scripts/bench.sh` on a Mac.
The `test` job is a required check on `dev`, `staging` and `prod`.

## The no-prompt rule

The bench runs unattended (overnight, over SSH, in CI). It must never raise a TCC dialog: no camera,
Accessibility, notification or location *request*. A check that needs a permission reads its status and
reports `skip` with the reason. Group 0 enforces this with a grep over `Sources/FocusBench`,
`Sources/FocusFixture` and `Tests` (not the app: onboarding legitimately requests) for

```
[Rr]equest[A-Za-z]*(Access|Authoriz|Permission)|CGRequest[A-Za-z]+|requestCamera|requestLocation|promptAccessibility|AXIsProcessTrustedWithOptions|kAXTrustedCheckOptionPrompt
```

i.e. `AVCaptureDevice.requestAccess`, `CGRequestListenEventAccess` / `CGRequestPostEventAccess`,
`UNUserNotificationCenter.requestAuthorization`, the location `requestWhenInUse` / `requestAlways` /
`requestTemporaryFullAccuracyAuthorization` calls, FocusMac's `Permissions.requestCamera` /
`promptAccessibility` / `requestLocation`, and the Accessibility prompt option. Any hit fails the run,
and so does a missing `lint.txt` ("lint not run").

## Groups

| # | group | what it proves |
|---|---|---|
| 0 | no-prompt lint | nothing unattended can prompt |
| 1 | unit | `swift test` exits 0 (the report lists the test count per bundle) |
| 2 | engine | the real `FocusEngine` makes the right decisions at the right time on synthetic desks |
| 3 | vision | GazeKit on fixture images |
| 4 | live AX | windows, actuator, input monitor against a fixture app; panes |
| 5 | app smoke | `scripts/build-app.sh` + `Focus --selftest`; skipped if that script is missing |

### Group 2: engine scenarios

Each scenario builds a fresh `Sim` (seed 42) with default `FocusSettings` and the One-Euro smoother on,
then feeds 15 fps samples on a synthetic clock. Latency is measured from the end of the head turn to the
first action that lands on the target screen.

| check | desk | script | pass rule |
|---|---|---|---|
| `switch-latency/<desk>` | side-by-side, stacked, laptop-below | every ordered pair: look A 1.5 s, turn A→B 0.25 s, look B 1.5 s | every pair switched, p95 < 500 ms (success criterion) |
| `bezel/<desk>` | same three | every ordered pair sharing an edge: look A 1 s, stare at the edge midpoint 10 s | ≤ 1 switch |
| `bezel/<desk>@<d>pt` | side-by-side at 1300/1000 pt, laptop-below at 1500/1300/1000 pt (head distance) | same | ≤ 1 switch |
| `quick-look` | side-by-side | L 1 s, R 0.2 s, L 1 s | 0 actions |
| `typing/screen` | side-by-side | L 1 s, keystroke, R 3 s | nothing before 1.0 s, first ≤ 1.6 s |
| `typing/pane` | single, two half windows | left 1 s, keystroke, right 5 s | nothing before 3.0 s, first `.window(right)` ≤ 3.6 s |
| `typing/off` | as above, `waitWhileTyping = false` | same | first ≤ 0.6 s |
| `mouse` | side-by-side | L 1 s, then R 5 s with the mouse moving every frame | 0 actions |
| `off-screen` | side-by-side | L 1 s, head down (pitch −0.7, a phone) 3 s, L 1 s | 0 actions, ≥ 90 % of off-screen frames `.lookingAway` |
| `off-screen/<desk>-<where>@<d>pt` | laptop-below phone (20° below M) and lap (40°), side-by-side left/right (20° past the outer edge), stacked above (20° over T); 1800/1300/900 pt | nearest screen 1 s, away pose 3 s, back 1 s | 0 actions after the first look, ≥ 90 % `.lookingAway` |
| `on-screen/<desk>` | side-by-side, stacked, laptop-below, single; 700/900/1300/1800/2400 pt | 11 × 11 points over each screen (1-99 %), 0.4 s each | no point `.lookingAway` |
| `screen-choice/<desk>` | same | same points, each reached from its own screen's centre (0.4 s) | every point `.facing` its own screen; laptop-below ≤ 3 % wrong (known limit, [Decision-engine](Decision-engine.md), Screen boundary) |
| `on-screen-lean/<desk>` | same four desks; 900/1800 pt | centre and 5 % inside each edge, 0.4 s, then 0.6 s with the face shifted ±0.1/±0.2 (x) or ±0.1 (y) | never `.lookingAway` |
| `switch-latency/laptop-below@<d>pt` | laptop-below at 900/700 pt | as `switch-latency` | as `switch-latency` |
| `no-face` | side-by-side | L 1 s, R 0.2 s, no face 1 s, R 1 s | nothing without a face, first ≥ 300 ms after it returns |
| `latch` | side-by-side, windows only on L | L 1 s, R 3 s | exactly one `.display(R)` |
| `window-accuracy` | single, two half windows | 100 seeded fixations ≥ 10 % of the width from the split, 1 s each | accuracy ≥ 0.90 (live target 0.80) |
| `learning` | single | gaze bias (0.06, −0.04); 60 clicks | mean map error over 30 probes halves |
| `recalibration-trigger` | single | bias (0.3, 0.3), clicks until flagged; control without bias, 60 clicks | flagged within 15 clicks; control never |
| `setups-two-places` (`SetupScenarios.swift`) | — | built-in + Dell at home (SSID "Home"), built-in + LG at the office (no SSID): `SetupResolver.resolve` at each place, a head turn each way, a click learned at home | right screen focused at each place; the click learned at home survives the trip to the office and back; worst switch < 500 ms |
| `setups-fingerprint` (`SetupScenarios.swift`) | — | `EnvironmentFingerprinter.current(displays: DisplayProvider().fingerprints, cameraID:)` against `CGGetActiveDisplayList` | screens fingerprinted == active screens; camera ID passed through; **`skip`** ("Location not granted…") instead of a check when `Permissions.location != .granted` — reading the Wi-Fi name needs a grant this bench never requests |

A failing row is a finding, not a bench bug: keep the rule, record the numbers, fix the engine (or tune a
knob with the numbers) test-first. Example (2026-09-30): staring at the seam flipped focus
5 (side-by-side) and 4 (laptop-below) times. A floor that fell back to centroid geometry below
`minScreenSeparation` fixed the default 1800 pt head distance but left the cliff at 1000-1300 pt
(side-by-side) and 1400-1700 pt (laptop-below), 2-3 flips each. `ScreenClassifier.gapFraction` now widens
any facing-edge gap narrower than `ScreenClassifier.minGap` (2.5 × `minScreenSeparation`) around its
midpoint; the `bezel/…@<distance>pt` rows pin the closer heads. Sweep 800-2400 pt: ≤ 1 flip everywhere.

### The synthetic desk (`Desk.swift`)

- The head sits 1800 pt in front of the centre of the displays' bounding box.
- The head covers 65 % of the gaze angle, the eyes the rest (60-70 % for large gaze shifts, Freedman 2008):
  that is why the screen is chosen from head pose, and the point on it from the calibrated gaze.
- Noise: pose σ 0.01 rad (≈ 0.6°, the focus-gaze probe at rest), raw gaze σ 0.03 BlazeGaze units.
- Calibration goes through the real `CalibrationLayout` + `CalibrationBuilder` (10 samples per dot).
- Layouts: `single` (1512×982), `sideBySide` (2 × 1920×1080), `stacked` (1920×1080 above 1920×1080),
  `laptopBelow` (2 × 2560×1440 with a 1536×960 laptop centred below their seam).
- RNG: SplitMix64, seed 42 per `Sim`; runs are bit-for-bit reproducible (displays are calibrated in array
  order, never dictionary order).
- `Sim.apply` plays a working actuator: `.window` focuses it, `.display` focuses the window
  `TargetResolver.windowToRestore` picks, `.pane` changes nothing.

### Group 3: vision (`GazeKit` on `portrait.jpg`)

The camera is never opened here — no Camera TCC prompt, ever. `--fixtures` points at a still photo
(`Tests/GazeKitTests/Fixtures/portrait.jpg`, 820×1024); CoreImage transforms (shift, scale, rotate,
a `CIPerspectiveTransform` skew) stand in for the head motion a real video would show. Each case
composites the (possibly transformed) photo over a mid-grey 1280×720 canvas, renders it into a
fresh `CVPixelBuffer` with one shared `CIContext`, and hands it to `GazeTracker.process(pixelBuffer:
time:)` 5 times, on a **fresh `GazeTracker` per case** — the landmarker tracks
state across frames, so reusing one tracker would let an earlier case's face bleed into the next.

| check | transform | pass rule |
|---|---|---|
| `frontal` | none | confidence ≥ 0.5, raw finite, \|yaw\| < 0.3, \|pitch\| < 0.4 |
| `shift` | translate x by −160, 0, +160 px | found in all three, `faceX` strictly increasing, \|Δyaw\| < 0.1 vs frontal |
| `scale` | scale 0.8× and 1.2× about the centre | found, \|Δyaw\| < 0.1, \|Δpitch\| < 0.1 vs frontal |
| `roll` | rotate ±10° about the centre | found, \|Δyaw\| < 0.15 vs frontal |
| `yaw-follows-turn` | `CIPerspectiveTransform`: shrink the right edge 20 %/10 %/0 %, then the left edge 10 %/20 % | **always skipped**, measured yaws kept in the row: a still photo warped in 2-D cannot turn a head. Checked live: TESTING.md "focus-gaze probe" (turn left/right → `yaw` changes sign) and `scripts/morning-check.sh` |
| `no-face` | a black frame; a frame of seeded uniform noise (`SplitMix64`, not `CIRandomGenerator`: the latter's output isn't a documented, reproducible seed) | both confidence == 0, raw NaN |
| `ms-per-frame` | none — one tracker, 5 warm-up + 60 timed `process` calls | median_ms < 20 (architecture target; the 15 fps camera gives a frame every 67 ms). Skipped in a debug build: unoptimized CoreML/Accelerate isn't representative |

A `GazeTracker()` init failure (e.g. the CoreML models aren't fetched — `scripts/fetch-models.sh`)
fails every check in the group with the same reason, rather than crashing the bench.

**Why `yaw-follows-turn` is a skip.** A 2-D `CIPerspectiveTransform`
skew of a flat photo isn't a real head turn: it distorts overall shape without the depth cues a real
turn gives, so FaceMesh/HeadPoseSolver's yaw stays at noise level (≈0.01–0.03 rad). Measured yaws at
fractions [0.2, 0.1, 0, −0.1, −0.2]: [−0.027, −0.022, 0.013, −0.012, −0.025] rad. That says the
approximation doesn't hold, not that the pipeline's sign convention is wrong, so the row reports the
numbers as a skip and the sign check is done live with a real head.

### Group 4: live AX (`LiveAXBench.swift`, `focus-fixture`)

FocusMac against the real window server, the real Accessibility API and real (synthetic) input. The
target is `focus-fixture` (`Sources/FocusFixture`), a small app built next to `focus-bench`: two
640×420 windows 120 pt below the top of the primary screen (x = 100 and x = 800); the second holds a
vertical `NSSplitView` of two text views (the pane rows use it). Once on screen it prints one JSON line —
`pid`, window ids and CG frames, plus `selfOnScreen` (its own windows in CGWindowList) and
`selfListed` (what a `WindowProvider` *inside the fixture* lists of them) — and quits on its own after
`--quit-after` seconds (the bench passes 60), so it never lingers even if the bench dies.

**Preconditions** (each turns every row of the group into the same result): screen locked → `skip`
"screen locked"; `Permissions.accessibility != .granted` → `skip` (grant it to the terminal);
`focus-fixture` missing next to the bench binary → `fail` "focus-fixture not built"; no JSON line within
10 s → `fail`. The four rows that post events also need `Permissions.eventPosting` (else `skip`). Nothing
ever prompts: status reads only.

**Checks, in order.** Input-sensitive checks run before any synthetic event, so the bench's own events
can't make "is the user active?" true.

| check | how | pass rule |
|---|---|---|
| `display-provider` | `DisplayProvider().displays` | ≥ 1, unique keys, non-empty frames |
| `window-provider` | poll `WindowProvider.windows()` ≤ 2 s | both fixture ids listed, frames within 2 pt |
| `own-app-exclusion` | fixture JSON | listed from focus-bench (above), while the fixture's own `WindowProvider` lists 0 of its ≥ 2 on-screen windows |
| `world-build-latency` | 30 × `World(displays:windows:focusedWindowID:)` on the main thread; also AX `focusedWindowID()` alone | p95 < 33 ms (half a 15 fps frame) |
| `focus-window-1/2` | `FocusActuator.perform(.window(id))`, poll `focusedWindowID()` every 50 ms | `perform` true and focused ≤ 1 s |
| `display-restores-last-window` | focus window 2; one virtual display = the main screen, `noteFocusChange(w1)`; `perform(.display)` | window 1 focused ≤ 1 s |
| `e2e-scripted-gaze` | wait for quiet input (3 s no key, 1.5 s no mouse; ≤ 10 s else `skip` "user active"); identity 5-point calibration, pose 0; `ScriptedGazeSource` replays 2 s at 15 fps at window 2's centre → `FocusEngine.decide` → `FocusActuator.perform`; then towards window 1 | each focused ≤ 1.5 s from the trace start |
| `cursor-warp` | main screen split into two virtual displays between the windows, focus = window 2; `perform(.window(w1))` crosses displays | pointer inside window 1 |
| `warp-is-not-mouse-activity` | `InputActivity.lastMouse` before/after two warps | unchanged ± 1 ms |
| `synthetic-click-ignored` | window 2, left pane focused by AX; post down/up at the right pane's centre exactly as `FocusActuator.focusPane` does: `.privateState` source, marker `0x464F4355`, `.cgSessionEventTap` | right pane focused (`PaneProvider.focusedPaneIndex`: the text view got the click), HID `leftMouseDown` idle counter not reset, `InputMonitor.onClick` not called |
| `input-sees-key` | post F18 down/up | `lastKey` ≤ 0.5 s |
| `input-sees-click` | post an unmarked click at window 1's centre | `onClick` ≤ 0.5 s at ≤ 2 pt, `lastMouse` updated |
| `hotkey` | `HotKey(⌃⌥⌘F19)`, post F19 with those flags **and `.maskSecondaryFn`** | action ≤ 0.5 s; `HotKey` nil → `fail` "combination taken" |

"Focused" means the AX focused window of the AX focused application (`WindowProvider.focusedWindowID()`,
system-wide element), not `NSWorkspace.frontmostApplication` (only updated while notifications pump).

**Safety and cleanup.** Every synthetic event targets a fixture window, and it is posted only if a fixture
window holds focus, is the topmost layer-0 window at that point, and no window of any layer above it
covers the point under `FocusActuator.occluders` (the pane click's own rule: other pids, alpha > 0, the
Dock by its strip only).
Otherwise the row is `skip`, naming the covering window, and nothing is posted. This matters: if the fixture dies, clicks at its coordinates land in whatever app is underneath.
A `defer` always terminates the fixture, re-activates the app that was frontmost, and warps the pointer
back to where it was. The group takes ~8 s.

**Pane rows (`PaneBench.swift`, `paneBenches()`).** Appended after the rows above,
regardless of which branch produced them (locked screen, no Accessibility, fixture missing — every path
still yields all 8 rows, `skip`ped the same way). Each row group launches its own `focus-fixture`, with
the flags listed below, and terminates it before the next group:

| row | fixture flags | how | pass rule |
|---|---|---|---|
| `P4.1 panes found` | — | `PaneProvider.panes(of:)` on the split window | 2 disjoint panes, left before right, each ≥ 200×150 |
| `P4.2 walk time` | — | `invalidate()`, then two more calls | first (fresh AX walk) < 50 ms; second (cached) < 1 ms |
| `P4.3 AX path` | — | `FocusActuator.perform(.pane)` on pane 0, then pane 1 — never a click, to keep the starting state clean | each `perform` true; `pane-focused <i>` within 0.5 s; `focusedPaneIndex == i`; no `pane-clicked` |
| `P4.4 click path` | `--refuse-ax-focus` | `perform(.pane)` on pane 1, `moveCursor = false`, `InputMonitor` counting clicks | `perform` true; `pane-clicked 1` & `pane-focused 1` within 0.5 s; pointer restored ≤ 1 pt; `onClick` 0; `lastMouse` unchanged |
| `P4.5 click moves pointer` | `--refuse-ax-focus` | same, `moveCursor = true`, on pane 0 | `perform` true; pointer inside pane 0 right after (then restored) |
| `P4.6 click disabled` | `--refuse-ax-focus` | `syntheticClickFallback = false`, target whichever pane isn't already focused (an AX request on an already-focused pane would trivially succeed and skip the setting entirely) | `perform` false; no `pane-clicked` within 0.3 s |
| `P4.7 covered pane` | `--refuse-ax-focus` | the fixture's other window moved (AX `kAXPositionAttribute`) and raised over pane 1's centre; same not-already-focused guard as P4.6 | `perform` false; no `pane-clicked` within 0.3 s |
| `P4.8 late tree` | `--late-ax` | `panes(of:)` right after launch, then again after 1.2 s | empty at first; 2 panes after 1.2 s (`PaneProvider`'s empty-tree 1 s retry) |

P4.4/P4.5 `skip` instead of `fail` when something other than the fixture already covers the click point
(a system notification banner, a stray popup) — the same class of real-desktop flakiness `fixtureOnTop`
above already guards against, not a product defect.

**Findings it caught (2026-09-30).**
- *Fixture killed by its own timeout.* `try? await Task.sleep` returns at once when the task is
  cancelled, so "cancel the 10 s timeout" ran its `terminate()`: focus went back to the terminal ~100 ms
  after each AX focus, and the clicks landed in the terminal. The timeout now returns if the sleep throws.
- *F-keys need the fn flag.* Carbon matched no synthetic F19 until `.maskSecondaryFn` was set, as on real
  F-key events (⌃⌥⌘K matched without it).
- *`.privateState` does not hide a click from the HID idle counters (fixed).* A click posted at
  `.cghidEventTap` reset `secondsSinceLastEventType(.hidSystemState, .leftMouseDown)` whatever the source
  state (97.9 s → 0.16 s), so the pane click fallback reset the mouse-quiet window it relies on.
  `FocusActuator.focusPane` now posts at `.cgSessionEventTap`: the click still reaches the text view
  (pane focused) and the counter keeps running (261.08 → 261.24 s).
- *The Dock covered every screen for the occluder rule (fixed).* The Dock owns a click-through window at
  layer 20 spanning the whole display with alpha 1, always on screen. The occluder rule counted it, so
  `PaneClick` found no safe point and the pane click fallback never fired; this guard skipped its four
  posting rows ("Dock layer 20"). `FocusActuator.occluders` now drops that window and counts the Dock's
  strip instead (`dockStrip`: `NSScreen.frame` minus `visibleFrame`'s Dock side). Only that window: its
  bounds equal a display frame **and** its layer is 20; Launchpad/Mission Control, which also have the
  size of a screen, sit at a different layer and remain obstacles. Stack popups and Dock
  menus stay ordinary occluders.

### Group 5: app smoke

`scripts/build-app.sh` + `Focus.app --selftest`; `skip` if the script is missing.

## Adding a check

A check is a function returning `BenchResult` (`Sources/FocusBench/Report.swift`):

```swift
.check("2 engine", "my-scenario", ok, rule: "p95 < 500 ms", metrics: ["p95_ms": p95], reason: "shown when it fails")
.skip("4 live AX", "window raise", "Accessibility not granted")
BenchResult(group: 5, name: "--selftest exits 0", passed: ok, detail: "…")   // numbered groups
BenchResult.skipped(group: 5, name: "…", reason: "…")
```

Metrics must be finite (JSON has no NaN; use −1 for "never"). `.check` drops `reason` on a pass (it
explains a failure); `init(group:name:passed:detail:)` keeps `detail` on a pass too (group 5's rows carry
the measured value there). Group labels come from `BenchResult.groupNames`.

- **New engine scenario**: add one row to `EngineBench.scenarios` (`("name", { [myScenario()] })`).
- **New group**: add one row to `groups` in `main.swift` (`"name": (appKit, { … })`, `appKit: true` when
  it needs an AppKit event loop), one `"$B" name --json "$OUT/name.json"` line in `scripts/bench.sh`, and
  pass that JSON to `report`.

## Skips and how to un-skip them

| skip reason | grant |
|---|---|
| Accessibility not granted | System Settings → Privacy & Security → Accessibility → the terminal running the bench |
| event posting not granted | same pane (posting is granted with Accessibility in practice) |
| screen locked | unlock; group 4 needs a live session |
| user active (`e2e-scripted-gaze`) | hands off keyboard and mouse while the bench runs |
| `ms-per-frame` skipped (debug build) | `swift build -c release` / `scripts/bench.sh` (group 3 never needs the camera — it only reads `portrait.jpg`) |
| `scripts/build-app.sh` not found | restore the script from the repo |

## The human part

What a bench cannot see (a real face, a real camera, the app's onboarding) is `scripts/morning-check.sh`:
a guided session run by hand, the only script allowed to show permission dialogs. It runs
`focus-gaze cameras`, `focus-gaze probe 10` (~15 samples/s, conf ≥ 0.5, lag 0-150 ms, yaw changes sign on a
head turn, "no face" under a hand), `focus-gaze screens` with ≥ 2 displays, then builds and opens
`build/Focus.app` for the onboarding. Answers go to
`build/bench/morning.md`; then the manual list in `TESTING.md`.

See also: [Decision engine](Decision-engine.md) (what group 2 exercises) ·
[Focusing windows and panes](Focusing-windows-and-panes.md) (what group 4 exercises).

## Results — 2026-09-30

`scripts/bench.sh` on macOS 27.0 (Build 26A428): **83 pass · 0 fail · 2 skip**. Full report:
`build/bench/report.md` (raw JSON per group alongside it).

| Bench | Result | Key numbers | Skipped because |
|---|---|---|---|
| 0 No-prompt lint | PASS | no permission-request match | — |
| 1 Unit | PASS | `swift test` exit 0 — 12 tests (FocusMacTests) + 17 (GazeKitTests) + 160 (FocusCoreTests), 3 bundles | — |
| 2 Engine scenarios | PASS (53/54; 1 skip) | switch-latency p50 267 ms / p95 267-333 ms (laptop-below); bezel ≤ 1 switch everywhere; window-accuracy 1.0; learning error 0.071 → 0.018 (75 % drop, target ≤ 50 %); recalibration-trigger flagged at 10 clicks; `screen-choice/laptop-below` 39/1815 wrong (2.1 %, known limit ≤ 3 %); `setups-two-places` right screen both places, learned click kept, worst switch 400 ms | `setups-fingerprint`: Location not granted (Wi-Fi name unavailable without a prompt) |
| 3 Vision | PASS (6/7; 1 skip) | `ms-per-frame` median 6.1 ms / p95 6.8 ms (release, target < 20 ms); frontal/shift/scale/roll/no-face all pass | `yaw-follows-turn`: always-skip by design (a still photo can't turn a head; checked live by `scripts/morning-check.sh`) |
| 4 Live AX | PASS | `world-build-latency` p95 2.55 ms (target < 33 ms); both `focus-window-*` and `display-restores-last-window` ≤ 12 ms; `e2e-scripted-gaze` 345/481 ms both ways (target ≤ 1.5 s); all 8 pane rows (P4.1-P4.8) pass, including the click fallback and the late-AX-tree retry | — |
| 5 App smoke | PASS | `scripts/build-app.sh` + `Focus --selftest` exit 0 | — |

Both skips are expected, not incidental: `setups-fingerprint` needs a Location grant this bench never
requests (see "The no-prompt rule" above); `yaw-follows-turn` is `.skip` by design (H-10,
[Decisions](Decisions.md)). No failures, no findings this run.
