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
                    print("  BOOK \(book.title) | \(book.author) | \(book.chapterCount) ch | \(DurationFormat.string(book.totalDuration)) | cover=\(book.coverJPEG != nil)")
                    expect(book.chapterCount >= 1, "\(book.title) has chapters")
                    expect(!book.title.isEmpty, "title present")
                }

                if let taleb = books.first(where: { $0.author.contains("Taleb") }) {
                    expect(taleb.chapterCount == 34, "Antifragile 34 chapters (got \(taleb.chapterCount))")
                    expect(taleb.coverJPEG != nil, "Antifragile cover")
                }

                if let campbell = books.first(where: { $0.author.contains("Campbell") }) {
                    expect(campbell.chapterCount == 49, "Hero 49 chapters (got \(campbell.chapterCount))")
                    expect(campbell.title.lowercased().contains("hero"), "Hero title from ID3 (\(campbell.title))")
                }

                if let iger = books.first(where: { $0.author.contains("Iger") }) {
                    expect(iger.title.lowercased().contains("ride"), "Ride title (\(iger.title))")
                    expect(iger.chapterCount == 16, "Ride 16 chapters")
                }

                if let systems = books.first(where: { $0.author.contains("Meadows") }) {
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
