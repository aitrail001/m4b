import Foundation

public struct SourceCleanupAuthorization: Equatable, Sendable {
    public var allowed: Bool
    public var sources: [URL]
    public var reason: String?

    public init(allowed: Bool, sources: [URL], reason: String? = nil) {
        self.allowed = allowed
        self.sources = sources
        self.reason = reason
    }
}

public struct SourceCleanupResult: Equatable, Sendable {
    public var moved: [URL]
    public var remaining: [URL]
    public var error: String?

    public init(moved: [URL], remaining: [URL], error: String? = nil) {
        self.moved = moved
        self.remaining = remaining
        self.error = error
    }

    public var didFinish: Bool { remaining.isEmpty && error == nil }
}

/// Authorize and trash original chapter files only when the inspected dest is
/// still this book's bound file and has not drifted since inspect.
public enum SourceCleanup {
    public static func authorization(
        book: Audiobook,
        inspection: M4BInspection,
        isBuilding: Bool
    ) -> SourceCleanupAuthorization {
        let sources = M4BInspector.sourceFilesToRemove(from: book)

        if isBuilding {
            return deny(sources, "Cannot trash sources while a build is running.")
        }
        guard let dest = book.existingM4BURL else {
            return deny(sources, "This book has no bound .m4b.")
        }
        if let inspectionBookID = inspection.bookID, inspectionBookID != book.id {
            return deny(sources, "Inspection is for a different book.")
        }
        guard refersToSameFile(dest, inspection.url) else {
            return deny(sources, "Inspection is not this book's bound file.")
        }
        guard let live = FileIdentity.read(from: inspection.url), !live.isDirectory else {
            return deny(sources, "Bound .m4b is missing or is a folder.")
        }
        guard live.matches(inspection) else {
            return deny(sources, "Bound .m4b changed since it was inspected.")
        }

        let boundChapters = M4BInspector.playableChapters(from: inspection)
        let summary = ChapterCompare.summary(
            original: book.chapters,
            bound: boundChapters,
            boundDuration: inspection.duration
        )
        guard summary.allMatch else {
            return deny(sources, "Original chapters do not match the .m4b.")
        }
        guard !sources.isEmpty else {
            return deny(sources, "No original audio files to remove.")
        }
        return SourceCleanupAuthorization(allowed: true, sources: sources)
    }

    /// Re-authorizes immediately, then trashes one file at a time.
    public static func perform(
        book: Audiobook,
        inspection: M4BInspection,
        isBuilding: Bool
    ) -> SourceCleanupResult {
        let initial = authorization(book: book, inspection: inspection, isBuilding: isBuilding)
        guard initial.allowed else {
            return SourceCleanupResult(moved: [], remaining: initial.sources, error: initial.reason)
        }

        var moved: [URL] = []
        var remaining = initial.sources

        while !remaining.isEmpty {
            let auth = authorization(book: book, inspection: inspection, isBuilding: isBuilding)
            guard auth.allowed else {
                return SourceCleanupResult(moved: moved, remaining: remaining, error: auth.reason)
            }
            let next = remaining[0]
            do {
                try FileManager.default.trashItem(at: next, resultingItemURL: nil)
                moved.append(next)
                remaining.removeAll { refersToSameFile($0, next) }
            } catch {
                return SourceCleanupResult(
                    moved: moved,
                    remaining: remaining,
                    error: error.localizedDescription
                )
            }
        }
        return SourceCleanupResult(moved: moved, remaining: remaining, error: nil)
    }

    public static func reconcile(chapters: [Chapter], moved: [URL]) -> [Chapter] {
        chapters.filter { chapter in
            !moved.contains { refersToSameFile($0, chapter.url) }
        }
    }

    public static func refersToSameFile(_ a: URL, _ b: URL) -> Bool {
        M4BExporter.isSameFileURL(a, b)
    }

    /// True when this inspect snapshot is still the current book's dest and the
    /// live file has not been replaced since the snapshot was captured.
    public static func shouldCommitInspection(
        _ inspection: M4BInspection,
        bookID: UUID,
        requestedURL: URL,
        currentURL: URL?
    ) -> Bool {
        if let inspectionBookID = inspection.bookID, inspectionBookID != bookID {
            return false
        }
        guard let currentURL else { return false }
        guard refersToSameFile(requestedURL, inspection.url),
              refersToSameFile(currentURL, inspection.url) else {
            return false
        }
        guard let live = FileIdentity.read(from: inspection.url), !live.isDirectory else {
            return false
        }
        return live.matches(inspection)
    }

    private static func deny(_ sources: [URL], _ reason: String) -> SourceCleanupAuthorization {
        SourceCleanupAuthorization(allowed: false, sources: sources, reason: reason)
    }
}

struct FileIdentity: Equatable, Sendable {
    var fileSize: Int64
    var modificationDate: Date?
    var fileResourceIdentifier: Data?
    var isDirectory: Bool

    static func read(from url: URL) -> FileIdentity? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        // URL.resourceValues can cache size/mtime on the URL value; always read live attrs.
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        var fresh = URL(fileURLWithPath: url.path)
        fresh.removeAllCachedResourceValues()
        let resourceID = try? fresh.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        return FileIdentity(
            fileSize: size,
            modificationDate: attrs?[.modificationDate] as? Date,
            fileResourceIdentifier: encodeResourceID(resourceID),
            isDirectory: isDirectory.boolValue
        )
    }

    func matches(_ inspection: M4BInspection) -> Bool {
        guard !isDirectory else { return false }
        guard fileSize == inspection.fileSize else { return false }
        if let expected = inspection.modificationDate {
            guard let live = modificationDate, live == expected else { return false }
        }
        if let expected = inspection.fileResourceIdentifier, !expected.isEmpty {
            guard let live = fileResourceIdentifier, !live.isEmpty else { return false }
            if let savedObject = decodeResourceID(expected),
               let liveObject = decodeResourceID(live) {
                guard savedObject.isEqual(liveObject) else { return false }
            }
        }
        return true
    }

    private static func encodeResourceID(
        _ id: (any NSCopying & NSSecureCoding & NSObjectProtocol)?
    ) -> Data? {
        guard let id else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: id, requiringSecureCoding: false)
    }

    private func decodeResourceID(_ data: Data) -> NSObject? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSObject.self], from: data) as? NSObject
    }
}
