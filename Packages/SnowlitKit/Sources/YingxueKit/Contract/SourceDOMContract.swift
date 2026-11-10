import Foundation
import SwiftSoup

public enum SourceDOMContract {
    /// One parsed document per call. No script evaluation, network requests,
    /// DOM/node handles, or mutable document state escapes this boundary.
    public static func query(_ request: YingxueWire.DOMQuery) throws -> YingxueWire.DOMResult {
        try Task.checkCancellation()
        _ = try YingxueWireCodec.encode(request)
        let document: Document
        do { document = try SwiftSoup.parse(request.html) }
        catch { throw SourceHostFailure.invalidSelector }
        var keys = Set<Data>()
        var results: [YingxueWire.DOMSelectionResult] = []
        for selection in request.selections {
            try Task.checkCancellation()
            let key: String, selector: String
            switch selection {
            case .text(let value): key = value.key; selector = value.selector
            case .html(let value): key = value.key; selector = value.selector
            case .attribute(let value): key = value.key; selector = value.selector
            }
            guard keys.insert(Data(key.utf8)).inserted else { throw SourceHostFailure.duplicateKey }
            do {
                let elements = try document.select(selector)
                var values: [String?] = []
                for element in elements {
                    try Task.checkCancellation()
                    switch selection {
                    case .text: values.append(try element.text())
                    case .html: values.append(try element.html())
                    case .attribute(let value):
                        values.append(element.hasAttr(value.attribute) ? try element.attr(value.attribute) : nil)
                    }
                }
                results.append(.init(key: key, values: values))
            } catch is CancellationError { throw CancellationError() }
            catch { throw SourceHostFailure.invalidSelector }
        }
        return .init(selections: results)
    }
}
