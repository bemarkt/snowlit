import Foundation
import SnowlitCore
import Testing
@testable import YingxueKit

struct SourceOperationGateTests {
    private let digest = String(repeating: "a", count: 64)
    private var request: YingxueWire.OperationInput {
        .search(.init(kind: .search, input: .init(query: "book", cursor: nil)))
    }

    @Test func cancellingOneConsumerPreservesAnotherAndFinishCannotBeReplayed() async throws {
        let gate = try gate()
        let cancelled = try await gate.begin(request)
        let survivor = try await gate.begin(request)
        #expect(await gate.cancel(cancelled))
        #expect(!(await gate.cancel(cancelled)))
        await #expect(throws: SourceOperationGate.Failure.staleOperation) { try await gate.check(cancelled) }
        let reply = try reply(for: survivor)
        _ = try await gate.validateReply(reply, for: survivor)
        try await gate.check(survivor)
        try await gate.finish(survivor)
        #expect(await gate.pendingCount == 0)
        await #expect(throws: SourceOperationGate.Failure.staleOperation) { try await gate.validateReply(reply, for: survivor) }
    }

    @Test func sourceConfigurationSessionChangesAndDisableInvalidateAllPriorResults() async throws {
        let installation = SourceInstallationID()
        let gate = try SourceOperationGate(installationID: installation, scriptSHA256: digest, configurationRevision: 0, sessionRevision: 0)
        for (hash, config, session, enabled) in [(String(repeating: "b", count: 64), 0, 0, true),
                                                (digest, 1, 0, true), (digest, 1, 1, true),
                                                (digest, 1, 2, false)] {
            let ticket = try await gate.begin(request)
            let json = try reply(for: ticket)
            _ = try await gate.validateReply(json, for: ticket)
            #expect(try await gate.replace(scriptSHA256: hash, configurationRevision: config, sessionRevision: session, enabled: enabled) == [ticket.call.context.requestID])
            await #expect(throws: (any Error).self) { try await gate.check(ticket) }
            await #expect(throws: (any Error).self) { try await gate.validateReply(json, for: ticket) }
            if !enabled {
                await #expect(throws: SourceOperationGate.Failure.disabled) { try await gate.begin(request) }
                try await gate.replace(scriptSHA256: hash, configurationRevision: config, sessionRevision: session, enabled: true)
            }
            let renewed = try await gate.begin(request)
            #expect(renewed.call.context.installationID == installation.rawValue.uuidString.lowercased())
            #expect(renewed.call.context.generation != ticket.call.context.generation)
            try await gate.finish(renewed)
        }
    }

    @Test func forgedContextWrongOperationAndAnotherInstallationCannotAdoptAReply() async throws {
        let first = try gate(), other = try gate()
        let a = try await first.begin(request), b = try await other.begin(request)
        await #expect(throws: SourceOperationGate.Failure.staleOperation) { try await first.check(b) }
        await #expect(throws: SourceOperationGate.Failure.mismatchedReply) {
            try await first.validateReply(reply(for: b), for: a)
        }
        let wrong = YingxueWire.OperationReply.book(.init(kind: .book, context: a.call.context,
            value: .init(reference: .init(key: "b"), title: "book")))
        await #expect(throws: SourceOperationGate.Failure.mismatchedReply) {
            try await first.validateReply(YingxueWireCodec.encode(wrong), for: a)
        }
        #expect(await first.pendingCount == 1)
        try await first.finish(a)
        try await other.finish(b)
    }

    @Test func invalidReplacementPreservesLiveStateAndClosePermanentlyRejectsWork() async throws {
        let gate = try gate()
        let ticket = try await gate.begin(request)
        await #expect(throws: WireViolation.self) {
            try await gate.replace(scriptSHA256: "invalid", configurationRevision: 0, sessionRevision: 0, enabled: true)
        }
        try await gate.check(ticket)
        #expect(await gate.close() == [ticket.call.context.requestID])
        await #expect(throws: SourceOperationGate.Failure.closed) { try await gate.begin(request) }
        await #expect(throws: SourceOperationGate.Failure.closed) {
            try await gate.replace(scriptSHA256: digest, configurationRevision: 0, sessionRevision: 0, enabled: true)
        }
    }

    @Test func invalidInputDoesNotLeavePendingWorkAndFailureReplyKeepsItsCategory() async throws {
        let gate = try gate()
        await #expect(throws: WireViolation.self) {
            try await gate.begin(.search(.init(kind: .search, input: .init(query: "", cursor: nil))))
        }
        #expect(await gate.pendingCount == 0)
        let ticket = try await gate.begin(request)
        let failure = YingxueWire.OperationReply.failure(.init(kind: .failure, context: ticket.call.context, operation: .search,
            error: .init(code: .needsAuthentication, stage: .execute, retryable: false)))
        #expect(try await gate.validateReply(YingxueWireCodec.encode(failure), for: ticket) == failure)
        try await gate.finish(ticket)
    }

    private func gate() throws -> SourceOperationGate {
        try .init(installationID: SourceInstallationID(), scriptSHA256: digest, configurationRevision: 0, sessionRevision: 0)
    }
    private func reply(for ticket: SourceOperationGate.Ticket) throws -> Data {
        try YingxueWireCodec.encode(YingxueWire.OperationReply.search(.init(kind: .search, context: ticket.call.context,
                                                                          value: .init(items: [], nextCursor: nil))))
    }
}
