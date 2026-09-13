import XCTest
@testable import AudiobookBinderCore

final class NamingAndModelsTests: XCTestCase {
    func testNaturalSortCompareAndSorted() {
        XCTAssertEqual(NaturalSort.compare("a2", "a10"), .orderedAscending)
        XCTAssertEqual(NaturalSort.compare("Track 10", "Track 2"), .orderedDescending)
        let sorted = NaturalSort.sorted(["ch10", "ch2", "ch1"], key: { $0 })
        XCTAssertEqual(sorted, ["ch1", "ch2", "ch10"])
        XCTAssertNil(NaturalSort.leadingIndex("Preface.mp3"))
        XCTAssertNil(NaturalSort.trailingIndex("Preface.mp3"))
        XCTAssertEqual(NaturalSort.leadingIndex("12 Intro.mp3"), 12)
        XCTAssertEqual(NaturalSort.trailingIndex("Intro 7.mp3"), 7)
    }

    func testTitleCleanupHelpers() {
        XCTAssertEqual(TitleCleanup.stripEdition("Rework (Unabridged)"), "Rework")
        XCTAssertEqual(TitleCleanup.collapseSpaces("  a   b\t c "), "a b c")
        XCTAssertTrue(TitleCleanup.looksLikeGenericChapter(""))
        XCTAssertTrue(TitleCleanup.looksLikeGenericChapter("t"))
        XCTAssertTrue(TitleCleanup.looksLikeGenericChapter("Chapter"))
        XCTAssertTrue(TitleCleanup.looksLikeGenericChapter("untitled"))
        XCTAssertFalse(TitleCleanup.looksLikeGenericChapter("Prologue"))
        XCTAssertEqual(TitleCleanup.folderTitle("Name_Subtitle"), "Name:Subtitle")
        let ebook = TitleCleanup.fromEbookFilename("Title - Author.epub")
        XCTAssertEqual(ebook.title, "Title")
        XCTAssertEqual(ebook.author, "Author")
        let single = TitleCleanup.fromEbookFilename("OnlyName.mobi")
        XCTAssertEqual(single.title, "OnlyName")
        XCTAssertNil(single.author)
        XCTAssertEqual(
            TitleCleanup.preferredTitle(candidates: ["Good Title", "x"], folderTitle: "Folder"),
            "Good Title"
        )
        XCTAssertEqual(
            TitleCleanup.preferredTitle(candidates: ["ab"], folderTitle: "Folder"),
            "Folder"
        )
    }

    func testChapterNamerDistinctiveAndID3() {
        XCTAssertEqual(
            ChapterNamer.distinctiveFilenameTitle(
                "001 - Prologue",
                bookTitle: "The Book",
                album: nil
            ),
            "Prologue"
        )
        XCTAssertNil(
            ChapterNamer.distinctiveFilenameTitle(
                "001 - The Book",
                bookTitle: "The Book",
                album: nil
            )
        )
        XCTAssertTrue(ChapterNamer.isBookTitle("The Book (Unabridged)", bookTitle: "The Book", album: nil))
        XCTAssertFalse(ChapterNamer.isBookTitle("Prologue", bookTitle: "The Book", album: nil))
        XCTAssertEqual(
            ChapterNamer.title(
                filename: "003 - Arrival.mp3",
                index: 3,
                bookTitle: "Dune",
                album: "Dune",
                id3Title: "Dune",
                paddedWidth: 2
            ),
            "Arrival"
        )
        XCTAssertEqual(
            ChapterNamer.title(
                filename: "track.mp3",
                index: 4,
                bookTitle: "Dune",
                album: "Dune",
                id3Title: "The Gom Jabbar",
                paddedWidth: 2
            ),
            "The Gom Jabbar"
        )
        XCTAssertEqual(
            ChapterNamer.title(
                filename: "track.mp3",
                index: 1,
                bookTitle: "Dune",
                album: nil,
                id3Title: "Dune",
                paddedWidth: 3
            ),
            "Chapter 001"
        )
        XCTAssertEqual(
            ChapterNamer.title(
                filename: "01-Dune - Intro.mp3",
                index: 1,
                bookTitle: "Dune",
                album: "Dune",
                id3Title: nil,
                paddedWidth: 2
            ),
            "Intro"
        )
    }

