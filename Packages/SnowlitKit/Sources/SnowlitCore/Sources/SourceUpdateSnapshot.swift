import Foundation

/// All saved identities of a local book, including historical content. A source
/// migration cannot infer these from only the currently displayed catalog.
public struct SourceUpdateBookSnapshot: Equatable, Sendable {
    public let book: LibraryBook
    public let references: [SourceBookReference]
    public let catalog: CatalogSnapshot?
    public let checkpoint: ReadingCheckpoint?

    public init(book: LibraryBook, references: [SourceBookReference], catalog: CatalogSnapshot?,
                checkpoint: ReadingCheckpoint?) throws {
        guard Set(references).count == references.count,
              references.contains(book.reference),
              references.allSatisfy({ $0.installationID == book.reference.installationID }),
              catalog.map({ references.contains($0.book) }) ?? true,
              checkpoint.map({ $0.session.bookID == book.id }) ?? true,
              checkpoint?.position.map({ references.contains($0.chapter.book) }) ?? true else {
            throw SourceUpdateFailure.invalidInventory
        }
        self.book = book; self.references = references; self.catalog = catalog; self.checkpoint = checkpoint
    }
}

public enum SourceUpdateFailure: Error, Equatable, Sendable {
    case invalidInventory, unsupportedProtocol, staleInventory
}

/// An immutable SQL read snapshot for preparing a candidate. Adoption must
/// recheck installation, inventoryRevision and both state snapshots inside its
/// write transaction. Capturing this value does not authorize candidate code.
public struct SourceUpdateSnapshot: Equatable, Sendable {
    public let installation: SourceInstallationSnapshot
    public let candidate: SourceImportRecord
    public let candidateMetadata: SourceScriptMetadata
    public let inventoryRevision: Int64
    public let books: [SourceUpdateBookSnapshot]
    public let currentState: SourcePublicState
    /// A previously used target state version may already have saved data.
    /// Reverting a version must not reset its revision or overwrite it blindly.
    public let targetState: SourcePublicState

    public init(installation: SourceInstallationSnapshot, candidate: SourceImportRecord,
                candidateMetadata: SourceScriptMetadata, inventoryRevision: Int64,
                books: [SourceUpdateBookSnapshot], currentState: SourcePublicState,
                targetState: SourcePublicState) throws {
        guard candidateMetadata.sourceID.utf8.elementsEqual(installation.metadata.sourceID.utf8),
              inventoryRevision >= 0, Set(books.map(\.book.id)).count == books.count,
              books.allSatisfy({ $0.book.reference.installationID == installation.id }),
              currentState.stateVersion == installation.metadata.stateVersion,
              targetState.stateVersion == candidateMetadata.stateVersion else {
            throw SourceUpdateFailure.invalidInventory
        }
        self.installation = installation; self.candidate = candidate; self.candidateMetadata = candidateMetadata
        self.inventoryRevision = inventoryRevision; self.books = books
        self.currentState = currentState; self.targetState = targetState
    }
}
