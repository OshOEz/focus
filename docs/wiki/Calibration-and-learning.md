# Calibration and learning

Everything in `Sources/FocusCore` that builds and maintains a `DisplayCalibration`. The AppKit
window that draws dots and the AVFoundation capture that feeds it are the app's; this page is the
engine side only — what runs the session, what it stores, and how the map improves afterward.

## Dot layout

`CalibrationLayout.targets(for:)` produces, per display key, the dots to show in display-local
[0,1] coordinates (y down):

- **9-dot grid**: every combination of x ∈ {10%, 50%, 90%} and y ∈ {12%, 50%, 88%}, row by row
  (`gridY` outer, `gridX` inner) — "3×3 grid".
- **Shared-edge dots**: for every *other* display whose frame touches this one (within 2 pt, to
  absorb rounding), 3 more dots at 25/50/75% along the touching span, sitting 3% inside the shared
  edge (`edgeNear`/`edgeFar`). A display can pick up edge dots from more than one neighbour (a
  laptop screen below two external monitors gets dots facing both of them).

Numbers: 9 dots on an untouched display, 12 with one shared edge, 15 with two — `CalibrationLayoutTests.swift`
asserts these counts directly for a single screen, a side-by-side pair, and a laptop-below-two-monitors
arrangement.

Timing (`CalibrationRun`, `Sources/FocusCore/CalibrationRun.swift`, merged with plan 3b): each dot
travels for `travel` = 0.6 s (eased in/out, smoothstep) then holds for `hold` = 1.0 s; only samples
captured during the hold are collected. 9 dots ≈ 15 s, 12–15 dots (with edge dots) ≈ 20 s per

## What is stored per display

`DisplayCalibration` (`Sources/FocusCore/Calibration.swift`):

| Field | What | Cap |
|---|---|---|
| `pose` | Median head pose across every calibration dot — the screen's centroid for `ScreenClassifier` | — |
| `dotPoses` | Median pose *per dot* — the "cloud" whose facing edge places the screen boundary (§ Decision-engine.md) | one per dot |
| `calibrationPoints` | (observed gaze → true point) pairs from the session, feeds the RBF map | — |
| `learnedPoints` | Same pairs, added later from clicks | 200 (`maxLearned`) |
| `recentErrors` | Map error at the moment each learned point was added, oldest dropped first | 30 (`errorWindow`) |

## RBF map

`RBFMap` (`Sources/FocusCore/RBFMap.swift`) fits a Gaussian radial basis function on the
**residual** (target − input) rather than the target directly, so a raw gaze point far from any
calibration data maps to itself unchanged instead of extrapolating wildly. Same kernel, same ridge
(0.01) as MacGaze's `RBFGazeCorrector` (MIT-licensed reference this app's calibration model
descends from). `sigma` is the mean pairwise distance between calibration inputs — it scales the
kernel to how spread out the session's own points were, so a tightly clustered calibration doesn't
get an oversized falloff radius. The linear solve (`LinearSolver.swift`) needs at least 3 points;
fewer, or a solve that produces a non-finite weight, and `RBFMap.init?` returns `nil`.

## Errors during calibration

- **"No face"** (`CalibrationRun.Failure.noFace`): `CalibrationBuilder.build` returned `nil` for a
  screen — too few good samples (`minSamplesPerTarget` = 5 per dot, or fewer than 3 dots survived)
  or no finite median pose. Space retries the same screen.
