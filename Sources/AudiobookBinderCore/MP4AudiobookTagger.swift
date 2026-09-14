import Foundation

public struct ChapterMark: Sendable, Equatable {
    public var start: TimeInterval
    public var duration: TimeInterval
    public var title: String

    public init(start: TimeInterval, duration: TimeInterval, title: String) {
        self.start = start
        self.duration = duration
        self.title = title
    }
}

public struct AudiobookTags: Sendable {
    public var title: String
    public var author: String
    public var album: String
    public var narrator: String
    public var genre: String
    public var comment: String
    public var coverJPEG: Data?

    public init(
        title: String,
        author: String,
        album: String? = nil,
        narrator: String = "",
        genre: String = "Audiobook",
        comment: String = "",
        coverJPEG: Data? = nil
    ) {
        self.title = title
        self.author = author
        self.album = album ?? title
        self.narrator = narrator
        self.genre = genre
        self.comment = comment
        self.coverJPEG = coverJPEG
    }
}

/// Rewrites an M4A/M4B so Apple Books treats it as an audiobook:
/// `stik=2`, iTunes tags, cover, Nero `chpl`, and a QuickTime chapter track.
public enum MP4AudiobookTagger {
    public static func apply(
        to url: URL,
        tags: AudiobookTags,
        chapters: [ChapterMark]
    ) throws {
        try validateChapters(chapters)
        let original = try Data(contentsOf: url, options: [.mappedIfSafe])
        let top = MP4AtomIO.parseHeaders(original, range: 0..<original.count)
        guard let moovHeader = top.first(where: { $0.type == "moov" }) else {
            throw BinderError.exportFailed("No moov atom in exported audio")
        }

        var rebuilt = Data()
        rebuilt.reserveCapacity(original.count + 64_000)

        for atom in top {
            if atom.type == "moov" {
                guard let size = Int(exactly: atom.size), size >= 8 else { continue }
                rebuilt.append(MP4Box.box("free", Data(count: size - 8)))
            } else {
                rebuilt.append(MP4AtomIO.slice(original, atom))
            }
        }

        let moovData = MP4AtomIO.slice(original, moovHeader)
        let extra = try buildExtras(
            originalMoov: moovData,
            tags: tags,
            chapters: chapters,
            extraMdatFileOffset: UInt64(rebuilt.count)
        )
        rebuilt.append(extra.mdat)
        rebuilt.append(extra.moov)
        try rebuilt.write(to: url, options: [.atomic])
    }

    private struct Extras {
        var mdat: Data
        var moov: Data
    }

    private static func buildExtras(
        originalMoov: Data,
        tags: AudiobookTags,
        chapters: [ChapterMark],
        extraMdatFileOffset: UInt64
    ) throws -> Extras {
        let mvhd = try readMovieHeader(originalMoov)
        let nextTrackID = max(mvhd.nextTrackID, maxTrackID(in: originalMoov) + 1)
        let chapterTrackID = nextTrackID

        let chapterSamples = chapterSampleData(chapters)
        let extraMdat = MP4Box.box("mdat", chapterSamples.payload)

        var moovPayload = originalMoov.subdata(in: 8..<originalMoov.count)
        moovPayload = replaceNextTrackID(in: moovPayload, next: chapterTrackID + 1)
        moovPayload = upsertItunesMetadata(in: moovPayload, tags: tags)
        moovPayload = addNeroChapters(in: moovPayload, chapters: chapters)

        if !chapters.isEmpty {
            let trak = makeChapterTrack(
                trackID: chapterTrackID,
                movieTimescale: mvhd.timescale,
                movieDuration: mvhd.duration,
                chapters: chapters,
                sampleSizes: chapterSamples.sizes,
                chunkOffset: extraMdatFileOffset + 8
            )
            moovPayload.append(trak)
            moovPayload = addChapterReference(to: moovPayload, chapterTrackID: chapterTrackID)
        }

        return Extras(mdat: extraMdat, moov: MP4Box.box("moov", moovPayload))
    }

    private struct MovieHeader {
        var timescale: UInt32
        var duration: UInt64
        var nextTrackID: UInt32
        var version: UInt8
    }

