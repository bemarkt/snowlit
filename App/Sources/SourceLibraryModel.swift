import Foundation
import Observation
import SnowlitCore
import SnowlitStorage
import YingxueKit

@MainActor
@Observable
final class SourceLibraryModel {
    struct SavedImport: Identifiable {
        let receipt: SourceImportRecord
        let script: SourceScriptSnapshot
        let manifest: YingxueWire.Manifest
        var id: UUID { receipt.id }
        init(receipt: SourceImportRecord, script: SourceScriptSnapshot) throws {
            self.receipt = receipt; self.script = script
            manifest = try SourceFileHeader(bytes: script.bytes).manifest
        }
    }

    struct Review: Identifiable {
        let id = UUID()
        let receipt: SourceImportRecord
        let script: SourceScriptSnapshot
        let manifest: YingxueWire.Manifest
        let existing: SourceInstallationSnapshot?
        let upgrade: SourceUpgradeAssessment?
        let retainedBooks: Int
    }

    struct Problem: Identifiable {
        let id = UUID()
        let message: String
    }

    private(set) var imports: [SavedImport] = []
    private(set) var installations: [SourceInstallationSnapshot] = []
    private(set) var review: Review?
    private(set) var isLoading = false
    private(set) var isInspecting = false
    private(set) var isSaving = false
    private(set) var problem: Problem?
    private(set) var savedName: String?

    @ObservationIgnored private let openLibrary: @Sendable () async throws -> LibraryDatabase
    @ObservationIgnored private let inspect: @MainActor (String, [String]) async throws -> Data
    @ObservationIgnored private let digest: SourceScriptSnapshot.Digest
    @ObservationIgnored private let readFile: @Sendable (URL) async throws -> Data
    @ObservationIgnored private var inspectionID: UUID?
    @ObservationIgnored private var refreshID: UUID?

    init(openLibrary: @escaping @Sendable () async throws -> LibraryDatabase,
         inspect: @escaping @MainActor (String, [String]) async throws -> Data,
         digest: @escaping SourceScriptSnapshot.Digest,
         readFile: @escaping @Sendable (URL) async throws -> Data) {
        self.openLibrary = openLibrary; self.inspect = inspect; self.digest = digest; self.readFile = readFile
    }

    func refresh() async {
        let attempt = UUID()
        refreshID = attempt
        isLoading = true
        defer { if refreshID == attempt { isLoading = false } }
        do {
            let library = try await openLibrary()
            let receipts = try await library.sourceImports()
            var loaded: [SavedImport] = []
            for receipt in receipts {
                try Task.checkCancellation()
                guard let script = try await library.sourceScript(sha256: receipt.scriptSHA256, digest: digest) else {
                    throw SourceInstallationFailure.missingImport
                }
                loaded.append(try .init(receipt: receipt, script: script))
            }
            let installed = try await library.sourceInstallations()
            try Task.checkCancellation()
            guard refreshID == attempt else { return }
            imports = loaded.sorted { $0.receipt.importedAt > $1.receipt.importedAt }
            installations = installed
        } catch {
            guard refreshID == attempt, !(error is CancellationError), !Task.isCancelled else { return }
            problem = .init(message: "暂时无法读取书源，请重试。已有文件会保留。")
        }
    }

    /// The selected bytes remain in memory until an explicit save. Static
    /// acceptance does not activate a script or reconnect retained local books.
    func preview(bytes: Data, fileName: String) async {
        guard !isSaving else { return }
        let attempt = beginInspection()
        await prepare(bytes: bytes, fileName: fileName, attempt: attempt)
    }

    func previewFile(_ url: URL) async {
        guard !isSaving else { return }
        let attempt = beginInspection()
        do {
            let bytes = try await readFile(url)
            try Task.checkCancellation()
            guard inspectionID == attempt else { return }
            await prepare(bytes: bytes, fileName: url.lastPathComponent, attempt: attempt)
        } catch {
            guard inspectionID == attempt else { return }
            isInspecting = false
            if !(error is CancellationError), !Task.isCancelled { fileSelectionFailed() }
        }
    }

    private func beginInspection() -> UUID {
        let attempt = UUID()
        inspectionID = attempt
        review = nil; problem = nil; savedName = nil; isInspecting = true
        return attempt
    }

    private func prepare(bytes: Data, fileName: String, attempt: UUID) async {
        defer { if inspectionID == attempt { isInspecting = false } }
        do {
            let preview = try SourceImportPreview(bytes: bytes)
            let library = try await openLibrary()
            let installed = try await library.sourceInstallations()
            let existing = installed.first {
                $0.metadata.sourceID.utf8.elementsEqual(preview.header.manifest.sourceID.utf8)
            }
            let upgrade: SourceUpgradeAssessment?
            if let existing {
                guard let current = try await library.sourceScript(sha256: existing.scriptSHA256, digest: digest) else {
                    throw SourceInstallationFailure.missingImport
                }
                upgrade = try .init(current: SourceFileHeader(bytes: current.bytes).manifest, candidate: preview.header.manifest)
            } else { upgrade = nil }
            let report = try await inspect(preview.header.source,
                SourceModuleInspection.requirements(for: preview.header.manifest, upgrade: upgrade))
            let script = try preview.acceptInspection(report, upgrade: upgrade, digest: digest)
            let receipt = try SourceImportRecord(scriptSHA256: script.sha256,
                inspectionContractSHA256: YingxueWire.schemaSHA256, fileName: fileName, importedAt: Date())
            let retained = try await library.books().filter { $0.reference.installationID == existing?.id }.count
            try Task.checkCancellation()
            guard inspectionID == attempt else { return }
            review = .init(receipt: receipt, script: script, manifest: preview.header.manifest,
                existing: existing, upgrade: upgrade, retainedBooks: retained)
        } catch {
            guard inspectionID == attempt, !(error is CancellationError), !Task.isCancelled else { return }
            problem = .init(message: Self.message(for: error))
        }
    }

    func cancelPreview() {
        guard !isSaving else { return }
        inspectionID = nil
        review = nil; isInspecting = false; problem = nil
    }

    func saveReviewedImport() async {
        guard let candidate = review, !isSaving else { return }
        isSaving = true
        problem = nil
        defer { isSaving = false }
        do {
            let library = try await openLibrary()
            try Task.checkCancellation()
            guard review?.id == candidate.id else { return }
            try await library.stageSourceScript(candidate.script, receipt: candidate.receipt)
            // A completed database transaction remains saved even if the view
            // disappeared while awaiting it. The next refresh reads that receipt.
            review = nil
            inspectionID = nil
            savedName = candidate.script.metadata.name
            await refresh()
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { return }
            problem = .init(message: "未能保存书源，请重试。当前启用的版本没有改变。")
        }
    }

    func fileSelectionFailed() {
        problem = .init(message: "无法读取这个文件，请重新选择。")
    }

    func clearProblem() { problem = nil }

    private static func message(for error: any Error) -> String {
        if error is SourceModuleInspection.Failure { return "脚本未通过检查，请确认使用完整的映雪书源文件。" }
        if error is SourceFileHeader.Failure || error is SourceScriptFailure {
            return "文件格式不受支持。请选择 UTF-8 编码的映雪 JavaScript 书源。"
        }
        return "暂时无法完成书源检查，请重试。尚未保存或启用这个文件。"
    }
}
