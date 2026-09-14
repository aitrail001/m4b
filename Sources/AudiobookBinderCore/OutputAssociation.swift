import Foundation

/// Persists the published .m4b path beside the source book folder so rebuilds
/// can find it after a rescan (new `Audiobook.id` UUIDs). Shared output dirs
/// do not put the .m4b inside the book folder.
public enum OutputAssociation: Sendable {
    public static let fileName = ".audiobookbinder-output"

    public static func load(inBookFolder folder: URL) -> URL? {
        let sidecar = folder.appendingPathComponent(fileName)
        guard let text = try? String(contentsOf: sidecar, encoding: .utf8) else { return nil }
        let line = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        let url = line.hasPrefix("/")
            ? URL(fileURLWithPath: line)
            : folder.appendingPathComponent(line)
        return url.standardizedFileURL
    }

    public static func record(_ destination: URL, inBookFolder folder: URL) {
        let sidecar = folder.appendingPathComponent(fileName)
        try? destination.standardizedFileURL.path.write(to: sidecar, atomically: true, encoding: .utf8)
    }

    public static func isExistingRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }
}
