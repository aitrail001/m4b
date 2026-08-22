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

        let booksRoot = URL(fileURLWithPath: NSString(string: "~/Documents/books").expandingTildeInPath, isDirectory: true)
        if FileManager.default.fileExists(atPath: booksRoot.path) {
            print("== Scan \(booksRoot.path) ==")
            do {
                let books = try await BookScanner().scan(root: booksRoot)
                expect(books.count == 7, "library has 7 books (got \(books.count))")
                for book in books {
                    print("  BOOK \(book.title) | \(book.author) | \(book.chapterCount) ch | \(DurationFormat.string(book.totalDuration)) | cover=\(book.coverJPEG != nil)")
                    expect(book.chapterCount >= 1, "\(book.title) has chapters")
                    expect(!book.title.isEmpty, "title present")
                    expect(book.author != "Unknown Author" || book.title.contains("Factfulness"), "author for \(book.title): \(book.author)")
                }

                if let taleb = books.first(where: { $0.author.contains("Taleb") }) {
                    expect(taleb.chapterCount == 34, "Antifragile 34 chapters (got \(taleb.chapterCount))")
                    expect(taleb.coverJPEG != nil, "Antifragile cover")
                } else {
                    expect(false, "found Taleb book")
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
