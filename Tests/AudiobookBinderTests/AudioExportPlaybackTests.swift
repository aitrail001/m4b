import AVFoundation
import CoreMedia
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
        XCTAssertEqual(AudioMetadata.fileInfo(of: TestSupport.tink).duration, info.duration)
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

    func testExportOverwritePreservesExistingDestWhenSourcesMissing() async throws {
        let dir = try TestSupport.tempDir("export-keep-dest")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("keep.m4b")
        let payload = Data("KEEP-OLD-M4B".utf8)
        try payload.write(to: dest)

        let missing = Chapter(
            url: dir.appendingPathComponent("gone.mp3"),
            index: 1,
            title: "Gone",
            duration: 1,
            fileSize: 1
        )
        let book = Audiobook(folder: dir, title: "Empty", author: "A", chapters: [missing])
        do {
            try await M4BExporter().export(book: book, to: dest, overwrite: true)
            XCTFail("expected noAudioFiles")
        } catch let error as BinderError {
            guard case .noAudioFiles = error else { return XCTFail("\(error)") }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(try Data(contentsOf: dest), payload)
    }

    func testExportOverwritePreservesDestinationDirectory() async throws {
        let dir = try TestSupport.tempDir("export-dest-dir")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("out.m4b", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let sentinel = dest.appendingPathComponent("keep-me.txt")
        try Data("SENTINEL".utf8).write(to: sentinel)

        let source = try makeSilence(in: dir)
        let info = AudioMetadata.fileInfo(of: source)
        let chapter = Chapter(
            url: source,
            index: 1,
            title: "Keep",
            duration: info.duration,
            fileSize: 1,
            audioInfo: info.audioInfo
        )
        let book = Audiobook(folder: dir, title: "Dir Dest", author: "A", chapters: [chapter])
        do {
            try await M4BExporter(bitrate: 48_000).export(book: book, to: dest, overwrite: true)
            XCTFail("expected directory rejection")
        } catch let error as BinderError {
            guard case .exportFailed = error else { return XCTFail("\(error)") }
        }

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("SENTINEL".utf8))
    }

    func testExportOverwriteReplacesTinyExistingDest() async throws {
        let dir = try TestSupport.tempDir("export-replace-tiny")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSilence(in: dir)
        let dest = dir.appendingPathComponent("out.m4b")
        try Data("TINY".utf8).write(to: dest)
        let oldSize = try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64 ?? 0

        let info = AudioMetadata.fileInfo(of: source)
        let chapter = Chapter(
            url: source,
            index: 1,
            title: "Tink",
            duration: info.duration,
            fileSize: 1,
            audioInfo: info.audioInfo
        )
        let book = Audiobook(folder: dir, title: "Replace Me", author: "System", chapters: [chapter])
        try await M4BExporter(bitrate: 48_000).export(book: book, to: dest, overwrite: true)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)
        let size = try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(size, oldSize)
        XCTAssertGreaterThan(size, 1_000)
    }

    func testExportRejectsDestinationEqualToSourceChapter() async throws {
        let dir = try TestSupport.tempDir("export-identity")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSilence(in: dir)
        let original = try Data(contentsOf: source)
        let info = AudioMetadata.fileInfo(of: source)
        let chapter = Chapter(
            url: source,
            index: 1,
            title: "Source",
            duration: info.duration,
            fileSize: 1,
            audioInfo: info.audioInfo
        )
        let book = Audiobook(folder: dir, title: "Identity", author: "A", chapters: [chapter])
        do {
            try await M4BExporter(bitrate: 48_000).export(book: book, to: source, overwrite: true)
            XCTFail("expected source/output identity collision")
        } catch let error as BinderError {
            guard case .exportFailed = error else { return XCTFail("\(error)") }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testPublishDoesNotRemoveDestWhenOverwriteIsFalse() throws {
        let dir = try TestSupport.tempDir("publish-noclobber")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("out.m4b")
        let staging = dir.appendingPathComponent("stage.m4a")
        let keep = Data("KEEP-DEST".utf8)
        try keep.write(to: dest)
        try Data("NEW-STAGING".utf8).write(to: staging)

        do {
            try M4BExporter.publish(staging: staging, to: dest, overwrite: false)
            XCTFail("expected outputExists")
        } catch let error as BinderError {
            guard case .outputExists = error else { return XCTFail("\(error)") }
        }

        XCTAssertEqual(try Data(contentsOf: dest), keep)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
    }

    func testPublishOverwriteReplacesExistingFile() throws {
        let dir = try TestSupport.tempDir("publish-replace")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("out.m4b")
        let staging = dir.appendingPathComponent("stage.m4a")
        try Data("OLD".utf8).write(to: dest)
        try Data("NEW-CONTENT".utf8).write(to: staging)

        try M4BExporter.publish(staging: staging, to: dest, overwrite: true)

        XCTAssertEqual(try Data(contentsOf: dest), Data("NEW-CONTENT".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
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
        let results = try await M4BExporter(bitrate: 48_000).exportAll(
            books: [ignored, selected],
            settings: settings
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].bookID, selected.id)
        XCTAssertEqual(results[0].outcome, .created)
        XCTAssertEqual(results[0].url.lastPathComponent, selected.suggestedFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: results[0].url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.outputURL(for: ignored).path))

        let existsSettings = ExportSettings(outputDirectory: dir, overwrite: false, writeNextToBook: false)
        let again = try await M4BExporter(bitrate: 48_000).exportAll(books: [selected], settings: existsSettings)
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(again[0].bookID, selected.id)
        XCTAssertEqual(again[0].outcome, .skippedExisting)
        XCTAssertNotEqual(again[0].outcome, .created)
        XCTAssertEqual(again[0].url.lastPathComponent, selected.suggestedFileName)
    }

    func testExportAllSkipExistingLeavesUnrelatedBytes() async throws {
        let root = try TestSupport.tempDir("export-skip-bytes")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDir = root.appendingPathComponent("BookA", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let book = try makeSilenceBook(folder: bookDir, title: "SkipMe", author: "A")
        let settings = ExportSettings(outputDirectory: out, overwrite: false, writeNextToBook: false)
        let dest = settings.plannedOutputs(for: [book])[book.id]!
        let payload = Data("UNRELATED-NOT-AN-M4B".utf8)
        try payload.write(to: dest)

        let results = try await M4BExporter(bitrate: 48_000).exportAll(books: [book], settings: settings)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].outcome, .skippedExisting)
        XCTAssertNotEqual(results[0].outcome, .created)
        XCTAssertEqual(results[0].url.standardizedFileURL.path, dest.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: dest), payload)
    }

    func testExportAllOverwriteReplacesExistingDest() async throws {
        let root = try TestSupport.tempDir("export-all-replace")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDir = root.appendingPathComponent("BookA", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let book = try makeSilenceBook(folder: bookDir, title: "ReplaceMe", author: "System")
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        let dest = settings.plannedOutputs(for: [book])[book.id]!
        try Data("OLD-DEST".utf8).write(to: dest)

        let results = try await M4BExporter(bitrate: 48_000).exportAll(books: [book], settings: settings)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].outcome, .replaced)
        XCTAssertEqual(results[0].url.standardizedFileURL.path, dest.standardizedFileURL.path)
        let size = try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(size, 1_000)
    }

    func testExportAllCollidingNamesWriteDistinctFiles() async throws {
        let root = try TestSupport.tempDir("export-collide")
        defer { try? FileManager.default.removeItem(at: root) }
        let editionA = root.appendingPathComponent("EditionA", isDirectory: true)
        let editionB = root.appendingPathComponent("EditionB", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: editionA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: editionB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let bookA = try makeSilenceBook(folder: editionA, title: "Same", author: "Ann")
        let bookB = try makeSilenceBook(folder: editionB, title: "Same", author: "Ann")
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        let plan = settings.plannedOutputs(for: [bookA, bookB])
        XCTAssertNotEqual(plan[bookA.id]?.standardizedFileURL.path, plan[bookB.id]?.standardizedFileURL.path)

        let results = try await M4BExporter(bitrate: 48_000).exportAll(
            books: [bookA, bookB],
            settings: settings
        )
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.outcome == .created })
        XCTAssertNotEqual(results[0].url.standardizedFileURL.path, results[1].url.standardizedFileURL.path)
        XCTAssertEqual(
            Set(results.map { $0.url.standardizedFileURL.path }),
            Set(plan.values.map { $0.standardizedFileURL.path })
        )
        for result in results {
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
            let size = try FileManager.default.attributesOfItem(atPath: result.url.path)[.size] as? Int64 ?? 0
            XCTAssertGreaterThan(size, 1_000)
        }
    }

    func testExportAllContinuesAfterFailureAndDoesNotPublishFailed() async throws {
        let root = try TestSupport.tempDir("export-continue-fail")
        defer { try? FileManager.default.removeItem(at: root) }
        let badDir = root.appendingPathComponent("BadBook", isDirectory: true)
        let goodDir = root.appendingPathComponent("GoodBook", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: goodDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let missing = Chapter(
            url: badDir.appendingPathComponent("gone.wav"),
            index: 1,
            title: "Gone",
            duration: 1,
            fileSize: 1
        )
        let bad = Audiobook(folder: badDir, title: "Bad", author: "A", chapters: [missing], selected: true)
        let good = try makeSilenceBook(folder: goodDir, title: "Good", author: "A")
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)

        let results = try await M4BExporter(bitrate: 48_000).exportAll(
            books: [bad, good],
            settings: settings
        )
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].bookID, bad.id)
        guard case .failed = results[0].outcome else {
            return XCTFail("expected failed, got \(results[0].outcome)")
        }
        XCTAssertFalse(results[0].outcome.isPublished)
        XCTAssertFalse(FileManager.default.fileExists(atPath: results[0].url.path))
        XCTAssertEqual(results[1].bookID, good.id)
        XCTAssertEqual(results[1].outcome, .created)
        XCTAssertTrue(FileManager.default.fileExists(atPath: results[1].url.path))
        let size = try FileManager.default.attributesOfItem(atPath: results[1].url.path)[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(size, 1_000)
    }

    func testWaitSemaphoreTimesOutWhenNeverSignaled() {
        let semaphore = DispatchSemaphore(value: 0)
        let start = Date()
        XCTAssertFalse(M4BExporter.wait(semaphore, timeout: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testWaitGroupTimesOutWhenNeverLeft() {
        let group = DispatchGroup()
        group.enter()
        let start = Date()
        XCTAssertFalse(M4BExporter.wait(group, timeout: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testWaitSemaphoreAndGroupSucceedWhenSignaled() {
        let semaphore = DispatchSemaphore(value: 0)
        semaphore.signal()
        XCTAssertTrue(M4BExporter.wait(semaphore, timeout: 0.2))

        let group = DispatchGroup()
        group.enter()
        group.leave()
        XCTAssertTrue(M4BExporter.wait(group, timeout: 0.2))
    }

    func testEncodeWaitTimeoutsAreBounded() {
        XCTAssertEqual(M4BExporter.assetLoadTimeout, 30)
        XCTAssertEqual(M4BExporter.finishWritingTimeout, 60)
        XCTAssertEqual(M4BExporter.writerReadyTimeout, 30)
    }

    func testEncodeCancellationTokenWorkerCheckSeesCancel() {
        let token = EncodeCancellation()
        XCTAssertFalse(token.isCancelled)

        token.cancel()

        var workerSawCancel = false
        DispatchQueue.global(qos: .userInitiated).sync {
            workerSawCancel = token.isCancelled
            XCTAssertTrue(token.isCancelled)
            do {
                try token.checkCancelled()
                XCTFail("expected cancelled")
            } catch let error as BinderError {
                guard case .cancelled = error else { return XCTFail("\(error)") }
            } catch {
                XCTFail("\(error)")
            }
        }
        XCTAssertTrue(workerSawCancel)
    }

    func testExportCancelDoesNotPublishFreshDest() async throws {
        let dir = try TestSupport.tempDir("export-cancel-fresh")
        defer { try? FileManager.default.removeItem(at: dir) }
        let book = try makeSilenceBook(
            folder: dir,
            title: "CancelFresh",
            author: "A",
            seconds: 5,
            chapterCount: 12
        )
        let dest = dir.appendingPathComponent("out.m4b")
        let encoding = StartedFlag()

        let task = Task {
            try await M4BExporter(bitrate: 48_000).export(book: book, to: dest, overwrite: true) { _, detail in
                if detail.contains("Encoding") {
                    encoding.mark()
                }
            }
        }
        await waitForFlag(encoding, timeout: 2)
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            try await task.value
            XCTFail("expected cancelled")
        } catch let error as BinderError {
            guard case .cancelled = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testExportCancelLeavesExistingDestUnchanged() async throws {
        let dir = try TestSupport.tempDir("export-cancel-keep")
        defer { try? FileManager.default.removeItem(at: dir) }
        let book = try makeSilenceBook(
            folder: dir,
            title: "CancelKeep",
            author: "A",
            seconds: 5,
            chapterCount: 12
        )
        let dest = dir.appendingPathComponent("keep.m4b")
        let payload = Data("KEEP-CANCEL-M4B".utf8)
        try payload.write(to: dest)
        let encoding = StartedFlag()

        let task = Task {
            try await M4BExporter(bitrate: 48_000).export(book: book, to: dest, overwrite: true) { _, detail in
                if detail.contains("Encoding") {
                    encoding.mark()
                }
            }
        }
        await waitForFlag(encoding, timeout: 2)
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            try await task.value
            XCTFail("expected cancelled")
        } catch let error as BinderError {
            guard case .cancelled = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(try Data(contentsOf: dest), payload)
    }

    func testExportAllCancelDoesNotTreatBookAsCreated() async throws {
        let root = try TestSupport.tempDir("export-all-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDir = root.appendingPathComponent("BookA", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let book = try makeSilenceBook(
            folder: bookDir,
            title: "CancelAll",
            author: "A",
            seconds: 5,
            chapterCount: 12
        )
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        let dest = settings.plannedOutputs(for: [book])[book.id]!
        let encoding = StartedFlag()

        let task = Task {
            try await M4BExporter(bitrate: 48_000).exportAll(books: [book], settings: settings) { progress in
                if progress.detail.contains("Encoding") {
                    encoding.mark()
                }
            }
        }
        await waitForFlag(encoding, timeout: 2)
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            let results = try await task.value
            XCTFail("expected cancelled, got \(results)")
        } catch let error as BinderError {
            guard case .cancelled = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testChaptersReadyForExport() {
        let keep = TestSupport.dummyChapter(index: 1, included: true)
        var drop = TestSupport.dummyChapter(index: 2, included: false)
        drop.included = false
        XCTAssertEqual(M4BExporter.chaptersReadyForExport([keep, drop]).map(\.index), [1])
    }

    func testChaptersForExportRejectsMissingIncludedAndIgnoresExcluded() throws {
        let dir = try TestSupport.tempDir("chapters-for-export")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("keep.wav")
        try TestSupport.writeSilenceWAV(to: wav)
        let missing = dir.appendingPathComponent("gone.wav")

        let keep = TestSupport.dummyChapter(index: 1, url: wav, included: true)
        let skip = TestSupport.dummyChapter(index: 2, url: missing, included: false)
        let gone = TestSupport.dummyChapter(index: 3, url: missing, included: true)

        let ready = try M4BExporter.chaptersForExport([keep, skip], folder: dir)
        XCTAssertEqual(ready.map(\.index), [1])

        do {
            _ = try M4BExporter.chaptersForExport([keep, gone], folder: dir)
            XCTFail("expected missingChapters")
        } catch let error as BinderError {
            guard case .missingChapters(let urls) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(urls.map(\.lastPathComponent), ["gone.wav"])
        }

        do {
            _ = try M4BExporter.chaptersForExport([gone], folder: dir)
            XCTFail("expected noAudioFiles")
        } catch let error as BinderError {
            guard case .noAudioFiles = error else { return XCTFail("\(error)") }
        }

        try FileManager.default.removeItem(at: wav)
        do {
            _ = try M4BExporter.chaptersForExport([keep], folder: dir)
            XCTFail("expected failure after source disappeared")
        } catch let error as BinderError {
            guard case .noAudioFiles = error else { return XCTFail("\(error)") }
        }
    }

    func testExportFailsWhenSomeIncludedChaptersAreMissing() async throws {
        let dir = try TestSupport.tempDir("export-partial-missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSilence(in: dir)
        let info = AudioMetadata.fileInfo(of: source)
        let keep = Chapter(
            url: source,
            index: 1,
            title: "Keep",
            duration: info.duration,
            fileSize: 1,
            audioInfo: info.audioInfo
        )
        let gone = Chapter(
            url: dir.appendingPathComponent("gone.wav"),
            index: 2,
            title: "Gone",
            duration: 1,
            fileSize: 1
        )
        let book = Audiobook(folder: dir, title: "Partial", author: "A", chapters: [keep, gone])
        let exporter = M4BExporter(bitrate: 48_000)

        let fresh = dir.appendingPathComponent("fresh.m4b")
        do {
            try await exporter.export(book: book, to: fresh, overwrite: true)
            XCTFail("expected missingChapters")
        } catch let error as BinderError {
            guard case .missingChapters(let urls) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(urls.map(\.lastPathComponent), ["gone.wav"])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))

        let dest = dir.appendingPathComponent("keep.m4b")
        let payload = Data("KEEP-PARTIAL".utf8)
        try payload.write(to: dest)
        do {
            try await exporter.export(book: book, to: dest, overwrite: true)
            XCTFail("expected missingChapters")
        } catch let error as BinderError {
            guard case .missingChapters = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: dest), payload)
    }

    func testExportSucceedsWhenExcludedChapterIsMissing() async throws {
        let dir = try TestSupport.tempDir("export-excluded-missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSilence(in: dir)
        let info = AudioMetadata.fileInfo(of: source)
        let keep = Chapter(
            url: source,
            index: 1,
            title: "Keep",
            duration: info.duration,
            fileSize: 1,
            audioInfo: info.audioInfo
        )
        var skip = Chapter(
            url: dir.appendingPathComponent("gone.wav"),
            index: 2,
            title: "Skip",
            duration: 1,
            fileSize: 1
        )
        skip.included = false
        let book = Audiobook(folder: dir, title: "Excluded Missing", author: "A", chapters: [keep, skip])
        let dest = dir.appendingPathComponent("out.m4b")
        try await M4BExporter(bitrate: 48_000).export(book: book, to: dest, overwrite: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        let size = try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(size, 1_000)
    }

    func testPCMRetimingSampleDurationIsOneFrameAndAdvanceIsNFrames() {
        let timescale: Int32 = 44_100
        let frames = 1_024
        let timing = M4BExporter.pcmTiming(frames: frames, timescale: timescale)

        XCTAssertEqual(timing.sampleDuration.value, 1)
        XCTAssertEqual(timing.sampleDuration.timescale, timescale)
        XCTAssertEqual(timing.bufferAdvance.value, Int64(frames))
        XCTAssertEqual(timing.bufferAdvance.timescale, timescale)
        XCTAssertEqual(
            CMTimeCompare(CMTimeMultiply(timing.sampleDuration, multiplier: Int32(frames)), timing.bufferAdvance),
            0
        )

        let one = M4BExporter.pcmTiming(frames: 1, timescale: 48_000)
        XCTAssertEqual(one.sampleDuration.value, 1)
        XCTAssertEqual(one.bufferAdvance.value, 1)
        XCTAssertEqual(one.sampleDuration.timescale, 48_000)
        XCTAssertEqual(CMTimeCompare(one.sampleDuration, one.bufferAdvance), 0)
    }

    func testPCMRetimingCopyAppliesPerSampleDuration() throws {
        let frames = 8
        let timescale: Int32 = 44_100
        let pts = CMTime(value: 100, timescale: timescale)
        let original = try makePCMSampleBuffer(frames: frames, sampleRate: timescale)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(original), .zero)

        let timing = M4BExporter.pcmTiming(frames: frames, timescale: timescale)
        let copied = try M4BExporter.retimed(original, pts: pts, sampleDuration: timing.sampleDuration)

        XCTAssertEqual(CMSampleBufferGetNumSamples(copied), frames)
        XCTAssertEqual(CMSampleBufferGetDuration(copied).value, Int64(frames))
        XCTAssertEqual(CMSampleBufferGetDuration(copied).timescale, timescale)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(copied), pts)

        var first = CMSampleTimingInfo()
        XCTAssertEqual(CMSampleBufferGetSampleTimingInfo(copied, at: 0, timingInfoOut: &first), noErr)
        XCTAssertEqual(first.duration.value, 1)
        XCTAssertEqual(first.duration.timescale, timescale)
        XCTAssertEqual(first.presentationTimeStamp, pts)

        var last = CMSampleTimingInfo()
        XCTAssertEqual(CMSampleBufferGetSampleTimingInfo(copied, at: frames - 1, timingInfoOut: &last), noErr)
        XCTAssertEqual(last.duration.value, 1)
        XCTAssertEqual(last.presentationTimeStamp.value, pts.value + Int64(frames - 1))
        XCTAssertEqual(last.presentationTimeStamp.timescale, timescale)
    }

    func testPCMRetimingCopyThrowsWhenTimingCopyFails() {
        do {
            _ = try M4BExporter.requireRetimedCopy(status: -12712, copy: nil)
            XCTFail("expected exportFailed")
        } catch let error as BinderError {
            guard case .exportFailed = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testPlaybackRangeUsesStartOffsetAndDuration() {
        let first = Chapter(
            url: URL(fileURLWithPath: "/tmp/book.m4b"),
            index: 1,
            title: "One",
            duration: 10,
            fileSize: 1,
            startOffset: 0,
            isEmbedded: true
        )
        let second = Chapter(
            url: URL(fileURLWithPath: "/tmp/book.m4b"),
            index: 2,
            title: "Two",
            duration: 20,
            fileSize: 1,
            startOffset: 10,
            isEmbedded: true
        )
        let file = Chapter(
            url: URL(fileURLWithPath: "/tmp/book.m4b"),
            index: 0,
            title: "Play file",
            duration: 30,
            fileSize: 1
        )
        let firstRange = ChapterPlayback.playbackRange(for: first)
        XCTAssertEqual(firstRange.start, 0)
        XCTAssertEqual(firstRange.end, 10)
        let secondRange = ChapterPlayback.playbackRange(for: second)
        XCTAssertEqual(secondRange.start, 10)
        XCTAssertEqual(secondRange.end, 30)
        let fileRange = ChapterPlayback.playbackRange(for: file)
        XCTAssertEqual(fileRange.start, 0)
        XCTAssertEqual(fileRange.end, 30)
        let short = Chapter(
            url: URL(fileURLWithPath: "/tmp/book.m4b"),
            index: 3,
            title: "Tiny",
            duration: 0,
            fileSize: 1,
            startOffset: 4,
            isEmbedded: true
        )
        let shortRange = ChapterPlayback.playbackRange(for: short)
        XCTAssertEqual(shortRange.start, 4)
        XCTAssertEqual(shortRange.end, 4.05)
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

    private func makePCMSampleBuffer(frames: Int, sampleRate: Int32) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard formatStatus == noErr, let format else {
            throw BinderError.exportFailed("Could not create PCM format")
        }

        let byteCount = frames * Int(asbd.mBytesPerFrame)
        var block: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &block
        )
        guard blockStatus == kCMBlockBufferNoErr, let block else {
            throw BinderError.exportFailed("Could not create PCM block")
        }
        let fillStatus = CMBlockBufferFillDataBytes(
            with: 0,
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
        guard fillStatus == kCMBlockBufferNoErr else {
            throw BinderError.exportFailed("Could not fill PCM block")
        }

        var originalTiming = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = Int(asbd.mBytesPerFrame)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &originalTiming,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
            throw BinderError.exportFailed("Could not create PCM sample buffer (\(status))")
        }
        return sample
    }

    private func makeSilence(in dir: URL, seconds: Double = 1) throws -> URL {
        let wav = dir.appendingPathComponent("silence.wav")
        try TestSupport.writeSilenceWAV(to: wav, seconds: seconds)
        return wav
    }

    private func makeSilenceBook(
        folder: URL,
        title: String,
        author: String,
        selected: Bool = true,
        seconds: Double = 1,
        chapterCount: Int = 1
    ) throws -> Audiobook {
        let source = try makeSilence(in: folder, seconds: seconds)
        let info = AudioMetadata.fileInfo(of: source)
        let chapters = (1...max(chapterCount, 1)).map { index in
            Chapter(
                url: source,
                index: index,
                title: "Ch\(index)",
                duration: info.duration,
                fileSize: 1,
                audioInfo: info.audioInfo
            )
        }
        return Audiobook(
            folder: folder,
            title: title,
            author: author,
            chapters: chapters,
            selected: selected
        )
    }

    private func waitForFlag(_ flag: StartedFlag, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if flag.isSet { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
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

private final class StartedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func mark() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
