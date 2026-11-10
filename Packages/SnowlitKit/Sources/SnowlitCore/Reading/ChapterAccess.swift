import Foundation

public enum ChapterAccessFailure: Error, Equatable, Sendable {
    case unavailableReference
    case cacheMissing
    case cacheCorrupt
    case invalidCachePath
    case readOnly
    case stale
    case closed
    case invalidLimit
}

/// A database-issued permit binds a network response to one exact installed
/// source and chapter request. Website sessions never become document identity.
public struct ChapterWriteToken: Equatable, Sendable {
    public let id: UUID
    public let bookID: LocalBookID
    public let requested: ChapterReference
    public let resolved: ChapterReference
    public let installation: SourceInstallationSnapshot

    public init(id: UUID, bookID: LocalBookID, requested: ChapterReference,
                resolved: ChapterReference, installation: SourceInstallationSnapshot) {
        self.id = id; self.bookID = bookID; self.requested = requested
        self.resolved = resolved; self.installation = installation
    }
}

public struct ChapterCacheUsage: Equatable, Sendable {
    public let documents: Int
    public let bytes: Int64
    public init(documents: Int, bytes: Int64) { self.documents = documents; self.bytes = bytes }
}
