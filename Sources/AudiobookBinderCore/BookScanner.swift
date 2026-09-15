import Foundation

public struct BookScanner: Sendable {
    private static let audioContainerNames: Set<String> = [
        "mp3", "mp3s", "m4a", "audio", "audios",
        "audiobook", "audiobooks", "tracks", "chapters",
        "files", "media", "music", "sound", "sounds"
    ]

    public init() {}

    public func scan(
        root: URL,
        progress: (@Sendable (JobProgress) -> Void)? = nil
    ) async throws -> [Audiobook] {
        let root = root.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw BinderError.noBooksFound(root)
        }

        let folders = await discoverBookFolders(root, progress: progress)
        var books: [Audiobook] = []
        books.reserveCapacity(folders.count)
        for (index, folder) in folders.enumerated() {
            await emit(progress, .reading(folder, index: index + 1, count: folders.count))
            if let book = try? await loadBook(at: folder) {
                books.append(book)
            }
        }

        if books.isEmpty {
            throw BinderError.noBooksFound(root)
        }
        return books
    }

    public func isSingleBookFolder(_ folder: URL) -> Bool {
        if hasDirectAudio(folder) || hasDirectM4B(folder) { return true }
        let children = bookSubfolders(folder)
        if children.isEmpty { return false }
        if children.count == 1 {
            let child = children[0]
            if isAudioContainerName(child.lastPathComponent) { return true }
            return isSingleBookFolder(child)
        }
        return children.allSatisfy { isDiscOrPartName($0.lastPathComponent) }
    }

    func discoverBookFolders(
        _ folder: URL,
        progress: (@Sendable (JobProgress) -> Void)? = nil
    ) async -> [URL] {
        await emit(progress, .looking(in: folder))
        if hasDirectAudio(folder) {
            return [folder]
        }
        if hasDirectM4B(folder) {
            return [folder]
        }

        let children = await bookSubfolders(folder, progress: progress)
        if children.isEmpty {
            return []
        }

        if children.count == 1 {
            let child = children[0]
            let nested = await discoverBookFolders(child, progress: progress)
            if nested.count > 1 {
                return nested
            }
            // Cover/OPF sit beside mp3/, so the parent is the book.
            if nested.count == 1 && isAudioContainerName(child.lastPathComponent) {
                return [folder]
            }
            return nested
        }

        if children.allSatisfy({ isDiscOrPartName($0.lastPathComponent) }) {
            return [folder]
        }

        var found: [URL] = []
        for child in children {
            found += await discoverBookFolders(child, progress: progress)
        }
        return found
    }

    private func emit(
        _ progress: (@Sendable (JobProgress) -> Void)?,
        _ value: JobProgress
    ) async {
        progress?(value)
        await Task.yield()
    }

    func isAudioContainerName(_ name: String) -> Bool {
        Self.audioContainerNames.contains(name.lowercased())
    }

    func isDiscOrPartName(_ name: String) -> Bool {
        name.range(
            of: #"^(cd|disc|disk|dvd|part|pt|vol|volume)\s*[-._]?\s*\d+$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    func discIndex(inRelativePath path: String) -> Int {
        discIndexes(inRelativePath: path).first ?? 0
    }

    func discIndexes(inRelativePath path: String) -> [Int] {
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 1 else { return [] }
        var indexes: [Int] = []
        for component in components.dropLast() {
            guard isDiscOrPartName(component) else { continue }
            if let match = component.range(of: #"\d+$"#, options: .regularExpression),
               let number = Int(component[match]) {
                indexes.append(number)
            }
        }
        return indexes
    }

    func hasDirectAudio(_ folder: URL) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return items.contains { audioExtensions.contains($0.pathExtension.lowercased()) && $0.pathExtension.lowercased() != "m4b" }
    }

    func hasDirectM4B(_ folder: URL) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return items.contains { $0.pathExtension.lowercased() == "m4b" }
    }

    func bookSubfolders(
        _ folder: URL,
        progress: (@Sendable (JobProgress) -> Void)? = nil
    ) async -> [URL] {
        var kept: [URL] = []
        for dir in candidateSubdirectories(folder) {
            await emit(progress, .checking(dir))
            if !collectAudio(in: dir).isEmpty || !collectM4B(in: dir).isEmpty {
                kept.append(dir)
            }
        }
        return kept
    }

    func bookSubfolders(_ folder: URL) -> [URL] {
        candidateSubdirectories(folder).filter {
            !collectAudio(in: $0).isEmpty || !collectM4B(in: $0).isEmpty
        }
    }

    func candidateSubdirectories(_ folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let dirs = items.filter {
            isDirectory($0) && !skippedDirectoryNames.contains($0.lastPathComponent.lowercased())
        }
        return dirs.sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: NaturalSort.options) == .orderedAscending
        }
    }

    public func loadBook(at folder: URL) async throws -> Audiobook {
        let audio = collectAudio(in: folder)
        if audio.isEmpty {
            return try await loadAlreadyBoundBook(at: folder)
        }

        let sorted = sortAudio(audio, relativeTo: folder)
        let firstTags = await AudioMetadata.loadTags(from: sorted[0], includeArtwork: true)

        var sampleTitles: [String] = []
        if sorted.count > 1 {
            let second = await AudioMetadata.loadTags(from: sorted[1], includeArtwork: false)
            if let t = firstTags.title { sampleTitles.append(t) }
            if let t = second.title { sampleTitles.append(t) }
        } else if let t = firstTags.title {
            sampleTitles.append(t)
        }

        let opf = loadOPF(in: folder)
        let ebookHint = loadEbookFilename(in: folder)
        let folderTitle = TitleCleanup.folderTitle(folder.lastPathComponent)

        let title = pickTitle(
            tags: firstTags,
            opf: opf,
            ebook: ebookHint,
            folderTitle: folderTitle
        )
        let author = pickAuthor(tags: firstTags, opf: opf, ebook: ebookHint)
        let narrator = firstTags.composer ?? ""
        let description = firstTags.comment ?? opf?.description ?? ""

        let coverURL = findCover(in: folder)
        var coverJPEG: Data?
        if let coverURL {
            coverJPEG = CoverJPEG.loadAndNormalize(from: coverURL)
        }
        if coverJPEG == nil, let embedded = firstTags.artwork {
            coverJPEG = CoverJPEG.normalize(embedded)
        }

        let pad = max(2, String(sorted.count).count)
        var chapters: [Chapter] = []
        chapters.reserveCapacity(sorted.count)

        try await withThrowingTaskGroup(of: (Int, URL, TimeInterval, Int64, String?, AudioInfo).self) { group in
            for (idx, url) in sorted.enumerated() {
                group.addTask {
                    let info = AudioMetadata.fileInfo(of: url)
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                    var id3: String?
                    if idx == 0 {
                        id3 = firstTags.title
                    }
                    return (idx, url, info.duration, size, id3, info.audioInfo)
                }
            }
            var collected: [(Int, URL, TimeInterval, Int64, String?, AudioInfo)] = []
            for try await row in group {
                collected.append(row)
            }
            collected.sort { $0.0 < $1.0 }
            for row in collected {
                let titlesDiffer = Set(sampleTitles.map { TitleCleanup.collapseSpaces($0).lowercased() }).count > 1
                let chapterTitle = ChapterNamer.title(
                    filename: row.1.lastPathComponent,
                    index: row.0 + 1,
                    bookTitle: title,
                    album: firstTags.album,
                    id3Title: titlesDiffer ? row.4 : nil,
                    paddedWidth: pad
                )
                chapters.append(
                    Chapter(
                        url: row.1,
                        index: row.0 + 1,
                        title: chapterTitle,
                        duration: row.2,
                        fileSize: row.3,
                        audioInfo: row.5
                    )
                )
            }
        }
        chapters = markSuspectedConcatenations(chapters)

        let leftoverM4B = collectM4B(in: folder).sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: NaturalSort.options) == .orderedAscending
        }.first
        let associated = OutputAssociation.load(inBookFolder: folder)
        let existingM4B: URL?
        if let associated,
           OutputAssociation.hasM4BExtension(associated),
           OutputAssociation.isExistingRegularFile(associated) {
            existingM4B = associated
        } else {
            existingM4B = leftoverM4B
        }
        let leftoverDuration = existingM4B.map { AudioMetadata.fileInfo(of: $0).duration } ?? 0
        return Audiobook(
            folder: folder,
            title: title,
            author: author,
            narrator: narrator,
            bookDescription: description,
            coverURL: coverURL,
            coverJPEG: coverJPEG,
            chapters: chapters,
            existingM4BURL: existingM4B,
            boundDuration: leftoverDuration
        )
    }

    func loadAlreadyBoundBook(at folder: URL) async throws -> Audiobook {
        let m4bs = collectM4B(in: folder).sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: NaturalSort.options) == .orderedAscending
        }
        guard let m4b = m4bs.first else { throw BinderError.noAudioFiles(folder) }

        let firstTags = await AudioMetadata.loadTags(from: m4b, includeArtwork: true)
        let opf = loadOPF(in: folder)
        let ebookHint = loadEbookFilename(in: folder)
        let folderTitle = TitleCleanup.folderTitle(folder.lastPathComponent)
        let title = pickTitle(tags: firstTags, opf: opf, ebook: ebookHint, folderTitle: folderTitle)
        let author = pickAuthor(tags: firstTags, opf: opf, ebook: ebookHint)
        let narrator = firstTags.composer ?? ""
        let description = firstTags.comment ?? opf?.description ?? ""

        let coverURL = findCover(in: folder)
        var coverJPEG: Data?
        if let coverURL {
            coverJPEG = CoverJPEG.loadAndNormalize(from: coverURL)
        }
        if coverJPEG == nil, let embedded = firstTags.artwork {
            coverJPEG = CoverJPEG.normalize(embedded)
        }

        let info = AudioMetadata.fileInfo(of: m4b)
        return Audiobook(
            folder: folder,
            title: title,
            author: author,
            narrator: narrator,
            bookDescription: description,
            coverURL: coverURL,
            coverJPEG: coverJPEG,
            chapters: [],
            selected: false,
            existingM4BURL: m4b,
            boundDuration: info.duration
        )
    }

    func collectM4B(in folder: URL) -> [URL] {
        recursiveFiles(in: folder, skipNames: skippedDirectoryNames)
            .filter { $0.pathExtension.lowercased() == "m4b" }
    }

    func collectAudio(in folder: URL) -> [URL] {
        let all = recursiveFiles(in: folder, skipNames: skippedDirectoryNames)
        let preferred = all.filter { url in
            audioExtensions.contains(url.pathExtension.lowercased())
            && url.pathExtension.lowercased() != "m4b"
        }
        if !preferred.isEmpty {
            return preferred
        }
        return recursiveFiles(in: folder, skipNames: ["ebook", "ebooks"])
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) && $0.pathExtension.lowercased() != "m4b" }
    }

    static func shouldAutoExcludeAsConcatenation(
        fileName: String,
        size: Int64,
        medianSize: Int64,
        fileCount: Int
    ) -> Bool {
        guard fileCount > 2, medianSize > 0, Double(size) >= Double(medianSize) * 8 else { return false }
        if looksLikeNumberedChapter(fileName) { return false }
        return looksLikeWholeBookDump(fileName)
    }

    func markSuspectedConcatenations(_ chapters: [Chapter]) -> [Chapter] {
        guard chapters.count > 2 else { return chapters }
        let sortedSizes = chapters.map(\.fileSize).sorted()
        let median = sortedSizes[sortedSizes.count / 2]
        guard median > 0 else { return chapters }
        return chapters.map { chapter in
            guard Self.shouldAutoExcludeAsConcatenation(
                fileName: chapter.url.lastPathComponent,
                size: chapter.fileSize,
                medianSize: median,
                fileCount: chapters.count
            ) else { return chapter }
            var marked = chapter
            marked.included = false
            marked.exclusionReason = "Looks like a concatenated whole-book file."
            return marked
        }
    }

    private static func looksLikeNumberedChapter(_ fileName: String) -> Bool {
        if NaturalSort.leadingIndex(fileName) != nil { return true }
        let stem = (fileName as NSString).deletingPathExtension
        return stem.range(
            of: #"^(chapter|ch)\s*[-._]?\s*\d+"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func looksLikeWholeBookDump(_ fileName: String) -> Bool {
        let stem = (fileName as NSString).deletingPathExtension
        return stem.range(
            of: #"\b(all[\s_-]*in[\s_-]*one|complete|concatenated|full[\s_-]*book|entire)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    public func sortAudio(_ files: [URL], relativeTo root: URL) -> [URL] {
        files.sorted { a, b in
            let relA = relativePath(of: a, to: root)
            let relB = relativePath(of: b, to: root)
            let layoutA = discIndexes(inRelativePath: relA)
            let layoutB = discIndexes(inRelativePath: relB)
            if layoutA != layoutB {
                return layoutA.lexicographicallyPrecedes(layoutB)
            }

            let ia = NaturalSort.leadingIndex(a.lastPathComponent) ?? NaturalSort.trailingIndex(a.lastPathComponent)
            let ib = NaturalSort.leadingIndex(b.lastPathComponent) ?? NaturalSort.trailingIndex(b.lastPathComponent)
            if let ia, let ib, ia != ib { return ia < ib }
            if ia != nil, ib == nil { return true }
            if ia == nil, ib != nil { return false }
            return relA.compare(relB, options: NaturalSort.options) == .orderedAscending
        }
    }

    private func relativePath(of file: URL, to root: URL) -> String {
        let rootParts = root.standardizedFileURL.pathComponents
        let fileParts = file.standardizedFileURL.pathComponents
        if fileParts.starts(with: rootParts) {
            let rest = fileParts.dropFirst(rootParts.count)
            if !rest.isEmpty {
                return rest.joined(separator: "/")
            }
        }
        return file.lastPathComponent
    }

    private func recursiveFiles(in folder: URL, skipNames: Set<String> = []) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if skipNames.contains(url.lastPathComponent.lowercased()) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if values?.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func loadOPF(in folder: URL) -> OPFMetadata? {
        let files = recursiveFiles(in: folder)
        if let opf = files.first(where: { $0.pathExtension.lowercased() == "opf" }) {
            return OPFParser.load(from: opf)
        }
        if let epub = files.first(where: { $0.pathExtension.lowercased() == "epub" }) {
            return OPFParser.loadFromEPUB(epub)
        }
        return nil
    }

    private func loadEbookFilename(in folder: URL) -> (title: String?, author: String?)? {
        let files = recursiveFiles(in: folder)
        let ebook = files.first(where: { ebookExtensions.contains($0.pathExtension.lowercased()) })
        guard let ebook else { return nil }
        return TitleCleanup.fromEbookFilename(ebook.lastPathComponent)
    }

    private func findCover(in folder: URL) -> URL? {
        let files = recursiveFiles(in: folder).filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        if files.isEmpty { return nil }
        let namedCover = files.first { $0.deletingPathExtension().lastPathComponent.lowercased() == "cover" }
        if let namedCover { return namedCover }
        return files.max { a, b in
            let sa = (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sb = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sa < sb
        }
    }

    private func pickTitle(tags: TrackTags, opf: OPFMetadata?, ebook: (title: String?, author: String?)?, folderTitle: String) -> String {
        TitleCleanup.preferredTitle(
            candidates: [tags.album, tags.title, opf?.title, ebook?.title, folderTitle].compactMap { $0 },
            folderTitle: folderTitle
        )
    }

    private func pickAuthor(tags: TrackTags, opf: OPFMetadata?, ebook: (title: String?, author: String?)?) -> String {
        let candidates = [tags.artist, opf?.author, ebook?.author]
            .compactMap { $0 }
            .map { TitleCleanup.collapseSpaces($0) }
            .filter { $0.count >= 2 }
        return candidates.first ?? "Unknown Author"
    }
}
