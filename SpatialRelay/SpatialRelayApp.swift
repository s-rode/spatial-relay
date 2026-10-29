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
