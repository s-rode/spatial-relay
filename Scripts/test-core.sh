#!/bin/bash
# Deterministic tests without XCTest, WindowServer, audio permission, or devices.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build/core-tests"
mkdir -p "$BUILD_DIR/ModuleCache"
xcrun clang++ -std=c++20 -fobjc-arc -DDEBUG=1 -O1 -g \
  -fsanitize=address,undefined "$ROOT/Tests/Headless/CaptureBridgeTests.mm" \
  -framework Foundation -framework CoreAudio -o "$BUILD_DIR/capture-tests"
"$BUILD_DIR/capture-tests"

xcrun clang++ -std=c++20 -fobjc-arc -DDEBUG=1 -O1 -g -fsanitize=address \
  -c "$ROOT/SpatialRelay/Audio/AudioCaptureBridge.mm" -o "$BUILD_DIR/capture.o"
xcrun swiftc -D DEBUG -sanitize=address -swift-version 5 -parse-as-library \
  -module-cache-path "$BUILD_DIR/ModuleCache" \
  -import-objc-header "$ROOT/SpatialRelay/SpatialRelay-Bridging-Header.h" \
  "$ROOT/SpatialRelay/Audio/CoreAudioSupport.swift" \
  "$ROOT/SpatialRelay/Audio/RelayError.swift" \
  "$ROOT/SpatialRelay/Audio/SampleBufferPlayer.swift" \
  "$ROOT/Tests/Headless/PlaybackPolicyTests.swift" \
  "$BUILD_DIR/capture.o" -lc++ -o "$BUILD_DIR/playback-tests"
"$BUILD_DIR/playback-tests"
