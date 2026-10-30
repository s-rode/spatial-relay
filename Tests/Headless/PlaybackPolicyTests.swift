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

        var monitor = LiveBufferMonitor()
        // Regression: a renderer requiring one second to prime must be able to
        // reach that threshold, rather than being flushed every 350 ms.
        for step in 1...100 {
            precondition(monitor.action(captured: 0, queued: Int64(step * 480), sampleRate: 48_000, playbackHasAdvanced: false) == .none)
        }
        for _ in 1...100 {
            precondition(monitor.action(captured: 0, queued: 48_000, sampleRate: 48_000, playbackHasAdvanced: true) == .none)
        }
        precondition(monitor.action(captured: 0, queued: 64_800, sampleRate: 48_000, playbackHasAdvanced: true) == .none)
        precondition(monitor.action(captured: 0, queued: 64_801, sampleRate: 48_000, playbackHasAdvanced: true) == .resetRenderer)
        var captureBacklog = LiveBufferMonitor()
        precondition(captureBacklog.action(captured: 16_800, queued: 48_000, sampleRate: 48_000, playbackHasAdvanced: false) == .none)
        precondition(captureBacklog.action(captured: 16_801, queued: 48_000, sampleRate: 48_000, playbackHasAdvanced: false) == .trimCapture)
        precondition(captureBacklog.baselineRendererFrames == nil)
        precondition(captureBacklog.action(captured: 0, queued: 144_001, sampleRate: 48_000, playbackHasAdvanced: false) == .stop)
        var rate441 = LiveBufferMonitor()
        precondition(rate441.action(captured: 15_436, queued: 0, sampleRate: 44_100, playbackHasAdvanced: false) == .trimCapture)
        print("PASS: native startup priming, stable native latency, excess growth, capture trimming and hard renderer bound")
        precondition(LivePlaybackPolicy.idlePollMilliseconds > LivePlaybackPolicy.activePollMilliseconds)
        precondition(!LivePlaybackPolicy.shouldUseIdlePolling(lastSignal: 1, now: 500_000_000))
        precondition(LivePlaybackPolicy.shouldUseIdlePolling(lastSignal: 1, now: 500_000_001))
        precondition(!LivePlaybackPolicy.shouldUseIdlePolling(lastSignal: 100, now: 99))
        print("PASS: silent polling boundaries and backwards-clock protection")

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
