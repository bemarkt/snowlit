import Foundation
import GRDB
import SnowlitCore

extension LibraryDatabase {
    /// Adds a complete discovered book in one transaction. Existing exact
    /// identities keep their current catalog; a duplicate add cannot publish an
    /// older network snapshot over a later refresh or rewrite reading history.
    public func addBook(reference: SourceBookReference, title: String, author: String?,
                        catalog: CatalogSnapshot, expectedInstallation: SourceInstallationSnapshot) throws -> LibraryBook {
        try checkOpen()
        try Task.checkCancellation()
        guard catalog.book == reference, reference.installationID == expectedInstallation.id,
              reference.referenceVersion == expectedInstallation.metadata.referenceVersion else {
            throw LibraryModelError.differentBook
        }
        return try queue.write { db in
            let installed = try Self.installation(db, expectedInstallation.id)
            guard installed == expectedInstallation, installed.canExecute else { throw SourceInstallationFailure.staleInstallation }
            let book = try Self.addBook(db, reference: reference, title: title, author: author)
            if try Self.savedCatalog(db, book.id) == nil {
                guard book.networkReference == catalog.book else { throw LibraryModelError.differentBook }
                try Self.replaceCatalog(db, catalog: catalog, bookID: book.id)
            }
            return book
        }
    }
}