    private static func readMovieHeader(_ moov: Data) throws -> MovieHeader {
        guard moov.count >= 8 else { throw BinderError.exportFailed("Missing mvhd") }
        let children = MP4AtomIO.parseHeaders(moov, range: 8..<moov.count)
        guard let mvhd = children.first(where: { $0.type == "mvhd" }),
              let start = Int(exactly: mvhd.payloadOffset),
              start < moov.count
        else {
            throw BinderError.exportFailed("Missing mvhd")
        }
        let version = moov[start]
        if version == 1 {
            guard moov.count - start >= 112,
                  let timescale = MP4AtomIO.readU32(moov, start + 20),
                  let duration = MP4AtomIO.readU64(moov, start + 24),
                  let next = MP4AtomIO.readU32(moov, start + 108)
            else {
                throw BinderError.exportFailed("Truncated mvhd")
            }
            return MovieHeader(timescale: timescale, duration: duration, nextTrackID: next, version: version)
        } else {
            guard moov.count - start >= 100,
                  let timescale = MP4AtomIO.readU32(moov, start + 12),
                  let duration32 = MP4AtomIO.readU32(moov, start + 16),
                  let nextTrack = MP4AtomIO.readU32(moov, start + 96)
            else {
                throw BinderError.exportFailed("Truncated mvhd")
            }
            return MovieHeader(timescale: timescale, duration: UInt64(duration32), nextTrackID: nextTrack, version: version)
        }
    }

    private static func maxTrackID(in moov: Data) -> UInt32 {
        var maxID: UInt32 = 0
        guard moov.count >= 8 else { return 0 }
        let traks = MP4AtomIO.parseHeaders(moov, range: 8..<moov.count).filter { $0.type == "trak" }
        for trak in traks {
            guard let trakStart = Int(exactly: trak.payloadOffset),
                  let trakSize = Int(exactly: trak.payloadSize),
                  trakStart >= 0,
                  trakStart <= moov.count,
                  moov.count - trakStart >= trakSize
            else { continue }
            let kids = MP4AtomIO.parseHeaders(moov, range: trakStart..<(trakStart + trakSize))
            guard let tkhd = kids.first(where: { $0.type == "tkhd" }),
                  let start = Int(exactly: tkhd.payloadOffset),
                  start < moov.count
            else { continue }
            let version = moov[start]
            let idDelta = version == 1 ? 20 : 12
            guard moov.count - start >= idDelta + 4,
                  let id = MP4AtomIO.readU32(moov, start + idDelta)
            else { continue }
            maxID = max(maxID, id)
        }
        return maxID
    }

    private static func replaceNextTrackID(in moovPayload: Data, next: UInt32) -> Data {
        var data = moovPayload
        let atoms = MP4AtomIO.parseHeaders(Data(MP4Box.u32(UInt32(data.count + 8)) + MP4Box.fourcc("moov") + data), range: 8..<(data.count + 8))
        // Work on payload offsets: parse as if payload is a sequence of atoms
        let children = parsePayloadAtoms(data)
        guard let mvhd = children.first(where: { $0.type == "mvhd" }),
              let start = Int(exactly: mvhd.payloadOffset),
              start < data.count
        else { return data }
        let version = data[start]
        let idDelta = version == 1 ? 108 : 96
        guard data.count - start >= idDelta + 4 else { return data }
        data.replaceSubrange((start + idDelta)..<(start + idDelta + 4), with: MP4Box.u32(next))
        _ = atoms
        return data
    }

    private static func parsePayloadAtoms(_ payload: Data) -> [MP4AtomHeader] {
        MP4AtomIO.parseHeaders(payload, range: 0..<payload.count)
    }

    private static func upsertItunesMetadata(in moovPayload: Data, tags: AudiobookTags) -> Data {
        var children = splitAtoms(moovPayload)
        if let idx = children.firstIndex(where: { fourCC(of: $0) == "udta" }) {
            children[idx] = rebuildUdta(children[idx], tags: tags)
        } else {
            children.append(makeUdta(tags: tags))
        }
        return children.reduce(into: Data(), { $0.append($1) })
    }

