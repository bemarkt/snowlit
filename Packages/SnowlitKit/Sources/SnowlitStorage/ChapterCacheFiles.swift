import Foundation
import SnowlitCore

/// Only generated leaf files are removed. A database write transaction must
/// enclose promotion/collection so independent connections cannot collect a
/// file while another writer is about to reference it.
struct ChapterCacheFiles: Sendable {
    let root: URL
    private var objects: URL { root.appendingPathComponent("objects", isDirectory: true) }
    private var staging: URL { root.appendingPathComponent("staging", isDirectory: true) }

    func prepare() throws {
        for directory in [root, objects, staging] {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            try require(directory, type: .typeDirectory)
        }
    }

    func store(_ bytes: Data, expected: String, digest: (Data) throws -> String) throws -> String {
        try prepare()
        let id = UUID().uuidString.lowercased()
        let temporary = staging.appendingPathComponent(id + ".tmp")
        let name = id + ".json"
        try bytes.write(to: temporary, options: .withoutOverwriting)
        guard try digest(Data(contentsOf: temporary)) == expected else { throw ChapterAccessFailure.cacheCorrupt }
        try FileManager.default.moveItem(at: temporary, to: objects.appendingPathComponent(name))
        return name
    }

    func read(_ name: String, count: Int, digest expected: String,
              using digest: (Data) throws -> String) throws -> Data {
        guard valid(name, extension: "json") else { throw ChapterAccessFailure.invalidCachePath }
        guard FileManager.default.fileExists(atPath: root.path) else { throw ChapterAccessFailure.cacheMissing }
        try require(root, type: .typeDirectory); try require(objects, type: .typeDirectory)
        let file = objects.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { throw ChapterAccessFailure.cacheMissing }
        try require(file, type: .typeRegular)
        let bytes = try Data(contentsOf: file)
        guard bytes.count == count, try digest(bytes) == expected else { throw ChapterAccessFailure.cacheCorrupt }
        return bytes
    }

    func collect(except retained: Set<String>) throws -> Int {
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        try require(root, type: .typeDirectory)
        var removal: [URL] = []
        for (directory, suffix) in [(objects, "json"), (staging, "tmp")] {
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            try require(directory, type: .typeDirectory)
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                if valid(file.lastPathComponent, extension: suffix), !retained.contains(file.lastPathComponent) {
                    try require(file, type: .typeRegular)
                    removal.append(file)
                }
            }
        }
        for file in removal { try FileManager.default.removeItem(at: file) }
        return removal.count
    }

    private func valid(_ name: String, extension suffix: String) -> Bool {
        guard name.hasSuffix("." + suffix) else { return false }
        let id = String(name.dropLast(suffix.count + 1))
        return UUID(uuidString: id)?.uuidString.lowercased() == id
    }

    private func require(_ url: URL, type: FileAttributeType) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let resource = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard attributes[.type] as? FileAttributeType == type, resource.isSymbolicLink != true else {
            throw ChapterAccessFailure.invalidCachePath
        }
        let expected = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == expected else {
            throw ChapterAccessFailure.invalidCachePath
        }
    }
}
