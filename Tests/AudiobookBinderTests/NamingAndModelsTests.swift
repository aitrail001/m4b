import XCTest
@testable import AudiobookBinderCore

final class NamingAndModelsTests: XCTestCase {
    func testNaturalSortIndexes() {
        XCTAssertNil(NaturalSort.leadingIndex("Preface.mp3"))
        XCTAssertNil(NaturalSort.trailingIndex("Preface.mp3"))
        XCTAssertEqual(NaturalSort.leadingIndex("12 Intro.mp3"), 12)
        XCTAssertEqual(NaturalSort.trailingIndex("Intro 7.mp3"), 7)
        XCTAssertEqual(
            ["ch10", "ch2", "ch1"].sorted {
                $0.compare($1, options: NaturalSort.options) == .orderedAscending
            },
            ["ch1", "ch2", "ch10"]
        )
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
        XCTAssertTrue(TitleCleanup.looksLikeCatalogTitle("OnWritingWellAudioCollection_ep6_A2TTVL6TAAJVUN"))
        XCTAssertTrue(TitleCleanup.looksLikeCatalogTitle("OnWritingWellAudioCollection"))
        XCTAssertTrue(TitleCleanup.looksLikeCatalogTitle("B000F77HD8"))
        XCTAssertFalse(TitleCleanup.looksLikeCatalogTitle("On Writing Well"))
        XCTAssertEqual(
            TitleCleanup.preferredTitle(
                candidates: ["OnWritingWellAudioCollection_ep6_A2TTVL6TAAJVUN"],
                folderTitle: "On Writing Well"
            ),
            "On Writing Well"
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
        XCTAssertEqual(
            BinderError.missingChapters([URL(fileURLWithPath: "/tmp/a/gone.wav")]).errorDescription,
            "Missing selected chapter: gone.wav"
        )
        XCTAssertEqual(
            BinderError.missingChapters([
                URL(fileURLWithPath: "/tmp/a/gone.wav"),
                URL(fileURLWithPath: "/tmp/b/also.mp3")
            ]).errorDescription,
            "Missing selected chapters: gone.wav, also.mp3"
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
        let reading = JobProgress.reading(URL(fileURLWithPath: "/tmp/X"), index: 1, count: 0)
        XCTAssertEqual(reading.fraction, 0)
        let progress = JobProgress(label: "T", index: 1, count: 2, fraction: 0.5, detail: "go")
        XCTAssertEqual(progress.label, "T")
        XCTAssertEqual(progress.detail, "go")
    }

    func testExtensionSets() {
        XCTAssertTrue(audioExtensions.contains("mp3"))
        XCTAssertTrue(imageExtensions.contains("jpg"))
        XCTAssertTrue(ebookExtensions.contains("epub"))
        XCTAssertTrue(skippedDirectoryNames.contains("不分章节"))
        XCTAssertTrue(skippedDirectoryNames.contains("ebook"))
    }

    func testCreatedAudiobooksStatusIncludesTitles() {
        XCTAssertEqual(
            BinderCopy.createdAudiobooks(titles: ["The Personal MBA"]),
            "Created 1 audiobook — The Personal MBA. Verify the .m4b in the editor."
        )
        XCTAssertEqual(
            BinderCopy.createdAudiobooks(titles: ["Antifragile", "Rework"]),
            "Created 2 audiobooks — Antifragile, Rework. Verify the .m4b files in the editor."
        )
        XCTAssertEqual(
            BinderCopy.createdAudiobooks(titles: ["  ", ""]),
            "Created 0 audiobooks."
        )
        XCTAssertEqual(
            BinderCopy.exportSummary([("The Personal MBA", .created)]),
            BinderCopy.createdAudiobooks(titles: ["The Personal MBA"])
        )
    }

    func testExportSummaryDistinguishesCreatedSkippedReplacedFailed() {
        XCTAssertEqual(
            BinderCopy.exportSummary([
                ("The Personal MBA", .created),
                ("Rework", .skippedExisting)
            ]),
            "Created 1 audiobook — The Personal MBA. Skipped 1 existing audiobook — Rework. Verify the .m4b in the editor."
        )
        XCTAssertEqual(
            BinderCopy.exportSummary([
                ("Antifragile", .skippedExisting),
                ("Rework", .skippedExisting)
            ]),
            "Skipped 2 existing audiobooks — Antifragile, Rework."
        )
        XCTAssertEqual(
            BinderCopy.exportSummary([("The Personal MBA", .replaced)]),
            "Replaced 1 audiobook — The Personal MBA. Verify the .m4b in the editor."
        )
        XCTAssertEqual(
            BinderCopy.exportSummary([("Broken", .failed("encode failed"))]),
            "Failed 1 audiobook — Broken (encode failed)."
        )
        XCTAssertEqual(
            BinderCopy.exportSummary([
                ("A", .created),
                ("B", .replaced),
                ("C", .skippedExisting),
                ("D", .failed("disk full"))
            ]),
            "Created 1 audiobook — A. Replaced 1 audiobook — B. Skipped 1 existing audiobook — C. Failed 1 audiobook — D (disk full). Verify the .m4b files in the editor."
        )
    }

    func testPlannedOutputsDisambiguatesSameTitleAuthorAndSanitizedNames() {
        let out = URL(fileURLWithPath: "/tmp/OutShared", isDirectory: true)
        let settings = ExportSettings(outputDirectory: out, writeNextToBook: false)
        let editionA = TestSupport.dummyBook(folder: "/tmp/lib/EditionA", title: "Same", author: "Ann")
        let editionB = TestSupport.dummyBook(folder: "/tmp/lib/EditionB", title: "Same", author: "Ann")
        XCTAssertEqual(editionA.suggestedFileName, editionB.suggestedFileName)

        let plan = settings.plannedOutputs(for: [editionA, editionB])
        XCTAssertEqual(plan.count, 2)
        XCTAssertNotEqual(plan[editionA.id]?.standardizedFileURL.path, plan[editionB.id]?.standardizedFileURL.path)
        XCTAssertEqual(plan[editionA.id]?.lastPathComponent, "Same - Ann.m4b")
        XCTAssertEqual(plan[editionB.id]?.lastPathComponent, "Same - Ann - EditionB.m4b")
        XCTAssertEqual(plan[editionA.id]?.deletingLastPathComponent().standardizedFileURL.path, out.standardizedFileURL.path)
        XCTAssertEqual(plan[editionB.id]?.deletingLastPathComponent().standardizedFileURL.path, out.standardizedFileURL.path)

        let slash = TestSupport.dummyBook(folder: "/tmp/lib/SlashBook", title: "Foo/Bar", author: "Ann")
        let dash = TestSupport.dummyBook(folder: "/tmp/lib/DashBook", title: "Foo-Bar", author: "Ann")
        XCTAssertEqual(slash.suggestedFileName, dash.suggestedFileName)
        XCTAssertEqual(slash.suggestedFileName, "Foo-Bar - Ann.m4b")

        let sanitized = settings.plannedOutputs(for: [slash, dash])
        XCTAssertNotEqual(sanitized[slash.id]?.standardizedFileURL.path, sanitized[dash.id]?.standardizedFileURL.path)
        XCTAssertEqual(sanitized[slash.id]?.lastPathComponent, "Foo-Bar - Ann.m4b")
        XCTAssertEqual(sanitized[dash.id]?.lastPathComponent, "Foo-Bar - Ann - DashBook.m4b")

        let nextTo = ExportSettings(writeNextToBook: true)
        let beside = nextTo.plannedOutputs(for: [editionA, editionB])
        XCTAssertEqual(beside[editionA.id]?.lastPathComponent, "Same - Ann.m4b")
        XCTAssertEqual(beside[editionB.id]?.lastPathComponent, "Same - Ann.m4b")
        XCTAssertNotEqual(beside[editionA.id]?.standardizedFileURL.path, beside[editionB.id]?.standardizedFileURL.path)

        let sameFolderNameA = TestSupport.dummyBook(folder: "/tmp/lib/one/Book", title: "Same", author: "Ann")
        let sameFolderNameB = TestSupport.dummyBook(folder: "/tmp/lib/two/Book", title: "Same", author: "Ann")
        let sameFolderNameC = TestSupport.dummyBook(folder: "/tmp/lib/three/Book", title: "Same", author: "Ann")
        let numbered = settings.plannedOutputs(for: [sameFolderNameA, sameFolderNameB, sameFolderNameC])
        XCTAssertEqual(numbered[sameFolderNameA.id]?.lastPathComponent, "Same - Ann.m4b")
        XCTAssertEqual(numbered[sameFolderNameB.id]?.lastPathComponent, "Same - Ann - Book.m4b")
        XCTAssertEqual(numbered[sameFolderNameC.id]?.lastPathComponent, "Same - Ann - Book 2.m4b")

        let dotted = ExportSettings(
            outputDirectory: URL(fileURLWithPath: "/tmp/OutShared/./", isDirectory: true),
            writeNextToBook: false
        )
        let equivalent = dotted.plannedOutputs(for: [editionA, editionB])
        XCTAssertNotEqual(
            equivalent[editionA.id]?.standardizedFileURL.path,
            equivalent[editionB.id]?.standardizedFileURL.path
        )
        XCTAssertEqual(
            Set(equivalent.values.map(\.standardizedFileURL.path)),
            Set(plan.values.map(\.standardizedFileURL.path))
        )
    }

    func testPlannedOutputsDisambiguatesCaseInsensitiveFileNames() {
        let out = URL(fileURLWithPath: "/tmp/OutShared", isDirectory: true)
        let settings = ExportSettings(outputDirectory: out, writeNextToBook: false)
        let titled = TestSupport.dummyBook(folder: "/tmp/lib/EditionA", title: "Same", author: "Ann", selected: true)
        let lower = TestSupport.dummyBook(folder: "/tmp/lib/EditionB", title: "same", author: "Ann", selected: true)
        XCTAssertEqual(titled.suggestedFileName.lowercased(), lower.suggestedFileName.lowercased())
        XCTAssertNotEqual(titled.suggestedFileName, lower.suggestedFileName)

        let plan = settings.plannedOutputs(for: [titled, lower])
        let pathA = plan[titled.id]?.standardizedFileURL.path
        let pathB = plan[lower.id]?.standardizedFileURL.path
        XCTAssertNotEqual(pathA, pathB)
        XCTAssertNotEqual(pathA?.lowercased(), pathB?.lowercased())
        XCTAssertEqual(plan[titled.id]?.lastPathComponent, "Same - Ann.m4b")
        XCTAssertEqual(plan[lower.id]?.lastPathComponent, "same - Ann - EditionB.m4b")
    }

    func testPlanIgnoresUnselectedBooks() {
        let out = URL(fileURLWithPath: "/tmp/OutShared", isDirectory: true)
        let settings = ExportSettings(outputDirectory: out, writeNextToBook: false)
        let selected = TestSupport.dummyBook(folder: "/tmp/lib/Keep", title: "Same", author: "Ann", selected: true)
        let ignored = TestSupport.dummyBook(folder: "/tmp/lib/Skip", title: "Same", author: "Ann", selected: false)
        let plan = M4BExporter.plan(books: [ignored, selected], settings: settings)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[selected.id]?.lastPathComponent, selected.suggestedFileName)
        XCTAssertNil(plan[ignored.id])
    }

    func testChapterCompareRowsPairOriginalAndBound() {
        let orig = [
            TestSupport.dummyChapter(index: 1),
            TestSupport.dummyChapter(index: 2)
        ]
        let bound = [TestSupport.dummyChapter(index: 1)]
        let rows = ChapterCompare.rows(original: orig, bound: bound)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].index, 1)
        XCTAssertEqual(rows[0].original?.index, 1)
        XCTAssertEqual(rows[0].bound?.index, 1)
        XCTAssertEqual(rows[1].index, 2)
        XCTAssertNotNil(rows[1].original)
        XCTAssertNil(rows[1].bound)
        XCTAssertTrue(ChapterCompare.rows(original: [], bound: []).isEmpty)
    }

    func testChapterCompareSummaryCountsAndPerChapterDuration() {
        let orig = [
            TestSupport.dummyChapter(index: 1, duration: 10),
            TestSupport.dummyChapter(index: 2, duration: 20)
        ]
        let matching = [
            TestSupport.dummyChapter(index: 1, duration: 10.2),
            TestSupport.dummyChapter(index: 2, duration: 20)
        ]
        let match = ChapterCompare.summary(original: orig, bound: matching)
        XCTAssertTrue(match.countsMatch)
        XCTAssertTrue(match.totalsMatch)
        XCTAssertTrue(match.mismatchedIndexes.isEmpty)
        XCTAssertTrue(match.allMatch)
        XCTAssertTrue(match.detail.contains("2 chapters"))
        XCTAssertTrue(match.detail.contains("match"))

        let shortBound = [TestSupport.dummyChapter(index: 1, duration: 10)]
        let counts = ChapterCompare.summary(original: orig, bound: shortBound)
        XCTAssertFalse(counts.countsMatch)
        XCTAssertEqual(counts.originalCount, 2)
        XCTAssertEqual(counts.boundCount, 1)
        XCTAssertTrue(counts.mismatchedIndexes.isEmpty)
        XCTAssertFalse(counts.allMatch)
        XCTAssertTrue(counts.detail.contains("Chapter count differs"))

        let skewed = [
            TestSupport.dummyChapter(index: 1, duration: 10),
            TestSupport.dummyChapter(index: 2, duration: 40)
        ]
        let durations = ChapterCompare.summary(original: orig, bound: skewed)
        XCTAssertTrue(durations.countsMatch)
        XCTAssertEqual(durations.mismatchedIndexes, [2])
        XCTAssertFalse(durations.allMatch)
        XCTAssertTrue(durations.detail.contains("chapter 2"))

        let empty = ChapterCompare.summary(original: [], bound: matching, boundDuration: 30)
        XCTAssertEqual(empty.detail, "No original audio left to compare.")
    }
}
