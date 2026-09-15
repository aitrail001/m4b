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

    func testApplyThrowsAndLeavesOriginalWhenMdatTruncatedAfterMoov() throws {
        let dir = try TestSupport.tempDir("tag-trunc-mdat")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("partial.m4a")
        let original = Self.truncatedMdatAfterMoov()
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
        XCTAssertEqual(leftovers.map(\.lastPathComponent), ["partial.m4a"])
    }

    func testApplyTagsValidMinimalMP4() throws {
        let dir = try TestSupport.tempDir("tag-valid")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ok.m4a")
        let original = Self.minimalTaggableMP4()
        try original.write(to: url)
        XCTAssertNoThrow(
            try MP4AudiobookTagger.apply(
                to: url,
                tags: AudiobookTags(title: "Tagged", author: "Author"),
                chapters: []
            )
        )
        let tagged = try Data(contentsOf: url)
        XCTAssertNotEqual(tagged, original)
        XCTAssertGreaterThan(tagged.count, original.count)
        let atoms = try MP4AtomIO.parseHeadersComplete(tagged, range: 0..<tagged.count)
        XCTAssertTrue(atoms.contains(where: { $0.type == "moov" }))
        XCTAssertNotNil(tagged.range(of: MP4Box.fourcc("©nam")))
        let leftovers = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(leftovers.map(\.lastPathComponent), ["ok.m4a"])
    }

    func testReadMovieHeaderRejectsShortMvhdEvenWhenSiblingIsLong() {
        let moov = Self.moovWithShortMvhdAndLongSibling()
        XCTAssertThrowsError(try MP4AudiobookTagger.readMovieHeader(moov)) { error in
            guard case BinderError.exportFailed = error else {
                return XCTFail("\(error)")
            }
        }
    }

    func testMaxTrackIDIgnoresShortTkhdAndDoesNotReadSibling() throws {
        let fakeID: UInt32 = 0xFFFF_FFFE
        let shortOnly = Self.moovWithShortTkhdAndLongSibling(fakeTrackID: fakeID)
        XCTAssertEqual(try MP4AudiobookTagger.maxTrackID(in: shortOnly), 0)
        XCTAssertNotEqual(try MP4AudiobookTagger.maxTrackID(in: shortOnly), fakeID)

        let mixed = Self.moovWithShortTkhdSiblingAndValidTrack(fakeTrackID: fakeID, validTrackID: 3)
        XCTAssertEqual(try MP4AudiobookTagger.maxTrackID(in: mixed), 3)
        XCTAssertNotEqual(try MP4AudiobookTagger.maxTrackID(in: mixed), fakeID)
    }

    func testAllocateChapterTrackIDThrowsWhenNextTrackIDIsUInt32Max() {
        XCTAssertThrowsError(
            try MP4AudiobookTagger.allocateChapterTrackID(nextTrackID: .max, maxTrackID: 1)
        ) { error in
            guard case BinderError.exportFailed = error else {
                return XCTFail("\(error)")
            }
        }
    }

    func testAllocateChapterTrackIDThrowsWhenMaxTrackIDIsUInt32Max() {
        XCTAssertThrowsError(
            try MP4AudiobookTagger.allocateChapterTrackID(nextTrackID: 2, maxTrackID: .max)
        ) { error in
            guard case BinderError.exportFailed = error else {
                return XCTFail("\(error)")
            }
        }
    }

    func testReadMovieHeaderParsesValidTinyMvhdV0() throws {
        let header = try MP4AudiobookTagger.readMovieHeader(Self.validTinyMvhdV0Moov())
        XCTAssertEqual(header.version, 0)
        XCTAssertEqual(header.timescale, 1000)
        XCTAssertEqual(header.duration, 5000)
        XCTAssertEqual(header.nextTrackID, 2)
        XCTAssertEqual(
            try MP4AudiobookTagger.allocateChapterTrackID(
                nextTrackID: header.nextTrackID,
                maxTrackID: 1
            ),
            2
        )
    }

    func testReadMovieHeaderRejectsUnsupportedVersion() {
        var mvhd = Data(count: 100)
        mvhd[0] = 2
        mvhd.replaceSubrange(12..<16, with: MP4Box.u32(1000))
        mvhd.replaceSubrange(16..<20, with: MP4Box.u32(1000))
        mvhd.replaceSubrange(96..<100, with: MP4Box.u32(2))
        let moov = MP4Box.box("moov", MP4Box.box("mvhd", mvhd))
        XCTAssertThrowsError(try MP4AudiobookTagger.readMovieHeader(moov)) { error in
            guard case BinderError.exportFailed = error else {
                return XCTFail("\(error)")
            }
        }
    }

    func testApplyThrowsAndLeavesOriginalWhenNextTrackIDIsUInt32Max() throws {
        let dir = try TestSupport.tempDir("tag-nextid-max")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("max-next.m4a")
        let original = Self.minimalTaggableMP4(nextTrackID: .max)
        try original.write(to: url)
        XCTAssertThrowsError(
            try MP4AudiobookTagger.apply(
                to: url,
                tags: AudiobookTags(title: "T", author: "A"),
                chapters: [ChapterMark(start: 0, duration: 1, title: "One")]
            )
        ) { error in
            guard case BinderError.exportFailed = error else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
        let leftovers = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(leftovers.map(\.lastPathComponent), ["max-next.m4a"])
    }

    func testApplyThrowsAndLeavesOriginalWhenMoovExceedsNestedAtomBudget() throws {
        let dir = try TestSupport.tempDir("tag-moov-budget")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("moov-budget.m4a")
        let original = Self.moovOverNestedAtomBudgetFile()
        try original.write(to: url)

        let top = try MP4AtomIO.parseHeadersComplete(original, range: 0..<original.count)
        XCTAssertEqual(top.map(\.type), ["ftyp", "moov", "mdat"])
        let moov = try XCTUnwrap(top.first(where: { $0.type == "moov" }))
        let payloadStart = try XCTUnwrap(Int(exactly: moov.payloadOffset))
        let payloadEnd = try XCTUnwrap(Int(exactly: moov.end))
        XCTAssertThrowsError(try MP4AtomIO.parseHeadersComplete(original, range: payloadStart..<payloadEnd))

        try assertApplyThrowsLeavesOriginalAndNoScratch(url: url, original: original, fileName: "moov-budget.m4a")
    }

    func testApplyThrowsAndLeavesOriginalWhenTrakHasTrailingTruncatedChild() throws {
        let dir = try TestSupport.tempDir("tag-trak-trunc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("trak-trunc.m4a")
        let original = Self.fileWithTrailingTruncatedChild(in: .trak)
        try original.write(to: url)

        let top = try MP4AtomIO.parseHeadersComplete(original, range: 0..<original.count)
        XCTAssertEqual(top.map(\.type), ["ftyp", "moov", "mdat"])

        try assertApplyThrowsLeavesOriginalAndNoScratch(url: url, original: original, fileName: "trak-trunc.m4a")
    }

    func testApplyThrowsAndLeavesOriginalWhenUdtaNestedParseIsIncomplete() throws {
        let dir = try TestSupport.tempDir("tag-udta-trunc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("udta-trunc.m4a")
        let original = Self.fileWithTrailingTruncatedChild(in: .udta)
        try original.write(to: url)

        let top = try MP4AtomIO.parseHeadersComplete(original, range: 0..<original.count)
        XCTAssertEqual(top.map(\.type), ["ftyp", "moov", "mdat"])

        try assertApplyThrowsLeavesOriginalAndNoScratch(url: url, original: original, fileName: "udta-trunc.m4a")
    }

    private func assertApplyThrowsLeavesOriginalAndNoScratch(url: URL, original: Data, fileName: String) throws {
        XCTAssertThrowsError(
            try MP4AudiobookTagger.apply(
                to: url,
                tags: AudiobookTags(title: "T", author: "A"),
                chapters: []
            )
        )
        XCTAssertEqual(try Data(contentsOf: url), original)
        let dir = url.deletingLastPathComponent()
        let leftovers = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(leftovers.map(\.lastPathComponent), [fileName])
        XCTAssertFalse(leftovers.contains { $0.lastPathComponent.contains("tagging") })
    }

    static func truncatedMdatAfterMoov() -> Data {
        let moov = MP4Box.box("moov", MP4Box.box("mvhd", Data(count: 100)))
        var mdat = Data()
        mdat.append(MP4Box.u32(1000))
        mdat.append(MP4Box.fourcc("mdat"))
        mdat.append(Data(count: 4))
        return moov + mdat
    }

    static func minimalTaggableMP4(nextTrackID: UInt32 = 2) -> Data {
        wrapTaggableFile(moovPayload: validMvhdV0(nextTrackID: nextTrackID))
    }

    /// `moov` with a valid `mvhd`, 9,999 empty `free` children, and a trailing `trak`
    /// (10,001 nested atoms). Top-level complete parse succeeds; nested `moov` parse does not.
    static func moovOverNestedAtomBudgetFile() -> Data {
        let free = MP4Box.box("free", Data())
        var payload = Data()
        payload.reserveCapacity(validMvhdV0().count + (MP4AtomIO.maxHeadersPerParse * 8))
        payload.append(validMvhdV0())
        for _ in 0..<(MP4AtomIO.maxHeadersPerParse - 1) {
            payload.append(free)
        }
        payload.append(MP4Box.box("trak", Data()))
        return wrapTaggableFile(moovPayload: payload)
    }

    enum NestedTruncationContainer {
        case trak
        case udta
    }

    /// Valid `mvhd` plus a `trak` or `udta` whose own children end in a truncated atom.
    static func fileWithTrailingTruncatedChild(in container: NestedTruncationContainer) -> Data {
        let truncatedTail = Data([0, 0, 0, 8])
        let nested: Data
        switch container {
        case .trak:
            nested = MP4Box.box("trak", validTkhd(trackID: 1) + truncatedTail)
        case .udta:
            let meta = MP4Box.box("meta", MP4Box.u32(0))
            nested = MP4Box.box("udta", meta + truncatedTail)
        }
        return wrapTaggableFile(moovPayload: validMvhdV0() + nested)
    }

    static func wrapTaggableFile(moovPayload: Data) -> Data {
        let ftyp = MP4Box.box(
            "ftyp",
            MP4Box.fourcc("M4A ") + MP4Box.u32(0) + MP4Box.fourcc("M4A ") + MP4Box.fourcc("mp42")
        )
        return ftyp + MP4Box.box("moov", moovPayload) + MP4Box.box("mdat", Data(count: 8))
    }

    static func validMvhdV0(nextTrackID: UInt32 = 2) -> Data {
        var mvhd = Data(count: 100)
        mvhd.replaceSubrange(12..<16, with: MP4Box.u32(1000))
        mvhd.replaceSubrange(16..<20, with: MP4Box.u32(1000))
        mvhd.replaceSubrange(20..<24, with: MP4Box.u32(0x00010000))
        mvhd.replaceSubrange(24..<26, with: MP4Box.u16(0x0100))
        mvhd.replaceSubrange(36..<40, with: MP4Box.u32(0x00010000))
        mvhd.replaceSubrange(52..<56, with: MP4Box.u32(0x00010000))
        mvhd.replaceSubrange(68..<72, with: MP4Box.u32(0x40000000))
        mvhd.replaceSubrange(96..<100, with: MP4Box.u32(nextTrackID))
        return MP4Box.box("mvhd", mvhd)
    }

    static func validTkhd(trackID: UInt32) -> Data {
        var tkhd = Data(count: 84)
        tkhd.replaceSubrange(12..<16, with: MP4Box.u32(trackID))
        return MP4Box.box("tkhd", tkhd)
    }

    /// 4-byte `mvhd` payload plus a long sibling planted with distinctive field values
    /// at the unbounded v0 offsets (`timescale` / `duration` / `next_track_ID`).
    static func moovWithShortMvhdAndLongSibling() -> Data {
        let shortMvhd = MP4Box.box("mvhd", Data([0, 0, 0, 0]))
        var siblingPayload = Data(count: 96)
        siblingPayload.replaceSubrange(0..<4, with: MP4Box.u32(0xDEAD_BEEF))
        siblingPayload.replaceSubrange(4..<8, with: MP4Box.u32(0xCAFE_BABE))
        siblingPayload.replaceSubrange(84..<88, with: MP4Box.u32(0x0BAD_F00D))
        return MP4Box.box("moov", shortMvhd + MP4Box.box("free", siblingPayload))
    }

    static func moovWithShortTkhdAndLongSibling(fakeTrackID: UInt32) -> Data {
        MP4Box.box("moov", shortTkhdTrak(fakeTrackID: fakeTrackID))
    }

    static func moovWithShortTkhdSiblingAndValidTrack(fakeTrackID: UInt32, validTrackID: UInt32) -> Data {
        MP4Box.box("moov", shortTkhdTrak(fakeTrackID: fakeTrackID) + validTkhdTrak(trackID: validTrackID))
    }

    static func validTinyMvhdV0Moov() -> Data {
        var mvhd = Data(count: 100)
        mvhd.replaceSubrange(12..<16, with: MP4Box.u32(1000))
        mvhd.replaceSubrange(16..<20, with: MP4Box.u32(5000))
        mvhd.replaceSubrange(96..<100, with: MP4Box.u32(2))
        return MP4Box.box("moov", MP4Box.box("mvhd", mvhd))
    }

    private static func shortTkhdTrak(fakeTrackID: UInt32) -> Data {
        let shortTkhd = MP4Box.box("tkhd", Data([0, 0, 0, 0]))
        var siblingPayload = Data(count: 32)
        siblingPayload.replaceSubrange(0..<4, with: MP4Box.u32(fakeTrackID))
        return MP4Box.box("trak", shortTkhd + MP4Box.box("free", siblingPayload))
    }

    private static func validTkhdTrak(trackID: UInt32) -> Data {
        var tkhd = Data(count: 84)
        tkhd.replaceSubrange(12..<16, with: MP4Box.u32(trackID))
        return MP4Box.box("trak", MP4Box.box("tkhd", tkhd))
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

    func testNeroChaptersFindsSmallChplInSparseLargeFile() throws {
        let dir = try TestSupport.tempDir("nero-sparse")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sparse.m4b")
        try writeSparseM4B(
            at: url,
            advertisedFileSize: 64 * 1024 * 1024,
            chapterTitle: "Sparse Chapter"
        )
        let marks = M4BInspector.neroChapters(in: url, duration: 10)
        XCTAssertEqual(marks.map(\.title), ["Sparse Chapter"])
        XCTAssertEqual(marks.first?.start, 0)
    }

    func testNeroChaptersReturnsEmptyWhenChplExceedsBudget() throws {
        let dir = try TestSupport.tempDir("nero-chpl-oversize")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("huge-chpl.m4b")
        try writeSparseFileWithOversizedChpl(
            at: url,
            chplSize: UInt64(MP4AtomIO.maxChapterAtomBytes) + 1
        )
        XCTAssertEqual(M4BInspector.neroChapters(in: url, duration: 10), [])
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

    func testShouldCommitInspectionAcceptsAlternateResourceIdentifierArchive() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        let live = try XCTUnwrap(FileIdentity.read(from: fixture.dest))
        let originalRID = try XCTUnwrap(live.fileResourceIdentifier)
        let alternate = try XCTUnwrap(FileIdentity.alternateResourceIdentifierArchive(originalRID))
        XCTAssertNotEqual(alternate, originalRID)
        let swapped = live.replacingResourceIdentifier(alternate)
        XCTAssertTrue(live.isSameVersion(as: swapped))
        XCTAssertTrue(swapped.matches(fixture.inspection))

        var inspection = fixture.inspection
        inspection.fileResourceIdentifier = alternate
        inspection.identityGeneration = (swapped.generationToken()) + "|alt-archive"
        let requested = try XCTUnwrap(SourceCleanup.destGeneration(of: fixture.dest))
        XCTAssertNotEqual(inspection.identityGeneration, requested)
        XCTAssertNotEqual(inspection.identityGeneration, live.generationToken())

        XCTAssertTrue(
            SourceCleanup.shouldCommitInspection(
                inspection,
                bookID: fixture.book.id,
                requestedURL: fixture.dest,
                currentURL: fixture.dest,
                requestedGeneration: requested
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

    func testCleanupAuthorizationFailsWhenSourceSidecarExceedsBudget() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        XCTAssertTrue(
            SourceCleanup.authorization(
                book: fixture.book,
                inspection: fixture.inspection,
                isBuilding: false
            ).allowed
        )

        let sidecar = SourceAssociation.sidecarURL(inBookFolder: fixture.dir)
        let original = try Data(contentsOf: sidecar)
        let handle = try FileHandle(forWritingTo: sidecar)
        try handle.write(contentsOf: Data(repeating: UInt8(ascii: " "), count: SourceAssociation.maxSidecarBytes + 1))
        try handle.write(contentsOf: original)
        try handle.close()

        XCTAssertNil(SourceAssociation.load(inBookFolder: fixture.dir))
        XCTAssertNil(SourceAssociation.loadDocument(inBookFolder: fixture.dir))

        let auth = SourceCleanup.authorization(
            book: fixture.book,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertFalse(auth.allowed)
        let reason = try XCTUnwrap(auth.reason)
        XCTAssertTrue(
            reason.localizedCaseInsensitiveContains("provenance")
                || reason.localizedCaseInsensitiveContains("manifest"),
            "expected a missing-provenance reason, got \(reason)"
        )
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

    func testCleanupAuthorizationAllowsRemainingAfterPartialReconcileWithoutAlreadyMoved() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        let sidecar = SourceAssociation.sidecarURL(inBookFolder: fixture.dir)
        let sidecarBefore = try Data(contentsOf: sidecar)
        try FileManager.default.removeItem(at: fixture.sourceA)

        var remaining = fixture.book
        remaining.chapters = SourceCleanup.reconcile(
            chapters: fixture.book.chapters,
            moved: [fixture.sourceA]
        )
        XCTAssertEqual(remaining.chapters.map(\.url.lastPathComponent), ["02.mp3"])
        XCTAssertFalse(
            ChapterCompare.summary(
                original: remaining.chapters,
                bound: M4BInspector.playableChapters(from: fixture.inspection),
                boundDuration: fixture.inspection.duration
            ).allMatch,
            "partial reconcile leaves fewer originals than the bound .m4b"
        )

        let auth = SourceCleanup.authorization(
            book: remaining,
            inspection: fixture.inspection,
            isBuilding: false,
            alreadyMoved: []
        )
        XCTAssertTrue(auth.allowed)
        XCTAssertEqual(auth.sources.map(\.lastPathComponent), ["02.mp3"])
        XCTAssertEqual(
            try Data(contentsOf: sidecar),
            sidecarBefore,
            "partial cleanup must not rewrite or delete export provenance"
        )
        XCTAssertEqual(SourceAssociation.load(inBookFolder: fixture.dir)?.count, 2)
    }

    func testCleanupAuthorizationAllowsWhenNeverExportedExtraChapterIsListed() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        let extra = fixture.dir.appendingPathComponent("whole-book.mp3")
        try Data(count: 16).write(to: extra)
        var book = fixture.book
        book.chapters.append(
            TestSupport.dummyChapter(index: 3, url: extra, duration: 30, included: false)
        )
        XCTAssertFalse(
            ChapterCompare.summary(
                original: book.chapters,
                bound: M4BInspector.playableChapters(from: fixture.inspection),
                boundDuration: fixture.inspection.duration
            ).allMatch,
            "never-exported extra must not be part of the bound chapter list"
        )

        let auth = SourceCleanup.authorization(
            book: book,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertTrue(auth.allowed)
        XCTAssertEqual(auth.sources.map(\.lastPathComponent), ["01.mp3", "02.mp3"])
        XCTAssertFalse(auth.sources.contains { $0.lastPathComponent == "whole-book.mp3" })
        XCTAssertEqual(SourceAssociation.load(inBookFolder: fixture.dir)?.count, 2)
    }

    func testCleanupAuthorizationFailsWhenRecordedChapterDurationMismatchesBound() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        let extra = fixture.dir.appendingPathComponent("whole-book.mp3")
        try Data(count: 16).write(to: extra)
        var book = fixture.book
        book.chapters[1].duration = 99
        book.chapters.append(
            TestSupport.dummyChapter(index: 3, url: extra, duration: 30, included: false)
        )
        XCTAssertFalse(
            ChapterCompare.summary(
                original: Array(book.chapters.prefix(2)),
                bound: M4BInspector.playableChapters(from: fixture.inspection),
                boundDuration: fixture.inspection.duration
            ).allMatch,
            "recorded 02.mp3 duration must not match the bound chapter"
        )

        let auth = SourceCleanup.authorization(
            book: book,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertFalse(auth.allowed)
        XCTAssertEqual(auth.reason, "Original chapters do not match the .m4b.")
        XCTAssertEqual(auth.sources.map(\.lastPathComponent), ["01.mp3", "02.mp3"])
    }

    func testCleanupAuthorizationAllowsWhenRecordedChapterDeselectedAfterExport() throws {
        let fixture = try CleanupFixture.make()
        defer { fixture.tearDown() }

        var book = fixture.book
        book.chapters[1].included = false
        XCTAssertEqual(book.includedChapters.map(\.url.lastPathComponent), ["01.mp3"])
        XCTAssertTrue(
            ChapterCompare.summary(
                original: book.chapters,
                bound: M4BInspector.playableChapters(from: fixture.inspection),
                boundDuration: fixture.inspection.duration
            ).allMatch
        )

        let auth = SourceCleanup.authorization(
            book: book,
            inspection: fixture.inspection,
            isBuilding: false
        )
        XCTAssertTrue(auth.allowed, "deselected-after-export chapters remain in provenance")
        XCTAssertEqual(auth.sources.map(\.lastPathComponent), ["01.mp3", "02.mp3"])
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

    func testInspectRejectsCommitWhenDestReplacedAfterMetadata() async throws {
        let fixture = try await ExportedInspectFixture.make()
        defer { fixture.tearDown() }

        let requestedGeneration = SourceCleanup.destGeneration(of: fixture.dest)
        let originalChapters = await M4BInspector.inspect(fixture.dest, bookID: fixture.book.id).chapters
        XCTAssertFalse(originalChapters.isEmpty)

        let inspection = await M4BInspector.inspect(
            fixture.dest,
            bookID: fixture.book.id,
            identityBarrier: { dest in
                try? Data(count: 256).write(to: dest)
            }
        )

        assertInspectDidNotCommit(
            inspection,
            book: fixture.book,
            dest: fixture.dest,
            requestedGeneration: requestedGeneration
        )
        XCTAssertNotEqual(
            inspection.fileSize,
            256,
            "Must not attach the replacement's identity to the original chapter list"
        )
    }

    func testInspectRejectsCommitWhenDestDeletedAfterMetadata() async throws {
        let fixture = try await ExportedInspectFixture.make()
        defer { fixture.tearDown() }

        let requestedGeneration = SourceCleanup.destGeneration(of: fixture.dest)
        let inspection = await M4BInspector.inspect(
            fixture.dest,
            bookID: fixture.book.id,
            identityBarrier: { dest in
                try? FileManager.default.removeItem(at: dest)
            }
        )

        assertInspectDidNotCommit(
            inspection,
            book: fixture.book,
            dest: fixture.dest,
            requestedGeneration: requestedGeneration
        )
    }

    func testInspectRejectsCommitWhenDestReplacedSameSizeAfterMetadata() async throws {
        let fixture = try await ExportedInspectFixture.make()
        defer { fixture.tearDown() }

        let originalSize = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: fixture.dest.path)[.size] as? NSNumber)?.intValue
        )
        let requestedGeneration = SourceCleanup.destGeneration(of: fixture.dest)
        let inspection = await M4BInspector.inspect(
            fixture.dest,
            bookID: fixture.book.id,
            identityBarrier: { dest in
                try? replaceFile(at: dest, with: Data(repeating: 0xEF, count: originalSize))
            }
        )

        assertInspectDidNotCommit(
            inspection,
            book: fixture.book,
            dest: fixture.dest,
            requestedGeneration: requestedGeneration
        )
        if let live = FileIdentity.read(from: fixture.dest) {
            XCTAssertFalse(
                live.matches(inspection) && inspection.identityVerified,
                "Same-size replace must not look like a verified snapshot of the new dest"
            )
        }
    }

    func testInspectUnchangedDestStillCommitsAndAuthorizes() async throws {
        let fixture = try await ExportedInspectFixture.make()
        defer { fixture.tearDown() }

        let requestedGeneration = SourceCleanup.destGeneration(of: fixture.dest)
        let inspection = await M4BInspector.inspect(fixture.dest, bookID: fixture.book.id)
        XCTAssertTrue(inspection.identityVerified)
        XCTAssertGreaterThan(inspection.duration, 0.2)
        XCTAssertFalse(inspection.chapters.isEmpty)
        XCTAssertTrue(
            SourceCleanup.shouldCommitInspection(
                inspection,
                bookID: fixture.book.id,
                requestedURL: fixture.dest,
                currentURL: fixture.book.existingM4BURL
            )
        )
        XCTAssertTrue(
            SourceCleanup.shouldCommitInspection(
                inspection,
                bookID: fixture.book.id,
                requestedURL: fixture.dest,
                currentURL: fixture.book.existingM4BURL,
                requestedGeneration: requestedGeneration
            )
        )
        let auth = SourceCleanup.authorization(
            book: fixture.book,
            inspection: inspection,
            isBuilding: false
        )
        XCTAssertTrue(auth.allowed)

        let cached = try CleanupFixture.make()
        defer { cached.tearDown() }
        XCTAssertTrue(
            SourceCleanup.authorization(
                book: cached.book,
                inspection: cached.inspection,
                isBuilding: false
            ).allowed
        )
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
        let document = try XCTUnwrap(SourceAssociation.loadDocument(inBookFolder: dir))
        let destDigest = try XCTUnwrap(document.destinationSHA256)
        XCTAssertFalse(destDigest.isEmpty)
        XCTAssertEqual(destDigest, try XCTUnwrap(SourceAssociation.sha256Hex(of: dest)))
    }
}

private struct ExportedInspectFixture {
    var dir: URL
    var dest: URL
    var book: Audiobook

    static func make() async throws -> ExportedInspectFixture {
        let dir = try TestSupport.tempDir("inspect-race")
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
        var book = Audiobook(folder: dir, title: "Inspect Race", author: "A", chapters: [chapter])
        let dest = dir.appendingPathComponent("out.m4b")
        try await M4BExporter(bitrate: 48_000).export(book: book, to: dest, overwrite: true)
        book.existingM4BURL = dest
        return ExportedInspectFixture(dir: dir, dest: dest, book: book)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }
}

private func assertInspectDidNotCommit(
    _ inspection: M4BInspection,
    book: Audiobook,
    dest: URL,
    requestedGeneration: String?,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertFalse(inspection.identityVerified, "inspection must not be marked verified", file: file, line: line)
    XCTAssertFalse(
        SourceCleanup.shouldCommitInspection(
            inspection,
            bookID: book.id,
            requestedURL: dest,
            currentURL: dest
        ),
        file: file,
        line: line
    )
    XCTAssertFalse(
        SourceCleanup.shouldCommitInspection(
            inspection,
            bookID: book.id,
            requestedURL: dest,
            currentURL: book.existingM4BURL,
            requestedGeneration: requestedGeneration
        ),
        file: file,
        line: line
    )
    XCTAssertFalse(
        SourceCleanup.authorization(
            book: book,
            inspection: inspection,
            isBuilding: false
        ).allowed,
        file: file,
        line: line
    )
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

private func writeSparseM4B(at url: URL, advertisedFileSize: UInt64, chapterTitle: String) throws {
    let ftyp = MP4Box.box(
        "ftyp",
        MP4Box.fourcc("M4A ") + MP4Box.u32(0) + MP4Box.fourcc("M4A ")
    )
    let chpl = MP4AudiobookTagger.makeChpl([
        ChapterMark(start: 0, duration: 1, title: chapterTitle)
    ])
    let moov = MP4Box.box("moov", MP4Box.box("udta", chpl))
    let prefix = UInt64(ftyp.count)
    let suffix = UInt64(moov.count)
    precondition(advertisedFileSize > prefix + suffix + 8)
    let mdatSize = advertisedFileSize - prefix - suffix
    guard let mdatSize32 = UInt32(exactly: mdatSize) else {
        throw BinderError.exportFailed("mdat size does not fit in 32 bits")
    }

    XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: ftyp)
    try handle.write(contentsOf: MP4Box.u32(mdatSize32) + MP4Box.fourcc("mdat"))
    try handle.truncate(atOffset: prefix + mdatSize)
    try handle.seek(toOffset: prefix + mdatSize)
    try handle.write(contentsOf: moov)
    try handle.close()
}

private func writeSparseFileWithOversizedChpl(at url: URL, chplSize: UInt64) throws {
    let ftyp = MP4Box.box(
        "ftyp",
        MP4Box.fourcc("M4A ") + MP4Box.u32(0) + MP4Box.fourcc("M4A ")
    )
    guard let chplSize32 = UInt32(exactly: chplSize),
          let udtaSize32 = UInt32(exactly: 8 + chplSize),
          let moovSize32 = UInt32(exactly: 16 + chplSize)
    else {
        throw BinderError.exportFailed("oversized chpl fixture does not fit in 32-bit atom sizes")
    }

    XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: ftyp)
    try handle.write(contentsOf: MP4Box.u32(moovSize32) + MP4Box.fourcc("moov"))
    try handle.write(contentsOf: MP4Box.u32(udtaSize32) + MP4Box.fourcc("udta"))
    try handle.write(contentsOf: MP4Box.u32(chplSize32) + MP4Box.fourcc("chpl"))
    try handle.truncate(atOffset: UInt64(ftyp.count) + UInt64(moovSize32))
    try handle.close()
}
