import Foundation

/// Persists the published .m4b path beside the source book folder so rebuilds
/// can find it after a rescan (new `Audiobook.id` UUIDs). Shared output dirs
/// do not put the .m4b inside the book folder.
///
/// The sidecar is a discovery hint. Ownership of an existing file requires a
/// trusted document: dest path, dest `FileIdentity`, and book-folder identity.
public enum OutputAssociation: Sendable {
    public static let fileName = ".audiobookbinder-output"

    /// Trusted dest only. Path-only, old-format, missing, or mismatched
    /// identities do not grant ownership of an existing file.
    public static func load(inBookFolder folder: URL) -> URL? {
        guard let parsed = readDocument(inBookFolder: folder),
              let document = parsed.document else {
            return nil
        }
        let dest = parsed.url
        guard hasM4BExtension(dest), isExistingRegularFile(dest) else { return nil }
        guard let recordedDest = document.destinationIdentity,
              let recordedFolder = document.bookFolderIdentity else {
            return nil
        }
        guard let liveDest = FileIdentity.read(from: dest),
              liveDest.matchesRecordedIdentity(recordedDest) else {
            return nil
        }
        guard let liveFolder = FileIdentity.read(from: folder),
              liveFolder.matchesRecordedIdentity(recordedFolder) else {
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
            return
        }
        do {
            try data.write(to: sidecar, options: .atomic)
        } catch {
            invalidate(sidecar)
        }
    }

    public static func isExistingRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    static func hasM4BExtension(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "m4b"
    }

    private static func readDocument(inBookFolder folder: URL) -> (url: URL, document: Document?)? {
        let sidecar = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: sidecar), !data.isEmpty else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let document = try? decoder.decode(Document.self, from: data) {
            let path = document.destination.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            return (resolve(path, relativeTo: folder), document)
        }

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let line = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
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

    private struct Document: Codable {
        var destination: String
        var destinationIdentity: FileIdentity?
        var bookFolderIdentity: FileIdentity?
    }
}
