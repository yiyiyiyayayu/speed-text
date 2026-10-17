#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$TASK_ROOT/ios/Frameworks"
CORE_SDK="${1:-iphoneos}"
CORE_ARCH="${2:-arm64}"
GO_ARCH="$CORE_ARCH"
if [ "$CORE_ARCH" = x86_64 ]; then GO_ARCH=amd64; fi
if [ "$CORE_SDK" = iphonesimulator ]; then
  MINIMUM_FLAG=-mios-simulator-version-min=16.0
else
  MINIMUM_FLAG=-miphoneos-version-min=16.0
fi
SDK_PATH="$(xcrun --sdk "$CORE_SDK" --show-sdk-path)"
COMPILER="$(mktemp -t nodescope-clang).sh"
trap 'rm -f "$COMPILER"' EXIT
cat > "$COMPILER" <<EOF
#!/usr/bin/env bash
exec xcrun --sdk "$CORE_SDK" clang -arch "$CORE_ARCH" -isysroot "$SDK_PATH" "$MINIMUM_FLAG" "\$@"
EOF
chmod +x "$COMPILER"
cd "$TASK_ROOT/core"
CGO_ENABLED=1 GOOS=ios GOARCH="$GO_ARCH" CC="$COMPILER" \
  go build -trimpath -buildmode=c-archive -ldflags='-s -w' -o "$TASK_ROOT/ios/Frameworks/libNodeCore.a" ./mobile
