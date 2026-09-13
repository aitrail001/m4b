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
