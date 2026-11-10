import Foundation
import CryptoKit
import SnowlitCore
import SnowlitReader
import SnowlitStorage
import YingxueKit

@MainActor
struct AppComposition {
    let startup: StartupModel
    let sources: SourceLibraryModel
    let management: SourceManagementModel
    let candidateValidator: SourceCandidateValidator
    let runtime: SourceRuntime
    let authentication: SourceAuthenticationModel
    let search: SourceSearchModel
    let shelf: LibraryShelfModel
    let backup: BackupModel
    let makeBook: @MainActor (SourceSearchModel.Item) -> SourceBookModel

    init() {
        #if DEBUG
        let fixtureDirectory = LibraryFlowFixture.directory(arguments: ProcessInfo.processInfo.arguments)
        let storage = LibraryBootstrap(directory: fixtureDirectory)
        #else
        let storage = LibraryBootstrap()
        #endif
        let files = SourceFileReader()
        let backups = BackupWorkspace(openLibrary: { try await storage.open() })
        backup = BackupModel(export: { try await backups.export(includeCache: $0) },
            inspect: { try await backups.preview($0) }, clear: { try await backups.clear() })
        let validator = SourceCandidateValidator()
        let runtime = SourceRuntime(openLibrary: { try await storage.open() },
            digest: { bytes in SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() })
        self.runtime = runtime
        candidateValidator = validator
        let management = SourceManagementModel(openLibrary: { try await storage.open() },
            digest: { bytes in SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() },
            validate: { try await validator.validate($0) },
            invalidate: { try await runtime.invalidate($0); try await validator.invalidate($0) },
            cleanup: { try await validator.cleanup($0, token: $1) })
        self.management = management
        authentication = SourceAuthenticationModel { expected in
            guard let signedOut = await management.perform(.signOut, expected: expected) else {
                throw SourceAuthenticationModel.Failure.resetFailed
            }
            try Task.checkCancellation()
            let reply = try await runtime.invoke(.authenticate(.init(kind: .authenticate, input: .init(reason: .signIn))), expected: signedOut)
            return (signedOut, reply)
        }
        sources = SourceLibraryModel(openLibrary: { try await storage.open() },
            inspect: { source, requirements in try await SourceFileInspector.inspect(source, requirements: requirements) },
            digest: { bytes in SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() },
            readFile: { url in try await files.read(url) })
        let invoke: SourceInvocation = { input, expected in try await runtime.invoke(input, expected: expected) }
        search = SourceSearchModel(invoke: invoke)
        let shelf = LibraryShelfModel(load: { try await storage.open().books() },
            loadCatalog: { try await storage.open().catalog(for: $0) },
            makeReader: { book, chapter in
                ReaderModel(book: book, chapter: chapter, openLibrary: { try await storage.open() }, makeService: { library in
                    ChapterAccessService(library: library, invoke: invoke,
                        digest: { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() })
                })
            })
        self.shelf = shelf
        makeBook = { item in
            SourceBookModel(item: item, invoke: invoke) { installed, details, catalog in
                let book = try await storage.open().addBook(reference: catalog.book, title: details.title,
                    author: details.author, catalog: catalog, expectedInstallation: installed)
                await shelf.refresh()
                return book
            }
        }

        #if DEBUG
        // Only debug UI tests can request this deterministic first-attempt failure.
        if ProcessInfo.processInfo.arguments.contains("-snowlit-test-startup-failure") {
            let fault = StartupTestFault()
            startup = StartupModel {
                try await fault.failOnce()
                _ = try await storage.open()
            }
            return
        }
        #endif

        startup = StartupModel {
            #if DEBUG
            let library = try await storage.open()
            if ProcessInfo.processInfo.arguments.contains("-snowlit-test-reader-flow") { try await LibraryFlowFixture.prepareReading(library) }
            else if fixtureDirectory != nil { try await LibraryFlowFixture.prepare(library) }
            #else
            _ = try await storage.open()
            #endif
        }
    }
}

#if DEBUG
private actor StartupTestFault {
    private var hasFailed = false

    func failOnce() throws {
        if !hasFailed {
            hasFailed = true
            throw Failure.requested
        }
    }

    private enum Failure: Error { case requested }
}
#endif
