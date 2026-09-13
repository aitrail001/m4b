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

    func testLibraryBookmarkAndOutlineHelpers() throws {
        XCTAssertNil(LibraryBookmark.resolvedDirectory(path: nil))
        let dir = try TestSupport.tempDir("bookmark")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(LibraryBookmark.resolvedDirectory(path: dir.path)?.path, dir.path)

        let withSlash = LibraryOutline.folderURL(URL(fileURLWithPath: dir.path + "/", isDirectory: true))
        XCTAssertTrue(LibraryOutline.sameFolder(withSlash, dir))
        XCTAssertFalse(LibraryOutline.sameFolder(dir, dir.appendingPathComponent("child")))

        let root = URL(fileURLWithPath: "/tmp/lib", isDirectory: true)
        let tree = LibraryOutline.build(
            root: root,
            books: [TestSupport.dummyBook(folder: "/tmp/lib/43/BookA")]
        )
        XCTAssertNotNil(tree.nestedFolders)
        XCTAssertEqual(tree.id.path, LibraryOutline.folderURL(root).path)
        XCTAssertNil(
            LibraryOutline.build(
                root: root,
                books: [TestSupport.dummyBook(folder: "/tmp/lib/BookA")]
            ).nestedFolders
        )
    }

    func testCoverJPEGNormalizeAndMissing() throws {
        XCTAssertNil(CoverJPEG.normalize(Data()))
        XCTAssertNil(CoverJPEG.loadAndNormalize(from: URL(fileURLWithPath: "/tmp/no-such-cover-\(UUID().uuidString).jpg")))
        let small = CoverJPEG.normalize(TestSupport.png1x1)
        XCTAssertNotNil(small)
        XCTAssertGreaterThan(small?.count ?? 0, 0)

        let dir = try TestSupport.tempDir("cover")
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("cover.png")
        try TestSupport.png1x1.write(to: png)
        let loaded = CoverJPEG.loadAndNormalize(from: png)
        XCTAssertNotNil(loaded)

        let large = makeJPEG(width: 2000, height: 1000)
        XCTAssertNotNil(large)
        let scaled = CoverJPEG.normalize(large!, maxEdge: 200)
        XCTAssertNotNil(scaled)
        let source = CGImageSourceCreateWithData(scaled! as CFData, nil)
        let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        XCTAssertNotNil(image)
        XCTAssertLessThanOrEqual(max(image?.width ?? 0, image?.height ?? 0), 200)
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
        CGImageDestinationFinalize(d)
        return dest as Data
    }
}
