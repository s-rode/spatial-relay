#!/bin/bash
# Build an isolated, sandboxed local app using Apple's Command Line Tools.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build/local}"
APP="$BUILD_DIR/Spatial Relay Local.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$BUILD_DIR/ModuleCache" "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun clang++ -std=c++20 -fobjc-arc -O2 -mmacosx-version-min=14.2 \
  -isysroot "$SDK" -fno-profile-instr-generate -fno-coverage-mapping \
  -c "$ROOT/SpatialRelay/Audio/AudioCaptureBridge.mm" -o "$BUILD_DIR/AudioCaptureBridge.o"
xcrun swiftc -O -swift-version 5 -strict-concurrency=complete -parse-as-library \
  -target arm64-apple-macosx14.2 -sdk "$SDK" -module-name SpatialRelay \
  -module-cache-path "$BUILD_DIR/ModuleCache" \
  -import-objc-header "$ROOT/SpatialRelay/SpatialRelay-Bridging-Header.h" \
  "$ROOT"/SpatialRelay/*.swift "$ROOT"/SpatialRelay/Audio/*.swift \
  "$BUILD_DIR/AudioCaptureBridge.o" -lc++ -o "$APP/Contents/MacOS/SpatialRelay"

cp "$ROOT/SpatialRelay/Info.plist" "$APP/Contents/Info.plist"
PLIST="$APP/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy
"$PB" -c 'Set :CFBundleDevelopmentRegion en' "$PLIST"
"$PB" -c 'Set :CFBundleDisplayName Spatial Relay Local' "$PLIST"
"$PB" -c 'Set :CFBundleExecutable SpatialRelay' "$PLIST"
"$PB" -c 'Set :CFBundleIdentifier com.srode.SpatialRelay' "$PLIST"
"$PB" -c 'Set :CFBundleName Spatial Relay Local' "$PLIST"
"$PB" -c 'Set :CFBundleShortVersionString 0.3.0' "$PLIST"
"$PB" -c 'Set :CFBundleVersion 3' "$PLIST"
"$PB" -c 'Add :LSMinimumSystemVersion string 14.2' "$PLIST"
"$PB" -c 'Add :CFBundleIconFile string AppIcon' "$PLIST"
"$PB" -c 'Add :CFBundleIconName string AppIcon' "$PLIST"

ICONSET="$BUILD_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  cp "$ROOT/SpatialRelay/Assets.xcassets/AppIcon.appiconset/AppIcon-$size.png" "$ICONSET/icon_${size}x${size}.png"
  double=$((size * 2))
  cp "$ROOT/SpatialRelay/Assets.xcassets/AppIcon.appiconset/AppIcon-$double.png" "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
codesign --force --sign - --options runtime --timestamp=none \
  --entitlements "$ROOT/SpatialRelay/SpatialRelay.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
nm "$APP/Contents/MacOS/SpatialRelay" > "$BUILD_DIR/symbols.txt"
if /usr/bin/grep -Eq '__llvm_(profile|prf)|__profc_' "$BUILD_DIR/symbols.txt"; then
  printf 'Release contains coverage instrumentation.\n' >&2
  exit 1
fi
printf 'Built %s\n' "$APP"
