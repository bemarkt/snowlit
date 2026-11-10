import Foundation

public enum SourcePageFailure: Error, Equatable, Sendable { case missingPage, staleNavigation, notReady }

/// Evaluation runs in an isolated WebKit content world with access to the page's
/// DOM, without the source runtime's host bridge. Pass inputJSON as an argument,
/// never interpolate it as code. The gate must be checked around the callback.
public enum SourcePageProgram {
    public static func body(for request: YingxueWire.EvaluatePage) throws -> String {
        _ = try YingxueWireCodec.encode(request)
        try YingxueWireCodec.validateJSON(Data(request.inputJSON.utf8))
        return """
        const input = JSON.parse(inputJSON);
        const result = await (async (input) => {
        \(request.script)
        })(input);
        return JSON.stringify(result, (_key, value) => {
          if (['undefined', 'function', 'symbol', 'bigint'].includes(typeof value) ||
              (typeof value === 'number' && !Number.isFinite(value))) {
            throw new TypeError('Page result is not JSON');
          }
          return value;
        });
        """
    }
}

struct SourcePageState: Sendable {
    let requestID: String
    let policy: SourceHostPolicy
    var navigationID: UUID?
    var readyURL: URL?
}

extension SourceOperationGate {
    /// Native ownership token. It cannot be reconstructed from a source message.
    public struct PageTicket: Sendable {
        public let id: String
        let operation: Ticket
    }
    public struct PageNavigation: Sendable {
        public let url: URL
        let id: UUID
        let page: PageTicket
    }

    public func createPage(for ticket: Ticket, policy: SourceHostPolicy) throws -> PageTicket {
        try check(ticket)
        try policy.check(ticket.call.context, capability: .browser)
        let id = UUID().uuidString.lowercased()
        pages[id] = .init(requestID: ticket.call.context.requestID, policy: policy)
        return .init(id: id, operation: ticket)
    }

    /// Called before each permitted navigation, including a website-initiated
    /// one. The native adapter must enforce this in navigation/redirect handling.
    public func beginNavigation(_ target: YingxueWire.URLReference, page: PageTicket) throws -> PageNavigation {
        var state = try pageState(page)
        let url = try state.policy.resolve(target)
        let id = UUID()
        state.navigationID = id; state.readyURL = nil
        pages[page.id] = state
        return .init(url: url, id: id, page: page)
    }

    public func finishNavigation(_ navigation: PageNavigation, finalURL: URL) throws -> YingxueWire.OpenedPage {
        var state = try pageState(navigation.page)
        guard state.navigationID == navigation.id else { throw SourcePageFailure.staleNavigation }
        _ = try state.policy.resolve(.init(url: finalURL.absoluteString))
        state.readyURL = finalURL
        pages[navigation.page.id] = state
        return .init(page: .init(id: navigation.page.id, navigationID: navigation.id.uuidString.lowercased()), finalURL: finalURL.absoluteString)
    }

    /// Before calling WebKit and after its callback, not only when dispatching.
    public func checkPage(_ handle: YingxueWire.PageHandle, for ticket: Ticket) throws {
        try check(ticket)
        _ = try YingxueWireCodec.encode(handle)
        guard let state = pages[handle.id], state.requestID == ticket.call.context.requestID else { throw SourcePageFailure.missingPage }
        guard state.navigationID?.uuidString.lowercased() == handle.navigationID else { throw SourcePageFailure.staleNavigation }
        guard state.readyURL != nil else { throw SourcePageFailure.notReady }
    }

    public func preparePageEvaluation(_ request: YingxueWire.EvaluatePage, for ticket: Ticket) throws {
        try checkPage(request.page, for: ticket)
        _ = try YingxueWireCodec.encode(request)
        try YingxueWireCodec.validateJSON(Data(request.inputJSON.utf8))
    }

    public func acceptPageEvaluation(_ bytes: Data, page: YingxueWire.PageHandle, for ticket: Ticket) throws -> YingxueWire.PageEvaluation {
        try checkPage(page, for: ticket)
        let value = try YingxueWireCodec.decode(YingxueWire.PageEvaluation.self, from: bytes)
        try YingxueWireCodec.validateJSON(Data(value.json.utf8))
        return value
    }

    /// Cleanup can use a page ID even after navigation invalidated its old handle.
    /// The owner closes the native WebView/resources after removing this registry entry.
    public func closePage(_ request: YingxueWire.ClosePage, for ticket: Ticket) throws -> YingxueWire.ClosedPage {
        try check(ticket)
        _ = try YingxueWireCodec.encode(request)
        guard let page = pages[request.id], page.requestID == ticket.call.context.requestID else {
            return .init(closed: false)
        }
        pages.removeValue(forKey: request.id)
        return .init(closed: true)
    }

    public func pageIDs(for ticket: Ticket) -> [String] {
        pages.filter { $0.value.requestID == ticket.call.context.requestID }.keys.sorted()
    }

    /// Native cleanup is allowed after caller cancellation. The unforgeable
    /// page token can only remove its own registration, never a newer page.
    func discardPage(_ page: PageTicket) {
        guard pages[page.id]?.requestID == page.operation.call.context.requestID else { return }
        pages.removeValue(forKey: page.id)
    }

    func discardPages(for requestID: String) { pages = pages.filter { $0.value.requestID != requestID } }

    private func pageState(_ page: PageTicket) throws -> SourcePageState {
        try check(page.operation)
        guard let state = pages[page.id], state.requestID == page.operation.call.context.requestID else { throw SourcePageFailure.missingPage }
        return state
    }
}
