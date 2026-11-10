import Foundation
import SnowlitCore

/// Owns result validity for one source installation. It does not run JavaScript,
/// stop a WebContent process, or perform storage side effects.
public actor SourceOperationGate {
    public enum Failure: Error, Equatable, Sendable {
        case disabled, closed, staleOperation, mismatchedReply
    }

    public struct Ticket: Sendable {
        public let call: YingxueWire.OperationCall
        fileprivate let id: UUID
    }

    private let installationID: SourceInstallationID
    private var scriptSHA256: String
    private var configurationRevision: Int
    private var sessionRevision: Int
    private var generation = UUID()
    private var enabled: Bool
    private var closed = false
    private var pending: [UUID: YingxueWire.OperationContext] = [:]
    var credentialPolicy: SourceCredentialPolicy?
    var credentialHandles: [UUID: SourceCredentialLease] = [:]
    var revokedCredentialConsents: Set<UUID> = []
    var interactions: [String: YingxueWire.InteractionPresentation] = [:]
    var hostCalls: [String: YingxueWire.HostCall] = [:]
    var hostCallIDs: Set<String> = []
    var pages: [String: SourcePageState] = [:]

    public init(installationID: SourceInstallationID, scriptSHA256: String,
                configurationRevision: Int, sessionRevision: Int, enabled: Bool = true,
                credentialPolicy: SourceCredentialPolicy? = nil) throws {
        try Self.validate(scriptSHA256: scriptSHA256, configurationRevision: configurationRevision, sessionRevision: sessionRevision)
        try Self.validate(credentialPolicy, installationID: installationID, scriptSHA256: scriptSHA256)
        self.installationID = installationID; self.scriptSHA256 = scriptSHA256
        self.configurationRevision = configurationRevision; self.sessionRevision = sessionRevision
        self.enabled = enabled
        self.credentialPolicy = credentialPolicy
    }

    public var pendingCount: Int { pending.count }

    public func begin(_ request: YingxueWire.OperationInput) throws -> Ticket {
        try Task.checkCancellation()
        guard !closed else { throw Failure.closed }
        guard enabled else { throw Failure.disabled }
        let id = UUID()
        let context = YingxueWire.OperationContext(requestID: id.uuidString.lowercased(),
            installationID: installationID.rawValue.uuidString.lowercased(), scriptSHA256: scriptSHA256,
            configurationRevision: configurationRevision, sessionRevision: sessionRevision,
            generation: generation.uuidString.lowercased())
        let call = YingxueWire.OperationCall(protocolVersion: 1, context: context, request: request)
        _ = try YingxueWireCodec.encode(call)
        pending[id] = context
        return Ticket(call: call, id: id)
    }

    /// Every host capability checks this before starting and again after an await.
    /// The caller must also check its reading/navigation generation at adoption.
    public func check(_ ticket: Ticket) throws {
        try Task.checkCancellation()
        guard !closed else { throw Failure.closed }
        guard enabled else { throw Failure.disabled }
        guard pending[ticket.id] == ticket.call.context,
              ticket.call.context.generation == generation.uuidString.lowercased() else { throw Failure.staleOperation }
    }

    /// Validate a candidate response without retiring its operation. The caller
    /// rechecks after normalization/storage awaits, then explicitly finishes it.
    public func validateReply(_ bytes: Data, for ticket: Ticket) throws -> YingxueWire.OperationReply {
        try check(ticket)
        let reply = try YingxueWireCodec.decode(YingxueWire.OperationReply.self, from: bytes)
        guard reply.context == ticket.call.context, reply.operation == ticket.call.request.operation else {
            throw Failure.mismatchedReply
        }
        return reply
    }

    public func finish(_ ticket: Ticket) throws {
        try check(ticket)
        pending.removeValue(forKey: ticket.id)
        discardCredentials(for: ticket.call.context.requestID)
        discardInteractions(for: ticket.call.context.requestID)
        discardHostCalls(for: ticket.call.context.requestID)
        discardPages(for: ticket.call.context.requestID)
    }

    /// Cancels exactly this owned consumer. Backends still receive explicit cancellation.
    @discardableResult
    public func cancel(_ ticket: Ticket) -> Bool {
        guard pending[ticket.id] == ticket.call.context else { return false }
        pending.removeValue(forKey: ticket.id)
        discardCredentials(for: ticket.call.context.requestID)
        discardInteractions(for: ticket.call.context.requestID)
        discardHostCalls(for: ticket.call.context.requestID)
        discardPages(for: ticket.call.context.requestID)
        return true
    }

    /// Source updates, configuration changes, login/logout, and enablement rotate
    /// generation even if the caller repeats the same revision. Returns operations
    /// whose backend/network/UI resources must be cancelled by their owner.
    @discardableResult
    public func replace(scriptSHA256: String, configurationRevision: Int, sessionRevision: Int, enabled: Bool,
                        credentialPolicy: SourceCredentialPolicy? = nil) throws -> [String] {
        guard !closed else { throw Failure.closed }
        try Self.validate(scriptSHA256: scriptSHA256, configurationRevision: configurationRevision, sessionRevision: sessionRevision)
        try Self.validate(credentialPolicy, installationID: installationID, scriptSHA256: scriptSHA256)
        let invalidated = invalidate()
        self.scriptSHA256 = scriptSHA256; self.configurationRevision = configurationRevision
        self.sessionRevision = sessionRevision; self.enabled = enabled
        self.credentialPolicy = credentialPolicy
        return invalidated
    }

    @discardableResult
    public func close() -> [String] {
        closed = true
        return invalidate()
    }

    func invalidate() -> [String] {
        let requests = pending.values.map(\.requestID).sorted()
        pending.removeAll()
        credentialHandles.removeAll()
        interactions.removeAll()
        hostCalls.removeAll()
        hostCallIDs.removeAll()
        pages.removeAll()
        generation = UUID()
        return requests
    }

    private static func validate(scriptSHA256: String, configurationRevision: Int, sessionRevision: Int) throws {
        let encoder = JSONEncoder()
        try YingxueWireCodec.validate(encoder.encode(scriptSHA256), as: "SHA256")
        try YingxueWireCodec.validate(encoder.encode(configurationRevision), as: "Revision")
        try YingxueWireCodec.validate(encoder.encode(sessionRevision), as: "Revision")
    }

    private static func validate(_ policy: SourceCredentialPolicy?, installationID: SourceInstallationID,
                                 scriptSHA256: String) throws {
        if let policy {
            guard policy.installationID == installationID, policy.scriptSHA256 == scriptSHA256 else {
                throw SourceCredentialFailure.invalidPolicy
            }
        }
    }
}

extension YingxueWire.OperationInput {
    public var operation: YingxueWire.OperationName {
        switch self {
        case .search: .search
        case .book: .book
        case .chapters: .chapters
        case .chapter: .chapter
        case .authenticate: .authenticate
        case .migrateReferences: .migrateReferences
        case .migrateState: .migrateState
        }
    }
}

extension YingxueWire.OperationReply {
    public var context: YingxueWire.OperationContext {
        switch self {
        case .search(let value): value.context
        case .book(let value): value.context
        case .chapters(let value): value.context
        case .chapter(let value): value.context
        case .authenticate(let value): value.context
        case .migrateReferences(let value): value.context
        case .migrateState(let value): value.context
        case .failure(let value): value.context
        }
    }
    public var operation: YingxueWire.OperationName {
        switch self {
        case .search: .search
        case .book: .book
        case .chapters: .chapters
        case .chapter: .chapter
        case .authenticate: .authenticate
        case .migrateReferences: .migrateReferences
        case .migrateState: .migrateState
        case .failure(let value): value.operation
        }
    }
}