    private static func addNeroChapters(in moovPayload: Data, chapters: [ChapterMark]) -> Data {
        guard !chapters.isEmpty else { return moovPayload }
        var children = splitAtoms(moovPayload)
        if let idx = children.firstIndex(where: { fourCC(of: $0) == "udta" }) {
            var udta = unwrap(children[idx])
            udta.append(makeChpl(chapters))
            children[idx] = MP4Box.box("udta", udta)
        } else {
            children.append(MP4Box.box("udta", makeChpl(chapters)))
        }
        return children.reduce(into: Data(), { $0.append($1) })
    }

    private static func addChapterReference(to moovPayload: Data, chapterTrackID: UInt32) -> Data {
        var children = splitAtoms(moovPayload)
        guard let idx = children.firstIndex(where: { atom in
            fourCC(of: atom) == "trak" && isAudioTrack(atom)
        }) else { return moovPayload }

        var trakKids = splitAtoms(unwrap(children[idx]))
        let tref = MP4Box.box("tref", MP4Box.box("chap", MP4Box.u32(chapterTrackID)))
        if let existing = trakKids.firstIndex(where: { fourCC(of: $0) == "tref" }) {
            trakKids[existing] = tref
        } else {
            trakKids.append(tref)
        }
        children[idx] = MP4Box.box("trak", trakKids.reduce(into: Data(), { $0.append($1) }))
        return children.reduce(into: Data(), { $0.append($1) })
    }

    private static func isAudioTrack(_ trak: Data) -> Bool {
        guard let mdia = child(trak, "mdia"), let hdlr = child(mdia, "hdlr") else { return false }
        // hdlr payload: version/flags 4, componentType 4, componentSubtype 4
        let payload = unwrap(hdlr)
        guard payload.count >= 12 else { return false }
        let subtype = String(bytes: payload[8..<12], encoding: .isoLatin1)
        return subtype == "soun"
    }

    private static func rebuildUdta(_ udta: Data, tags: AudiobookTags) -> Data {
        var kids = splitAtoms(unwrap(udta))
        if let idx = kids.firstIndex(where: { fourCC(of: $0) == "meta" }) {
            kids[idx] = makeMeta(tags: tags)
        } else {
            kids.append(makeMeta(tags: tags))
        }
        return MP4Box.box("udta", kids.reduce(into: Data(), { $0.append($1) }))
    }

    private static func makeUdta(tags: AudiobookTags) -> Data {
        MP4Box.box("udta", makeMeta(tags: tags))
    }

    private static func makeMeta(tags: AudiobookTags) -> Data {
        var payload = Data()
        payload.append(MP4Box.u32(0)) // version/flags
        payload.append(itunesHandler())
        payload.append(makeIlst(tags))
        return MP4Box.box("meta", payload)
    }

    private static func itunesHandler() -> Data {
        var payload = Data()
        payload.append(MP4Box.u32(0)) // version/flags
        payload.append(MP4Box.u32(0)) // component type
        payload.append(MP4Box.fourcc("mdir"))
        payload.append(MP4Box.fourcc("appl"))
        payload.append(MP4Box.u32(0))
        payload.append(MP4Box.u32(0))
        payload.append(MP4Box.u32(0))
        payload.append(Data([0]))
        return MP4Box.box("hdlr", payload)
    }

    private static func makeIlst(_ tags: AudiobookTags) -> Data {
        var items = Data()
        items.append(textItem("©nam", tags.title))
        items.append(textItem("©ART", tags.author))
        items.append(textItem("aART", tags.author))
        items.append(textItem("©alb", tags.album))
        items.append(textItem("©gen", tags.genre))
        items.append(textItem("©too", "Audiobook Binder"))
        if !tags.narrator.isEmpty {
            items.append(textItem("©wrt", tags.narrator))
            items.append(textItem("©com", tags.narrator))
        }
        if !tags.comment.isEmpty {
            let clipped = String(tags.comment.prefix(4000))
            items.append(textItem("©cmt", clipped))
            items.append(textItem("©des", clipped))
            items.append(textItem("ldes", clipped))
        }
        items.append(int8Item("stik", 2))
        items.append(int8Item("rtng", 0))
        if let cover = tags.coverJPEG, !cover.isEmpty {
            items.append(coverItem(cover))
        }
        return MP4Box.box("ilst", items)
    }

