#!/usr/bin/env bash
# Human-run checks: the only script allowed to show permission dialogs (camera, Accessibility —
# a person is in front of the Mac to answer them). Never run it unattended. Results → build/bench/morning.md.
set -uo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
OUT=build/bench/morning.md
mkdir -p build/bench
echo "# Morning check $(date '+%F %T')" > "$OUT"
ask() { read -r -p "$1 [y/n] " a; if [ "$a" = y ]; then echo "- [x] $1" >> "$OUT"; else echo "- [ ] $1" >> "$OUT"; fi; }

swift build -c release --product focus-gaze || exit 1
.build/release/focus-gaze cameras
ask "cameras: the built-in camera (and any USB camera) is listed"
.build/release/focus-gaze probe 10
ask "probe: ~15 samples/s, conf >= 0.5, lag 0-150 ms, yaw changes sign left/right, 'no face' with a hand over the camera"
if [ "$(system_profiler SPDisplaysDataType | grep -c Resolution)" -ge 2 ]; then
  echo "Ctrl-C ends the live screen tracking."
  trap ':' INT; .build/release/focus-gaze screens; trap - INT
  ask "screens: the right screen each time, 'hors écran' when looking at the phone"
else
  echo "- screens: skipped (one display)" >> "$OUT"
fi
if [ -x scripts/build-app.sh ] && ! scripts/build-app.sh; then
  echo "- [ ] app build failed (scripts/build-app.sh), see output above" >> "$OUT"
fi
if [ -d build/Focus.app ]; then
  open build/Focus.app
  ask "onboarding: permission page updates by itself; 9-dot calibration; Try it map follows the head"
else
  echo "- app onboarding: skipped (build/Focus.app not built yet, plan 3b)" >> "$OUT"
fi
echo "Also run the manual list in TESTING.md. Results: $OUT"
