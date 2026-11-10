import Foundation
import Observation
import SnowlitCore
import YingxueKit

/// Native input never becomes a source-visible reply. The operation owner must
/// store secret fields, issue current credential handles and complete the gate.
@MainActor
@Observable
final class SourceFormModel: Identifiable {
    struct Submission: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        enum Field: Sendable {
            case publicText(key: String, value: String)
            case secret(key: String, value: CredentialSecret)
        }
        let presentationID: String
        let fields: [Field]
        var description: String { "[redacted]" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: [:]) }
    }

    enum Failure: Error { case invalidForm, alreadyWaiting, invalidResponse, closed }
    enum Phase { case editing, submitting, cancelling, finished }
    let id: String
    let sourceName: String
    let sourceID: String
    let allowsCredentialRead: Bool
    let form: YingxueWire.FormInteraction
    private(set) var phase: Phase = .editing
    private(set) var message: String?
    private var values: [Data: String] = [:]
    var isFinished: Bool { phase == .finished }

    // Required adapters own gate validation and credentials. On failure submit
    // must roll back its temporary credentials before allowing another attempt.
    @ObservationIgnored private let submitForm: @MainActor (Submission) async throws -> YingxueWire.InteractionResult
    @ObservationIgnored private let cancelForm: @MainActor () async throws -> Void
    @ObservationIgnored private var attempt: UUID?
    // Finite work belongs to this presentation and receives cancellation. The
    // generation also rejects backends that return after cancellation.
    @ObservationIgnored private var work: Task<YingxueWire.InteractionResult, any Error>?
    @ObservationIgnored private var completion: Result<YingxueWire.InteractionResult, any Error>?
    @ObservationIgnored private var waiter: CheckedContinuation<YingxueWire.InteractionResult, any Error>?

    init(presentation: YingxueWire.InteractionPresentation, sourceName: String, sourceID: String, allowsCredentialRead: Bool,
         submit: @escaping @MainActor (Submission) async throws -> YingxueWire.InteractionResult,
         cancel: @escaping @MainActor () async throws -> Void) throws {
        _ = try YingxueWireCodec.encode(presentation)
        guard case .form(let form) = presentation.request, !form.fields.isEmpty,
              Set(form.fields.map { Data($0.formKey.utf8) }).count == form.fields.count else { throw Failure.invalidForm }
        id = presentation.id; self.form = form; self.sourceName = sourceName; self.sourceID = sourceID
        self.allowsCredentialRead = allowsCredentialRead
        submitForm = submit; cancelForm = cancel
    }

    func value(for key: String) -> String { values[Data(key.utf8)] ?? "" }

    func setValue(_ value: String, for key: String) {
        guard phase == .editing, form.fields.contains(where: { $0.formKey.utf8.elementsEqual(key.utf8) }) else { return }
        values[Data(key.utf8)] = value
        message = nil
    }

    func submit() async {
        guard phase == .editing else { return }
        guard form.fields.allSatisfy({ !$0.formRequired || !value(for: $0.formKey).isEmpty }) else {
            message = "请填写所有必填项。"; return
        }
        let fields: [Submission.Field] = form.fields.compactMap { field in
            let value = value(for: field.formKey)
            guard field.formRequired || !value.isEmpty else { return nil }
            switch field {
            case .publicText: return .publicText(key: field.formKey, value: value)
            case .secret: return .secret(key: field.formKey, value: .init(utf8: value))
            }
        }
        let submission = Submission(presentationID: id, fields: fields)
        let current = UUID()
        attempt = current; phase = .submitting; message = nil
        let task = Task { @MainActor [submitForm] in try await submitForm(submission) }
        work = task
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard attempt == current else { return }
            guard case .submitted = result else { throw Failure.invalidResponse }
            finish(.success(result))
        } catch {
            guard attempt == current else { return }
            work = nil; attempt = nil
            if Task.isCancelled || error is CancellationError || error is SourceOperationGate.Failure {
                finish(.failure(error))
            } else {
                phase = .editing
                message = "未能提交，请重试。登录状态尚未确认。"
            }
        }
    }

    /// User cancellation waits for the owning host's cleanup. A cleanup failure
    /// remains visible and retryable; it is never reported as a completed cancel.
    func cancel() async {
        guard phase != .finished, phase != .cancelling else { return }
        let oldWork = work
        work = nil; oldWork?.cancel(); attempt = nil; values.removeAll()
        phase = .cancelling; message = nil
        do {
            // The adapter serializes cancellation with any in-flight capture.
            try await cancelForm()
            guard phase == .cancelling else { return }
            finish(.success(.cancelled(.init(kind: .cancelled))))
        } catch {
            guard phase == .cancelling else { return }
            message = "取消尚未完成，请重试清理。"
        }
    }

    func retryCancellation() async {
        guard phase == .cancelling, message != nil else { return }
        phase = .editing
        await cancel()
    }

    /// The operation owner calls this after revoking its gate/backend resources,
    /// including logout, source changes and background cancellation.
    func invalidate() {
        guard completion == nil else { return }
        work?.cancel()
        finish(.failure(Failure.closed))
    }

    /// One host call waits for one native presentation. It may start waiting
    /// after a very fast response; neither ordering loses the completion.
    func response() async throws -> YingxueWire.InteractionResult {
        if Task.isCancelled { invalidate(); throw CancellationError() }
        if let completion { return try completion.get() }
        guard waiter == nil else { throw Failure.alreadyWaiting }
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.invalidate() }
        }
        try Task.checkCancellation()
        return result
    }

    private func finish(_ result: Result<YingxueWire.InteractionResult, any Error>) {
        guard completion == nil else { return }
        completion = result; phase = .finished; values.removeAll(); work = nil; attempt = nil; message = nil
        let continuation = waiter; waiter = nil
        continuation?.resume(with: result)
    }
}

extension SourceFormModel: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    nonisolated var description: String { "[redacted]" }
    nonisolated var debugDescription: String { description }
    nonisolated var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension YingxueWire.InteractionField {
    var formKey: String { switch self { case .publicText(let field): field.key; case .secret(let field): field.key } }
    var formLabel: String { switch self { case .publicText(let field): field.label; case .secret(let field): field.label } }
    var formRequired: Bool { switch self { case .publicText(let field): field.required; case .secret(let field): field.required } }
}