    private static func dataAtom(type: UInt32, payload: Data) -> Data {
        var body = Data()
        body.append(MP4Box.u32(type))
        body.append(MP4Box.u32(0)) // locale
        body.append(payload)
        return MP4Box.box("data", body)
    }

    private static func textItem(_ fourcc: String, _ value: String) -> Data {
        MP4Box.box(fourcc, dataAtom(type: 1, payload: Data(value.utf8)))
    }

    private static func int8Item(_ fourcc: String, _ value: UInt8) -> Data {
        MP4Box.box(fourcc, dataAtom(type: 21, payload: Data([value])))
    }

    private static func coverItem(_ jpeg: Data) -> Data {
        MP4Box.box("covr", dataAtom(type: 13, payload: jpeg))
    }

    static func makeChpl(_ chapters: [ChapterMark]) -> Data {
        let limited = chapters.prefix(255)
        var payload = Data()
        payload.append(MP4Box.u32(0x01000000)) // version 1, flags 0
        payload.append(MP4Box.u32(0)) // reserved
        payload.append(UInt8(limited.count))
        for chapter in limited {
            let start100ns = clampedUInt64(max(0, chapter.start) * 10_000_000)
            payload.append(MP4Box.u64(start100ns))
            let title = utf8Prefix(chapter.title, maxBytes: 255)
            payload.append(UInt8(title.count))
            payload.append(title)
        }
        return MP4Box.box("chpl", payload)
    }

    /// Version-aware Nero `chpl` payload. Prefers reserved + 1-byte count (v1);
    /// falls back to the old flags + 32-bit count layout.
    static func parseChpl(_ payload: Data) -> [ChapterMark] {
        let data = Data(payload)
        let conventional = parseChplEntries(data, layout: .conventional)
        if !conventional.isEmpty {
            return conventional
        }
        return parseChplEntries(data, layout: .legacyU32Count)
    }

    private enum ChplCountLayout {
        case conventional
        case legacyU32Count
    }

    private static func parseChplEntries(_ payload: Data, layout: ChplCountLayout) -> [ChapterMark] {
        guard payload.count >= 5 else { return [] }
        var offset = 4
        let count: Int
        switch layout {
        case .conventional:
            if payload[0] == 1 {
                guard payload.count >= 9 else { return [] }
                offset += 4
            }
            guard offset < payload.count else { return [] }
            count = Int(payload[offset])
            offset += 1
        case .legacyU32Count:
            guard payload.count >= 8,
                  let count32 = MP4AtomIO.readU32(payload, offset),
                  let exact = Int(exactly: count32)
            else { return [] }
            count = exact
            offset += 4
        }
        guard count > 0 else { return [] }

        var marks: [ChapterMark] = []
        for _ in 0..<count {
            guard offset <= payload.count - 9,
                  let start100ns = MP4AtomIO.readU64(payload, offset)
            else { break }
            offset += 8
            let titleLen = Int(payload[offset])
            offset += 1
            guard titleLen <= payload.count - offset else { break }
            let titleBytes = payload.subdata(in: offset..<(offset + titleLen))
            let title = String(data: titleBytes, encoding: .utf8) ?? "Chapter"
            offset += titleLen
            marks.append(ChapterMark(start: Double(start100ns) / 10_000_000.0, duration: 0, title: title))
        }
        return marks
    }

    /// Character-boundary UTF-8 prefix shared by Nero `chpl` (255) and QT text samples (65535).
    static func utf8Prefix(_ string: String, maxBytes: Int) -> Data {
        var result = Data()
        result.reserveCapacity(min(maxBytes, string.utf8.count))
        for character in string {
            let piece = Data(String(character).utf8)
            if result.count + piece.count > maxBytes { break }
            result.append(piece)
        }
        return result
    }

