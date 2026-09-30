#!/usr/bin/env bash
# Bench group 5, app smoke: build the real bundle and exercise it with no human and no TCC prompt.
# Standalone script (not Tools/focus-bench's Swift harness, `BenchResult`/group table): that harness
# lives on the unmerged feat/benches branch. Prints one "[pass|fail|skip] 5 app smoke/<name>  <detail>"
# line per check, in the same shape focus-bench's report table prints, so E4's bench.sh can fold this
# script's output straight in — see the "wired into bench.sh" note at the bottom of this file.
#
# --selftest and --smoke never prompt: --selftest only reads permission statuses (Permissions.camera/
# accessibility/location, all status getters), and --smoke (LaunchOptions.smoke, AppController.swift)
# skips onboarding, the login item, the hot key and the camera. FOCUS_SUPPORT_DIR points both at a
# throwaway folder so the developer's real settings.json/setups are never touched.
set -uo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

pass=0
fail=0
skip=0
report() {   # $1=pass|fail|skip  $2=name  $3=detail
  echo "[$1] 5 app smoke/$2   $3"
  case "$1" in
    pass) pass=$((pass + 1)) ;;
    fail) fail=$((fail + 1)) ;;
    skip) skip=$((skip + 1)) ;;
  esac
}

mkdir -p build/bench
support=$(mktemp -d "${TMPDIR:-/tmp}/focus-bench-app.XXXXXX")
trap 'rm -rf "$support"' EXIT
export FOCUS_SUPPORT_DIR="$support"

scripts/build-app.sh >build/bench/build-app.log 2>&1
build_status=$?
app=build/Focus.app
exe="$app/Contents/MacOS/Focus"
lsui=$(plutil -extract LSUIElement raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)
models=false
[[ -d "$app/Contents/Resources/Focus_GazeKit.bundle" ]] && models=true

if [[ $build_status -eq 0 && "$lsui" == "true" && "$models" == "true" ]]; then
  report pass "build-app.sh -> signed Focus.app" "exit $build_status, LSUIElement=$lsui, models bundle $models"
else
  report fail "build-app.sh -> signed Focus.app" "exit $build_status, LSUIElement=$lsui, models bundle $models (see build/bench/build-app.log)"
fi

if [[ $build_status -ne 0 ]]; then
  echo "$pass pass · $fail fail · $skip skip"
  exit $((fail > 0 ? fail : 1))
fi

st_out=$("$exe" --selftest 2>&1)
st_status=$?
if [[ $st_status -eq 0 ]] && printf '%s' "$st_out" | grep -q '"ok":true'; then
  report pass "--selftest exits 0" "$st_out"
else
  report fail "--selftest exits 0" "exit $st_status: $st_out"
fi

"$exe" --smoke &
pid=$!
sleep 3
alive=false
if kill -0 "$pid" 2>/dev/null; then
  alive=true
  report pass "smoke: alive after 3 s" "pid $pid"
else
  report fail "smoke: alive after 3 s" "pid $pid"
fi

ax_json=$(swift "$(dirname "$0")/bench-app-ax.swift" "$pid" 2>/dev/null)
[[ -z "$ax_json" ]] && ax_json='{"trusted":false}'

if ! printf '%s' "$ax_json" | grep -q '"trusted":true'; then
  report skip "smoke: status item via AX" "Accessibility not granted to the bench host"
  report skip "smoke: no windows" "Accessibility not granted to the bench host"
elif [[ "$alive" == "true" ]]; then
  extras=$(printf '%s' "$ax_json" | sed -n 's/.*"menuExtras":\([0-9]*\).*/\1/p')
  windows=$(printf '%s' "$ax_json" | sed -n 's/.*"windows":\([0-9]*\).*/\1/p')
  extras=${extras:-0}
  windows=${windows:-0}
  if [[ "$extras" -ge 1 ]]; then
    report pass "smoke: status item via AX" "$extras menu bar extra(s)"
  else
    report fail "smoke: status item via AX" "$extras menu bar extra(s)"
  fi
  if [[ "$windows" -eq 0 ]]; then
    report pass "smoke: no windows" "$windows window(s)"
  else
    report fail "smoke: no windows" "$windows window(s)"
  fi
fi

kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null

# settings.json is written (with loginItemDefaultApplied=true) only by the non-smoke startup path;
# --smoke must leave the support dir untouched (AppController.swift: `guard !options.smoke else { return }`).
written=false
if [[ -f "$support/settings.json" ]] && grep -q '"loginItemDefaultApplied" *: *true' "$support/settings.json"; then
  written=true
fi
setups=0
if [[ -d "$support/setups" ]]; then
  setups=$(find "$support/setups" -type f | wc -l | tr -d ' ')
fi
if [[ "$written" == "false" && "$setups" -eq 0 ]]; then
  report pass "smoke: no side effects" "loginItemDefaultApplied=$written, setups=$setups"
else
  report fail "smoke: no side effects" "loginItemDefaultApplied=$written, setups=$setups"
fi

echo "$pass pass · $fail fail · $skip skip"
exit "$fail"

# Wired into bench.sh (E4, feat/benches, once merged): replace bench.sh's group-5 step with a call to
# this script instead of `focus-bench app` — `scripts/bench-app.sh` (no args), fold its
# "[pass|fail|skip] 5 app smoke/<name>  <detail>" lines straight into the combined report (same shape
# `BenchResult`/Report.write already prints for the other groups), and add its trailing fail count to
# bench.sh's overall exit code. No Swift harness change needed for this group.
