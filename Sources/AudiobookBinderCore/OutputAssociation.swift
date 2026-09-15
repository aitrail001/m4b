import CryptoKit
import Foundation

/// Persists the published .m4b path beside the source book folder so rebuilds
/// can find it after a rescan (new `Audiobook.id` UUIDs). Shared output dirs
/// do not put the .m4b inside the book folder.
///
/// The in-folder sidecar is a discovery / unused-path naming hint only.
/// Ownership of an existing file requires an app-issued record stored outside
/// the untrusted book folder.
public enum OutputAssociation: Sendable {
    public static let fileName = ".audiobookbinder-output"
    static let maxSidecarBytes = 16 * 1024
    static let maxPathLength = BoundedFileRead.maxPathLength

    /// Trusted dest only. Folder JSON, path-only, old-format, missing, or
    /// mismatched identities do not grant ownership of an existing file.
    public static func load(inBookFolder folder: URL) -> URL? {
        guard let liveFolder = FileIdentity.read(from: folder), liveFolder.isDirectory else {
            return nil
        }
        guard let document = readAuthority(for: liveFolder) else { return nil }
        let dest = resolve(document.destination, relativeTo: folder)
        guard hasM4BExtension(dest), isExistingRegularFile(dest) else { return nil }
        guard let recordedDest = document.destinationIdentity,
              let recordedFolder = document.bookFolderIdentity else {
            return nil
        }
        guard let liveDest = FileIdentity.read(from: dest),
              liveDest.matchesRecordedIdentity(recordedDest) else {
            return nil
        }
        guard liveFolder.matchesRecordedIdentity(recordedFolder) else {
            return nil
        }
        return dest
    }

    /// Parsed dest path when the last component is `.m4b`. Unused paths may be
    /// reused as a naming hint; existing files still need `load`.
    static func destinationHint(inBookFolder folder: URL) -> URL? {
        guard let dest = readDocument(inBookFolder: folder)?.url else { return nil }
        guard hasM4BExtension(dest) else { return nil }
        return dest
    }

    public static func record(_ destination: URL, inBookFolder folder: URL) {
        let sidecar = folder.appendingPathComponent(fileName)
        let dest = destination.standardizedFileURL
        guard hasM4BExtension(dest),
              let destIdentity = FileIdentity.read(from: dest),
              !destIdentity.isDirectory,
              let folderIdentity = FileIdentity.read(from: folder),
              folderIdentity.isDirectory
        else {
            invalidate(sidecar)
            invalidateAuthority(inBookFolder: folder)
            return
        }
        let document = Document(
            destination: dest.path,
            destinationIdentity: destIdentity,
            bookFolderIdentity: folderIdentity
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(document) else {
            invalidate(sidecar)
            invalidateAuthority(inBookFolder: folder)
            return
        }
        do {
            try data.write(to: sidecar, options: .atomic)
        } catch {
            invalidate(sidecar)
            invalidateAuthority(inBookFolder: folder)
            return
        }
        writeAuthority(document, folderIdentity: folderIdentity)
    }

    public static func isExistingRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    static func hasM4BExtension(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "m4b"
    }

    /// Test override. Nil uses the XCTest temp store or Application Support.
    package static var authorityDirectoryOverride: URL? {
        get { AuthorityDirectory.override }
        set { AuthorityDirectory.override = newValue }
    }

    package static func resolvedAuthorityDirectory() -> URL {
        AuthorityDirectory.url()
    }

    private static func readDocument(inBookFolder folder: URL) -> (url: URL, document: Document?)? {
        let sidecar = folder.appendingPathComponent(fileName)
        guard let data = BoundedFileRead.read(from: sidecar, maxBytes: maxSidecarBytes) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let document = try? decoder.decode(Document.self, from: data) {
            let path = document.destination.trimmingCharacters(in: .whitespacesAndNewlines)
            guard BoundedFileRead.isAllowedPath(path, maxLength: maxPathLength) else { return nil }
            return (resolve(path, relativeTo: folder), document)
        }

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let line = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let line, BoundedFileRead.isAllowedPath(line, maxLength: maxPathLength) else { return nil }
        return (resolve(line, relativeTo: folder), nil)
    }

    private static func resolve(_ line: String, relativeTo folder: URL) -> URL {
        let url = line.hasPrefix("/")
            ? URL(fileURLWithPath: line)
            : folder.appendingPathComponent(line)
        return url.standardizedFileURL
    }

    private static func invalidate(_ sidecar: URL) {
        try? FileManager.default.removeItem(at: sidecar)
    }

    private static func authorityKey(for folderIdentity: FileIdentity) -> String? {
        guard let rid = folderIdentity.fileResourceIdentifier, !rid.isEmpty else { return nil }
        return SHA256.hash(data: rid).map { String(format: "%02x", $0) }.joined()
    }

    private static func authorityURL(for folderIdentity: FileIdentity) -> URL? {
        guard let key = authorityKey(for: folderIdentity) else { return nil }
        return AuthorityDirectory.url().appendingPathComponent("\(key).json")
    }

    private static func readAuthority(for folderIdentity: FileIdentity) -> Document? {
        guard let url = authorityURL(for: folderIdentity),
              let data = BoundedFileRead.read(from: url, maxBytes: maxSidecarBytes) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let document = try? decoder.decode(Document.self, from: data) else { return nil }
        let path = document.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BoundedFileRead.isAllowedPath(path, maxLength: maxPathLength) else { return nil }
        return document
    }

    private static func writeAuthority(_ document: Document, folderIdentity: FileIdentity) {
        guard let url = authorityURL(for: folderIdentity) else { return }
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(document) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func invalidateAuthority(inBookFolder folder: URL) {
        guard let identity = FileIdentity.read(from: folder) else { return }
        guard let url = authorityURL(for: identity) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private struct Document: Codable {
        var destination: String
        var destinationIdentity: FileIdentity?
        var bookFolderIdentity: FileIdentity?
    }
}

private enum AuthorityDirectory {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var overrideURL: URL?

    static var `override`: URL? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return overrideURL
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            overrideURL = newValue
        }
    }

    static func url() -> URL {
        if let overrideURL = `override` {
            return overrideURL
        }
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "AudiobookBinder-xctest-output-authority-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("AudiobookBinder", isDirectory: true)
            .appendingPathComponent("output-authority", isDirectory: true)
    }
}