- **"Screens looked the same"** (`CalibrationRun.Failure.screensLookedSame`): the screen just
  calibrated has a pose within `minScreenSeparation` of another screen already calibrated in this
  run or already on file (`others`). `CalibrationRun` uses 0.08 rad during a *live* session (a
  stricter, "give the user a chance to sit up straighter" number); `CalibrationBuilder.indistinguishable`
  uses 0.05 as the equivalent **after-the-fact** check across a whole setup's saved calibrations —
  the number `NotificationPolicy`-adjacent code and Settings-window diagnostics use to flag two
  displays that can't be told apart. Space on `.screensLookedSame` discards every result in the run
  and restarts from screen 0 (recalibrating one screen without the others would leave a stale
  centroid that's no longer separated from the new one).

## Learning from clicks

`FocusEngine.recordClick(at:time:world:)`: a click only teaches the model if the gaze was **steady**
just before it — at least 3 samples in the last `screenDwell` seconds, all classified onto the
clicked display. That's the same window the screen-switch dwell uses, on the theory that a steady
gaze for that long is itself evidence the head wasn't mid-turn. Steady samples' raw gaze points are
combined by median (robust to one late sample from a fast final movement) and paired with the click
position (display-local) as a new `CalibrationPoint`.

`FocusSettings.learnFromClicks` (default true) turns this off entirely — `recordClick` returns
`false` immediately when it's off, so no calibration is mutated, no error is recorded, and drift can
never be detected on a display where learning is off ("adapts... turn it off in Settings
anytime").

Recalibrating a display (`FocusEngine.setCalibration`) throws away everything learned:
`learnedPoints` and `recentErrors` are reset before the new calibration is loaded — the map goes
back to only the original session's points, and any accumulated drift-detection history for that
display is gone too.

## Drift

Each learned point's error is measured **before** it's learned (`DisplayCalibration.learn`): the
current map is asked to place the observed gaze, and the distance from that answer to the actual
click position becomes one entry in `recentErrors` (capped at the last 30). `needsRecalibration` is
true once there are at least 10 entries and their mean exceeds 15% of the unit-square diagonal
(`errorThreshold = 0.15 * √2`) — "if focus starts missing on a screen, it tells you it's
time to recalibrate", modeled as accumulated click error rather than a specific miss-count, since
FocusCore has no visibility into what the user *meant* to click.

`NotificationPolicy.drifted(_:notified:)` (`Sources/FocusCore/NotificationPolicy.swift`) turns the
calibrations with `needsRecalibration == true` into the display keys to notify about, minus
whichever are already in the caller's `notified` set — so the same drifted display isn't announced
every frame. The caller clears a display's "notified" flag when it's recalibrated (a fresh
`DisplayCalibration` starts with empty `recentErrors`, so `needsRecalibration` is false again until
enough new bad clicks accumulate).

## New display / layout changed

`NotificationPolicy` is pure and stateless: the "already notified" set for new displays lives in
`AppSettings.notifiedDisplays` (not in `FocusSettings` — R1/R6) and is passed in and read back by
the caller, never read from disk by `NotificationPolicy` itself.

- `newDisplays(present:calibrated:notified:)`: every connected display key that has no calibration
  and hasn't been notified about yet — once per display, ever, even across relaunches (the caller
  persists `notified` into `AppSettings`).
- `layoutChanged(from:to:)`: true only when the *same set* of physical displays (by vendor/model/
  serial/resolution, ignoring order and position) now sit at different origins. Connecting or
  removing a display is deliberately **not** a layout change — that's `newDisplays`'s job, or (if a
  calibrated display disappears) a setup-matching concern, not a notification.

`DisplayFingerprint.uniqueKeys(_:)` (`Sources/FocusCore/Setup.swift`) is the other half of "which
displays are these, really": two monitors that report the *same* non-zero serial (seen on cheap
panels and some docks) would otherwise collide on one calibration. `uniqueKeys` appends each
display's origin to its key only when its plain key is duplicated within the list — a display with
a unique key keeps the plain, stable one, so normal setups are unaffected by this fallback.

## Persistence

`DisplayCalibration.init(from:)` requires only `pose` and `calibrationPoints` — the fields present
since the plan-1 format. `dotPoses`, `learnedPoints` and `recentErrors` were added later and decode
to `[]` when absent, so a calibration file written by an older build loads without error (it just
starts with an empty cloud and no learning history, same as decoding tolerance elsewhere in
FocusCore — `FocusSettings`, `AppSettings`). `Tests/FocusCoreTests/Fixtures` holds the plan-1
setup/settings JSON this tolerance is tested against (`PersistenceTests.swift`).
