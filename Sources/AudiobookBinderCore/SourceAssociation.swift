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
        try capture(urls, dest: dest, cancellation: nil)
    }

    static func capture(
        _ urls: [URL],
        dest: URL,
        cancellation: EncodeCancellation?
    ) throws -> [Entry] {
        var entries: [Entry] = []
        var seen = Set<String>()
        for url in urls {
            try cancellation?.checkCancelled()
            let standardized = url.standardizedFileURL
            if M4BExporter.isSameFileURL(standardized, dest) { continue }
            let key = standardized.path
            guard seen.insert(key).inserted else { continue }
            guard let entry = try captureEntry(standardized, cancellation: cancellation) else {
                throw BinderError.exportFailed(
                    "Cannot capture source provenance for \(standardized.lastPathComponent)"
                )
            }
            entries.append(entry)
        }
        return entries
    }

    /// Persist pre-encode captures plus the published dest identity and digest.
    @discardableResult
    static func record(
        captured: [Entry],
        dest: URL,
        destIdentity: FileIdentity,
        destinationSHA256: String,
        inBookFolder folder: URL
    ) -> Bool {
        guard !destIdentity.isDirectory, !destinationSHA256.isEmpty else {
            invalidate(inBookFolder: folder)
            return false
        }
        let document = Document(
            sources: captured,
            destination: dest.standardizedFileURL.path,
            destinationIdentity: destIdentity,
            destinationSHA256: destinationSHA256
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
            if let entry = try? captureEntry(standardized, cancellation: nil) {
                entries.append(entry)
            }
        }
        guard let destIdentity = FileIdentity.read(from: dest), !destIdentity.isDirectory,
              let destDigest = sha256Hex(of: dest), !destDigest.isEmpty else {
            invalidate(inBookFolder: folder)
            return false
        }
        return record(
            captured: entries,
            dest: dest,
            destIdentity: destIdentity,
            destinationSHA256: destDigest,
            inBookFolder: folder
        )
    }

    /// Copy captured sources to a temp directory and re-hash each copy.
    /// Throws if a snapshot digest does not match the capture.
    static func stageEncodeSnapshots(
        _ captured: [Entry],
        cancellation: EncodeCancellation? = nil
    ) throws -> (directory: URL, remap: [String: URL]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4b-encode-src-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var remap: [String: URL] = [:]
            for (index, entry) in captured.enumerated() {
                try cancellation?.checkCancelled()
                guard let expected = entry.sha256, !expected.isEmpty else {
                    throw BinderError.exportFailed(
                        "Cannot snapshot source provenance for \(URL(fileURLWithPath: entry.path).lastPathComponent)"
                    )
                }
                let live = URL(fileURLWithPath: entry.path).resolvingSymlinksInPath()
                let snapshot = directory.appendingPathComponent("\(index)-\(live.lastPathComponent)")
                do {
                    try FileManager.default.copyItem(at: live, to: snapshot)
                } catch {
                    throw BinderError.exportFailed("Cannot snapshot \(live.lastPathComponent)")
                }
                guard let digest = try sha256Hex(of: snapshot, cancellation: cancellation), !digest.isEmpty,
                      digest.caseInsensitiveCompare(expected) == .orderedSame else {
                    throw BinderError.exportFailed("Source changed after capture: \(live.lastPathComponent)")
                }
                remap[entry.path] = snapshot
            }
            return (directory, remap)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func removeEncodeSnapshots(at directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    public static func invalidate(inBookFolder folder: URL) {
        let sidecar = sidecarURL(inBookFolder: folder)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return }
        try? FileManager.default.removeItem(at: sidecar)
    }

    static func sha256Hex(of url: URL) -> String? {
        try? sha256Hex(of: url, cancellation: nil)
    }

    static func sha256Hex(of url: URL, cancellation: EncodeCancellation?) throws -> String? {
        let resolved = url.resolvingSymlinksInPath()
        let onMainThread = Thread.isMainThread
        do {
            try cancellation?.checkCancelled()
            let handle = try FileHandle(forReadingFrom: resolved)
            defer { try? handle.close() }
            var hasher = SHA256()
            var bytes = 0
            while true {
                try cancellation?.checkCancelled()
                DigestProbe.noteChunk()
                try cancellation?.checkCancelled()
                let chunk = try handle.read(upToCount: 65_536)
                guard let chunk, !chunk.isEmpty else { break }
                bytes += chunk.count
                hasher.update(data: chunk)
            }
            DigestProbe.record(url: url, bytes: bytes, onMainThread: onMainThread)
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch let error as BinderError {
            if case .cancelled = error { throw error }
            return nil
        } catch is CancellationError {
            throw BinderError.cancelled
        } catch {
            return nil
        }
    }

    private static func captureEntry(
        _ url: URL,
        cancellation: EncodeCancellation? = nil
    ) throws -> Entry? {
        try cancellation?.checkCancelled()
        guard let identity = FileIdentity.readResolved(from: url), !identity.isDirectory else {
            return nil
        }
        guard let digest = try sha256Hex(of: url, cancellation: cancellation), !digest.isEmpty else {
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
        var destinationSHA256: String? = nil
    }
}
