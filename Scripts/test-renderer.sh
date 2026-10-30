#!/bin/bash
# Explicit live-output integration test; not a device-free unit test.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build/renderer-tests"
mkdir -p "$BUILD_DIR/ModuleCache"
xcrun clang++ -std=c++20 -fobjc-arc -DDEBUG=1 -O2 \
  -c "$ROOT/SpatialRelay/Audio/AudioCaptureBridge.mm" -o "$BUILD_DIR/capture.o"
xcrun swiftc -D DEBUG -Xcc -DDEBUG=1 -swift-version 5 -parse-as-library \
  -module-cache-path "$BUILD_DIR/ModuleCache" \
  -import-objc-header "$ROOT/SpatialRelay/SpatialRelay-Bridging-Header.h" \
  "$ROOT"/SpatialRelay/Audio/*.swift "$ROOT/Tests/Headless/RendererIntegrationTests.swift" \
  "$BUILD_DIR/capture.o" -lc++ -o "$BUILD_DIR/renderer-tests"
"$BUILD_DIR/renderer-tests" "$BUILD_DIR/last-native-renderer.json"
