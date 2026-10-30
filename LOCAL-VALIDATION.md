Local fork validation
=====================

This fork preserves the original Apple Spatialize Stereo playback path. It changes queue recovery, background scheduling, lifecycle monitoring, and packaging. It does not certify that every macOS/AirPods combination permits Fixed or Head Tracked playback.

Automated checks
----------------

Run `Scripts/test-core.sh` for device-free tests under AddressSanitizer, with UndefinedBehaviorSanitizer also enabled for the C++ capture tests. Tests cover PCM preservation, layout rejection, overflow, wraparound, concurrent capture/consumption, concurrent stale-frame trimming with exact accounting, silence detection, recovery deadlines, combined queue limits, bounded resynchronization attempts, and safe reconnect eligibility. They do not capture audio.

The original XCTest suite remains in `SpatialRelayTests`. CI runs it with Xcode, the standalone sanitizer tests, static analysis, and a Release build. `Scripts/build-local.sh` builds with Command Line Tools, signs with App Sandbox and hardened runtime, and rejects a binary containing compiler coverage counters. Full Xcode is required for the XCTest command in the main README.

The first live AirPods test exposed a startup regression in the initial fork: the 350 ms limit repeatedly flushed AVFoundation before its playback clock could advance. Preparing the renderer before starting capture and using natural-rate varispeed removed that loop in the subsequent probe. Queue metadata stayed at 190–201 ms after warmup for 15 seconds, without resynchronization. That probe received silent samples and did not establish audible music or working spatialization. A later music test still hit the original guard. Version 0.3.1 therefore replaces the combined fixed limit with separate capture trimming and growth monitoring above the native renderer baseline. The regression test allows a renderer to accumulate a full second of priming data before its clock starts. Do not treat the initial CI pass as evidence of real-device behavior.

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

An output interruption can cause a short skipped passage because the fork deliberately discards stale PCM. Captured backlog above 350 ms is trimmed independently of renderer priming. After playback starts, renderer growth above its lowest observed queue is allowed a further 350 ms before resync. A three-second renderer ceiling and five-second startup/recovery timeouts bound stalled startup. Three resyncs are allowed within 30 seconds; further backlog problems stop playback routing and restore direct output.

Do not run multiple process-tap relays on Spotify at once during comparisons. A second tap can interfere with the first relay's muted capture path.

Observed on 30 October 2026
---------------------------

- The generated nonzero-signal test passed on built-in speakers and on connected AirPods Pro. The revised AirPods Pro run used a hard -100 dBFS amplitude limit and no system-volume changes; it transferred 291,840 signal frames, advanced the native playback clock, and had zero resyncs over six seconds. Recent relay queue estimates were 301–315 ms. This did not tap Spotify.
- The user confirmed that version 0.3.1 continues Spotify playback with a moving green input meter. This establishes an actual nonzero Spotify relay path, beyond the earlier silent probe. Fixed/Head Tracked and route-transition checks remain separate.
- Native UI automation timed out, so the physical listening checks require the user. No success is inferred from a selectable menu option alone.
