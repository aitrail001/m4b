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
        let discBook = root.appendingPathComponent("DiscBook", isDirectory: true)
        let disc = try await BookScanner().scan(root: discBook)
        XCTAssertEqual(disc.count, 1)
        XCTAssertEqual(disc[0].folder.lastPathComponent, "DiscBook")
        XCTAssertEqual(disc[0].chapterCount, 2)
        XCTAssertEqual(
            relativePaths(disc[0].chapters.map(\.url), to: discBook),
            ["Disc 1/01.mp3", "CD2/01.mp3"]
        )

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

    func testOrdersMultiDiscRepeatedTrackNamesByDiscThenTrack() async throws {
        let root = try TestSupport.tempDir("multi-disc-tracks")
        defer { try? FileManager.default.removeItem(at: root) }
        let book = root.appendingPathComponent("DiscBook", isDirectory: true)
        for disc in ["CD2", "CD1"] {
            for file in ["02.mp3", "01.mp3"] {
                try TestSupport.writeMP3(in: book, book: disc, file: file)
            }
        }
        let loaded = try await BookScanner().loadBook(at: book)
        XCTAssertEqual(
            relativePaths(loaded.chapters.map(\.url), to: book),
            ["CD1/01.mp3", "CD1/02.mp3", "CD2/01.mp3", "CD2/02.mp3"]
        )
    }

    func testOrdersCD2BeforeCD10() async throws {
        let root = try TestSupport.tempDir("cd2-cd10")
        defer { try? FileManager.default.removeItem(at: root) }
        let book = root.appendingPathComponent("DiscBook", isDirectory: true)
        for disc in ["CD10", "CD2"] {
            for file in ["02.mp3", "01.mp3"] {
                try TestSupport.writeMP3(in: book, book: disc, file: file)
            }
        }
        let loaded = try await BookScanner().loadBook(at: book)
        XCTAssertEqual(
            relativePaths(loaded.chapters.map(\.url), to: book),
            ["CD2/01.mp3", "CD2/02.mp3", "CD10/01.mp3", "CD10/02.mp3"]
        )
    }

    func testOrdersNestedPartThenDiscThenTrack() async throws {
        let root = try TestSupport.tempDir("nested-part-disc")
        defer { try? FileManager.default.removeItem(at: root) }
        let book = root.appendingPathComponent("NestedBook", isDirectory: true)
        let expected = [
            "00-intro.mp3",
            "audio/01.mp3",
            "Part1/CD1/01.mp3",
            "Part1/CD1/02.mp3",
            "Part1/CD2/01.mp3",
            "Part1/CD2/02.mp3",
            "Part1/CD10/01.mp3",
            "Part2/CD1/01.mp3",
            "Part2/CD1/02.mp3",
        ]
        let shuffled = [
            "Part2/CD1/02.mp3",
            "Part1/CD2/01.mp3",
            "00-intro.mp3",
            "Part1/CD1/02.mp3",
            "Part1/CD10/01.mp3",
            "audio/01.mp3",
            "Part2/CD1/01.mp3",
            "Part1/CD2/02.mp3",
            "Part1/CD1/01.mp3",
        ]
        for relative in shuffled {
            try writeRelativeMP3(in: book, relative)
        }

        let scanner = BookScanner()
        let shuffledURLs = shuffled.map { nestedURL(book, $0) }
        XCTAssertEqual(
            relativePaths(scanner.sortAudio(shuffledURLs, relativeTo: book), to: book),
            expected
        )

        let loaded = try await scanner.loadBook(at: book)
        XCTAssertEqual(
            relativePaths(loaded.chapters.map(\.url), to: book),
            expected
        )
    }

    func testOrdersDiscAndPartFolderNamesByDiscThenTrack() async throws {
        let root = try TestSupport.tempDir("disc-part-names")
        defer { try? FileManager.default.removeItem(at: root) }
        let book = root.appendingPathComponent("DiscBook", isDirectory: true)
        try TestSupport.writeMP3(in: book, book: "Disc 2", file: "02.mp3")
        try TestSupport.writeMP3(in: book, book: "Disc 1", file: "01.mp3")
        try TestSupport.writeMP3(in: book, book: "Disc 2", file: "01.mp3")
        try TestSupport.writeMP3(in: book, book: "Disc 1", file: "02.mp3")
        let loaded = try await BookScanner().loadBook(at: book)
        XCTAssertEqual(
            relativePaths(loaded.chapters.map(\.url), to: book),
            ["Disc 1/01.mp3", "Disc 1/02.mp3", "Disc 2/01.mp3", "Disc 2/02.mp3"]
        )

        let parts = root.appendingPathComponent("PartBook", isDirectory: true)
        try TestSupport.writeMP3(in: parts, book: "Part-10", file: "02.mp3")
        try TestSupport.writeMP3(in: parts, book: "Part-03", file: "01.mp3")
        try TestSupport.writeMP3(in: parts, book: "Part-10", file: "01.mp3")
        try TestSupport.writeMP3(in: parts, book: "Part-03", file: "02.mp3")
        let partBook = try await BookScanner().loadBook(at: parts)
        XCTAssertEqual(
            relativePaths(partBook.chapters.map(\.url), to: parts),
            ["Part-03/01.mp3", "Part-03/02.mp3", "Part-10/01.mp3", "Part-10/02.mp3"]
        )
    }

    func testSortAudioOrdersByDiscThenTrackThenRelativePath() {
        let scanner = BookScanner()
        let root = URL(fileURLWithPath: "/tmp/DiscBook", isDirectory: true)
        let shuffled = [
            URL(fileURLWithPath: "/tmp/DiscBook/CD2/01.mp3"),
            URL(fileURLWithPath: "/tmp/DiscBook/CD1/02.mp3"),
            URL(fileURLWithPath: "/tmp/DiscBook/CD2/02.mp3"),
            URL(fileURLWithPath: "/tmp/DiscBook/CD1/01.mp3"),
        ]
        XCTAssertEqual(
            relativePaths(scanner.sortAudio(shuffled, relativeTo: root), to: root),
            ["CD1/01.mp3", "CD1/02.mp3", "CD2/01.mp3", "CD2/02.mp3"]
        )

        let numericDiscs = [
            URL(fileURLWithPath: "/tmp/DiscBook/CD10/mp3/01.mp3"),
            URL(fileURLWithPath: "/tmp/DiscBook/CD2/mp3/02.mp3"),
            URL(fileURLWithPath: "/tmp/DiscBook/CD10/mp3/02.mp3"),
            URL(fileURLWithPath: "/tmp/DiscBook/CD2/mp3/01.mp3"),
        ]
        XCTAssertEqual(
            relativePaths(scanner.sortAudio(numericDiscs, relativeTo: root), to: root),
            ["CD2/mp3/01.mp3", "CD2/mp3/02.mp3", "CD10/mp3/01.mp3", "CD10/mp3/02.mp3"]
        )

        let mixedNames = [
            URL(fileURLWithPath: "/tmp/DiscBook/Part-10/01.mp3"),
            URL(fileURLWithPath: "/tmp/DiscBook/Disc 1/02.mp3"),
            URL(fileURLWithPath: "/tmp/DiscBook/Part-03/02.mp3"),
            URL(fileURLWithPath: "/tmp/DiscBook/Disc 1/01.mp3"),
            URL(fileURLWithPath: "/tmp/DiscBook/Part-10/02.mp3"),
            URL(fileURLWithPath: "/tmp/DiscBook/Part-03/01.mp3"),
        ]
        XCTAssertEqual(
            relativePaths(scanner.sortAudio(mixedNames, relativeTo: root), to: root),
            [
                "Disc 1/01.mp3",
                "Disc 1/02.mp3",
                "Part-03/01.mp3",
                "Part-03/02.mp3",
                "Part-10/01.mp3",
                "Part-10/02.mp3",
            ]
        )

        let flat = [
            URL(fileURLWithPath: "/tmp/Book/10-later.mp3"),
            URL(fileURLWithPath: "/tmp/Book/2-early.mp3"),
            URL(fileURLWithPath: "/tmp/Book/Book - 003.mp3"),
        ]
        let flatRoot = URL(fileURLWithPath: "/tmp/Book", isDirectory: true)
        XCTAssertEqual(
            scanner.sortAudio(flat, relativeTo: flatRoot).map(\.lastPathComponent),
            ["2-early.mp3", "Book - 003.mp3", "10-later.mp3"]
        )

        let ties = [
            URL(fileURLWithPath: "/tmp/DiscBook/CD1/b/01.mp3"),
            URL(fileURLWithPath: "/tmp/DiscBook/CD1/a/01.mp3"),
        ]
        XCTAssertEqual(
            relativePaths(scanner.sortAudio(ties, relativeTo: root), to: root),
            ["CD1/a/01.mp3", "CD1/b/01.mp3"]
        )
    }

    func testDiscIndexFromRelativePath() {
        let scanner = BookScanner()
        XCTAssertEqual(scanner.discIndex(inRelativePath: "01.mp3"), 0)
        XCTAssertEqual(scanner.discIndex(inRelativePath: "CD1/01.mp3"), 1)
        XCTAssertEqual(scanner.discIndex(inRelativePath: "CD2/mp3/02.mp3"), 2)
        XCTAssertEqual(scanner.discIndex(inRelativePath: "CD10/01.mp3"), 10)
        XCTAssertEqual(scanner.discIndex(inRelativePath: "Disc 1/01.mp3"), 1)
        XCTAssertEqual(scanner.discIndex(inRelativePath: "Disc 2/tracks/01.mp3"), 2)
        XCTAssertEqual(scanner.discIndex(inRelativePath: "Part-03/01.mp3"), 3)
        XCTAssertEqual(scanner.discIndex(inRelativePath: "Part-10/01.mp3"), 10)
        XCTAssertEqual(scanner.discIndex(inRelativePath: "audio/01.mp3"), 0)
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

    func testLoadBookKeepsLeftoverForDisplayWithoutOwning() async throws {
        let root = try TestSupport.tempDir("load-leftover-display")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDir = root.appendingPathComponent("BookA", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try Data().write(to: bookDir.appendingPathComponent("01.mp3"))

        let leftover = Data("LEFTOVER-DISPLAY".utf8)
        let dest = bookDir.appendingPathComponent("Same - Ann.m4b")
        try leftover.write(to: dest)

        var loaded = try await BookScanner().loadBook(at: bookDir)
        loaded.title = "Same"
        loaded.author = "Ann"
        XCTAssertEqual(loaded.existingM4BURL?.standardizedFileURL.path, dest.standardizedFileURL.path)
        XCTAssertNil(OutputAssociation.load(inBookFolder: bookDir))

        let settings = ExportSettings(overwrite: true, writeNextToBook: true)
        XCTAssertFalse(settings.owns(dest, for: loaded))
        let plan = settings.plannedOutputs(for: [loaded])
        XCTAssertNotEqual(plan[loaded.id]?.standardizedFileURL.path, dest.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: dest), leftover)
    }

    func testLoadBookRestoresExistingM4BFromSidecar() async throws {
        let root = try TestSupport.tempDir("load-sidecar")
        defer { try? FileManager.default.removeItem(at: root) }
        let book = root.appendingPathComponent("EditionB", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data().write(to: book.appendingPathComponent("01.mp3"))
        try Data().write(to: book.appendingPathComponent("leftover.m4b"))

        let dest = out.appendingPathComponent("Same - Ann - EditionB.m4b")
        try Data("OWNED-B".utf8).write(to: dest)
        OutputAssociation.record(dest, inBookFolder: book)

        let loaded = try await BookScanner().loadBook(at: book)
        XCTAssertEqual(loaded.existingM4BURL?.standardizedFileURL.path, dest.standardizedFileURL.path)
        XCTAssertNotEqual(loaded.existingM4BURL?.lastPathComponent, "leftover.m4b")
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

    func testCancelledScanThrowsCancellationError() async throws {
        let root = try TestSupport.tempDir("cancel-scan")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.writeMP3(in: root, book: "BookA")
        try TestSupport.writeMP3(in: root, book: "BookB")

        let task = Task {
            try await BookScanner().scan(root: root)
        }
        task.cancel()
        await assertCancellationError {
            try await task.value
        }
    }

    func testCancelledLoadBookThrowsCancellationError() async throws {
        let root = try TestSupport.tempDir("cancel-load")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.writeMP3(in: root, book: "BookA")
        let book = root.appendingPathComponent("BookA", isDirectory: true)

        let task = Task {
            try await BookScanner().loadBook(at: book)
        }
        task.cancel()
        await assertCancellationError {
            try await task.value
        }
    }

    func testScanDoesNotSwallowLoadBookCancellation() async throws {
        let root = try TestSupport.tempDir("cancel-scan-load")
        defer { try? FileManager.default.removeItem(at: root) }
        try TestSupport.writeMP3(in: root, book: "BookA")
        try TestSupport.writeMP3(in: root, book: "BookB")

        let task = Task {
            try await BookScanner().scan(root: root) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await assertCancellationError {
            try await task.value
        }
    }

    private func assertCancellationError(
        _ body: () async throws -> some Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("expected CancellationError", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)", file: file, line: line)
        }
    }

    private func relativePaths(_ urls: [URL], to root: URL) -> [String] {
        let rootParts = root.standardizedFileURL.pathComponents
        return urls.map { url in
            let parts = url.standardizedFileURL.pathComponents
            if parts.starts(with: rootParts) {
                return parts.dropFirst(rootParts.count).joined(separator: "/")
            }
            return url.lastPathComponent
        }
    }

    private func nestedURL(_ root: URL, _ relative: String) -> URL {
        relative.split(separator: "/").reduce(root) { partial, part in
            partial.appendingPathComponent(String(part))
        }
    }

    private func writeRelativeMP3(in root: URL, _ relative: String) throws {
        let parts = relative.split(separator: "/").map(String.init)
        var dir = root
        for folder in parts.dropLast() {
            dir = dir.appendingPathComponent(folder, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent(parts.last!))
    }
}
