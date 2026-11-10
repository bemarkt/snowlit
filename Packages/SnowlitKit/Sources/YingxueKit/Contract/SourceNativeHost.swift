#if os(iOS)
import Foundation
import SnowlitCore
import WebKit

/// Native capability dispatcher for exactly one operation. The App supplies
/// real interaction and state boundaries; candidate validation supplies isolated
/// state instead of a token for the active library. No branch returns a stub.
@MainActor
public final class SourceNativeHost {
    public typealias Interaction = @MainActor (YingxueWire.InteractionRequest) async throws -> YingxueWire.InteractionResult
    public typealias ReadState = @MainActor (YingxueWire.ReadPublicState) async throws -> YingxueWire.PublicStateSnapshot
    public typealias WriteState = @MainActor (YingxueWire.WritePublicState) async throws -> YingxueWire.PublicStateWriteResult

    public let browser: SourceBrowserSession
    private let gate: SourceOperationGate
    private let ticket: SourceOperationGate.Ticket
    private let policy: SourceHostPolicy
    private let configuration: SourceConfiguration
    private let website: SourceWebsiteSession
    private let credentials: any CredentialStore
    private let interact: Interaction
    private let readState: ReadState
    private let writeState: WriteState
    private var closed = false

    public init(gate: SourceOperationGate, ticket: SourceOperationGate.Ticket, policy: SourceHostPolicy,
                configuration: SourceConfiguration, website: SourceWebsiteSession, credentials: any CredentialStore,
                mount: @escaping @MainActor (WKWebView) -> Void, interact: @escaping Interaction,
                readState: @escaping ReadState, writeState: @escaping WriteState) {
        self.gate = gate; self.ticket = ticket; self.policy = policy; self.configuration = configuration
        self.website = website; self.credentials = credentials; self.interact = interact
        self.readState = readState; self.writeState = writeState
        browser = .init(gate: gate, ticket: ticket, policy: policy, dataStore: website.dataStore, mount: mount)
    }

    public func reply(to host: SourceOperationGate.HostTicket) async throws -> YingxueWire.HostReply {
        guard !closed, host.call.context == ticket.call.context else { throw SourceHostFailure.wrongContext }
        try await gate.check(host)
        let call = host.call
        let result: YingxueWire.HostReply
        switch call.request {
        case .http(let request):
            let value = try await website.perform(request.input, policy: policy, gate: gate, ticket: ticket, credentials: credentials)
            result = .http(.init(kind: .http, id: call.id, context: call.context, value: value))
        case .decodeText(let request):
            result = .decodeText(.init(kind: .decodeText, id: call.id, context: call.context, value: try SourceTextDecoder.decode(request.input)))
        case .dom(let request):
            result = .dom(.init(kind: .dom, id: call.id, context: call.context, value: try SourceDOMContract.query(request.input)))
        case .readConfiguration:
            result = .readConfiguration(.init(kind: .readConfiguration, id: call.id, context: call.context,
                value: try configuration.read(for: call.context)))
        case .readCredential(let request):
            let value = try await gate.credentialForSource(request.input.handle, for: ticket, store: credentials)
            result = .readCredential(.init(kind: .readCredential, id: call.id, context: call.context, value: value))
        case .readPublicState(let request):
            result = .readPublicState(.init(kind: .readPublicState, id: call.id, context: call.context, value: try await readState(request.input)))
        case .writePublicState(let request):
            result = .writePublicState(.init(kind: .writePublicState, id: call.id, context: call.context, value: try await writeState(request.input)))
        case .interact(let request):
            // The native presenter owns begin/completeInteraction, including
            // captured form credentials. Closing a page is not login success.
            result = .interact(.init(kind: .interact, id: call.id, context: call.context, value: try await interact(request.input)))
        case .openPage(let request):
            result = .openPage(.init(kind: .openPage, id: call.id, context: call.context, value: try await browser.open(request.input)))
        case .evaluatePage(let request):
            result = .evaluatePage(.init(kind: .evaluatePage, id: call.id, context: call.context, value: try await browser.evaluate(request.input)))
        case .closePage(let request):
            result = .closePage(.init(kind: .closePage, id: call.id, context: call.context, value: try await browser.closePage(request.input)))
        }
        guard !closed else { throw SourceHostFailure.wrongContext }
        _ = try await gate.validateHostReply(YingxueWireCodec.encode(result), for: host)
        return result
    }

    /// Operation owner retires its gate ticket and closes interaction/state
    /// owners too. The website session can remain alive for the next operation.
    public func close() async throws {
        closed = true
        try await browser.close()
    }
}
#endif
