import Foundation

/// Prepares one application directory without opening or replacing a dataset.
public actor StorageBootstrap {
    private let directory: URL?

    /// A supplied directory allows isolated filesystem tests.
    public init(directory: URL? = nil) {
        self.directory = directory
    }

    public func prepare() throws {
        try Task.checkCancellation()
        let fileManager = FileManager()
        let destination: URL
        if let directory {
            destination = directory
        } else {
            destination = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Snowlit", isDirectory: true)
        }
        // Existing contents stay in place. A file/path conflict is a failure.
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    }
}
