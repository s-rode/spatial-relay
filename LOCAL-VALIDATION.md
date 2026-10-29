Local fork validation
=====================

This fork preserves the original Apple Spatialize Stereo playback path. It changes queue recovery, background scheduling, lifecycle monitoring, and packaging. It does not certify that every macOS/AirPods combination permits Fixed or Head Tracked playback.

Automated checks
----------------

Run `Scripts/test-core.sh` for device-free tests under AddressSanitizer, with UndefinedBehaviorSanitizer also enabled for the C++ capture tests. Tests cover PCM preservation, layout rejection, overflow, wraparound, concurrent capture/consumption, concurrent stale-frame trimming with exact accounting, silence detection, recovery deadlines, combined queue limits, bounded resynchronization attempts, and safe reconnect eligibility. They do not capture audio.

The original XCTest suite remains in `SpatialRelayTests`. CI runs it with Xcode, the standalone sanitizer tests, static analysis, and a Release build. `Scripts/build-local.sh` builds with Command Line Tools, signs with App Sandbox and hardened runtime, and rejects a binary containing compiler coverage counters. Full Xcode is required for the XCTest command in the main README.

The first live AirPods test exposed a startup regression in the initial fork: the 350 ms limit repeatedly flushed AVFoundation before its playback clock could advance. Preparing the renderer before starting capture and using natural-rate varispeed removed that loop in the subsequent probe. Queue metadata stayed at 190–201 ms after warmup for 15 seconds, without resynchronization. That probe received silent samples, so it does not establish audible music or working spatialization. Do not treat the initial CI pass as evidence of those real-device behaviors.

Read-only discovery can be checked with:

```sh
"build/local/Spatial Relay Local.app/Contents/MacOS/SpatialRelay" --diagnostics
```

Real-device checks
------------------

1. Wear compatible AirPods, select them as the normal Mac output, and play a Spotify track.
2. Open Spatial Relay Local and click Start relay. Approve its System Audio Recording prompt yourself. The fork uses `com.srode.SpatialRelay`, separate from upstream's permission identity.
3. In the macOS Sound/AirPods menu, select Fixed, then Head Tracked for Spatial Relay Local. Confirm that both can be selected, remain selected, and audibly change the experience. Turn your head to check tracking. A menu option alone does not establish success.
4. Close the relay panel and keep listening. Reopen it and check that the queue estimate stays small and steady. The estimate excludes hardware, Bluetooth, and OS processing latency.
5. Pause Spotify for 15 seconds and resume. Check that music resumes cleanly. Silent polling is intentionally slower; resumption can take up to one extra 80 ms interval.
6. Switch to speakers. Spotify should play directly while the relay waits. Switch back to AirPods and check automatic reconnection. Stop relay while waiting should cancel further reconnection.
7. Restart Spotify and check that the changed audio process is discovered and the route rebuilt. A terminal renderer error or cleanup error should stop with a visible explanation, rather than endlessly retrying.
8. Stop and quit normally. Confirm Spotify continues playing directly. No long backlog should play after stopping or restarting.

An output interruption can cause a short skipped passage because the fork deliberately discards stale PCM. Three resyncs are allowed within 30 seconds; further backlog problems stop playback routing and restore direct output. The five-second output-recovery limit is fixed across repeated notifications.

Do not run multiple process-tap relays on Spotify at once during comparisons. A second tap can interfere with the first relay's muted capture path.
