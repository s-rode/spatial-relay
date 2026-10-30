import AVFoundation
import CoreMedia
import Foundation

private final class ProbeFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var error: String?
    func record(_ error: Error) { lock.lock(); self.error = error.localizedDescription; lock.unlock() }
    var message: String? { lock.lock(); defer { lock.unlock() }; return error }
}

/// Explicit hardware integration check. Plays a very quiet synthetic stereo
/// signal for six seconds; never creates a process tap or captures user audio.
@main
struct RendererIntegrationTests {
    static func main() throws {
        let output = try AudioHardwareClient().defaultOutputDevice()
        let capture = SRAudioCaptureBridge()
        let failure = ProbeFailure()
        let player = try SampleBufferPlayer(capture: capture, sampleRate: output.sampleRate, outputDeviceUID: output.uid) {
            failure.record($0)
        }
        let producer = DispatchQueue(label: "relay-renderer-integration-producer")
        let timer = DispatchSource.makeTimerSource(queue: producer)
        let frames = Int(output.sampleRate * 0.02)
        var position = 0
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler {
            var samples = [Float]()
            samples.reserveCapacity(frames * 2)
            for index in 0..<frames {
                // Hard upper bound: -100 dBFS. Never change system volume.
                let fade = min(1, Double(position + index) / (output.sampleRate * 0.1))
                let value = Float(sin(Double(position + index) * 2 * .pi * 440 / output.sampleRate) * fade) * 0.00001
                precondition(abs(value) <= 0.00001)
                samples.append(value)
                samples.append(value)
            }
            position += frames
            capture.debugEnqueueInterleavedFloat(samples.withUnsafeBytes { Data($0) })
        }
        player.start()
        timer.resume()
        let end = Date().addingTimeInterval(6)
        var lastTime: Double = 0
        while Date() < end, failure.message == nil {
            let status = player.bufferStatus()
            lastTime = status.playheadSeconds
            print("capture=\(capture.availableFrameCount) queued=\(status.queuedFrames) clock=\(status.playheadSeconds) rate=\(status.timebaseRate) resync=\(status.resynchronizationCount) signalFrames=\(capture.signalFrameCount)")
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        timer.setEventHandler {}
        timer.cancel()
        producer.sync {}
        if CommandLine.arguments.count > 1, let report = player.diagnosticReport() {
            try report.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        }
        player.stop()
        if let message = failure.message { print("FAIL: \(message)"); exit(1) }
        guard capture.signalFrameCount > 0, lastTime >= 3 else {
            print("FAIL: nonzero audio did not advance the playback clock")
            exit(1)
        }
        print("PASS: nonzero synthetic PCM advanced the native renderer without a relay failure")
    }
}
