import XCTest
@testable import AudiobookBinderCore

final class M4BInspectorTests: XCTestCase {
    func testCompareDurationsMatchAndMismatch() {
        XCTAssertTrue(M4BInspector.durationsMatch(source: 100, bound: 100.4))
        XCTAssertTrue(M4BInspector.durationsMatch(source: 10_000, bound: 10_050), "1% slack on long books")
        XCTAssertFalse(M4BInspector.durationsMatch(source: 100, bound: 130))
        XCTAssertFalse(M4BInspector.durationsMatch(source: 0, bound: 10))
        XCTAssertFalse(M4BInspector.durationsMatch(source: 10, bound: 0))
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
        SourceAssociation.record([mp3a, mp3b, missing, m4b], dest: m4b, inBookFolder: dir)
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
        XCTAssertEqual(chapters[0].duration, 10)
        XCTAssertTrue(chapters[0].isEmbedded, "first bound chapter is still a range, even at offset 0")
        XCTAssertEqual(chapters[1].startOffset, 10)
        XCTAssertEqual(chapters[1].duration, 20)
        XCTAssertTrue(chapters[1].isEmbedded)
        XCTAssertEqual(chapters[1].url, url)
        XCTAssertFalse(TestSupport.dummyChapter(index: 1).isEmbedded)
    }

    func testApplyLeavesFileUnchangedWhenMoovMissing() throws {
        let dir = try TestSupport.tempDir("tag-nomov")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("bad.m4a")
        let original = Data("not-an-mp4-file".utf8)
        try original.write(to: url)
        XCTAssertThrowsError(
            try MP4AudiobookTagger.apply(
                to: url,
                tags: AudiobookTags(title: "T", author: "A"),
                chapters: []
            )
        )
        XCTAssertEqual(try Data(contentsOf: url), original)
        let leftovers = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(leftovers.map(\.lastPathComponent), ["bad.m4a"])
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
        XCTAssertTrue(M4BInspector.durationsMatch(source: info.duration, bound: inspection.duration))
        let nero = M4BInspector.neroChapters(in: dest, duration: inspection.duration)
        XCTAssertTrue(nero.contains(where: { $0.title == "Silence" }))
    }

    func testMakeChplWritesReservedAndUInt8Count() {
        let box = MP4AudiobookTagger.makeChpl([
            ChapterMark(start: 0, duration: 1, title: "One"),
            ChapterMark(start: 1, duration: 1, title: "Two")
        ])
        XCTAssertEqual(String(bytes: box[4..<8], encoding: .isoLatin1), "chpl")
        let payload = Data(box.dropFirst(8))
        XCTAssertGreaterThanOrEqual(payload.count, 9)
        XCTAssertEqual(payload[0], 1, "version must be 1")
        XCTAssertEqual(Array(payload[4..<8]), [0, 0, 0, 0], "bytes after flags are reserved 0, not a 32-bit count")
        XCTAssertEqual(payload[8], 2, "chapter count is a single byte")
    }

    func testParseChplRoundtripsTwoChapters() {
        let chapters = [
            ChapterMark(start: 0, duration: 1, title: "One"),
            ChapterMark(start: 1, duration: 1, title: "Two")
        ]
        let payload = Data(MP4AudiobookTagger.makeChpl(chapters).dropFirst(8))
        let parsed = MP4AudiobookTagger.parseChpl(payload)
        XCTAssertEqual(parsed.map(\.title), ["One", "Two"])
        XCTAssertEqual(parsed.map(\.start), [0, 1])
    }

