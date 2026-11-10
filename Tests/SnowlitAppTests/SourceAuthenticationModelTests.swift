import Foundation
import SnowlitCore
import Testing
import YingxueKit
@testable import Snowlit

@MainActor
struct SourceAuthenticationModelTests {
    @Test(arguments: [YingxueWire.AuthenticationStatus.authenticated, .anonymous])
    func onlyAnAuthenticationReplyForTheCurrentInstallationSetsStatus(_ status: YingxueWire.AuthenticationStatus) async throws {
        let installed = try installation()
        let context = context(installed)
        let model = SourceAuthenticationModel { expected in
            (expected, .authenticate(.init(kind: .authenticate, context: context, value: .init(status: status))))
        }
        await model.authenticate(expected: installed)
        #expect(model.result(for: installed)?.authenticated == (status == .authenticated))
        #expect(model.problem == nil && model.busy == nil)
        let changed = try installation(id: installed.id, revision: 2)
        #expect(model.result(for: changed) == nil)
    }

    @Test func unrelatedReplyAndChangedIdentityCannotBecomeAuthenticationSuccess() async throws {
        let installed = try installation()
        let wrong = try installation()
        let context = context(installed)
        let unrelated = SourceAuthenticationModel { expected in
            (expected, .search(.init(kind: .search, context: context, value: .init(items: [], nextCursor: nil))))
        }
        await unrelated.authenticate(expected: installed)
        #expect(unrelated.result(for: installed) == nil && unrelated.problem != nil)
        let replaced = SourceAuthenticationModel { _ in
            (wrong, .authenticate(.init(kind: .authenticate, context: context, value: .init(status: .authenticated))))
        }
        await replaced.authenticate(expected: installed)
        #expect(replaced.result(for: installed) == nil && replaced.problem != nil)
    }

    @Test func cancellationAndFailedResetNeverRecordASuccessfulLogin() async throws {
        let installed = try installation()
        let cancelled = SourceAuthenticationModel { _ in throw CancellationError() }
        await cancelled.authenticate(expected: installed)
        #expect(cancelled.result(for: installed) == nil && cancelled.problem == "已取消网站登录。")
        let failed = SourceAuthenticationModel { _ in throw SourceAuthenticationModel.Failure.resetFailed }
        await failed.authenticate(expected: installed)
        #expect(failed.result(for: installed) == nil && failed.problem != nil && failed.busy == nil)
    }

    private func installation(id: SourceInstallationID = .init(), revision: Int = 1) throws -> SourceInstallationSnapshot {
        try .init(id: id, importID: UUID(), scriptSHA256: String(repeating: "a", count: 64),
            metadata: .init(sourceID: "org.example.authentication", name: "Fixture", scriptVersion: "1",
                protocolVersion: 1, referenceVersion: 1, stateVersion: 1),
            revision: revision, state: .enabled, configuration: [], allowsCredentialRead: false,
            websiteSessionID: UUID(), pendingCleanup: nil)
    }

    private func context(_ installation: SourceInstallationSnapshot) -> YingxueWire.OperationContext {
        .init(requestID: UUID().uuidString.lowercased(), installationID: installation.id.rawValue.uuidString.lowercased(),
            scriptSHA256: installation.scriptSHA256, configurationRevision: installation.revision,
            sessionRevision: installation.revision, generation: UUID().uuidString.lowercased())
    }
}
