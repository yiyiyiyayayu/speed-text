#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
bash scripts/build-core.sh
python3 scripts/third-party-notices.py
cd ios
xcodegen generate
xcodebuild -project NodeScope.xcodeproj -scheme NodeScope -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$TASK_ROOT/build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
python3 "$TASK_ROOT/scripts/package-ipa.py" package \
  "$TASK_ROOT/build/DerivedData/Build/Products/Release-iphoneos/NodeScope.app" \
  "$TASK_ROOT/dist/NodeScope-unsigned.ipa"
cd "$TASK_ROOT/dist"
shasum -a 256 NodeScope-unsigned.ipa > SHA256SUMS.txt
