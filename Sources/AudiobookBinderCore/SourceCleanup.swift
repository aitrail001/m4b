import Darwin
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
    /// Test seam: runs at the start of each perform loop iteration, before dest
    /// revalidation and trash. Production callers never set this.
    nonisolated(unsafe) package static var testingBeforeEachDeletion: (() -> Void)?

    /// Test seam: after the source has been renamed onto the private hold and
    /// that inode has been opened, before verify through the fd. Production
    /// callers never set this.
    nonisolated(unsafe) package static var testingAfterHold: ((_ original: URL, _ held: URL) -> Void)?

    /// Test seam: after the held file has been verified through the open fd,
    /// before dest recheck. Production callers never set this.
    nonisolated(unsafe) package static var testingBeforeTrashHeld: ((_ original: URL, _ held: URL) -> Void)?

    /// Test seam: after dest recheck succeeds, before exclusive copy/trash.
    /// Production callers never set this.
    nonisolated(unsafe) package static var testingAfterDestRecheck: ((_ original: URL, _ held: URL) -> Void)?

    /// Test seam: the URL passed to `trashItem` after exclusive materialize.
    /// Production callers never set this.
    nonisolated(unsafe) package static var testingDidTrash: ((_ url: URL) -> Void)?

    /// View-body helper: cached/pending/cheap guards only. Does not hash.
    public static func controlsState(
        canCleanupSources: Bool,
        isBuilding: Bool,
        cached: SourceCleanupAuthorization?,
        isCleaningUp: Bool = false
    ) -> SourceCleanupControlsState {
        guard canCleanupSources, !isBuilding, !isCleaningUp else { return .hidden }
        guard let cached else { return .pending }
        if cached.allowed {
            return .allowed(sourceCount: cached.sources.count)
        }
        return .hidden
    }

    /// Identity for SwiftUI `.task` restarts. Listed chapter URLs only —
    /// inclusion and exclusion reason do not change authorization.
    public static func verificationCacheKey(
        book: Audiobook,
        inspection: M4BInspection,
        destGeneration: String
    ) -> String {
        let sources = book.chapters
            .map { $0.url.standardizedFileURL.path }
            .joined(separator: ";")
        return [
            book.id.uuidString,
            inspection.url.path,
            inspection.identityGeneration ?? "",
            String(inspection.fileSize),
            destGeneration,
            sources
        ].joined(separator: "|")
    }

    public static func authorization(
        book: Audiobook,
        inspection: M4BInspection,
        isBuilding: Bool,
        alreadyMoved: [URL] = [],
        cancellation: EncodeCancellation? = nil
    ) -> SourceCleanupAuthorization {
        let sources = M4BInspector.sourceFilesToRemove(from: book)

        if cancellation?.isCancelled == true {
            return deny(sources, cancelledReason)
        }
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

        let document = SourceAssociation.loadDocument(inBookFolder: book.folder)
        if let document, !bookOmitsRecordedExportedSource(book, document: document) {
            let boundChapters = M4BInspector.playableChapters(from: inspection)
            let summary = ChapterCompare.summary(
                original: chaptersRepresentedInExport(book, document: document),
                bound: boundChapters,
                boundDuration: inspection.duration
            )
            guard summary.allMatch else {
                return deny(sources, "Original chapters do not match the .m4b.")
            }
        }
        if let sourceReason = verifyRecordedSources(
            book: book,
            dest: dest,
            alreadyMoved: alreadyMoved,
            document: document,
            cancellation: cancellation
        ) {
            return deny(sources, sourceReason)
        }
        guard !sources.isEmpty else {
            return deny(sources, "No original audio files to remove.")
        }
        return SourceCleanupAuthorization(allowed: true, sources: sources)
    }

    /// One bulk verification, then dest revalidation before each hold.
    /// Rename onto a same-directory hold, open that inode immediately, verify
    /// through the fd, dest-recheck, copy verified bytes into an exclusive
    /// file named with the original chapter basename, trash that file, then
    /// unlink the hold entry only if it still names the open inode and
    /// nlink / F_GETPATH confirm that inode left the namespace.
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

        var moved: [URL] = []
        var remaining = initial.sources

        while !remaining.isEmpty {
            testingBeforeEachDeletion?()
            if let reason = destStillAuthorized(
                dest: dest,
                book: book,
                inspection: inspection,
                isBuilding: isBuilding,
                document: document
            ) {
                return SourceCleanupResult(moved: moved, remaining: remaining, error: reason)
            }
            let next = remaining[0]
            let hold: URL
            do {
                hold = try moveSourceToPrivateHold(next)
            } catch {
                return SourceCleanupResult(
                    moved: moved,
                    remaining: remaining,
                    error: error.localizedDescription
                )
            }
            let handle: FileHandle
            do {
                handle = try openHoldForVerify(hold)
            } catch {
                return abortAfterHoldRestore(
                    hold: hold,
                    original: next,
                    moved: moved,
                    remaining: remaining,
                    reason: "Cannot read the held source identity."
                )
            }
            defer { try? handle.close() }
            testingAfterHold?(next, hold)
            if let reason = verifySingleRecordedSource(
                original: next,
                handle: handle,
                dest: dest,
                bookFolder: book.folder,
                document: document
            ) {
                return abortAfterOpenHandleRestore(
                    handle: handle,
                    original: next,
                    moved: moved,
                    remaining: remaining,
                    reason: reason
                )
            }
            guard let verifiedHold = inodeSnapshot(of: handle) else {
                return abortAfterOpenHandleRestore(
                    handle: handle,
                    original: next,
                    moved: moved,
                    remaining: remaining,
                    reason: "Cannot read the held source identity."
                )
            }
            testingBeforeTrashHeld?(next, hold)
            if let reason = destStillAuthorized(
                dest: dest,
                book: book,
                inspection: inspection,
                isBuilding: isBuilding,
                document: document
            ) {
                return abortAfterOpenHandleRestore(
                    handle: handle,
                    expected: verifiedHold,
                    original: next,
                    moved: moved,
                    remaining: remaining,
                    reason: reason
                )
            }
            testingAfterDestRecheck?(next, hold)
            guard let now = inodeSnapshot(of: handle), now == verifiedHold else {
                return abortMismatchedHold(
                    original: next,
                    moved: moved,
                    remaining: remaining
                )
            }
            let exclusive: URL
            do {
                exclusive = try materializeExclusiveCopy(
                    from: handle,
                    original: next,
                    inDirectory: next.deletingLastPathComponent()
                )
            } catch {
                return abortAfterOpenHandleRestore(
                    handle: handle,
                    expected: verifiedHold,
                    original: next,
                    moved: moved,
                    remaining: remaining,
                    reason: error.localizedDescription
                )
            }
            do {
                try FileManager.default.trashItem(at: exclusive, resultingItemURL: nil)
                testingDidTrash?(exclusive)
            } catch {
                try? FileManager.default.removeItem(at: exclusive)
                try? FileManager.default.removeItem(at: exclusive.deletingLastPathComponent())
                return abortAfterOpenHandleRestore(
                    handle: handle,
                    expected: verifiedHold,
                    original: next,
                    moved: moved,
                    remaining: remaining,
                    reason: error.localizedDescription
                )
            }
            try? FileManager.default.removeItem(at: exclusive.deletingLastPathComponent())
            guard let nlinkBefore = linkCount(of: handle) else {
                return abortAfterOpenHandleRestore(
                    handle: handle,
                    expected: verifiedHold,
                    original: next,
                    moved: moved,
                    remaining: remaining,
                    reason: "Cannot read the held source identity."
                )
            }
            if pathNamesHeldInode(hold, expected: verifiedHold, handle: handle) {
                unlinkPath(hold)
            }
            let nlinkDropped = linkCount(of: handle).map { $0 < nlinkBefore } ?? false
            let fullyUnlinked = currentURL(of: handle) == nil
            if nlinkDropped || fullyUnlinked {
                moved.append(next)
                remaining.removeAll { refersToSameFile($0, next) }
                continue
            }
            return abortMismatchedHold(
                original: next,
                moved: moved,
                remaining: remaining,
                reason: verifiedInodeStillLinkedReason
            )
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
            guard let live = FileIdentity.read(from: currentURL), !live.isDirectory else {
                return false
            }
            let snapshot = FileIdentity(
                fileSize: inspection.fileSize,
                modificationDate: inspection.modificationDate,
                fileResourceIdentifier: inspection.fileResourceIdentifier,
                isDirectory: false
            )
            let tokensAgree = inspection.identityGeneration == requestedGeneration
                && live.generationToken() == requestedGeneration
            let sameVersion = live.isSameVersion(as: snapshot) && live.matches(inspection)
            // Token strings may differ when NSKeyedArchiver emits another
            // encoding of the same resource-identifier object.
            guard tokensAgree || sameVersion else {
                return false
            }
        }
        guard let live = FileIdentity.read(from: inspection.url), !live.isDirectory else {
            return false
        }
        return live.matches(inspection)
    }

    private static let destMismatchReason = "Bound .m4b is not the file recorded at export."
    private static let sourceChangedReason = "Source files changed since they were bound."
    private static let holdChangedAfterDestRecheckReason =
        "Held source is no longer the verified file."
    private static let verifiedInodeStillLinkedReason =
        "Verified source is still on disk after Trash."
    private static let cancelledReason = BinderError.cancelled.errorDescription ?? "Cancelled"

    private static func deny(_ sources: [URL], _ reason: String) -> SourceCleanupAuthorization {
        SourceCleanupAuthorization(allowed: false, sources: sources, reason: reason)
    }

    /// Fail closed unless every recorded source still exists as the same regular file.
    private static func verifyRecordedSources(
        book: Audiobook,
        dest: URL,
        alreadyMoved: [URL],
        document: SourceAssociation.Document?,
        cancellation: EncodeCancellation? = nil
    ) -> String? {
        guard let document else {
            return "Cannot verify sources: missing export provenance."
        }
        if cancellation?.isCancelled == true {
            return cancelledReason
        }
        if let reason = verifyRecordedDestination(
            dest: dest,
            document: document,
            cancellation: cancellation
        ) {
            return reason
        }
        for entry in document.sources {
            if cancellation?.isCancelled == true {
                return cancelledReason
            }
            let url = entry.url(relativeTo: book.folder)
            if refersToSameFile(url, dest) { continue }
            if alreadyMoved.contains(where: { refersToSameFile($0, url) }) { continue }
            if !isListedChapter(url, on: book) { continue }
            if let reason = verifyLiveSource(url: url, entry: entry, cancellation: cancellation) {
                return reason
            }
        }
        return nil
    }

    /// True when a recorded exported source is no longer on `book.chapters`
    /// (prior partial cleanup). Dest aliases in the manifest do not count.
    private static func bookOmitsRecordedExportedSource(
        _ book: Audiobook,
        document: SourceAssociation.Document
    ) -> Bool {
        document.sources.contains { entry in
            let url = entry.url(relativeTo: book.folder)
            if let dest = book.existingM4BURL, refersToSameFile(url, dest) {
                return false
            }
            return !isListedChapter(url, on: book)
        }
    }

    /// Chapters still listed that were actually bound, by sidecar provenance.
    /// Deselected-after-export files stay in; never-exported extras do not.
    private static func chaptersRepresentedInExport(
        _ book: Audiobook,
        document: SourceAssociation.Document
    ) -> [Chapter] {
        book.chapters.filter { chapter in
            document.sources.contains { entry in
                refersToSameFile(entry.url(relativeTo: book.folder), chapter.url)
            }
        }
    }

    private static func isListedChapter(_ url: URL, on book: Audiobook) -> Bool {
        book.chapters.contains { refersToSameFile($0.url, url) }
    }

    /// Cheap dest/inspection guards, then dest digest before hold and before trash.
    private static func destStillAuthorized(
        dest: URL,
        book: Audiobook,
        inspection: M4BInspection,
        isBuilding: Bool,
        document: SourceAssociation.Document
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
        return verifyRecordedDestination(dest: dest, document: document)
    }

    /// Same-directory rename to a short hidden name (`.{uuid}`) so NAME_MAX
    /// cannot clip a long basename. Never copy off-volume.
    private static func moveSourceToPrivateHold(_ source: URL) throws -> URL {
        let hold = source.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)")
        try FileManager.default.moveItem(at: source, to: hold)
        return hold
    }

    private enum HeldSourceRestore: Equatable {
        case restored
        case alreadyAtOriginal
        /// Hold still exists; original path is occupied or the move failed.
        case stranded
    }

    /// Put the held object back only when the original path is vacant.
    private static func restoreHeldSource(from hold: URL, to original: URL) -> HeldSourceRestore {
        let fm = FileManager.default
        guard fm.fileExists(atPath: hold.path) else { return .alreadyAtOriginal }
        if fm.fileExists(atPath: original.path) { return .stranded }
        do {
            try fm.moveItem(at: hold, to: original)
            return .restored
        } catch {
            return .stranded
        }
    }

    /// Abort after a failed verify/dest/trash: restore when possible, else name the hold.
    private static func abortAfterHoldRestore(
        hold: URL,
        original: URL,
        moved: [URL],
        remaining: [URL],
        reason: String
    ) -> SourceCleanupResult {
        switch restoreHeldSource(from: hold, to: original) {
        case .restored, .alreadyAtOriginal:
            return SourceCleanupResult(moved: moved, remaining: remaining, error: reason)
        case .stranded:
            let leftover = remaining.filter { !refersToSameFile($0, original) }
            return SourceCleanupResult(
                moved: moved,
                remaining: leftover,
                error: strandedRestoreError(hold: hold, reason: reason)
            )
        }
    }

    /// Restore only the inode held open, via F_GETPATH when that path still
    /// names the fd. Never move a replacement at a stale hold pathname.
    private static func abortAfterOpenHandleRestore(
        handle: FileHandle,
        expected: HeldInodeSnapshot? = nil,
        original: URL,
        moved: [URL],
        remaining: [URL],
        reason: String
    ) -> SourceCleanupResult {
        let snapshot = expected ?? inodeSnapshot(of: handle)
        guard let snapshot,
              let current = currentURL(of: handle),
              pathNamesHeldInode(current, expected: snapshot, handle: handle)
        else {
            return abortMismatchedHold(
                original: original,
                moved: moved,
                remaining: remaining,
                reason: reason
            )
        }
        return abortAfterHoldRestore(
            hold: current,
            original: original,
            moved: moved,
            remaining: remaining,
            reason: reason
        )
    }

    private static func pathNamesHeldInode(
        _ url: URL,
        expected: HeldInodeSnapshot,
        handle: FileHandle
    ) -> Bool {
        guard let pathSnap = inodeSnapshot(at: url),
              let fdSnap = inodeSnapshot(of: handle)
        else {
            return false
        }
        return pathSnap.device == expected.device
            && pathSnap.inode == expected.inode
            && fdSnap.device == expected.device
            && fdSnap.inode == expected.inode
    }

    private static func unlinkPath(_ url: URL) {
        url.withUnsafeFileSystemRepresentation { cPath in
            guard let cPath else { return }
            _ = unlink(cPath)
        }
    }

    private static func linkCount(of handle: FileHandle) -> nlink_t? {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
        return info.st_nlink
    }

    private static func openHoldForVerify(_ hold: URL) throws -> FileHandle {
        try hold.withUnsafeFileSystemRepresentation { cPath in
            guard let cPath else {
                throw POSIXError(.ENOENT)
            }
            let fd = open(cPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
    }

    /// Original chapter basename, truncated to `NAME_MAX` while keeping the extension.
    package static func exclusiveMaterializeFileName(from original: URL) -> String {
        let name = original.lastPathComponent
        let maxBytes = Int(NAME_MAX)
        if name.utf8.count <= maxBytes { return name }
        let ext = original.pathExtension
        if ext.isEmpty {
            return utf8Prefix(name, maxBytes: maxBytes)
        }
        let suffix = ".\(ext)"
        let suffixBytes = suffix.utf8.count
        if suffixBytes >= maxBytes {
            return utf8Prefix(name, maxBytes: maxBytes)
        }
        let stem = (name as NSString).deletingPathExtension
        return utf8Prefix(stem, maxBytes: maxBytes - suffixBytes) + suffix
    }

    /// Bytes of the open handle into a file this process exclusively created,
    /// using the original chapter basename inside a unique hidden directory.
    package static func materializeExclusiveCopy(
        from handle: FileHandle,
        original: URL,
        inDirectory directory: URL
    ) throws -> URL {
        var lastError: Error = POSIXError(.EIO)
        let fileName = exclusiveMaterializeFileName(from: original)
        for _ in 0..<4 {
            let uniqueDir = directory.appendingPathComponent(".\(UUID().uuidString)")
            do {
                try createExclusiveDirectory(uniqueDir)
            } catch let error as POSIXError where error.code == .EEXIST {
                lastError = error
                continue
            }
            let dest = uniqueDir.appendingPathComponent(fileName)
            do {
                try writeExclusiveCopy(from: handle, to: dest)
                return dest
            } catch let error as POSIXError where error.code == .EEXIST {
                lastError = error
                try? FileManager.default.removeItem(at: uniqueDir)
                continue
            } catch {
                try? FileManager.default.removeItem(at: uniqueDir)
                throw error
            }
        }
        throw lastError
    }

    private static func createExclusiveDirectory(_ url: URL) throws {
        try url.withUnsafeFileSystemRepresentation { cPath in
            guard let cPath else { throw POSIXError(.EFAULT) }
            guard mkdir(cPath, S_IRWXU) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    /// Drops trailing Unicode scalars until the UTF-8 byte length fits.
    private static func utf8Prefix(_ string: String, maxBytes: Int) -> String {
        if maxBytes <= 0 { return "" }
        if string.utf8.count <= maxBytes { return string }
        var used = 0
        var scalars = String.UnicodeScalarView()
        for scalar in string.unicodeScalars {
            let n = scalar.utf8.count
            if used + n > maxBytes { break }
            scalars.append(scalar)
            used += n
        }
        return String(scalars)
    }

    private static func writeExclusiveCopy(from handle: FileHandle, to dest: URL) throws {
        try dest.withUnsafeFileSystemRepresentation { cPath in
            guard let cPath else { throw POSIXError(.EFAULT) }
            let fd = open(cPath, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, S_IRUSR | S_IWUSR)
            if fd < 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { close(fd) }
            do {
                try handle.seek(toOffset: 0)
                while true {
                    let chunk = try handle.read(upToCount: 65_536)
                    guard let chunk, !chunk.isEmpty else { break }
                    var written = 0
                    while written < chunk.count {
                        let n = chunk.withUnsafeBytes { ptr -> Int in
                            guard let base = ptr.baseAddress else { return -1 }
                            return write(fd, base.advanced(by: written), chunk.count - written)
                        }
                        if n < 0 {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        written += n
                    }
                }
                try? handle.seek(toOffset: 0)
            } catch {
                unlink(cPath)
                throw error
            }
        }
    }

    /// Hold path no longer names the verified object. Do not trash it and do
    /// not move a replacement onto the original path.
    private static func abortMismatchedHold(
        original: URL,
        moved: [URL],
        remaining: [URL],
        reason: String = holdChangedAfterDestRecheckReason
    ) -> SourceCleanupResult {
        if FileManager.default.fileExists(atPath: original.path) {
            let leftover = remaining.filter { !refersToSameFile($0, original) }
            return SourceCleanupResult(
                moved: moved,
                remaining: leftover,
                error: reason
            )
        }
        return SourceCleanupResult(
            moved: moved,
            remaining: remaining,
            error: reason
        )
    }

    private struct HeldInodeSnapshot: Equatable {
        var device: dev_t
        var inode: ino_t
        var size: off_t
        var mtimeSec: time_t
        var mtimeNsec: Int
    }

    private static func inodeSnapshot(of handle: FileHandle) -> HeldInodeSnapshot? {
        snapshot(from: { fstat(handle.fileDescriptor, &$0) })
    }

    private static func inodeSnapshot(at url: URL) -> HeldInodeSnapshot? {
        url.withUnsafeFileSystemRepresentation { cPath in
            guard let cPath else { return nil }
            return snapshot(from: { lstat(cPath, &$0) })
        }
    }

    private static func snapshot(from statFn: (inout stat) -> Int32) -> HeldInodeSnapshot? {
        var info = stat()
        guard statFn(&info) == 0 else { return nil }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return HeldInodeSnapshot(
            device: info.st_dev,
            inode: info.st_ino,
            size: info.st_size,
            mtimeSec: info.st_mtimespec.tv_sec,
            mtimeNsec: info.st_mtimespec.tv_nsec
        )
    }

    /// Current directory entry for the open inode. Fails if the inode is unlinked.
    private static func currentURL(of handle: FileHandle) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let status = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            return fcntl(handle.fileDescriptor, F_GETPATH, base)
        }
        guard status == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func strandedRestoreError(hold: URL, reason: String) -> String {
        let restoreNote = "Could not restore held source; it remains at \(hold.path)."
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return restoreNote }
        return "\(trimmed) \(restoreNote)"
    }

    /// Match the sidecar entry by the original path, then identity-check the
    /// already-open hold inode (fstat size/mtime, resource-id only if
    /// F_GETPATH still names that inode, digest through the same handle).
    private static func verifySingleRecordedSource(
        original: URL,
        handle: FileHandle,
        dest: URL,
        bookFolder: URL,
        document: SourceAssociation.Document
    ) -> String? {
        if refersToSameFile(original, dest) {
            return "Cannot verify sources: missing export provenance."
        }
        guard let entry = document.sources.first(where: {
            refersToSameFile($0.url(relativeTo: bookFolder), original)
        }) else {
            return "Cannot verify sources: missing export provenance."
        }
        return verifyLiveSource(handle: handle, entry: entry, recordedAs: original)
    }

    private static func verifyLiveSource(
        handle: FileHandle,
        entry: SourceAssociation.Entry,
        recordedAs url: URL,
        cancellation: EncodeCancellation? = nil
    ) -> String? {
        guard entry.isRegularFile, let snap = inodeSnapshot(of: handle) else {
            return "Cannot read a source file's identity."
        }
        guard snap.size == entry.fileSize else {
            return sourceChangedReason
        }
        guard let expectedDate = entry.modificationDate else {
            return sourceChangedReason
        }
        let liveDate = Date(
            timeIntervalSince1970: TimeInterval(snap.mtimeSec)
                + TimeInterval(snap.mtimeNsec) / 1_000_000_000
        )
        if expectedDate != liveDate,
           abs(expectedDate.timeIntervalSince1970 - liveDate.timeIntervalSince1970) >= 0.002 {
            return sourceChangedReason
        }
        guard let current = currentURL(of: handle),
              pathNamesHeldInode(current, expected: snap, handle: handle),
              let identity = FileIdentity.read(from: current),
              !identity.isDirectory
        else {
            return "Cannot read a source file's identity."
        }
        guard identity.matchesCapturedResourceIdentifier(entry) else {
            return sourceChangedReason
        }
        let liveDigest: String?
        do {
            liveDigest = try SourceAssociation.sha256Hex(
                of: handle,
                recordedAs: url,
                cancellation: cancellation
            )
        } catch BinderError.cancelled {
            return cancelledReason
        } catch is CancellationError {
            return cancelledReason
        } catch {
            liveDigest = nil
        }
        guard let expectedDigest = entry.sha256, !expectedDigest.isEmpty,
              let liveDigest,
              liveDigest.caseInsensitiveCompare(expectedDigest) == .orderedSame
        else {
            return sourceChangedReason
        }
        return nil
    }

    private static func verifyRecordedDestination(
        dest: URL,
        document: SourceAssociation.Document,
        cancellation: EncodeCancellation? = nil
    ) -> String? {
        guard let recordedDest = document.destinationIdentity else {
            return "Cannot verify sources: missing export provenance."
        }
        guard let liveDest = FileIdentity.read(from: dest), !liveDest.isDirectory,
              liveDest.matchesRecordedIdentity(recordedDest) else {
            return destMismatchReason
        }
        guard let recordedDestDigest = document.destinationSHA256, !recordedDestDigest.isEmpty else {
            return "Cannot verify sources: missing export provenance."
        }
        let liveDestDigest: String?
        do {
            liveDestDigest = try SourceAssociation.sha256Hex(of: dest, cancellation: cancellation)
        } catch BinderError.cancelled {
            return cancelledReason
        } catch is CancellationError {
            return cancelledReason
        } catch {
            liveDestDigest = nil
        }
        guard let liveDestDigest,
              !liveDestDigest.isEmpty,
              liveDestDigest.caseInsensitiveCompare(recordedDestDigest) == .orderedSame
        else {
            return destMismatchReason
        }
        return nil
    }

    private static func verifyLiveSource(
        url: URL,
        entry: SourceAssociation.Entry,
        cancellation: EncodeCancellation? = nil
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
            return sourceChangedReason
        }
        let liveDigest: String?
        do {
            liveDigest = try SourceAssociation.sha256Hex(of: url, cancellation: cancellation)
        } catch BinderError.cancelled {
            return cancelledReason
        } catch is CancellationError {
            return cancelledReason
        } catch {
            liveDigest = nil
        }
        guard let expectedDigest = entry.sha256, !expectedDigest.isEmpty,
              let liveDigest,
              liveDigest.caseInsensitiveCompare(expectedDigest) == .orderedSame
        else {
            return sourceChangedReason
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
        return "\(fileSize)|\(mtime)|\(canonicalResourceIdentifierToken())"
    }

    /// Stable across NSKeyedArchiver encodings of the same identifier object.
    /// Still changes when the file object itself is replaced, so dest digest
    /// is re-checked after a same-size restored-mtime swap.
    private func canonicalResourceIdentifierToken() -> String {
        guard let data = fileResourceIdentifier, !data.isEmpty else { return "" }
        if let object = Self.decodeResourceID(data) as? NSData {
            return (object as Data).base64EncodedString()
        }
        return data.base64EncodedString()
    }

    package func replacingResourceIdentifier(_ archive: Data) -> FileIdentity {
        var copy = self
        copy.fileResourceIdentifier = archive
        return copy
    }

    /// Another NSKeyedArchiver blob for the same decoded identifier object.
    package static func alternateResourceIdentifierArchive(_ data: Data) -> Data? {
        guard let object = decodeResourceID(data) else { return nil }

        func accepts(_ candidate: Data?) -> Data? {
            guard let candidate, candidate != data,
                  let decoded = decodeResourceID(candidate),
                  decoded.isEqual(object)
            else {
                return nil
            }
            return candidate
        }

        if let encoded = accepts(encodeObject(object)) { return encoded }
        if let encoded = accepts(encodeObject(object, requiringSecureCoding: true)) {
            return encoded
        }
        for _ in 0..<64 {
            if let encoded = accepts(encodeObject(object)) { return encoded }
        }
        return accepts(tweakKeyedArchive(data))
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
            guard let savedObject = Self.decodeResourceID(expected),
                  let liveObject = Self.decodeResourceID(live) else {
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
            if let savedObject = Self.decodeResourceID(expected),
               let liveObject = Self.decodeResourceID(live) {
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
        return matchesCapturedResourceIdentifier(entry)
    }

    func matchesCapturedResourceIdentifier(_ entry: SourceAssociation.Entry) -> Bool {
        guard !isDirectory, entry.isRegularFile else { return false }
        guard let expectedID = entry.fileResourceIdentifier, !expectedID.isEmpty,
              let liveID = fileResourceIdentifier, !liveID.isEmpty else {
            return false
        }
        guard let savedObject = Self.decodeResourceID(expectedID),
              let liveObject = Self.decodeResourceID(liveID) else {
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
        guard let savedObject = Self.decodeResourceID(expected),
              let liveObject = Self.decodeResourceID(live) else {
            return false
        }
        return savedObject.isEqual(liveObject)
    }

    private static func encodeResourceID(
        _ id: (any NSCopying & NSSecureCoding & NSObjectProtocol)?
    ) -> Data? {
        guard let id else { return nil }
        return encodeObject(id)
    }

    private static func encodeObject(
        _ object: Any,
        requiringSecureCoding: Bool = false
    ) -> Data? {
        try? NSKeyedArchiver.archivedData(
            withRootObject: object,
            requiringSecureCoding: requiringSecureCoding
        )
    }

    private static func decodeResourceID(_ data: Data) -> NSObject? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSObject.self], from: data) as? NSObject
    }

    private static func tweakKeyedArchive(_ data: Data) -> Data? {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: Any] else {
            return nil
        }
        plist["__abb_alt_archive"] = "1"
        return try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: format,
            options: 0
        )
    }
}
