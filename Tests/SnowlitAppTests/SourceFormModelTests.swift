import Foundation
import Testing
import SnowlitCore
import YingxueKit
@testable import Snowlit

@Suite(.serialized)
@MainActor
struct SourceFormModelTests {
    @Test func requiredFieldsReachTheHostAsNativeSecretsAndTheReplyContainsOnlyHandles() async throws {
        let host = try await FormHost()
        let model = try host.model()
        await model.submit()
        #expect(model.message != nil && host.submissions == 0)
        model.setValue("reader", for: "user")
        model.setValue("fixture-private-password", for: "password")
        model.setValue("ignored", for: "unknown")
        #expect(model.value(for: "unknown").isEmpty)
        #expect(String(reflecting: model) == "[redacted]")
        await model.submit()
        let result = try await model.response()
        guard case .submitted(let form) = result else { Issue.record("Expected a submitted form"); return }
        #expect(form.fields.count == 2 && host.submissions == 1)
        guard case .credential(let secret) = form.fields[1] else { Issue.record("Expected a credential handle"); return }
        let native = try await host.gate.credentialForHost(secret.handle, destination: URL(string: "https://forms.invalid/login")!, for: host.ticket, store: host.store)
        #expect(native.bytes == Data("fixture-private-password".utf8))
        await #expect(throws: SourceCredentialFailure.permissionDenied) {
            try await host.gate.credentialForSource(secret.handle, for: host.ticket, store: host.store)
        }
        let wire = try YingxueWireCodec.encode(result)
        #expect(!String(decoding: wire, as: UTF8.self).contains("fixture-private-password"))
        #expect(model.isFinished && model.value(for: "password").isEmpty && model.value(for: "user").isEmpty)
    }

    @Test func optionalBlankFieldsAreOmittedAndExactUTF8KeysStaySeparate() async throws {
        let host = try await FormHost(fields: [
            .publicText(.init(kind: .publicText, key: "\u{e9}", label: "One", required: true)),
            .publicText(.init(kind: .publicText, key: "e\u{301}", label: "Two", required: true)),
            .secret(.init(kind: .secret, key: "optional", label: "Optional", required: false))])
        let model = try host.model()
        model.setValue("first", for: "\u{e9}"); model.setValue("second", for: "e\u{301}")
        await model.submit()
        guard case .submitted(let submitted) = try await model.response() else { Issue.record("Expected form"); return }
        #expect(submitted.fields == [.publicText(.init(kind: .publicText, key: "\u{e9}", value: "first")),
            .publicText(.init(kind: .publicText, key: "e\u{301}", value: "second"))])
        #expect(await host.store.count == 0)
    }

    @Test func doubleSubmissionAndEditingDuringSubmissionCannotChangeTheSnapshot() async throws {
        let host = try await FormHost()
        let pending = FormPendingWork()
        var captured: SourceFormModel.Submission?
        let model = try host.model(submit: { submission in
            captured = submission; await pending.run()
            return try await host.submit(submission)
        })
        fill(model)
        let work = Task { await model.submit() }
        await pending.waitUntilStarted()
        model.setValue("late edit", for: "user")
        await model.submit()
        #expect(model.value(for: "user") == "reader")
        #expect(String(reflecting: try #require(captured)) == "[redacted]")
        pending.finish(); await work.value
        #expect(host.submissions == 1 && model.isFinished)
    }

    @Test func cancellingInFlightSubmissionCancelsTheBackendAndRejectsItsLateResult() async throws {
        let host = try await FormHost()
        let pending = FormPendingWork()
        var cancelled = false
        let model = try host.model(submit: { _ in
            await pending.run(); cancelled = Task.isCancelled
            return .submitted(.init(kind: .submitted, fields: []))
        }, cancel: { pending.finish() })
        fill(model)
        let work = Task { await model.submit() }
        await pending.waitUntilStarted()
        await model.cancel(); await work.value
        #expect(cancelled && model.isFinished && model.value(for: "password").isEmpty)
        #expect(try await model.response() == .cancelled(.init(kind: .cancelled)))
    }

    @Test func cancelledHostWaitClosesTheFormAndLateResultsCannotCompleteIt() async throws {
        let host = try await FormHost()
        let pending = FormPendingWork()
        let model = try host.model(submit: { _ in
            await pending.run()
            return .submitted(.init(kind: .submitted, fields: []))
        })
        fill(model)
        let work = Task { await model.submit() }
        await pending.waitUntilStarted()
        let waiting = Task { try await model.response() }
        waiting.cancel()
        await #expect(throws: (any Error).self) { try await waiting.value }
        pending.finish(); await work.value
        #expect(model.isFinished && model.value(for: "password").isEmpty)
        await #expect(throws: SourceFormModel.Failure.closed) { try await model.response() }
    }

    @Test func failedSubmissionCanRetryWithoutExposingTheFailurePayload() async throws {
        let host = try await FormHost()
        var attempts = 0
        let model = try host.model(submit: { submission in
            attempts += 1
            if attempts == 1 { throw NSError(domain: "fixture-private-password", code: 1) }
            return try await host.submit(submission)
        })
        fill(model)
        await model.submit()
        #expect(model.phase == .editing && model.value(for: "password") == "fixture-private-password")
        #expect(model.message != nil && !model.message!.contains("fixture-private-password"))
        await model.submit()
        #expect(model.isFinished && attempts == 2 && host.submissions == 1)
    }

    @Test func failedCancellationStaysLockedUntilCleanupSucceeds() async throws {
        let host = try await FormHost()
        var attempts = 0
        let model = try host.model(cancel: {
            attempts += 1
            if attempts == 1 { throw FixtureFailure.requested }
        })
        fill(model)
        await model.cancel()
        #expect(model.phase == .cancelling && model.message != nil && model.value(for: "password").isEmpty)
        model.setValue("not accepted", for: "user")
        await model.submit()
        #expect(host.submissions == 0 && model.value(for: "user").isEmpty)
        await model.retryCancellation()
        #expect(attempts == 2 && model.isFinished)
        #expect(try await model.response() == .cancelled(.init(kind: .cancelled)))
    }

    @Test func invalidatedSourceCannotCaptureCredentialsOrAcceptAnOldForm() async throws {
        let host = try await FormHost()
        let model = try host.model()
        fill(model)
        _ = await host.gate.close()
        await model.submit()
        #expect(model.isFinished && model.value(for: "password").isEmpty)
        #expect(await host.store.count == 0)
        await #expect(throws: SourceOperationGate.Failure.closed) { try await model.response() }
    }

    private func fill(_ model: SourceFormModel) {
        model.setValue("reader", for: "user"); model.setValue("fixture-private-password", for: "password")
    }
    private enum FixtureFailure: Error { case requested }
}

