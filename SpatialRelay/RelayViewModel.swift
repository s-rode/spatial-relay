import AppKit
import Combine
import Foundation

@MainActor
final class RelayViewModel: ObservableObject {
    enum CheckState { case ready, warning, unavailable }
    struct Message: Equatable {
        enum Kind { case info, warning, error }
        let kind: Kind
        let text: String
    }

    @Published private(set) var spotifyDetail = "Looking for Spotify…"
    @Published private(set) var spotifyState: CheckState = .warning
    @Published private(set) var outputDetail = "Looking for the current output…"
    @Published private(set) var outputState: CheckState = .warning
    @Published private(set) var message: Message?
    @Published private(set) var isRelaying = false
    @Published private(set) var isRelayRequested = false
    @Published private(set) var isBusy = false
    @Published private(set) var meterLevel: CGFloat = 0
    @Published private(set) var latencyLabel = "80 ms startup buffer"

    private let coordinator = AudioRelayCoordinator()
    private let startupQueue = DispatchQueue(label: "com.srode.SpatialRelay.control", qos: .userInitiated)
    private var discovery: RelayDiscovery?
    private var meterTimer: DispatchSourceTimer?
    private var panelIsVisible = false
    private var relaySessionID: UUID?
    private var lastRouteRevision: UInt64 = 0
    private var terminationCleanupIsRunning = false
    private var terminationCompletions: [() -> Void] = []
    private(set) var isReadyToTerminate = false

    deinit {
        meterTimer?.cancel()
        coordinator.stop()
    }

    var canToggleRelay: Bool {
        if isRelayRequested { return !isBusy }
        return !isBusy && discovery?.outputDevice != nil && !(discovery?.spotifyProcesses.isEmpty ?? true)
    }

    var menuBarSymbolName: String {
        if isBusy { return "ellipsis.circle" }
        if isRelaying { return "waveform.circle.fill" }
        if isRelayRequested { return "pause.circle" }
        if message?.kind == .error { return "exclamationmark.triangle.fill" }
        return "waveform.circle"
    }

    var menuBarStatusText: String {
        if isBusy { return "Spatial Relay is changing audio state" }
        if isRelaying { return "Spatial Relay is active" }
        if isRelayRequested { return "Spatial Relay is waiting to reconnect" }
        if message?.kind == .error { return "Spatial Relay needs attention" }
        return "Spatial Relay is stopped"
    }

    func setPanelVisible(_ visible: Bool) {
        panelIsVisible = visible
        updateMetering()
        if visible { refresh() }
    }

    func refresh() {
        guard !isRelayRequested, !isBusy else { return }
        fetchDiscovery(preservingMessage: false)
    }

    private func fetchDiscovery(preservingMessage: Bool) {
        let coordinator = coordinator
        startupQueue.async { [weak self] in
            let result = Result { try coordinator.discover() }
            Task { @MainActor [weak self] in
                guard let self, !self.isRelayRequested, !self.isBusy else { return }
                switch result {
                case .success(let discovery):
                    self.discovery = discovery
                    self.apply(discovery)
                    if !preservingMessage { self.message = nil }
                case .failure(let error):
                    self.discovery = nil
                    self.spotifyDetail = "Unable to inspect audio processes"
                    self.spotifyState = .unavailable
                    self.outputDetail = "Unable to inspect the current output"
                    self.outputState = .unavailable
                    if !preservingMessage { self.message = Message(kind: .error, text: error.localizedDescription) }
                }
            }
        }
    }

    func toggleRelay() {
        guard !isBusy else { return }
        if isRelayRequested { stopRelay() } else { startRelay() }
    }

