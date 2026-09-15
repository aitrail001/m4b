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

/// Cheap view-body decision. Never hashes; only reads a cached result.
public enum SourceCleanupControlsState: Equatable, Sendable {
    case hidden
    case pending
    case allowed(sourceCount: Int)
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
/// still this book's bound file, recorded source identity still matches, and
/// neither dest nor sources have drifted since export/inspect.
public enum SourceCleanup {
    /// View-body helper: cached/pending/cheap guards only. Does not hash.
    public static func controlsState(
        canCleanupSources: Bool,
        isBuilding: Bool,
        cached: SourceCleanupAuthorization?
    ) -> SourceCleanupControlsState {
        guard canCleanupSources, !isBuilding else { return .hidden }
        guard let cached else { return .pending }
        if cached.allowed {
            return .allowed(sourceCount: cached.sources.count)
        }
        return .hidden
    }

    public static func authorization(
        book: Audiobook,
        inspection: M4BInspection,
        isBuilding: Bool,
        alreadyMoved: [URL] = []
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
        guard inspection.identityVerified else {
            return deny(sources, "Inspection is not a stable snapshot of the bound file.")
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
        if let sourceReason = verifyRecordedSources(
            book: book,
            dest: dest,
            alreadyMoved: alreadyMoved
        ) {
            return deny(sources, sourceReason)
        }
        guard !sources.isEmpty else {
            return deny(sources, "No original audio files to remove.")
        }
        return SourceCleanupAuthorization(allowed: true, sources: sources)
    }

    /// One bulk verification, then a last-moment check of only the file about to
    /// be trashed. Dest is re-hashed only if its generation token changes.
    public static func perform(
        book: Audiobook,
        inspection: M4BInspection,
        isBuilding: Bool
    ) -> SourceCleanupResult {
        let initial = authorization(book: book, inspection: inspection, isBuilding: isBuilding)
        guard initial.allowed else {
            return SourceCleanupResult(moved: [], remaining: initial.sources, error: initial.reason)
        }
        guard let dest = book.existingM4BURL,
              let document = SourceAssociation.loadDocument(inBookFolder: book.folder)
        else {
            return SourceCleanupResult(
                moved: [],
                remaining: initial.sources,
                error: "Cannot verify sources: missing export provenance."
            )
        }

        var destToken = destGeneration(of: dest)
        var moved: [URL] = []
        var remaining = initial.sources

        while !remaining.isEmpty {
            if let reason = destStillAuthorized(
                dest: dest,
                book: book,
                inspection: inspection,
                isBuilding: isBuilding,
                document: document,
                destToken: &destToken
            ) {
                return SourceCleanupResult(moved: moved, remaining: remaining, error: reason)
            }
            let next = remaining[0]
            if let reason = verifySingleRecordedSource(
                next,
                dest: dest,
                bookFolder: book.folder,
                document: document
            ) {
                return SourceCleanupResult(moved: moved, remaining: remaining, error: reason)
            }
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

    /// Live dest identity token so an async inspect can refuse a replacement.
    public static func destGeneration(of url: URL) -> String? {
        guard let identity = FileIdentity.read(from: url), !identity.isDirectory else {
            return nil
        }
        return identity.generationToken()
    }

    /// True when this inspect snapshot is still the current book's dest and the
    /// live file has not been replaced since the snapshot was captured.
    public static func shouldCommitInspection(
        _ inspection: M4BInspection,
        bookID: UUID,
        requestedURL: URL,
        currentURL: URL?,
        requestedGeneration: String? = nil
    ) -> Bool {
        guard inspection.identityVerified else { return false }
        if let inspectionBookID = inspection.bookID, inspectionBookID != bookID {
            return false
        }
        guard let currentURL else { return false }
        guard refersToSameFile(requestedURL, inspection.url),
              refersToSameFile(currentURL, inspection.url) else {
            return false
        }
        if let requestedGeneration {
            guard inspection.identityGeneration == requestedGeneration,
                  destGeneration(of: currentURL) == requestedGeneration
            else {
                return false
            }
        }
        guard let live = FileIdentity.read(from: inspection.url), !live.isDirectory else {
            return false
        }
        return live.matches(inspection)
    }

    private static func deny(_ sources: [URL], _ reason: String) -> SourceCleanupAuthorization {
        SourceCleanupAuthorization(allowed: false, sources: sources, reason: reason)
    }

    /// Fail closed unless every recorded source still exists as the same regular file.
    private static func verifyRecordedSources(
        book: Audiobook,
        dest: URL,
        alreadyMoved: [URL]
    ) -> String? {
        guard let document = SourceAssociation.loadDocument(inBookFolder: book.folder) else {
            return "Cannot verify sources: missing export provenance."
        }
        if let reason = verifyRecordedDestination(dest: dest, document: document) {
            return reason
        }
        for entry in document.sources {
            let url = entry.url(relativeTo: book.folder)
            if refersToSameFile(url, dest) { continue }
            if alreadyMoved.contains(where: { refersToSameFile($0, url) }) { continue }
            if let reason = verifyLiveSource(url: url, entry: entry) {
                return reason
            }
        }
        return nil
    }

    /// Cheap dest/inspection guards, plus dest digest only when generation changed.
    private static func destStillAuthorized(
        dest: URL,
        book: Audiobook,
        inspection: M4BInspection,
        isBuilding: Bool,
        document: SourceAssociation.Document,
        destToken: inout String?
    ) -> String? {
        if isBuilding {
            return "Cannot trash sources while a build is running."
        }
        if let inspectionBookID = inspection.bookID, inspectionBookID != book.id {
            return "Inspection is for a different book."
        }
        guard inspection.identityVerified else {
            return "Inspection is not a stable snapshot of the bound file."
        }
        guard refersToSameFile(dest, inspection.url) else {
            return "Inspection is not this book's bound file."
        }
        guard let live = FileIdentity.read(from: dest), !live.isDirectory else {
            return "Bound .m4b is missing or is a folder."
        }
        guard live.matches(inspection) else {
            return "Bound .m4b changed since it was inspected."
        }
        let liveToken = live.generationToken()
        if liveToken != destToken {
            if let reason = verifyRecordedDestination(dest: dest, document: document) {
                return reason
            }
            destToken = liveToken
        }
        return nil
    }

    private static func verifySingleRecordedSource(
        _ url: URL,
        dest: URL,
        bookFolder: URL,
        document: SourceAssociation.Document
    ) -> String? {
        if refersToSameFile(url, dest) {
            return "Cannot verify sources: missing export provenance."
        }
        guard let entry = document.sources.first(where: {
            refersToSameFile($0.url(relativeTo: bookFolder), url)
        }) else {
            return "Cannot verify sources: missing export provenance."
        }
        return verifyLiveSource(url: url, entry: entry)
    }

    private static func verifyRecordedDestination(
        dest: URL,
        document: SourceAssociation.Document
    ) -> String? {
        guard let recordedDest = document.destinationIdentity else {
            return "Cannot verify sources: missing export provenance."
        }
        guard let liveDest = FileIdentity.read(from: dest), !liveDest.isDirectory,
              liveDest.matchesRecordedIdentity(recordedDest) else {
            return "Bound .m4b is not the file recorded at export."
        }
        guard let recordedDestDigest = document.destinationSHA256, !recordedDestDigest.isEmpty else {
            return "Cannot verify sources: missing export provenance."
        }
        guard let liveDestDigest = SourceAssociation.sha256Hex(of: dest),
              !liveDestDigest.isEmpty,
              liveDestDigest.caseInsensitiveCompare(recordedDestDigest) == .orderedSame
        else {
            return "Bound .m4b is not the file recorded at export."
        }
        return nil
    }

    private static func verifyLiveSource(
        url: URL,
        entry: SourceAssociation.Entry
    ) -> String? {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if !exists {
            return "A source file is missing since export."
        }
        if isDirectory.boolValue || !entry.isRegularFile {
            return "A source file is no longer a regular file."
        }
        guard let live = FileIdentity.readResolved(from: url) else {
            return "Cannot read a source file's identity."
        }
        guard live.matchesCaptured(entry) else {
            return "Source files changed since they were bound."
        }
        guard let expectedDigest = entry.sha256, !expectedDigest.isEmpty,
              let liveDigest = SourceAssociation.sha256Hex(of: url),
              liveDigest.caseInsensitiveCompare(expectedDigest) == .orderedSame
        else {
            return "Source files changed since they were bound."
        }
        return nil
    }
}

struct FileIdentity: Equatable, Sendable, Codable {
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

    /// Identity of the object behind `url` (follows a symlink so cleanup can
    /// tell a redirected target from the file that was bound).
    static func readResolved(from url: URL) -> FileIdentity? {
        var resolved = url.resolvingSymlinksInPath()
        resolved.removeAllCachedResourceValues()
        return read(from: resolved)
    }

    func generationToken() -> String {
        let mtime = modificationDate.map { String($0.timeIntervalSince1970) } ?? ""
        let rid = fileResourceIdentifier?.base64EncodedString() ?? ""
        return "\(fileSize)|\(mtime)|\(rid)"
    }

    func isSameVersion(as other: FileIdentity) -> Bool {
        guard !isDirectory, !other.isDirectory else { return false }
        guard fileSize == other.fileSize else { return false }
        switch (modificationDate, other.modificationDate) {
        case (nil, nil):
            break
        case let (expected?, live?):
            if expected != live { return false }
        default:
            return false
        }
        switch (fileResourceIdentifier, other.fileResourceIdentifier) {
        case (nil, nil):
            return true
        case let (expected?, live?):
            if expected == live { return true }
            guard let savedObject = decodeResourceID(expected),
                  let liveObject = decodeResourceID(live) else {
                return false
            }
            return savedObject.isEqual(liveObject)
        default:
            return false
        }
    }

    /// Dest files compare size, mtime (JSON-safe slop), and resource id.
    /// Folders compare resource id only — writing the sidecar updates mtime.
    func matchesRecordedIdentity(_ recorded: FileIdentity) -> Bool {
        if isDirectory || recorded.isDirectory {
            guard isDirectory, recorded.isDirectory else { return false }
            return resourceIdentifierMatches(recorded.fileResourceIdentifier)
        }
        guard fileSize == recorded.fileSize else { return false }
        guard let expectedDate = recorded.modificationDate, let liveDate = modificationDate else {
            return false
        }
        if expectedDate != liveDate,
           abs(expectedDate.timeIntervalSince1970 - liveDate.timeIntervalSince1970) >= 0.002 {
            return false
        }
        return resourceIdentifierMatches(recorded.fileResourceIdentifier)
    }

    func matches(_ inspection: M4BInspection) -> Bool {
        guard inspection.identityVerified else { return false }
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

    func matchesCaptured(_ entry: SourceAssociation.Entry) -> Bool {
        guard !isDirectory, entry.isRegularFile else { return false }
        guard fileSize == entry.fileSize else { return false }
        guard let expectedDate = entry.modificationDate, let liveDate = modificationDate else {
            return false
        }
        // JSON secondsSince1970 can drop a sliver of sub-second precision.
        if expectedDate != liveDate,
           abs(expectedDate.timeIntervalSince1970 - liveDate.timeIntervalSince1970) >= 0.002 {
            return false
        }
        guard let expectedID = entry.fileResourceIdentifier, !expectedID.isEmpty,
              let liveID = fileResourceIdentifier, !liveID.isEmpty else {
            return false
        }
        guard let savedObject = decodeResourceID(expectedID),
              let liveObject = decodeResourceID(liveID) else {
            return false
        }
        return savedObject.isEqual(liveObject)
    }

    private func resourceIdentifierMatches(_ expected: Data?) -> Bool {
        guard let expected, !expected.isEmpty,
              let live = fileResourceIdentifier, !live.isEmpty else {
            return false
        }
        if expected == live { return true }
        guard let savedObject = decodeResourceID(expected),
              let liveObject = decodeResourceID(live) else {
            return false
        }
        return savedObject.isEqual(liveObject)
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
