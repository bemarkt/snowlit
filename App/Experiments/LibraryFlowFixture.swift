#if DEBUG
import Foundation
import CryptoKit
import SnowlitCore
import SnowlitStorage
import YingxueKit

/// A UI test supplies a UUID to select an isolated persistent library. Only the
/// saved import is seeded; adoption, execution and book persistence use the UI.
enum LibraryFlowFixture {
    static func directory(arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "-snowlit-test-library-flow"),
              arguments.indices.contains(index + 1), let id = UUID(uuidString: arguments[index + 1]) else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnowlitUITests", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    @MainActor
    static func prepare(_ library: LibraryDatabase) async throws {
        guard try await library.sourceImports().isEmpty else { return }
        let preview = try SourceImportPreview(bytes: Data(source.utf8))
        let inspected = try await SourceFileInspector.inspect(preview.header.source,
            requirements: SourceModuleInspection.requirements(for: preview.header.manifest))
        let script = try preview.acceptInspection(inspected) {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        }
        let receipt = try SourceImportRecord(scriptSHA256: script.sha256,
            inspectionContractSHA256: YingxueWire.schemaSHA256, fileName: "reading-fixture.source.js", importedAt: Date())
        try await library.stageSourceScript(script, receipt: receipt)
    }

    private static let source = """
    /* @yingxue
    {"protocolVersion":1,"sourceID":"org.example.reading-fixture","name":"Reading fixture","scriptVersion":"1","referenceVersion":1,"stateVersion":1,"capabilities":[],"origins":[],"authentication":[],"publicConfiguration":[]}
    */
    export async function search(ctx, input) {
      if (input.query !== 'fixture') return {items: [], nextCursor: null};
      if (input.cursor === null) return {items: [{reference: {key: 'other'}, title: 'Another Novel'}], nextCursor: 'second'};
      return {items: [{reference: {key: 'book'}, title: 'Fixture Novel', author: 'Fixture Author'}], nextCursor: null};
    }
    export async function book(ctx, input) {
      return {reference: input.reference, title: 'Fixture Novel', author: 'Fixture Author', summary: 'A two-page synthetic catalog.'};
    }
    export async function chapters(ctx, input) {
      return {book: input.book, revision: 'catalog-1',
        items: input.cursor === null ? [{key: 'c1', title: 'Chapter One'}] : [{key: 'c2', title: 'Chapter Two'}],
        nextCursor: input.cursor === null ? 'page-2' : null};
    }
    export async function chapter(ctx, input) { throw new Error('No reading content in this fixture'); }
    """
}
#endif
