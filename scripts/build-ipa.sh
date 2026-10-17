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
mkdir -p "$TASK_ROOT/build/package/Payload" "$TASK_ROOT/dist"
cp -R "$TASK_ROOT/build/DerivedData/Build/Products/Release-iphoneos/NodeScope.app" "$TASK_ROOT/build/package/Payload/"
cd "$TASK_ROOT/build/package"
zip -qry "$TASK_ROOT/dist/NodeScope-unsigned.ipa" Payload
shasum -a 256 "$TASK_ROOT/dist/NodeScope-unsigned.ipa" > "$TASK_ROOT/dist/SHA256SUMS.txt"
