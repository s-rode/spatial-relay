import CoreAudio
import Foundation

struct RelayDiscovery: Sendable {
    let spotifyProcesses: [AudioProcessInfo]
    let outputDevice: OutputDeviceInfo?
}

struct RelayMetrics: Sendable {
    let peakLevel: Float
    let bufferedMilliseconds: Double
    let droppedFrameCount: UInt64
    let resynchronizationCount: UInt64
    let isIdlePolling: Bool
    let diagnostic: String
}

enum RelayRouteEvent: Sendable {
    case waiting(String)
    case resumed(RelayDiscovery)
}

struct RelayRouteUpdate: Sendable {
    let revision: UInt64
    let event: RelayRouteEvent
}

final class AudioRelayCoordinator: @unchecked Sendable {
    private let hardware = AudioHardwareClient()
    private let controlQueue = DispatchQueue(label: "com.shevlfs.SpatialRelay.audio-coordinator")
    private let controlQueueKey = DispatchSpecificKey<UInt8>()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var capture: SRAudioCaptureBridge?
    private var player: SampleBufferPlayer?
    private var activeOutput: OutputDeviceInfo?
    private var activeProcessIDs = Set<AudioObjectID>()
    private var activeSampleRate: Double = 0
    private var lastCapturedFrameCount: UInt64 = 0
    private var stalledCaptureChecks = 0
    private var sampleRateMismatchStartTime: DispatchTime?

    private var isActive = false
    private var generation = RelayGeneration()
    private var healthTimer: DispatchSourceTimer?
    private var failureHandler: (@Sendable (Error) -> Void)?
    private var routeHandler: (@Sendable (RelayRouteUpdate) -> Void)?
    private var routeRevision: UInt64 = 0
    private var reconnectAttempts = 0
    private var lastWaitingMessage: String?
    private var reconnectOutputUIDs = Set<String>()

    init() {
        controlQueue.setSpecific(key: controlQueueKey, value: 1)
    }

    deinit {
        _ = stop()
    }

    func discover() throws -> RelayDiscovery {
        try performSync {
            RelayDiscovery(
                spotifyProcesses: try hardware.spotifyProcesses(),
                outputDevice: try? hardware.defaultOutputDevice()
            )
        }
    }

