import CryptoKit
import Foundation

/// Persists identity of the chapter files that were bound, beside the book
/// folder (next to `.audiobookbinder-output`). Cleanup refuses to trash
/// without this provenance, and refuses if a recorded source has changed.
public enum SourceAssociation: Sendable {
    public static let fileName = ".audiobookbinder-sources"
    static let maxSidecarBytes = 256 * 1024
    static let maxSourceEntries = 4_096
    static let maxPathLength = BoundedFileRead.maxPathLength

    public struct Entry: Equatable, Sendable, Codable {
        public var path: String
        public var isRegularFile: Bool
        public var fileSize: Int64
        public var modificationDate: Date?
        public var fileResourceIdentifier: Data?
        public var sha256: String?

        public init(
            path: String,
            isRegularFile: Bool,
            fileSize: Int64,
            modificationDate: Date?,
            fileResourceIdentifier: Data?,
            sha256: String? = nil
        ) {
            self.path = path
            self.isRegularFile = isRegularFile
            self.fileSize = fileSize
            self.modificationDate = modificationDate
            self.fileResourceIdentifier = fileResourceIdentifier
            self.sha256 = sha256
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
        loadDocument(inBookFolder: folder)?.sources
    }

    static func loadDocument(inBookFolder folder: URL) -> Document? {
        let sidecar = sidecarURL(inBookFolder: folder)
        guard let data = BoundedFileRead.read(from: sidecar, maxBytes: maxSidecarBytes) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let document = try? decoder.decode(Document.self, from: data) else { return nil }
        guard document.sources.count <= maxSourceEntries else { return nil }
        if let destination = document.destination,
           !BoundedFileRead.isAllowedPath(destination, maxLength: maxPathLength) {
            return nil
        }
        for entry in document.sources {
            guard BoundedFileRead.isAllowedPath(entry.path, maxLength: maxPathLength) else { return nil }
        }
        return document
    }

    /// Snapshot each included source before encode. Dest aliases are skipped.
    /// Throws if a remaining source is not a regular file with a digest.
    public static func capture(_ urls: [URL], dest: URL) throws -> [Entry] {
        var entries: [Entry] = []
        var seen = Set<String>()
        for url in urls {
            let standardized = url.standardizedFileURL
            if M4BExporter.isSameFileURL(standardized, dest) { continue }
            let key = standardized.path
            guard seen.insert(key).inserted else { continue }
            guard let entry = captureEntry(standardized) else {
                throw BinderError.exportFailed(
                    "Cannot capture source provenance for \(standardized.lastPathComponent)"
                )
            }
            entries.append(entry)
        }
        return entries
    }

    /// Persist pre-encode captures plus the published dest identity. Atomic write.
    @discardableResult
    static func record(
        captured: [Entry],
        dest: URL,
        destIdentity: FileIdentity,
        inBookFolder folder: URL
    ) -> Bool {
        guard !destIdentity.isDirectory else {
            invalidate(inBookFolder: folder)
            return false
        }
        let document = Document(
            sources: captured,
            destination: dest.standardizedFileURL.path,
            destinationIdentity: destIdentity
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(document) else {
            invalidate(inBookFolder: folder)
            return false
        }
        do {
            try data.write(to: sidecarURL(inBookFolder: folder), options: .atomic)
            return true
        } catch {
            invalidate(inBookFolder: folder)
            return false
        }
    }

    /// Test/helper convenience: capture live files now and persist immediately.
    @discardableResult
    public static func record(_ urls: [URL], dest: URL, inBookFolder folder: URL) -> Bool {
        var entries: [Entry] = []
        var seen = Set<String>()
        for url in urls {
            let standardized = url.standardizedFileURL
            if M4BExporter.isSameFileURL(standardized, dest) { continue }
            let key = standardized.path
            guard seen.insert(key).inserted else { continue }
            if let entry = captureEntry(standardized) {
                entries.append(entry)
            }
        }
        guard let destIdentity = FileIdentity.read(from: dest), !destIdentity.isDirectory else {
            invalidate(inBookFolder: folder)
            return false
        }
        return record(captured: entries, dest: dest, destIdentity: destIdentity, inBookFolder: folder)
    }

    public static func invalidate(inBookFolder folder: URL) {
        let sidecar = sidecarURL(inBookFolder: folder)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return }
        try? FileManager.default.removeItem(at: sidecar)
    }

    static func sha256Hex(of url: URL) -> String? {
        let resolved = url.resolvingSymlinksInPath()
        do {
            let handle = try FileHandle(forReadingFrom: resolved)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let chunk = try handle.read(upToCount: 65_536)
                guard let chunk, !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            return nil
        }
    }

    private static func captureEntry(_ url: URL) -> Entry? {
        guard let identity = FileIdentity.readResolved(from: url), !identity.isDirectory else {
            return nil
        }
        guard let digest = sha256Hex(of: url), !digest.isEmpty else {
            return nil
        }
        return Entry(
            path: url.standardizedFileURL.path,
            isRegularFile: true,
            fileSize: identity.fileSize,
            modificationDate: identity.modificationDate,
            fileResourceIdentifier: identity.fileResourceIdentifier,
            sha256: digest
        )
    }

    struct Document: Equatable, Sendable, Codable {
        var sources: [Entry]
        var destination: String?
        var destinationIdentity: FileIdentity?
    }
}
