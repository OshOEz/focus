# Focus wiki

Focus watches where you look and moves keyboard focus there first, so the click you used to make to
catch up is gone; this wiki is the engineering reference for how, page by page.

## Pages

| Page | Read it when… |
|---|---|
| Home (this page) | You need the map, not a page. |
| [Architecture](Architecture.md) | You want the module boundaries, the data-flow diagram, isolation rules (MainActor, off-main CoreML, one clock), persistence paths, or the packaging/signing ceiling. |
| [Gaze-pipeline](Gaze-pipeline.md) | You're touching the camera, the face-mesh/head-pose/eye-patch/BlazeGaze stages, One-Euro smoothing, or need the measured ms/frame. |
| [Decision-engine](Decision-engine.md) | You need `decide()`'s exact order — confidence gate, screen classifier, off-screen, typing/mouse guards, dwell, stickiness, panes, suppression — with each constant and its test. |
| [Calibration-and-learning](Calibration-and-learning.md) | You're changing the 9-dot layout, the RBF map, "learn from my clicks," or the drift-notification rule. |
| [Focusing-windows-and-panes](Focusing-windows-and-panes.md) | You need the screen/window/pane focus rules: z-order pick, stickiness, the pane allowlist, AX-then-click fallback. |
| [Setups](Setups.md) | You're working on per-place calibration: how Focus tells places apart, the Setup ▸ menu, or the optional Places (Wi-Fi) onboarding step. |
| [Permissions-and-privacy](Permissions-and-privacy.md) | You need the permission table (why, when asked, what breaks without it), why there's no Input Monitoring, or the privacy checklist. |
| [Benches](Benches.md) | You're running or reading `focus-bench`: what each group proves, and which findings it already caught. |
| [Settings](Settings.md) | You need a setting's default, range, what it does, and why — read from `FocusSettings`, not guessed. |
| [Troubleshooting](Troubleshooting.md) | The menu bar shows a status you don't understand, a setup loaded wrong, panes won't focus, or permissions vanished after a rebuild. |
| [Decisions](Decisions.md) | You want the ruling and the "why" behind a specific choice. |

## Other docs

- [`TESTING.md`](../../TESTING.md) — how to run `swift test` and read its output.
- [`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md) — vendored code and its license.

## Build

```bash
scripts/build-app.sh   # builds build/Focus.app (run scripts/make-signing-cert.sh once first)
open build/Focus.app   # the Setup Guide walks you through permissions and calibration
```

## Benches

```bash
scripts/bench.sh            # ~30 s, unattended, never prompts for a permission
open build/bench/report.md  # per-group pass/fail/skip with numbers
```