    @discardableResult
    func start(
        onFailure: @escaping @Sendable (Error) -> Void,
        onRouteEvent: @escaping @Sendable (RelayRouteUpdate) -> Void
    ) throws -> RelayDiscovery {
        try performSync {
            stopMonitoring()
            let discovery = try startPipeline(onFailure: onFailure)
            failureHandler = onFailure
            routeHandler = onRouteEvent
            routeRevision = 0
            reconnectAttempts = 0
            lastWaitingMessage = nil
            if let output = discovery.outputDevice { reconnectOutputUIDs.insert(output.uid) }
            let timer = DispatchSource.makeTimerSource(queue: controlQueue)
            timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.checkHealthAndReconnect() }
            healthTimer = timer
            timer.resume()
            return discovery
        }
    }

    private func startPipeline(onFailure: @escaping @Sendable (Error) -> Void) throws -> RelayDiscovery {
        if let cleanupFailure = stopPipeline() {
            throw cleanupFailure
        }

        #if !arch(arm64)
        throw RelayError.unsupportedMac
        #endif

        let output = try hardware.defaultOutputDevice()
        let processes = try hardware.spotifyProcesses()
        guard !processes.isEmpty else {
            throw RelayError.spotifyNotRunning
        }

        do {
            tapID = try hardware.createSpotifyTap(processes: processes, outputDevice: output)
            let format = try hardware.tapFormat(tapID)
            guard abs(format.mSampleRate - output.sampleRate) <= 0.5 else {
                throw RelayError.unsupportedTapFormat(
                    "the tap is \(Int(format.mSampleRate.rounded())) Hz but the output is \(Int(output.sampleRate.rounded())) Hz"
                )
            }
            let uid = try hardware.tapUID(tapID)
            aggregateID = try hardware.createAggregateDevice(tapUID: uid)

            let capture = SRAudioCaptureBridge()
            let pipelineToken = generation.value
            let player = try SampleBufferPlayer(
                capture: capture,
                sampleRate: format.mSampleRate,
                outputDeviceUID: output.uid
            ) { [weak self] error in
                guard let self else { return }
                self.controlQueue.async { [weak self] in
                    guard let self, self.isActive, self.generation.accepts(pipelineToken) else { return }
                    let routeChanged = self.outputRouteChanged()
                    // Flush playback before stopping the tap, then immediately release
                    // mutedWhenTapped so Spotify's direct output is restored.
                    let cleanupFailure = self.stopPipeline()
                    if routeChanged, cleanupFailure == nil {
                        let reason = RelayError.outputChanged.localizedDescription
                        self.reconnectAttempts = 0
                        self.emitRouteEvent(.waiting(reason))
                        return
                    }
                    self.stopMonitoring()
                    DispatchQueue.main.async {
                        onFailure(cleanupFailure ?? error)
                    }
                }
            }

            self.capture = capture
            self.player = player

            // Prepare AVFoundation before muting/capturing Spotify, so device
            // setup cannot accumulate old PCM before the first pump runs.
            player.start()
            do {
                try capture.startCapturingDevice(aggregateID, format: format)
            } catch {
                throw RelayError.captureFailed(error.localizedDescription)
            }
            activeOutput = output
            activeProcessIDs = Set(processes.map(\.id))
            activeSampleRate = format.mSampleRate
            lastCapturedFrameCount = capture.capturedFrameCount
            stalledCaptureChecks = 0
            sampleRateMismatchStartTime = nil
            isActive = true

            return RelayDiscovery(spotifyProcesses: processes, outputDevice: output)
        } catch {
            let startupFailure = error
            if let cleanupFailure = tearDownPipeline() {
                throw cleanupFailure
            }
            throw startupFailure
        }
    }

    @discardableResult
    func stop() -> Error? {
        performSync {
            stopMonitoring()
            return stopPipeline()
        }
    }

    private func stopMonitoring() {
        healthTimer?.setEventHandler {}
        healthTimer?.cancel()
        healthTimer = nil
        failureHandler = nil
        routeHandler = nil
        lastWaitingMessage = nil
        reconnectOutputUIDs.removeAll()
    }

    /// Runs off the main actor, including while the panel is hidden or AppKit
    /// is busy. Direct Spotify output is restored before requesting any retry.
    private func checkHealthAndReconnect() {
        if isActive {
            guard let failure = healthFailureLocked() else { return }
            let canReconnect = (failure as? RelayError)?.allowsAutomaticReconnect == true
            let cleanupFailure = stopPipeline()
            if let cleanupFailure {
                finishWithFailure(cleanupFailure)
                return
            }
            guard canReconnect else {
                finishWithFailure(failure)
                return
            }
            emitRouteEvent(.waiting(failure.localizedDescription))
            reconnectAttempts = 0
        }

        guard let onFailure = failureHandler else { return }
        do {
            let discovery = try discover()
            let reason: String?
            if discovery.outputDevice.map({ $0.isLikelySpatialAudioHeadphones || reconnectOutputUIDs.contains($0.uid) }) != true {
                reason = "Waiting for AirPods. Spotify plays directly; Stop relay cancels reconnection."
            } else if discovery.spotifyProcesses.isEmpty {
                reason = "Waiting for Spotify. Stop relay cancels reconnection."
            } else {
                reason = nil
            }
            if let reason {
                if reason != lastWaitingMessage { emitRouteEvent(.waiting(reason)) }
                lastWaitingMessage = reason
                return
            }
            let resumed = try startPipeline(onFailure: onFailure)
            if let output = resumed.outputDevice { reconnectOutputUIDs.insert(output.uid) }
            lastWaitingMessage = nil
            reconnectAttempts = 0
            emitRouteEvent(.resumed(resumed))
        } catch {
            reconnectAttempts += 1
            if reconnectAttempts >= 3 || (error as? RelayError).map({
                if case .cleanupFailed = $0 { return true }; return false
            }) == true {
                finishWithFailure(error)
            }
        }
    }

    private func finishWithFailure(_ error: Error) {
        let callback = failureHandler
        stopMonitoring()
        callback?(error)
    }

    private func emitRouteEvent(_ event: RelayRouteEvent) {
        routeRevision += 1
        routeHandler?(RelayRouteUpdate(revision: routeRevision, event: event))
    }

    private func outputRouteChanged() -> Bool {
        guard let activeOutput else { return false }
        guard let output = try? hardware.defaultOutputDevice() else { return true }
        return output.id != activeOutput.id || output.uid != activeOutput.uid ||
            abs(output.sampleRate - activeOutput.sampleRate) > 0.5
    }

    private func stopPipeline() -> Error? {
        generation.advance()
        isActive = false
        return tearDownPipeline()
    }

    func metrics() -> RelayMetrics {
        performSync {
            guard let capture, activeSampleRate > 0 else {
                return RelayMetrics(peakLevel: 0, bufferedMilliseconds: 0, droppedFrameCount: 0, resynchronizationCount: 0, isIdlePolling: false, diagnostic: "stopped")
            }
            let playback = player?.bufferStatus()
            let buffered = (Double(capture.availableFrameCount) + Double(playback?.queuedFrames ?? 0)) / activeSampleRate * 1_000
            return RelayMetrics(
                peakLevel: capture.peakLevel,
                bufferedMilliseconds: buffered,
                droppedFrameCount: capture.droppedFrameCount,
                resynchronizationCount: playback?.resynchronizationCount ?? 0,
                isIdlePolling: playback?.isIdlePolling ?? false,
                diagnostic: "capture=\(capture.availableFrameCount) renderer=\(playback?.queuedFrames ?? 0) rate=\(playback?.timebaseRate ?? 0) playhead=\(playback?.playheadSeconds ?? 0) sufficient=\(playback?.hasSufficientData ?? false)"
            )
        }
    }

    /// The relay safely stops on route/process replacement. Restarting builds
    /// a new device-scoped tap with the new stream format and avoids consuming muted audio
    /// through a stale renderer.
    func healthFailure() -> Error? {
        performSync {
            healthFailureLocked()
        }
    }

    private func healthFailureLocked() -> Error? {
        guard isActive, let activeOutput else { return nil }
        let isWithinOutputGrace = player?.isWithinOutputReconfigurationGracePeriod() == true

        do {
            let output = try hardware.defaultOutputDevice()
            if output.id != activeOutput.id || output.uid != activeOutput.uid {
                if !isWithinOutputGrace {
                    return RelayError.outputChanged
                }
            }

            if abs(output.sampleRate - activeOutput.sampleRate) > 0.5 {
                if let sampleRateMismatchStartTime {
                    if !isWithinOutputGrace,
                       elapsedMilliseconds(since: sampleRateMismatchStartTime) > OutputReconfigurationGrace.durationMilliseconds {
                        return RelayError.outputChanged
                    }
                } else {
                    sampleRateMismatchStartTime = .now()
                }
            } else {
                sampleRateMismatchStartTime = nil
            }

            guard capture?.isCapturing == true else {
                return outputRouteChanged() ? RelayError.outputChanged : RelayError.captureFailed("the Core Audio callback stopped")
            }

            let processes = try hardware.spotifyProcesses()
            let processIDs = Set(processes.map(\.id))
            if activeProcessIDs.isDisjoint(with: processIDs) {
                return RelayError.spotifyProcessChanged
            }

            let runningOutputIDs = Set(processes.filter(\.isRunningOutput).map(\.id))
            if !runningOutputIDs.isEmpty && !runningOutputIDs.isSubset(of: activeProcessIDs) {
                return RelayError.spotifyProcessChanged
            }

            if !runningOutputIDs.isEmpty, let capture {
                let capturedFrameCount = capture.capturedFrameCount
                if isWithinOutputGrace {
                    // A spatial-output transition can briefly suspend the HAL
                    // callback. Begin stall detection after the bounded grace,
                    // rather than spending the grace period's entire budget.
                    lastCapturedFrameCount = capturedFrameCount
                    stalledCaptureChecks = 0
                } else if capturedFrameCount == lastCapturedFrameCount {
                    stalledCaptureChecks += 1
                } else {
                    lastCapturedFrameCount = capturedFrameCount
                    stalledCaptureChecks = 0
                }
                if stalledCaptureChecks >= 6 {
                    return RelayError.captureFailed("the Core Audio tap stopped delivering frames")
                }
            } else {
                lastCapturedFrameCount = capture?.capturedFrameCount ?? 0
                stalledCaptureChecks = 0
            }
        } catch {
            if isWithinOutputGrace {
                return nil
            }
            if outputRouteChanged() { return RelayError.outputChanged }
            return error
        }
        return nil
    }

    private func tearDownPipeline() -> Error? {
        // Order matters: discard queued relay audio, stop reading (which un-mutes
        // Spotify), then destroy the aggregate device and process tap.
        var cleanupProblems: [String] = []

        player?.stop()
        player = nil

        var callbackWasDestroyed = true
        if let capture {
            do {
                try capture.stop()
            } catch {
                cleanupProblems.append(error.localizedDescription)
                callbackWasDestroyed = !capture.isCapturing
                let unmuteStatus = hardware.unmuteTap(tapID)
                if unmuteStatus != noErr {
                    cleanupProblems.append(
                        "Unmuting the process tap failed (\(CoreAudioFailure.describe(unmuteStatus)))"
                    )
                }
            }
        }

        // Keep the bridge and its HAL objects alive when its IOProc is still
        // registered. A later Stop (or app teardown) can safely retry it.
        if callbackWasDestroyed {
            self.capture = nil

            let aggregateStatus = hardware.destroyAggregateDevice(aggregateID)
            if aggregateStatus == noErr {
                aggregateID = kAudioObjectUnknown
            } else {
                cleanupProblems.append(
                    "Destroying the private tap device failed (\(CoreAudioFailure.describe(aggregateStatus)))"
                )
            }

            // Do not remove a tap while an aggregate device still references it.
            if aggregateID == kAudioObjectUnknown {
                let tapStatus = hardware.destroyTap(tapID)
                if tapStatus == noErr {
                    tapID = kAudioObjectUnknown
                } else {
                    cleanupProblems.append(
                        "Destroying the process tap failed (\(CoreAudioFailure.describe(tapStatus)))"
                    )
                    let unmuteStatus = hardware.unmuteTap(tapID)
                    if unmuteStatus != noErr {
                        cleanupProblems.append(
                            "Unmuting the retained process tap failed (\(CoreAudioFailure.describe(unmuteStatus)))"
                        )
                    }
                }
            } else {
                _ = hardware.unmuteTap(tapID)
            }
        }

        activeOutput = nil
        activeProcessIDs.removeAll()
        activeSampleRate = 0
        lastCapturedFrameCount = 0
        stalledCaptureChecks = 0
        sampleRateMismatchStartTime = nil

        guard !cleanupProblems.isEmpty else { return nil }
        return RelayError.cleanupFailed(cleanupProblems.joined(separator: "; "))
    }

    private func performSync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: controlQueueKey) != nil {
            return try work()
        }
        return try controlQueue.sync(execute: work)
    }

    private func elapsedMilliseconds(since time: DispatchTime) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let then = time.uptimeNanoseconds
        guard now >= then else { return 0 }
        return (now - then) / 1_000_000
    }
}
