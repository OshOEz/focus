#!/usr/bin/env bash
# Builds build/Focus.app from the SwiftPM product and signs it ad hoc.
# Ceiling: an ad-hoc signature changes on every build, so macOS may ask to re-grant Camera and
# Accessibility after a rebuild (docs/wiki/Troubleshooting.md). A Developer ID signature would fix that.
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
codesign --force --deep --sign - --entitlements Packaging/Focus.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
