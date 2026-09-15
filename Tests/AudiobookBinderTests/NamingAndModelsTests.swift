import Darwin
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
        XCTAssertEqual(
            BinderError.publishedUnverified("Could not record source provenance").errorDescription,
            "Could not record source provenance"
        )
        XCTAssertEqual(
            BinderError.publishedUnverified("Could not record output association").errorDescription,
            "Could not record output association"
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
        XCTAssertFalse(ExportOutcome.cancelled.isPublished)
        XCTAssertTrue(ExportOutcome.publishedUnverified(replaced: false, warning: "late hash").isPublished)
        XCTAssertEqual(
            BinderCopy.exportSummary([
                ("KeepCreated", .created),
                ("CancelSecond", .cancelled)
            ]),
            "Created 1 audiobook — KeepCreated. Cancelled 1 audiobook — CancelSecond. Verify the .m4b in the editor."
        )
        XCTAssertEqual(
            BinderCopy.exportSummary([
                ("KeepFirst", .publishedUnverified(replaced: false, warning: "hash failed")),
                ("LeaveSecond", .cancelled)
            ]),
            "Unverified 1 audiobook — KeepFirst (hash failed). Cancelled 1 audiobook — LeaveSecond. Verify the .m4b in the editor."
        )
        XCTAssertEqual(
            BinderCopy.exportSummary([
                ("A", .created),
                ("B", .replaced),
                ("C", .publishedUnverified(replaced: true, warning: "sidecar write failed"))
            ]),
            "Created 1 audiobook — A. Replaced 1 audiobook — B. Unverified 1 audiobook — C (sidecar write failed). Verify the .m4b files in the editor."
        )
    }

    func testCLIOutcomeLineMapsPublishedUnverifiedAwayFromCancelled() {
        let url = URL(fileURLWithPath: "/tmp/out.m4b")
        XCTAssertEqual(BinderCopy.cliOutcomeLine(url: url, outcome: .created), "created\t/tmp/out.m4b")
        XCTAssertEqual(BinderCopy.cliOutcomeLine(url: url, outcome: .replaced), "replaced\t/tmp/out.m4b")
        XCTAssertEqual(BinderCopy.cliOutcomeLine(url: url, outcome: .skippedExisting), "skipped\t/tmp/out.m4b")
        XCTAssertEqual(BinderCopy.cliOutcomeLine(url: url, outcome: .cancelled), "cancelled\t/tmp/out.m4b")
        XCTAssertEqual(
            BinderCopy.cliOutcomeLine(url: url, outcome: .failed("disk full")),
            "failed\t/tmp/out.m4b\tdisk full"
        )
        let unverified = ExportOutcome.publishedUnverified(
            replaced: false,
            warning: "Could not record source provenance"
        )
        let line = BinderCopy.cliOutcomeLine(url: url, outcome: unverified)
        XCTAssertEqual(line, "unverified\t/tmp/out.m4b\tCould not record source provenance")
        XCTAssertFalse(line.hasPrefix("cancelled"))
        XCTAssertNotEqual(line, BinderCopy.cliOutcomeLine(url: url, outcome: .cancelled))
    }

    func testCLIReportsFailureForFailedAndPublishedUnverified() {
        XCTAssertTrue(BinderCopy.cliReportsFailure(.failed("disk full")))
        XCTAssertTrue(
            BinderCopy.cliReportsFailure(.publishedUnverified(replaced: false, warning: "late hash"))
        )
        XCTAssertTrue(
            BinderCopy.cliReportsFailure(.publishedUnverified(replaced: true, warning: "sidecar write failed"))
        )
    }

    func testCLIReportsFailureIsFalseForSuccessfulAndCancelledOutcomes() {
        XCTAssertFalse(BinderCopy.cliReportsFailure(.created))
        XCTAssertFalse(BinderCopy.cliReportsFailure(.replaced))
        XCTAssertFalse(BinderCopy.cliReportsFailure(.skippedExisting))
        XCTAssertFalse(BinderCopy.cliReportsFailure(.cancelled))
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

    func testBOnlyPlanKeepsOwnedSuffixedDestination() {
        let out = URL(fileURLWithPath: "/tmp/OutShared", isDirectory: true)
        let settings = ExportSettings(outputDirectory: out, writeNextToBook: false)
        var editionA = TestSupport.dummyBook(folder: "/tmp/lib/EditionA", title: "Same", author: "Ann")
        var editionB = TestSupport.dummyBook(folder: "/tmp/lib/EditionB", title: "Same", author: "Ann")

        let first = settings.plannedOutputs(for: [editionA, editionB])
        XCTAssertEqual(first[editionA.id]?.lastPathComponent, "Same - Ann.m4b")
        XCTAssertEqual(first[editionB.id]?.lastPathComponent, "Same - Ann - EditionB.m4b")

        editionA.existingM4BURL = first[editionA.id]
        editionB.existingM4BURL = first[editionB.id]

        let bOnly = settings.plannedOutputs(for: [editionB])
        XCTAssertEqual(bOnly[editionB.id]?.standardizedFileURL.path, first[editionB.id]?.standardizedFileURL.path)
        XCTAssertEqual(bOnly[editionB.id]?.lastPathComponent, "Same - Ann - EditionB.m4b")
        XCTAssertNotEqual(bOnly[editionB.id]?.lastPathComponent, "Same - Ann.m4b")
        XCTAssertNotEqual(bOnly[editionB.id]?.standardizedFileURL.path, first[editionA.id]?.standardizedFileURL.path)
    }

    func testReversedQueueKeepsPreviousDestinations() {
        let out = URL(fileURLWithPath: "/tmp/OutShared", isDirectory: true)
        let settings = ExportSettings(outputDirectory: out, writeNextToBook: false)
        var editionA = TestSupport.dummyBook(folder: "/tmp/lib/EditionA", title: "Same", author: "Ann")
        var editionB = TestSupport.dummyBook(folder: "/tmp/lib/EditionB", title: "Same", author: "Ann")

        let first = settings.plannedOutputs(for: [editionA, editionB])
        editionA.existingM4BURL = first[editionA.id]
        editionB.existingM4BURL = first[editionB.id]

        let reversed = settings.plannedOutputs(for: [editionB, editionA])
        XCTAssertEqual(reversed[editionA.id]?.standardizedFileURL.path, first[editionA.id]?.standardizedFileURL.path)
        XCTAssertEqual(reversed[editionB.id]?.standardizedFileURL.path, first[editionB.id]?.standardizedFileURL.path)
        XCTAssertEqual(reversed[editionA.id]?.lastPathComponent, "Same - Ann.m4b")
        XCTAssertEqual(reversed[editionB.id]?.lastPathComponent, "Same - Ann - EditionB.m4b")
    }

    func testRescanRestoresOwnedDestinationFromSidecar() async throws {
        let root = try TestSupport.tempDir("rescan-owned-dest")
        defer { try? FileManager.default.removeItem(at: root) }
        let editionA = root.appendingPathComponent("EditionA", isDirectory: true)
        let editionB = root.appendingPathComponent("EditionB", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: editionA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: editionB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data().write(to: editionA.appendingPathComponent("01.mp3"))
        try Data().write(to: editionB.appendingPathComponent("01.mp3"))

        let destA = out.appendingPathComponent("Same - Ann.m4b")
        let destB = out.appendingPathComponent("Same - Ann - EditionB.m4b")
        try Data("A-BYTES".utf8).write(to: destA)
        try Data("B-BYTES".utf8).write(to: destB)
        try writeOutputSidecar(destA, in: editionA)
        try writeOutputSidecar(destB, in: editionB)

        let loadedB = try await BookScanner().loadBook(at: editionB)
        XCTAssertNotEqual(loadedB.id.uuidString, TestSupport.dummyBook(folder: editionB.path).id.uuidString)
        XCTAssertEqual(loadedB.existingM4BURL?.standardizedFileURL.path, destB.standardizedFileURL.path)

        var rescannedB = loadedB
        rescannedB.title = "Same"
        rescannedB.author = "Ann"
        let settings = ExportSettings(outputDirectory: out, writeNextToBook: false)
        let bOnly = settings.plannedOutputs(for: [rescannedB])
        XCTAssertEqual(bOnly[rescannedB.id]?.standardizedFileURL.path, destB.standardizedFileURL.path)
        XCTAssertNotEqual(bOnly[rescannedB.id]?.standardizedFileURL.path, destA.standardizedFileURL.path)

        let freshB = TestSupport.dummyBook(folder: editionB.path, title: "Same", author: "Ann")
        XCTAssertNil(freshB.existingM4BURL)
        XCTAssertNotEqual(freshB.id, loadedB.id)
        let fromSidecar = settings.plannedOutputs(for: [freshB])
        XCTAssertEqual(fromSidecar[freshB.id]?.standardizedFileURL.path, destB.standardizedFileURL.path)
    }

    func testUnrelatedPreexistingPrimaryIsNotClaimed() throws {
        let root = try TestSupport.tempDir("unrelated-primary")
        defer { try? FileManager.default.removeItem(at: root) }
        let editionB = root.appendingPathComponent("EditionB", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: editionB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let primary = out.appendingPathComponent("Same - Ann.m4b")
        try Data("UNRELATED".utf8).write(to: primary)
        let book = TestSupport.dummyBook(folder: editionB.path, title: "Same", author: "Ann")
        let settings = ExportSettings(outputDirectory: out, writeNextToBook: false)
        let plan = settings.plannedOutputs(for: [book])
        XCTAssertEqual(plan[book.id]?.lastPathComponent, "Same - Ann - EditionB.m4b")
        XCTAssertNotEqual(plan[book.id]?.standardizedFileURL.path, primary.standardizedFileURL.path)
    }

    func testOnDiskCaseEquivalentPrimaryIsNotClaimed() throws {
        let root = try TestSupport.tempDir("case-occupied-primary")
        defer { try? FileManager.default.removeItem(at: root) }
        let editionB = root.appendingPathComponent("EditionB", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: editionB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        try Data("UNRELATED".utf8).write(to: out.appendingPathComponent("Same - Ann.m4b"))
        let book = TestSupport.dummyBook(folder: editionB.path, title: "same", author: "Ann")
        let settings = ExportSettings(outputDirectory: out, writeNextToBook: false)
        let plan = settings.plannedOutputs(for: [book])
        XCTAssertEqual(plan[book.id]?.lastPathComponent, "same - Ann - EditionB.m4b")
        XCTAssertNotEqual(plan[book.id]?.lastPathComponent.lowercased(), "same - ann.m4b")
    }

    func testPersistedDestOutsideOutputDirectoryIsNotReused() throws {
        let root = try TestSupport.tempDir("dest-dir-change")
        defer { try? FileManager.default.removeItem(at: root) }
        let editionB = root.appendingPathComponent("EditionB", isDirectory: true)
        let oldOut = root.appendingPathComponent("old-out", isDirectory: true)
        let newOut = root.appendingPathComponent("new-out", isDirectory: true)
        try FileManager.default.createDirectory(at: editionB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oldOut, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newOut, withIntermediateDirectories: true)

        let oldDest = oldOut.appendingPathComponent("Same - Ann - EditionB.m4b")
        try Data("OLD-B".utf8).write(to: oldDest)
        try Data("TAKEN".utf8).write(to: newOut.appendingPathComponent("Same - Ann.m4b"))
        try writeOutputSidecar(oldDest, in: editionB)

        var book = TestSupport.dummyBook(folder: editionB.path, title: "Same", author: "Ann")
        book.existingM4BURL = oldDest
        let settings = ExportSettings(outputDirectory: newOut, writeNextToBook: false)
        let plan = settings.plannedOutputs(for: [book])
        XCTAssertEqual(plan[book.id]?.lastPathComponent, "Same - Ann - EditionB.m4b")
        XCTAssertEqual(plan[book.id]?.deletingLastPathComponent().standardizedFileURL.path, newOut.standardizedFileURL.path)
        XCTAssertNotEqual(plan[book.id]?.standardizedFileURL.path, oldDest.standardizedFileURL.path)
        XCTAssertNotEqual(plan[book.id]?.lastPathComponent, "Same - Ann.m4b")
    }

    func testTitleChangeAllocatesFreshNameWithoutStealing() throws {
        let root = try TestSupport.tempDir("title-change")
        defer { try? FileManager.default.removeItem(at: root) }
        let editionB = root.appendingPathComponent("EditionB", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: editionB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let oldDest = out.appendingPathComponent("Same - Ann - EditionB.m4b")
        try Data("OLD-B".utf8).write(to: oldDest)
        try Data("TAKEN".utf8).write(to: out.appendingPathComponent("Other - Ann.m4b"))
        try writeOutputSidecar(oldDest, in: editionB)

        var book = TestSupport.dummyBook(folder: editionB.path, title: "Other", author: "Ann")
        book.existingM4BURL = oldDest
        let settings = ExportSettings(outputDirectory: out, writeNextToBook: false)
        let plan = settings.plannedOutputs(for: [book])
        XCTAssertEqual(plan[book.id]?.lastPathComponent, "Other - Ann - EditionB.m4b")
        XCTAssertNotEqual(plan[book.id]?.standardizedFileURL.path, oldDest.standardizedFileURL.path)
        XCTAssertNotEqual(plan[book.id]?.lastPathComponent, "Other - Ann.m4b")
    }

    func testWriteNextToBookStillUsesPrimaryBesideEachFolder() {
        let nextTo = ExportSettings(writeNextToBook: true)
        let editionA = TestSupport.dummyBook(folder: "/tmp/lib/EditionA", title: "Same", author: "Ann")
        let editionB = TestSupport.dummyBook(folder: "/tmp/lib/EditionB", title: "Same", author: "Ann")
        let beside = nextTo.plannedOutputs(for: [editionA, editionB])
        XCTAssertEqual(beside[editionA.id]?.lastPathComponent, "Same - Ann.m4b")
        XCTAssertEqual(beside[editionB.id]?.lastPathComponent, "Same - Ann.m4b")
        XCTAssertEqual(beside[editionA.id]?.deletingLastPathComponent().path, "/tmp/lib/EditionA")
        XCTAssertEqual(beside[editionB.id]?.deletingLastPathComponent().path, "/tmp/lib/EditionB")
    }

    func testStaleExistingM4BURLDoesNotOwnReplacedSharedDest() throws {
        let root = try TestSupport.tempDir("stale-existing-m4b")
        defer { try? FileManager.default.removeItem(at: root) }
        let editionB = root.appendingPathComponent("EditionB", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: editionB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let dest = out.appendingPathComponent("Same - Ann.m4b")
        try Data("OWNED-B".utf8).write(to: dest)
        OutputAssociation.record(dest, inBookFolder: editionB)
        try Data("REPLACED-SENTINEL".utf8).write(to: dest)

        var book = TestSupport.dummyBook(folder: editionB.path, title: "Same", author: "Ann")
        book.existingM4BURL = dest
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        XCTAssertFalse(settings.owns(dest, for: book))
        let plan = settings.plannedOutputs(for: [book])
        XCTAssertNotEqual(plan[book.id]?.standardizedFileURL.path, dest.standardizedFileURL.path)
        XCTAssertEqual(plan[book.id]?.pathExtension.lowercased(), "m4b")
    }

    func testExistingM4BURLWithoutSidecarDoesNotOwnSharedDest() throws {
        let root = try TestSupport.tempDir("existing-no-sidecar")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDir = root.appendingPathComponent("BookA", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let dest = out.appendingPathComponent("ReplaceMe - System.m4b")
        try Data("OLD-DEST".utf8).write(to: dest)
        var book = TestSupport.dummyBook(folder: bookDir.path, title: "ReplaceMe", author: "System")
        book.existingM4BURL = dest
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        XCTAssertFalse(settings.owns(dest, for: book))
        let plan = settings.plannedOutputs(for: [book])
        XCTAssertNotEqual(plan[book.id]?.standardizedFileURL.path, dest.standardizedFileURL.path)
        XCTAssertEqual(plan[book.id]?.pathExtension.lowercased(), "m4b")
    }

    func testLeftoverInFolderM4BIsNotOwnedWhenWritingNextToBook() throws {
        let root = try TestSupport.tempDir("leftover-in-folder")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDir = root.appendingPathComponent("BookA", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)

        var book = TestSupport.dummyBook(folder: bookDir.path, title: "Same", author: "Ann")
        let dest = bookDir.appendingPathComponent(book.suggestedFileName)
        let leftover = Data("LEFTOVER-M4B".utf8)
        try leftover.write(to: dest)
        book.existingM4BURL = dest
        let settings = ExportSettings(overwrite: true, writeNextToBook: true)
        XCTAssertFalse(settings.owns(dest, for: book))
        let plan = settings.plannedOutputs(for: [book])
        XCTAssertNotEqual(plan[book.id]?.standardizedFileURL.path, dest.standardizedFileURL.path)
        XCTAssertEqual(plan[book.id]?.pathExtension.lowercased(), "m4b")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan[book.id]!.path))
        XCTAssertEqual(try Data(contentsOf: dest), leftover)
    }

    func testForgedStructuredFolderJSONDoesNotOwnSharedDest() throws {
        let root = try TestSupport.tempDir("forged-structured-json")
        defer { try? FileManager.default.removeItem(at: root) }
        let editionB = root.appendingPathComponent("EditionB", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: editionB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let dest = out.appendingPathComponent("Same - Ann.m4b")
        let payload = Data("FORGED-SHARED-DEST".utf8)
        try payload.write(to: dest)
        try TestSupport.writeStructuredOutputSidecar(dest, in: editionB)

        XCTAssertNil(OutputAssociation.load(inBookFolder: editionB))
        XCTAssertEqual(
            OutputAssociation.destinationHint(inBookFolder: editionB)?.standardizedFileURL.path,
            dest.standardizedFileURL.path
        )

        let book = TestSupport.dummyBook(folder: editionB.path, title: "Same", author: "Ann")
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        XCTAssertFalse(settings.owns(dest, for: book))
        let plan = settings.plannedOutputs(for: [book])
        XCTAssertNotEqual(plan[book.id]?.standardizedFileURL.path, dest.standardizedFileURL.path)
        XCTAssertEqual(plan[book.id]?.pathExtension.lowercased(), "m4b")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan[book.id]!.path))
        XCTAssertEqual(try Data(contentsOf: dest), payload)
    }

    func testAppIssuedAuthoritySurvivesDeletedFolderSidecar() throws {
        let root = try TestSupport.tempDir("authority-without-sidecar")
        defer { try? FileManager.default.removeItem(at: root) }
        let editionB = root.appendingPathComponent("EditionB", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: editionB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let dest = out.appendingPathComponent("Same - Ann - EditionB.m4b")
        try Data("OWNED-B".utf8).write(to: dest)
        OutputAssociation.record(dest, inBookFolder: editionB)
        XCTAssertEqual(
            OutputAssociation.load(inBookFolder: editionB)?.standardizedFileURL.path,
            dest.standardizedFileURL.path
        )

        try FileManager.default.removeItem(at: editionB.appendingPathComponent(OutputAssociation.fileName))
        XCTAssertNil(OutputAssociation.destinationHint(inBookFolder: editionB))
        XCTAssertEqual(
            OutputAssociation.load(inBookFolder: editionB)?.standardizedFileURL.path,
            dest.standardizedFileURL.path
        )

        let book = TestSupport.dummyBook(folder: editionB.path, title: "Same", author: "Ann")
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        XCTAssertTrue(settings.owns(dest, for: book))
        let plan = settings.plannedOutputs(for: [book])
        XCTAssertEqual(plan[book.id]?.standardizedFileURL.path, dest.standardizedFileURL.path)
    }

    func testXCTestAuthorityStoreIsIsolatedFromApplicationSupport() throws {
        let root = try TestSupport.tempDir("authority-isolation")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDir = root.appendingPathComponent("BookA", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        let dest = root.appendingPathComponent("Same - Ann.m4b")
        try Data("OWNED".utf8).write(to: dest)
        OutputAssociation.record(dest, inBookFolder: bookDir)

        let store = OutputAssociation.resolvedAuthorityDirectory()
        XCTAssertTrue(store.path.contains("xctest-output-authority"))
        XCTAssertFalse(store.path.contains("Library/Application Support/AudiobookBinder"))
        XCTAssertNotNil(OutputAssociation.load(inBookFolder: bookDir))
    }

    func testAuthorityLoadSurvivesAlternateResourceIdentifierArchive() throws {
        let root = try TestSupport.tempDir("authority-alt-archive")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDir = root.appendingPathComponent("BookA", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let dest = out.appendingPathComponent("Same - Ann.m4b")
        let payload = Data("OWNED-A".utf8)
        try payload.write(to: dest)
        OutputAssociation.record(dest, inBookFolder: bookDir)

        let folderIdentity = try XCTUnwrap(FileIdentity.read(from: bookDir))
        let originalRID = try XCTUnwrap(folderIdentity.fileResourceIdentifier)
        let alternate = try XCTUnwrap(FileIdentity.alternateResourceIdentifierArchive(originalRID))
        XCTAssertNotEqual(alternate, originalRID)
        XCTAssertTrue(folderIdentity.replacingResourceIdentifier(alternate).matchesRecordedIdentity(folderIdentity))

        XCTAssertTrue(
            OutputAssociation.replaceStoredBookFolderResourceIdentifier(inBookFolder: bookDir, with: alternate)
        )
        XCTAssertEqual(
            OutputAssociation.load(inBookFolder: bookDir)?.standardizedFileURL.path,
            dest.standardizedFileURL.path
        )
        let book = TestSupport.dummyBook(folder: bookDir.path, title: "Same", author: "Ann")
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        XCTAssertTrue(settings.owns(dest, for: book))
        XCTAssertEqual(try Data(contentsOf: dest), payload)
    }

    func testAuthorityLoadResolvesByPathAfterReread() throws {
        let root = try TestSupport.tempDir("authority-reread")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDir = root.appendingPathComponent("BookA", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let dest = out.appendingPathComponent("Same - Ann.m4b")
        try Data("OWNED-A".utf8).write(to: dest)
        OutputAssociation.record(dest, inBookFolder: bookDir)
        XCTAssertEqual(
            OutputAssociation.load(inBookFolder: bookDir)?.standardizedFileURL.path,
            dest.standardizedFileURL.path
        )
        XCTAssertEqual(
            OutputAssociation.load(inBookFolder: bookDir)?.standardizedFileURL.path,
            dest.standardizedFileURL.path,
            "A second load from the same store must resolve by path index"
        )
        let book = TestSupport.dummyBook(folder: bookDir.path, title: "Same", author: "Ann")
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        XCTAssertTrue(settings.owns(dest, for: book))
    }

    func testAuthorityLoadResolvesRenamedFolderViaIdentityScan() throws {
        let root = try TestSupport.tempDir("authority-rename")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDir = root.appendingPathComponent("BookA", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let dest = out.appendingPathComponent("Same - Ann.m4b")
        try Data("OWNED-A".utf8).write(to: dest)
        OutputAssociation.record(dest, inBookFolder: bookDir)

        let renamed = root.appendingPathComponent("BookA2", isDirectory: true)
        try FileManager.default.moveItem(at: bookDir, to: renamed)
        XCTAssertEqual(
            OutputAssociation.load(inBookFolder: renamed)?.standardizedFileURL.path,
            dest.standardizedFileURL.path,
            "Rename on the same volume resolves via identity scan and refreshes the path index"
        )
        XCTAssertEqual(
            OutputAssociation.load(inBookFolder: renamed)?.standardizedFileURL.path,
            dest.standardizedFileURL.path
        )

        let other = root.appendingPathComponent("BookC", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertNil(OutputAssociation.load(inBookFolder: other))
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        let bookRenamed = TestSupport.dummyBook(folder: renamed.path, title: "Same", author: "Ann")
        let bookC = TestSupport.dummyBook(folder: other.path, title: "Same", author: "Ann")
        XCTAssertTrue(settings.owns(dest, for: bookRenamed))
        XCTAssertFalse(settings.owns(dest, for: bookC))
    }

    func testAuthorityDoesNotGrantOtherFolderOrForgedSidecar() throws {
        let root = try TestSupport.tempDir("authority-other-folder")
        defer { try? FileManager.default.removeItem(at: root) }
        let editionA = root.appendingPathComponent("EditionA", isDirectory: true)
        let editionB = root.appendingPathComponent("EditionB", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: editionA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: editionB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let destA = out.appendingPathComponent("Same - Ann.m4b")
        let payload = Data("OWNED-A".utf8)
        try payload.write(to: destA)
        OutputAssociation.record(destA, inBookFolder: editionA)
        try TestSupport.writeStructuredOutputSidecar(destA, in: editionB)

        XCTAssertEqual(
            OutputAssociation.load(inBookFolder: editionA)?.standardizedFileURL.path,
            destA.standardizedFileURL.path
        )
        XCTAssertNil(OutputAssociation.load(inBookFolder: editionB))
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        let bookA = TestSupport.dummyBook(folder: editionA.path, title: "Same", author: "Ann")
        let bookB = TestSupport.dummyBook(folder: editionB.path, title: "Same", author: "Ann")
        XCTAssertTrue(settings.owns(destA, for: bookA))
        XCTAssertFalse(settings.owns(destA, for: bookB))
        XCTAssertEqual(try Data(contentsOf: destA), payload)
    }

    func testAuthorityLoadRejectsReplacedDestination() throws {
        let root = try TestSupport.tempDir("authority-replaced-dest")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDir = root.appendingPathComponent("BookA", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let dest = out.appendingPathComponent("Same - Ann.m4b")
        try Data("OWNED-A".utf8).write(to: dest)
        OutputAssociation.record(dest, inBookFolder: bookDir)
        try Data("REPLACED-DEST".utf8).write(to: dest)

        XCTAssertNil(OutputAssociation.load(inBookFolder: bookDir))
        let book = TestSupport.dummyBook(folder: bookDir.path, title: "Same", author: "Ann")
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        XCTAssertFalse(settings.owns(dest, for: book))
    }

    func testCaseDistinctFoldersKeepIndependentAuthorityRecords() throws {
        try withIsolatedAuthorityStore { _ in
            let fixture = try caseDistinctFixtureRoot()
            defer { fixture.cleanup() }

            let library = fixture.root.appendingPathComponent("Library", isDirectory: true)
            let edition = library.appendingPathComponent("Edition", isDirectory: true)
            let editionLower = library.appendingPathComponent("edition", isDirectory: true)
            let out = fixture.root.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: edition, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: editionLower, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

            let editionIdentity = try XCTUnwrap(FileIdentity.read(from: edition))
            let lowerIdentity = try XCTUnwrap(FileIdentity.read(from: editionLower))
            XCTAssertFalse(
                editionIdentity.matchesRecordedIdentity(lowerIdentity),
                "Edition and edition must be distinct filesystem objects"
            )

            let destA = out.appendingPathComponent("Same - Ann - Edition.m4b")
            let destB = out.appendingPathComponent("Same - Ann - paperback.m4b")
            let payloadA = Data("OWNED-EDITION".utf8)
            let payloadB = Data("OWNED-edition".utf8)
            try payloadA.write(to: destA)
            try payloadB.write(to: destB)

            OutputAssociation.record(destA, inBookFolder: edition)
            OutputAssociation.record(destB, inBookFolder: editionLower)

            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: edition)?.standardizedFileURL.path,
                destA.standardizedFileURL.path
            )
            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: editionLower)?.standardizedFileURL.path,
                destB.standardizedFileURL.path
            )
            XCTAssertEqual(try Data(contentsOf: destA), payloadA)
            XCTAssertEqual(try Data(contentsOf: destB), payloadB)
            XCTAssertEqual(OutputAssociation.authorityDocumentCount(), 2)

            let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
            let bookA = TestSupport.dummyBook(folder: edition.path, title: "Same", author: "Ann")
            let bookB = TestSupport.dummyBook(folder: editionLower.path, title: "Same", author: "Ann")
            XCTAssertTrue(settings.owns(destA, for: bookA))
            XCTAssertFalse(settings.owns(destB, for: bookA))
            XCTAssertTrue(settings.owns(destB, for: bookB))
            XCTAssertFalse(settings.owns(destA, for: bookB))

            OutputAssociation.record(out.appendingPathComponent("missing.m4b"), inBookFolder: edition)
            XCTAssertNil(OutputAssociation.load(inBookFolder: edition))
            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: editionLower)?.standardizedFileURL.path,
                destB.standardizedFileURL.path
            )
            XCTAssertEqual(try Data(contentsOf: destB), payloadB)
            XCTAssertEqual(OutputAssociation.authorityDocumentCount(), 1)

            OutputAssociation.record(destA, inBookFolder: edition)
            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: edition)?.standardizedFileURL.path,
                destA.standardizedFileURL.path
            )
            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: editionLower)?.standardizedFileURL.path,
                destB.standardizedFileURL.path
            )
            XCTAssertEqual(OutputAssociation.authorityDocumentCount(), 2)

            OutputAssociation.record(destB, inBookFolder: editionLower)
            OutputAssociation.record(destA, inBookFolder: edition)
            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: edition)?.standardizedFileURL.path,
                destA.standardizedFileURL.path
            )
            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: editionLower)?.standardizedFileURL.path,
                destB.standardizedFileURL.path
            )
            XCTAssertEqual(try Data(contentsOf: destA), payloadA)
            XCTAssertEqual(try Data(contentsOf: destB), payloadB)
            XCTAssertEqual(OutputAssociation.authorityDocumentCount(), 2)

            OutputAssociation.record(destA, inBookFolder: edition)
            OutputAssociation.record(destB, inBookFolder: editionLower)
            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: edition)?.standardizedFileURL.path,
                destA.standardizedFileURL.path
            )
            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: editionLower)?.standardizedFileURL.path,
                destB.standardizedFileURL.path
            )
            XCTAssertEqual(try Data(contentsOf: destA), payloadA)
            XCTAssertEqual(try Data(contentsOf: destB), payloadB)
            XCTAssertEqual(OutputAssociation.authorityDocumentCount(), 2)
            XCTAssertTrue(settings.owns(destA, for: bookA))
            XCTAssertFalse(settings.owns(destB, for: bookA))
            XCTAssertTrue(settings.owns(destB, for: bookB))
            XCTAssertFalse(settings.owns(destA, for: bookB))
        }
    }

    func testPathIndexHintForDifferentIdentityDoesNotOverwriteAuthority() throws {
        try withIsolatedAuthorityStore { _ in
            let root = try TestSupport.tempDir("r6-01-stale-hint")
            defer { try? FileManager.default.removeItem(at: root) }
            let folderA = root.appendingPathComponent("FolderA", isDirectory: true)
            let folderB = root.appendingPathComponent("FolderB", isDirectory: true)
            let out = root.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

            let destA = out.appendingPathComponent("Same - Ann - A.m4b")
            let destB = out.appendingPathComponent("Same - Ann - B.m4b")
            let payloadA = Data("OWNED-A".utf8)
            let payloadB = Data("OWNED-B".utf8)
            try payloadA.write(to: destA)
            try payloadB.write(to: destB)

            OutputAssociation.record(destA, inBookFolder: folderA)
            let idA = try XCTUnwrap(OutputAssociation.recordedAssociationID(inBookFolder: folderA))
            XCTAssertEqual(OutputAssociation.authorityDocumentCount(), 1)

            OutputAssociation.plantPathIndexHint(idA, for: folderB)
            OutputAssociation.record(destB, inBookFolder: folderB)

            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: folderA)?.standardizedFileURL.path,
                destA.standardizedFileURL.path
            )
            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: folderB)?.standardizedFileURL.path,
                destB.standardizedFileURL.path
            )
            XCTAssertEqual(try Data(contentsOf: destA), payloadA)
            XCTAssertEqual(OutputAssociation.authorityDocumentCount(), 2)
        }
    }

    func testCaseVariantPathOfSameFolderReusesAuthoritySafely() throws {
        try withIsolatedAuthorityStore { _ in
            let root = try TestSupport.tempDir("r6-01-case-variant")
            defer { try? FileManager.default.removeItem(at: root) }
            if try volumeIsCaseSensitive(at: root) {
                throw XCTSkip("Fixture volume is case-sensitive; cannot spell the same folder two ways")
            }

            let bookDir = root.appendingPathComponent("Edition", isDirectory: true)
            let out = root.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

            let dest = out.appendingPathComponent("Same - Ann.m4b")
            let payload = Data("OWNED-VARIANT".utf8)
            try payload.write(to: dest)
            OutputAssociation.record(dest, inBookFolder: bookDir)

            let variant = root.appendingPathComponent("edition", isDirectory: true)
            let recorded = try XCTUnwrap(FileIdentity.read(from: bookDir))
            let variantIdentity = try XCTUnwrap(FileIdentity.read(from: variant))
            XCTAssertTrue(
                variantIdentity.matchesRecordedIdentity(recorded),
                "Alternate capitalization must resolve to the same folder object"
            )

            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: variant)?.standardizedFileURL.path,
                dest.standardizedFileURL.path
            )
            XCTAssertEqual(OutputAssociation.authorityDocumentCount(), 1)

            OutputAssociation.record(dest, inBookFolder: variant)
            XCTAssertEqual(OutputAssociation.authorityDocumentCount(), 1)
            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: bookDir)?.standardizedFileURL.path,
                dest.standardizedFileURL.path
            )
            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: variant)?.standardizedFileURL.path,
                dest.standardizedFileURL.path
            )
            XCTAssertEqual(try Data(contentsOf: dest), payload)

            let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
            let book = TestSupport.dummyBook(folder: bookDir.path, title: "Same", author: "Ann")
            let bookVariant = TestSupport.dummyBook(folder: variant.path, title: "Same", author: "Ann")
            XCTAssertTrue(settings.owns(dest, for: book))
            XCTAssertTrue(settings.owns(dest, for: bookVariant))
        }
    }

    func testPathIndexJustUnderAndAtLimitRemainsLoadable() throws {
        try withIsolatedAuthorityStore { store in
            let root = try TestSupport.tempDir("r6-02-index-limit-loadable")
            defer { try? FileManager.default.removeItem(at: root) }
            let folderA = root.appendingPathComponent("FolderA", isDirectory: true)
            let out = root.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

            let destA = out.appendingPathComponent("Same - Ann - A.m4b")
            let payloadA = Data("OWNED-A-LIMIT".utf8)
            try payloadA.write(to: destA)
            OutputAssociation.record(destA, inBookFolder: folderA)
            let idA = try XCTUnwrap(OutputAssociation.recordedAssociationID(inBookFolder: folderA))

            let under = try XCTUnwrap(
                OutputAssociation.writeLargestLoadablePathIndex(
                    including: [folderA.standardizedFileURL.path: idA]
                )
            )
            XCTAssertLessThanOrEqual(under, OutputAssociation.maxPathIndexBytes)
            XCTAssertTrue(OutputAssociation.isPathIndexLoadable())
            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: folderA)?.standardizedFileURL.path,
                destA.standardizedFileURL.path
            )
            XCTAssertEqual(try Data(contentsOf: destA), payloadA)

            let exact = try XCTUnwrap(OutputAssociation.padPathIndexToExactLimit())
            XCTAssertEqual(exact, OutputAssociation.maxPathIndexBytes)
            XCTAssertTrue(OutputAssociation.isPathIndexLoadable())
            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: folderA)?.standardizedFileURL.path,
                destA.standardizedFileURL.path
            )
            XCTAssertEqual(try Data(contentsOf: destA), payloadA)
            _ = store
        }
    }

    func testRecordDoesNotWriteOverLimitPathIndex() throws {
        try withIsolatedAuthorityStore { store in
            let root = try TestSupport.tempDir("r6-02-index-over-limit")
            defer { try? FileManager.default.removeItem(at: root) }
            let folderA = root.appendingPathComponent("FolderA", isDirectory: true)
            let folderB = root.appendingPathComponent("FolderB", isDirectory: true)
            let out = root.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

            let destA = out.appendingPathComponent("Same - Ann - A.m4b")
            let destB = out.appendingPathComponent("Same - Ann - B.m4b")
            let payloadA = Data("OWNED-A-KEEP".utf8)
            let payloadB = Data("OWNED-B-NEW".utf8)
            try payloadA.write(to: destA)
            try payloadB.write(to: destB)

            OutputAssociation.record(destA, inBookFolder: folderA)
            let idA = try XCTUnwrap(OutputAssociation.recordedAssociationID(inBookFolder: folderA))
            let under = try XCTUnwrap(
                OutputAssociation.writeLargestLoadablePathIndex(
                    including: [folderA.standardizedFileURL.path: idA]
                )
            )
            XCTAssertLessThanOrEqual(under, OutputAssociation.maxPathIndexBytes)
            let projected = try XCTUnwrap(
                OutputAssociation.encodedByteCountIfInsertingPath(folderB.standardizedFileURL.path)
            )
            XCTAssertGreaterThan(
                projected,
                OutputAssociation.maxPathIndexBytes,
                "Near-limit fixture must be tight enough that one more record exceeds"
            )

            let indexURL = store.appendingPathComponent(OutputAssociation.pathIndexFileName)
            let before = try Data(contentsOf: indexURL)
            XCTAssertTrue(OutputAssociation.isPathIndexLoadable())

            OutputAssociation.record(destB, inBookFolder: folderB)

            let after = try Data(contentsOf: indexURL)
            XCTAssertEqual(after, before, "Over-limit persist must leave the previous index bytes untouched")
            XCTAssertTrue(OutputAssociation.isPathIndexLoadable())
            XCTAssertLessThanOrEqual(
                try XCTUnwrap(OutputAssociation.pathIndexByteCount()),
                OutputAssociation.maxPathIndexBytes
            )
            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: folderA)?.standardizedFileURL.path,
                destA.standardizedFileURL.path
            )
            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: folderB)?.standardizedFileURL.path,
                destB.standardizedFileURL.path
            )
            XCTAssertEqual(try Data(contentsOf: destA), payloadA)
            XCTAssertEqual(try Data(contentsOf: destB), payloadB)
            XCTAssertGreaterThanOrEqual(OutputAssociation.authorityDocumentCount(), 2)
        }
    }

    func testUnusablePathIndexIsNotReplacedByOneRecordRepair() throws {
        try withIsolatedAuthorityStore { store in
            let root = try TestSupport.tempDir("r6-02-unusable-index")
            defer { try? FileManager.default.removeItem(at: root) }
            let folderA = root.appendingPathComponent("FolderA", isDirectory: true)
            let folderB = root.appendingPathComponent("FolderB", isDirectory: true)
            let folderC = root.appendingPathComponent("FolderC", isDirectory: true)
            let out = root.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folderC, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

            let destA = out.appendingPathComponent("Same - Ann - A.m4b")
            let destB = out.appendingPathComponent("Same - Ann - B.m4b")
            let payloadA = Data("OWNED-A-UNUSABLE".utf8)
            let payloadB = Data("OWNED-B-UNUSABLE".utf8)
            try payloadA.write(to: destA)
            try payloadB.write(to: destB)

            OutputAssociation.record(destA, inBookFolder: folderA)
            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: folderA)?.standardizedFileURL.path,
                destA.standardizedFileURL.path
            )

            var oversized = Data("{\"paths\":{".utf8)
            oversized.append(Data(repeating: UInt8(ascii: "x"), count: OutputAssociation.maxPathIndexBytes + 64))
            oversized.append(contentsOf: "}}".utf8)
            XCTAssertGreaterThan(oversized.count, OutputAssociation.maxPathIndexBytes)
            OutputAssociation.writePathIndexJSON(oversized)
            XCTAssertFalse(OutputAssociation.isPathIndexLoadable())
            let plantedCount = try XCTUnwrap(OutputAssociation.pathIndexByteCount())
            XCTAssertGreaterThan(plantedCount, OutputAssociation.maxPathIndexBytes)

            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: folderA)?.standardizedFileURL.path,
                destA.standardizedFileURL.path
            )
            XCTAssertFalse(OutputAssociation.isPathIndexLoadable())
            XCTAssertEqual(OutputAssociation.pathIndexByteCount(), plantedCount)

            OutputAssociation.record(destB, inBookFolder: folderB)
            XCTAssertFalse(OutputAssociation.isPathIndexLoadable())
            XCTAssertEqual(OutputAssociation.pathIndexByteCount(), plantedCount)
            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: folderA)?.standardizedFileURL.path,
                destA.standardizedFileURL.path
            )
            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: folderB)?.standardizedFileURL.path,
                destB.standardizedFileURL.path
            )
            XCTAssertEqual(try Data(contentsOf: destA), payloadA)
            XCTAssertEqual(try Data(contentsOf: destB), payloadB)

            try TestSupport.writeStructuredOutputSidecar(destA, in: folderC)
            XCTAssertNil(OutputAssociation.load(inBookFolder: folderC))
            let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
            let bookC = TestSupport.dummyBook(folder: folderC.path, title: "Same", author: "Ann")
            XCTAssertFalse(settings.owns(destA, for: bookC))
            _ = store
        }
    }

    func testAuthorityScanFindsRecordBeyond512Prefix() throws {
        try withIsolatedAuthorityStore { _ in
            let root = try TestSupport.tempDir("r6-02-scan-beyond-512")
            defer { try? FileManager.default.removeItem(at: root) }
            let folder = root.appendingPathComponent("FolderReal", isDirectory: true)
            let out = root.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

            OutputAssociation.plantSyntheticAuthorityDocuments(count: 512)
            let dest = out.appendingPathComponent("Same - Ann.m4b")
            let payload = Data("OWNED-BEYOND-512".utf8)
            try payload.write(to: dest)
            OutputAssociation.record(dest, inBookFolder: folder)
            let id = try XCTUnwrap(OutputAssociation.recordedAssociationID(inBookFolder: folder))
            XCTAssertGreaterThan(
                id.uuidString,
                "00000000-0000-4000-8000-0000000001ff",
                "Real document must sort after the 512 synthetic prefix"
            )
            XCTAssertGreaterThan(OutputAssociation.authorityDocumentCount(), 512)
            OutputAssociation.writePathIndexJSON(Data("{\"paths\":{}}\n".utf8))

            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: folder)?.standardizedFileURL.path,
                dest.standardizedFileURL.path
            )
            XCTAssertEqual(try Data(contentsOf: dest), payload)
        }
    }

    func testImportedSidecarNotesTxtIsNotOwned() throws {
        let root = try TestSupport.tempDir("imported-notes-txt")
        defer { try? FileManager.default.removeItem(at: root) }
        let editionB = root.appendingPathComponent("EditionB", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: editionB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let notes = out.appendingPathComponent("Same - Ann notes.txt")
        try Data("NOT-AN-M4B".utf8).write(to: notes)
        try TestSupport.writePathOnlyOutputSidecar(notes, in: editionB)

        let book = TestSupport.dummyBook(folder: editionB.path, title: "Same", author: "Ann")
        let settings = ExportSettings(outputDirectory: out, writeNextToBook: false)
        XCTAssertFalse(settings.owns(notes, for: book))
        let plan = settings.plannedOutputs(for: [book])
        XCTAssertNotEqual(plan[book.id]?.standardizedFileURL.path, notes.standardizedFileURL.path)
        XCTAssertEqual(plan[book.id]?.pathExtension.lowercased(), "m4b")
    }

    func testImportedSidecarOtherEditionM4BIsNotOwned() throws {
        let root = try TestSupport.tempDir("imported-other-edition")
        defer { try? FileManager.default.removeItem(at: root) }
        let editionA = root.appendingPathComponent("EditionA", isDirectory: true)
        let editionB = root.appendingPathComponent("EditionB", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: editionA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: editionB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let destA = out.appendingPathComponent("Same - Ann.m4b")
        try Data("SENTINEL-A".utf8).write(to: destA)
        try TestSupport.writePathOnlyOutputSidecar(destA, in: editionB)

        let bookB = TestSupport.dummyBook(folder: editionB.path, title: "Same", author: "Ann")
        let settings = ExportSettings(outputDirectory: out, writeNextToBook: false)
        XCTAssertFalse(settings.owns(destA, for: bookB))
        let plan = settings.plannedOutputs(for: [bookB])
        XCTAssertNotEqual(plan[bookB.id]?.standardizedFileURL.path, destA.standardizedFileURL.path)
        XCTAssertEqual(plan[bookB.id]?.pathExtension.lowercased(), "m4b")
    }

    func testCopiedStaleAssociationDoesNotClaimSourceDest() throws {
        let root = try TestSupport.tempDir("copied-stale-assoc")
        defer { try? FileManager.default.removeItem(at: root) }
        let editionA = root.appendingPathComponent("EditionA", isDirectory: true)
        let editionB = root.appendingPathComponent("EditionB", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: editionA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: editionB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let destA = out.appendingPathComponent("Same - Ann.m4b")
        try Data("SENTINEL-A".utf8).write(to: destA)
        OutputAssociation.record(destA, inBookFolder: editionA)
        try FileManager.default.copyItem(
            at: editionA.appendingPathComponent(OutputAssociation.fileName),
            to: editionB.appendingPathComponent(OutputAssociation.fileName)
        )

        let bookB = TestSupport.dummyBook(folder: editionB.path, title: "Same", author: "Ann")
        let settings = ExportSettings(outputDirectory: out, writeNextToBook: false)
        XCTAssertFalse(settings.owns(destA, for: bookB))
        let copied = settings.plannedOutputs(for: [bookB])
        XCTAssertNotEqual(copied[bookB.id]?.standardizedFileURL.path, destA.standardizedFileURL.path)

        try TestSupport.writePathOnlyOutputSidecar(destA, in: editionB)
        XCTAssertFalse(settings.owns(destA, for: bookB))
        let pathOnly = settings.plannedOutputs(for: [bookB])
        XCTAssertNotEqual(pathOnly[bookB.id]?.standardizedFileURL.path, destA.standardizedFileURL.path)
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

    func testOutputAssociationRejectsOversizedSidecar() throws {
        let root = try TestSupport.tempDir("output-sidecar-oversize")
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("book.m4b")
        try Data("M4B".utf8).write(to: dest)
        try writePaddedSidecar(
            at: root.appendingPathComponent(OutputAssociation.fileName),
            padBytes: 2 * 1024 * 1024,
            suffix: dest.path
        )

        XCTAssertNil(OutputAssociation.load(inBookFolder: root))
        XCTAssertNil(OutputAssociation.destinationHint(inBookFolder: root))
    }

    func testOutputAssociationRejectsOverlongDestinationPath() throws {
        let root = try TestSupport.tempDir("output-sidecar-long-path")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "/" + String(repeating: "a", count: OutputAssociation.maxPathLength) + ".m4b"
        XCTAssertGreaterThan(path.count, OutputAssociation.maxPathLength)
        let json = Data("{\"destination\":\"\(path)\"}".utf8)
        XCTAssertLessThanOrEqual(json.count, OutputAssociation.maxSidecarBytes)
        try json.write(to: root.appendingPathComponent(OutputAssociation.fileName))

        XCTAssertNil(OutputAssociation.load(inBookFolder: root))
        XCTAssertNil(OutputAssociation.destinationHint(inBookFolder: root))
    }

    func testSourceAssociationRejectsOversizedSidecar() throws {
        let root = try TestSupport.tempDir("source-sidecar-oversize")
        defer { try? FileManager.default.removeItem(at: root) }
        try writePaddedSidecar(
            at: SourceAssociation.sidecarURL(inBookFolder: root),
            padBytes: SourceAssociation.maxSidecarBytes + 1,
            suffix: "{\"sources\":[]}"
        )

        XCTAssertNil(SourceAssociation.load(inBookFolder: root))
        XCTAssertNil(SourceAssociation.loadDocument(inBookFolder: root))
    }

    func testSourceAssociationRejectsTooManyEntries() throws {
        let root = try TestSupport.tempDir("source-sidecar-too-many")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSourceSidecar(in: root, entryCount: SourceAssociation.maxSourceEntries + 1)

        XCTAssertNil(SourceAssociation.load(inBookFolder: root))
        XCTAssertNil(SourceAssociation.loadDocument(inBookFolder: root))
    }

    func testSourceAssociationAcceptsMaxSourceEntries() throws {
        let root = try TestSupport.tempDir("source-sidecar-max-entries")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSourceSidecar(in: root, entryCount: SourceAssociation.maxSourceEntries)

        let loaded = try XCTUnwrap(SourceAssociation.load(inBookFolder: root))
        XCTAssertEqual(loaded.count, SourceAssociation.maxSourceEntries)
        XCTAssertEqual(loaded.first?.path, "/t/0")
        XCTAssertEqual(loaded.last?.path, "/t/\(SourceAssociation.maxSourceEntries - 1)")
    }

    func testSourceAssociationRejectsOverlongSourcePath() throws {
        let root = try TestSupport.tempDir("source-sidecar-long-path")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = String(repeating: "x", count: SourceAssociation.maxPathLength + 1)
        let json = Data(
            "{\"sources\":[{\"path\":\"\(path)\",\"isRegularFile\":true,\"fileSize\":1}]}".utf8
        )
        XCTAssertLessThanOrEqual(json.count, SourceAssociation.maxSidecarBytes)
        try json.write(to: SourceAssociation.sidecarURL(inBookFolder: root))

        XCTAssertNil(SourceAssociation.load(inBookFolder: root))
        XCTAssertNil(SourceAssociation.loadDocument(inBookFolder: root))
    }

    func testSourceAssociationRecordRejectsOversizedPrettyPrintedDocument() throws {
        let root = try TestSupport.tempDir("source-record-700")
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("out.m4b")
        let entries = syntheticCapturedEntries(count: 700)
        let destIdentity = syntheticDestIdentity()
        let destDigest = String(repeating: "ab", count: 32)
        let encoded = try prettyPrintedProvenance(
            entries: entries,
            dest: dest,
            destIdentity: destIdentity,
            destDigest: destDigest
        )
        XCTAssertGreaterThan(encoded.count, SourceAssociation.maxSidecarBytes)
        XCTAssertLessThan(entries.count, SourceAssociation.maxSourceEntries)

        let recorded = SourceAssociation.record(
            captured: entries,
            dest: dest,
            destIdentity: destIdentity,
            destinationSHA256: destDigest,
            inBookFolder: root
        )
        XCTAssertFalse(recorded, "writer must not claim success for a sidecar the reader rejects")
        XCTAssertNil(SourceAssociation.loadDocument(inBookFolder: root))
        XCTAssertNil(SourceAssociation.load(inBookFolder: root))
        assertNoSuccessfulUnreadableSidecar(in: root, recorded: recorded)
    }

    func testSourceAssociationRecordRoundTripMatchesLoadedDocument() throws {
        let root = try TestSupport.tempDir("source-record-roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("out.m4b")
        let sourceA = root.appendingPathComponent("01.mp3")
        let sourceB = root.appendingPathComponent("02.mp3")
        try Data("dest-bytes".utf8).write(to: dest)
        try Data("aaa".utf8).write(to: sourceA)
        try Data("bbb".utf8).write(to: sourceB)

        XCTAssertTrue(SourceAssociation.record([sourceA, sourceB], dest: dest, inBookFolder: root))
        let sidecar = SourceAssociation.sidecarURL(inBookFolder: root)
        let bytes = try Data(contentsOf: sidecar)
        XCTAssertGreaterThan(bytes.count, 0)
        XCTAssertLessThanOrEqual(bytes.count, SourceAssociation.maxSidecarBytes)

        let document = try XCTUnwrap(SourceAssociation.loadDocument(inBookFolder: root))
        XCTAssertEqual(document.sources.map(\.path), ["01.mp3", "02.mp3"])
        XCTAssertEqual(
            document.sources.map { $0.url(relativeTo: root).standardizedFileURL.path },
            [sourceA, sourceB].map { $0.standardizedFileURL.path }
        )
        XCTAssertEqual(document.sources.map(\.sha256), [
            SourceAssociation.sha256Hex(of: sourceA),
            SourceAssociation.sha256Hex(of: sourceB)
        ])
        XCTAssertEqual(document.destinationSHA256, SourceAssociation.sha256Hex(of: dest))
    }

    func testSourceAssociationRecordReloadsSupportedPrettyPrintedDocument() throws {
        let root = try TestSupport.tempDir("source-record-small-pretty")
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("out.m4b")
        let source = root.appendingPathComponent("01.mp3")
        try Data("dest".utf8).write(to: dest)
        try Data("src".utf8).write(to: source)
        let destIdentity = try XCTUnwrap(FileIdentity.read(from: dest))
        let destDigest = try XCTUnwrap(SourceAssociation.sha256Hex(of: dest))
        let captured = try SourceAssociation.capture([source], dest: dest)

        XCTAssertTrue(
            SourceAssociation.record(
                captured: captured,
                dest: dest,
                destIdentity: destIdentity,
                destinationSHA256: destDigest,
                inBookFolder: root
            )
        )
        let sidecar = SourceAssociation.sidecarURL(inBookFolder: root)
        let bytes = try Data(contentsOf: sidecar)
        XCTAssertGreaterThan(bytes.count, 0)
        XCTAssertLessThanOrEqual(bytes.count, SourceAssociation.maxSidecarBytes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNotNil(object["destinationIdentity"])
        XCTAssertNotNil(object["destinationSHA256"])

        let loaded = try XCTUnwrap(SourceAssociation.loadDocument(inBookFolder: root))
        XCTAssertEqual(loaded.sources.map(\.path), ["01.mp3"])
        XCTAssertEqual(
            loaded.sources.map { $0.url(relativeTo: root).standardizedFileURL.path },
            captured.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
        )
        XCTAssertEqual(loaded.sources.map(\.sha256), captured.map(\.sha256))
        XCTAssertEqual(loaded.destinationSHA256, destDigest)
    }

    func testSourceAssociationRecordsInBookSourcesAsRelativePaths() throws {
        let folder = try TestSupport.tempDir("source-rel-inside")
        defer { try? FileManager.default.removeItem(at: folder) }
        let nested = folder.appendingPathComponent("mp3", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let source = nested.appendingPathComponent("01.mp3")
        try Data("chapter".utf8).write(to: source)
        let dest = folder.appendingPathComponent("book.m4b")
        try Data("dest".utf8).write(to: dest)

        XCTAssertTrue(SourceAssociation.record([source], dest: dest, inBookFolder: folder))
        let loaded = try XCTUnwrap(SourceAssociation.load(inBookFolder: folder))
        XCTAssertEqual(loaded.map(\.path), ["mp3/01.mp3"])
        XCTAssertFalse(loaded[0].path.hasPrefix("/"))
        XCTAssertFalse(loaded[0].path.split(separator: "/").contains(".."))
        XCTAssertEqual(
            loaded[0].url(relativeTo: folder).standardizedFileURL.path,
            source.standardizedFileURL.path
        )
    }

    func testSourceAssociationRelativePathsSurviveBookFolderRename() throws {
        let parent = try TestSupport.tempDir("source-rel-move-parent")
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appendingPathComponent("Book", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let nested = folder.appendingPathComponent("mp3", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let source = nested.appendingPathComponent("01.mp3")
        try Data("chapter".utf8).write(to: source)
        let dest = folder.appendingPathComponent("book.m4b")
        try Data("dest".utf8).write(to: dest)

        XCTAssertTrue(SourceAssociation.record([source], dest: dest, inBookFolder: folder))
        let recorded = try XCTUnwrap(SourceAssociation.load(inBookFolder: folder))
        XCTAssertEqual(recorded.map(\.path), ["mp3/01.mp3"])

        let moved = parent.appendingPathComponent("Book Renamed", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: moved)
        let movedSource = moved.appendingPathComponent("mp3/01.mp3")
        let movedDest = moved.appendingPathComponent("book.m4b")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedSource.path))

        let loaded = try XCTUnwrap(SourceAssociation.load(inBookFolder: moved))
        XCTAssertEqual(loaded.map(\.path), ["mp3/01.mp3"])
        XCTAssertEqual(
            loaded[0].url(relativeTo: moved).standardizedFileURL.path,
            movedSource.standardizedFileURL.path
        )

        var book = TestSupport.dummyBook(
            folder: moved.path,
            chapters: [TestSupport.dummyChapter(index: 1, url: movedSource)]
        )
        book.existingM4BURL = movedDest
        let files = M4BInspector.sourceFilesToRemove(from: book)
        XCTAssertEqual(
            files.map(\.standardizedFileURL.path),
            [movedSource.standardizedFileURL.path]
        )
    }

    func testSourceAssociationKeepsExternalSourceAbsolute() throws {
        let root = try TestSupport.tempDir("source-rel-external")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Book", isDirectory: true)
        let outside = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let source = outside.appendingPathComponent("ch.mp3")
        try Data("out".utf8).write(to: source)
        let dest = folder.appendingPathComponent("book.m4b")
        try Data("dest".utf8).write(to: dest)

        XCTAssertTrue(SourceAssociation.record([source], dest: dest, inBookFolder: folder))
        let loaded = try XCTUnwrap(SourceAssociation.load(inBookFolder: folder))
        XCTAssertEqual(loaded.map(\.path), [source.standardizedFileURL.path])
        XCTAssertTrue(loaded[0].path.hasPrefix("/"))
        XCTAssertEqual(
            loaded[0].url(relativeTo: folder).standardizedFileURL.path,
            source.standardizedFileURL.path
        )
    }

    func testSourceAssociationAbsoluteSidecarResolvesWhenFolderUnmoved() throws {
        let folder = try TestSupport.tempDir("source-abs-legacy")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("01.mp3")
        try Data("ch".utf8).write(to: source)
        let dest = folder.appendingPathComponent("book.m4b")
        try Data("dest".utf8).write(to: dest)
        let destIdentity = try XCTUnwrap(FileIdentity.read(from: dest))
        let destDigest = try XCTUnwrap(SourceAssociation.sha256Hex(of: dest))
        let captured = try SourceAssociation.capture([source], dest: dest)
        XCTAssertTrue(captured[0].path.hasPrefix("/"))
        XCTAssertEqual(captured[0].path, source.standardizedFileURL.path)

        let data = try prettyPrintedProvenance(
            entries: captured,
            dest: dest,
            destIdentity: destIdentity,
            destDigest: destDigest
        )
        try data.write(to: SourceAssociation.sidecarURL(inBookFolder: folder))

        let loaded = try XCTUnwrap(SourceAssociation.load(inBookFolder: folder))
        XCTAssertEqual(loaded[0].path, source.standardizedFileURL.path)
        XCTAssertTrue(loaded[0].path.hasPrefix("/"))
        XCTAssertEqual(
            loaded[0].url(relativeTo: folder).standardizedFileURL.path,
            source.standardizedFileURL.path
        )

        var book = TestSupport.dummyBook(
            folder: folder.path,
            chapters: [TestSupport.dummyChapter(index: 1, url: source)]
        )
        book.existingM4BURL = dest
        XCTAssertEqual(
            M4BInspector.sourceFilesToRemove(from: book).map(\.standardizedFileURL.path),
            [source.standardizedFileURL.path]
        )
    }

    func testSourceAssociationRecordRejectsOverlongCapturedPath() throws {
        let root = try TestSupport.tempDir("source-record-long-path")
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("out.m4b")
        let path = String(repeating: "x", count: SourceAssociation.maxPathLength + 1)
        XCTAssertGreaterThan(path.count, SourceAssociation.maxPathLength)
        let entries = [
            SourceAssociation.Entry(
                path: path,
                isRegularFile: true,
                fileSize: 1,
                modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                fileResourceIdentifier: Data([1]),
                sha256: String(repeating: "ab", count: 32)
            )
        ]

        let recorded = SourceAssociation.record(
            captured: entries,
            dest: dest,
            destIdentity: syntheticDestIdentity(),
            destinationSHA256: String(repeating: "cd", count: 32),
            inBookFolder: root
        )
        XCTAssertFalse(recorded)
        XCTAssertNil(SourceAssociation.loadDocument(inBookFolder: root))
        XCTAssertNil(SourceAssociation.load(inBookFolder: root))
        assertNoSuccessfulUnreadableSidecar(in: root, recorded: recorded)
    }

    func testSourceAssociationRecordRejectsTooManyCapturedEntries() throws {
        let root = try TestSupport.tempDir("source-record-too-many")
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("out.m4b")
        let entries = syntheticCapturedEntries(
            count: SourceAssociation.maxSourceEntries + 1,
            resourceBytes: 1
        )
        XCTAssertEqual(entries.count, SourceAssociation.maxSourceEntries + 1)

        let recorded = SourceAssociation.record(
            captured: entries,
            dest: dest,
            destIdentity: syntheticDestIdentity(),
            destinationSHA256: String(repeating: "ef", count: 32),
            inBookFolder: root
        )
        XCTAssertFalse(recorded)
        XCTAssertNil(SourceAssociation.loadDocument(inBookFolder: root))
        XCTAssertNil(SourceAssociation.load(inBookFolder: root))
        assertNoSuccessfulUnreadableSidecar(in: root, recorded: recorded)
    }

    func testSourceAssociationCaptureRejectsOversizedProvenanceBeforeEncode() throws {
        let root = try TestSupport.tempDir("source-capture-700")
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("out.m4b")
        let entries = syntheticCapturedEntries(count: 700)
        let encoded = try prettyPrintedProvenance(
            entries: entries,
            dest: dest,
            destIdentity: syntheticDestIdentity(),
            destDigest: String(repeating: "0", count: 64)
        )
        XCTAssertGreaterThan(encoded.count, SourceAssociation.maxSidecarBytes)

        XCTAssertThrowsError(try SourceAssociation.validateForExport(captured: entries, dest: dest)) { error in
            guard case BinderError.exportFailed = error else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertNil(SourceAssociation.loadDocument(inBookFolder: root))
    }

    func testSourceAssociationCaptureRejectsOverlongPath() throws {
        let root = try TestSupport.tempDir("source-capture-long-path")
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("out.m4b")
        let url = URL(
            fileURLWithPath: "/" + String(repeating: "x", count: SourceAssociation.maxPathLength + 1) + "/ch.mp3"
        )
        XCTAssertGreaterThan(url.path.count, SourceAssociation.maxPathLength)

        XCTAssertThrowsError(try SourceAssociation.capture([url], dest: dest)) { error in
            guard case let BinderError.exportFailed(message) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("path")
                    || message.localizedCaseInsensitiveContains("exceed"),
                message
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertNil(SourceAssociation.loadDocument(inBookFolder: root))
    }

    func testSourceAssociationCaptureRejectsTooManyEntries() throws {
        let root = try TestSupport.tempDir("source-capture-too-many")
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("out.m4b")
        let urls = (0...SourceAssociation.maxSourceEntries).map {
            root.appendingPathComponent("ch\($0).mp3")
        }
        XCTAssertEqual(urls.count, SourceAssociation.maxSourceEntries + 1)

        XCTAssertThrowsError(try SourceAssociation.capture(urls, dest: dest)) { error in
            guard case let BinderError.exportFailed(message) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("many")
                    || message.localizedCaseInsensitiveContains("entries")
                    || message.localizedCaseInsensitiveContains("limit"),
                message
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertNil(SourceAssociation.loadDocument(inBookFolder: root))
    }

    func testScanGenerationNewestWins() {
        var generation = ScanGeneration()
        let a = generation.begin()
        let b = generation.begin()
        XCTAssertFalse(generation.isCurrent(a))
        XCTAssertTrue(generation.isCurrent(b))
    }

    func testOutputAssociationRecordFailsWhenLeftoverAuthorityIsNotNewDest() throws {
        try withIsolatedAuthorityStore { store in
            let root = try TestSupport.tempDir("oa-record-leftover-dest")
            defer { try? FileManager.default.removeItem(at: root) }
            let destA = root.appendingPathComponent("bookA.m4b")
            let destB = root.appendingPathComponent("bookB.m4b")
            try Data("M4B-A".utf8).write(to: destA)
            try Data("M4B-B".utf8).write(to: destB)

            XCTAssertTrue(OutputAssociation.record(destA, inBookFolder: root))
            XCTAssertEqual(
                OutputAssociation.load(inBookFolder: root)?.standardizedFileURL.path,
                destA.standardizedFileURL.path
            )

            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.path)
            }

            XCTAssertFalse(
                OutputAssociation.record(destB, inBookFolder: root),
                "leftover dest A must not count as a successful record of dest B"
            )
            if let loaded = OutputAssociation.load(inBookFolder: root) {
                XCTAssertFalse(
                    M4BExporter.isSameFileURL(loaded, destB),
                    "load must not report dest B after a failed record"
                )
            }
        }
    }

    private func writeOutputSidecar(_ dest: URL, in folder: URL) throws {
        OutputAssociation.record(dest, inBookFolder: folder)
        let sidecar = folder.appendingPathComponent(OutputAssociation.fileName)
        guard FileManager.default.fileExists(atPath: sidecar.path) else {
            throw BinderError.exportFailed("Could not write output association sidecar")
        }
    }

    private func writePaddedSidecar(at url: URL, padBytes: Int, suffix: String) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        let chunk = Data(repeating: UInt8(ascii: " "), count: min(65_536, padBytes))
        var remaining = padBytes
        while remaining > 0 {
            let n = min(remaining, chunk.count)
            try handle.write(contentsOf: chunk.prefix(n))
            remaining -= n
        }
        try handle.write(contentsOf: Data(suffix.utf8))
        try handle.close()
    }

    private func writeSourceSidecar(in folder: URL, entryCount: Int) throws {
        let entries: [[String: Any]] = (0..<entryCount).map { index in
            [
                "path": "/t/\(index)",
                "isRegularFile": true,
                "fileSize": 1
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["sources": entries])
        XCTAssertLessThanOrEqual(data.count, SourceAssociation.maxSidecarBytes)
        try data.write(to: SourceAssociation.sidecarURL(inBookFolder: folder))
    }

    private func syntheticCapturedEntries(
        count: Int,
        resourceBytes: Int = 160
    ) -> [SourceAssociation.Entry] {
        (0..<count).map { index in
            SourceAssociation.Entry(
                path: "/Users/shared/Audiobooks/Synthetic Provenance Book/CD1/chapter-\(String(format: "%04d", index))-full-title.mp3",
                isRegularFile: true,
                fileSize: Int64(index + 1),
                modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                fileResourceIdentifier: Data(
                    repeating: UInt8(truncatingIfNeeded: index),
                    count: resourceBytes
                ),
                sha256: String(repeating: String(format: "%02x", index % 256), count: 32)
            )
        }
    }

    private func syntheticDestIdentity() -> FileIdentity {
        FileIdentity(
            fileSize: 12,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            fileResourceIdentifier: Data(repeating: 7, count: 160),
            isDirectory: false
        )
    }

    private func prettyPrintedProvenance(
        entries: [SourceAssociation.Entry],
        dest: URL,
        destIdentity: FileIdentity,
        destDigest: String
    ) throws -> Data {
        let document = SourceAssociation.Document(
            sources: entries,
            destination: dest.standardizedFileURL.path,
            destinationIdentity: destIdentity,
            destinationSHA256: destDigest
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(document)
    }

    private func assertNoSuccessfulUnreadableSidecar(
        in folder: URL,
        recorded: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sidecar = SourceAssociation.sidecarURL(inBookFolder: folder)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return }
        XCTAssertFalse(recorded, "leftover sidecar must not be a writer success", file: file, line: line)
        XCTAssertNil(
            SourceAssociation.loadDocument(inBookFolder: folder),
            "leftover sidecar must be unreadable",
            file: file,
            line: line
        )
        if let leftover = try? Data(contentsOf: sidecar) {
            XCTAssertTrue(
                leftover.count > SourceAssociation.maxSidecarBytes
                    || SourceAssociation.loadDocument(inBookFolder: folder) == nil,
                "leftover bytes must not be a loadable success record",
                file: file,
                line: line
            )
        }
    }

    private func withIsolatedAuthorityStore(_ body: (URL) throws -> Void) throws {
        let store = try TestSupport.tempDir("r6-01-authority")
        let previous = OutputAssociation.authorityDirectoryOverride
        OutputAssociation.authorityDirectoryOverride = store
        defer {
            OutputAssociation.authorityDirectoryOverride = previous
            try? FileManager.default.removeItem(at: store)
        }
        try body(store)
    }

    /// `CaseFoldProbe` vs `casefoldprobe` on the same parent: if they are the
    /// same object, the volume is case-insensitive.
    private func volumeIsCaseSensitive(at directory: URL) throws -> Bool {
        let probe = directory.appendingPathComponent("CaseFoldProbe", isDirectory: true)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probe) }
        let folded = directory.appendingPathComponent("casefoldprobe", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folded.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return true
        }
        let probeIdentity = try XCTUnwrap(FileIdentity.read(from: probe))
        let foldedIdentity = try XCTUnwrap(FileIdentity.read(from: folded))
        return !probeIdentity.matchesRecordedIdentity(foldedIdentity)
    }

    private struct CaseDistinctFixture {
        let root: URL
        let cleanup: () -> Void
    }

    private func caseDistinctFixtureRoot() throws -> CaseDistinctFixture {
        let native = try TestSupport.tempDir("r6-01-case-distinct")
        if try volumeIsCaseSensitive(at: native) {
            return CaseDistinctFixture(root: native) {
                try? FileManager.default.removeItem(at: native)
            }
        }
        try? FileManager.default.removeItem(at: native)
        return try attachCaseSensitiveVolume()
    }

    private func attachCaseSensitiveVolume() throws -> CaseDistinctFixture {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let volname = "m4bCS\(token.prefix(8))"
        let dmg = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4b-cs-\(token).dmg")
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4b-cs-mnt-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        func cleanupImage() {
            _ = try? runHDIUtil(["detach", mountPoint.path, "-force"])
            try? FileManager.default.removeItem(at: dmg)
            try? FileManager.default.removeItem(at: mountPoint)
        }

        do {
            let created = try runHDIUtil([
                "create",
                "-size", "16m",
                "-fs", "Case-sensitive APFS",
                "-volname", volname,
                "-ov",
                dmg.path
            ])
            if created.status != 0 {
                let retry = try runHDIUtil([
                    "create",
                    "-size", "16m",
                    "-fs", "APFSX",
                    "-volname", volname,
                    "-ov",
                    dmg.path
                ])
                guard retry.status == 0 else {
                    throw XCTSkip(
                        "Could not create a case-sensitive APFS disk image: \(created.output) \(retry.output)"
                    )
                }
            }
            let attached = try runHDIUtil([
                "attach",
                "-nobrowse",
                "-mountpoint", mountPoint.path,
                dmg.path
            ])
            guard attached.status == 0 else {
                throw XCTSkip(
                    "Could not attach a case-sensitive APFS disk image: \(attached.output)"
                )
            }
            guard try volumeIsCaseSensitive(at: mountPoint) else {
                throw XCTSkip("Attached disk image is not case-sensitive")
            }
        } catch {
            cleanupImage()
            throw error
        }

        return CaseDistinctFixture(root: mountPoint, cleanup: cleanupImage)
    }

    private func runHDIUtil(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }
}

final class BoundedFileReadTests: XCTestCase {
    func testRejectsFIFOPromptly() throws {
        let root = try TestSupport.tempDir("bounded-fifo")
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent(OutputAssociation.fileName)
        try makeFIFO(at: fifo)
        try makeFIFO(at: SourceAssociation.sidecarURL(inBookFolder: root))

        assertNilPromptly("fifo-read") {
            BoundedFileRead.read(from: fifo, maxBytes: 64)
        }
        assertNilPromptly("fifo-output-load") {
            OutputAssociation.load(inBookFolder: root)
        }
        assertNilPromptly("fifo-output-hint") {
            OutputAssociation.destinationHint(inBookFolder: root)
        }
        assertNilPromptly("fifo-source-load") {
            SourceAssociation.loadDocument(inBookFolder: root)
        }
    }

    func testRejectsDirectoryPromptly() throws {
        let root = try TestSupport.tempDir("bounded-dir")
        defer { try? FileManager.default.removeItem(at: root) }
        let sidecar = root.appendingPathComponent(OutputAssociation.fileName)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)

        assertNilPromptly("dir-read") {
            BoundedFileRead.read(from: sidecar, maxBytes: 64)
        }
        assertNilPromptly("dir-hint") {
            OutputAssociation.destinationHint(inBookFolder: root)
        }
    }

    func testRejectsSymlinkToRegularSidecarWithoutFollowing() throws {
        let root = try TestSupport.tempDir("bounded-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("book.m4b")
        try Data("M4B".utf8).write(to: dest)
        let real = root.appendingPathComponent("real-sidecar")
        try dest.standardizedFileURL.path.write(to: real, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent(OutputAssociation.fileName)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        assertNilPromptly("symlink-read") {
            BoundedFileRead.read(from: link, maxBytes: 256)
        }
        assertNilPromptly("symlink-hint") {
            OutputAssociation.destinationHint(inBookFolder: root)
        }
    }

    func testRejectsSymlinkToFIFOPromptly() throws {
        let root = try TestSupport.tempDir("bounded-symlink-fifo")
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("no-writer.fifo")
        try makeFIFO(at: fifo)
        let link = root.appendingPathComponent(OutputAssociation.fileName)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fifo)

        assertNilPromptly("symlink-fifo-read") {
            BoundedFileRead.read(from: link, maxBytes: 64)
        }
    }

    func testRejectsCharacterDevicePromptly() throws {
        let device = URL(fileURLWithPath: "/dev/null")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: device.path), "/dev/null missing")
        assertNilPromptly("dev-null") {
            BoundedFileRead.read(from: device, maxBytes: 16)
        }
    }

    func testEmptyMissingAndSizeLimits() throws {
        let root = try TestSupport.tempDir("bounded-limits")
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(BoundedFileRead.read(from: root.appendingPathComponent("missing"), maxBytes: 16))

        let empty = root.appendingPathComponent("empty")
        try Data().write(to: empty)
        XCTAssertNil(BoundedFileRead.read(from: empty, maxBytes: 16))

        let exact = Data(repeating: 0x61, count: 16)
        let exactURL = root.appendingPathComponent("exact")
        try exact.write(to: exactURL)
        XCTAssertEqual(BoundedFileRead.read(from: exactURL, maxBytes: 16), exact)
        XCTAssertNil(BoundedFileRead.read(from: exactURL, maxBytes: 15))

        let over = Data(repeating: 0x62, count: 17)
        let overURL = root.appendingPathComponent("over")
        try over.write(to: overURL)
        XCTAssertNil(BoundedFileRead.read(from: overURL, maxBytes: 16))
        XCTAssertEqual(BoundedFileRead.read(from: overURL, maxBytes: 17), over)
    }

    func testMalformedJSONLoadReturnsNil() throws {
        let root = try TestSupport.tempDir("bounded-bad-json")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not-json".utf8).write(to: root.appendingPathComponent(OutputAssociation.fileName))
        try Data("not-json".utf8).write(to: SourceAssociation.sidecarURL(inBookFolder: root))

        XCTAssertNil(OutputAssociation.load(inBookFolder: root))
        XCTAssertNil(OutputAssociation.destinationHint(inBookFolder: root))
        XCTAssertNil(SourceAssociation.loadDocument(inBookFolder: root))
    }

    func testOutputAssociationRecordStillLoads() throws {
        let root = try TestSupport.tempDir("bounded-record")
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("book.m4b")
        try Data("M4B".utf8).write(to: dest)
        XCTAssertTrue(OutputAssociation.record(dest, inBookFolder: root))

        XCTAssertEqual(
            OutputAssociation.load(inBookFolder: root)?.standardizedFileURL.path,
            dest.standardizedFileURL.path
        )
        XCTAssertEqual(
            OutputAssociation.destinationHint(inBookFolder: root)?.standardizedFileURL.path,
            dest.standardizedFileURL.path
        )
    }

    func testOutputAssociationRecordFailsWhenAuthorityUnwritable() throws {
        let root = try TestSupport.tempDir("oa-record-unwritable")
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("book.m4b")
        try Data("M4B".utf8).write(to: dest)
        let sidecar = root.appendingPathComponent(OutputAssociation.fileName)
        try Data("stale-output-record".utf8).write(to: sidecar)

        let parent = try TestSupport.tempDir("oa-record-block-parent")
        defer { try? FileManager.default.removeItem(at: parent) }
        let blocker = parent.appendingPathComponent("store")
        try Data("not-a-directory".utf8).write(to: blocker)

        let previous = OutputAssociation.authorityDirectoryOverride
        OutputAssociation.authorityDirectoryOverride = blocker
        defer { OutputAssociation.authorityDirectoryOverride = previous }

        XCTAssertFalse(OutputAssociation.record(dest, inBookFolder: root))
        XCTAssertNil(OutputAssociation.load(inBookFolder: root))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sidecar.path),
            "sidecar must be invalidated when authority cannot persist"
        )
    }

    private func assertNilPromptly<T>(
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        work: @escaping @Sendable () -> T?
    ) {
        let finished = expectation(description: name)
        let box = PromptBox<T>()
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = work()
            box.didFinish = true
            finished.fulfill()
        }
        let outcome = XCTWaiter().wait(for: [finished], timeout: 1.0)
        XCTAssertEqual(outcome, .completed, "\(name) did not return within 1s", file: file, line: line)
        XCTAssertTrue(box.didFinish, "\(name) did not finish", file: file, line: line)
        XCTAssertNil(box.value, file: file, line: line)
    }

    private func makeFIFO(at url: URL) throws {
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return mkfifo(path, S_IRUSR | S_IWUSR)
        }
        guard status == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
    }
}

private final class PromptBox<T>: @unchecked Sendable {
    var value: T?
    var didFinish = false
}
