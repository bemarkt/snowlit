#if DEBUG
import CryptoKit
import Foundation
import SwiftUI
@_spi(Experiments) import SnowlitStorage

/// Explicit launch arguments select synthetic data under a unique Caches directory.
/// No live database or source installation participates in this process experiment.
struct StorageProcessProbeView: View {
    @State private var status = "Storage process experiment"

    var body: some View {
        Text(status).task {
            do {
                try await execute()
                status = "Experiment operation finished"
            } catch {
                status = "Experiment operation failed: \(String(reflecting: type(of: error)))"
            }
        }
    }

    private enum Failure: Error { case invalidArguments, checkpointExpired }

    private struct Report: Encodable, Sendable {
        let token: String
        let mode: String
        let point: String
        let pid: Int32
        let stage: String
        let details: [String: String]
    }

    private func execute() async throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-snowlit-probe-storage"),
              arguments.count == index + 5,
              let trial = UUID(uuidString: arguments[index + 2]),
              let token = UUID(uuidString: arguments[index + 4]) else { throw Failure.invalidArguments }
        let mode = arguments[index + 1]
        let point = arguments[index + 3]
        let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("SnowlitStorageProcessProbes", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.appendingPathComponent(trial.uuidString, isDirectory: true)
        if mode.hasSuffix("-seed") {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        let reportURL = root.appendingPathComponent(token.uuidString + ".json")
        let pid = ProcessInfo.processInfo.processIdentifier
        let publish: @Sendable (String, [String: String]) throws -> Void = { stage, details in
            let report = Report(token: token.uuidString, mode: mode, point: point, pid: pid,
                                stage: stage, details: details)
            try JSONEncoder().encode(report).write(to: reportURL, options: .atomic)
        }
        do {
            let details = try await ProbeStorageProcess.run(mode: mode, root: root, point: point, digest: { data in
                SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }, checkpoint: { reached in
                try publish("checkpoint", ["reached": reached])
                // Synchronous checkpoint on the storage actor/writer, not the main actor.
                // A bounded wait prevents a lost supervisor leaving an infinite probe.
                Thread.sleep(forTimeInterval: 60)
                throw Failure.checkpointExpired
            })
            try publish("completed", details)
        } catch {
            try publish("failed", ["errorType": String(reflecting: type(of: error))])
            throw error
        }
    }
}
#endif
