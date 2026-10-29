import CoreMedia
import Foundation

@main
struct PlaybackPolicyTests {
    static func main() {
        var generation = RelayGeneration()
        let old = generation.value
        generation.advance()
        precondition(!generation.accepts(old))
        precondition(generation.accepts(generation.value))
        print("PASS: a replaced pipeline rejects late failures from its predecessor")
        let start: UInt64 = 1_000_000
        var recovery = OutputRecoveryWindow()
        precondition(!recovery.contains(start))
        recovery.begin(at: start)
        // A notification storm cannot move the original deadline.
        for second in 1...8 { recovery.begin(at: start + UInt64(second) * 1_000_000_000) }
        precondition(recovery.start == start)
        precondition(recovery.contains(start + 5_000_000_000))
        precondition(!recovery.contains(start + 5_000_000_001))
        recovery.finish()
        recovery.begin(at: start + 10_000_000_000)
        precondition(recovery.contains(start + 14_000_000_000))
        print("PASS: bounded recovery across repeated notifications and a later independent recovery")

        precondition(!LivePlaybackPolicy.needsResynchronization(captured: 0, queued: 16_800, sampleRate: 48_000))
        precondition(LivePlaybackPolicy.needsResynchronization(captured: 1, queued: 16_800, sampleRate: 48_000))
        precondition(LivePlaybackPolicy.needsResynchronization(captured: 96_000, queued: 0, sampleRate: 48_000))
        // Both queues count: an empty capture ring cannot hide stale renderer PCM.
        precondition(LivePlaybackPolicy.needsResynchronization(captured: 0, queued: 96_000, sampleRate: 48_000))
        precondition(LivePlaybackPolicy.needsResynchronization(captured: 8_000, queued: 9_000, sampleRate: 48_000))
        precondition(!LivePlaybackPolicy.needsResynchronization(captured: 3_840, queued: -100, sampleRate: 48_000))
        precondition(LivePlaybackPolicy.needsResynchronization(captured: 15_436, queued: 0, sampleRate: 44_100))
        precondition(LivePlaybackPolicy.idlePollMilliseconds > LivePlaybackPolicy.activePollMilliseconds)
        precondition(!LivePlaybackPolicy.shouldUseIdlePolling(lastSignal: 1, now: 500_000_000))
        precondition(LivePlaybackPolicy.shouldUseIdlePolling(lastSignal: 1, now: 500_000_001))
        precondition(!LivePlaybackPolicy.shouldUseIdlePolling(lastSignal: 100, now: 99))
        print("PASS: 350 ms boundary, combined capture/renderer backlog, 44.1/48 kHz policies")

        var budget = ResynchronizationBudget()
        precondition(budget.record(at: 0))
        precondition(budget.record(at: 1))
        precondition(budget.record(at: 2))
        precondition(!budget.record(at: 3))
        precondition(budget.record(at: 30_000_000_000))
        precondition(!budget.record(at: 30_000_000_000))
        print("PASS: repeated backlog recovery is bounded and expires correctly")

        precondition(RelayError.outputChanged.allowsAutomaticReconnect)
        precondition(RelayError.spotifyProcessChanged.allowsAutomaticReconnect)
        precondition(!RelayError.cleanupFailed("retained callback").allowsAutomaticReconnect)
        precondition(!RelayError.rendererFailed("terminal").allowsAutomaticReconnect)
        precondition(!RelayError.captureFailed("overflow").allowsAutomaticReconnect)
        let frame = RendererRecoveryTimeline.restartFrame(
            currentTime: CMTime(value: 96_000, timescale: 48_000),
            suggestedFlushTime: CMTime(value: 120_000, timescale: 48_000),
            timescale: 48_000, fallbackFrame: 150_000
        )
        precondition(frame == 120_000)
        print("PASS: reconnect eligibility excludes unsafe retry paths; recovery keeps latest valid timestamp")
    }
}
