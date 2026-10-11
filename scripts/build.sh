#!/usr/bin/env bash
# Builds AmbientLights.app with swiftc. Works with only the Command Line Tools
# installed (no Xcode needed). Output: build/AmbientLights.app
#
# Usage: scripts/build.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/AmbientLights"
BUILD="$ROOT/build"
APP="$BUILD/AmbientLights.app"

PRODUCT_NAME="AmbientLights"
BUNDLE_ID="local.ambientlights.AmbientLights"
MARKETING_VERSION="0.1.0"
BUILD_NUMBER="1"
DEPLOYMENT_TARGET="13.0"
ARCH="$(uname -m)"

case "$CONFIG" in
  debug)   OPT_FLAGS=(-Onone -g -DDEBUG) ;;
  release) OPT_FLAGS=(-O) ;;
  *) echo "Unknown config: $CONFIG (use debug or release)" >&2; exit 1 ;;
esac

SDK="$(xcrun --sdk macosx --show-sdk-path)"
echo "▸ Swift:  $(xcrun swiftc --version 2>&1 | head -1)"
echo "▸ SDK:    $SDK"
echo "▸ Target: $ARCH-apple-macos$DEPLOYMENT_TARGET ($CONFIG)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done < <(find "$SRC" -name '*.swift' -print0 | sort -z)

echo "▸ Compiling ${#SOURCES[@]} Swift files"
xcrun swiftc \
  -sdk "$SDK" \
  -target "$ARCH-apple-macos$DEPLOYMENT_TARGET" \
  -swift-version 5 \
  -parse-as-library \
  -module-name "$PRODUCT_NAME" \
  "${OPT_FLAGS[@]}" \
  -framework SwiftUI -framework AppKit -framework CoreBluetooth -framework Network -framework Security \
  -o "$APP/Contents/MacOS/$PRODUCT_NAME" \
  "${SOURCES[@]}"

echo "▸ Writing Info.plist"
sed \
  -e "s/\$(EXECUTABLE_NAME)/$PRODUCT_NAME/g" \
  -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" \
  -e "s/\$(PRODUCT_NAME)/$PRODUCT_NAME/g" \
  -e "s/\$(MARKETING_VERSION)/$MARKETING_VERSION/g" \
  -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD_NUMBER/g" \
  -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$DEPLOYMENT_TARGET/g" \
  "$SRC/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Signing (ad-hoc, sandbox + Bluetooth entitlements)"
codesign --force --sign - \
  --options runtime \
  --entitlements "$SRC/AmbientLights.entitlements" \
  "$APP"
codesign --verify --strict "$APP"

echo "✓ Built $APP"
echo "  Run: open \"$APP\""