    func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") else {
            message = Message(kind: .error, text: "Spotify is not installed in a location macOS can find.")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                MainActor.assumeIsolated {
                    if let error { self?.message = Message(kind: .error, text: error.localizedDescription) }
                    else { self?.refresh() }
                }
            }
        }
    }

    func prepareForTermination(completion: @escaping () -> Void) {
        if isReadyToTerminate { completion(); return }
        terminationCompletions.append(completion)
        guard !terminationCleanupIsRunning else { return }
        terminationCleanupIsRunning = true
        relaySessionID = nil
        isRelayRequested = false
        isRelaying = false
        isBusy = true
        updateMetering()
        let coordinator = coordinator
        startupQueue.async { [weak self] in
            _ = coordinator.stop()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isBusy = false
                self.isReadyToTerminate = true
                self.terminationCleanupIsRunning = false
                let callbacks = self.terminationCompletions
                self.terminationCompletions.removeAll()
                callbacks.forEach { $0() }
            }
        }
    }

    func quitApplication() { NSApplication.shared.terminate(nil) }

    private func startRelay() {
        guard canToggleRelay else { return }
        isBusy = true
        isRelayRequested = true
        message = nil
        let sessionID = UUID()
        relaySessionID = sessionID
        lastRouteRevision = 0
        let coordinator = coordinator
        startupQueue.async { [weak self] in
            let result = Result {
                try coordinator.start(
                    onFailure: { [weak self] error in
                        Task { @MainActor [weak self] in
                            guard let self, self.relaySessionID == sessionID else { return }
                            self.handlePipelineFailure(error)
                        }
                    },
                    onRouteEvent: { [weak self] update in
                        Task { @MainActor [weak self] in
                            guard let self, self.relaySessionID == sessionID else { return }
                            guard update.revision > self.lastRouteRevision else { return }
                            self.lastRouteRevision = update.revision
                            switch update.event {
                            case .waiting(let reason):
                                self.isRelaying = false
                                self.message = Message(kind: .info, text: reason)
                                self.updateMetering()
                            case .resumed(let discovery):
                                self.showActiveRelay(discovery, reconnected: true)
                            }
                        }
                    }
                )
            }
            Task { @MainActor [weak self] in
                guard let self, self.relaySessionID == sessionID else { return }
                self.isBusy = false
                switch result {
                case .success(let discovery):
                    if self.lastRouteRevision == 0 { self.showActiveRelay(discovery, reconnected: false) }
                case .failure(let error): self.handlePipelineFailure(error)
                }
            }
        }
    }

    private func showActiveRelay(_ discovery: RelayDiscovery, reconnected: Bool) {
        self.discovery = discovery
        apply(discovery)
        isRelaying = true
        isBusy = false
        if let output = discovery.outputDevice, !output.isLikelySpatialAudioHeadphones {
            message = Message(kind: .warning, text: "Relay active on \(output.name). Spatial Audio requires compatible headphones.")
        } else {
            message = Message(kind: .info, text: "\(reconnected ? "Relay reconnected." : "Relay active.") Choose Fixed or Head Tracked for Spatial Relay in the macOS Sound menu. Availability depends on macOS and your AirPods.")
        }
        updateMetering()
    }

    private func stopRelay() {
        relaySessionID = nil
        isRelayRequested = false
        isRelaying = false
        isBusy = true
        updateMetering()
        let coordinator = coordinator
        startupQueue.async { [weak self] in
            let error = coordinator.stop()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isBusy = false
                self.message = error.map { Message(kind: .error, text: $0.localizedDescription) }
                    ?? Message(kind: .info, text: "Relay stopped. Spotify is playing directly again.")
                self.fetchDiscovery(preservingMessage: true)
            }
        }
    }

    private func handlePipelineFailure(_ error: Error) {
        relaySessionID = nil
        isRelayRequested = false
        isRelaying = false
        isBusy = false
        message = Message(kind: .error, text: startFailureMessage(error))
        updateMetering()
        fetchDiscovery(preservingMessage: true)
    }

    private func updateMetering() {
        meterTimer?.setEventHandler {}
        meterTimer?.cancel()
        meterTimer = nil
        meterLevel = 0
        guard panelIsVisible, isRelaying, let sessionID = relaySessionID else { return }
        let coordinator = coordinator
        let timer = DispatchSource.makeTimerSource(queue: startupQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(120), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            let metrics = coordinator.metrics()
            Task { @MainActor [weak self] in
                guard let self, self.panelIsVisible, self.isRelaying, self.relaySessionID == sessionID else { return }
                let peak = CGFloat(pow(max(0, min(1, metrics.peakLevel)), 0.45))
                self.meterLevel = max(peak, self.meterLevel * 0.72)
                self.latencyLabel = "\(Int(metrics.bufferedMilliseconds.rounded())) ms queued"
                    + (metrics.resynchronizationCount > 0 ? " · \(metrics.resynchronizationCount) resync" : "")
            }
        }
        meterTimer = timer
        timer.resume()
    }

    private func apply(_ discovery: RelayDiscovery) {
        if discovery.spotifyProcesses.isEmpty {
            spotifyDetail = "Open Spotify and start playback"
            spotifyState = .unavailable
        } else {
            let active = discovery.spotifyProcesses.contains(where: \.isRunningOutput)
            spotifyDetail = active ? "Audio stream detected" : "Connected; waiting for playback"
            spotifyState = active ? .ready : .warning
        }
        if let output = discovery.outputDevice {
            outputDetail = "\(output.name) · \(Int(output.sampleRate.rounded())) Hz"
            outputState = output.isLikelySpatialAudioHeadphones ? .ready : .warning
        } else {
            outputDetail = "No default output device"
            outputState = .unavailable
        }
    }

    private func startFailureMessage(_ error: Error) -> String {
        let description = error.localizedDescription
        if description.localizedCaseInsensitiveContains("permission") ||
            description.localizedCaseInsensitiveContains("denied") ||
            description.localizedCaseInsensitiveContains("operation not permitted") ||
            description.localizedCaseInsensitiveContains("'perm'") ||
            description.contains("560492391") || description.localizedCaseInsensitiveContains("!hog") {
            return "\(description) Allow Spatial Relay in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch it."
        }
        return description
    }
}