    func testParseChplReadsConventionalVersion1Fixture() {
        var payload = Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02])
        appendChplEntry(&payload, start: 0, title: "One")
        appendChplEntry(&payload, start: 1, title: "Two")
        let parsed = MP4AudiobookTagger.parseChpl(payload)
        XCTAssertEqual(parsed.map(\.title), ["One", "Two"])
        XCTAssertEqual(parsed.map(\.start), [0, 1])
    }

    func testParseChplAcceptsLegacyU32CountLayout() {
        var payload = Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02])
        appendChplEntry(&payload, start: 0, title: "One")
        appendChplEntry(&payload, start: 1, title: "Two")
        let parsed = MP4AudiobookTagger.parseChpl(payload)
        XCTAssertEqual(parsed.map(\.title), ["One", "Two"])
        XCTAssertEqual(parsed.map(\.start), [0, 1])
    }

    func testMakeChplTruncatesMultibyteTitlesOnUTF8Boundaries() {
        let title = String(repeating: "é", count: 200)
        XCTAssertGreaterThan(title.utf8.count, 255)
        let payload = Data(MP4AudiobookTagger.makeChpl([
            ChapterMark(start: 0, duration: 1, title: title)
        ]).dropFirst(8))
        XCTAssertEqual(payload[8], 1)
        let titleLen = Int(payload[17])
        XCTAssertLessThanOrEqual(titleLen, 255)
        let titleBytes = payload.subdata(in: 18..<(18 + titleLen))
        XCTAssertEqual(titleBytes.count, titleLen)
        let decoded = String(data: titleBytes, encoding: .utf8)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded, String(repeating: "é", count: titleLen / 2))
        XCTAssertEqual(titleLen % 2, 0, "must not split a 2-byte character")
        XCTAssertFalse(titleBytes.isEmpty)
    }

    func testChapterSampleDataFits65535UTF8Bytes() {
        let title = String(repeating: "A", count: 65_535)
        XCTAssertEqual(title.utf8.count, 65_535)
        let pack = MP4AudiobookTagger.chapterSampleData([
            ChapterMark(start: 0, duration: 1, title: title)
        ])
        let parsed = parseQuickTimeTextSample(pack.payload)
        XCTAssertEqual(parsed.length, 65_535)
        XCTAssertEqual(parsed.text.count, 65_535)
        XCTAssertEqual(String(data: parsed.text, encoding: .utf8), title)
        XCTAssertEqual(pack.sizes, [UInt32(65_537)])
    }

    func testChapterSampleDataTruncatesOverlongAndMultibyteTitles() {
        let ascii = String(repeating: "A", count: 65_536)
        XCTAssertEqual(ascii.utf8.count, 65_536)
        let asciiPack = MP4AudiobookTagger.chapterSampleData([
            ChapterMark(start: 0, duration: 1, title: ascii)
        ])
        let asciiSample = parseQuickTimeTextSample(asciiPack.payload)
        XCTAssertLessThanOrEqual(asciiSample.length, 65_535)
        XCTAssertEqual(asciiSample.length, 65_535)
        XCTAssertEqual(asciiSample.text.count, asciiSample.length)
        XCTAssertNotNil(String(data: asciiSample.text, encoding: .utf8))
        XCTAssertEqual(String(data: asciiSample.text, encoding: .utf8), String(repeating: "A", count: 65_535))

        let accented = String(repeating: "é", count: 32_768)
        XCTAssertEqual(accented.utf8.count, 65_536)
        let accentedPack = MP4AudiobookTagger.chapterSampleData([
            ChapterMark(start: 0, duration: 1, title: accented)
        ])
        let accentedSample = parseQuickTimeTextSample(accentedPack.payload)
        XCTAssertLessThanOrEqual(accentedSample.length, 65_535)
        XCTAssertEqual(accentedSample.length % 2, 0, "must not split a 2-byte character")
        XCTAssertEqual(accentedSample.length, 65_534)
        let decoded = String(data: accentedSample.text, encoding: .utf8)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded, String(repeating: "é", count: 32_767))

        let mixed = String(repeating: "A", count: 65_534) + "é"
        XCTAssertEqual(mixed.utf8.count, 65_536)
        let mixedSample = parseQuickTimeTextSample(
            MP4AudiobookTagger.chapterSampleData([
                ChapterMark(start: 0, duration: 1, title: mixed)
            ]).payload
        )
        XCTAssertLessThanOrEqual(mixedSample.length, 65_535)
        XCTAssertEqual(mixedSample.length, 65_534)
        XCTAssertEqual(String(data: mixedSample.text, encoding: .utf8), String(repeating: "A", count: 65_534))
    }

    func testChunkOffsetTableUsesStcoAtUInt32Max() {
        let table = MP4AudiobookTagger.chunkOffsetTable(offset: UInt64(UInt32.max))
        XCTAssertEqual(String(bytes: table[4..<8], encoding: .isoLatin1), "stco")
        XCTAssertEqual(MP4AtomIO.readU32(table, 12), 1)
        XCTAssertEqual(MP4AtomIO.readU32(table, 16), UInt32.max)
        XCTAssertNil(table.range(of: Data("co64".utf8)))
    }

    func testChunkOffsetTableUsesCo64AboveUInt32Max() {
        let offset: UInt64 = 4_294_967_296
        XCTAssertEqual(offset, UInt64(UInt32.max) + 1)
        let table = MP4AudiobookTagger.chunkOffsetTable(offset: offset)
        XCTAssertEqual(String(bytes: table[4..<8], encoding: .isoLatin1), "co64")
        XCTAssertEqual(MP4AtomIO.readU32(table, 12), 1)
        XCTAssertEqual(MP4AtomIO.readU64(table, 16), offset)
        XCTAssertNil(table.range(of: Data("stco".utf8)))

        let chapters = [ChapterMark(start: 0, duration: 1, title: "A")]
        let samples = MP4AudiobookTagger.chapterSampleData(chapters)
        let stbl = MP4AudiobookTagger.makeChapterStbl(
            chapters: chapters,
            sampleSizes: samples.sizes,
            chunkOffset: offset
        )
        XCTAssertNotNil(stbl.range(of: Data("co64".utf8)))
        XCTAssertNil(stbl.range(of: Data("stco".utf8)))
    }

    func testInvalidChapterTimesThrowWithoutTrapping() {
        let cases: [(start: TimeInterval, duration: TimeInterval, needle: String)] = [
            (.nan, 1, "start"),
            (.infinity, 1, "start"),
            (-.infinity, 1, "start"),
            (-1, 1, "start"),
            (0, .nan, "duration"),
            (0, .infinity, "duration"),
            (0, -.infinity, "duration"),
            (0, -0.5, "duration")
        ]
        for item in cases {
            XCTAssertThrowsError(
                try MP4AudiobookTagger.validateChapters([
                    ChapterMark(start: item.start, duration: item.duration, title: "X")
                ]),
                "start=\(item.start) duration=\(item.duration)"
            ) { error in
                guard case BinderError.exportFailed(let message) = error else {
                    return XCTFail("\(error)")
                }
                XCTAssertTrue(
                    message.localizedCaseInsensitiveContains(item.needle),
                    "expected \(item.needle) in \(message)"
                )
            }
        }
        XCTAssertNoThrow(
            try MP4AudiobookTagger.validateChapters([
                ChapterMark(start: 0, duration: 0, title: "OK")
            ])
        )
    }

    func testCleanupAuthorizationFailsWhenDestDeletedAfterInspection() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        try FileManager.default.removeItem(at: fixture.dest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.dest.path))

        let auth = SourceCleanup.authorization(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertFalse(auth.allowed)

        let result = SourceCleanup.perform(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertFalse(result.didFinish)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceB.path))
    }

    func testCleanupAuthorizationFailsWhenDestReplacedAfterInspection() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        try Data(count: 256).write(to: fixture.dest)
        let liveSize = (try FileManager.default.attributesOfItem(atPath: fixture.dest.path)[.size] as? NSNumber)?.int64Value
        XCTAssertEqual(liveSize, 256)
        XCTAssertNotEqual(liveSize, fixture.inspection.fileSize)

        let auth = SourceCleanup.authorization(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertFalse(auth.allowed)

        let result = SourceCleanup.perform(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertFalse(result.didFinish)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceB.path))
    }

    func testCleanupAuthorizationFailsWhenInspectionURLDoesNotMatchBook() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        let otherDest = fixture.dir.appendingPathComponent("other.m4b")
        try Data(count: 32).write(to: otherDest)
        var mismatched = fixture.book
        mismatched.existingM4BURL = otherDest

        let auth = SourceCleanup.authorization(
            book: mismatched,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertFalse(auth.allowed, "Same durations must not authorize a different bound file")
        XCTAssertTrue(
            ChapterCompare.summary(
                original: mismatched.chapters,
                bound: M4BInspector.playableChapters(from: fixture.inspection),
                boundDuration: fixture.inspection.duration
            ).allMatch
        )
    }

    func testCleanupAuthorizationFailsWhileBuilding() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        let auth = SourceCleanup.authorization(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: true
        )
        XCTAssertFalse(auth.allowed)
    }

    func testCleanupAuthorizationSucceedsWhenIdentityAndDurationsMatch() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        let auth = SourceCleanup.authorization(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertTrue(auth.allowed)
        XCTAssertEqual(Set(auth.sources.map(\.lastPathComponent)), ["01.mp3", "02.mp3"])
    }

    func testShouldCommitInspectionRejectsStaleIdentityAndMismatchedBook() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        XCTAssertTrue(
            SourceCleanup.shouldCommitInspection(
                fixture.inspection,
                bookID: fixture.book.id,
                requestedURL: fixture.dest,
                currentURL: fixture.book.existingM4BURL
            )
        )

        try Data(count: 256).write(to: fixture.dest)
        XCTAssertFalse(
            SourceCleanup.shouldCommitInspection(
                fixture.inspection,
                bookID: fixture.book.id,
                requestedURL: fixture.dest,
                currentURL: fixture.dest
            ),
            "Must not commit an inspection after the dest bytes change"
        )

        try FileManager.default.removeItem(at: fixture.dest)
        XCTAssertFalse(
            SourceCleanup.shouldCommitInspection(
                fixture.inspection,
                bookID: fixture.book.id,
                requestedURL: fixture.dest,
                currentURL: fixture.dest
            )
        )
    }

    func testShouldCommitInspectionRejectsURLAndBookMismatch() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        let other = fixture.dir.appendingPathComponent("other.m4b")
        try Data(count: 32).write(to: other)
        XCTAssertFalse(
            SourceCleanup.shouldCommitInspection(
                fixture.inspection,
                bookID: fixture.book.id,
                requestedURL: fixture.dest,
                currentURL: other
            )
        )
        XCTAssertFalse(
            SourceCleanup.shouldCommitInspection(
                fixture.inspection,
                bookID: UUID(),
                requestedURL: fixture.dest,
                currentURL: fixture.dest
            )
        )
        XCTAssertFalse(
            SourceCleanup.shouldCommitInspection(
                fixture.inspection,
                bookID: fixture.book.id,
                requestedURL: fixture.dest,
                currentURL: nil
            )
        )
    }

    func testCleanupReconcileKeepsRemainingChaptersAfterPartialTrash() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        let leftover = SourceCleanup.reconcile(chapters: fixture.book.chapters, moved: [fixture.sourceA])
        XCTAssertEqual(leftover.map(\.url.lastPathComponent), ["02.mp3"])

        let partial = SourceCleanupResult(
            moved: [fixture.sourceA],
            remaining: [fixture.sourceB],
            error: "could not trash"
        )
        XCTAssertFalse(partial.didFinish)
        XCTAssertEqual(partial.remaining.map(\.lastPathComponent), ["02.mp3"])

        let finished = SourceCleanupResult(
            moved: [fixture.sourceA, fixture.sourceB],
            remaining: [],
            error: nil
        )
        XCTAssertTrue(finished.didFinish)
    }

    func testCleanupAuthorizationFailsWhenSourceBytesReplacedSameLength() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        try replaceFile(at: fixture.sourceA, with: Data(repeating: 0xAB, count: 8))

        let auth = SourceCleanup.authorization(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertFalse(
            auth.allowed,
            "Matching dest + cached durations must not authorize replaced source bytes"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceB.path))
    }

    func testCleanupAuthorizationFailsWhenSourceReplacedByDirectory() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        try FileManager.default.removeItem(at: fixture.sourceB)
        try FileManager.default.createDirectory(at: fixture.sourceB, withIntermediateDirectories: true)
        try Data("unrelated".utf8).write(to: fixture.sourceB.appendingPathComponent("other.txt"))

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceB.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        let files = M4BInspector.sourceFilesToRemove(from: fixture.book)
        XCTAssertEqual(files.map(\.lastPathComponent), ["01.mp3"])
        XCTAssertFalse(files.contains { $0.standardizedFileURL.path == fixture.sourceB.standardizedFileURL.path })

        let auth = SourceCleanup.authorization(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertFalse(auth.allowed)
        XCTAssertFalse(
            auth.sources.contains { $0.standardizedFileURL.path == fixture.sourceB.standardizedFileURL.path },
            "A directory substituted for a source must never be authorized"
        )
    }

    func testCleanupAuthorizationFailsWhenSourceIsSymlinkToOtherFile() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        let other = fixture.dir.appendingPathComponent("other.mp3")
        try Data(repeating: 0xCD, count: 8).write(to: other)
        try FileManager.default.removeItem(at: fixture.sourceA)
        try FileManager.default.createSymbolicLink(at: fixture.sourceA, withDestinationURL: other)

        let auth = SourceCleanup.authorization(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertFalse(
            auth.allowed,
            "A symlink to a different object than the captured source must be denied"
        )
    }

    func testCleanupAuthorizationFailsWhenSourceMissing() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        try FileManager.default.removeItem(at: fixture.sourceA)

        let auth = SourceCleanup.authorization(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertFalse(auth.allowed)
        let reason = try XCTUnwrap(auth.reason)
        XCTAssertTrue(
            reason.localizedCaseInsensitiveContains("missing"),
            "expected an explicit missing-source reason, got \(reason)"
        )
    }

    func testCleanupAuthorizationFailsWhenSourceManifestMissing() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        try FileManager.default.removeItem(at: SourceAssociation.sidecarURL(inBookFolder: fixture.dir))
        XCTAssertNil(SourceAssociation.load(inBookFolder: fixture.dir))

        let auth = SourceCleanup.authorization(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertFalse(auth.allowed, "Matching dest identity is not enough without source provenance")
        let reason = try XCTUnwrap(auth.reason)
        XCTAssertTrue(
            reason.localizedCaseInsensitiveContains("provenance")
                || reason.localizedCaseInsensitiveContains("manifest"),
            "expected a missing-provenance reason, got \(reason)"
        )
        XCTAssertTrue(auth.sources.isEmpty)
    }

    func testCleanupAuthorizationFailsWhenSourceManifestUnreadable() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        try Data("not-json".utf8).write(to: SourceAssociation.sidecarURL(inBookFolder: fixture.dir))
        XCTAssertNil(SourceAssociation.load(inBookFolder: fixture.dir))

        let auth = SourceCleanup.authorization(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertFalse(auth.allowed)
    }

    func testCleanupAuthorizationAllowsRemainingAfterAlreadyMovedSource() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        try FileManager.default.removeItem(at: fixture.sourceA)
        let denied = SourceCleanup.authorization(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertFalse(denied.allowed)

        let allowed = SourceCleanup.authorization(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false,
            alreadyMoved: [fixture.sourceA]
        )
        XCTAssertTrue(allowed.allowed)
        XCTAssertEqual(allowed.sources.map(\.lastPathComponent), ["02.mp3"])
    }

    func testSourceFilesToRemoveIntersectsManifestAndSkipsDirectory() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        let extra = fixture.dir.appendingPathComponent("sneaky.mp3")
        try Data(count: 8).write(to: extra)
        var book = fixture.book
        book.chapters.append(TestSupport.dummyChapter(index: 3, url: extra, duration: 10))

        let files = M4BInspector.sourceFilesToRemove(from: book)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["01.mp3", "02.mp3"])
        XCTAssertFalse(files.contains { $0.lastPathComponent == "sneaky.mp3" })

        try FileManager.default.removeItem(at: fixture.sourceB)
        try FileManager.default.createDirectory(at: fixture.sourceB, withIntermediateDirectories: true)
        let afterDir = M4BInspector.sourceFilesToRemove(from: book)
        XCTAssertEqual(afterDir.map(\.lastPathComponent), ["01.mp3"])
    }

    func testExportRecordsSourceAssociationSidecar() async throws {
        let dir = try TestSupport.tempDir("source-sidecar")
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
        let book = Audiobook(folder: dir, title: "Sidecar", author: "A", chapters: [chapter])
        let dest = dir.appendingPathComponent("out.m4b")
        try await M4BExporter(bitrate: 48_000).export(book: book, to: dest, overwrite: true)

        let entries = try XCTUnwrap(SourceAssociation.load(inBookFolder: dir))
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].isRegularFile)
        XCTAssertGreaterThan(entries[0].fileSize, 0)
        XCTAssertNotNil(entries[0].modificationDate)
        XCTAssertEqual(
            URL(fileURLWithPath: entries[0].path).standardizedFileURL.path,
            wav.standardizedFileURL.path
        )
        XCTAssertFalse(M4BExporter.isSameFileURL(URL(fileURLWithPath: entries[0].path), dest))
    }
}

