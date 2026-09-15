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
    static let maxAuthorityScan = 512
    static let pathIndexFileName = "path-index.json"

    /// Trusted dest only. Folder JSON, path-only, old-format, missing, or
    /// mismatched identities do not grant ownership of an existing file.
    public static func load(inBookFolder folder: URL) -> URL? {
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
            return
        }
        do {
            try data.write(to: sidecar, options: .atomic)
        } catch {
            invalidate(sidecar)
            invalidateAuthority(inBookFolder: folder)
            return
        }
        writeAuthority(document)
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
            return loadPathIndex().associationID(for: folderPathKey(folder))
        }
    }

    /// Plants a path-index hint without rewriting authority documents.
    /// Does not remove other keys that already point at `associationID`.
    package static func plantPathIndexHint(_ associationID: UUID, for folder: URL) {
        AuthorityStore.withLock {
            var index = loadPathIndex()
            index.plant(associationID, for: folderPathKey(folder))
            persistPathIndex(index)
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
            let index = loadPathIndex()
            let key = folderPathKey(folder)
            if let id = index.associationID(for: key),
               let document = decodeAuthorityDocument(id: id),
               documentMatchesLiveFolder(document, liveFolder: folderIdentity) {
                return id
            }
            return scanAuthority(matching: folderIdentity)?.associationID
        }
    }

    private static func readAuthority(for folder: URL, liveFolder: FileIdentity) -> Document? {
        AuthorityStore.withLock {
            lookupAuthorityDocument(for: folder, liveFolder: liveFolder)
        }
    }

    /// Path index first. On a miss, scan a bounded number of documents by
    /// semantic folder identity and refresh the index. Callers still verify
    /// live folder / dest identities.
    private static func lookupAuthorityDocument(
        for folder: URL?,
        liveFolder: FileIdentity
    ) -> Document? {
        if let folder {
            let key = folderPathKey(folder)
            let index = loadPathIndex()
            if let id = index.associationID(for: key),
               let document = decodeAuthorityDocument(id: id),
               documentMatchesLiveFolder(document, liveFolder: liveFolder) {
                return document
            }
        }
        guard let document = scanAuthority(matching: liveFolder) else { return nil }
        if let folder, let id = document.associationID {
            var index = loadPathIndex()
            index.set(id, for: folderPathKey(folder), replacing: document.bookFolderPath)
            persistPathIndex(index)
        }
        return document
    }

    private static func writeAuthority(_ document: Document) {
        AuthorityStore.withLock {
            _ = persistAuthorityDocument(document)
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
        var index = loadPathIndex()
        if let folderPath = document.bookFolderPath, !folderPath.isEmpty {
            index.set(id, for: folderPathKey(path: folderPath), replacing: nil)
        }
        persistPathIndex(index)
        return true
    }

    private static func invalidateAuthority(inBookFolder folder: URL) {
        AuthorityStore.withLock {
            var index = loadPathIndex()
            var ids = Set<UUID>()
            let liveIdentity = FileIdentity.read(from: folder).flatMap { $0.isDirectory ? $0 : nil }
            if let liveIdentity,
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
                index.remove(associationID: id)
            }
            persistPathIndex(index)
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
        let dir = AuthorityDirectory.url()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        var scanned = 0
        var match: Document?
        for file in files {
            guard file.pathExtension.lowercased() == "json" else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: name) else { continue }
            scanned += 1
            if scanned > maxAuthorityScan { break }
            guard let document = decodeAuthorityDocument(from: file, expectedID: id),
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

    private static func loadPathIndex() -> PathIndex {
        let url = pathIndexURL()
        guard let data = BoundedFileRead.read(from: url, maxBytes: maxPathIndexBytes) else {
            return PathIndex()
        }
        return (try? JSONDecoder().decode(PathIndex.self, from: data)) ?? PathIndex()
    }

    private static func persistPathIndex(_ index: PathIndex) {
        let url = pathIndexURL()
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(index) else { return }
        try? data.write(to: url, options: .atomic)
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

    static func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
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