    static func validateChapters(_ chapters: [ChapterMark]) throws {
        for (index, chapter) in chapters.enumerated() {
            let n = index + 1
            guard chapter.start.isFinite else {
                throw BinderError.exportFailed("Chapter \(n) start time is not a finite number")
            }
            guard chapter.start >= 0 else {
                throw BinderError.exportFailed("Chapter \(n) start time is negative")
            }
            guard chapter.duration.isFinite else {
                throw BinderError.exportFailed("Chapter \(n) duration is not a finite number")
            }
            guard chapter.duration >= 0 else {
                throw BinderError.exportFailed("Chapter \(n) duration is negative")
            }
            guard String(data: Data(chapter.title.utf8), encoding: .utf8) != nil else {
                throw BinderError.exportFailed("Chapter \(n) title is not representable as UTF-8")
            }
        }
    }

    struct SamplePack: Equatable, Sendable {
        var payload: Data
        var sizes: [UInt32]
    }

    static func chapterSampleData(_ chapters: [ChapterMark]) -> SamplePack {
        var payload = Data()
        var sizes: [UInt32] = []
        for chapter in chapters {
            let utf8 = utf8Prefix(chapter.title, maxBytes: Int(UInt16.max))
            let length = UInt16(exactly: utf8.count) ?? UInt16.max
            let stored = Data(utf8.prefix(Int(length)))
            let sample = MP4Box.u16(length) + stored
            sizes.append(UInt32(clamping: sample.count))
            payload.append(sample)
        }
        return SamplePack(payload: payload, sizes: sizes)
    }

    static func chunkOffsetTable(offset: UInt64) -> Data {
        if let offset32 = UInt32(exactly: offset) {
            var stco = Data()
            stco.append(MP4Box.u32(0))
            stco.append(MP4Box.u32(1))
            stco.append(MP4Box.u32(offset32))
            return MP4Box.box("stco", stco)
        }
        var co64 = Data()
        co64.append(MP4Box.u32(0))
        co64.append(MP4Box.u32(1))
        co64.append(MP4Box.u64(offset))
        return MP4Box.box("co64", co64)
    }

    private static func clampedUInt32(_ value: Double) -> UInt32 {
        guard value.isFinite, value > 0 else { return 0 }
        if value >= Double(UInt32.max) { return .max }
        return UInt32(value)
    }