@MainActor
private final class FormHost {
    let gate: SourceOperationGate
    let ticket: SourceOperationGate.Ticket
    let presentation: YingxueWire.InteractionPresentation
    let installation: SourceInstallationID
    let origins: [YingxueWire.Origin]
    let store = FormCredentialStore()
    private(set) var submissions = 0

    init(fields: [YingxueWire.InteractionField]? = nil) async throws {
        installation = .init()
        origins = [.init(scheme: .https, host: "forms.invalid")]
        let manifest = YingxueWire.Manifest(protocolVersion: 1, sourceID: "org.example.forms", name: "Forms", scriptVersion: "1",
            referenceVersion: 1, stateVersion: 1, capabilities: [.http], origins: origins, authentication: [.form], publicConfiguration: [])
        let digest = String(repeating: "a", count: 64)
        let policy = try SourceHostPolicy(installationID: installation, scriptSHA256: digest, manifest: manifest)
        let credentials = try SourceCredentialPolicy(installationID: installation, scriptSHA256: digest, manifest: manifest)
        gate = try SourceOperationGate(installationID: installation, scriptSHA256: digest,
            configurationRevision: 0, sessionRevision: 0, credentialPolicy: credentials)
        ticket = try await gate.begin(.authenticate(.init(kind: .authenticate, input: .init(reason: .signIn))))
        presentation = try await gate.beginInteraction(.form(.init(kind: .form, title: "Sign in", fields: fields ?? [
            .publicText(.init(kind: .publicText, key: "user", label: "User", required: true)),
            .secret(.init(kind: .secret, key: "password", label: "Password", required: true))], credentialOrigins: origins)), for: ticket, policy: policy)
    }

    func model(submit: (@MainActor (SourceFormModel.Submission) async throws -> YingxueWire.InteractionResult)? = nil,
               cancel: (@MainActor () async throws -> Void)? = nil) throws -> SourceFormModel {
        try .init(presentation: presentation, sourceName: "Forms", sourceID: "org.example.forms", allowsCredentialRead: false,
            submit: submit ?? { try await self.submit($0) }, cancel: cancel ?? {
                _ = try await self.gate.completeInteraction(.init(id: self.presentation.id,
                    result: .cancelled(.init(kind: .cancelled))), for: self.ticket)
            })
    }

    func submit(_ input: SourceFormModel.Submission) async throws -> YingxueWire.InteractionResult {
        try await gate.check(ticket)
        submissions += 1
        var fields: [YingxueWire.FieldSubmission] = []
        for field in input.fields {
            switch field {
            case .publicText(let key, let value): fields.append(.publicText(.init(kind: .publicText, key: key, value: value)))
            case .secret(let key, let value):
                let record = StoredCredentialID(installationID: installation)
                try await store.write(value, for: record)
                let handle = try await gate.issueCredential(record, origins: origins, for: ticket)
                fields.append(.credential(.init(kind: .credential, key: key, handle: handle)))
            }
        }
        return try await gate.completeInteraction(.init(id: input.presentationID,
            result: .submitted(.init(kind: .submitted, fields: fields))), for: ticket)
    }
}

private actor FormCredentialStore: CredentialStore {
    private var values: [StoredCredentialID: CredentialSecret] = [:]
    var count: Int { values.count }
    func read(_ id: StoredCredentialID) -> CredentialSecret? { values[id] }
    func write(_ value: CredentialSecret, for id: StoredCredentialID) { values[id] = value }
    func remove(_ id: StoredCredentialID) { values.removeValue(forKey: id) }
    func removeAll(for installationID: SourceInstallationID) { values = values.filter { $0.key.installationID != installationID } }
}

@MainActor
private final class FormPendingWork {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var started = false
    func run() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation; started = true; observer?.resume(); observer = nil
        }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { observer = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
}
