import XCTest
@testable import AudiobookBinderCore
import ImageIO

final class ParserAndLibraryTests: XCTestCase {
    func testOPFParseDescriptionCoverAndEntities() {
        let xml = """
        <?xml version="1.0"?>
        <package>
          <metadata>
            <dc:title>Meditations</dc:title>
            <dc:creator>René Descartes</dc:creator>
            <dc:description>A &amp; B notes</dc:description>
          </metadata>
          <guide>
            <reference type="cover" href="images/cover.jpg"/>
          </guide>
        </package>
        """
        let meta = OPFParser.parse(xml)
        XCTAssertEqual(meta.title, "Meditations")
        XCTAssertEqual(meta.author, "René Descartes")
        XCTAssertEqual(meta.description, "A & B notes")
        XCTAssertEqual(meta.coverHref, "images/cover.jpg")
        XCTAssertEqual(OPFParser.parse("<package/>").title, nil)
    }

    func testOPFLoadFromFile() throws {
        let dir = try TestSupport.tempDir("opf")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("metadata.opf")
        try """
        <package><metadata><dc:title>From File</dc:title><dc:creator>Author</dc:creator></metadata></package>
        """.write(to: url, atomically: true, encoding: .utf8)
        let loaded = OPFParser.load(from: url)
        XCTAssertEqual(loaded?.title, "From File")
        XCTAssertEqual(loaded?.author, "Author")
        XCTAssertNil(OPFParser.load(from: dir.appendingPathComponent("missing.opf")))
    }

