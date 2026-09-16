import AVFoundation
import CoreMedia
import CryptoKit
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

    func testExportRefusesUnownedDestAppearingAfterPreflight() async throws {
        let dir = try TestSupport.tempDir("export-appear-after-preflight")
        defer { try? FileManager.default.removeItem(at: dir) }
        let book = try makeSilenceBook(folder: dir, title: "AppearAfterPreflight", author: "A")
        let dest = dir.appendingPathComponent("out.m4b")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        let planted = Data("PLANTED-UNOWNED-DEST".utf8)
        let plantedFlag = StartedFlag()

        var exporter = M4BExporter(bitrate: 48_000)
        exporter.afterPreflight = {
            plantedFlag.mark()
            try? planted.write(to: dest)
        }

        do {
            try await exporter.export(book: book, to: dest, overwrite: true)
            XCTFail("expected outputExists")
        } catch let error as BinderError {
            guard case .outputExists = error else { return XCTFail("\(error)") }
        }

        XCTAssertTrue(plantedFlag.isSet, "hook must plant dest after preflight")
        XCTAssertEqual(try Data(contentsOf: dest), planted)
    }

    func testExportRefusesStaleExistingM4BURLDestAppearingAfterPreflight() async throws {
        let dir = try TestSupport.tempDir("export-stale-existing-appear")
        defer { try? FileManager.default.removeItem(at: dir) }
        var book = try makeSilenceBook(folder: dir, title: "StaleExisting", author: "A")
        let dest = dir.appendingPathComponent(book.suggestedFileName)
        try Data("PRIOR-OWNED".utf8).write(to: dest)
        book.existingM4BURL = dest
        XCTAssertTrue(OutputAssociation.record(dest, inBookFolder: dir))
        try FileManager.default.removeItem(at: dest)
        XCTAssertNil(OutputAssociation.load(inBookFolder: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))

        let planted = Data("PLANTED-STALE-EXISTING".utf8)
        let plantedFlag = StartedFlag()
        var exporter = M4BExporter(bitrate: 48_000)
        exporter.afterPreflight = {
            plantedFlag.mark()
            try? planted.write(to: dest)
        }

        do {
            try await exporter.export(book: book, to: dest, overwrite: true)
            XCTFail("expected outputExists")
        } catch let error as BinderError {
            guard case .outputExists = error else { return XCTFail("\(error)") }
        }

        XCTAssertTrue(plantedFlag.isSet, "hook must plant dest after preflight")
        XCTAssertNil(OutputAssociation.load(inBookFolder: dir))
        XCTAssertEqual(try Data(contentsOf: dest), planted)
    }

    func testExportAdoptsAssociatedDestAppearingAfterPreflight() async throws {
        let dir = try TestSupport.tempDir("export-adopt-associated-appear")
        defer { try? FileManager.default.removeItem(at: dir) }
        var book = try makeSilenceBook(folder: dir, title: "AdoptAssociated", author: "A")
        let dest = dir.appendingPathComponent(book.suggestedFileName)
        let owned = Data("ASSOCIATED-DEST".utf8)
        try owned.write(to: dest)
        book.existingM4BURL = dest
        XCTAssertTrue(OutputAssociation.record(dest, inBookFolder: dir))
        let aside = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).m4b")
        try FileManager.default.moveItem(at: dest, to: aside)
        XCTAssertNil(OutputAssociation.load(inBookFolder: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))

        let restored = StartedFlag()
        var exporter = M4BExporter(bitrate: 48_000)
        exporter.afterPreflight = {
            restored.mark()
            try? FileManager.default.moveItem(at: aside, to: dest)
        }

        try await exporter.export(book: book, to: dest, overwrite: true)

        XCTAssertTrue(restored.isSet, "hook must restore associated dest after preflight")
        XCTAssertNotEqual(try Data(contentsOf: dest), owned)
        let size = try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(size, 1_000)
    }

    func testOwnedAppearedDestRefusesWhenLiveIdentityDiffersFromLoadVerified() throws {
        let dir = try TestSupport.tempDir("owned-appeared-dest-identity")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("out.m4b")
        try Data("OWNED-DEST-B".utf8).write(to: dest)
        let book = TestSupport.dummyBook(folder: dir.path)
        XCTAssertTrue(OutputAssociation.record(dest, inBookFolder: dir))

        let verified = try XCTUnwrap(OutputAssociation.loadVerified(inBookFolder: dir))
        XCTAssertEqual(OutputAssociation.load(inBookFolder: dir)?.standardizedFileURL.path, dest.standardizedFileURL.path)
        XCTAssertTrue(M4BExporter.isSameFileURL(verified.url, dest))
        let ownedLive = try XCTUnwrap(FileIdentity.read(from: dest))
        XCTAssertTrue(ownedLive.isSameVersion(as: verified.identity))
        XCTAssertTrue(M4BExporter.isOwnedAppearedDest(dest, book: book, live: ownedLive))

        let unowned = dir.appendingPathComponent("unowned-a.m4b")
        try Data("UNOWNED-DEST-A-DIFFERENT".utf8).write(to: unowned)
        let unownedLive = try XCTUnwrap(FileIdentity.read(from: unowned))
        XCTAssertFalse(unownedLive.isSameVersion(as: verified.identity))
        XCTAssertFalse(
            M4BExporter.isOwnedAppearedDest(dest, book: book, live: unownedLive),
            "live identity A must not adopt when load validated owned identity B"
        )
    }

    func testExportOverwriteReplacesDestThatExistedAtStart() async throws {
        let dir = try TestSupport.tempDir("export-existed-at-start")
        defer { try? FileManager.default.removeItem(at: dir) }
        var book = try makeSilenceBook(folder: dir, title: "ExistedAtStart", author: "A")
        let dest = dir.appendingPathComponent(book.suggestedFileName)
        let old = Data("OLD-OWNED-DEST".utf8)
        try old.write(to: dest)
        book.existingM4BURL = dest
        OutputAssociation.record(dest, inBookFolder: dir)

        try await M4BExporter(bitrate: 48_000).export(book: book, to: dest, overwrite: true)

        XCTAssertNotEqual(try Data(contentsOf: dest), old)
        let size = try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64 ?? 0
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
            try M4BExporter.publish(
                staging: staging,
                to: dest,
                overwrite: false,
                expectedIdentity: FileIdentity.read(from: dest)
            )
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

        try M4BExporter.publish(
            staging: staging,
            to: dest,
            overwrite: true,
            expectedIdentity: FileIdentity.read(from: dest)
        )

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
        let primary = out.appendingPathComponent(book.suggestedFileName)
        let payload = Data("UNRELATED-NOT-AN-M4B".utf8)
        try payload.write(to: primary)

        let results = try await M4BExporter(bitrate: 48_000).exportAll(books: [book], settings: settings)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].outcome, .created)
        XCTAssertNotEqual(results[0].url.standardizedFileURL.path, primary.standardizedFileURL.path)
        XCTAssertEqual(results[0].url.lastPathComponent, "SkipMe - A - BookA.m4b")
        XCTAssertEqual(try Data(contentsOf: primary), payload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: results[0].url.path))
    }

    func testExportAllOverwriteReplacesExistingDest() async throws {
        let root = try TestSupport.tempDir("export-all-replace")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDir = root.appendingPathComponent("BookA", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var book = try makeSilenceBook(folder: bookDir, title: "ReplaceMe", author: "System")
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        let dest = settings.plannedOutputs(for: [book])[book.id]!
        let payload = Data("OLD-DEST".utf8)
        try payload.write(to: dest)
        book.existingM4BURL = dest

        let results = try await M4BExporter(bitrate: 48_000).exportAll(books: [book], settings: settings)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try Data(contentsOf: dest), payload)
        XCTAssertNotEqual(results[0].url.standardizedFileURL.path, dest.standardizedFileURL.path)
        XCTAssertEqual(results[0].url.pathExtension.lowercased(), "m4b")
        XCTAssertNotEqual(results[0].outcome, .replaced)
        XCTAssertTrue(FileManager.default.fileExists(atPath: results[0].url.path))
    }

    func testExportAllOverwriteTrustedSidecarReplacesExistingDest() async throws {
        let root = try TestSupport.tempDir("export-all-replace-trusted")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDir = root.appendingPathComponent("BookA", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var book = try makeSilenceBook(folder: bookDir, title: "ReplaceMe", author: "System")
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        let dest = settings.plannedOutputs(for: [book])[book.id]!
        try Data("OLD-DEST".utf8).write(to: dest)
        book.existingM4BURL = dest
        OutputAssociation.record(dest, inBookFolder: bookDir)

        let results = try await M4BExporter(bitrate: 48_000).exportAll(books: [book], settings: settings)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].outcome, .replaced)
        XCTAssertEqual(results[0].url.standardizedFileURL.path, dest.standardizedFileURL.path)
        let size = try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(size, 1_000)
    }

    func testExportAllDoesNotReplaceUnownedDestAppearingAfterFirstCheck() async throws {
        let root = try TestSupport.tempDir("export-all-appear-after-check")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDir = root.appendingPathComponent("Book", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let book = try makeSilenceBook(folder: bookDir, title: "AppearAfterCheck", author: "A")
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        let dest = settings.plannedOutputs(for: [book])[book.id]!
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertFalse(settings.owns(dest, for: book))
        let planted = Data("PLANTED-AFTER-CHECK".utf8)
        let plantedFlag = StartedFlag()

        var exporter = M4BExporter(bitrate: 48_000)
        exporter.afterDestinationCheck = {
            plantedFlag.mark()
            try? planted.write(to: dest)
        }

        let results = try await exporter.exportAll(books: [book], settings: settings)
        XCTAssertTrue(plantedFlag.isSet, "hook must plant dest after the first existence check")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].outcome, .skippedExisting)
        XCTAssertEqual(results[0].url.standardizedFileURL.path, dest.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: dest), planted)
    }

    func testExportAllDoesNotReplaceUnownedDestAppearingBeforeExport() async throws {
        let root = try TestSupport.tempDir("export-all-appear-before-export")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDir = root.appendingPathComponent("Book", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let book = try makeSilenceBook(folder: bookDir, title: "AppearBeforeExport", author: "A")
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        let dest = settings.plannedOutputs(for: [book])[book.id]!
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertFalse(settings.owns(dest, for: book))
        let planted = Data("PLANTED-BEFORE-EXPORT".utf8)
        let plantedFlag = StartedFlag()

        var exporter = M4BExporter(bitrate: 48_000)
        exporter.beforeExport = {
            plantedFlag.mark()
            try? planted.write(to: dest)
        }

        let results = try await exporter.exportAll(books: [book], settings: settings)
        XCTAssertTrue(plantedFlag.isSet, "hook must plant dest after the last skip check")
        XCTAssertEqual(results.count, 1)
        switch results[0].outcome {
        case .skippedExisting, .failed:
            break
        default:
            XCTFail("expected skip or failure, got \(results[0].outcome)")
        }
        XCTAssertEqual(results[0].url.standardizedFileURL.path, dest.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: dest), planted)
    }

    func testExportAllRefusesStaleExistingM4BURLDestAppearingBeforeExport() async throws {
        let root = try TestSupport.tempDir("export-all-stale-existing-appear")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDir = root.appendingPathComponent("Book", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var book = try makeSilenceBook(folder: bookDir, title: "StaleExisting", author: "A")
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        let dest = settings.plannedOutputs(for: [book])[book.id]!
        book.existingM4BURL = dest
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertNil(OutputAssociation.load(inBookFolder: bookDir))
        XCTAssertEqual(
            settings.plannedOutputs(for: [book])[book.id]?.standardizedFileURL.path,
            dest.standardizedFileURL.path
        )

        let planted = Data("PLANTED-STALE-BEFORE-EXPORT".utf8)
        let plantedFlag = StartedFlag()
        var exporter = M4BExporter(bitrate: 48_000)
        exporter.beforeExport = {
            plantedFlag.mark()
            try? planted.write(to: dest)
        }

        let results = try await exporter.exportAll(books: [book], settings: settings)
        XCTAssertTrue(plantedFlag.isSet, "hook must plant dest after the last skip check")
        XCTAssertEqual(results.count, 1)
        switch results[0].outcome {
        case .skippedExisting, .failed:
            break
        default:
            XCTFail("expected skip or failure, got \(results[0].outcome)")
        }
        XCTAssertEqual(results[0].url.standardizedFileURL.path, dest.standardizedFileURL.path)
        XCTAssertNil(OutputAssociation.load(inBookFolder: bookDir))
        XCTAssertEqual(try Data(contentsOf: dest), planted)
    }

    func testExportAllOverwriteStaleExistingM4BURLDoesNotReplaceReplacedDest() async throws {
        let root = try TestSupport.tempDir("export-stale-existing")
        defer { try? FileManager.default.removeItem(at: root) }
        let editionB = root.appendingPathComponent("EditionB", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: editionB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var book = try makeSilenceBook(folder: editionB, title: "Same", author: "Ann")
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        let dest = settings.plannedOutputs(for: [book])[book.id]!
        try Data("OWNED-B".utf8).write(to: dest)
        book.existingM4BURL = dest
        OutputAssociation.record(dest, inBookFolder: editionB)
        let sentinel = Data("REPLACED-SENTINEL".utf8)
        try sentinel.write(to: dest)

        XCTAssertFalse(settings.owns(dest, for: book))
        let plan = settings.plannedOutputs(for: [book])
        XCTAssertNotEqual(plan[book.id]?.standardizedFileURL.path, dest.standardizedFileURL.path)

        let results = try await M4BExporter(bitrate: 48_000).exportAll(books: [book], settings: settings)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try Data(contentsOf: dest), sentinel)
        XCTAssertNotEqual(results[0].url.standardizedFileURL.path, dest.standardizedFileURL.path)
        XCTAssertNotEqual(results[0].outcome, .replaced)
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

    func testExportAllOverwriteBOnlyDoesNotReplaceABytes() async throws {
        let root = try TestSupport.tempDir("export-b-only-overwrite")
        defer { try? FileManager.default.removeItem(at: root) }
        let editionA = root.appendingPathComponent("EditionA", isDirectory: true)
        let editionB = root.appendingPathComponent("EditionB", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: editionA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: editionB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var bookA = try makeSilenceBook(folder: editionA, title: "Same", author: "Ann")
        var bookB = try makeSilenceBook(folder: editionB, title: "Same", author: "Ann")
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        let first = settings.plannedOutputs(for: [bookA, bookB])
        let destA = first[bookA.id]!
        let destB = first[bookB.id]!
        let payloadA = Data("SENTINEL-A".utf8)
        try payloadA.write(to: destA)
        try Data("SENTINEL-B".utf8).write(to: destB)
        bookA.existingM4BURL = destA
        bookB.existingM4BURL = destB
        OutputAssociation.record(destA, inBookFolder: editionA)
        OutputAssociation.record(destB, inBookFolder: editionB)

        let results = try await M4BExporter(bitrate: 48_000).exportAll(books: [bookB], settings: settings)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].bookID, bookB.id)
        XCTAssertEqual(results[0].outcome, .replaced)
        XCTAssertEqual(results[0].url.standardizedFileURL.path, destB.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: destA), payloadA)
        let sizeB = try FileManager.default.attributesOfItem(atPath: destB.path)[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(sizeB, 1_000)
    }

    func testExportAllOverwriteOffBOnlyTargetsOwnedDest() async throws {
        let root = try TestSupport.tempDir("export-b-only-skip")
        defer { try? FileManager.default.removeItem(at: root) }
        let editionA = root.appendingPathComponent("EditionA", isDirectory: true)
        let editionB = root.appendingPathComponent("EditionB", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: editionA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: editionB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var bookA = try makeSilenceBook(folder: editionA, title: "Same", author: "Ann")
        var bookB = try makeSilenceBook(folder: editionB, title: "Same", author: "Ann")
        let settings = ExportSettings(outputDirectory: out, overwrite: false, writeNextToBook: false)
        let first = settings.plannedOutputs(for: [bookA, bookB])
        let destA = first[bookA.id]!
        let destB = first[bookB.id]!
        let payloadA = Data("SENTINEL-A".utf8)
        let payloadB = Data("SENTINEL-B".utf8)
        try payloadA.write(to: destA)
        try payloadB.write(to: destB)
        bookA.existingM4BURL = destA
        bookB.existingM4BURL = destB
        OutputAssociation.record(destA, inBookFolder: editionA)
        OutputAssociation.record(destB, inBookFolder: editionB)

        let results = try await M4BExporter(bitrate: 48_000).exportAll(books: [bookB], settings: settings)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].bookID, bookB.id)
        XCTAssertEqual(results[0].outcome, .skippedExisting)
        XCTAssertEqual(results[0].url.standardizedFileURL.path, destB.standardizedFileURL.path)
        XCTAssertNotEqual(results[0].url.standardizedFileURL.path, destA.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: destA), payloadA)
        XCTAssertEqual(try Data(contentsOf: destB), payloadB)
    }

    func testExportAllRecordsOutputAssociationSidecar() async throws {
        let root = try TestSupport.tempDir("export-sidecar")
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
        let results = try await M4BExporter(bitrate: 48_000).exportAll(
            books: [bookA, bookB],
            settings: settings
        )
        XCTAssertEqual(results.count, 2)
        let destByID = Dictionary(uniqueKeysWithValues: results.map { ($0.bookID, $0.url) })

        let storedA = OutputAssociation.load(inBookFolder: editionA)
        let storedB = OutputAssociation.load(inBookFolder: editionB)
        XCTAssertEqual(
            storedA?.standardizedFileURL.path,
            destByID[bookA.id]?.standardizedFileURL.path
        )
        XCTAssertEqual(
            storedB?.standardizedFileURL.path,
            destByID[bookB.id]?.standardizedFileURL.path
        )
        XCTAssertEqual(storedA?.lastPathComponent, "Same - Ann.m4b")
        XCTAssertEqual(storedB?.lastPathComponent, "Same - Ann - EditionB.m4b")
    }

    func testExportAllOverwriteImportedTxtSidecarDoesNotReplaceBytes() async throws {
        let root = try TestSupport.tempDir("export-imported-txt")
        defer { try? FileManager.default.removeItem(at: root) }
        let editionB = root.appendingPathComponent("EditionB", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: editionB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let bookB = try makeSilenceBook(folder: editionB, title: "Same", author: "Ann")
        let notes = out.appendingPathComponent("Same - Ann notes.txt")
        let payload = Data("KEEP-NOTES-TXT".utf8)
        try payload.write(to: notes)
        try TestSupport.writePathOnlyOutputSidecar(notes, in: editionB)

        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        let results = try await M4BExporter(bitrate: 48_000).exportAll(books: [bookB], settings: settings)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try Data(contentsOf: notes), payload)
        XCTAssertNotEqual(results[0].url.standardizedFileURL.path, notes.standardizedFileURL.path)
        XCTAssertEqual(results[0].url.pathExtension.lowercased(), "m4b")
        XCTAssertNotEqual(results[0].outcome, .replaced)
    }

    func testExportAllOverwriteForgedStructuredJSONDoesNotReplaceDest() async throws {
        let root = try TestSupport.tempDir("export-forged-json")
        defer { try? FileManager.default.removeItem(at: root) }
        let editionB = root.appendingPathComponent("EditionB", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: editionB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let bookB = try makeSilenceBook(folder: editionB, title: "Same", author: "Ann")
        let dest = out.appendingPathComponent(bookB.suggestedFileName)
        let payload = Data("FORGED-SHARED-DEST".utf8)
        try payload.write(to: dest)
        try TestSupport.writeStructuredOutputSidecar(dest, in: editionB)

        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        XCTAssertFalse(settings.owns(dest, for: bookB))
        let results = try await M4BExporter(bitrate: 48_000).exportAll(books: [bookB], settings: settings)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try Data(contentsOf: dest), payload)
        XCTAssertNotEqual(results[0].url.standardizedFileURL.path, dest.standardizedFileURL.path)
        XCTAssertNotEqual(results[0].outcome, .replaced)
        XCTAssertTrue(FileManager.default.fileExists(atPath: results[0].url.path))
    }

    func testExportAllOverwriteLeftoverInFolderDoesNotReplaceBytes() async throws {
        let root = try TestSupport.tempDir("export-leftover-folder")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDir = root.appendingPathComponent("BookA", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)

        var book = try makeSilenceBook(folder: bookDir, title: "Same", author: "Ann")
        let dest = bookDir.appendingPathComponent(book.suggestedFileName)
        let leftover = Data("LEFTOVER-M4B".utf8)
        try leftover.write(to: dest)
        book.existingM4BURL = dest

        let settings = ExportSettings(overwrite: true, writeNextToBook: true)
        XCTAssertFalse(settings.owns(dest, for: book))
        let results = try await M4BExporter(bitrate: 48_000).exportAll(books: [book], settings: settings)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try Data(contentsOf: dest), leftover)
        XCTAssertNotEqual(results[0].url.standardizedFileURL.path, dest.standardizedFileURL.path)
        XCTAssertNotEqual(results[0].outcome, .replaced)
        XCTAssertTrue(FileManager.default.fileExists(atPath: results[0].url.path))
    }

    func testExportAllOverwriteImportedOtherEditionSidecarDoesNotReplaceABytes() async throws {
        let root = try TestSupport.tempDir("export-imported-other")
        defer { try? FileManager.default.removeItem(at: root) }
        let editionA = root.appendingPathComponent("EditionA", isDirectory: true)
        let editionB = root.appendingPathComponent("EditionB", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: editionA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: editionB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let bookB = try makeSilenceBook(folder: editionB, title: "Same", author: "Ann")
        let destA = out.appendingPathComponent("Same - Ann.m4b")
        let payloadA = Data("SENTINEL-A".utf8)
        try payloadA.write(to: destA)
        try TestSupport.writePathOnlyOutputSidecar(destA, in: editionB)

        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        let results = try await M4BExporter(bitrate: 48_000).exportAll(books: [bookB], settings: settings)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try Data(contentsOf: destA), payloadA)
        XCTAssertNotEqual(results[0].url.standardizedFileURL.path, destA.standardizedFileURL.path)
        XCTAssertNotEqual(results[0].outcome, .replaced)
    }

    func testExportAllPublicationBarrierUnusedDestDoesNotClobber() async throws {
        let root = try TestSupport.tempDir("export-pub-unused")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDir = root.appendingPathComponent("BookA", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let book = try makeSilenceBook(folder: bookDir, title: "FreshDest", author: "A")
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        let dest = settings.plannedOutputs(for: [book])[book.id]!
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))

        let sentinel = Data("RACE-UNUSED-SENTINEL".utf8)
        let injected = StartedFlag()
        let results = try await M4BExporter(bitrate: 48_000).exportAll(books: [book], settings: settings) { progress in
            guard progress.fraction >= 0.92, progress.fraction < 1.0, !injected.isSet else { return }
            injected.mark()
            try? sentinel.write(to: dest)
        }

        XCTAssertTrue(injected.isSet)
        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].outcome.isPublished)
        XCTAssertEqual(try Data(contentsOf: dest), sentinel)
    }

    func testExportAllPublicationBarrierOwnedDestIdentityChangeDoesNotReplace() async throws {
        let root = try TestSupport.tempDir("export-pub-owned")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDir = root.appendingPathComponent("EditionB", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var book = try makeSilenceBook(folder: bookDir, title: "Same", author: "Ann")
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        let dest = settings.plannedOutputs(for: [book])[book.id]!
        try Data("OWNED-DEST".utf8).write(to: dest)
        book.existingM4BURL = dest
        OutputAssociation.record(dest, inBookFolder: book.folder)

        let sentinel = Data("RACE-OWNED-SENTINEL".utf8)
        let injected = StartedFlag()
        let results = try await M4BExporter(bitrate: 48_000).exportAll(books: [book], settings: settings) { progress in
            guard progress.fraction >= 0.92, progress.fraction < 1.0, !injected.isSet else { return }
            injected.mark()
            try? sentinel.write(to: dest)
        }

        XCTAssertTrue(injected.isSet)
        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].outcome.isPublished)
        XCTAssertEqual(try Data(contentsOf: dest), sentinel)
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

    func testWaitReturnsPromptlyWhenCancelled() throws {
        let token = EncodeCancellation()
        token.cancel()

        let semaphore = DispatchSemaphore(value: 0)
        let semStart = Date()
        do {
            _ = try M4BExporter.wait(semaphore, timeout: 2, cancellation: token, slice: 0.05)
            XCTFail("expected cancelled")
        } catch let error as BinderError {
            guard case .cancelled = error else { return XCTFail("\(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(semStart), 0.3)

        let group = DispatchGroup()
        group.enter()
        let groupStart = Date()
        do {
            _ = try M4BExporter.wait(group, timeout: 2, cancellation: token, slice: 0.05)
            XCTFail("expected cancelled")
        } catch let error as BinderError {
            guard case .cancelled = error else { return XCTFail("\(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(groupStart), 0.3)

        let live = EncodeCancellation()
        let liveSem = DispatchSemaphore(value: 0)
        let liveStart = Date()
        let liveError = ErrorBox()
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try M4BExporter.wait(liveSem, timeout: 2, cancellation: live, slice: 0.05)
            } catch {
                liveError.value = error
            }
            done.leave()
        }
        live.cancel()
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertLessThan(Date().timeIntervalSince(liveStart), 0.3)
        guard case .cancelled = liveError.value as? BinderError else {
            return XCTFail("expected cancelled, got \(String(describing: liveError.value))")
        }
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

        let results = try await task.value
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].bookID, book.id)
        XCTAssertEqual(results[0].outcome, .cancelled)
        XCTAssertFalse(results[0].outcome.isPublished)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testExportAllKeepsCreatedResultsWhenLaterBookCancelled() async throws {
        let root = try TestSupport.tempDir("export-all-keep-created")
        defer { try? FileManager.default.removeItem(at: root) }
        let book1Dir = root.appendingPathComponent("Book1", isDirectory: true)
        let book2Dir = root.appendingPathComponent("Book2", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: book1Dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: book2Dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let book1 = try makeSilenceBook(
            folder: book1Dir,
            title: "KeepCreated",
            author: "A",
            seconds: 1,
            chapterCount: 1
        )
        let book2 = try makeSilenceBook(
            folder: book2Dir,
            title: "CancelSecond",
            author: "A",
            seconds: 5,
            chapterCount: 12
        )
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        let plan = settings.plannedOutputs(for: [book1, book2])
        let dest1 = plan[book1.id]!
        let dest2 = plan[book2.id]!
        let secondEncoding = StartedFlag()

        let task = Task {
            try await M4BExporter(bitrate: 48_000).exportAll(
                books: [book1, book2],
                settings: settings
            ) { progress in
                if progress.index == 2 && progress.detail.contains("Encoding") {
                    secondEncoding.mark()
                }
            }
        }
        await waitForFlag(secondEncoding, timeout: 30)
        XCTAssertTrue(secondEncoding.isSet, "book 2 should have started encoding")
        task.cancel()

        let results = try await task.value
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].bookID, book1.id)
        XCTAssertEqual(results[0].outcome, .created)
        XCTAssertTrue(results[0].outcome.isPublished)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest1.path))
        XCTAssertEqual(results[1].bookID, book2.id)
        XCTAssertEqual(results[1].outcome, .cancelled)
        XCTAssertFalse(results[1].outcome.isPublished)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest2.path))
    }

    func testTaggerApplyCancelLeavesOriginalUnchanged() throws {
        let dir = try TestSupport.tempDir("tag-cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("big.m4a")
        let original = largeTaggableMP4()
        XCTAssertGreaterThan(original.count, MP4AtomIO.ioChunkSize)
        try original.write(to: url)

        let token = EncodeCancellation()
        token.cancel()
        do {
            try MP4AudiobookTagger.apply(
                to: url,
                tags: AudiobookTags(title: "T", author: "A"),
                chapters: [],
                cancellation: token
            )
            XCTFail("expected cancelled")
        } catch let error as BinderError {
            guard case .cancelled = error else { return XCTFail("\(error)") }
        }

        XCTAssertEqual(try Data(contentsOf: url), original)
        let leftovers = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(leftovers.map(\.lastPathComponent), ["big.m4a"])
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

    func testExportLateSourceReplacementDoesNotUpdateSidecarAndDeniesCleanup() async throws {
        let dir = try TestSupport.tempDir("source-late-capture")
        defer { try? FileManager.default.removeItem(at: dir) }
        let book = try makeSilenceBook(folder: dir, title: "LateCapture", author: "A")
        let source = book.chapters[0].url
        let dest = dir.appendingPathComponent("out.m4b")
        let original = try Data(contentsOf: source)
        let originalHash = sha256Hex(original)
        let originalSize = Int64(original.count)
        let replacement = Data(repeating: 0xAB, count: original.count + 32)
        XCTAssertNotEqual(replacement.count, original.count)

        let replaced = StartedFlag()
        try await M4BExporter(bitrate: 48_000).export(book: book, to: dest, overwrite: true) { fraction, _ in
            guard fraction >= 0.92, fraction < 1.0, !replaced.isSet else { return }
            replaced.mark()
            try? replacement.write(to: source)
        }

        XCTAssertTrue(replaced.isSet, "replacement must happen after encode and before source persist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(try Data(contentsOf: source), replacement)

        let entries = try XCTUnwrap(SourceAssociation.load(inBookFolder: dir))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].fileSize, originalSize)
        XCTAssertEqual(entries[0].sha256, originalHash)
        XCTAssertNotEqual(entries[0].fileSize, Int64(replacement.count))
        XCTAssertNotEqual(entries[0].sha256, sha256Hex(replacement))

        var bound = book
        bound.existingM4BURL = dest
        let inspection = await M4BInspector.inspect(dest, bookID: book.id)
        let auth = SourceCleanup.authorization(book: bound, inspection: inspection, isBuilding: false)
        XCTAssertFalse(auth.allowed, "replacement bytes must not be authorized for cleanup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
    }

    func testCleanupDeniedWhenSourceEditedInPlaceSameSizeRestoredMtime() throws {
        let fixture = try makeRecordedCleanupFixture()
        defer { fixture.tearDown() }

        let original = try Data(contentsOf: fixture.sourceA)
        let edited = Data(repeating: 0xAB, count: original.count)
        XCTAssertEqual(edited.count, original.count)
        XCTAssertNotEqual(edited, original)
        try overwriteInPlaceKeepingMtime(at: fixture.sourceA, with: edited)

        let live = try XCTUnwrap(FileIdentity.readResolved(from: fixture.sourceA))
        let recorded = try XCTUnwrap(SourceAssociation.load(inBookFolder: fixture.dir)?.first)
        XCTAssertTrue(live.matchesCaptured(recorded), "identity-only compare must still match after mtime restore")
        XCTAssertNotEqual(recorded.sha256, sha256Hex(edited))

        let auth = SourceCleanup.authorization(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertFalse(auth.allowed, "same-size in-place edit with restored mtime must fail closed on digest")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceB.path))
    }

    func testCleanupDeniedWhenReplacedDestHasFreshMatchingInspection() throws {
        let fixture = try makeRecordedCleanupFixture()
        defer { fixture.tearDown() }

        try Data(repeating: 0xCD, count: 64).write(to: fixture.dest)
        let fresh = M4BInspection.capturingIdentity(
            url: fixture.dest,
            duration: 30,
            chapters: [
                ChapterMark(start: 0, duration: 10, title: "One"),
                ChapterMark(start: 10, duration: 20, title: "Two")
            ],
            bookID: fixture.book.id
        )
        XCTAssertTrue(fresh.identityVerified)
        XCTAssertTrue(
            ChapterCompare.summary(
                original: fixture.book.chapters,
                bound: M4BInspector.playableChapters(from: fresh),
                boundDuration: fresh.duration
            ).allMatch,
            "chapter durations of the replacement must look like a match"
        )

        let auth = SourceCleanup.authorization(
            book: fixture.book,
            inspection: fresh,
            isBuilding: false
        )
        XCTAssertFalse(auth.allowed, "fresh inspection of a replaced dest must not authorize cleanup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceB.path))
    }

    func testExportRejectsSourceSwapBetweenCaptureAndSnapshot() async throws {
        let dir = try TestSupport.tempDir("source-swap-before-snapshot")
        defer { try? FileManager.default.removeItem(at: dir) }
        let book = try makeSilenceBook(folder: dir, title: "SwapCapture", author: "A")
        let source = book.chapters[0].url
        let dest = dir.appendingPathComponent("out.m4b")
        let original = try Data(contentsOf: source)
        let originalHash = sha256Hex(original)
        XCTAssertFalse(original.isEmpty)

        let swapped = StartedFlag()
        var exporter = M4BExporter(bitrate: 48_000)
        exporter.afterSourceCapture = {
            swapped.mark()
            try? TestSupport.writeSilenceWAV(to: source, seconds: 2)
        }

        var exportError: Error?
        do {
            try await exporter.export(book: book, to: dest, overwrite: true)
        } catch {
            exportError = error
        }

        XCTAssertTrue(swapped.isSet, "hook must replace the live source after capture")
        try original.write(to: source)
        XCTAssertEqual(try Data(contentsOf: source), original, "restored original source bytes must still be present")

        let destPublished = FileManager.default.fileExists(atPath: dest.path)
        let sidecar = SourceAssociation.loadDocument(inBookFolder: dir)
        var bound = book
        bound.existingM4BURL = destPublished ? dest : nil
        let inspection: M4BInspection
        if destPublished {
            inspection = await M4BInspector.inspect(dest, bookID: book.id)
        } else {
            inspection = M4BInspection.capturingIdentity(url: dest, duration: 1, chapters: [], bookID: book.id)
        }
        let auth = SourceCleanup.authorization(book: bound, inspection: inspection, isBuilding: false)

        if destPublished {
            XCTAssertFalse(
                auth.allowed,
                "cleanup of the restored original must be denied if dest was published after a swapped encode"
            )
        } else {
            XCTAssertNotNil(exportError, "export must refuse to certify a swapped source")
        }
        if let sidecar {
            XCTAssertFalse(
                auth.allowed,
                "sidecar must not authorize cleanup of the restored original after a swapped encode"
            )
            if sidecar.sources.contains(where: { $0.sha256 == originalHash }) {
                XCTAssertFalse(
                    auth.allowed,
                    "must not claim the restored original was the consumed input if B was read"
                )
            }
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCleanupDeniedWhenDestEditedInPlaceSameSizeRestoredMtime() throws {
        let fixture = try makeRecordedCleanupFixture()
        defer { fixture.tearDown() }

        let originalDest = try Data(contentsOf: fixture.dest)
        let originalSourceA = try Data(contentsOf: fixture.sourceA)
        let originalSourceB = try Data(contentsOf: fixture.sourceB)
        let edited = Data(repeating: 0xEF, count: originalDest.count)
        XCTAssertEqual(edited.count, originalDest.count)
        XCTAssertNotEqual(edited, originalDest)
        try overwriteInPlaceKeepingMtime(at: fixture.dest, with: edited)

        let document = try XCTUnwrap(SourceAssociation.loadDocument(inBookFolder: fixture.dir))
        let recordedDest = try XCTUnwrap(document.destinationIdentity)
        let liveDest = try XCTUnwrap(FileIdentity.read(from: fixture.dest))
        XCTAssertTrue(
            liveDest.matchesRecordedIdentity(recordedDest),
            "identity-only dest compare may still match after same-size in-place edit"
        )

        let fresh = M4BInspection.capturingIdentity(
            url: fixture.dest,
            duration: 30,
            chapters: [
                ChapterMark(start: 0, duration: 10, title: "One"),
                ChapterMark(start: 10, duration: 20, title: "Two")
            ],
            bookID: fixture.book.id
        )
        XCTAssertTrue(fresh.identityVerified)
        XCTAssertTrue(
            ChapterCompare.summary(
                original: fixture.book.chapters,
                bound: M4BInspector.playableChapters(from: fresh),
                boundDuration: fresh.duration
            ).allMatch,
            "chapter timings of the mutated dest must look like a match"
        )

        let auth = SourceCleanup.authorization(
            book: fixture.book,
            inspection: fresh,
            isBuilding: false
        )
        XCTAssertFalse(auth.allowed, "same-size in-place dest edit with restored mtime must fail closed on dest digest")
        XCTAssertEqual(try Data(contentsOf: fixture.dest), edited)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceA), originalSourceA)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceB), originalSourceB)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.dest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceB.path))
    }

    func testCleanupPerformDeniedWhenDestEditedInPlaceSameSizeRestoredMtime() throws {
        let fixture = try makeRecordedCleanupFixture()
        defer { fixture.tearDown() }

        let originalDest = try Data(contentsOf: fixture.dest)
        let originalSourceA = try Data(contentsOf: fixture.sourceA)
        let originalSourceB = try Data(contentsOf: fixture.sourceB)
        let edited = Data(repeating: 0xCD, count: originalDest.count)
        XCTAssertEqual(edited.count, originalDest.count)
        XCTAssertNotEqual(edited, originalDest)

        let auth = SourceCleanup.authorization(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertTrue(auth.allowed, "authorization must succeed on the original dest")

        let destTokenBefore = try XCTUnwrap(SourceCleanup.destGeneration(of: fixture.dest))
        let mutated = StartedFlag()
        SourceCleanup.testingBeforeEachDeletion = {
            guard !mutated.isSet else { return }
            do {
                try self.overwriteInPlaceKeepingMtime(at: fixture.dest, with: edited)
                mutated.mark()
            } catch {
                XCTFail("in-place dest overwrite failed: \(error)")
            }
        }
        defer { SourceCleanup.testingBeforeEachDeletion = nil }

        let result = SourceCleanup.perform(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )

        XCTAssertTrue(mutated.isSet, "hook must mutate dest after authorization and before trash")
        XCTAssertEqual(
            SourceCleanup.destGeneration(of: fixture.dest),
            destTokenBefore,
            "same-size restored mtime must keep the dest generation token"
        )
        XCTAssertFalse(result.didFinish)
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertFalse(result.remaining.isEmpty)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(try Data(contentsOf: fixture.dest), edited)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceA), originalSourceA)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceB), originalSourceB)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.dest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceB.path))
    }

    func testCleanupPerformTrashesHeldVerifiedSourceNotReplacementAtOriginalPath() throws {
        let fixture = try makeRecordedCleanupFixture()
        defer { fixture.tearDown() }

        let originalA = try Data(contentsOf: fixture.sourceA)
        let originalDigest = sha256Hex(originalA)
        let planted = Data(repeating: 0xAB, count: 24)
        XCTAssertNotEqual(planted, originalA)

        let plantedAfterVerify = StartedFlag()
        SourceCleanup.testingBeforeTrashHeld = { original, held in
            XCTAssertEqual(
                held.deletingLastPathComponent().standardizedFileURL.path,
                original.deletingLastPathComponent().standardizedFileURL.path
            )
            XCTAssertTrue(held.lastPathComponent.hasPrefix("."))
            XCTAssertFalse(held.lastPathComponent.hasPrefix(".\(original.lastPathComponent)"))
            XCTAssertNotEqual(held.lastPathComponent, original.lastPathComponent)
            XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: original.path),
                "hold must leave the original path vacant so a replacement can appear"
            )
            guard SourceCleanup.refersToSameFile(original, fixture.sourceA) else { return }
            do {
                try planted.write(to: original)
                plantedAfterVerify.mark()
            } catch {
                XCTFail("planting replacement at original path failed: \(error)")
            }
        }
        defer {
            SourceCleanup.testingBeforeTrashHeld = nil
            SourceCleanup.testingAfterHold = nil
        }

        let result = SourceCleanup.perform(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )

        XCTAssertTrue(plantedAfterVerify.isSet, "hook must plant after hold+verify and before trash")
        XCTAssertTrue(result.didFinish)
        XCTAssertNil(result.error)
        XCTAssertTrue(result.moved.contains { SourceCleanup.refersToSameFile($0, fixture.sourceA) })
        XCTAssertTrue(result.moved.contains { SourceCleanup.refersToSameFile($0, fixture.sourceB) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceA.path))
        XCTAssertEqual(try Data(contentsOf: fixture.sourceA), planted)
        XCTAssertNotEqual(sha256Hex(try Data(contentsOf: fixture.sourceA)), originalDigest)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.sourceB.path),
            "the verified original with no replacement must be gone"
        )
    }

    func testCleanupPerformRestoresOriginalWhenHeldSourceVerifyFails() throws {
        let fixture = try makeRecordedCleanupFixture()
        defer { fixture.tearDown() }

        let originalB = try Data(contentsOf: fixture.sourceB)
        let mutatedHold = StartedFlag()
        SourceCleanup.testingAfterHold = { original, held in
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: original.path),
                "source must be off the original path before held verify"
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
            XCTAssertEqual(
                held.deletingLastPathComponent().standardizedFileURL.path,
                original.deletingLastPathComponent().standardizedFileURL.path
            )
            XCTAssertTrue(held.lastPathComponent.hasPrefix("."))
            XCTAssertFalse(held.lastPathComponent.hasPrefix(".\(original.lastPathComponent)"))
            do {
                try Data(repeating: 0xFF, count: 16).write(to: held)
                mutatedHold.mark()
            } catch {
                XCTFail("mutating held source failed: \(error)")
            }
        }
        defer {
            SourceCleanup.testingAfterHold = nil
            SourceCleanup.testingBeforeTrashHeld = nil
        }

        let result = SourceCleanup.perform(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )

        XCTAssertTrue(mutatedHold.isSet, "hook must mutate the held file before verify")
        XCTAssertFalse(result.didFinish)
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertFalse(result.remaining.isEmpty)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.sourceA.path),
            "failed held verify must restore the original path"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceB.path))
        XCTAssertEqual(try Data(contentsOf: fixture.sourceB), originalB)
    }

    func testCleanupPerformReportsStrandedHoldWhenReplacementOccupiesOriginalAndHeldVerifyFails() throws {
        let fixture = try makeRecordedCleanupFixture()
        defer { fixture.tearDown() }

        let originalA = try Data(contentsOf: fixture.sourceA)
        let planted = Data(repeating: 0xCD, count: 24)
        XCTAssertNotEqual(planted, originalA)

        var heldURL: URL?
        let plantedAndMutated = StartedFlag()
        SourceCleanup.testingAfterHold = { original, held in
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: original.path),
                "source must be off the original path before held verify"
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
            do {
                try planted.write(to: original)
                try Data(repeating: 0xFF, count: 16).write(to: held)
                heldURL = held
                plantedAndMutated.mark()
            } catch {
                XCTFail("planting replacement and mutating hold failed: \(error)")
            }
        }
        defer {
            SourceCleanup.testingAfterHold = nil
            SourceCleanup.testingBeforeTrashHeld = nil
        }

        let result = SourceCleanup.perform(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )

        let hold = try XCTUnwrap(heldURL, "hook must capture the hold URL")
        XCTAssertTrue(plantedAndMutated.isSet, "hook must plant a replacement and mutate the hold")
        XCTAssertFalse(result.didFinish)
        let error = try XCTUnwrap(result.error)
        XCTAssertFalse(error.isEmpty)
        XCTAssertTrue(
            error.contains(hold.path),
            "stranded restore must name the hold path: \(error)"
        )
        XCTAssertEqual(try Data(contentsOf: fixture.sourceA), planted)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: hold.path),
            "stranded hold must remain so it can be found from the error"
        )
        XCTAssertFalse(result.moved.contains { SourceCleanup.refersToSameFile($0, fixture.sourceA) })
        XCTAssertFalse(
            result.remaining.contains { SourceCleanup.refersToSameFile($0, fixture.sourceA) },
            "remaining must not invite retry-trashing the replacement at the original path"
        )
        XCTAssertTrue(
            result.remaining.contains { SourceCleanup.refersToSameFile($0, fixture.sourceB) },
            "other unprocessed sources stay in remaining"
        )
    }

    func testCleanupPerformRestoresOriginalWhenDestUnauthorizedAfterHeldVerify() throws {
        let fixture = try makeRecordedCleanupFixture()
        defer { fixture.tearDown() }

        let originalDest = try Data(contentsOf: fixture.dest)
        let originalSourceA = try Data(contentsOf: fixture.sourceA)
        let originalSourceB = try Data(contentsOf: fixture.sourceB)
        let edited = Data(repeating: 0xBE, count: originalDest.count)
        XCTAssertEqual(edited.count, originalDest.count)
        XCTAssertNotEqual(edited, originalDest)

        let destTokenBefore = try XCTUnwrap(SourceCleanup.destGeneration(of: fixture.dest))
        let mutatedDest = StartedFlag()
        SourceCleanup.testingBeforeTrashHeld = { original, held in
            XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: original.path),
                "source must still be on the hold when dest is mutated"
            )
            guard SourceCleanup.refersToSameFile(original, fixture.sourceA) else { return }
            do {
                try self.overwriteInPlaceKeepingMtime(at: fixture.dest, with: edited)
                mutatedDest.mark()
            } catch {
                XCTFail("in-place dest overwrite failed: \(error)")
            }
        }
        defer {
            SourceCleanup.testingBeforeTrashHeld = nil
            SourceCleanup.testingAfterHold = nil
        }

        let result = SourceCleanup.perform(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )

        XCTAssertTrue(mutatedDest.isSet, "hook must mutate dest after hold+verify and before trash")
        XCTAssertEqual(
            SourceCleanup.destGeneration(of: fixture.dest),
            destTokenBefore,
            "same-size restored mtime must keep the dest generation token"
        )
        XCTAssertFalse(result.didFinish)
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertFalse(result.remaining.isEmpty)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(try Data(contentsOf: fixture.dest), edited)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceA), originalSourceA)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceB), originalSourceB)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.dest.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.sourceA.path),
            "failed dest recheck must restore the held source to the original path"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceB.path))
    }

    func testCleanupPerformDoesNotTrashHoldReplacedAfterDestRecheck() throws {
        let fixture = try makeRecordedCleanupFixture()
        defer { fixture.tearDown() }

        let originalA = try Data(contentsOf: fixture.sourceA)
        let planted = Data(repeating: 0xCA, count: 24)
        XCTAssertNotEqual(planted, originalA)

        var heldURL: URL?
        let swappedHold = StartedFlag()
        SourceCleanup.testingAfterDestRecheck = { original, held in
            XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: original.path),
                "original path must stay vacant while dest is rechecked"
            )
            guard SourceCleanup.refersToSameFile(original, fixture.sourceA) else { return }
            do {
                try FileManager.default.removeItem(at: held)
                try planted.write(to: held)
                heldURL = held
                swappedHold.mark()
            } catch {
                XCTFail("replacing hold after dest recheck failed: \(error)")
            }
        }
        defer {
            SourceCleanup.testingAfterDestRecheck = nil
            SourceCleanup.testingBeforeTrashHeld = nil
            SourceCleanup.testingAfterHold = nil
        }

        let result = SourceCleanup.perform(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )

        let hold = try XCTUnwrap(heldURL, "hook must capture the hold URL")
        XCTAssertTrue(swappedHold.isSet, "hook must replace the hold after dest recheck")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: hold.path),
            "planted hold bytes must not be trashed"
        )
        XCTAssertEqual(try Data(contentsOf: hold), planted)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.sourceA.path),
            "must not restore the mismatched hold onto the original path"
        )

        let originalMoved = result.moved.contains { SourceCleanup.refersToSameFile($0, fixture.sourceA) }
        if originalMoved {
            XCTAssertFalse(
                result.remaining.contains { SourceCleanup.refersToSameFile($0, fixture.sourceA) },
                "exclusive trash of the verified bytes lists the original as moved"
            )
            XCTAssertTrue(
                result.moved.contains { SourceCleanup.refersToSameFile($0, fixture.sourceB) }
            )
            XCTAssertTrue(result.didFinish)
            XCTAssertNil(result.error)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceB.path))
        } else {
            XCTAssertFalse(result.didFinish, "must not finish as if the verified original was cleaned")
            XCTAssertTrue(
                result.remaining.contains { SourceCleanup.refersToSameFile($0, fixture.sourceA) },
                "vacant original stays in remaining"
            )
            let error = try XCTUnwrap(result.error)
            XCTAssertFalse(error.isEmpty)
        }
    }

    func testCleanupPerformTrashesRenamedHoldInodeNotReplacementAtHoldPath() throws {
        let fixture = try makeRecordedCleanupFixture()
        defer { fixture.tearDown() }

        let originalA = try Data(contentsOf: fixture.sourceA)
        let planted = Data(repeating: 0xDD, count: 24)
        XCTAssertNotEqual(planted, originalA)

        var holdPath: URL?
        var relocatedURL: URL?
        let renamedAndPlanted = StartedFlag()
        SourceCleanup.testingAfterDestRecheck = { original, held in
            XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: original.path),
                "original path must stay vacant while dest is rechecked"
            )
            guard SourceCleanup.refersToSameFile(original, fixture.sourceA) else { return }
            let relocated = held.deletingLastPathComponent()
                .appendingPathComponent("\(held.lastPathComponent).away")
            do {
                try FileManager.default.moveItem(at: held, to: relocated)
                try planted.write(to: held)
                holdPath = held
                relocatedURL = relocated
                renamedAndPlanted.mark()
            } catch {
                XCTFail("renaming hold and planting replacement failed: \(error)")
            }
        }
        defer {
            SourceCleanup.testingAfterDestRecheck = nil
            SourceCleanup.testingBeforeTrashHeld = nil
            SourceCleanup.testingAfterHold = nil
        }

        let result = SourceCleanup.perform(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )

        let hold = try XCTUnwrap(holdPath, "hook must capture the hold URL")
        let relocated = try XCTUnwrap(relocatedURL, "hook must capture the renamed hold URL")
        XCTAssertTrue(renamedAndPlanted.isSet, "hook must rename the hold and plant a replacement")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: hold.path),
            "planted replacement at the old hold pathname must survive"
        )
        XCTAssertEqual(try Data(contentsOf: hold), planted)

        let verifiedStillPresent = FileManager.default.fileExists(atPath: relocated.path)
        if verifiedStillPresent {
            XCTAssertFalse(
                result.moved.contains { SourceCleanup.refersToSameFile($0, fixture.sourceA) },
                "must not list the original as moved unless the verified inode was unlinked"
            )
            XCTAssertFalse(result.didFinish, "must not finish while the verified inode remains linked")
            XCTAssertNotNil(result.error)
            XCTAssertTrue(
                result.remaining.contains { SourceCleanup.refersToSameFile($0, fixture.sourceA) },
                "vacant original stays in remaining when the verified inode was not unlinked"
            )
        } else {
            XCTAssertTrue(
                result.moved.contains { SourceCleanup.refersToSameFile($0, fixture.sourceA) },
                "verified inode was unlinked, so the original must be listed as moved"
            )
            XCTAssertFalse(
                result.remaining.contains { SourceCleanup.refersToSameFile($0, fixture.sourceA) },
                "successfully unlinked original must leave remaining"
            )
            XCTAssertTrue(result.didFinish)
            XCTAssertNil(result.error)
            XCTAssertTrue(result.moved.contains { SourceCleanup.refersToSameFile($0, fixture.sourceB) })
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceB.path))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.sourceA.path),
            "must not restore a mismatched hold onto the original chapter path"
        )
    }

    func testCleanupPerformDoesNotReportMovedWhenHoldReplacementLeavesVerifiedInode() throws {
        let fixture = try makeRecordedCleanupFixture()
        defer { fixture.tearDown() }

        let originalA = try Data(contentsOf: fixture.sourceA)
        let planted = Data(repeating: 0x31, count: 24)
        XCTAssertNotEqual(planted, originalA)

        var holdPath: URL?
        var asideURL: URL?
        let swappedHold = StartedFlag()
        SourceCleanup.testingAfterDestRecheck = { original, held in
            XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: original.path),
                "original path must stay vacant while dest is rechecked"
            )
            guard SourceCleanup.refersToSameFile(original, fixture.sourceA) else { return }
            let aside = held.deletingLastPathComponent()
                .appendingPathComponent("\(held.lastPathComponent).aside")
            do {
                try FileManager.default.moveItem(at: held, to: aside)
                try planted.write(to: held)
                holdPath = held
                asideURL = aside
                swappedHold.mark()
            } catch {
                XCTFail("renaming hold and planting replacement failed: \(error)")
            }
        }
        defer {
            SourceCleanup.testingAfterDestRecheck = nil
            SourceCleanup.testingBeforeTrashHeld = nil
            SourceCleanup.testingAfterHold = nil
            SourceCleanup.testingDidTrash = nil
        }

        let result = SourceCleanup.perform(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )

        let hold = try XCTUnwrap(holdPath, "hook must capture the hold URL")
        let aside = try XCTUnwrap(asideURL, "hook must capture the aside URL")
        XCTAssertTrue(swappedHold.isSet, "hook must rename the hold and plant a replacement")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: hold.path),
            "planted replacement at the old hold pathname must survive"
        )
        XCTAssertEqual(try Data(contentsOf: hold), planted)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: aside.path),
            "verified inode must remain at the aside path when unlink would hit the replacement"
        )
        XCTAssertEqual(try Data(contentsOf: aside), originalA)
        XCTAssertFalse(
            result.moved.contains { SourceCleanup.refersToSameFile($0, fixture.sourceA) },
            "exclusive trash is a copy; do not report moved while the verified inode is still linked"
        )
        XCTAssertFalse(result.didFinish)
        let error = try XCTUnwrap(result.error)
        XCTAssertFalse(error.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.sourceA.path),
            "must not restore the replacement or the aside onto the original chapter path"
        )
        XCTAssertTrue(
            result.remaining.contains { SourceCleanup.refersToSameFile($0, fixture.sourceA) },
            "vacant original stays in remaining"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceB.path))
        XCTAssertTrue(
            result.remaining.contains { SourceCleanup.refersToSameFile($0, fixture.sourceB) }
        )
        XCTAssertFalse(
            result.moved.contains { SourceCleanup.refersToSameFile($0, fixture.sourceB) }
        )
    }

    func testCleanupPerformExclusiveTrashUsesOriginalChapterBasename() throws {
        let fixture = try makeRecordedCleanupFixture()
        defer { fixture.tearDown() }

        let namedA = SourceCleanup.exclusiveMaterializeFileName(from: fixture.sourceA)
        let namedB = SourceCleanup.exclusiveMaterializeFileName(from: fixture.sourceB)
        XCTAssertEqual(namedA, fixture.sourceA.lastPathComponent)
        XCTAssertEqual(namedB, fixture.sourceB.lastPathComponent)
        XCTAssertEqual(namedA, "01.mp3")
        XCTAssertEqual((namedA as NSString).pathExtension, "mp3")
        XCTAssertEqual((namedB as NSString).pathExtension, "mp3")
        XCTAssertFalse(namedA.hasPrefix("."))
        XCTAssertNil(UUID(uuidString: namedA))
        XCTAssertNil(UUID(uuidString: namedA.hasPrefix(".") ? String(namedA.dropFirst()) : namedA))

        let longName = String(repeating: "a", count: 300) + ".m4a"
        let truncated = SourceCleanup.exclusiveMaterializeFileName(
            from: URL(fileURLWithPath: "/tmp/\(longName)")
        )
        XCTAssertLessThanOrEqual(truncated.utf8.count, SourceAssociation.maxSnapshotComponentBytes)
        XCTAssertEqual((truncated as NSString).pathExtension, "m4a")
        XCTAssertTrue(truncated.hasSuffix(".m4a"))
        XCTAssertNotEqual(truncated, longName)
        XCTAssertNil(UUID(uuidString: truncated))

        let helperDir = try TestSupport.tempDir("exclusive-materialize-name")
        defer { try? FileManager.default.removeItem(at: helperDir) }
        let original = helperDir.appendingPathComponent("Chapter 01.mp3")
        let payload = Data("exclusive-name".utf8)
        try payload.write(to: original)
        let handle = try FileHandle(forReadingFrom: original)
        defer { try? handle.close() }
        let copy = try SourceCleanup.materializeExclusiveCopy(
            from: handle,
            original: original,
            inDirectory: helperDir
        )
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        XCTAssertEqual(copy.lastPathComponent, original.lastPathComponent)
        XCTAssertEqual(copy.pathExtension, "mp3")
        XCTAssertTrue(copy.deletingLastPathComponent().lastPathComponent.hasPrefix("."))
        XCTAssertNotEqual(copy.lastPathComponent, copy.deletingLastPathComponent().lastPathComponent)
        XCTAssertNotNil(
            UUID(uuidString: String(copy.deletingLastPathComponent().lastPathComponent.dropFirst()))
        )
        XCTAssertEqual(try Data(contentsOf: copy), payload)

        var trashed: [URL] = []
        SourceCleanup.testingDidTrash = { url in
            trashed.append(url)
        }
        defer { SourceCleanup.testingDidTrash = nil }

        let result = SourceCleanup.perform(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertTrue(result.didFinish)
        XCTAssertNil(result.error)
        XCTAssertEqual(Set(trashed.map(\.lastPathComponent)), ["01.mp3", "02.mp3"])
        XCTAssertTrue(trashed.allSatisfy { $0.pathExtension == "mp3" })
        XCTAssertTrue(
            trashed.allSatisfy { $0.deletingLastPathComponent().lastPathComponent.hasPrefix(".") }
        )
        XCTAssertTrue(
            trashed.allSatisfy {
                UUID(uuidString: String($0.deletingLastPathComponent().lastPathComponent.dropFirst())) != nil
            }
        )
        XCTAssertFalse(trashed.contains { UUID(uuidString: $0.lastPathComponent) != nil })
        XCTAssertFalse(trashed.contains { UUID(uuidString: String($0.lastPathComponent.dropFirst())) != nil })
    }

    func testCleanupPerformDoesNotTrashReplacedExclusiveCopy() throws {
        let fixture = try makeRecordedCleanupFixture()
        defer { fixture.tearDown() }

        let planted = Data(repeating: 0xCD, count: 24)
        var plantedPath: URL?
        let plantedFlag = StartedFlag()
        SourceCleanup.testingAfterExclusiveCopy = { _, exclusive in
            guard plantedPath == nil else { return }
            plantedPath = exclusive
            do {
                try planted.write(to: exclusive, options: .atomic)
                plantedFlag.mark()
            } catch {
                XCTFail("planting exclusive replacement failed: \(error)")
            }
        }
        defer { SourceCleanup.testingAfterExclusiveCopy = nil }

        let result = SourceCleanup.perform(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )

        XCTAssertTrue(plantedFlag.isSet, "hook must replace the exclusive path after materialize")
        let exclusive = try XCTUnwrap(plantedPath)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: exclusive.path),
            "replacement at the exclusive pathname must survive path-based trash"
        )
        XCTAssertEqual(try Data(contentsOf: exclusive), planted)
        XCTAssertFalse(
            result.moved.contains { SourceCleanup.refersToSameFile($0, fixture.sourceA) },
            "must not report the original as moved if the exclusive path was swapped"
        )
        _ = result
    }

    func testCleanupPerformDoesNotRestorePlantedHoldWhenDestUnauthorizedAfterRenameAway() throws {
        let fixture = try makeRecordedCleanupFixture()
        defer { fixture.tearDown() }

        let originalDest = try Data(contentsOf: fixture.dest)
        let originalSourceA = try Data(contentsOf: fixture.sourceA)
        let originalSourceB = try Data(contentsOf: fixture.sourceB)
        let planted = Data(repeating: 0xEE, count: 24)
        XCTAssertNotEqual(planted, originalSourceA)
        let edited = Data(repeating: 0xBE, count: originalDest.count)
        XCTAssertEqual(edited.count, originalDest.count)
        XCTAssertNotEqual(edited, originalDest)

        var holdPath: URL?
        var relocatedURL: URL?
        let swappedAndMutated = StartedFlag()
        SourceCleanup.testingBeforeTrashHeld = { original, held in
            XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: original.path),
                "source must still be off the original path when dest is mutated"
            )
            guard SourceCleanup.refersToSameFile(original, fixture.sourceA) else { return }
            let relocated = held.deletingLastPathComponent()
                .appendingPathComponent("\(held.lastPathComponent).away")
            do {
                try FileManager.default.moveItem(at: held, to: relocated)
                try planted.write(to: held)
                try self.overwriteInPlaceKeepingMtime(at: fixture.dest, with: edited)
                holdPath = held
                relocatedURL = relocated
                swappedAndMutated.mark()
            } catch {
                XCTFail("rename-away, plant, and dest mutate failed: \(error)")
            }
        }
        defer {
            SourceCleanup.testingBeforeTrashHeld = nil
            SourceCleanup.testingAfterHold = nil
            SourceCleanup.testingAfterDestRecheck = nil
        }

        let result = SourceCleanup.perform(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )

        let hold = try XCTUnwrap(holdPath, "hook must capture the hold URL")
        let relocated = try XCTUnwrap(relocatedURL, "hook must capture the renamed hold URL")
        XCTAssertTrue(swappedAndMutated.isSet, "hook must swap the hold and mutate dest")
        XCTAssertFalse(result.didFinish)
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertFalse(result.remaining.isEmpty)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(try Data(contentsOf: fixture.dest), edited)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: hold.path),
            "planted replacement at the old hold pathname must survive"
        )
        XCTAssertEqual(try Data(contentsOf: hold), planted)
        XCTAssertFalse(
            (try? Data(contentsOf: fixture.sourceA)) == planted,
            "must not move the planted hold replacement onto the original chapter path"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.sourceA.path),
            "verified inode must be restored from its current path"
        )
        XCTAssertEqual(try Data(contentsOf: fixture.sourceA), originalSourceA)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: relocated.path),
            "restored inode must leave the relocated hold path"
        )
        XCTAssertEqual(try Data(contentsOf: fixture.sourceB), originalSourceB)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceB.path))
        XCTAssertTrue(
            result.remaining.contains { SourceCleanup.refersToSameFile($0, fixture.sourceA) },
            "restored original stays in remaining"
        )
    }

    func testCleanupDeniedWhenDestDigestMissing() throws {
        let fixture = try makeRecordedCleanupFixture()
        defer { fixture.tearDown() }

        let originalDest = try Data(contentsOf: fixture.dest)
        let originalSourceA = try Data(contentsOf: fixture.sourceA)
        let originalSourceB = try Data(contentsOf: fixture.sourceB)

        let sidecar = SourceAssociation.sidecarURL(inBookFolder: fixture.dir)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        object.removeValue(forKey: "destinationSHA256")
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: sidecar)

        let document = try XCTUnwrap(SourceAssociation.loadDocument(inBookFolder: fixture.dir))
        XCTAssertTrue(document.destinationSHA256 == nil || document.destinationSHA256?.isEmpty == true)
        XCTAssertNotNil(document.destinationIdentity)
        XCTAssertFalse(document.sources.isEmpty)

        let auth = SourceCleanup.authorization(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertFalse(auth.allowed, "identity-only dest match is not enough without a dest digest")
        XCTAssertEqual(try Data(contentsOf: fixture.dest), originalDest)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceA), originalSourceA)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceB), originalSourceB)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.dest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceB.path))
    }

    func testCleanupAuthorizationCancelDuringDestHashIsNotDestMismatch() throws {
        let fixture = try makeRecordedCleanupFixture()
        defer { fixture.tearDown() }

        let destBytes = try Data(contentsOf: fixture.dest)
        let sourceA = try Data(contentsOf: fixture.sourceA)
        let sourceB = try Data(contentsOf: fixture.sourceB)
        let destMismatch = "Bound .m4b is not the file recorded at export."
        let sourceChanged = "Source files changed since they were bound."

        let token = EncodeCancellation()
        DigestProbe.reset()
        defer { DigestProbe.reset() }
        DigestProbe.onChunk = { token.cancel() }

        let auth = SourceCleanup.authorization(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false,
            cancellation: token
        )

        XCTAssertFalse(auth.allowed, "cancelled dest hash must not authorize cleanup")
        XCTAssertNotEqual(auth.reason, destMismatch, "cancel must not look like a dest digest mismatch")
        XCTAssertNotEqual(auth.reason, sourceChanged, "cancel must not look like a source digest mismatch")
        XCTAssertTrue(
            auth.reason?.localizedCaseInsensitiveContains("cancel") == true,
            "cancelled authorization must surface cancel distinctly, got \(auth.reason ?? "nil")"
        )
        XCTAssertTrue(token.isCancelled)
        XCTAssertEqual(try Data(contentsOf: fixture.dest), destBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceA), sourceA)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceB), sourceB)

        DigestProbe.onChunk = nil
        let allowed = SourceCleanup.authorization(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertTrue(allowed.allowed, "unchanged bytes must still authorize after a cancelled probe")

        try overwriteInPlaceKeepingMtime(
            at: fixture.dest,
            with: Data(repeating: 0xEF, count: destBytes.count)
        )
        let denied = SourceCleanup.authorization(
            book: fixture.book,
            inspection: M4BInspection.capturingIdentity(
                url: fixture.dest,
                duration: 30,
                chapters: [
                    ChapterMark(start: 0, duration: 10, title: "One"),
                    ChapterMark(start: 10, duration: 20, title: "Two")
                ],
                bookID: fixture.book.id
            ),
            isBuilding: false
        )
        XCTAssertFalse(denied.allowed, "real dest edits must still deny")
        XCTAssertEqual(denied.reason, destMismatch)
    }

    func testExportRecordsLoadableSidecarForSmallMultiChapterBook() async throws {
        let dir = try TestSupport.tempDir("export-sidecar-small")
        defer { try? FileManager.default.removeItem(at: dir) }
        var chapters: [Chapter] = []
        for index in 1...3 {
            let url = dir.appendingPathComponent(String(format: "ch%02d.wav", index))
            try TestSupport.writeSilenceWAV(to: url, seconds: 1)
            let info = AudioMetadata.fileInfo(of: url)
            chapters.append(
                Chapter(
                    url: url,
                    index: index,
                    title: "Ch\(index)",
                    duration: info.duration,
                    fileSize: 1,
                    audioInfo: info.audioInfo
                )
            )
        }
        let book = Audiobook(folder: dir, title: "SmallSidecar", author: "A", chapters: chapters)
        let dest = dir.appendingPathComponent("out.m4b")
        try await M4BExporter(bitrate: 48_000).export(book: book, to: dest, overwrite: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        let sidecar = SourceAssociation.sidecarURL(inBookFolder: dir)
        let bytes = try Data(contentsOf: sidecar)
        XCTAssertGreaterThan(bytes.count, 0)
        XCTAssertLessThanOrEqual(bytes.count, SourceAssociation.maxSidecarBytes)
        let document = try XCTUnwrap(SourceAssociation.loadDocument(inBookFolder: dir))
        XCTAssertEqual(document.sources.count, 3)
        XCTAssertEqual(
            document.sources.map(\.path),
            chapters.map(\.url.lastPathComponent)
        )
        XCTAssertEqual(
            document.sources.map { $0.url(relativeTo: dir).standardizedFileURL.path },
            chapters.map { $0.url.standardizedFileURL.path }
        )
        XCTAssertEqual(
            document.sources.map(\.sha256),
            chapters.map { SourceAssociation.sha256Hex(of: $0.url) }
        )
        XCTAssertEqual(document.destinationSHA256, SourceAssociation.sha256Hex(of: dest))
    }

    func testExportRecordsOutputDigestAndAllowsUnchangedCleanup() async throws {
        let dir = try TestSupport.tempDir("export-dest-digest")
        defer { try? FileManager.default.removeItem(at: dir) }
        let book = try makeSilenceBook(folder: dir, title: "DestDigest", author: "A")
        let dest = dir.appendingPathComponent("out.m4b")
        try await M4BExporter(bitrate: 48_000).export(book: book, to: dest, overwrite: true)

        let document = try XCTUnwrap(SourceAssociation.loadDocument(inBookFolder: dir))
        let destDigest = try XCTUnwrap(document.destinationSHA256)
        XCTAssertFalse(destDigest.isEmpty)
        XCTAssertEqual(destDigest, try XCTUnwrap(SourceAssociation.sha256Hex(of: dest)))

        var bound = book
        bound.existingM4BURL = dest
        let inspection = await M4BInspector.inspect(dest, bookID: book.id)
        let auth = SourceCleanup.authorization(book: bound, inspection: inspection, isBuilding: false)
        XCTAssertTrue(auth.allowed, "unchanged published dest with recorded digest must allow cleanup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.chapters[0].url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))

        let fixture = try makeRecordedCleanupFixture()
        defer { fixture.tearDown() }
        let fixtureDocument = try XCTUnwrap(SourceAssociation.loadDocument(inBookFolder: fixture.dir))
        XCTAssertFalse(fixtureDocument.destinationSHA256?.isEmpty ?? true)
        XCTAssertTrue(
            SourceCleanup.authorization(
                book: fixture.book,
                inspection: fixture.inspection,
                isBuilding: false
            ).allowed,
            "unchanged recorded fixture must still allow cleanup"
        )
    }

    @MainActor
    func testCleanupControlsPathDoesNotHashOnMainActor() {
        DigestProbe.reset()
        DigestProbe.setEnabled(true)
        defer { DigestProbe.reset() }

        XCTAssertTrue(Thread.isMainThread)
        let sample = URL(fileURLWithPath: "/tmp/r4-03-a.mp3")
        let cachedAllow = SourceCleanupAuthorization(allowed: true, sources: [sample, sample])
        let cachedDeny = SourceCleanupAuthorization(allowed: false, sources: [sample], reason: "no")

        XCTAssertEqual(
            SourceCleanup.controlsState(canCleanupSources: true, isBuilding: false, cached: nil),
            .pending
        )
        XCTAssertEqual(
            SourceCleanup.controlsState(canCleanupSources: true, isBuilding: true, cached: cachedAllow),
            .hidden
        )
        XCTAssertEqual(
            SourceCleanup.controlsState(canCleanupSources: false, isBuilding: false, cached: cachedAllow),
            .hidden
        )
        XCTAssertEqual(
            SourceCleanup.controlsState(canCleanupSources: true, isBuilding: false, cached: cachedDeny),
            .hidden
        )
        XCTAssertEqual(
            SourceCleanup.controlsState(canCleanupSources: true, isBuilding: false, cached: cachedAllow),
            .allowed(sourceCount: 2)
        )
        XCTAssertEqual(
            SourceCleanup.controlsState(
                canCleanupSources: true,
                isBuilding: false,
                cached: cachedAllow,
                isCleaningUp: true
            ),
            .hidden
        )

        let snap = DigestProbe.snapshot()
        XCTAssertEqual(snap.callCount, 0)
        XCTAssertEqual(snap.bytesHashed, 0)
        XCTAssertEqual(snap.mainThreadCallCount, 0)
        XCTAssertEqual(snap.mainThreadBytes, 0)
    }

    func testCleanupPerformHashWorkIsLinearInSourceCount() throws {
        let measured3 = try measureCleanupHashes(sourceCount: 3)
        let measured6 = try measureCleanupHashes(sourceCount: 6)

        XCTAssertTrue(measured3.didFinish)
        XCTAssertTrue(measured6.didFinish)
        XCTAssertGreaterThanOrEqual(
            measured3.destCalls,
            1 + 2 * 3,
            "dest SHA-256 must run at authorization, before each hold, and before each trash"
        )
        XCTAssertGreaterThanOrEqual(
            measured6.destCalls,
            1 + 2 * 6,
            "dest SHA-256 must run at authorization, before each hold, and before each trash"
        )
        XCTAssertGreaterThan(measured6.destCalls, measured3.destCalls)
        XCTAssertEqual(measured3.calls - measured3.destCalls, 2 * 3, "source hashing stays linear in N")
        XCTAssertEqual(measured6.calls - measured6.destCalls, 2 * 6, "source hashing stays linear in N")

        XCTAssertLessThanOrEqual(measured3.calls, 4 * 3 + 2)
        XCTAssertLessThanOrEqual(measured6.calls, 4 * 6 + 2)
        XCTAssertLessThan(
            measured6.calls,
            27,
            "N=6 must stay far below the old N(N+3)/2 source-hash schedule (27)"
        )
        XCTAssertLessThanOrEqual(measured6.calls, measured3.calls * 2 + 4)
        XCTAssertLessThanOrEqual(measured6.bytes, measured3.bytes * 2 + 64)
    }

    func testExportCancelDuringSourceHashDoesNotPublish() async throws {
        let dir = try TestSupport.tempDir("export-cancel-source-hash")
        defer { try? FileManager.default.removeItem(at: dir) }

        var chapters: [Chapter] = []
        for index in 1...6 {
            let url = dir.appendingPathComponent(String(format: "ch%02d.wav", index))
            try TestSupport.writeSilenceWAV(to: url, seconds: 2)
            let info = AudioMetadata.fileInfo(of: url)
            chapters.append(
                Chapter(
                    url: url,
                    index: index,
                    title: "Ch\(index)",
                    duration: info.duration,
                    fileSize: 1,
                    audioInfo: info.audioInfo
                )
            )
        }
        let book = Audiobook(folder: dir, title: "CancelHash", author: "A", chapters: chapters)
        let dest = dir.appendingPathComponent("out.m4b")
        let sidecar = SourceAssociation.sidecarURL(inBookFolder: dir)

        DigestProbe.reset()
        DigestProbe.setEnabled(true)
        defer { DigestProbe.reset() }

        let gate = ExportCancelGate()
        DigestProbe.onChunk = { gate.requestCancel() }

        let task = Task {
            try await M4BExporter(bitrate: 48_000).export(book: book, to: dest, overwrite: true)
        }
        gate.attach(task)

        do {
            try await task.value
            XCTFail("expected cancelled")
        } catch let error as BinderError {
            guard case .cancelled = error else { return XCTFail("\(error)") }
        } catch is CancellationError {}

        XCTAssertTrue(gate.didRequest, "cancel must fire at the first hash chunk")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "dest must not be published")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sidecar.path),
            "must not write a new source sidecar"
        )
        XCTAssertNil(SourceAssociation.load(inBookFolder: dir))

        let snap = DigestProbe.snapshot()
        XCTAssertLessThan(
            snap.callCount,
            6,
            "cancel must not finish hashing every source (completed hashes=\(snap.callCount))"
        )
    }

    func testExportAllCancelAfterPublishReportsPublishedNotCancelled() async throws {
        let root = try TestSupport.tempDir("export-cancel-after-publish")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDir = root.appendingPathComponent("Book", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let book = try makeSilenceBook(folder: bookDir, title: "AfterPublish", author: "A")
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        let dest = settings.plannedOutputs(for: [book])[book.id]!

        var exporter = M4BExporter(bitrate: 48_000)
        exporter.afterPublish = {
            withUnsafeCurrentTask { $0?.cancel() }
        }

        let results = try await exporter.exportAll(books: [book], settings: settings)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].outcome.isPublished)
        XCTAssertNotEqual(results[0].outcome, .cancelled)
        switch results[0].outcome {
        case .created, .publishedUnverified(replaced: false, _):
            break
        default:
            XCTFail("expected created or unverified new dest, got \(results[0].outcome)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        let size = try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(size, 1_000)
        try assertSidecarLoadableOrInvalidated(folder: bookDir, dest: dest)
        let published = results.filter(\.outcome.isPublished)
        XCTAssertEqual(published.map(\.url.standardizedFileURL.path), [dest.standardizedFileURL.path])
    }

    func testExportAllCancelDuringPublishedDestHashReportsPublished() async throws {
        let root = try TestSupport.tempDir("export-cancel-dest-hash")
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDir = root.appendingPathComponent("Book", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let book = try makeSilenceBook(folder: bookDir, title: "DestHashCancel", author: "A")
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        let dest = settings.plannedOutputs(for: [book])[book.id]!

        DigestProbe.reset()
        defer { DigestProbe.reset() }

        let hashedDest = StartedFlag()
        var exporter = M4BExporter(bitrate: 48_000)
        exporter.afterPublish = {
            DigestProbe.onChunk = {
                hashedDest.mark()
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        let results = try await exporter.exportAll(books: [book], settings: settings)
        XCTAssertTrue(hashedDest.isSet, "published dest hash must start after publish")
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].outcome.isPublished)
        XCTAssertNotEqual(results[0].outcome, .cancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        try assertSidecarLoadableOrInvalidated(folder: bookDir, dest: dest)
    }

    func testExportAllOverwriteCancelAfterPublishReplacesPayload() async throws {
        let dir = try TestSupport.tempDir("export-overwrite-cancel-after-publish")
        defer { try? FileManager.default.removeItem(at: dir) }
        var book = try makeSilenceBook(folder: dir, title: "OverwriteCancel", author: "A")
        let dest = dir.appendingPathComponent(book.suggestedFileName)
        let old = Data("OLD-DEST-PAYLOAD".utf8)
        try old.write(to: dest)
        book.existingM4BURL = dest
        OutputAssociation.record(dest, inBookFolder: dir)

        let settings = ExportSettings(overwrite: true, writeNextToBook: true)
        XCTAssertTrue(settings.owns(dest, for: book), "existing dest must be owned so overwrite can replace it")

        var exporter = M4BExporter(bitrate: 48_000)
        exporter.afterPublish = {
            withUnsafeCurrentTask { $0?.cancel() }
        }

        let results = try await exporter.exportAll(books: [book], settings: settings)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].outcome.isPublished)
        XCTAssertNotEqual(results[0].outcome, .cancelled)
        switch results[0].outcome {
        case .replaced, .publishedUnverified(replaced: true, _):
            break
        default:
            XCTFail("expected replaced or unverified overwrite, got \(results[0].outcome)")
        }
        XCTAssertNotEqual(try Data(contentsOf: dest), old)
        let size = try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(size, 1_000)
        try assertSidecarLoadableOrInvalidated(folder: dir, dest: dest)
    }

    func testExportAllCancelAfterFirstPublishCancelsRemainingBooks() async throws {
        let root = try TestSupport.tempDir("export-all-cancel-after-first-publish")
        defer { try? FileManager.default.removeItem(at: root) }
        let book1Dir = root.appendingPathComponent("Book1", isDirectory: true)
        let book2Dir = root.appendingPathComponent("Book2", isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: book1Dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: book2Dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let book1 = try makeSilenceBook(folder: book1Dir, title: "KeepFirst", author: "A")
        let book2 = try makeSilenceBook(folder: book2Dir, title: "LeaveSecond", author: "A")
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        let plan = settings.plannedOutputs(for: [book1, book2])
        let dest1 = plan[book1.id]!
        let dest2 = plan[book2.id]!

        let firstPublished = StartedFlag()
        var exporter = M4BExporter(bitrate: 48_000)
        exporter.afterPublish = {
            guard !firstPublished.isSet else { return }
            firstPublished.mark()
            withUnsafeCurrentTask { $0?.cancel() }
        }

        let results = try await exporter.exportAll(books: [book1, book2], settings: settings)
        XCTAssertTrue(firstPublished.isSet)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].bookID, book1.id)
        XCTAssertTrue(results[0].outcome.isPublished)
        XCTAssertNotEqual(results[0].outcome, .cancelled)
        XCTAssertEqual(results[1].bookID, book2.id)
        XCTAssertEqual(results[1].outcome, .cancelled)
        XCTAssertFalse(results[1].outcome.isPublished)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest2.path))

        let summary = BinderCopy.exportSummary(results: results, books: [book1, book2])
        XCTAssertTrue(
            summary.contains("Created") || summary.contains("Replaced") || summary.contains("Unverified"),
            "mixed summary must mention a published phrase: \(summary)"
        )
        XCTAssertTrue(summary.contains("Cancelled"), "mixed summary must mention cancelled: \(summary)")
        XCTAssertTrue(summary.contains("Verify the .m4b"), "published dest must still ask for a verify: \(summary)")
    }

    func testExportSourcePersistFailureInvalidatesSidecarAndDeniesCleanup() async throws {
        let dir = try TestSupport.tempDir("source-persist-fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let book = try makeSilenceBook(folder: dir, title: "PersistFail", author: "A")
        let dest = dir.appendingPathComponent("out.m4b")
        let sidecar = SourceAssociation.sidecarURL(inBookFolder: dir)
        try Data("stale-source-record".utf8).write(to: sidecar)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))

        let blocked = StartedFlag()
        var exporter = M4BExporter(bitrate: 48_000)
        exporter.afterPublish = {
            blocked.mark()
            try? FileManager.default.removeItem(at: sidecar)
            try? FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        }
        do {
            try await exporter.export(book: book, to: dest, overwrite: true)
            XCTFail("expected source persist failure after publish")
        } catch let error as BinderError {
            guard case .publishedUnverified = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }

        XCTAssertTrue(blocked.isSet)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertNil(SourceAssociation.load(inBookFolder: dir))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sidecar.path),
            "older source sidecar must be invalidated when persist fails"
        )

        var bound = book
        bound.existingM4BURL = dest
        let inspection = await M4BInspector.inspect(dest, bookID: book.id)
        XCTAssertFalse(
            SourceCleanup.authorization(book: bound, inspection: inspection, isBuilding: false).allowed
        )

        let allDir = try TestSupport.tempDir("source-persist-fail-all")
        defer { try? FileManager.default.removeItem(at: allDir) }
        let book2 = try makeSilenceBook(folder: allDir, title: "PersistFailAll", author: "A")
        let out = allDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let sidecar2 = SourceAssociation.sidecarURL(inBookFolder: allDir)
        var allExporter = M4BExporter(bitrate: 48_000)
        allExporter.afterPublish = {
            try? FileManager.default.removeItem(at: sidecar2)
            try? FileManager.default.createDirectory(at: sidecar2, withIntermediateDirectories: true)
        }
        let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
        let results = try await allExporter.exportAll(books: [book2], settings: settings)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].outcome.isPublished)
        guard case .publishedUnverified(replaced: false, _) = results[0].outcome else {
            return XCTFail("expected publishedUnverified, got \(results[0].outcome)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: results[0].url.path))
        XCTAssertNil(SourceAssociation.load(inBookFolder: allDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar2.path))
    }

    func testExportOutputAuthorityPersistFailureInvalidatesSidecarAndDeniesCleanup() async throws {
        let dir = try TestSupport.tempDir("output-authority-persist-fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let book = try makeSilenceBook(folder: dir, title: "OAPersistFail", author: "A")
        let dest = dir.appendingPathComponent("out.m4b")
        let sidecar = dir.appendingPathComponent(OutputAssociation.fileName)
        try Data("stale-output-record".utf8).write(to: sidecar)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))

        try await withUnwritableAuthorityStore {
            do {
                try await M4BExporter(bitrate: 48_000).export(book: book, to: dest, overwrite: true)
                XCTFail("expected output association persist failure after publish")
            } catch let error as BinderError {
                guard case .publishedUnverified = error else { return XCTFail("\(error)") }
            } catch {
                XCTFail("\(error)")
            }

            XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
            XCTAssertNil(OutputAssociation.load(inBookFolder: dir))
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: sidecar.path),
                "older output sidecar must be invalidated when authority persist fails"
            )
            XCTAssertNil(SourceAssociation.load(inBookFolder: dir))

            var bound = book
            bound.existingM4BURL = dest
            let inspection = await M4BInspector.inspect(dest, bookID: book.id)
            XCTAssertFalse(
                SourceCleanup.authorization(book: bound, inspection: inspection, isBuilding: false).allowed
            )
        }

        let allDir = try TestSupport.tempDir("output-authority-persist-fail-all")
        defer { try? FileManager.default.removeItem(at: allDir) }
        let book2 = try makeSilenceBook(folder: allDir, title: "OAPersistFailAll", author: "A")
        let out = allDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        try await withUnwritableAuthorityStore {
            let settings = ExportSettings(outputDirectory: out, overwrite: true, writeNextToBook: false)
            let results = try await M4BExporter(bitrate: 48_000).exportAll(books: [book2], settings: settings)
            XCTAssertEqual(results.count, 1)
            XCTAssertTrue(results[0].outcome.isPublished)
            guard case .publishedUnverified(replaced: false, warning: let warning) = results[0].outcome else {
                return XCTFail("expected publishedUnverified, got \(results[0].outcome)")
            }
            XCTAssertTrue(
                warning.localizedCaseInsensitiveContains("output association"),
                warning
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: results[0].url.path))
            XCTAssertNil(OutputAssociation.load(inBookFolder: allDir))
            XCTAssertNil(SourceAssociation.load(inBookFolder: allDir))

            var bound2 = book2
            bound2.existingM4BURL = results[0].url
            let inspection2 = await M4BInspector.inspect(results[0].url, bookID: book2.id)
            XCTAssertFalse(
                SourceCleanup.authorization(book: bound2, inspection: inspection2, isBuilding: false).allowed
            )
        }
    }

    func testExportFailureBeforePublishLeavesExistingSourceSidecar() async throws {
        let fixture = try makeRecordedCleanupFixture()
        defer { fixture.tearDown() }

        let seeded = try XCTUnwrap(SourceAssociation.load(inBookFolder: fixture.dir))
        XCTAssertFalse(seeded.isEmpty)
        let destBytes = try Data(contentsOf: fixture.dest)
        XCTAssertTrue(
            SourceCleanup.authorization(
                book: fixture.book,
                inspection: fixture.inspection,
                isBuilding: false
            ).allowed,
            "seeded bind must be authorized before the failed retry"
        )

        let retry = try makeSilenceBook(folder: fixture.dir, title: "Retry", author: "A")
        do {
            try await M4BExporter(bitrate: 48_000).export(book: retry, to: fixture.dest, overwrite: true) { fraction, _ in
                guard fraction >= 0.92, fraction < 1.0 else { return }
                withUnsafeCurrentTask { $0?.cancel() }
            }
            XCTFail("expected cancel before publish")
        } catch let error as BinderError {
            guard case .cancelled = error else { return XCTFail("\(error)") }
        } catch is CancellationError {}

        XCTAssertEqual(try Data(contentsOf: fixture.dest), destBytes)
        let loaded = try XCTUnwrap(
            SourceAssociation.load(inBookFolder: fixture.dir),
            "pre-publish failure must leave the previous source record"
        )
        XCTAssertEqual(loaded.map(\.path), seeded.map(\.path))
        XCTAssertEqual(loaded.map(\.sha256), seeded.map(\.sha256))
        XCTAssertTrue(
            SourceCleanup.authorization(
                book: fixture.book,
                inspection: fixture.inspection,
                isBuilding: false
            ).allowed,
            "cleanup of the previous bind must still use the seeded record"
        )
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

    func testUsesScannedEndBoundaryOnlyForEmbeddedChapters() {
        let standalone = Chapter(
            url: URL(fileURLWithPath: "/tmp/book.mp3"),
            index: 0,
            title: "File",
            duration: 0,
            fileSize: 1
        )
        XCTAssertFalse(ChapterPlayback.usesScannedEndBoundary(for: standalone))

        let underestimated = Chapter(
            url: URL(fileURLWithPath: "/tmp/book.mp3"),
            index: 1,
            title: "Short scan",
            duration: 0.01,
            fileSize: 1
        )
        XCTAssertFalse(ChapterPlayback.usesScannedEndBoundary(for: underestimated))

        let embedded = Chapter(
            url: URL(fileURLWithPath: "/tmp/book.m4b"),
            index: 1,
            title: "One",
            duration: 10,
            fileSize: 1,
            startOffset: 0,
            isEmbedded: true
        )
        XCTAssertTrue(ChapterPlayback.usesScannedEndBoundary(for: embedded))

        let embeddedEmpty = Chapter(
            url: URL(fileURLWithPath: "/tmp/book.m4b"),
            index: 2,
            title: "Tiny",
            duration: 0,
            fileSize: 1,
            startOffset: 4,
            isEmbedded: true
        )
        XCTAssertTrue(ChapterPlayback.usesScannedEndBoundary(for: embeddedEmpty))
    }

    @MainActor
    func testStandaloneZeroDurationChapterPlaysPastFiftyMilliseconds() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: TestSupport.tink.path), "Tink.aiff missing")
        let playback = ChapterPlayback()
        let chapter = Chapter(
            url: TestSupport.tink,
            index: 1,
            title: "Tink",
            duration: 0,
            fileSize: 1
        )
        XCTAssertFalse(ChapterPlayback.usesScannedEndBoundary(for: chapter))
        playback.toggle(chapter)
        let started = await waitUntil(timeout: 3) {
            playback.isPlaying(chapter)
        }
        XCTAssertTrue(started)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(
            playback.isPlaying(chapter),
            "standalone duration 0 must not stop at the 50ms scanned-end fallback"
        )
        let ended = await waitUntil(timeout: 3) {
            !playback.isPlaying && playback.playingID == nil
        }
        XCTAssertTrue(ended, "standalone playback should clear on AVPlayer end")
    }

    @MainActor
    func testStandaloneUnderestimatedChapterPlaysToFileEnd() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: TestSupport.tink.path), "Tink.aiff missing")
        let playback = ChapterPlayback()
        // Tink ~0.56s; 0.2s is a large underestimate so a scanned-end stop is observable.
        let chapter = Chapter(
            url: TestSupport.tink,
            index: 1,
            title: "Tink",
            duration: 0.2,
            fileSize: 1
        )
        XCTAssertFalse(ChapterPlayback.usesScannedEndBoundary(for: chapter))
        playback.toggle(chapter)
        let started = await waitUntil(timeout: 3) {
            playback.isPlaying(chapter)
        }
        XCTAssertTrue(started)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(
            playback.isPlaying(chapter),
            "standalone file must keep playing past the scanned-duration boundary"
        )
        let ended = await waitUntil(timeout: 3) {
            !playback.isPlaying && playback.playingID == nil
        }
        XCTAssertTrue(ended, "standalone playback should clear on AVPlayer end")
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

    private func largeTaggableMP4() -> Data {
        var mvhd = Data(count: 100)
        mvhd.replaceSubrange(12..<16, with: MP4Box.u32(1000))
        mvhd.replaceSubrange(16..<20, with: MP4Box.u32(1000))
        mvhd.replaceSubrange(20..<24, with: MP4Box.u32(0x00010000))
        mvhd.replaceSubrange(24..<26, with: MP4Box.u16(0x0100))
        mvhd.replaceSubrange(36..<40, with: MP4Box.u32(0x00010000))
        mvhd.replaceSubrange(52..<56, with: MP4Box.u32(0x00010000))
        mvhd.replaceSubrange(68..<72, with: MP4Box.u32(0x40000000))
        mvhd.replaceSubrange(96..<100, with: MP4Box.u32(2))
        let ftyp = MP4Box.box(
            "ftyp",
            MP4Box.fourcc("M4A ") + MP4Box.u32(0) + MP4Box.fourcc("M4A ") + MP4Box.fourcc("mp42")
        )
        let mdat = MP4Box.box("mdat", Data(count: MP4AtomIO.ioChunkSize + 64))
        return ftyp + MP4Box.box("moov", MP4Box.box("mvhd", mvhd)) + mdat
    }

    private func withUnwritableAuthorityStore(_ body: () async throws -> Void) async throws {
        let parent = try TestSupport.tempDir("oa-auth-block")
        let blocker = parent.appendingPathComponent("store")
        try Data("not-a-directory".utf8).write(to: blocker)
        let previous = OutputAssociation.authorityDirectoryOverride
        OutputAssociation.authorityDirectoryOverride = blocker
        defer {
            OutputAssociation.authorityDirectoryOverride = previous
            try? FileManager.default.removeItem(at: parent)
        }
        try await body()
    }

    private func assertSidecarLoadableOrInvalidated(folder: URL, dest: URL) throws {
        let sidecar = SourceAssociation.sidecarURL(inBookFolder: folder)
        if FileManager.default.fileExists(atPath: sidecar.path) {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: sidecar.path, isDirectory: &isDirectory)
            XCTAssertFalse(isDirectory.boolValue, "source sidecar must be a file or absent")
            let document = try XCTUnwrap(
                SourceAssociation.loadDocument(inBookFolder: folder),
                "existing sidecar must be a loadable provenance record"
            )
            let destDigest = try XCTUnwrap(SourceAssociation.sha256Hex(of: dest))
            XCTAssertEqual(document.destinationSHA256?.lowercased(), destDigest.lowercased())
        } else {
            XCTAssertNil(SourceAssociation.load(inBookFolder: folder))
        }
    }

    private func makeSilence(in dir: URL, seconds: Double = 1) throws -> URL {
        let wav = dir.appendingPathComponent("silence.wav")
        try TestSupport.writeSilenceWAV(to: wav, seconds: seconds)
        return wav
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func overwriteInPlaceKeepingMtime(at url: URL, with data: Data) throws {
        var info = stat()
        try url.path.withCString { path in
            guard lstat(path, &info) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.close()
        let times = [info.st_atimespec, info.st_mtimespec]
        let restored = url.path.withCString { path in
            times.withUnsafeBufferPointer { buffer in
                utimensat(AT_FDCWD, path, buffer.baseAddress, 0)
            }
        }
        guard restored == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func measureCleanupHashes(sourceCount: Int) throws -> (
        calls: Int,
        bytes: Int,
        destCalls: Int,
        didFinish: Bool
    ) {
        let dir = try TestSupport.tempDir("cleanup-linear-\(sourceCount)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let dest = dir.appendingPathComponent("book.m4b")
        try Data(count: 128).write(to: dest)
        var sources: [URL] = []
        var chapters: [Chapter] = []
        var marks: [ChapterMark] = []
        for index in 1...sourceCount {
            let url = dir.appendingPathComponent(String(format: "%02d.mp3", index))
            try Data(count: 64).write(to: url)
            sources.append(url)
            chapters.append(TestSupport.dummyChapter(index: index, url: url, duration: 10))
            marks.append(ChapterMark(start: Double((index - 1) * 10), duration: 10, title: "Ch\(index)"))
        }

        var book = TestSupport.dummyBook(folder: dir.path, chapters: chapters)
        book.existingM4BURL = dest
        XCTAssertTrue(SourceAssociation.record(sources, dest: dest, inBookFolder: dir))
        let inspection = M4BInspection.capturingIdentity(
            url: dest,
            duration: Double(sourceCount * 10),
            chapters: marks,
            bookID: book.id
        )

        DigestProbe.reset()
        DigestProbe.setEnabled(true)
        defer { DigestProbe.reset() }
        let result = SourceCleanup.perform(book: book, inspection: inspection, isBuilding: false)
        let snap = DigestProbe.snapshot()
        return (
            calls: snap.callCount,
            bytes: snap.bytesHashed,
            destCalls: DigestProbe.callCount(for: dest),
            didFinish: result.didFinish
        )
    }

    private func makeRecordedCleanupFixture() throws -> RecordedCleanupFixture {
        let dir = try TestSupport.tempDir("export-cleanup-auth")
        let dest = dir.appendingPathComponent("book.m4b")
        let sourceA = dir.appendingPathComponent("01.mp3")
        let sourceB = dir.appendingPathComponent("02.mp3")
        try Data(count: 32).write(to: dest)
        try Data(count: 8).write(to: sourceA)
        try Data(count: 8).write(to: sourceB)

        var book = TestSupport.dummyBook(
            folder: dir.path,
            chapters: [
                TestSupport.dummyChapter(index: 1, url: sourceA, duration: 10),
                TestSupport.dummyChapter(index: 2, url: sourceB, duration: 20)
            ]
        )
        book.existingM4BURL = dest
        XCTAssertTrue(SourceAssociation.record([sourceA, sourceB], dest: dest, inBookFolder: dir))

        let inspection = M4BInspection.capturingIdentity(
            url: dest,
            duration: 30,
            chapters: [
                ChapterMark(start: 0, duration: 10, title: "One"),
                ChapterMark(start: 10, duration: 20, title: "Two")
            ],
            bookID: book.id
        )
        return RecordedCleanupFixture(
            dir: dir,
            dest: dest,
            sourceA: sourceA,
            sourceB: sourceB,
            book: book,
            inspection: inspection
        )
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

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    var value: Error? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

private struct RecordedCleanupFixture {
    var dir: URL
    var dest: URL
    var sourceA: URL
    var sourceB: URL
    var book: Audiobook
    var inspection: M4BInspection

    func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }
}

private final class ExportCancelGate: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Error>?
    private var pending = false
    private var requested = false

    var didRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func attach(_ task: Task<Void, Error>) {
        lock.lock()
        self.task = task
        let shouldCancel = pending
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func requestCancel() {
        lock.lock()
        requested = true
        pending = true
        let task = self.task
        lock.unlock()
        task?.cancel()
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
