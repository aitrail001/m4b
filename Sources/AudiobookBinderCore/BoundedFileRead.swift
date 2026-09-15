import Foundation

enum BoundedFileRead {
    static let maxPathLength = 4_096

    /// Streams at most `maxBytes + 1` bytes. Returns nil if missing, empty,
    /// unreadable, or larger than `maxBytes`. Never truncates to accept.
    static func read(from url: URL, maxBytes: Int) -> Data? {
        guard maxBytes > 0 else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1) else { return nil }
        guard !data.isEmpty, data.count <= maxBytes else { return nil }
        return data
    }

    static func isAllowedPath(_ path: String, maxLength: Int = maxPathLength) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maxLength
    }
}
