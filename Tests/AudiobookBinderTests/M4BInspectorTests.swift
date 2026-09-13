import XCTest
@testable import AudiobookBinderCore

final class M4BInspectorTests: XCTestCase {
    func testCompareDurationsMatchAndMismatch() {
        let match = M4BInspector.compareDurations(source: 100, bound: 100.4)
        XCTAssertTrue(match.durationsMatch)
        if case .match(let source, let bound) = match {
            XCTAssertEqual(source, 100)
            XCTAssertEqual(bound, 100.4)
        } else {
            XCTFail("expected match")
        }

        let close = M4BInspector.compareDurations(source: 10_000, bound: 10_050)
        XCTAssertTrue(close.durationsMatch, "1% slack on long books")

        let mismatch = M4BInspector.compareDurations(source: 100, bound: 130)
        XCTAssertFalse(mismatch.durationsMatch)
        if case .mismatch(let source, let bound) = mismatch {
            XCTAssertEqual(source, 100)
            XCTAssertEqual(bound, 130)
        } else {
            XCTFail("expected mismatch")
        }

        XCTAssertEqual(M4BInspector.compareDurations(source: 0, bound: 10), .noSource)
        XCTAssertEqual(M4BInspector.compareDurations(source: 10, bound: 0), .noBoundFile)
    }

    func testSourceFilesToRemoveSkipsM4BAndMissing() throws {
        let dir = try TestSupport.tempDir("cleanup")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp3a = dir.appendingPathComponent("01.mp3")
        let mp3b = dir.appendingPathComponent("02.mp3")
        let m4b = dir.appendingPathComponent("book.m4b")
        try Data(count: 10).write(to: mp3a)
        try Data(count: 10).write(to: mp3b)
        try Data(count: 10).write(to: m4b)
        let missing = dir.appendingPathComponent("gone.mp3")
        var book = TestSupport.dummyBook(
            folder: dir.path,
            chapters: [
                TestSupport.dummyChapter(index: 1, url: mp3a),
                TestSupport.dummyChapter(index: 2, url: mp3b),
                TestSupport.dummyChapter(index: 3, url: missing),
                TestSupport.dummyChapter(index: 4, url: m4b)
            ]
        )
        book.existingM4BURL = m4b
        let files = M4BInspector.sourceFilesToRemove(from: book)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["01.mp3", "02.mp3"])
        XCTAssertTrue(book.canCleanupSources)
        XCTAssertFalse(book.isAlreadyBound)
    }

    func testPlayableChaptersUseStartOffset() {
        let url = URL(fileURLWithPath: "/tmp/book.m4b")
        let inspection = M4BInspection(
            url: url,
            duration: 30,
            chapters: [
                ChapterMark(start: 0, duration: 10, title: "One"),
                ChapterMark(start: 10, duration: 20, title: "Two")
            ],
            fileSize: 99
        )
        let chapters = M4BInspector.playableChapters(from: inspection)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, "One")
        XCTAssertEqual(chapters[0].startOffset, 0)
        XCTAssertFalse(chapters[0].isEmbedded)
        XCTAssertEqual(chapters[1].startOffset, 10)
        XCTAssertTrue(chapters[1].isEmbedded)
        XCTAssertEqual(chapters[1].url, url)
    }

    func testInspectExportedM4B() async throws {
        let dir = try TestSupport.tempDir("inspect")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("silence.wav")
        try TestSupport.writeSilenceWAV(to: wav, seconds: 1)
        let info = AudioMetadata.fileInfo(of: wav)
        let chapter = Chapter(
            url: wav,
            index: 1,
            title: "Silence",
            duration: info.duration,
            fileSize: 1,
            audioInfo: info.audioInfo
        )
        let book = Audiobook(folder: dir, title: "Inspect Me", author: "A", chapters: [chapter])
        let dest = dir.appendingPathComponent("out.m4b")
        try await M4BExporter(bitrate: 48_000).export(book: book, to: dest, overwrite: true)
        let inspection = await M4BInspector.inspect(dest)
        XCTAssertGreaterThan(inspection.duration, 0.2)
        XCTAssertFalse(inspection.chapters.isEmpty)
        XCTAssertTrue(inspection.chapters.contains(where: { $0.title == "Silence" }))
        let comparison = M4BInspector.compareDurations(source: info.duration, bound: inspection.duration)
        XCTAssertTrue(comparison.durationsMatch)
    }
}
