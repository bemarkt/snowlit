import Foundation
import Observation
import SnowlitStorage

@MainActor @Observable
final class BackupModel {
    struct Export: Sendable {
        let file: URL
        let summary: LibraryBackupSummary
    }
    enum Action: Sendable { case export(includeCache: Bool), preview(URL), restore }
    struct Request: Identifiable { let id = UUID(); let action: Action }
    struct Problem {
        let id = UUID()
        let message: String
    }
    enum Failure: Error { case noPreparedBackup }

    private(set) var isBusy = false
    private(set) var exported: Export?
    private(set) var preview: LibraryBackupSummary?
    private(set) var restored: LibraryBackupSummary?
    private(set) var problem: Problem?
    private let export: @Sendable (Bool) async throws -> Export
    private let inspect: @Sendable (URL) async throws -> LibraryBackupSummary
    private let restore: @Sendable () async throws -> LibraryBackupSummary
    private let clear: @Sendable () async throws -> Void
    private let refresh: @MainActor () async -> Void

    init(export: @escaping @Sendable (Bool) async throws -> Export,
         inspect: @escaping @Sendable (URL) async throws -> LibraryBackupSummary,
         restore: @escaping @Sendable () async throws -> LibraryBackupSummary = { throw Failure.noPreparedBackup },
         clear: @escaping @Sendable () async throws -> Void,
         refresh: @escaping @MainActor () async -> Void = {}) {
        self.export = export; self.inspect = inspect; self.restore = restore
        self.clear = clear; self.refresh = refresh
    }

    func run(_ action: Action) async {
        guard !isBusy else { return }
        isBusy = true; problem = nil; exported = nil; restored = nil
        defer { isBusy = false }
        do {
            switch action {
            case .export(let includeCache):
                preview = nil
                let result = try await export(includeCache)
                try Task.checkCancellation()
                exported = result
            case .preview(let file):
                let result = try await inspect(file)
                try Task.checkCancellation()
                preview = result
            case .restore:
                let result = try await restore()
                try Task.checkCancellation()
                preview = nil
                restored = result
                await refresh()
            }
        } catch {
            if !(error is CancellationError) && !Task.isCancelled { report(error) }
            do { try await clear() }
            catch { problem = .init(message: "临时备份文件未能清理，请重试。本机阅读数据未被替换。") }
        }
    }

    func report(_ error: any Error) {
        let message: String
        switch error {
        case LibraryBackupFailure.unsupportedFormat: message = "暂不支持这个备份版本，请选择映雪备份文件。"
        case LibraryBackupFailure.damagedArchive, LibraryBackupFailure.inconsistentLibrary:
            message = "备份内容损坏或不完整，无法使用。本机阅读数据未被替换。"
        case LibraryBackupFailure.recordTooLarge: message = "备份中的单条记录过大，无法安全读取。"
        case LibraryBackupFailure.invalidPath: message = "无法使用这个文件位置，请重新选择。"
        case LibraryBootstrap.Failure.rollbackFailed:
            message = "恢复失败，且原库未能自动恢复。请停止继续操作并保留应用数据以便诊断。"
        case BackupModel.Failure.noPreparedBackup:
            message = "请先检查备份文件，再执行恢复。本机阅读数据未被替换。"
        default: message = "未能完成备份操作，请检查可用空间与文件权限后重试。"
        }
        problem = .init(message: message)
    }
}
