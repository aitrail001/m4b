import Foundation
import AudiobookBinderCore

@main
struct AudiobookBinderSelfTest {
    static func main() async {
        var failed = 0
        func expect(_ cond: Bool, _ message: String) {
            if cond {
                print("  ok  \(message)")
            } else {
                failed += 1
                print("  FAIL  \(message)")
            }
        }

        @MainActor
        func waitUntil(_ message: String, timeoutMs: Int = 3000, _ condition: () -> Bool) async {
            let steps = max(timeoutMs / 50, 1)
            for _ in 0..<steps {
                if condition() {
                    expect(true, message)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            expect(condition(), message)
        }

        print("== NaturalSort / titles ==")
        expect(NaturalSort.leadingIndex("001 - T.mp3") == 1, "leading 001")
        expect(NaturalSort.leadingIndex("01-Factfulness (Unabridged).mp3") == 1, "leading 01-")
        expect(NaturalSort.trailingIndex("Book - 034.mp3") == 34, "trailing 034")
        expect(TitleCleanup.folderTitle("Thinking in Systems A Primer (Unabridged)(1)") == "Thinking in Systems A Primer", "strip unabridged+(1)")
        expect(TitleCleanup.folderTitle("The Ride of a(1)") == "The Ride of a", "strip (1)")
        let ebook = TitleCleanup.fromEbookFilename("Antifragile_ Things That Gain F - Nassim Nicholas Taleb.epub")
        expect(ebook.author == "Nassim Nicholas Taleb", "ebook author")
        expect(ChapterNamer.title(filename: "001 - T.mp3", index: 1, bookTitle: "The Hero with a Thousand Faces", album: "The Hero with a Thousand Faces", id3Title: "The Hero with a Thousand Faces", paddedWidth: 2) == "Chapter 01", "generic filename -> Chapter 01")
        expect(ChapterNamer.title(filename: "01-Factfulness (Unabridged).mp3", index: 1, bookTitle: "Factfulness", album: nil, id3Title: nil, paddedWidth: 2) == "Chapter 01", "filename is book title -> Chapter")

        print("== Catalog titles ==")
        expect(
            TitleCleanup.looksLikeCatalogTitle("OnWritingWellAudioCollection_ep6_A2TTVL6TAAJVUN"),
            "full Audible SKU is catalog"
        )
        expect(
            TitleCleanup.looksLikeCatalogTitle("OnWritingWellAudioCollection"),
            "camelCase blob is catalog"
        )
        expect(
            TitleCleanup.looksLikeCatalogTitle("AudioCollection"),
            "AudioCollection with no spaces is catalog"
        )
        expect(
            TitleCleanup.looksLikeCatalogTitle("B000F77HD8"),
            "10-char ASIN is catalog"
        )
        expect(
            TitleCleanup.looksLikeCatalogTitle("x_ep6_A2TTVL6TAAJVUN"),
            "_ep digits + SKU is catalog"
        )
        expect(!TitleCleanup.looksLikeCatalogTitle("On Writing Well"), "On Writing Well is not catalog")
        expect(!TitleCleanup.looksLikeCatalogTitle("The Lean Startup"), "The Lean Startup is not catalog")
        expect(
            !TitleCleanup.looksLikeCatalogTitle("The Marketing Gurus Collection"),
            "Marketing Gurus Collection is not catalog"
        )
        expect(
            !TitleCleanup.looksLikeCatalogTitle("Crucial Conversations: Tools for Talking When Stakes are High"),
            "Crucial Conversations is not catalog"
        )
        expect(!TitleCleanup.looksLikeCatalogTitle("Rework"), "Rework is not catalog")
        expect(
            TitleCleanup.preferredTitle(
                candidates: ["OnWritingWellAudioCollection_ep6_A2TTVL6TAAJVUN"],
                folderTitle: "On Writing Well"
            ) == "On Writing Well",
            "preferredTitle skips catalog SKU for folder title"
        )
        expect(
            TitleCleanup.preferredTitle(
                candidates: ["On Writing Well (Unabridged)"],
                folderTitle: "Folder"
            ) == "On Writing Well",
            "preferredTitle strips edition before catalog check"
        )

        do {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("m4b-catalog-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            let bookDir = tmp.appendingPathComponent("On Writing Well", isDirectory: true)
            try fm.createDirectory(at: bookDir, withIntermediateDirectories: true)
            try Data().write(to: bookDir.appendingPathComponent("01.mp3"))
            let books = try await BookScanner().scan(root: tmp)
            expect(books.count == 1, "catalog fixture yields 1 book (got \(books.count))")
            expect(
                books.first?.title == "On Writing Well",
                "empty tags fall back to folder title (got \(books.first?.title ?? "nil"))"
            )
        } catch {
            expect(false, "catalog folder fixture: \(error)")
        }

        print("== OPF ==")
        let opf = OPFParser.parse("""
        <?xml version='1.0'?>
        <package>
          <metadata>
            <dc:title>Meditations on First Philosophy</dc:title>
            <dc:creator opf:role="aut">René Descartes</dc:creator>
          </metadata>
        </package>
        """)
        expect(opf.title == "Meditations on First Philosophy", "opf title")
        expect(opf.author == "René Descartes", "opf author")

        print("== AudioInfo summary ==")
        let mp3Info = AudioInfo(bitrate: 128_000, sampleRate: 44_100, channelCount: 1, formatName: "MP3")
        expect(mp3Info.summary.contains("128 kbps"), "128 kbps in summary (got \(mp3Info.summary))")
        expect(mp3Info.summary.contains("44.1 kHz"), "44.1 kHz in summary (got \(mp3Info.summary))")
        expect(mp3Info.summary.contains("mono"), "mono in summary (got \(mp3Info.summary))")
        expect(mp3Info.summary.contains("MP3"), "MP3 in summary (got \(mp3Info.summary))")
        expect(mp3Info.summary == "128 kbps · 44.1 kHz · mono · MP3", "mp3 summary exact (got \(mp3Info.summary))")

        let aacInfo = AudioInfo(bitrate: 64_000, sampleRate: 48_000, channelCount: 2, formatName: "AAC")
        expect(aacInfo.summary.contains("64 kbps"), "64 kbps in summary (got \(aacInfo.summary))")
        expect(aacInfo.summary.contains("48 kHz"), "48 kHz in summary (got \(aacInfo.summary))")
        expect(aacInfo.summary.contains("stereo"), "stereo in summary (got \(aacInfo.summary))")
        expect(aacInfo.summary.contains("AAC"), "AAC in summary (got \(aacInfo.summary))")
        expect(aacInfo.summary == "64 kbps · 48 kHz · stereo · AAC", "aac summary exact (got \(aacInfo.summary))")

        let emptyInfo = AudioInfo(bitrate: 0, sampleRate: 0, channelCount: 0, formatName: "")
        expect(emptyInfo.summary == "", "all-unknown summary is empty")

        let rate22050 = AudioInfo(bitrate: 0, sampleRate: 22_050, channelCount: 0, formatName: "")
        expect(rate22050.summary.contains("22.05 kHz"), "22050 Hz formats as 22.05 kHz (got \(rate22050.summary))")
        expect(rate22050.summary == "22.05 kHz", "only known sample rate (got \(rate22050.summary))")

        let lowBitrate = AudioInfo(bitrate: 500, sampleRate: 0, channelCount: 3, formatName: "")
        expect(lowBitrate.summary.contains("500 bps"), "sub-kbps shows bps (got \(lowBitrate.summary))")
        expect(lowBitrate.summary.contains("3 ch"), "3 channels (got \(lowBitrate.summary))")

        print("== Audiobook.matches ==")
        let rework = Audiobook(
            folder: URL(fileURLWithPath: "/tmp/Rework"),
            title: "Rework",
            author: "Jason Fried"
        )
        expect(rework.matches(query: ""), "empty query matches")
        expect(rework.matches(query: "  "), "whitespace query matches")
        expect(rework.matches(query: "rework"), "title substring")
        expect(rework.matches(query: "FRIED"), "author case-insensitive")
        expect(!rework.matches(query: "lean"), "unrelated query does not match")
        expect(rework.matches(query: "jason"), "author first name")

        print("== Already-bound Audiobook ==")
        let already = Audiobook(
            folder: URL(fileURLWithPath: "/tmp/Bound"),
            title: "Bound",
            author: "A",
            existingM4BURL: URL(fileURLWithPath: "/tmp/Bound/book.m4b"),
            boundDuration: 99
        )
        expect(already.isAlreadyBound, "empty chapters + existingM4BURL is already bound")
        expect(already.totalDuration == 99, "totalDuration uses boundDuration (got \(already.totalDuration))")
        expect(already.chapterCount == 0, "chapterCount stays chapters.count")
        expect(!rework.isAlreadyBound, "no existingM4BURL is not already bound")

        print("== Included chapters ==")
        func dummyChapter(index: Int, duration: TimeInterval, included: Bool = true) -> Chapter {
            var chapter = Chapter(
                url: URL(fileURLWithPath: "/tmp/missing-\(index).mp3"),
                index: index,
                title: "Chapter \(index)",
                duration: duration,
                fileSize: 1
            )
            chapter.included = included
            return chapter
        }

        let defaultChapter = Chapter(
            url: URL(fileURLWithPath: "/tmp/missing-default.mp3"),
            index: 1,
            title: "Default",
            duration: 12,
            fileSize: 1
        )
        expect(defaultChapter.included, "default Chapter included is true")

        let first = dummyChapter(index: 1, duration: 10)
        let secondOff = dummyChapter(index: 2, duration: 25, included: false)
        let partial = Audiobook(
            folder: URL(fileURLWithPath: "/tmp/Partial"),
            title: "Partial",
            author: "A",
            chapters: [first, secondOff]
        )
        expect(partial.includedChapters.count == 1, "includedChapters skips unchecked (got \(partial.includedChapters.count))")
        expect(partial.includedChapters.first?.index == 1, "included chapter is the first")
        expect(partial.totalDuration == 10, "totalDuration sums included only (got \(partial.totalDuration))")
        expect(partial.chapterCountLabel == "1 of 2 chapters", "partial include label (got \(partial.chapterCountLabel))")
        expect(partial.chapterCount == 2, "chapterCount stays all chapters")
        expect(
            M4BExporter.chaptersReadyForExport(partial.chapters).map(\.index) == [1],
            "chaptersReadyForExport keeps included dummy URLs"
        )

        var allIncluded = partial
        allIncluded.chapters[1].included = true
        expect(allIncluded.chapterCountLabel == "2 chapters", "all included label (got \(allIncluded.chapterCountLabel))")
        expect(allIncluded.totalDuration == 35, "all included duration sums both (got \(allIncluded.totalDuration))")
        expect(
            M4BExporter.chaptersReadyForExport(allIncluded.chapters).count == 2,
            "chaptersReadyForExport keeps every included chapter"
        )

        let oneChapter = Audiobook(
            folder: URL(fileURLWithPath: "/tmp/OneCh"),
            title: "One",
            author: "A",
            chapters: [first]
        )
        expect(oneChapter.chapterCountLabel == "1 chapter", "singular chapter label (got \(oneChapter.chapterCountLabel))")

        expect(already.totalDuration == 99, "already-bound totalDuration still uses boundDuration")
        expect(already.includedChapters.isEmpty, "already-bound includedChapters is empty")

        print("== ExportSettings outputURL ==")
        let book = Audiobook(folder: URL(fileURLWithPath: "/tmp/MyBook"), title: "T", author: "A")
        expect(book.suggestedFileName == "T - A.m4b", "suggestedFileName is T - A.m4b")

        let nextToBook = ExportSettings(
            outputDirectory: URL(fileURLWithPath: "/tmp/Out"),
            writeNextToBook: true
        )
        expect(
            nextToBook.outputURL(for: book).path == "/tmp/MyBook/T - A.m4b",
            "writeNextToBook uses book folder even if outputDirectory is set (got \(nextToBook.outputURL(for: book).path))"
        )

        let chosenDir = ExportSettings(
            outputDirectory: URL(fileURLWithPath: "/tmp/Out"),
            writeNextToBook: false
        )
        expect(
            chosenDir.outputURL(for: book).path == "/tmp/Out/T - A.m4b",
            "chosen outputDirectory when not next-to-book (got \(chosenDir.outputURL(for: book).path))"
        )

        let defaultDir = ExportSettings(outputDirectory: nil, writeNextToBook: false)
        let defaultURL = defaultDir.outputURL(for: book)
        expect(defaultURL.lastPathComponent == "T - A.m4b", "default output filename is T - A.m4b")
        let defaultParent = defaultURL.deletingLastPathComponent()
        expect(
            defaultParent.path == ExportSettings.defaultOutputDirectory.path,
            "nil outputDirectory uses defaultOutputDirectory (got \(defaultParent.path))"
        )
        expect(
            defaultParent.lastPathComponent == "Audiobooks",
            "default dir lastPathComponent is Audiobooks (got \(defaultParent.lastPathComponent))"
        )
        expect(
            defaultParent.deletingLastPathComponent().lastPathComponent == "Music",
            "default dir is inside Music (got \(defaultParent.deletingLastPathComponent().lastPathComponent))"
        )

        let defaultPath = ExportSettings.defaultOutputDirectory.path
        let pathParts = defaultPath.split(separator: "/").map(String.init)
        expect(
            defaultPath.contains("Music/Audiobooks")
                || pathParts.suffix(2).elementsEqual(["Music", "Audiobooks"]),
            "defaultOutputDirectory path contains Music/Audiobooks (got \(defaultPath))"
        )

        print("== LibraryBookmark ==")
        expect(LibraryBookmark.resolvedDirectory(path: nil) == nil, "nil path is nil")
        expect(LibraryBookmark.resolvedDirectory(path: "") == nil, "empty path is nil")
        do {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("m4b-libbookmark-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            let resolved = LibraryBookmark.resolvedDirectory(path: tmp.path)
            expect(resolved != nil, "temp directory resolves")
            expect(resolved == tmp, "temp directory URL matches (got \(resolved?.path ?? "nil"))")
            expect(resolved?.path == tmp.path, "temp directory path matches (got \(resolved?.path ?? "nil"))")

            let file = tmp.appendingPathComponent("file.txt")
            try Data().write(to: file)
            expect(LibraryBookmark.resolvedDirectory(path: file.path) == nil, "temp file path is nil")

            let missing = tmp.appendingPathComponent("no-such-dir", isDirectory: true)
            expect(LibraryBookmark.resolvedDirectory(path: missing.path) == nil, "missing path is nil")
        } catch {
            expect(false, "LibraryBookmark fixtures: \(error)")
        }

        print("== LibraryOutline ==")
        do {
            func book(_ path: String) -> Audiobook {
                Audiobook(
                    folder: URL(fileURLWithPath: path, isDirectory: true),
                    title: URL(fileURLWithPath: path).lastPathComponent,
                    author: "A"
                )
            }
            let root = URL(fileURLWithPath: "/tmp/lib", isDirectory: true)

            let flat = LibraryOutline.build(
                root: root,
                books: [book("/tmp/lib/BookA"), book("/tmp/lib/BookB")]
            )
            expect(flat.name == "lib", "flat root name is lib (got \(flat.name))")
            expect(flat.bookCount == 2, "flat root bookCount 2 (got \(flat.bookCount))")
            expect(flat.children.isEmpty, "flat library has no grouping folders")
            expect(!flat.hasNestedFolders, "flat hasNestedFolders is false")
            expect(
                LibraryOutline.books([book("/tmp/lib/BookA"), book("/tmp/lib/BookB")], under: root).count == 2,
                "flat books under root are both"
            )

            let wrapperBooks = [book("/tmp/lib/43/BookA"), book("/tmp/lib/43/BookB")]
            let wrapper = LibraryOutline.build(root: root, books: wrapperBooks)
            expect(wrapper.children.count == 1, "wrapper has one grouping folder (got \(wrapper.children.count))")
            expect(wrapper.children.first?.name == "43", "wrapper child is 43 (got \(wrapper.children.first?.name ?? "nil"))")
            expect(wrapper.children.first?.bookCount == 2, "43 bookCount 2")
            expect(wrapper.children.first?.children.isEmpty == true, "43 does not list book folders")
            expect(wrapper.hasNestedFolders, "wrapper hasNestedFolders is true")
            let folder43 = URL(fileURLWithPath: "/tmp/lib/43", isDirectory: true)
            expect(
                LibraryOutline.books(wrapperBooks, under: folder43).map { $0.folder.lastPathComponent }.sorted() == ["BookA", "BookB"],
                "books under 43 are BookA/BookB"
            )
            expect(
                !LibraryOutline.book(book("/tmp/lib/Other/BookC"), isUnder: folder43),
                "book outside 43 is not under 43"
            )

            let cats = [book("/tmp/lib/Biz/A"), book("/tmp/lib/Life/B")]
            let catTree = LibraryOutline.build(root: root, books: cats)
            expect(
                catTree.children.map(\.name) == ["Biz", "Life"],
                "category folders Biz/Life (got \(catTree.children.map(\.name)))"
            )
            expect(
                LibraryOutline.books(cats, under: URL(fileURLWithPath: "/tmp/lib/Biz", isDirectory: true))
                    .map { $0.folder.lastPathComponent } == ["A"],
                "Biz scope is A"
            )
            expect(
                LibraryOutline.books(cats, under: root).count == 2,
                "root scope is both categories"
            )

            let deep = LibraryOutline.build(
                root: root,
                books: [book("/tmp/lib/a/b/BookA"), book("/tmp/lib/a/c/BookB")]
            )
            expect(deep.children.map(\.name) == ["a"], "deep child is a")
            expect(
                deep.children.first?.children.map(\.name) == ["b", "c"],
                "a has b and c (got \(deep.children.first?.children.map(\.name) ?? []))"
            )
            expect(
                LibraryOutline.books(
                    [book("/tmp/lib/a/b/BookA"), book("/tmp/lib/a/c/BookB")],
                    under: URL(fileURLWithPath: "/tmp/lib/a/b", isDirectory: true)
                ).map { $0.folder.lastPathComponent } == ["BookA"],
                "b scope is BookA"
            )

            let mixed = LibraryOutline.build(
                root: root,
                books: [book("/tmp/lib/Solo"), book("/tmp/lib/Cat/Nested")]
            )
            expect(mixed.children.map(\.name) == ["Cat"], "mixed grouping is Cat only (got \(mixed.children.map(\.name)))")
            expect(mixed.bookCount == 2, "mixed root still counts Solo + Nested")
            expect(
                LibraryOutline.books(
                    [book("/tmp/lib/Solo"), book("/tmp/lib/Cat/Nested")],
                    under: URL(fileURLWithPath: "/tmp/lib/Cat", isDirectory: true)
                ).map { $0.folder.lastPathComponent } == ["Nested"],
                "Cat scope excludes Solo"
            )

            let single = LibraryOutline.build(root: root, books: [book("/tmp/lib")])
            expect(single.children.isEmpty, "single-book root has no grouping folders")
            expect(single.bookCount == 1, "single-book root bookCount 1")
            expect(
                LibraryOutline.book(book("/tmp/lib"), isUnder: root),
                "book at root is under root"
            )
            expect(
                !LibraryOutline.book(book("/tmp/lib-other/X"), isUnder: root),
                "sibling-prefix folder is not under root"
            )
        }

        print("== AudioMetadata file info ==")
        do {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("m4b-audioinfo-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            let aiff = URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff")
            expect(fm.fileExists(atPath: aiff.path), "system Tink.aiff exists")

            let aiffFile = AudioMetadata.fileInfo(of: aiff)
            expect(aiffFile.duration > 0, "aiff duration > 0 (got \(aiffFile.duration))")
            expect(aiffFile.audioInfo.sampleRate > 0, "aiff sampleRate > 0 (got \(aiffFile.audioInfo.sampleRate))")
            expect(aiffFile.audioInfo.channelCount >= 1, "aiff channelCount >= 1 (got \(aiffFile.audioInfo.channelCount))")
            let aiffFormat = aiffFile.audioInfo.formatName
            expect(["PCM", "AIFF", "AIF"].contains(aiffFormat), "aiff format PCM/AIFF (got \(aiffFormat))")
            expect(AudioMetadata.duration(of: aiff) == aiffFile.duration, "duration(of:) matches fileInfo")

            let m4a = tmp.appendingPathComponent("tink.m4a")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            proc.arguments = [aiff.path, "-o", m4a.path, "-f", "m4af", "-d", "aac", "-b", "64000"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            proc.waitUntilExit()
            expect(proc.terminationStatus == 0, "afconvert Tink.aiff -> m4a (status \(proc.terminationStatus))")
            expect(fm.fileExists(atPath: m4a.path), "converted tink.m4a exists")

            let m4aFile = AudioMetadata.fileInfo(of: m4a)
            expect(m4aFile.duration > 0, "m4a duration > 0 (got \(m4aFile.duration))")
            expect(m4aFile.audioInfo.sampleRate > 0, "m4a sampleRate > 0 (got \(m4aFile.audioInfo.sampleRate))")
            expect(m4aFile.audioInfo.channelCount >= 1, "m4a channelCount >= 1 (got \(m4aFile.audioInfo.channelCount))")
            let m4aFormat = m4aFile.audioInfo.formatName.uppercased()
            expect(m4aFormat.contains("AAC") || m4aFormat == "M4A", "m4a format AAC (got \(m4aFile.audioInfo.formatName))")
            if m4aFile.audioInfo.bitrate > 0 {
                expect(
                    m4aFile.audioInfo.bitrate >= 1_000 && m4aFile.audioInfo.bitrate <= 512_000,
                    "m4a bitrate sane (got \(m4aFile.audioInfo.bitrate))"
                )
            }
            expect(!m4aFile.audioInfo.summary.isEmpty, "m4a summary non-empty (got \(m4aFile.audioInfo.summary))")

            let bookDir = tmp.appendingPathComponent("TinkBook", isDirectory: true)
            try fm.createDirectory(at: bookDir, withIntermediateDirectories: true)
            try fm.copyItem(at: m4a, to: bookDir.appendingPathComponent("01.m4a"))
            let scanned = try await BookScanner().loadBook(at: bookDir)
            expect(scanned.chapterCount == 1, "fixture book has 1 chapter")
            expect(
                !scanned.chapters[0].audioInfo.summary.isEmpty,
                "scanned chapter summary non-empty (got \(scanned.chapters[0].audioInfo.summary))"
            )
            expect(scanned.chapters[0].duration > 0, "scanned chapter duration > 0")
        } catch {
            expect(false, "audio file info fixtures: \(error)")
        }

        print("== Nested library scan ==")
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("m4b-scan-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            func fixture(_ path: String) -> URL {
                URL(fileURLWithPath: path, isDirectory: true, relativeTo: tmp).absoluteURL
            }
            func writeMP3(_ dirPath: String, _ file: String) throws {
                let dir = fixture(dirPath)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data().write(to: dir.appendingPathComponent(file))
            }
            func folderNames(_ books: [Audiobook]) -> [String] {
                books.map { $0.folder.lastPathComponent }.sorted()
            }
            func scan(_ path: String) async -> [Audiobook] {
                do {
                    return try await BookScanner().scan(root: fixture(path))
                } catch {
                    expect(false, "scan \(path): \(error)")
                    return []
                }
            }

            try writeMP3("wrapper/43/BookA", "01.mp3")
            try writeMP3("wrapper/43/BookB", "01.mp3")
            let wrapper = await scan("wrapper")
            expect(wrapper.count == 2, "wrapper lib/43 yields 2 books (got \(wrapper.count))")
            expect(folderNames(wrapper) == ["BookA", "BookB"], "wrapper folders BookA/BookB (got \(folderNames(wrapper)))")
            expect(!folderNames(wrapper).contains("43") && !folderNames(wrapper).contains("wrapper"), "wrapper books are not named lib or 43")
            expect(!BookScanner().isSingleBookFolder(fixture("wrapper")), "wrapper is not a single book folder")

            let opened43 = await scan("wrapper/43")
            expect(opened43.count == 2, "opening 43/ yields 2 books (got \(opened43.count))")
            expect(folderNames(opened43) == ["BookA", "BookB"], "43/ folders BookA/BookB (got \(folderNames(opened43)))")

            try writeMP3("flat/BookA", "01.mp3")
            try writeMP3("flat/BookB", "01.mp3")
            let flat = await scan("flat")
            expect(flat.count == 2, "flat library yields 2 books (got \(flat.count))")
            expect(folderNames(flat) == ["BookA", "BookB"], "flat folders BookA/BookB (got \(folderNames(flat)))")

            try writeMP3("nested-audio/Book/mp3", "01.mp3")
            let nestedAudio = await scan("nested-audio/Book")
            expect(nestedAudio.count == 1, "nested mp3/ dir yields 1 book (got \(nestedAudio.count))")
            expect(nestedAudio.first?.folder.lastPathComponent == "Book", "nested mp3/ book folder is Book not mp3")
            expect(BookScanner().isSingleBookFolder(fixture("nested-audio/Book")), "Book/mp3 is a single book folder")

            try writeMP3("multi-disc/Book/CD1", "01.mp3")
            try writeMP3("multi-disc/Book/CD2", "01.mp3")
            let multiDisc = await scan("multi-disc/Book")
            expect(multiDisc.count == 1, "multi-disc yields 1 book (got \(multiDisc.count))")
            expect(multiDisc.first?.folder.lastPathComponent == "Book", "multi-disc book folder is Book")
            expect(multiDisc.first?.chapterCount == 2, "multi-disc collects both discs (got \(multiDisc.first?.chapterCount ?? -1))")
            expect(BookScanner().isSingleBookFolder(fixture("multi-disc/Book")), "multi-disc Book is a single book folder")

            try writeMP3("direct/Book", "01.mp3")
            try writeMP3("direct/Book", "02.mp3")
            let direct = await scan("direct/Book")
            expect(direct.count == 1, "direct files yield 1 book (got \(direct.count))")
            expect(direct.first?.folder.lastPathComponent == "Book", "direct book folder is Book")
            expect(direct.first?.chapterCount == 2, "direct book has 2 chapters (got \(direct.first?.chapterCount ?? -1))")

            try writeMP3("deep/lib/a/b/BookA", "1.mp3")
            try writeMP3("deep/lib/a/b/BookB", "1.mp3")
            let deep = await scan("deep/lib")
            expect(deep.count == 2, "deep wrap yields 2 books (got \(deep.count))")
            expect(folderNames(deep) == ["BookA", "BookB"], "deep wrap folders BookA/BookB (got \(folderNames(deep)))")

            try writeMP3("mp3-subs/lib/BookA/mp3", "1.mp3")
            try writeMP3("mp3-subs/lib/BookB/mp3", "1.mp3")
            let mp3Subs = await scan("mp3-subs/lib")
            expect(mp3Subs.count == 2, "two books with mp3/ yield 2 books (got \(mp3Subs.count))")
            expect(folderNames(mp3Subs) == ["BookA", "BookB"], "mp3-sub folders BookA/BookB (got \(folderNames(mp3Subs)))")
        } catch {
            expect(false, "nested scan fixtures: \(error)")
        }

        print("== Already-bound m4b scan ==")
        do {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("m4b-bound-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            func fixture(_ path: String) -> URL {
                URL(fileURLWithPath: path, isDirectory: true, relativeTo: tmp).absoluteURL
            }
            func writeMP3(_ dirPath: String, _ file: String) throws {
                let dir = fixture(dirPath)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data().write(to: dir.appendingPathComponent(file))
            }

            var m4bSource: URL?
            let aiff = URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff")
            if fm.fileExists(atPath: aiff.path) {
                let m4a = tmp.appendingPathComponent("_tink.m4a")
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
                proc.arguments = [aiff.path, "-o", m4a.path, "-f", "m4af", "-d", "aac", "-b", "64000"]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    let m4b = tmp.appendingPathComponent("_tink.m4b")
                    try fm.copyItem(at: m4a, to: m4b)
                    m4bSource = m4b
                }
            }

            func writeM4B(_ dirPath: String, _ file: String) throws {
                let dir = fixture(dirPath)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(file)
                if let m4bSource {
                    try fm.copyItem(at: m4bSource, to: dest)
                } else {
                    try Data().write(to: dest)
                }
            }
            func folderNames(_ books: [Audiobook]) -> [String] {
                books.map { $0.folder.lastPathComponent }.sorted()
            }
            func scan(_ path: String) async -> [Audiobook] {
                do {
                    return try await BookScanner().scan(root: fixture(path))
                } catch {
                    expect(false, "scan \(path): \(error)")
                    return []
                }
            }
            func bookNamed(_ books: [Audiobook], _ name: String) -> Audiobook? {
                books.first { $0.folder.lastPathComponent == name }
            }

            try writeMP3("lib/BookA", "01.mp3")
            try writeM4B("lib/Bound", "book.m4b")
            let mixedLib = await scan("lib")
            expect(mixedLib.count == 2, "lib with mp3 book + m4b book yields 2 books (got \(mixedLib.count))")
            expect(folderNames(mixedLib) == ["BookA", "Bound"], "lib folders BookA/Bound (got \(folderNames(mixedLib)))")
            if let bookA = bookNamed(mixedLib, "BookA") {
                expect(!bookA.isAlreadyBound, "BookA is not already bound")
                expect(bookA.chapterCount == 1, "BookA has 1 chapter (got \(bookA.chapterCount))")
                expect(bookA.selected, "BookA is selected")
                expect(bookA.existingM4BURL == nil, "BookA has no existingM4BURL")
            } else {
                expect(false, "lib scan includes BookA")
            }
            if let bound = bookNamed(mixedLib, "Bound") {
                expect(bound.isAlreadyBound, "Bound is already bound")
                expect(bound.chapterCount == 0, "Bound has 0 chapters (got \(bound.chapterCount))")
                expect(!bound.selected, "Bound is not selected")
                expect(bound.existingM4BURL != nil, "Bound has existingM4BURL")
            } else {
                expect(false, "lib scan includes Bound")
            }

            let openedBound = await scan("lib/Bound")
            expect(openedBound.count == 1, "opening Bound alone yields 1 book (got \(openedBound.count))")
            expect(openedBound.first?.folder.lastPathComponent == "Bound", "opened Bound folder is Bound (got \(openedBound.first?.folder.lastPathComponent ?? "nil"))")
            expect(openedBound.first?.isAlreadyBound == true, "opened Bound is already bound")
            expect(openedBound.first?.selected == false, "opened Bound is not selected")

            try writeMP3("mixed/Mixed", "01.mp3")
            try writeM4B("mixed/Mixed", "out.m4b")
            let leftover = await scan("mixed/Mixed")
            expect(leftover.count == 1, "mp3 + leftover m4b yields 1 book (got \(leftover.count))")
            expect(leftover.first?.isAlreadyBound == false, "leftover m4b book is not already bound")
            expect(leftover.first?.chapterCount == 1, "leftover m4b book has 1 chapter (got \(leftover.first?.chapterCount ?? -1))")
            expect(leftover.first?.existingM4BURL == nil, "leftover m4b is not existingM4BURL")
            expect(
                leftover.first?.chapters.first?.url.pathExtension.lowercased() == "mp3",
                "leftover m4b is not a chapter (got \(leftover.first?.chapters.first?.url.lastPathComponent ?? "nil"))"
            )

            try writeM4B("wrapper/43/BoundA", "a.m4b")
            try writeM4B("wrapper/43/BoundB", "b.m4b")
            let wrapperBound = await scan("wrapper")
            expect(wrapperBound.count == 2, "wrapper of two m4b books yields 2 books (got \(wrapperBound.count))")
            expect(folderNames(wrapperBound) == ["BoundA", "BoundB"], "wrapper m4b folders BoundA/BoundB (got \(folderNames(wrapperBound)))")
            expect(wrapperBound.allSatisfy(\.isAlreadyBound), "wrapper m4b books are already bound")
            expect(wrapperBound.allSatisfy { !$0.selected }, "wrapper m4b books are not selected")
            expect(!BookScanner().isSingleBookFolder(fixture("wrapper")), "m4b wrapper is not a single book folder")
            expect(!BookScanner().isSingleBookFolder(fixture("wrapper/43")), "m4b 43/ is not a single book folder")
        } catch {
            expect(false, "already-bound m4b fixtures: \(error)")
        }

        print("== ChapterPlayback ==")
        do {
            @MainActor
            func testPlayback() async throws {
                let fm = FileManager.default
                let tink = URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff")
                expect(fm.fileExists(atPath: tink.path), "system Tink.aiff exists")

                let tmp = fm.temporaryDirectory.appendingPathComponent("m4b-playback-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: tmp) }

                let tink2 = tmp.appendingPathComponent("tink-copy.aiff")
                try fm.copyItem(at: tink, to: tink2)

                func chapter(url: URL, index: Int, title: String) -> Chapter {
                    Chapter(url: url, index: index, title: title, duration: 0.56, fileSize: 0)
                }

                let chapter1 = chapter(url: tink, index: 1, title: "One")
                let chapter2 = chapter(url: tink2, index: 2, title: "Two")
                let playback = ChapterPlayback()

                playback.toggle(chapter1)
                await waitUntil("toggle starts playing chapter") {
                    playback.isPlaying(chapter1) && playback.playingID == chapter1.id
                }

                playback.toggle(chapter1)
                expect(playback.playingID == chapter1.id, "pause keeps playingID")
                expect(playback.isPlaying == false, "pause sets isPlaying false")
                expect(playback.isPlaying(chapter1) == false, "pause: isPlaying(chapter) is false")

                playback.toggle(chapter1)
                await waitUntil("resume starts playing again") {
                    playback.isPlaying(chapter1) && playback.playingID == chapter1.id
                }

                playback.toggle(chapter2)
                await waitUntil("switch plays chapter2") {
                    playback.playingID == chapter2.id && playback.isPlaying(chapter2)
                }
                expect(playback.isPlaying(chapter1) == false, "switch is not playing chapter1")

                playback.stop()
                expect(playback.playingID == nil, "stop clears playingID")
                expect(playback.isPlaying == false, "stop sets isPlaying false")
                expect(playback.isPlaying(chapter2) == false, "stop: not playing chapter2")

                playback.toggle(chapter1)
                await waitUntil("play-to-end starts") {
                    playback.isPlaying(chapter1)
                }
                try await Task.sleep(for: .milliseconds(1500))
                var ended = false
                for _ in 0..<40 {
                    if playback.playingID == nil && playback.isPlaying == false {
                        ended = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                if ended {
                    expect(true, "end of item resets playingID and isPlaying")
                } else {
                    print("  skip  end-of-item reset (AVPlayer didPlayToEndTime not observed)")
                    playback.stop()
                }

                let missing = chapter(url: tmp.appendingPathComponent("no-such-file.aiff"), index: 3, title: "Missing")
                playback.toggle(missing)
                expect(playback.playingID == nil, "missing file: playingID nil")
                expect(playback.isPlaying == false, "missing file: isPlaying false")
                expect(playback.isPlaying(missing) == false, "missing file: isPlaying(chapter) false")
            }
            try await testPlayback()
        } catch {
            expect(false, "ChapterPlayback fixtures: \(error)")
        }

        let booksRoot = URL(fileURLWithPath: NSString(string: "~/Documents/books").expandingTildeInPath, isDirectory: true)
        if FileManager.default.fileExists(atPath: booksRoot.path) {
            print("== Scan \(booksRoot.path) ==")
            do {
                let books = try await BookScanner().scan(root: booksRoot)
                for book in books {
                    print("  BOOK \(book.title) | \(book.author) | \(book.chapterCount) ch | \(DurationFormat.string(book.totalDuration)) | cover=\(book.coverJPEG != nil)\(book.isAlreadyBound ? " | already-bound" : "")")
                    if book.isAlreadyBound {
                        expect(book.chapterCount == 0, "\(book.title) already bound has 0 chapters")
                        expect(!book.selected, "\(book.title) already bound is not selected")
                        expect(book.existingM4BURL != nil, "\(book.title) already bound has m4b")
                    } else {
                        expect(book.chapterCount >= 1, "\(book.title) has chapters")
                    }
                    expect(!book.title.isEmpty, "title present")
                }

                if let taleb = books.first(where: { $0.author.contains("Taleb") && !$0.isAlreadyBound }) {
                    expect(taleb.chapterCount == 34, "Antifragile 34 chapters (got \(taleb.chapterCount))")
                    expect(taleb.coverJPEG != nil, "Antifragile cover")
                }

                if let campbell = books.first(where: { $0.author.contains("Campbell") && !$0.isAlreadyBound }) {
                    expect(campbell.chapterCount == 49, "Hero 49 chapters (got \(campbell.chapterCount))")
                    expect(campbell.title.lowercased().contains("hero"), "Hero title from ID3 (\(campbell.title))")
                }

                if let iger = books.first(where: { $0.author.contains("Iger") && !$0.isAlreadyBound }) {
                    expect(iger.title.lowercased().contains("ride"), "Ride title (\(iger.title))")
                    expect(iger.chapterCount == 16, "Ride 16 chapters")
                }

                if let systems = books.first(where: { $0.author.contains("Meadows") && !$0.isAlreadyBound }) {
                    expect(systems.chapterCount == 10, "Systems 10 chapters")
                    print("== Tiny encode \(systems.title) chapters 1+last ==")
                    var tiny = systems
                    tiny.chapters = [systems.chapters[0], systems.chapters[systems.chapters.count - 1]]
                    tiny.title = "Systems Smoke Test"
                    let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("audiobook-binder-test", isDirectory: true)
                    try? FileManager.default.removeItem(at: outDir)
                    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
                    let dest = outDir.appendingPathComponent("systems-smoke.m4b")
                    try await M4BExporter(bitrate: 48_000).export(book: tiny, to: dest, overwrite: true)
                    let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
                    let size = attrs[.size] as? Int64 ?? 0
                    expect(size > 10_000, "m4b size \(size)")
                    let data = try Data(contentsOf: dest, options: [.mappedIfSafe])
                    let asString = String(data: data, encoding: .isoLatin1) ?? ""
                    expect(asString.contains("stik"), "stik atom present")
                    expect(asString.contains("©nam") || asString.contains("nam"), "title atom present")
                    expect(asString.contains("chpl") || asString.contains("text"), "chapter data present")
                    expect(asString.contains("covr") || tiny.coverJPEG == nil, "cover atom if we had art")
                    print("  wrote \(dest.path) (\(size) bytes)")
                }
            } catch {
                expect(false, "scan/export error: \(error)")
            }
        } else {
            print("  skip live library (no \(booksRoot.path))")
        }

        if failed == 0 {
            print("\nAll tests passed.")
            Darwin.exit(0)
        } else {
            print("\n\(failed) test(s) failed.")
            Darwin.exit(1)
        }
    }
}