    private static func clampedUInt64(_ value: Double) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        if value >= Double(UInt64.max) { return .max }
        return UInt64(value)
    }

    private static func makeChapterTrack(
        trackID: UInt32,
        movieTimescale: UInt32,
        movieDuration: UInt64,
        chapters: [ChapterMark],
        sampleSizes: [UInt32],
        chunkOffset: UInt64
    ) -> Data {
        let mediaTimescale: UInt32 = 1000
        let lastEnd = chapters.last.map { $0.start + max($0.duration, 0.001) } ?? 0
        let mediaDuration = clampedUInt32(lastEnd * 1000)
        let tkhdDuration = movieDuration == 0
            ? UInt64(mediaDuration) * UInt64(movieTimescale) / UInt64(mediaTimescale)
            : movieDuration

        let tkhd = makeTkhd(trackID: trackID, duration: tkhdDuration)
        let edts = makeEdts(duration: UInt32(min(tkhdDuration, UInt64(UInt32.max))))
        let mdia = makeChapterMdia(
            mediaTimescale: mediaTimescale,
            mediaDuration: mediaDuration,
            chapters: chapters,
            sampleSizes: sampleSizes,
            chunkOffset: chunkOffset
        )
        return MP4Box.boxes("trak", tkhd, edts, mdia)
    }

    private static func makeTkhd(trackID: UInt32, duration: UInt64) -> Data {
        var payload = Data()
        payload.append(MP4Box.u32(0x0000000F)) // version 0, flags enabled|inMovie|inPreview|inPoster
        payload.append(MP4Box.u32(0)) // creation
        payload.append(MP4Box.u32(0)) // modification
        payload.append(MP4Box.u32(trackID))
        payload.append(MP4Box.u32(0)) // reserved
        payload.append(MP4Box.u32(UInt32(min(duration, UInt64(UInt32.max)))))
        payload.append(Data(count: 8)) // reserved
        payload.append(MP4Box.u16(0)) // layer
        payload.append(MP4Box.u16(0)) // alternate group
        payload.append(MP4Box.u16(0)) // volume
        payload.append(MP4Box.u16(0)) // reserved
        payload.append(identityMatrix())
        payload.append(MP4Box.u32(0)) // width
        payload.append(MP4Box.u32(0)) // height
        return MP4Box.box("tkhd", payload)
    }

    private static func identityMatrix() -> Data {
        func fp(_ v: Int32) -> Data { MP4Box.i32(v) }
        return fp(0x00010000) + fp(0) + fp(0)
            + fp(0) + fp(0x00010000) + fp(0)
            + fp(0) + fp(0) + fp(0x40000000)
    }

    private static func makeEdts(duration: UInt32) -> Data {
        var elst = Data()
        elst.append(MP4Box.u32(0)) // version/flags
        elst.append(MP4Box.u32(1)) // entry count
        elst.append(MP4Box.u32(duration))
        elst.append(MP4Box.i32(0)) // media time
        elst.append(MP4Box.u32(0x00010000)) // media rate
        return MP4Box.box("edts", MP4Box.box("elst", elst))
    }

    private static func makeChapterMdia(
        mediaTimescale: UInt32,
        mediaDuration: UInt32,
        chapters: [ChapterMark],
        sampleSizes: [UInt32],
        chunkOffset: UInt64
    ) -> Data {
        let mdhd = makeMdhd(timescale: mediaTimescale, duration: mediaDuration)
        let hdlr = makeTextHandler()
        let minf = makeChapterMinf(chapters: chapters, sampleSizes: sampleSizes, chunkOffset: chunkOffset)
        return MP4Box.boxes("mdia", mdhd, hdlr, minf)
    }

    private static func makeMdhd(timescale: UInt32, duration: UInt32) -> Data {
        var payload = Data()
        payload.append(MP4Box.u32(0))
        payload.append(MP4Box.u32(0))
        payload.append(MP4Box.u32(0))
        payload.append(MP4Box.u32(timescale))
        payload.append(MP4Box.u32(duration))
        payload.append(MP4Box.u16(0x55C4)) // und
        payload.append(MP4Box.u16(0))
        return MP4Box.box("mdhd", payload)
    }

    private static func makeTextHandler() -> Data {
        var payload = Data()
        payload.append(MP4Box.u32(0))
        payload.append(MP4Box.fourcc("mhlr"))
        payload.append(MP4Box.fourcc("text"))
        payload.append(MP4Box.u32(0))
        payload.append(MP4Box.u32(0))
        payload.append(MP4Box.u32(0))
        payload.append(MP4Box.cString("Chapter Handler"))
        return MP4Box.box("hdlr", payload)
    }

    private static func makeChapterMinf(chapters: [ChapterMark], sampleSizes: [UInt32], chunkOffset: UInt64) -> Data {
        let gmhd = makeGmhd()
        let dinf = makeDinf()
        let stbl = makeChapterStbl(chapters: chapters, sampleSizes: sampleSizes, chunkOffset: chunkOffset)
        return MP4Box.boxes("minf", gmhd, dinf, stbl)
    }

    private static func makeGmhd() -> Data {
        var gmin = Data()
        gmin.append(MP4Box.u32(0))
        gmin.append(MP4Box.u16(0x0040)) // graphics mode
        gmin.append(MP4Box.u16(0x8000))
        gmin.append(MP4Box.u16(0x8000))
        gmin.append(MP4Box.u16(0x8000))
        gmin.append(MP4Box.u16(0))
        gmin.append(MP4Box.u16(0))
        let text = MP4Box.box("text", Data(count: 36))
        return MP4Box.boxes("gmhd", MP4Box.box("gmin", gmin), text)
    }

    private static func makeDinf() -> Data {
        var url = Data()
        url.append(MP4Box.u32(0x00000001)) // self-contained
        var dref = Data()
        dref.append(MP4Box.u32(0))
        dref.append(MP4Box.u32(1))
        dref.append(MP4Box.box("url ", url))
        return MP4Box.box("dinf", MP4Box.box("dref", dref))
    }

    static func makeChapterStbl(chapters: [ChapterMark], sampleSizes: [UInt32], chunkOffset: UInt64) -> Data {
        let stsd = makeTextSampleDescription()
        var stts = Data()
        stts.append(MP4Box.u32(0))
        stts.append(MP4Box.u32(UInt32(clamping: chapters.count)))
        for chapter in chapters {
            let delta = max(clampedUInt32(chapter.duration * 1000), 1)
            stts.append(MP4Box.u32(1))
            stts.append(MP4Box.u32(delta))
        }
        var stsc = Data()
        stsc.append(MP4Box.u32(0))
        stsc.append(MP4Box.u32(1))
        stsc.append(MP4Box.u32(1))
        stsc.append(MP4Box.u32(UInt32(clamping: chapters.count)))
        stsc.append(MP4Box.u32(1))
        var stsz = Data()
        stsz.append(MP4Box.u32(0))
        stsz.append(MP4Box.u32(0))
        stsz.append(MP4Box.u32(UInt32(clamping: sampleSizes.count)))
        for size in sampleSizes {
            stsz.append(MP4Box.u32(size))
        }
        return MP4Box.boxes(
            "stbl",
            stsd,
            MP4Box.box("stts", stts),
            MP4Box.box("stsc", stsc),
            MP4Box.box("stsz", stsz),
            chunkOffsetTable(offset: chunkOffset)
        )
    }

    private static func makeTextSampleDescription() -> Data {
        var body = Data()
        body.append(Data(count: 6)) // reserved
        body.append(MP4Box.u16(1)) // data reference index
        body.append(MP4Box.u32(0x00000001)) // display flags
        body.append(MP4Box.i32(1)) // horiz just
        body.append(MP4Box.u16(0))
        body.append(MP4Box.u16(0))
        body.append(MP4Box.u16(0)) // bg color
        body.append(MP4Box.i16(0)) // default text box
        body.append(MP4Box.i16(0))
        body.append(MP4Box.i16(0))
        body.append(MP4Box.i16(0))
        body.append(Data(count: 8)) // reserved
        body.append(MP4Box.u16(0)) // font number
        body.append(MP4Box.u16(0)) // font face
        body.append(UInt8(0))
        body.append(UInt8(0))
        body.append(MP4Box.u16(0))
        body.append(MP4Box.u16(0))
        body.append(MP4Box.u16(0))
        body.append(UInt8(0)) // font name length
        let entryBox = MP4Box.box("text", body)
        var stsd = Data()
        stsd.append(MP4Box.u32(0))
        stsd.append(MP4Box.u32(1))
        stsd.append(entryBox)
        return MP4Box.box("stsd", stsd)
    }

    private static func splitAtoms(_ payload: Data) -> [Data] {
        parsePayloadAtoms(payload).compactMap { header in
            let piece = MP4AtomIO.slice(payload, header)
            return piece.isEmpty ? nil : piece
        }
    }

    private static func unwrap(_ atom: Data) -> Data {
        guard atom.count >= 8, let size32 = MP4AtomIO.readU32(atom, 0) else { return Data() }
        if size32 == 1, atom.count >= 16 {
            return atom.subdata(in: 16..<atom.count)
        }
        if size32 == 0 {
            return atom.subdata(in: 8..<atom.count)
        }
        guard let size = Int(exactly: size32), size >= 8 else { return Data() }
        return atom.subdata(in: 8..<min(size, atom.count))
    }

    private static func fourCC(of atom: Data) -> String {
        guard atom.count >= 8 else { return "????" }
        return MP4AtomIO.readFourCC(atom, 4) ?? "????"
    }

    private static func child(_ atom: Data, _ type: String) -> Data? {
        splitAtoms(unwrap(atom)).first { fourCC(of: $0) == type }
    }
}
