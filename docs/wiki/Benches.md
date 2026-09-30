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
| 3 | vision | GazeKit on fixture images (plan 3a Task 12) |
| 4 | live AX | windows, actuator, input monitor against a fixture app (Task 13); panes (plan 4) |
| 5 | app smoke | `scripts/build-app.sh` + `Focus --selftest` (plan 3b); skipped until that script exists |

### Group 2: engine scenarios

Each scenario builds a fresh `Sim` (seed 42) with default `FocusSettings` and the One-Euro smoother on,
then feeds 15 fps samples on a synthetic clock. Latency is measured from the end of the head turn to the
first action that lands on the target screen.

| check | desk | script | pass rule |
|---|---|---|---|
| `switch-latency/<desk>` | side-by-side, stacked, laptop-below | every ordered pair: look A 1.5 s, turn A→B 0.25 s, look B 1.5 s | every pair switched, p95 < 500 ms (spec success criterion) |
| `bezel/<desk>` | same three | every ordered pair sharing an edge: look A 1 s, stare at the edge midpoint 10 s | ≤ 1 switch |
| `bezel/<desk>@<d>pt` | side-by-side at 1300/1000 pt, laptop-below at 1500/1300/1000 pt (head distance) | same | ≤ 1 switch |
| `quick-glance` | side-by-side | L 1 s, R 0.2 s, L 1 s | 0 actions |
| `typing/screen` | side-by-side | L 1 s, keystroke, R 3 s | nothing before 1.0 s, first ≤ 1.6 s |
| `typing/pane` | single, two half windows | left 1 s, keystroke, right 5 s | nothing before 3.0 s, first `.window(right)` ≤ 3.6 s |
| `typing/off` | as above, `waitWhileTyping = false` | same | first ≤ 0.6 s |
| `mouse` | side-by-side | L 1 s, then R 5 s with the mouse moving every frame | 0 actions |
| `off-screen` | side-by-side | L 1 s, head down (pitch −0.7, a phone) 3 s, L 1 s | 0 actions, ≥ 90 % of off-screen frames `.lookingAway` |
| `no-face` | side-by-side | L 1 s, R 0.2 s, no face 1 s, R 1 s | nothing without a face, first ≥ 300 ms after it returns |
| `latch` | side-by-side, windows only on L | L 1 s, R 3 s | exactly one `.display(R)` |
| `window-accuracy` | single, two half windows | 100 seeded fixations ≥ 10 % of the width from the split, 1 s each | accuracy ≥ 0.90 (live target 0.80, spec §1) |
| `learning` | single | gaze bias (0.06, −0.04); 60 clicks | mean map error over 30 probes halves |
| `recalibration-trigger` | single | bias (0.3, 0.3), clicks until flagged; control without bias, 60 clicks | flagged within 15 clicks; control never |

A failing row is a finding, not a bench bug: keep the rule, record the numbers, fix the engine (or tune a
knob with the numbers) test-first. Example (issue #17, 2026-09-30): staring at the seam flipped focus
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
time:)` (public since Task 6) 5 times, on a **fresh `GazeTracker` per case** — the landmarker tracks
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

**Why `yaw-follows-turn` is a skip (controller ruling, 2026-09-30).** A 2-D `CIPerspectiveTransform`
skew of a flat photo isn't a real head turn: it distorts overall shape without the depth cues a real
turn gives, so FaceMesh/HeadPoseSolver's yaw stays at noise level (≈0.01–0.03 rad). Measured yaws at
fractions [0.2, 0.1, 0, −0.1, −0.2]: [−0.027, −0.022, 0.013, −0.012, −0.025] rad. That says the
approximation doesn't hold, not that the pipeline's sign convention is wrong, so the row reports the
numbers as a skip and the sign check is done live with a real head.

### Group 4: live AX (`LiveAXBench.swift`, `focus-fixture`)

FocusMac against the real window server, the real Accessibility API and real (synthetic) input. The
target is `focus-fixture` (`Sources/FocusFixture`), a small app built next to `focus-bench`: two
640×420 windows 120 pt below the top of the primary screen (x = 100 and x = 800); the second holds a
vertical `NSSplitView` of two text views (plan 4's panes). Once on screen it prints one JSON line —
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
| `synthetic-click-ignored` | window 2, left pane focused by AX; post down/up at the right pane's centre exactly as `FocusActuator.focusPane` does: `.privateState` source, marker `0x464F4355` (R10), `.cgSessionEventTap` | right pane focused (`PaneProvider.focusedPaneIndex`: the text view got the click), HID `leftMouseDown` idle counter not reset, `InputMonitor.onClick` not called |
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
  layer 20 spanning the whole display with alpha 1, always on screen. R11's rule counted it, so
  `PaneClick` found no safe point and the pane click fallback never fired; this guard skipped its four
  posting rows ("Dock layer 20"). `FocusActuator.occluders` now drops that window and counts the Dock's
  strip instead (`dockStrip`: `NSScreen.frame` minus `visibleFrame`'s Dock side). Only that window: its
  bounds equal a display frame **and** its layer is 20; Launchpad/Mission Control, which also have the
  size of a screen, sit at a different layer and remain obstacles (audit #27). Stack popups and Dock
  menus stay ordinary occluders.

### Group 5: app smoke (plan 3b)

Placeholder: `scripts/build-app.sh` + `Focus.app --selftest`; `skip` until plan 3b adds the script.

## Adding a check

A check is a function returning `BenchResult` (`Sources/FocusBench/Report.swift`):

```swift
.check("2 engine", "my-scenario", ok, rule: "p95 < 500 ms", metrics: ["p95_ms": p95], reason: "shown when it fails")
.skip("4 live AX", "window raise", "Accessibility not granted")
BenchResult(group: 5, name: "--selftest exits 0", passed: ok, detail: "…")   // numbered groups
BenchResult.skipped(group: 5, name: "…", reason: "…")
```

Metrics must be finite (JSON has no NaN; use −1 for "never"). `.check` drops `reason` on a pass (it
explains a failure); `init(group:name:passed:detail:)` keeps `detail` on a pass too (plan 3b's rows carry
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
| `scripts/build-app.sh` not there yet | lands with plan 3b |

## The human part

What a bench cannot see (a real face, a real camera, the app's onboarding) is `scripts/morning-check.sh`:
a guided session run by hand, the only script allowed to show permission dialogs. It runs
`focus-gaze cameras`, `focus-gaze probe 10` (~15 samples/s, conf ≥ 0.5, lag 0-150 ms, yaw changes sign on a
head turn, "no face" under a hand), `focus-gaze screens` with ≥ 2 displays, then builds and opens
`build/Focus.app` for the onboarding once plan 3b provides `scripts/build-app.sh`. Answers go to
`build/bench/morning.md`; then the manual list in `TESTING.md`.

See also: [Decision engine](Decision-engine.md) (what group 2 exercises) ·
[Focusing windows and panes](Focusing-windows-and-panes.md) (what group 4 exercises).
