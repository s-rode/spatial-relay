import AppKit
import SwiftUI

@MainActor
private final class SpatialRelayApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: RelayViewModel?
    private var terminationReplyIsPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel else { return .terminateNow }
        guard !viewModel.isReadyToTerminate else { return .terminateNow }

        if !terminationReplyIsPending {
            terminationReplyIsPending = true
            viewModel.prepareForTermination {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

@main
struct SpatialRelayApp: App {
    @NSApplicationDelegateAdaptor(SpatialRelayApplicationDelegate.self) private var appDelegate
    @StateObject private var viewModel: RelayViewModel

    init() {
        if CommandLine.arguments.contains("--last-run") {
            do {
                let data = try RelayDiagnostics.load()
                print(String(decoding: data, as: UTF8.self))
                exit(0)
            } catch {
                print("No playback diagnostic report is available: \(error.localizedDescription)")
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--diagnostics") {
            // Read-only diagnostics: never creates a tap or starts a renderer.
            print("Spatial Relay Local \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown")")
            print("Identity: \(Bundle.main.bundleIdentifier ?? "unknown")")
            do {
                let discovery = try AudioRelayCoordinator().discover()
                print("Spotify audio processes: \(discovery.spotifyProcesses.count)")
                if let output = discovery.outputDevice {
                    print("Output: \(output.name), \(output.sampleRate) Hz")
                } else {
                    print("Output: unavailable")
                }
                print("No audio capture was started. Spatial Audio availability requires a playback test.")
                exit(0)
            } catch {
                print("Discovery failed: \(error.localizedDescription)")
                exit(1)
            }
        }
        let otherCopies = NSRunningApplication.runningApplications(withBundleIdentifier: "com.srode.SpatialRelay")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
        if CommandLine.arguments.contains("--playback-test") {
            guard otherCopies.isEmpty else {
                print("Quit other relay copies from their menu-bar menus first.")
                exit(1)
            }
            let relay = AudioRelayCoordinator()
            do {
                _ = try relay.start(
                    onFailure: { print("PLAYBACK FAILURE: \($0.localizedDescription)") },
                    onRouteEvent: { print("Route update: \($0.revision)") }
                )
                let end = Date().addingTimeInterval(15)
                while Date() < end {
                    let metrics = relay.metrics()
                    print("queue=\(Int(metrics.bufferedMilliseconds))ms resync=\(metrics.resynchronizationCount) idle=\(metrics.isIdlePolling) \(metrics.diagnostic)")
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                }
                if let error = relay.stop() { print("STOP FAILURE: \(error.localizedDescription)") }
                print("Playback probe ended; direct Spotify output restored.")
                exit(0)
            } catch {
                print("Playback probe could not start: \(error.localizedDescription)")
                exit(1)
            }
        }
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !isTestHost, let existing = otherCopies.first {
            existing.activate()
            exit(0)
        }
        let viewModel = RelayViewModel()
        _viewModel = StateObject(wrappedValue: viewModel)
        appDelegate.viewModel = viewModel
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(viewModel: viewModel)
                .frame(width: 500, height: 540)
        } label: {
            Image(systemName: viewModel.menuBarSymbolName)
                .symbolRenderingMode(.monochrome)
                .accessibilityLabel(viewModel.menuBarStatusText)
        }
        .menuBarExtraStyle(.window)
    }
}
