# Decision engine

How `FocusEngine.decide(_:world:input:)` turns one camera sample into a focus action, or nothing.
Everything here is in `Sources/FocusCore`; the app only supplies `World` (what's on screen) and
reads back a `FocusAction?`.

## 1. Pipeline

```
GazeSample (GazeKit, host clock)
      │
      ▼
 GazeSmoother (1€ filter)  ──── no-face sample? ─── reset filters, pass through
      │
      ▼
 confidence / raw finite? ──no──► idle(.noFace)
      │ yes
      ▼
 ScreenClassifier.classify(pose) ──nil──► idle(.lookingAway)
      │ key
      ▼
 status = .facing(key)  (or .oneDisplayWindowFocusOff)
      │
      ▼
 same screen as focused window? ──yes──► allowsSameScreen? → window/pane candidate
      │ no
      ▼
 allowsScreenSwitch? ──► gaze resolves to a window on target? → .window : .display(key)
      │
      ▼
 Dwell<FocusAction> (screenDwell or paneDwell) ──not held long enough──► nil
      │ released
      ▼
 ActionLatch.admit ──already fired for this state──► nil
      │
      ▼
 FocusAction (.display / .window / .pane)  ──► FocusActuator (plan 3b)
```

Every stage is pure and takes `now` as a parameter (`GazeSample.time`, `InputActivity`'s
timestamps): there is exactly **one clock**, the host monotonic clock (`CACurrentMediaTime` base),
shared by the camera samples, the keyboard/mouse guard and the dwell timers. Nothing in FocusCore
reads the wall clock or `Date()` on the hot path — a test can drive the whole pipeline with
made-up `Double`s and get deterministic results.

## 2. Smoothing

`GazeSmoother` (`Sources/FocusCore/OneEuro.swift`) runs a 1€ filter — Casiez, Roussel & Vogel,
*"1€ Filter: A Simple Speed-based Low-pass Filter for Noisy Input in Interactive Systems"*, CHI
2012 — independently on yaw, pitch, face X/Y and the raw gaze point. The filter's cutoff rises
with how fast the signal is moving, so a still head is smoothed hard (no jitter at rest) and a
turning head is followed with little lag (no rubber-banding mid-turn).

Per-signal defaults (`GazeSmoother.init`), all in Hz for the cutoffs:

| Signal | min cutoff | β |
|---|---|---|
| pose (yaw, pitch) | 1.0 | 1.5 |
| face position | 1.0 | 2.0 |
| gaze point | 0.7 | 1.0 |

These are starting values for a 15 fps camera, not truths — FocusBench's group 2 latency metric
(time from a real head turn to the resulting switch) is how you'd tune them for a different frame
rate or camera. A gap longer than `GazeSmoother.maxGap` (0.5 s) between face samples restarts every
filter: bridging the gap would drag the old pose into wherever the head ended up, which is worse
than a one-frame jump. A no-face sample (`GazeSample.noFace(at:)`) also resets and passes through
unchanged, so a `NaN` never enters a filter's running state.

## 3. Screen boundary

`ScreenClassifier` (`Sources/FocusCore/ScreenClassifier.swift`) picks which display the head faces.
Off-screen (phone, desk, ceiling) is a pose farther than `maxDistance` from every calibrated
centroid — `nil`, no switch.

Switching between two on-screen displays is not "nearest centroid wins": the current screen keeps
the pose until the next screen has *earned* it. For current screen C and a candidate N, the pose is
projected onto the C→N axis and expressed as a fraction `s` of the gap between the **facing edges**
of their calibration clouds — the clouds recorded per calibration dot (`DisplayCalibration.dotPoses`),
not just the two centroids. `s = 0` is C's nearest edge dot, `s = 1` is N's. N takes over once
`s > threshold`, where

```
threshold = 0.5 + (headTurn − 0.3) / 2
```

maps the "Head turn needed" setting (0.3…0.7) onto 0.5…0.7. The floor is 0.5 — the midpoint of the
gap — and it's a hard floor: whatever the setting, N is never granted the pose before the pose has
crossed into its half of the gap. Two screens can therefore never both claim the same pose, and
there is no ping-pong right at the bezel no matter how low "head turn needed" is set. Going back to
"going back needs a slightly bigger turn" — so a pose sitting exactly on the boundary doesn't flap
between two screens as it drifts by a pixel.

Why the *facing* edge of the cloud and not the centroid: the centroid is the average pose looking
at the whole screen, but the screen a head turns to next is decided at the edge closest to the
neighbour. Two 27" monitors angled inward have centroids much closer together (in yaw) than their
outer edges, so anchoring the gap on the facing edges keeps the boundary where the bezel actually
is instead of biasing it toward whichever screen has the wider cloud.

**Worked example** (`cloudsMoveTheBoundaryToTheFacingEdges`, `ScreenClassifierTests.swift`): L
centroid at yaw −0.3 rad, R centroid at yaw 0.3 rad, headTurn = 0.5 → threshold = 0.5 + (0.5 −
0.3)/2 = **0.6** (not 0.5 — the setting only reaches the 0.5 floor at its minimum, 0.3).

*Centroids only* (no dot clouds recorded — an old calibration): the gap is defined edge-to-edge as
the full centroid span, −0.3…0.3 (length 0.6). A pose at yaw 0.05 projects to (0.05 − (−0.3)) =
0.35 along that axis, i.e. 0.35 / 0.6 = **58%** of the gap — under the 60% threshold, so the pose
stays on L.

*With clouds* (`dotPoses` from calibration, at −0.4/−0.3/−0.2 for L and 0.2/0.3/0.4 for R): the gap
is redefined as the span between the two clouds' *facing* edges — L's dot nearest R (−0.2 → projects
to 0.1) to R's dot nearest L (0.2 → projects to 0.5), a narrower span of length 0.4. The same pose at
yaw 0.05 (projecting to 0.35 as before) is now (0.35 − 0.1) / 0.4 = **62.5%** of this shorter gap —
over the 60% threshold, so R takes over.

Same pose, same centroids, opposite outcomes: recording the calibration dot clouds moves the
decision boundary to where the screens' bezels actually are, instead of leaving it at the midpoint
between two averages that can sit closer together (angled monitors) or farther apart (monitors with
very different eye distances) than the physical seam.

*Minimum gap*: the hysteresis is a fixed share of the gap, so a gap only a few times the pose jitter
at rest (σ ≈ 0.01 rad) lets noise alone cross it — and edge dots 3 % inside two screens are only
0.04–0.06 rad apart at 1–2 m. Any facing-edge gap narrower than `ScreenClassifier.minGap`
(2.5 × `CalibrationBuilder.minScreenSeparation` = 0.125 rad ≈ 7°) is widened to it around its
midpoint: the boundary stays at the seam, only the dead band grows, and it is continuous (no cliff).
Bench `bezel/*` pins it (docs/wiki/Benches.md). History: floor/2 fallback → 5 flips per 10 s stare
at 1800 pt; a full-floor fallback to centroids → 0 there but 2-3 flips at 1000-1700 pt; widening →
≤ 1 flip from 800 to 2400 pt. Switch latency p50 267 ms throughout (laptop-below p95 267 → 333 ms).

## 4. Guards

`InputActivity` (`Sources/FocusCore/Settings.swift`) tracks only the *time* of the last key and
mouse event — never their content.

| Guard | Value | Setting? | Source |
|---|---|---|---|
| Screen dwell | 300 ms default | `FocusSettings.screenDwell`, 0.1–1 s | |
| Screens after typing | 1 s | fixed, `FocusSettings.screenTypingPause` | (b), "inferred" |
| Panes/windows after typing | 3 s default | `FocusSettings.typingPause`, 1–10 s | (a) |
| Wait while typing | on by default, can turn off | `FocusSettings.waitWhileTyping` | |
| Mouse guard | 1.5 s fixed | `FocusSettings.mousePause` (no setting exposed) | |
| Off-screen distance | 0.35 | `FocusSettings.offScreenDistance` | |

`allowsScreenSwitch(at:_:)` only checks the mouse guard and (if `waitWhileTyping`) the fixed
1-second screen-typing pause — turning to another screen still moves focus "after about a second"
even mid-sentence. `allowsSameScreen(at:_:)` checks the mouse guard and the full, user-set
`typingPause` — reading another pane on the same screen never steals keystrokes until that pause
elapses. `InputActivity.isQuiet` does not exist; these two named guards are the whole API (R4).

## 5. What a screen switch focuses

On landing on a new screen (`FocusEngine.decide`, the `key != focusedDisplay` branch):

1. If window focus is trusted (`settings.windowFocus` and the display isn't flagged
   `needsRecalibration`) and the gaze point resolves to a specific window on that screen
   (`TargetResolver.window(at:...)`), focus **that** window.
2. Otherwise `TargetResolver.windowToRestore(on:windows:last:)` returns the last window used on
   that screen if it's still there, else the topmost window at least `minSize` (200×150 default) —
   never a synthetic click. This is 3b's `FocusActuator`'s job; FocusCore only
   exposes the pure function.
3. If neither yields a window, the action is `.display(key)` — the pointer/Space follows, no window
   focus change.

Same-screen switches (`sameScreenTarget`) prefer a different window under the gaze point, then a
pane inside the currently focused window (`settings.paneFocus`), else nothing.

**Latch semantics** (`ActionLatch`): once an action has been emitted, it stays "latched" — the
engine won't re-emit the *same* action — until either the engine's candidate changes, or the
focused window itself changes underneath it (e.g. the user manually switched windows). This stops
an action with no visible effect (screen with no window, a raise the app refused) from being
re-proposed every frame.

## 6. Status

`EngineStatus` (`Sources/FocusCore/FocusEngine.swift`) is what the engine itself can report:

- `.needsCalibration` — no connected display has a calibration.
- `.noFace` — "Looking for your face".
- `.lookingAway` — pose far from every screen; ignored.
- `.facing(String)` — the display key currently faced.
- `.oneDisplayWindowFocusOff` — a single display with same-screen focus off: nothing to switch to.

The app layers its own states in front of these (`AppStatus`, `Sources/FocusCore/AppStatus.swift`):
paused, screen locked, camera/accessibility permissions, camera unavailable — all of which mean the
engine isn't even running, so they take priority over anything `EngineStatus` would say.

Benches: [group 2 engine scenarios](Benches.md#group-2-engine-scenarios), end-to-end through FocusMac in [group 4](Benches.md#group-4-live-ax-liveaxbenchswift-focus-fixture).
