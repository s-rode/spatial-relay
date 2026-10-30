import CoreAudio
import Foundation

struct RelayGeneration {
    private(set) var value: UInt64 = 0
    mutating func advance() { value &+= 1 }
    func accepts(_ token: UInt64) -> Bool { token == value }
}

enum RelayDiagnostics {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpatialRelayLocal", isDirectory: true)
            .appendingPathComponent("last-playback.json")
    }

    static func store(_ data: Data) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Reporting failure must never keep a process tap active.
            print("Could not save playback timing diagnostics: \(error.localizedDescription)")
        }
    }

    static func load() throws -> Data { try Data(contentsOf: fileURL) }
}

struct CoreAudioFailure: LocalizedError, Equatable {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "\(operation) failed (\(Self.describe(status)))."
    }

    static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw CoreAudioFailure(operation: operation, status: status)
        }
    }

    static func describe(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]

        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }),
           let code = String(bytes: bytes, encoding: .ascii) {
            return "'\(code)' / \(status)"
        }
        return String(status)
    }
}
func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}