    func testDurationFormat() {
        XCTAssertEqual(DurationFormat.string(0), "—")
        XCTAssertEqual(DurationFormat.string(.nan), "—")
        XCTAssertEqual(DurationFormat.string(-1), "—")
        XCTAssertEqual(DurationFormat.string(65), "1:05")
        XCTAssertEqual(DurationFormat.string(3661), "1:01:01")
        XCTAssertEqual(DurationFormat.string(5), "0:05")
    }

    func testBinderErrorDescriptions() {
        let url = URL(fileURLWithPath: "/tmp/book")
        XCTAssertEqual(BinderError.noAudioFiles(url).errorDescription, "No audio files found in /tmp/book")
        XCTAssertEqual(BinderError.noBooksFound(url).errorDescription, "No books found in /tmp/book")
        XCTAssertEqual(BinderError.exportFailed("boom").errorDescription, "boom")
        XCTAssertEqual(BinderError.cancelled.errorDescription, "Cancelled")
        XCTAssertEqual(
            BinderError.outputExists(URL(fileURLWithPath: "/tmp/T - A.m4b")).errorDescription,
            "Already exists: T - A.m4b"
        )
    }

    func testAudiobookSuggestedNameMatchesNarrator() {
        let book = TestSupport.dummyBook(
            folder: "/tmp/A/B",
            title: "Foo/Bar: Baz",
            author: "Ann",
            narrator: "Bob"
        )
        XCTAssertEqual(book.suggestedFileName, "Foo-Bar - Baz - Ann.m4b")
        XCTAssertTrue(book.matches(query: "bob"))
        XCTAssertFalse(book.matches(query: "carol"))
    }

    func testExportSettingsResolvedDirectory() {
        let book = TestSupport.dummyBook(folder: "/tmp/MyBook")
        let nextTo = ExportSettings(
            outputDirectory: URL(fileURLWithPath: "/tmp/Out"),
            writeNextToBook: true
        )
        XCTAssertEqual(nextTo.resolvedOutputDirectory(for: book).path, "/tmp/MyBook")
        let custom = ExportSettings(
            outputDirectory: URL(fileURLWithPath: "/tmp/Out"),
            writeNextToBook: false
        )
        XCTAssertEqual(custom.resolvedOutputDirectory(for: book).path, "/tmp/Out")
        let fallback = ExportSettings(outputDirectory: nil, writeNextToBook: false)
        XCTAssertEqual(fallback.resolvedOutputDirectory(for: book).path, ExportSettings.defaultOutputDirectory.path)
    }

    func testAudioInfoExactKilohertzAndScanProgressZeroCount() {
        let info = AudioInfo(bitrate: 64_000, sampleRate: 48_000, channelCount: 2, formatName: "AAC")
        XCTAssertEqual(info.summary, "64 kbps · 48 kHz · stereo · AAC")
        let reading = ScanProgress.reading(URL(fileURLWithPath: "/tmp/X"), index: 1, count: 0)
        XCTAssertEqual(reading.fraction, 0)
        let progress = BuildProgress(
            bookTitle: "T",
            bookIndex: 1,
            bookCount: 2,
            fraction: 0.5,
            detail: "go"
        )
        XCTAssertEqual(progress.bookTitle, "T")
        XCTAssertEqual(progress.detail, "go")
    }

    func testExtensionSets() {
        XCTAssertTrue(audioExtensions.contains("mp3"))
        XCTAssertTrue(imageExtensions.contains("jpg"))
        XCTAssertTrue(ebookExtensions.contains("epub"))
        XCTAssertTrue(skippedDirectoryNames.contains("不分章节"))
        XCTAssertTrue(skippedDirectoryNames.contains("ebook"))
    }
}
