#!/usr/bin/env bash
# Builds build/Focus.app from the SwiftPM product and signs it with the local identity from
# scripts/make-signing-cert.sh (ad hoc when absent). Ceiling: local only, no Gatekeeper trust;
# a Developer ID signature would make it installable on other Macs without warnings.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
swift build -c release --product Focus
BIN=$(swift build -c release --show-bin-path)
APP=build/Focus.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Focus" "$APP/Contents/MacOS/Focus"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"
# SwiftPM's Bundle.module looks in Bundle.main.resourceURL (Contents/Resources) first; the bundle root would break the signature.
for b in "$BIN"/Focus_*.bundle; do
  [[ "$b" == *Tests.bundle ]] && continue
  cp -R "$b" "$APP/Contents/Resources/"
done
# Ad-hoc signatures change with every build, and macOS ties Camera/Accessibility grants to the
# signature: each rebuild silently loses them. A stable local identity keeps them (designated
# requirement = bundle id + certificate). Create it once with scripts/make-signing-cert.sh.
ID="${FOCUS_SIGN_ID:-Focus Local Signing}"
security find-identity -p codesigning 2>/dev/null | grep -q "\"$ID\"" || ID=-
[ "$ID" = - ] && echo "note: ad-hoc signature, permissions reset on every rebuild (see scripts/make-signing-cert.sh)" >&2
codesign --force --deep --sign "$ID" --entitlements Packaging/Focus.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
