#if DEBUG
import CryptoKit
import Foundation
import SwiftUI
import UIKit
@_spi(Experiments) import SnowlitStorage

/// Explicit launch arguments select synthetic data under a unique Caches directory.
/// No live database or source installation participates in this process experiment.
struct StorageProcessProbeView: View {
    @ObservedObject var probe: StorageProcessProbeDelegate
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Text(probe.status)
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { probe.sceneBecameActive() }
            }
    }
}

/// The process experiment starts once from application launch, independently of
/// scene presentation. The delegate owns its task until completion/termination;
/// view disappearance must not cancel an interrupted-store reopen operation.
@MainActor
final class StorageProcessProbeDelegate: NSObject, UIApplicationDelegate, ObservableObject {
    @Published private(set) var status = "Storage process experiment"
    private var work: Task<Void, Never>?
    private var operation: StorageProbeOperation?
    private var publishedActive = false

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        guard ProcessInfo.processInfo.arguments.contains("-snowlit-probe-storage") else { return true }
        do {
            let operation = try StorageProbeOperation(arguments: ProcessInfo.processInfo.arguments)
            self.operation = operation
            try operation.publishProgress("application-launched")
            work = Task { [weak self] in
                guard let self else { return }
                defer { work = nil }
                do {
                    try await operation.execute()
                    status = "Experiment operation finished"
                } catch {
                    status = "Experiment operation failed: \(String(reflecting: type(of: error)))"
                }
            }
        } catch {
            status = "Experiment launch failed: \(String(reflecting: type(of: error)))"
            print("SNOWLIT_STORAGE_LAUNCH_FAILED type=\(String(reflecting: type(of: error)))")
        }
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) { work?.cancel() }

    func sceneBecameActive() {
        guard let operation, !publishedActive else { return }
        do {
            try operation.publishActive()
            publishedActive = true
        } catch {
            status = "Experiment scene readiness could not be recorded"
            print("SNOWLIT_STORAGE_ACTIVE_FAILED type=\(String(reflecting: type(of: error)))")
        }
    }
}

private struct StorageProbeOperation: Sendable {
    let token: UUID
    let mode: String
    let point: String
    let root: URL
    let pid: Int32

    func execute() async throws {
        do {
            try publishProgress("operation-started")
            let details = try await ProbeStorageProcess.run(mode: mode, root: root, point: point, digest: { data in
                SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }, checkpoint: { reached in
                try publish("checkpoint", ["reached": reached])
                // Synchronous checkpoint on the storage actor/writer, not the main actor.
                // A bounded wait prevents a lost supervisor leaving an infinite probe.
                Thread.sleep(forTimeInterval: 60)
                throw Failure.checkpointExpired
            }, progress: { phase in try publishProgress(phase) })
            try publish("completed", details)
        } catch {
            // Record a semantic failure separately from a missing launch/phase.
            let native = error as NSError
            try publish("failed", ["errorType": String(reflecting: type(of: error)),
                                   "errorDomain": native.domain, "errorCode": String(native.code)])
            throw error
        }
    }

    func publishProgress(_ phase: String) throws {
        try publish("progress", ["phase": phase], suffix: ".progress.json")
    }

    func publishActive() throws {
        try publish("active", [:], suffix: ".active.json")
    }

    private func publish(_ stage: String, _ details: [String: String], suffix: String = ".json") throws {
        let report = Report(token: token.uuidString, mode: mode, point: point, pid: pid, stage: stage, details: details)
        try JSONEncoder().encode(report).write(to: root.appendingPathComponent(token.uuidString + suffix), options: .atomic)
    }

    init(arguments: [String]) throws {
        guard let index = arguments.firstIndex(of: "-snowlit-probe-storage"),
              arguments.count == index + 5,
              let trial = UUID(uuidString: arguments[index + 2]),
              let token = UUID(uuidString: arguments[index + 4]) else { throw Failure.invalidArguments }
        self.token = token
        mode = arguments[index + 1]
        point = arguments[index + 3]
        pid = ProcessInfo.processInfo.processIdentifier
        let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("SnowlitStorageProcessProbes", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent(trial.uuidString, isDirectory: true)
        if mode.hasSuffix("-seed") {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
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
}
#endif
