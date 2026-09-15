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
    static let maxPathIndexBytes = 256 * 1024
    static let maxAuthorityScan = 100_000
    static let pathIndexFileName = "path-index.json"

    /// Trusted dest only. Folder JSON, path-only, old-format, missing, or
    /// mismatched identities do not grant ownership of an existing file.
    public static func load(inBookFolder folder: URL) -> URL? {
        loadVerified(inBookFolder: folder)?.url
    }

    /// Dest URL plus the live identity that passed the same checks as `load`.
    static func loadVerified(inBookFolder folder: URL) -> (url: URL, identity: FileIdentity)? {
        guard let liveFolder = FileIdentity.read(from: folder), liveFolder.isDirectory else {
            return nil
        }
        guard let document = readAuthority(for: folder, liveFolder: liveFolder) else { return nil }
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
        return (dest, liveDest)
    }

    /// Parsed dest path when the last component is `.m4b`. Unused paths may be
    /// reused as a naming hint; existing files still need `load`.
    static func destinationHint(inBookFolder folder: URL) -> URL? {
        guard let dest = readDocument(inBookFolder: folder)?.url else { return nil }
        guard hasM4BExtension(dest) else { return nil }
        return dest
    }

    @discardableResult
    public static func record(_ destination: URL, inBookFolder folder: URL) -> Bool {
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
            return false
        }
        let document = Document(
            associationID: existingAssociationID(for: folder, folderIdentity: folderIdentity) ?? UUID(),
            destination: dest.path,
            destinationIdentity: destIdentity,
            bookFolderIdentity: folderIdentity,
            bookFolderPath: folder.standardizedFileURL.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(document) else {
            invalidate(sidecar)
            invalidateAuthority(inBookFolder: folder)
            return false
        }
        do {
            try data.write(to: sidecar, options: .atomic)
        } catch {
            invalidate(sidecar)
            invalidateAuthority(inBookFolder: folder)
            return false
        }
        _ = writeAuthority(document)
        if let associated = load(inBookFolder: folder),
           M4BExporter.isSameFileURL(associated, dest) {
            return true
        }
        invalidate(sidecar)
        invalidateAuthority(inBookFolder: folder)
        return false
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

    /// Times `scanAuthority` ran. Tests reset this around isolated stores.
    package static func authorityScanCount() -> Int {
        AuthorityStore.scanCount()
    }

    package static func resetAuthorityScanCount() {
        AuthorityStore.resetScanCount()
    }

    /// UUID-named authority JSON files, excluding `path-index.json`.
    package static func authorityDocumentCount() -> Int {
        AuthorityStore.withLock {
            let dir = AuthorityDirectory.url()
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            ) else {
                return 0
            }
            return files.filter { file in
                file.pathExtension.lowercased() == "json"
                    && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil
            }.count
        }
    }

    package static func recordedAssociationID(inBookFolder folder: URL) -> UUID? {
        AuthorityStore.withLock {
            if let live = FileIdentity.read(from: folder), live.isDirectory,
               let document = lookupAuthorityDocument(for: folder, liveFolder: live) {
                return document.associationID
            }
            if case .loaded(let index) = pathIndexState() {
                return index.associationID(for: folderPathKey(folder))
            }
            return nil
        }
    }

    /// Plants a path-index hint without rewriting authority documents.
    /// Does not remove other keys that already point at `associationID`.
    package static func plantPathIndexHint(_ associationID: UUID, for folder: URL) {
        AuthorityStore.withLock {
            var index: PathIndex
            switch pathIndexState() {
            case .unusable:
                return
            case .missing:
                index = PathIndex()
            case .loaded(let loaded):
                index = loaded
            }
            index.plant(associationID, for: folderPathKey(folder))
            _ = persistPathIndex(index)
        }
    }

    package static func pathIndexByteCount() -> Int? {
        AuthorityStore.withLock {
            let attrs = try? FileManager.default.attributesOfItem(atPath: pathIndexURL().path)
            return (attrs?[.size] as? NSNumber)?.intValue
        }
    }

    package static func isPathIndexLoadable() -> Bool {
        AuthorityStore.withLock {
            if case .loaded = pathIndexState() { return true }
            return false
        }
    }

    package static func writePathIndexJSON(_ data: Data) {
        AuthorityStore.withLock {
            let url = pathIndexURL()
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Pretty-printed index at the largest size that still fits `maxPathIndexBytes`.
    /// Includes `reserved` path → UUID entries (keys standardized like production).
    package static func writeLargestLoadablePathIndex(including reserved: [String: UUID]) -> Int? {
        AuthorityStore.withLock {
            var paths: [String: String] = [:]
            for (path, id) in reserved {
                paths[folderPathKey(path: path)] = id.uuidString
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            func encoded(_ paths: [String: String]) -> Data? {
                try? encoder.encode(PathIndex(paths: paths))
            }
            func filler(_ count: Int) -> [String: String] {
                var trial = paths
                for i in 0..<count {
                    let hex = String(format: "%012x", i)
                    trial["/f/\(i)"] = "ffffffff-0000-4000-8000-\(hex)"
                }
                return trial
            }
            var low = 0
            var high = 20_000
            while low < high {
                let mid = (low + high + 1) / 2
                if let data = encoded(filler(mid)), data.count <= maxPathIndexBytes {
                    low = mid
                } else {
                    high = mid - 1
                }
            }
            paths = filler(low)
            guard let data = encoded(paths), data.count <= maxPathIndexBytes else { return nil }
            let url = pathIndexURL()
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
            } catch {
                return nil
            }
            return data.count
        }
    }

    package static func padPathIndexToExactLimit() -> Int? {
        AuthorityStore.withLock {
            let url = pathIndexURL()
            guard let current = BoundedFileRead.read(from: url, maxBytes: maxPathIndexBytes) else {
                return nil
            }
            var padded = current
            if padded.count < maxPathIndexBytes {
                padded.append(
                    Data(repeating: UInt8(ascii: "\n"), count: maxPathIndexBytes - padded.count)
                )
            }
            do {
                try padded.write(to: url, options: .atomic)
            } catch {
                return nil
            }
            return padded.count
        }
    }

    package static func encodedByteCountIfInsertingPath(_ path: String) -> Int? {
        AuthorityStore.withLock {
            guard case .loaded(var index) = pathIndexState() else { return nil }
            index.set(UUID(), for: folderPathKey(path: path), replacing: nil)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return (try? encoder.encode(index))?.count
        }
    }

    /// UUID-named documents that do not match `matching`. Names sort first so a
    /// later recorded UUID is outside a 512-file prefix after a sorted listing.
    package static func plantSyntheticAuthorityDocuments(count: Int) {
        AuthorityStore.withLock {
            let dir = AuthorityDirectory.url()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970
            for i in 0..<count {
                let hex = String(format: "%012x", i)
                guard let id = UUID(uuidString: "00000000-0000-4000-8000-\(hex)") else { continue }
                let dummyIdentity = FileIdentity(
                    fileSize: Int64(i + 1),
                    modificationDate: nil,
                    fileResourceIdentifier: Data("r6-02-synth-\(i)".utf8),
                    isDirectory: true
                )
                let document = Document(
                    associationID: id,
                    destination: "/tmp/r6-02-synth-\(i).m4b",
                    destinationIdentity: nil,
                    bookFolderIdentity: dummyIdentity,
                    bookFolderPath: "/tmp/r6-02-synth-\(i)"
                )
                guard let data = try? encoder.encode(document) else { continue }
                try? data.write(to: authorityURL(for: id), options: .atomic)
            }
        }
    }

    /// Test helper: swap the stored folder identifier archive without
    /// changing lookup keys or dest bytes.
    package static func replaceStoredBookFolderResourceIdentifier(
        inBookFolder folder: URL,
        with archive: Data
    ) -> Bool {
        AuthorityStore.withLock {
            guard let liveFolder = FileIdentity.read(from: folder), liveFolder.isDirectory else {
                return false
            }
            guard var document = lookupAuthorityDocument(for: folder, liveFolder: liveFolder),
                  var folderIdentity = document.bookFolderIdentity else {
                return false
            }
            folderIdentity.fileResourceIdentifier = archive
            document.bookFolderIdentity = folderIdentity
            return persistAuthorityDocument(document)
        }
    }

    private static func folderPathKey(_ folder: URL) -> String {
        folder.standardizedFileURL.path
    }

    private static func folderPathKey(path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private static func documentMatchesLiveFolder(_ document: Document, liveFolder: FileIdentity) -> Bool {
        guard let recorded = document.bookFolderIdentity else { return false }
        return liveFolder.matchesRecordedIdentity(recorded)
    }

    private static func authorityURL(for associationID: UUID) -> URL {
        AuthorityDirectory.url().appendingPathComponent("\(associationID.uuidString).json")
    }

    private static func pathIndexURL() -> URL {
        AuthorityDirectory.url().appendingPathComponent(pathIndexFileName)
    }

    private static func existingAssociationID(for folder: URL, folderIdentity: FileIdentity) -> UUID? {
        AuthorityStore.withLock {
            if case .loaded(let index) = pathIndexState() {
                let key = folderPathKey(folder)
                if let id = index.associationID(for: key),
                   let document = decodeAuthorityDocument(id: id),
                   documentMatchesLiveFolder(document, liveFolder: folderIdentity) {
                    return id
                }
            }
            if let document = sidecarAuthorityDocument(for: folder, liveFolder: folderIdentity) {
                return document.associationID
            }
            return scanAuthority(matching: folderIdentity)?.associationID
        }
    }

    private static func readAuthority(for folder: URL, liveFolder: FileIdentity) -> Document? {
        AuthorityStore.withLock {
            lookupAuthorityDocument(for: folder, liveFolder: liveFolder)
        }
    }

    /// Path index, then sidecar `associationID`. `load` does not list the
    /// authority store; `record` / invalidate may still `scanAuthority`.
    private static func lookupAuthorityDocument(
        for folder: URL?,
        liveFolder: FileIdentity
    ) -> Document? {
        let state = pathIndexState()
        if let folder, case .loaded(let index) = state {
            let key = folderPathKey(folder)
            if let id = index.associationID(for: key),
               let document = decodeAuthorityDocument(id: id),
               documentMatchesLiveFolder(document, liveFolder: liveFolder) {
                return document
            }
        }
        if let folder,
           let document = sidecarAuthorityDocument(for: folder, liveFolder: liveFolder) {
            rememberPathIfNeeded(state, folder: folder, document: document)
            return document
        }
        return nil
    }

    /// Sidecar is only a file-name hint. Ownership still comes from the
    /// authority UUID document plus `matchesRecordedIdentity`.
    private static func sidecarAuthorityDocument(
        for folder: URL,
        liveFolder: FileIdentity
    ) -> Document? {
        guard let parsed = readDocument(inBookFolder: folder),
              let hint = parsed.document,
              let id = hint.associationID,
              let document = decodeAuthorityDocument(id: id),
              documentMatchesLiveFolder(document, liveFolder: liveFolder)
        else {
            return nil
        }
        return document
    }

    private static func rememberPathIfNeeded(
        _ state: PathIndexState,
        folder: URL,
        document: Document
    ) {
        guard let id = document.associationID else { return }
        var index: PathIndex
        switch state {
        case .unusable:
            return
        case .missing:
            index = PathIndex()
        case .loaded(let loaded):
            index = loaded
        }
        index.set(id, for: folderPathKey(folder), replacing: document.bookFolderPath)
        _ = persistPathIndex(index)
    }

    private static func writeAuthority(_ document: Document) -> Bool {
        AuthorityStore.withLock {
            persistAuthorityDocument(document)
        }
    }

    @discardableResult
    private static func persistAuthorityDocument(_ document: Document) -> Bool {
        guard let id = document.associationID else { return false }
        let url = authorityURL(for: id)
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(document) else {
            removeAuthority(id)
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            removeAuthority(id)
            return false
        }
        switch pathIndexState() {
        case .unusable:
            return false
        case .missing:
            var index = PathIndex()
            if let folderPath = document.bookFolderPath, !folderPath.isEmpty {
                index.set(id, for: folderPathKey(path: folderPath), replacing: nil)
            }
            return persistPathIndex(index)
        case .loaded(var index):
            if let folderPath = document.bookFolderPath, !folderPath.isEmpty {
                index.set(id, for: folderPathKey(path: folderPath), replacing: nil)
            }
            return persistPathIndex(index)
        }
    }

    private static func invalidateAuthority(inBookFolder folder: URL) {
        AuthorityStore.withLock {
            let state = pathIndexState()
            var ids = Set<UUID>()
            let liveIdentity = FileIdentity.read(from: folder).flatMap { $0.isDirectory ? $0 : nil }
            if case .loaded(let index) = state,
               let liveIdentity,
               let id = index.associationID(for: folderPathKey(folder)),
               let document = decodeAuthorityDocument(id: id),
               documentMatchesLiveFolder(document, liveFolder: liveIdentity) {
                ids.insert(id)
            }
            if let liveIdentity,
               let found = scanAuthority(matching: liveIdentity),
               let id = found.associationID {
                ids.insert(id)
            }
            for id in ids {
                removeAuthority(id)
            }
            switch state {
            case .unusable:
                break
            case .missing:
                if !ids.isEmpty {
                    var index = PathIndex()
                    for id in ids {
                        index.remove(associationID: id)
                    }
                    _ = persistPathIndex(index)
                }
            case .loaded(var index):
                for id in ids {
                    index.remove(associationID: id)
                }
                _ = persistPathIndex(index)
            }
        }
    }

    private static func removeAuthority(_ id: UUID) {
        try? FileManager.default.removeItem(at: authorityURL(for: id))
    }

    private static func decodeAuthorityDocument(id: UUID) -> Document? {
        decodeAuthorityDocument(from: authorityURL(for: id), expectedID: id)
    }

    private static func decodeAuthorityDocument(from url: URL, expectedID: UUID? = nil) -> Document? {
        guard let data = BoundedFileRead.read(from: url, maxBytes: maxSidecarBytes) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard var document = try? decoder.decode(Document.self, from: data) else { return nil }
        if document.associationID == nil {
            let name = url.deletingPathExtension().lastPathComponent
            document.associationID = UUID(uuidString: name)
        }
        if let expectedID {
            guard document.associationID == expectedID else { return nil }
        }
        let path = document.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BoundedFileRead.isAllowedPath(path, maxLength: maxPathLength) else { return nil }
        if let folderPath = document.bookFolderPath, !folderPath.isEmpty {
            guard BoundedFileRead.isAllowedPath(folderPath, maxLength: maxPathLength) else {
                return nil
            }
        }
        return document
    }

    private static func scanAuthority(matching folderIdentity: FileIdentity) -> Document? {
        AuthorityStore.incrementScanCountLocked()
        let dir = AuthorityDirectory.url()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        let uuidFiles = files.filter { file in
            file.pathExtension.lowercased() == "json"
                && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var scanned = 0
        var match: Document?
        for file in uuidFiles {
            scanned += 1
            if scanned > maxAuthorityScan { break }
            let name = file.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: name),
                  let document = decodeAuthorityDocument(from: file, expectedID: id),
                  let recorded = document.bookFolderIdentity,
                  folderIdentity.matchesRecordedIdentity(recorded)
            else {
                continue
            }
            if match != nil { return nil }
            match = document
        }
        return match
    }

    private enum PathIndexState {
        case missing
        case loaded(PathIndex)
        case unusable
    }

    private static func pathIndexState() -> PathIndexState {
        let url = pathIndexURL()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }
        if isDirectory.boolValue {
            return .unusable
        }
        guard let data = BoundedFileRead.read(from: url, maxBytes: maxPathIndexBytes) else {
            return .unusable
        }
        guard let index = try? JSONDecoder().decode(PathIndex.self, from: data) else {
            return .unusable
        }
        return .loaded(index)
    }

    @discardableResult
    private static func persistPathIndex(_ index: PathIndex) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(index) else { return false }
        guard data.count <= maxPathIndexBytes else { return false }
        let url = pathIndexURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            return false
        }
        guard let readBack = BoundedFileRead.read(from: url, maxBytes: maxPathIndexBytes),
              (try? JSONDecoder().decode(PathIndex.self, from: readBack)) != nil
        else {
            return false
        }
        return true
    }

    private struct Document: Codable {
        var associationID: UUID?
        var destination: String
        var destinationIdentity: FileIdentity?
        var bookFolderIdentity: FileIdentity?
        var bookFolderPath: String?
    }

    private struct PathIndex: Codable {
        var paths: [String: String] = [:]

        func associationID(for key: String) -> UUID? {
            paths[key].flatMap(UUID.init(uuidString:))
        }

        mutating func set(_ id: UUID, for key: String, replacing oldPath: String?) {
            remove(associationID: id)
            if let oldPath, !oldPath.isEmpty {
                paths.removeValue(forKey: folderPathKey(path: oldPath))
            }
            paths[key] = id.uuidString
        }

        mutating func remove(associationID id: UUID) {
            let value = id.uuidString
            paths = paths.filter { $0.value.caseInsensitiveCompare(value) != .orderedSame }
        }

        mutating func plant(_ id: UUID, for key: String) {
            paths[key] = id.uuidString
        }
    }
}

private enum AuthorityStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scanCountValue = 0

    static func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Call only while holding `withLock`.
    static func incrementScanCountLocked() {
        scanCountValue += 1
    }

    static func scanCount() -> Int {
        withLock { scanCountValue }
    }

    static func resetScanCount() {
        withLock { scanCountValue = 0 }
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
