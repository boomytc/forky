#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .artifacts
xcodebuild -project Forky.xcodeproj -scheme Forky -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath .artifacts/DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual build "$@"
printf '\nApp: %s/.artifacts/DerivedData/Build/Products/Debug/Forky.app\n' "$PWD"
