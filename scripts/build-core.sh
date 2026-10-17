#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$TASK_ROOT/ios/Frameworks"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
COMPILER="$(mktemp -t nodescope-clang).sh"
trap 'rm -f "$COMPILER"' EXIT
cat > "$COMPILER" <<EOF
#!/usr/bin/env bash
exec xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK_PATH" -miphoneos-version-min=16.0 "\$@"
EOF
chmod +x "$COMPILER"
cd "$TASK_ROOT/core"
CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$COMPILER" \
  go build -trimpath -buildmode=c-archive -ldflags='-s -w' -o "$TASK_ROOT/ios/Frameworks/libNodeCore.a" ./mobile
