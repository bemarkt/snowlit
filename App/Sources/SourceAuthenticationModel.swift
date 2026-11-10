import Foundation
import Observation
import SnowlitCore
import YingxueKit

/// Only a source's checked authenticate reply establishes a displayed login
/// result. Form submission and webpage dismissal never establish authentication.
@MainActor
@Observable
final class SourceAuthenticationModel {
    enum Failure: Error { case invalidReply, resetFailed }
    struct Result {
        let installation: SourceInstallationSnapshot
        let message: String
        let authenticated: Bool
    }
    private(set) var busy: SourceInstallationID?
    private(set) var problem: String?
    private(set) var changed = 0
    private var results: [SourceInstallationID: Result] = [:]
    @ObservationIgnored private let signIn: @MainActor (SourceInstallationSnapshot) async throws -> (SourceInstallationSnapshot, YingxueWire.OperationReply)

    init(signIn: @escaping @MainActor (SourceInstallationSnapshot) async throws -> (SourceInstallationSnapshot, YingxueWire.OperationReply)) {
        self.signIn = signIn
    }

    func result(for installation: SourceInstallationSnapshot) -> Result? {
        guard let result = results[installation.id], result.installation == installation else { return nil }
        return result
    }

    /// Invoked only after the native confirmation to end any saved website
    /// session. The injected action must await logout cleanup before signing in.
    func authenticate(expected: SourceInstallationSnapshot) async {
        guard busy == nil else { return }
        busy = expected.id; problem = nil; results.removeValue(forKey: expected.id)
        defer { busy = nil; changed += 1 }
        do {
            let (current, reply) = try await signIn(expected)
            try Task.checkCancellation()
            guard current.id == expected.id, current.scriptSHA256 == expected.scriptSHA256, current.canExecute,
                  reply.context.installationID == current.id.rawValue.uuidString.lowercased(),
                  reply.context.scriptSHA256 == current.scriptSHA256,
                  reply.context.configurationRevision == current.revision, reply.context.sessionRevision == current.revision else {
                throw Failure.invalidReply
            }
            switch reply {
            case .authenticate(let reply):
                let authenticated = reply.value.status == .authenticated
                results[current.id] = .init(installation: current,
                    message: authenticated ? "书源已确认网站登录有效。" : "书源未确认登录成功，可以重试。", authenticated: authenticated)
            case .failure(let reply) where reply.operation == .authenticate:
                problem = reply.error.code == .cancelled ? "已取消网站登录。" : "网站登录未完成，请检查后重试。"
            default: throw Failure.invalidReply
            }
        } catch {
            problem = error is CancellationError || Task.isCancelled ? "已取消网站登录。" : "网站登录未完成。请先处理书源管理或会话清理提示，再重试。"
        }
    }
}
