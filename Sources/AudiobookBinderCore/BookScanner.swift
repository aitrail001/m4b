import Foundation

public struct BookScanner: Sendable {
    public init() {}

    public func scan(root: URL) async throws -> [Audiobook] {
        let root = root.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw BinderError.noBooksFound(root)
        }

        if hasDirectAudio(root) {
            return [try await loadBook(at: root)]
        }

        let children = bookSubfolders(root)
        if children.count == 1 {
            return [try await loadBook(at: root)]
        }

        var books: [Audiobook] = []
        for child in children {
            if let book = try? await loadBook(at: child) {
                books.append(book)
            }
        }

        if books.isEmpty {
            throw BinderError.noBooksFound(root)
        }
        return books
    }

    public func isSingleBookFolder(_ folder: URL) -> Bool {
        hasDirectAudio(folder) || (bookSubfolders(folder).count <= 1 && !collectAudio(in: folder).isEmpty)
    }

    func hasDirectAudio(_ folder: URL) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return items.contains { audioExtensions.contains($0.pathExtension.lowercased()) && $0.pathExtension.lowercased() != "m4b" }
    }

    func bookSubfolders(_ folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let dirs = items.filter {
            isDirectory($0) && !skippedDirectoryNames.contains($0.lastPathComponent.lowercased())
        }
        return NaturalSort.sorted(dirs, key: { $0.lastPathComponent }).filter { !collectAudio(in: $0).isEmpty }
    }

    public func loadBook(at folder: URL) async throws -> Audiobook {
        let audio = collectAudio(in: folder)
        guard !audio.isEmpty else { throw BinderError.noAudioFiles(folder) }

        let sorted = sortAudio(audio)
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

        try await withThrowingTaskGroup(of: (Int, URL, TimeInterval, Int64, String?).self) { group in
            for (idx, url) in sorted.enumerated() {
                group.addTask {
                    let dur = AudioMetadata.duration(of: url)
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                    var id3: String?
                    if idx == 0 {
                        id3 = firstTags.title
                    }
                    return (idx, url, dur, size, id3)
                }
            }
            var collected: [(Int, URL, TimeInterval, Int64, String?)] = []
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
                        fileSize: row.3
                    )
                )
            }
        }

        return Audiobook(
            folder: folder,
            title: title,
            author: author,
            narrator: narrator,
            bookDescription: description,
            coverURL: coverURL,
            coverJPEG: coverJPEG,
            chapters: chapters
        )
    }

    func collectAudio(in folder: URL) -> [URL] {
        let all = recursiveFiles(in: folder, skipNames: skippedDirectoryNames)
        let preferred = all.filter { url in
            audioExtensions.contains(url.pathExtension.lowercased())
            && url.pathExtension.lowercased() != "m4b"
        }
        if !preferred.isEmpty {
            return dropConcatenatedDuplicates(preferred)
        }
        return recursiveFiles(in: folder, skipNames: ["ebook", "ebooks"])
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) && $0.pathExtension.lowercased() != "m4b" }
    }

    private func dropConcatenatedDuplicates(_ files: [URL]) -> [URL] {
        guard files.count > 2 else { return files }
        let sizes = files.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map { Double($0) }
        guard !sizes.isEmpty else { return files }
        let sortedSizes = sizes.sorted()
        let median = sortedSizes[sortedSizes.count / 2]
        guard median > 0 else { return files }
        return files.filter { url in
            let size = Double((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return size < median * 8
        }
    }

    private func sortAudio(_ files: [URL]) -> [URL] {
        files.sorted { a, b in
            let ia = NaturalSort.leadingIndex(a.lastPathComponent) ?? NaturalSort.trailingIndex(a.lastPathComponent)
            let ib = NaturalSort.leadingIndex(b.lastPathComponent) ?? NaturalSort.trailingIndex(b.lastPathComponent)
            if let ia, let ib, ia != ib { return ia < ib }
            if ia != nil, ib == nil { return true }
            if ia == nil, ib != nil { return false }
            return NaturalSort.compare(a.lastPathComponent, b.lastPathComponent) == .orderedAscending
        }
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
        let candidates = [
            tags.album,
            tags.title,
            opf?.title,
            ebook?.title,
            folderTitle
        ].compactMap { $0 }.map { TitleCleanup.stripEdition(TitleCleanup.collapseSpaces($0)) }
        return candidates.first { $0.count >= 3 } ?? folderTitle
    }

    private func pickAuthor(tags: TrackTags, opf: OPFMetadata?, ebook: (title: String?, author: String?)?) -> String {
        let candidates = [tags.artist, opf?.author, ebook?.author]
            .compactMap { $0 }
            .map { TitleCleanup.collapseSpaces($0) }
            .filter { $0.count >= 2 }
        return candidates.first ?? "Unknown Author"
    }
}
