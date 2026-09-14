import XCTest
@testable import AudiobookBinderCore

final class ScannerTests: XCTestCase {
    func testScanRejectsMissingAndEmpty() async {
        let scanner = BookScanner()
        let missing = URL(fileURLWithPath: "/tmp/m4b-no-such-\(UUID().uuidString)", isDirectory: true)
        do {
            _ = try await scanner.scan(root: missing)
            XCTFail("expected noBooksFound")
        } catch let error as BinderError {
            guard case .noBooksFound = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }

        let file = URL(fileURLWithPath: "/tmp/m4b-file-\(UUID().uuidString).txt")
        try? Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            _ = try await scanner.scan(root: file)
            XCTFail("expected noBooksFound for file")
        } catch let error as BinderError {
            guard case .noBooksFound = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testScanEmptyDirectory() async throws {
        let dir = try TestSupport.tempDir("empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            _ = try await BookScanner().scan(root: dir)
            XCTFail("expected noBooksFound")
        } catch let error as BinderError {
            guard case .noBooksFound = error else { return XCTFail("\(error)") }
        }
    }

    func testSkipsHelperFoldersWhenNumberedChaptersExist() async throws {
        let root = try TestSupport.tempDir("skip-dirs")
        defer { try? FileManager.default.removeItem(at: root) }
        let book = root.appendingPathComponent("Book", isDirectory: true)
        let extras = book.appendingPathComponent("不分章节", isDirectory: true)
        let ebook = book.appendingPathComponent("ebook", isDirectory: true)
        try FileManager.default.createDirectory(at: extras, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ebook, withIntermediateDirectories: true)
        try Data().write(to: book.appendingPathComponent("001.mp3"))
        try Data().write(to: extras.appendingPathComponent("whole.mp3"))
        try Data().write(to: ebook.appendingPathComponent("noise.mp3"))
        let loaded = try await BookScanner().loadBook(at: book)
        XCTAssertEqual(loaded.chapterCount, 1)
        XCTAssertTrue(loaded.chapters[0].url.lastPathComponent.hasPrefix("001"))
    }

    func testDiscAndAudioContainerFolders() async throws {
        let root = try TestSupport.tempDir("discs")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.writeMP3(in: root.appendingPathComponent("DiscBook", isDirectory: true), book: "Disc 1")
        try TestSupport.writeMP3(in: root.appendingPathComponent("DiscBook", isDirectory: true), book: "CD2")
        let disc = try await BookScanner().scan(root: root.appendingPathComponent("DiscBook", isDirectory: true))
        XCTAssertEqual(disc.count, 1)
        XCTAssertEqual(disc[0].folder.lastPathComponent, "DiscBook")
        XCTAssertEqual(disc[0].chapterCount, 2)

        let nested = try TestSupport.tempDir("audio-dir")
        defer { try? FileManager.default.removeItem(at: nested) }
        try TestSupport.writeMP3(in: nested.appendingPathComponent("Book", isDirectory: true), book: "audio")
        let books = try await BookScanner().scan(root: nested.appendingPathComponent("Book"))
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].folder.lastPathComponent, "Book")
    }

    func testScannerNameHelpersAndDirectFiles() throws {
        let scanner = BookScanner()
        XCTAssertTrue(scanner.isAudioContainerName("MP3"))
        XCTAssertTrue(scanner.isAudioContainerName("audiobooks"))
        XCTAssertFalse(scanner.isAudioContainerName("43"))
        XCTAssertTrue(scanner.isDiscOrPartName("CD1"))
        XCTAssertTrue(scanner.isDiscOrPartName("Disc 2"))
        XCTAssertTrue(scanner.isDiscOrPartName("Part-03"))
        XCTAssertFalse(scanner.isDiscOrPartName("43"))
        XCTAssertFalse(scanner.isDiscOrPartName("BookA"))
    }

    func testLoadBookThrowsWithoutAudio() async {
        do {
            let dir = try TestSupport.tempDir("silent")
            defer { try? FileManager.default.removeItem(at: dir) }
            _ = try await BookScanner().loadBook(at: dir)
            XCTFail("expected noAudioFiles")
        } catch let error as BinderError {
            guard case .noAudioFiles = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testKeepsLargeNumberedChapter() async throws {
        let root = try TestSupport.tempDir("large-chapter")
        defer { try? FileManager.default.removeItem(at: root) }
        let book = root.appendingPathComponent("Book", isDirectory: true)
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        try Data(count: 1000).write(to: book.appendingPathComponent("01.mp3"))
        try Data(count: 1000).write(to: book.appendingPathComponent("02.mp3"))
        try Data(count: 9000).write(to: book.appendingPathComponent("03.mp3"))
        let loaded = try await BookScanner().loadBook(at: book)
        XCTAssertEqual(loaded.chapterCount, 3)
        XCTAssertEqual(loaded.chapters.map(\.url.lastPathComponent), ["01.mp3", "02.mp3", "03.mp3"])
        XCTAssertTrue(loaded.chapters.allSatisfy(\.included))
        XCTAssertTrue(loaded.chapters.allSatisfy { ($0.exclusionReason ?? "").isEmpty })
    }

    func testKeepsLargeMixedFormatNumberedChapter() async throws {
        let root = try TestSupport.tempDir("mixed-format")
        defer { try? FileManager.default.removeItem(at: root) }
        let book = root.appendingPathComponent("Book", isDirectory: true)
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        try Data(count: 200).write(to: book.appendingPathComponent("01.mp3"))
        try Data(count: 200).write(to: book.appendingPathComponent("02.m4a"))
        try Data(count: 1800).write(to: book.appendingPathComponent("03.wav"))
        let loaded = try await BookScanner().loadBook(at: book)
        XCTAssertEqual(loaded.chapterCount, 3)
        XCTAssertEqual(Set(loaded.chapters.map(\.url.lastPathComponent)), ["01.mp3", "02.m4a", "03.wav"])
        XCTAssertTrue(loaded.chapters.allSatisfy(\.included))
    }

    func testDeselectsHugeConcatenatedFile() async throws {
        let root = try TestSupport.tempDir("concat")
        defer { try? FileManager.default.removeItem(at: root) }
        let book = root.appendingPathComponent("Book", isDirectory: true)
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        try Data(count: 200).write(to: book.appendingPathComponent("001.mp3"))
        try Data(count: 220).write(to: book.appendingPathComponent("002.mp3"))
        try Data(count: 210).write(to: book.appendingPathComponent("003.mp3"))
        try Data(count: 20_000).write(to: book.appendingPathComponent("all-in-one.mp3"))
        let loaded = try await BookScanner().loadBook(at: book)
        XCTAssertEqual(loaded.chapterCount, 4)
        XCTAssertEqual(loaded.includedChapters.count, 3)
        let dump = loaded.chapters.first { $0.url.lastPathComponent == "all-in-one.mp3" }
        XCTAssertNotNil(dump)
        XCTAssertEqual(dump?.included, false)
        XCTAssertFalse((dump?.exclusionReason ?? "").isEmpty)
        XCTAssertFalse(dump!.title.contains(dump!.exclusionReason!))
        for name in ["001.mp3", "002.mp3", "003.mp3"] {
            let chapter = loaded.chapters.first { $0.url.lastPathComponent == name }
            XCTAssertEqual(chapter?.included, true, name)
            XCTAssertTrue((chapter?.exclusionReason ?? "").isEmpty, name)
        }
    }

    func testConcatenationHeuristicNeedsNameAndSize() {
        XCTAssertFalse(
            BookScanner.shouldAutoExcludeAsConcatenation(
                fileName: "03.mp3",
                size: 9000,
                medianSize: 1000,
                fileCount: 3
            )
        )
        XCTAssertFalse(
            BookScanner.shouldAutoExcludeAsConcatenation(
                fileName: "Chapter 03.mp3",
                size: 20_000,
                medianSize: 210,
                fileCount: 4
            )
        )
        XCTAssertFalse(
            BookScanner.shouldAutoExcludeAsConcatenation(
                fileName: "extra.mp3",
                size: 20_000,
                medianSize: 210,
                fileCount: 4
            )
        )
        XCTAssertFalse(
            BookScanner.shouldAutoExcludeAsConcatenation(
                fileName: "all-in-one.mp3",
                size: 400,
                medianSize: 210,
                fileCount: 4
            )
        )
        XCTAssertFalse(
            BookScanner.shouldAutoExcludeAsConcatenation(
                fileName: "all-in-one.mp3",
                size: 20_000,
                medianSize: 210,
                fileCount: 2
            )
        )
        XCTAssertTrue(
            BookScanner.shouldAutoExcludeAsConcatenation(
                fileName: "all-in-one.mp3",
                size: 20_000,
                medianSize: 210,
                fileCount: 4
            )
        )
        XCTAssertTrue(
            BookScanner.shouldAutoExcludeAsConcatenation(
                fileName: "Complete.mp3",
                size: 20_000,
                medianSize: 210,
                fileCount: 4
            )
        )
        XCTAssertTrue(
            BookScanner.shouldAutoExcludeAsConcatenation(
                fileName: "Full Book.mp3",
                size: 20_000,
                medianSize: 210,
                fileCount: 4
            )
        )
        XCTAssertTrue(
            BookScanner.shouldAutoExcludeAsConcatenation(
                fileName: "entire.mp3",
                size: 20_000,
                medianSize: 210,
                fileCount: 4
            )
        )
        XCTAssertTrue(
            BookScanner.shouldAutoExcludeAsConcatenation(
                fileName: "concatenated.mp3",
                size: 20_000,
                medianSize: 210,
                fileCount: 4
            )
        )
    }

    func testSortsLeadingAndTrailingIndexes() async throws {
        let root = try TestSupport.tempDir("sort")
        defer { try? FileManager.default.removeItem(at: root) }
        let book = root.appendingPathComponent("Book", isDirectory: true)
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        try Data().write(to: book.appendingPathComponent("10-later.mp3"))
        try Data().write(to: book.appendingPathComponent("2-early.mp3"))
        try Data().write(to: book.appendingPathComponent("Book - 003.mp3"))
        let loaded = try await BookScanner().loadBook(at: book)
        XCTAssertEqual(loaded.chapters.map(\.url.lastPathComponent), ["2-early.mp3", "Book - 003.mp3", "10-later.mp3"])
    }

    func testOPFInBookFolderWinsOverFolderName() async throws {
        let root = try TestSupport.tempDir("opf-book")
        defer { try? FileManager.default.removeItem(at: root) }
        let book = root.appendingPathComponent("Folder Name", isDirectory: true)
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        try Data().write(to: book.appendingPathComponent("01.mp3"))
        try """
        <package><metadata><dc:title>OPF Title Here</dc:title><dc:creator>OPF Author</dc:creator></metadata></package>
        """.write(to: book.appendingPathComponent("metadata.opf"), atomically: true, encoding: .utf8)
        let loaded = try await BookScanner().loadBook(at: book)
        XCTAssertEqual(loaded.title, "OPF Title Here")
        XCTAssertEqual(loaded.author, "OPF Author")
    }

    func testHasDirectAudioIgnoresM4B() throws {
        let dir = try TestSupport.tempDir("direct")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("book.m4b"))
        let scanner = BookScanner()
        XCTAssertFalse(scanner.hasDirectAudio(dir))
        XCTAssertTrue(scanner.hasDirectM4B(dir))
        try Data().write(to: dir.appendingPathComponent("01.mp3"))
        XCTAssertTrue(scanner.hasDirectAudio(dir))
    }

    func testScanFallsBackToFolderTitle() async throws {
        let dir = try TestSupport.tempDir("catalog")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookDir = dir.appendingPathComponent("On Writing Well", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try Data().write(to: bookDir.appendingPathComponent("01.mp3"))
        let books = try await BookScanner().scan(root: dir)
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.title, "On Writing Well")
    }
}
