#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .artifacts
RESULT=".artifacts/Forky-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild -project Forky.xcodeproj -scheme Forky -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath .artifacts/DerivedData \
  -parallel-testing-enabled NO -resultBundlePath "$RESULT" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual test "$@"
printf '\nTest results: %s\n' "$RESULT"
