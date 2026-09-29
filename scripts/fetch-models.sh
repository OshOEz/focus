#!/usr/bin/env bash
# Rebuilds the two CoreML models committed in Sources/GazeKit/Resources.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Sources/GazeKit/Resources
TMP=$(mktemp -d)
# BlazeGaze (WebEyeTrack, MIT) — compiled by MacGaze CI, release v0.1.0-assets.
curl -fsSL https://github.com/AACTools/MacGaze/releases/download/v0.1.0-assets/blazegaze.mlmodelc.zip -o "$TMP/b.zip"
rm -rf "$OUT/blazegaze.mlmodelc" && unzip -qo "$TMP/b.zip" -d "$OUT"
# FaceMesh 468 pts (PINTO model zoo #032, Apache-2.0), CoreML conversion shipped by PINTO.
curl -fsSL https://s3.ap-northeast-2.wasabisys.com/pinto-model-zoo/032_FaceMesh/032_FaceMesh.tar.gz | tar -xz -C "$TMP"
tar -xzf "$TMP/032_FaceMesh/07_coreml/resources.tar.gz" -C "$TMP"
rm -rf "$OUT/face_mesh.mlmodelc" && xcrun coremlcompiler compile "$(find "$TMP" -name face_mesh.mlmodel | head -1)" "$OUT" >/dev/null
rm -rf "$TMP"
ls "$OUT"