private struct CleanupFixture {
    var dir: URL
    var dest: URL
    var sourceA: URL
    var sourceB: URL
    var book: Audiobook
    var inspection: M4BInspection

    static func make() throws -> CleanupFixture {
        let dir = try TestSupport.tempDir("cleanup-auth")
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
        SourceAssociation.record([sourceA, sourceB], dest: dest, inBookFolder: dir)

        let inspection = M4BInspection.capturingIdentity(
            url: dest,
            duration: 30,
            chapters: [
                ChapterMark(start: 0, duration: 10, title: "One"),
                ChapterMark(start: 10, duration: 20, title: "Two")
            ],
            bookID: book.id
        )
        return CleanupFixture(
            dir: dir,
            dest: dest,
            sourceA: sourceA,
            sourceB: sourceB,
            book: book,
            inspection: inspection
        )
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }
}

private func replaceFile(at url: URL, with data: Data) throws {
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
    try data.write(to: tmp)
    _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
}

private func appendChplEntry(_ payload: inout Data, start: TimeInterval, title: String) {
    payload.append(MP4Box.u64(UInt64(max(0, start) * 10_000_000)))
    let bytes = Data(title.utf8)
    payload.append(UInt8(bytes.count))
    payload.append(bytes)
}

private func parseQuickTimeTextSample(_ payload: Data) -> (length: Int, text: Data) {
    precondition(payload.count >= 2)
    let length = Int(UInt16(payload[0]) << 8 | UInt16(payload[1]))
    precondition(payload.count >= 2 + length)
    return (length, payload.subdata(in: 2..<(2 + length)))
}