    func testOPFLoadFromOversizedFileReturnsNil() throws {
        let dir = try TestSupport.tempDir("opf-oversize")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("huge.opf")
        let xml = Data("<package><metadata><dc:title>Huge</dc:title></metadata></package>".utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: xml)
        try handle.truncate(atOffset: UInt64(OPFParser.maxOPFFileBytes) + 1)
        try handle.close()

        let size = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        )
        XCTAssertGreaterThan(size, OPFParser.maxOPFFileBytes)
        XCTAssertNil(OPFParser.load(from: url))
    }

    func testOPFLoadFromEPUB() throws {
        let dir = try TestSupport.tempDir("epub")
        defer { try? FileManager.default.removeItem(at: dir) }
        let metaInf = dir.appendingPathComponent("META-INF", isDirectory: true)
        let ops = dir.appendingPathComponent("OPS", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ops, withIntermediateDirectories: true)
        try """
        <?xml version="1.0"?>
        <container>
          <rootfiles>
            <rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.write(to: metaInf.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        try """
        <package>
          <metadata>
            <dc:title>EPUB Title</dc:title>
            <dc:creator>EPUB Author</dc:creator>
          </metadata>
        </package>
        """.write(to: ops.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        try "application/epub+zip".write(to: dir.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        let epub = dir.appendingPathComponent("book.epub")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", epub.path, "mimetype", "META-INF", "OPS"]
        zip.currentDirectoryURL = dir
        zip.standardOutput = Pipe()
        zip.standardError = Pipe()
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        let meta = OPFParser.loadFromEPUB(epub)
        XCTAssertEqual(meta?.title, "EPUB Title")
        XCTAssertEqual(meta?.author, "EPUB Author")
    }

    func testOPFLoadFromEPUBWithHugeDescriptionDoesNotHang() throws {
        let dir = try TestSupport.tempDir("epub-huge")
        defer { try? FileManager.default.removeItem(at: dir) }
        let description = String(repeating: "x", count: 262_144)
        let epub = try makeEPUB(
            in: dir,
            opfXML: """
            <package>
              <metadata>
                <dc:title>Huge EPUB</dc:title>
                <dc:creator>Huge Author</dc:creator>
                <dc:description>\(description)</dc:description>
              </metadata>
            </package>
            """
        )
        let deadline = Date().addingTimeInterval(5)
        let meta = OPFParser.loadFromEPUB(epub)
        XCTAssertLessThan(Date(), deadline, "loadFromEPUB must return before the 5s deadline")
        XCTAssertNil(meta, "OPF over the unzip byte budget must fail closed")
    }

    func testOPFLoadFromEPUBRejectsUnsafeOPFPath() throws {
        let dir = try TestSupport.tempDir("epub-zipslip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let epub = try makeEPUB(
            in: dir,
            containerFullPath: "../OPS/content.opf",
            opfXML: """
            <package>
              <metadata>
                <dc:title>Should Not Load</dc:title>
                <dc:creator>Author</dc:creator>
              </metadata>
            </package>
            """
        )
        XCTAssertNil(OPFParser.loadFromEPUB(epub))
        XCTAssertFalse(OPFParser.isSafeArchiveMember("../OPS/content.opf"))
        XCTAssertFalse(OPFParser.isSafeArchiveMember("/etc/passwd"))
        XCTAssertFalse(OPFParser.isSafeArchiveMember("OPS/../../../etc/passwd"))
        XCTAssertFalse(OPFParser.isSafeArchiveMember(""))
        XCTAssertTrue(OPFParser.isSafeArchiveMember("META-INF/container.xml"))
        XCTAssertTrue(OPFParser.isSafeArchiveMember("OPS/content.opf"))
    }

    func testUnzipRunDrainsSmallStdout() {
        let output = OPFParser.run("/bin/echo", ["ok"])
        XCTAssertEqual(output, "ok\n")
    }

    func testUnzipRunLargeStdoutDoesNotHang() throws {
        let dir = try TestSupport.tempDir("unzip-run-huge")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.txt")
        try Data(repeating: UInt8(ascii: "a"), count: OPFParser.subprocessOutputBudget + 40_000)
            .write(to: file)
        let deadline = Date().addingTimeInterval(5)
        let output = OPFParser.run("/bin/cat", [file.path])
        XCTAssertLessThan(Date(), deadline, "run must return before the 5s deadline")
        XCTAssertNil(output)
    }

    func testUnzipRunHonorsDeadline() {
        let deadline = Date().addingTimeInterval(5)
        let output = OPFParser.run("/bin/sleep", ["20"])
        XCTAssertLessThan(Date(), deadline, "run must terminate the child at the deadline")
        XCTAssertNil(output)
    }

    func testLibraryOutlineHelpers() throws {
        let dir = try TestSupport.tempDir("bookmark")
        defer { try? FileManager.default.removeItem(at: dir) }
        let withSlash = LibraryOutline.folderURL(URL(fileURLWithPath: dir.path + "/", isDirectory: true))
        XCTAssertTrue(LibraryOutline.sameFolder(withSlash, dir))
        XCTAssertFalse(LibraryOutline.sameFolder(dir, dir.appendingPathComponent("child")))

        let root = URL(fileURLWithPath: "/tmp/lib", isDirectory: true)
        let nested = LibraryOutline.build(
            root: root,
            books: [TestSupport.dummyBook(folder: "/tmp/lib/43/BookA")]
        )
        XCTAssertTrue(nested.hasNestedFolders)
        XCTAssertEqual(nested.id.path, LibraryOutline.folderURL(root).path)
        XCTAssertFalse(
            LibraryOutline.build(
                root: root,
                books: [TestSupport.dummyBook(folder: "/tmp/lib/BookA")]
            ).hasNestedFolders
        )
    }

    func testCoverJPEGNormalizeAndMissing() throws {
        XCTAssertNil(CoverJPEG.normalize(Data()))
        XCTAssertNil(CoverJPEG.loadAndNormalize(from: URL(fileURLWithPath: "/tmp/no-such-cover-\(UUID().uuidString).jpg")))
        let small = CoverJPEG.normalize(TestSupport.png1x1)
        XCTAssertNotNil(small)
        XCTAssertGreaterThan(small?.count ?? 0, 0)
        XCTAssertTrue(isJPEG(small!))
        XCTAssertEqual(imageSourceType(small!), "public.jpeg")

        let dir = try TestSupport.tempDir("cover")
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("cover.png")
        try TestSupport.png1x1.write(to: png)
        let loaded = CoverJPEG.loadAndNormalize(from: png)
        XCTAssertNotNil(loaded)
        XCTAssertTrue(isJPEG(loaded!))

        let large = makeJPEG(width: 2000, height: 1000)
        XCTAssertNotNil(large)
        let scaled = CoverJPEG.normalize(large!, maxEdge: 200)
        XCTAssertNotNil(scaled)
        XCTAssertTrue(isJPEG(scaled!))
        let source = CGImageSourceCreateWithData(scaled! as CFData, nil)
        let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        XCTAssertNotNil(image)
        XCTAssertLessThanOrEqual(max(image?.width ?? 0, image?.height ?? 0), 200)
    }

    func testCoverJPEGRejectsInvalidEmptyAndOversized() throws {
        XCTAssertNil(CoverJPEG.normalize(Data()))
        XCTAssertNil(CoverJPEG.normalize(Data("not-an-image".utf8)))
        XCTAssertNil(CoverJPEG.normalize(Data([0xFF, 0xD8, 0x00])))
        XCTAssertNil(CoverJPEG.normalize(Data(count: CoverJPEG.maxSourceBytes + 1)))

        let dir = try TestSupport.tempDir("cover-oversize")
        defer { try? FileManager.default.removeItem(at: dir) }
        let huge = dir.appendingPathComponent("huge.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: huge.path, contents: nil))
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(CoverJPEG.maxSourceBytes) + 1)
        try handle.close()
        XCTAssertNil(CoverJPEG.loadAndNormalize(from: huge))
    }

    func testCoverDisplayNeverUsesRawURLWhenJPEGIsNil() throws {
        XCTAssertFalse(CoverDisplay.usesRawURLFallback)

        let dir = try TestSupport.tempDir("cover-display")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cover.png")
        try TestSupport.png1x1.write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        XCTAssertNil(CoverDisplay.imageData(jpeg: nil, url: url))
        XCTAssertEqual(CoverDisplay.source(jpeg: nil, url: url), .placeholder)

        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        XCTAssertEqual(CoverDisplay.imageData(jpeg: jpeg, url: url), jpeg)
        XCTAssertEqual(CoverDisplay.source(jpeg: jpeg, url: url), .jpeg)
    }

    private func makeEPUB(
        in dir: URL,
        containerFullPath: String = "OPS/content.opf",
        opfXML: String
    ) throws -> URL {
        let metaInf = dir.appendingPathComponent("META-INF", isDirectory: true)
        let ops = dir.appendingPathComponent("OPS", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ops, withIntermediateDirectories: true)
        try """
        <?xml version="1.0"?>
        <container>
          <rootfiles>
            <rootfile full-path="\(containerFullPath)" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.write(to: metaInf.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        try opfXML.write(to: ops.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        try "application/epub+zip".write(to: dir.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        let epub = dir.appendingPathComponent("book.epub")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", epub.path, "mimetype", "META-INF", "OPS"]
        zip.currentDirectoryURL = dir
        zip.standardOutput = Pipe()
        zip.standardError = Pipe()
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return epub
    }

    private func makeJPEG(width: Int, height: Int) -> Data? {
        let color = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: color,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let image = ctx.makeImage() else { return nil }
        let dest = NSMutableData()
        guard let d = CGImageDestinationCreateWithData(dest, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(d, image, nil)
        guard CGImageDestinationFinalize(d), dest.length > 0 else { return nil }
        return dest as Data
    }

    private func isJPEG(_ data: Data) -> Bool {
        data.count >= 2 && data[0] == 0xFF && data[1] == 0xD8
    }

    private func imageSourceType(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceGetType(source) as String?
    }
}

final class MP4AtomIOTests: XCTestCase {
    func testExtendedSizeUInt64MaxDoesNotTrapOrAcceptAtom() {
        var data = Data()
        data.append(MP4Box.u32(1))
        data.append(MP4Box.fourcc("mdat"))
        data.append(MP4Box.u64(.max))
        XCTAssertEqual(data.count, 16)

        var atoms: [MP4AtomHeader] = []
        XCTAssertNoThrow(atoms = MP4AtomIO.parseHeaders(data, range: 0..<data.count))
        XCTAssertTrue(atoms.isEmpty, "UInt64.max extended size must not be accepted")
        XCTAssertNoThrow {
            _ = MP4AtomIO.slice(data, MP4AtomHeader(offset: 0, headerSize: 16, size: .max, type: "mdat"))
        }
    }

    func testShortBufferMustNotAcceptOversizedMoov() {
        var data = Data()
        data.append(MP4Box.u32(4096))
        data.append(MP4Box.fourcc("moov"))
        XCTAssertEqual(data.count, 8)

        var atoms: [MP4AtomHeader] = []
        XCTAssertNoThrow(atoms = MP4AtomIO.parseHeaders(data, range: 0..<data.count))
        XCTAssertFalse(atoms.contains(where: { $0.end == 4096 }))
        XCTAssertTrue(atoms.isEmpty)
    }

    func testTruncatedHeaderAndInvalidSizesAreRejected() {
        XCTAssertTrue(MP4AtomIO.parseHeaders(Data([0, 0, 0, 8, 0x66, 0x72, 0x65]), range: 0..<7).isEmpty)
        XCTAssertTrue(MP4AtomIO.parseHeaders(Data(), range: 0..<0).isEmpty)

        var tooSmall = Data()
        tooSmall.append(MP4Box.u32(4))
        tooSmall.append(MP4Box.fourcc("free"))
        XCTAssertTrue(MP4AtomIO.parseHeaders(tooSmall, range: 0..<tooSmall.count).isEmpty)

        var sizeZero = Data()
        sizeZero.append(MP4Box.u32(0))
        sizeZero.append(MP4Box.fourcc("free"))
        let filled = MP4AtomIO.parseHeaders(sizeZero, range: 0..<sizeZero.count)
        XCTAssertEqual(filled.count, 1)
        XCTAssertEqual(filled[0].size, 8)
        XCTAssertEqual(filled[0].type, "free")

        var shortExtended = Data()
        shortExtended.append(MP4Box.u32(1))
        shortExtended.append(MP4Box.fourcc("mdat"))
        shortExtended.append(MP4Box.u64(10))
        XCTAssertTrue(MP4AtomIO.parseHeaders(shortExtended, range: 0..<shortExtended.count).isEmpty)

        var truncatedExtended = Data()
        truncatedExtended.append(MP4Box.u32(1))
        truncatedExtended.append(MP4Box.fourcc("mdat"))
        truncatedExtended.append(contentsOf: [0, 0, 0])
        XCTAssertTrue(
            MP4AtomIO.parseHeaders(truncatedExtended, range: 0..<truncatedExtended.count).isEmpty
        )
    }

    func testChildAtomLargerThanParentPayloadIsRejected() {
        var data = Data()
        data.append(MP4Box.u32(24))
        data.append(MP4Box.fourcc("moov"))
        data.append(MP4Box.u32(100))
        data.append(MP4Box.fourcc("free"))
        data.append(Data(count: 8))
        XCTAssertEqual(data.count, 24)

        let top = MP4AtomIO.parseHeaders(data, range: 0..<data.count)
        XCTAssertEqual(top.count, 1)
        XCTAssertEqual(top[0].type, "moov")
        XCTAssertEqual(top[0].size, 24)

        guard let payloadStart = Int(exactly: top[0].payloadOffset),
              let payloadEnd = Int(exactly: top[0].end)
        else {
            return XCTFail("valid parent offsets must convert")
        }
        let children = MP4AtomIO.parseHeaders(data, range: payloadStart..<payloadEnd)
        XCTAssertTrue(children.isEmpty, "oversized child must not be accepted")
    }

    func testValidTinyAtomStillParses() {
        let free = MP4Box.box("free", Data())
        XCTAssertEqual(free.count, 8)
        let atoms = MP4AtomIO.parseHeaders(free, range: 0..<free.count)
        XCTAssertEqual(atoms.count, 1)
        XCTAssertEqual(atoms[0].type, "free")
        XCTAssertEqual(atoms[0].headerSize, 8)
        XCTAssertEqual(atoms[0].size, 8)
        XCTAssertEqual(atoms[0].end, 8)
        XCTAssertEqual(MP4AtomIO.slice(free, atoms[0]), free)

        let nested = MP4Box.box("moov", MP4Box.box("free", Data()))
        let top = MP4AtomIO.parseHeaders(nested, range: 0..<nested.count)
        XCTAssertEqual(top.count, 1)
        XCTAssertEqual(top[0].type, "moov")
        XCTAssertEqual(top[0].size, UInt64(nested.count))
        guard let start = Int(exactly: top[0].payloadOffset),
              let end = Int(exactly: top[0].end)
        else {
            return XCTFail("valid nested offsets must convert")
        }
        let kids = MP4AtomIO.parseHeaders(nested, range: start..<end)
        XCTAssertEqual(kids.count, 1)
        XCTAssertEqual(kids[0].type, "free")
        XCTAssertEqual(kids[0].size, 8)
    }

    func testReadAtomLoadsSmallAtom() throws {
        let free = MP4Box.box("free", Data([1, 2, 3, 4]))
        let dir = try TestSupport.tempDir("atom-read-small")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tiny.mp4")
        try free.write(to: url)

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let headers = try MP4AtomIO.readHeaders(of: url)
        XCTAssertEqual(headers.count, 1)
        let loaded = try MP4AtomIO.readAtom(headers[0], from: handle)
        XCTAssertEqual(loaded, free)
        XCTAssertEqual(loaded.count, 12)
    }

    func testReadAtomRejectsThirtyTwoMebibyteMoovWithoutLoading() throws {
        let advertised: UInt64 = 32 * 1024 * 1024
        XCTAssertGreaterThan(advertised, UInt64(MP4AtomIO.maxMetadataAtomBytes))

        let dir = try TestSupport.tempDir("atom-32mib")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("moov.mp4")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let writer = try FileHandle(forWritingTo: url)
        try writer.write(contentsOf: MP4Box.u32(UInt32(advertised)) + MP4Box.fourcc("moov"))
        try writer.truncate(atOffset: advertised)
        try writer.close()

        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let header = MP4AtomHeader(offset: 0, headerSize: 8, size: advertised, type: "moov")
        XCTAssertThrowsError(try MP4AtomIO.readAtom(header, from: reader)) { error in
            guard case BinderError.exportFailed(let message) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("too large"),
                "expected a size-budget error, got \(message)"
            )
        }
    }

    func testReadHeadersFromFileMatchesDataParser() throws {
        let nested = MP4Box.box("ftyp", Data(count: 16)) + MP4Box.box("moov", MP4Box.box("free", Data()))
        let fromData = MP4AtomIO.parseHeaders(nested, range: 0..<nested.count)
        XCTAssertEqual(fromData.map(\.type), ["ftyp", "moov"])

        let dir = try TestSupport.tempDir("atom-io")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tiny.mp4")
        try nested.write(to: url)
        let fromFile = try MP4AtomIO.readHeaders(of: url)
        XCTAssertEqual(fromFile.map(\.type), fromData.map(\.type))
        XCTAssertEqual(fromFile.map(\.size), fromData.map(\.size))
        XCTAssertEqual(fromFile.map(\.offset), fromData.map(\.offset))
        XCTAssertEqual(fromFile.map(\.headerSize), fromData.map(\.headerSize))
    }

    func testReadersRejectOutOfBoundsWithoutTrapping() {
        let short = Data([1, 2, 3])
        XCTAssertNil(MP4AtomIO.readU32(short, 0))
        XCTAssertNil(MP4AtomIO.readU64(short, 0))
        XCTAssertNil(MP4AtomIO.readFourCC(short, 0))
        XCTAssertNil(MP4AtomIO.readU32(short, -1))
        XCTAssertNil(MP4AtomIO.readU32(Data([0, 1, 2, 3]), 1))

        var claimed = Data()
        claimed.append(MP4Box.u32(4096))
        claimed.append(MP4Box.fourcc("moov"))
        let bogus = MP4AtomHeader(offset: 0, headerSize: 8, size: 4096, type: "moov")
        XCTAssertTrue(MP4AtomIO.slice(claimed, bogus).isEmpty)
        XCTAssertTrue(
            MP4AtomIO.slice(claimed, MP4AtomHeader(offset: 0, headerSize: 16, size: .max, type: "mdat")).isEmpty
        )
    }

    func testParseHeadersCompleteRejectsBudgetOverflowWhileTolerantReturnsPrefix() throws {
        let count = MP4AtomIO.maxHeadersPerParse + 1
        var data = Data()
        data.reserveCapacity(count * 8)
        let atom = MP4Box.box("free", Data())
        for _ in 0..<count {
            data.append(atom)
        }
        XCTAssertEqual(data.count, count * 8)

        let prefix = MP4AtomIO.parseHeaders(data, range: 0..<data.count)
        XCTAssertEqual(prefix.count, MP4AtomIO.maxHeadersPerParse)
        XCTAssertEqual(prefix.last?.end, UInt64(MP4AtomIO.maxHeadersPerParse * 8))

        XCTAssertThrowsError(try MP4AtomIO.parseHeadersComplete(data, range: 0..<data.count))

        let dir = try TestSupport.tempDir("atom-budget")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("many.mp4")
        try data.write(to: url)
        let fromFile = try MP4AtomIO.readHeaders(of: url)
        XCTAssertEqual(fromFile.count, MP4AtomIO.maxHeadersPerParse)
        XCTAssertThrowsError(try MP4AtomIO.readHeadersComplete(of: url))
    }

    func testParseHeadersCompleteRejectsTruncatedMdatAfterMoov() {
        let data = Self.truncatedMdatAfterMoov()
        let prefix = MP4AtomIO.parseHeaders(data, range: 0..<data.count)
        XCTAssertEqual(prefix.map(\.type), ["moov"])
        XCTAssertThrowsError(try MP4AtomIO.parseHeadersComplete(data, range: 0..<data.count))
    }

    func testParseHeadersCompleteRejectsTrailingMalformedAtom() {
        var data = MP4Box.box("ftyp", Data(count: 8)) + MP4Box.box("free", Data())
        data.append(MP4Box.u32(4))
        data.append(MP4Box.fourcc("free"))
        let prefix = MP4AtomIO.parseHeaders(data, range: 0..<data.count)
        XCTAssertEqual(prefix.map(\.type), ["ftyp", "free"])
        XCTAssertThrowsError(try MP4AtomIO.parseHeadersComplete(data, range: 0..<data.count))
    }

    func testParseHeadersCompleteAcceptsValidTinyFile() throws {
        let nested = MP4Box.box("ftyp", Data(count: 16)) + MP4Box.box("moov", MP4Box.box("free", Data()))
        let atoms = try MP4AtomIO.parseHeadersComplete(nested, range: 0..<nested.count)
        XCTAssertEqual(atoms.map(\.type), ["ftyp", "moov"])
        XCTAssertEqual(atoms.last?.end, UInt64(nested.count))

        let dir = try TestSupport.tempDir("atom-complete")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tiny.mp4")
        try nested.write(to: url)
        let fromFile = try MP4AtomIO.readHeadersComplete(of: url)
        XCTAssertEqual(fromFile.map(\.type), ["ftyp", "moov"])
    }

    static func truncatedMdatAfterMoov() -> Data {
        let moov = MP4Box.box("moov", MP4Box.box("mvhd", Data(count: 100)))
        var mdat = Data()
        mdat.append(MP4Box.u32(1000))
        mdat.append(MP4Box.fourcc("mdat"))
        mdat.append(Data(count: 4))
        return moov + mdat
    }
}
