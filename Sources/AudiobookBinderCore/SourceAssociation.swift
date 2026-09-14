import Foundation

/// Persists identity of the chapter files that were bound, beside the book
/// folder (next to `.audiobookbinder-output`). Cleanup refuses to trash
/// without this provenance, and refuses if a recorded source has changed.
public enum SourceAssociation: Sendable {
    public static let fileName = ".audiobookbinder-sources"

    public struct Entry: Equatable, Sendable, Codable {
        public var path: String
        public var isRegularFile: Bool
        public var fileSize: Int64
        public var modificationDate: Date?
        public var fileResourceIdentifier: Data?

        public init(
            path: String,
            isRegularFile: Bool,
            fileSize: Int64,
            modificationDate: Date?,
            fileResourceIdentifier: Data?
        ) {
            self.path = path
            self.isRegularFile = isRegularFile
            self.fileSize = fileSize
            self.modificationDate = modificationDate
            self.fileResourceIdentifier = fileResourceIdentifier
        }

        public func url(relativeTo folder: URL) -> URL {
            let url = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : folder.appendingPathComponent(path)
            return url.standardizedFileURL
        }
    }

    public static func sidecarURL(inBookFolder folder: URL) -> URL {
        folder.appendingPathComponent(fileName)
    }

    public static func load(inBookFolder folder: URL) -> [Entry]? {
        let sidecar = sidecarURL(inBookFolder: folder)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return nil }
        guard let data = try? Data(contentsOf: sidecar) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Document.self, from: data).sources
    }

    public static func record(_ urls: [URL], dest: URL, inBookFolder folder: URL) {
        var entries: [Entry] = []
        var seen = Set<String>()
        for url in urls {
            let standardized = url.standardizedFileURL
            if M4BExporter.isSameFileURL(standardized, dest) { continue }
            let key = standardized.path
            guard seen.insert(key).inserted else { continue }
            let identity = FileIdentity.readResolved(from: standardized)
            entries.append(
                Entry(
                    path: key,
                    isRegularFile: identity.map { !$0.isDirectory } ?? false,
                    fileSize: identity?.fileSize ?? 0,
                    modificationDate: identity?.modificationDate,
                    fileResourceIdentifier: identity?.fileResourceIdentifier
                )
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(Document(sources: entries)) else { return }
        try? data.write(to: sidecarURL(inBookFolder: folder), options: .atomic)
    }

    private struct Document: Codable {
        var sources: [Entry]
    }
}
