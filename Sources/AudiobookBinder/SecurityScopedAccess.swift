import Foundation

/// Keeps App Sandbox access to a user-chosen folder until it is replaced.
final class SecurityScopedAccess {
    private(set) var url: URL?
    var isActive: Bool { url != nil }

    func retain(_ url: URL) {
        let next = url.standardizedFileURL
        if self.url?.path == next.path { return }
        self.url?.stopAccessingSecurityScopedResource()
        self.url = nil
        guard next.startAccessingSecurityScopedResource() else { return }
        self.url = next
    }
}

enum SecurityScopedBookmark {
    struct Resolved {
        var url: URL
        var isStale: Bool
    }

    static func data(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolve(_ data: Data) -> Resolved? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return Resolved(url: url, isStale: isStale)
    }
}
