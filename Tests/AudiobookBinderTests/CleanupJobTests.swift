import XCTest
@testable import AudiobookBinderCore

final class CleanupJobTests: XCTestCase {
    func testCommitSuccessDoesNotApplyToUnrelatedLibraryReplacement() throws {
        let bookA = try makeBoundBook(name: "BookA")
        let bookB = try makeBoundBook(name: "BookB")
        defer {
            bookA.tearDown()
            bookB.tearDown()
        }

        var owner = CleanupJobOwner()
        var books = [bookA.book]
        let job = owner.begin(bookID: bookA.book.id)
        XCTAssertNotNil(job)
        XCTAssertTrue(owner.isCleaningUp)

        let beforeB = bookB.book
        books = [bookB.book]
        owner.commitSuccess(&books, job: job!, inspection: bookA.inspection)

        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].id, beforeB.id)
        XCTAssertNotEqual(books[0].id, bookA.book.id)
        XCTAssertEqual(books[0].chapters, beforeB.chapters)
        XCTAssertEqual(books[0].existingM4BURL, beforeB.existingM4BURL)
        XCTAssertEqual(books[0].boundDuration, beforeB.boundDuration)
        XCTAssertEqual(books[0].selected, beforeB.selected)
    }

    func testCommitSuccessDoesNotTrapOnEmptyLibraryReplacement() throws {
        let bookA = try makeBoundBook(name: "EmptyRescanA")
        defer { bookA.tearDown() }

        var owner = CleanupJobOwner()
        var books = [bookA.book]
        let job = owner.begin(bookID: bookA.book.id)
        XCTAssertNotNil(job)

        books = []
        owner.commitSuccess(&books, job: job!, inspection: bookA.inspection)
        XCTAssertTrue(books.isEmpty)
    }

    func testCommitSuccessUpdatesOnlyMatchingBookAfterReorder() throws {
        let bookA = try makeBoundBook(name: "ReorderA")
        let bookB = try makeBoundBook(name: "ReorderB")
        defer {
            bookA.tearDown()
            bookB.tearDown()
        }

        var owner = CleanupJobOwner()
        var books = [bookA.book]
        let job = owner.begin(bookID: bookA.book.id)
        XCTAssertNotNil(job)

        let beforeB = bookB.book
        books = [bookB.book, bookA.book]
        owner.commitSuccess(&books, job: job!, inspection: bookA.inspection)

        XCTAssertEqual(books.map(\.id), [beforeB.id, bookA.book.id])
        XCTAssertEqual(books[0].chapters, beforeB.chapters)
        XCTAssertEqual(books[0].existingM4BURL, beforeB.existingM4BURL)
        XCTAssertEqual(books[0].boundDuration, beforeB.boundDuration)
        XCTAssertEqual(books[0].selected, beforeB.selected)

        XCTAssertTrue(books[1].chapters.isEmpty)
        XCTAssertEqual(books[1].existingM4BURL, bookA.inspection.url)
        XCTAssertEqual(books[1].boundDuration, bookA.inspection.duration)
        XCTAssertFalse(books[1].selected)
    }

    func testCommitPartialReconcilesSnapshotChaptersOnMatchingBookOnly() throws {
        let bookA = try makeBoundBook(name: "PartialA", chapterFiles: ["01.mp3", "02.mp3"])
        let bookB = try makeBoundBook(name: "PartialB")
        defer {
            bookA.tearDown()
            bookB.tearDown()
        }

        var owner = CleanupJobOwner()
        var books = [bookA.book]
        let job = owner.begin(bookID: bookA.book.id)
        XCTAssertNotNil(job)

        let beforeB = bookB.book
        let snapshot = bookA.book.chapters
        let moved = [bookA.chapterURLs[0]]
        books = [bookB.book, bookA.book]
        owner.commitPartial(
            &books,
            job: job!,
            inspection: bookA.inspection,
            snapshotChapters: snapshot,
            moved: moved
        )

        let expected = SourceCleanup.reconcile(chapters: snapshot, moved: moved)
        XCTAssertEqual(expected.map(\.url.lastPathComponent), ["02.mp3"])
        XCTAssertEqual(books[0].id, beforeB.id)
        XCTAssertEqual(books[0].chapters, beforeB.chapters)
        XCTAssertEqual(books[0].existingM4BURL, beforeB.existingM4BURL)
        XCTAssertEqual(books[0].boundDuration, beforeB.boundDuration)
        XCTAssertEqual(books[0].selected, beforeB.selected)

        XCTAssertEqual(books[1].id, bookA.book.id)
        XCTAssertEqual(books[1].chapters.map(\.url.lastPathComponent), ["02.mp3"])
        XCTAssertEqual(books[1].existingM4BURL, bookA.inspection.url)
        XCTAssertEqual(books[1].boundDuration, bookA.inspection.duration)
        XCTAssertTrue(books[1].selected)
    }

    func testStaleGenerationCommitDoesNotMutateBooks() throws {
        let bookA = try makeBoundBook(name: "StaleA")
        defer { bookA.tearDown() }

        var owner = CleanupJobOwner()
        var books = [bookA.book]
        let job = owner.begin(bookID: bookA.book.id)
        XCTAssertNotNil(job)
        owner.finish(job!)
        XCTAssertFalse(owner.isCleaningUp)

        owner.commitSuccess(&books, job: job!, inspection: bookA.inspection)

        XCTAssertEqual(books[0].chapters, bookA.book.chapters)
        XCTAssertEqual(books[0].existingM4BURL, bookA.book.existingM4BURL)
        XCTAssertEqual(books[0].boundDuration, bookA.book.boundDuration)
        XCTAssertEqual(books[0].selected, bookA.book.selected)
    }

    func testSecondBeginFailsAndFinishOnlyClearsMatchingJob() throws {
        let bookA = try makeBoundBook(name: "JobA")
        let bookB = try makeBoundBook(name: "JobB")
        defer {
            bookA.tearDown()
            bookB.tearDown()
        }

        var owner = CleanupJobOwner()
        let first = owner.begin(bookID: bookA.book.id)
        XCTAssertNotNil(first)
        XCTAssertTrue(owner.isCleaningUp)
        XCTAssertNil(owner.begin(bookID: bookA.book.id))
        XCTAssertNil(owner.begin(bookID: bookB.book.id))

        owner.finish(CleanupJob(bookID: bookB.book.id, generation: first!.generation))
        XCTAssertTrue(owner.isCleaningUp)

        owner.finish(first!)
        XCTAssertFalse(owner.isCleaningUp)
        XCTAssertNotNil(owner.begin(bookID: bookB.book.id))
    }

    func testControlsStateHidesWhileCleaningUp() {
        let sample = URL(fileURLWithPath: "/tmp/cleanup-job-a.mp3")
        let cached = SourceCleanupAuthorization(allowed: true, sources: [sample])
        XCTAssertEqual(
            SourceCleanup.controlsState(
                canCleanupSources: true,
                isBuilding: false,
                cached: cached,
                isCleaningUp: true
            ),
            .hidden
        )
    }

    private struct BoundBookFixture {
        var dir: URL
        var book: Audiobook
        var inspection: M4BInspection
        var chapterURLs: [URL]

        func tearDown() {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func makeBoundBook(
        name: String,
        chapterFiles: [String] = ["01.mp3"]
    ) throws -> BoundBookFixture {
        let dir = try TestSupport.tempDir("cleanup-job-\(name)")
        var chapterURLs: [URL] = []
        var chapters: [Chapter] = []
        for (offset, file) in chapterFiles.enumerated() {
            let url = try TestSupport.writeMP3(in: dir, book: name, file: file)
            chapterURLs.append(url)
            chapters.append(TestSupport.dummyChapter(index: offset + 1, url: url, duration: TimeInterval(offset + 2)))
        }
        let dest = dir.appendingPathComponent("\(name).m4b")
        try Data("m4b-\(name)".utf8).write(to: dest)
        var book = TestSupport.dummyBook(
            folder: dir.path,
            title: name,
            chapters: chapters,
            selected: true
        )
        book.existingM4BURL = dest
        book.boundDuration = 1
        let inspection = M4BInspection(
            url: dest,
            duration: 42,
            chapters: [],
            fileSize: 8,
            bookID: book.id
        )
        return BoundBookFixture(dir: dir, book: book, inspection: inspection, chapterURLs: chapterURLs)
    }
}
