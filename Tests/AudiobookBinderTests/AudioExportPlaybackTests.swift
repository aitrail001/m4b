import AVFoundation
import XCTest
@testable import AudiobookBinderCore

final class AudioExportPlaybackTests: XCTestCase {
    func testStreamDescriptionDurationAndTagsOnTink() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: TestSupport.tink.path), "Tink.aiff missing")
        let asbd = AudioMetadata.streamDescription(of: TestSupport.tink)
        XCTAssertNotNil(asbd)
        XCTAssertGreaterThan(asbd?.mSampleRate ?? 0, 0)
        XCTAssertGreaterThan(Int(asbd?.mChannelsPerFrame ?? 0), 0)
        let info = AudioMetadata.fileInfo(of: TestSupport.tink)
        XCTAssertGreaterThan(info.duration, 0)
        XCTAssertEqual(AudioMetadata.duration(of: TestSupport.tink), info.duration)
        let tags = await AudioMetadata.loadTags(from: TestSupport.tink, includeArtwork: false)
        XCTAssertGreaterThan(tags.duration, 0)
        XCTAssertGreaterThan(tags.sampleRate, 0)
    }

    func testExportOverwriteAndMissingChapters() async throws {
        let dir = try TestSupport.tempDir("export")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSilence(in: dir)
        let dest = dir.appendingPathComponent("out.m4b")
        let info = AudioMetadata.fileInfo(of: source)
        let chapter = Chapter(
            url: source,
            index: 1,
            title: "Tink",
            duration: info.duration,
            fileSize: 1,
            audioInfo: info.audioInfo
        )
        let book = Audiobook(
            folder: dir,
            title: "Tink Book",
            author: "System",
            chapters: [chapter]
        )
        let exporter = M4BExporter(bitrate: 48_000)
        try await exporter.export(book: book, to: dest, overwrite: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        let size = try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(size, 1_000)

        do {
            try await exporter.export(book: book, to: dest, overwrite: false)
            XCTFail("expected outputExists")
        } catch let error as BinderError {
            guard case .outputExists = error else { return XCTFail("\(error)") }
        }

        try await exporter.export(book: book, to: dest, overwrite: true)

        var missing = chapter
        missing.url = dir.appendingPathComponent("gone.aiff")
        let empty = Audiobook(folder: dir, title: "Empty", author: "A", chapters: [missing])
        do {
            try await exporter.export(book: empty, to: dir.appendingPathComponent("empty.m4b"), overwrite: true)
            XCTFail("expected noAudioFiles")
        } catch let error as BinderError {
            guard case .noAudioFiles = error else { return XCTFail("\(error)") }
        }
    }

    func testExportAllSkipsUnselectedAndExcludedChapters() async throws {
        let dir = try TestSupport.tempDir("export-all")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSilence(in: dir)
        let info = AudioMetadata.fileInfo(of: source)
        func chapter(_ included: Bool) -> Chapter {
            var c = Chapter(
                url: source,
                index: included ? 1 : 2,
                title: included ? "Keep" : "Skip",
                duration: info.duration,
                fileSize: 1,
                audioInfo: info.audioInfo
            )
            c.included = included
            return c
        }
        let selected = Audiobook(
            folder: dir,
            title: "KeepMe",
            author: "A",
            chapters: [chapter(true), chapter(false)],
            selected: true
        )
        let ignored = Audiobook(
            folder: dir,
            title: "IgnoreMe",
            author: "A",
            chapters: [chapter(true)],
            selected: false
        )
        let settings = ExportSettings(outputDirectory: dir, overwrite: true, writeNextToBook: false)
        let urls = try await M4BExporter(bitrate: 48_000).exportAll(
            books: [ignored, selected],
            settings: settings
        )
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls[0].lastPathComponent, selected.suggestedFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path))

        let existsSettings = ExportSettings(outputDirectory: dir, overwrite: false, writeNextToBook: false)
        let again = try await M4BExporter(bitrate: 48_000).exportAll(books: [selected], settings: existsSettings)
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(again[0].lastPathComponent, selected.suggestedFileName)
    }

    func testChaptersReadyForExport() {
        let keep = TestSupport.dummyChapter(index: 1, included: true)
        var drop = TestSupport.dummyChapter(index: 2, included: false)
        drop.included = false
        XCTAssertEqual(M4BExporter.chaptersReadyForExport([keep, drop]).map(\.index), [1])
    }

    @MainActor
    func testChapterPlaybackStartPauseStopMissing() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: TestSupport.tink.path), "Tink.aiff missing")
        let playback = ChapterPlayback()
        XCTAssertFalse(playback.isPlaying)
        XCTAssertNil(playback.playingID)
        let chapter = Chapter(
            url: TestSupport.tink,
            index: 1,
            title: "Tink",
            duration: 0.5,
            fileSize: 1
        )
        playback.toggle(chapter)
        let started = await waitUntil(timeout: 3) {
            playback.isPlaying(chapter) && playback.playingID == chapter.id
        }
        XCTAssertTrue(started)
        playback.toggle(chapter)
        XCTAssertEqual(playback.playingID, chapter.id)
        XCTAssertFalse(playback.isPlaying)
        playback.stop()
        XCTAssertNil(playback.playingID)
        let missing = Chapter(
            url: URL(fileURLWithPath: "/tmp/no-tink-\(UUID().uuidString).aiff"),
            index: 2,
            title: "Missing",
            duration: 1,
            fileSize: 0
        )
        playback.toggle(missing)
        XCTAssertNil(playback.playingID)
        XCTAssertFalse(playback.isPlaying)
    }

    private func makeSilence(in dir: URL) throws -> URL {
        let wav = dir.appendingPathComponent("silence.wav")
        try TestSupport.writeSilenceWAV(to: wav, seconds: 1)
        return wav
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}
