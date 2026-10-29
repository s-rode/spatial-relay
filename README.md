# Spatial Relay

This fork adds bounded live buffering, quieter background operation, and automatic reconnection to the original Spotify relay. It keeps the same Apple playback API and does not implement its own spatial effects.

Build a local app without full Xcode:

```sh
Scripts/test-core.sh
Scripts/build-local.sh
```

The result is `build/local/Spatial Relay Local.app`, version 0.3.0, with its own privacy identity (`com.srode.SpatialRelay`). It is sandboxed and ad-hoc signed, with hardened runtime enabled. It is not notarized. The script does not install it, remove quarantine, or change macOS security settings. Full Xcode builds and the original XCTest suite are still supported.

Changes in this fork:

- At more than 350 ms of audio in the capture and renderer queues together, discard stale audio and restart from a fresh startup buffer. This can skip a brief passage after an interruption. Three resyncs are allowed per 30 seconds; further trouble stops the relay and restores direct playback.
- After 500 ms without nonzero audio samples, poll every 80 ms instead of 8 ms. Resume the faster cadence when signal returns. This can add up to one idle polling interval to playback resumption.
- Sample the meter only while the panel is visible. Run health checks once per second on a background control queue, including with the panel closed.
- Restore direct playback before rebuilding after an output or Spotify-process change. If compatible-looking headphones or Spotify are absent, wait with direct playback enabled. Stop relay cancels waiting. Failed rebuilds stop after three attempts; unsafe cleanup failures are never retried automatically.
- Keep a fixed five-second renderer recovery deadline across repeated notifications.
- Show the estimated relay queue instead of a fixed latency label. This excludes device, Bluetooth, and system processing latency.
- Disable coverage instrumentation in distribution builds and reject instrumented binaries during packaging.

Read-only hardware discovery is available with `Spatial Relay Local.app/Contents/MacOS/SpatialRelay --diagnostics`. It does not start capture. A running relay and a recognized AirPods name do not prove that spatialization is active: Fixed and Head Tracked still need to be checked on the actual Mac and headphones.

[![CI](https://github.com/s-rode/spatial-relay/actions/workflows/ci.yml/badge.svg)](https://github.com/s-rode/spatial-relay/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Spatial Relay is a macOS menu-bar app that routes audio from Spotify Desktop through an Apple playback API that supports Spatialize Stereo. It is intended for AirPods models with Spatial Audio support.

```text
Spotify -> Core Audio process tap -> stereo Float32 PCM ring buffer
        -> AVSampleBufferAudioRenderer -> current output device
```

The app runs in the menu bar and has no Dock icon. Closing its panel does not stop an active relay.

## Requirements

- Apple silicon Mac
- macOS 14.2 or later
- Spatial Audio-capable AirPods
- Spotify Desktop (`com.spotify.client`)
- Xcode 16.4 or later when building from source

## Install

Prebuilt Apple silicon packages are available on the [Releases page](https://github.com/shevlfs/spatial-relay/releases). Release builds are ad-hoc signed and are not notarized. For a normal Gatekeeper-trusted build, compile the app with your own Apple development identity.

To build locally:

1. Clone the repository.
2. Open `SpatialRelay.xcodeproj` in Xcode.
3. Select the **SpatialRelay** scheme and your Mac.
4. Choose a Development Team if Xcode requests one.
5. Run the app.

## Use

1. Connect your AirPods and select them as the Mac's output.
2. Start playback in Spotify.
3. Open Spatial Relay from its waveform icon in the menu bar.
4. Click **Start relay**.
5. Approve **System Audio Recording** access when macOS asks.
6. Open the macOS Sound or AirPods menu and select **Fixed** or **Head Tracked** under Spatial Audio.

Use **Stop relay** to stop playback routing or cancel reconnection. Use **Quit Spatial Relay** from the ellipsis menu to close the app and restore Spotify's direct output.

## Audio and privacy

The relay accepts stereo, native-endian 32-bit floating-point PCM from Core Audio and submits Float32 PCM at the output device's nominal sample rate. It does not add lossy encoding, sample-rate conversion, normalization, EQ, or gain changes. Spotify's own source quality and normalization settings still apply.

Audio remains in a bounded in-memory buffer. It is not written to disk, sent over the network, or collected as telemetry. Spotify's original output is muted only while the process tap is active. Normal stop, quit, and failure paths restore direct output.

Spatial Audio mode changes can briefly reconfigure the renderer. Spatial Relay gives those changes a fixed five-second recovery window, flushes and rebases the render timeline, and stops if the output does not recover. During recovery, stale PCM may be discarded to preserve live playback rather than replaying a long backlog.

## Development

Run the unit tests from the command line:

```sh
xcodebuild \
  -project SpatialRelay.xcodeproj \
  -scheme SpatialRelay \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

CI runs tests, static analysis, and a Release build on a native arm64 macOS runner. Tags matching `vMAJOR.MINOR.PATCH` build an ad-hoc signed app, verify it, and publish a ZIP and SHA-256 checksum to GitHub Releases.

The hosted test suite cannot exercise the System Audio Recording prompt, Spotify playback, AirPods routing, or the Spatial Audio menu. Changes to those paths should also be checked on a physical Mac.

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request. Security reports are covered by [SECURITY.md](SECURITY.md).

## License

Spatial Relay is open source under the [MIT License](LICENSE).

Spotify, AirPods, Spatial Audio, macOS, and Apple are trademarks of their respective owners. This project is independent and is not affiliated with, endorsed by, or sponsored by Spotify or Apple.
