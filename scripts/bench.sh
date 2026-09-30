#!/usr/bin/env bash
# Unattended benches (docs/wiki/Benches.md). Never prompts for a permission: checks that need one
# are reported as skipped with the reason. Exit code = number of failed checks.
set -uo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
OUT=build/bench
rm -rf "$OUT" && mkdir -p "$OUT"

# 0. Nothing unattended may call a permission request API.
grep -rnE '[Rr]equest[A-Za-z]*(Access|Authoriz|Permission)|CGRequest[A-Za-z]+|requestCamera|requestLocation|promptAccessibility|AXIsProcessTrustedWithOptions|kAXTrustedCheckOptionPrompt' \
  Sources/FocusBench Sources/FocusFixture Tests > "$OUT/lint.txt" 2>/dev/null
copy=$?

# 1. Unit tests.
swift test > "$OUT/unit.log" 2>&1
unit=$?

# 2-4. Release build (vision timings are only meaningful in release). If it fails, the groups don't
# run: a debug focus-bench still writes the report, where each missing group counts as a failure.
if swift build -c release > "$OUT/build.log" 2>&1; then
  B=.build/release/focus-bench
  "$B" engine --json "$OUT/engine.json"
  "$B" vision --fixtures Tests/GazeKitTests/Fixtures --json "$OUT/vision.json"
  "$B" ax --json "$OUT/ax.json"
else
  echo "release build failed, see $OUT/build.log"
  B=.build/debug/focus-bench
  if ! swift build --product focus-bench >> "$OUT/build.log" 2>&1; then
    printf '# Bench report\n\n**build failed**: focus-bench does not compile, see build.log\n' > "$OUT/report.md"
    exit 1
  fi
fi

# 5. App smoke (plan 3b adds scripts/build-app.sh).
if [ -x scripts/build-app.sh ]; then
  if scripts/build-app.sh > "$OUT/app.log" 2>&1 && build/Focus.app/Contents/MacOS/Focus --selftest > "$OUT/selftest.json" 2>> "$OUT/app.log"
  then app=pass; else app=fail; fi
else
  app="skip:scripts/build-app.sh not there yet (plan 3b)"
fi

"$B" report --out "$OUT/report.md" --unit-log "$OUT/unit.log" --unit-status "$unit" --lint "$OUT/lint.txt" \
  --copy "$copy" --copy-log "$OUT/copy.txt" \
  --app "$app" "$OUT/engine.json" "$OUT/vision.json" "$OUT/ax.json"
