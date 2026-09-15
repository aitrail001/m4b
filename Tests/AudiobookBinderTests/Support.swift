import Foundation
@testable import AudiobookBinderCore

enum TestSupport {
    static func tempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4b-xctest-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func writeMP3(in root: URL, book: String, file: String = "01.mp3", bytes: Int = 0) throws -> URL {
        let dir = root.appendingPathComponent(book, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(file)
        try Data(count: bytes).write(to: url)
        return url
    }

    static func dummyBook(
        folder: String,
        title: String? = nil,
        author: String = "A",
        narrator: String = "",
        chapters: [Chapter] = [],
        selected: Bool = true
    ) -> Audiobook {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        return Audiobook(
            folder: url,
            title: title ?? url.lastPathComponent,
            author: author,
            narrator: narrator,
            chapters: chapters,
            selected: selected
        )
    }

    static func dummyChapter(
        index: Int,
        url: URL = URL(fileURLWithPath: "/tmp/c.mp3"),
        duration: TimeInterval = 1,
        included: Bool = true
    ) -> Chapter {
        var chapter = Chapter(
            url: url,
            index: index,
            title: "Chapter \(index)",
            duration: duration,
            fileSize: 1
        )
        chapter.included = included
        return chapter
    }

    static let tink = URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff")

    static let png1x1 = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    static func writeSilenceWAV(to url: URL, seconds: Double = 1, sampleRate: Int = 44_100) throws {
        let samples = Int(seconds * Double(sampleRate))
        let dataSize = UInt32(samples * 2)
        var data = Data()
        func append(_ s: String) { data.append(contentsOf: s.utf8) }
        func appendU16(_ v: UInt16) {
            Swift.withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendU32(_ v: UInt32) {
            Swift.withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        append("RIFF")
        appendU32(36 + dataSize)
        append("WAVE")
        append("fmt ")
        appendU32(16)
        appendU16(1)
        appendU16(1)
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(sampleRate * 2))
        appendU16(2)
        appendU16(16)
        append("data")
        appendU32(dataSize)
        data.append(Data(count: Int(dataSize)))
        try data.write(to: url)
    }

    static func writePathOnlyOutputSidecar(_ dest: URL, in folder: URL) throws {
        try dest.standardizedFileURL.path.write(
            to: folder.appendingPathComponent(OutputAssociation.fileName),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Writes a self-consistent `.audiobookbinder-output` JSON from live
    /// identities without calling `OutputAssociation.record`.
    static func writeStructuredOutputSidecar(_ dest: URL, in folder: URL) throws {
        guard let destIdentity = FileIdentity.read(from: dest),
              let folderIdentity = FileIdentity.read(from: folder) else {
            throw BinderError.exportFailed("Could not read identities for structured sidecar")
        }
        struct Document: Codable {
            var destination: String
            var destinationIdentity: FileIdentity
            var bookFolderIdentity: FileIdentity
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(
            Document(
                destination: dest.standardizedFileURL.path,
                destinationIdentity: destIdentity,
                bookFolderIdentity: folderIdentity
            )
        )
        try data.write(
            to: folder.appendingPathComponent(OutputAssociation.fileName),
            options: .atomic
        )
    }
}
