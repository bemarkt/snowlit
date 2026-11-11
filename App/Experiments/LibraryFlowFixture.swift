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
        guard let index = arguments.firstIndex(where: {
            ["-snowlit-test-library-flow", "-snowlit-test-reader-flow", "-snowlit-test-source-management-flow"].contains($0)
        }),
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

    /// Reading scenarios start at a known local catalog. The separate library
    /// flow still adopts, searches and saves this source through the product UI.
    @MainActor
    static func prepareInstalledSource(_ library: LibraryDatabase) async throws {
        try await prepare(library)
        guard try await library.sourceInstallations().isEmpty, let receipt = try await library.sourceImports().first else { return }
        _ = try await library.installSource(importID: receipt.id, id: .init(), configuration: [], consent: .managedOnly)
    }

    @MainActor
    static func prepareReading(_ library: LibraryDatabase) async throws {
        try await prepareInstalledSource(library)
        guard try await library.books().isEmpty, let installed = try await library.sourceInstallations().first else { return }
        let reference = try SourceBookReference(installationID: installed.id, referenceVersion: 1, key: "book")
        let catalog = try CatalogSnapshot(book: reference, revision: "catalog-1", entries: [
            .init(reference: .init(book: reference, key: "c1"), title: "Chapter One"),
            .init(reference: .init(book: reference, key: "c2"), title: "Chapter Two")])
        _ = try await library.addBook(reference: reference, title: "Fixture Novel", author: "Fixture Author", catalog: catalog, expectedInstallation: installed)
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
    export async function chapter(ctx, input) {
      const label = input.reference.key === 'c1' ? 'Chapter One' : 'Chapter Two';
      return {reference: input.reference, revision: 'text-1', body: {kind: 'structured', blocks:
        Array.from({length: 36}, (_, i) => ({kind: 'paragraph', id: 'p' + i, runs:
          [{kind: 'text', text: label + ' paragraph ' + i + ': ' + '中文 👩🏽‍💻 reading text. '.repeat(8), strong: i === 0, emphasis: false}]}))}};
    }
    """
}
#endif
