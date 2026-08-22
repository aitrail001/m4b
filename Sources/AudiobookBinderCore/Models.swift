import Foundation

public let audioExtensions: Set<String> = [
    "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "caf", "ogg"
]

public let imageExtensions: Set<String> = [
    "jpg", "jpeg", "png", "webp", "tif", "tiff"
]

public let ebookExtensions: Set<String> = [
    "epub", "mobi", "azw3", "azw", "pdf"
]

public let skippedDirectoryNames: Set<String> = [
    "ebook", "ebooks", "e-book", "e-books",
    "不分章节", "extras", "scans", "pdf"
]

public struct Chapter: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var url: URL
    public var index: Int
    public var title: String
    public var duration: TimeInterval
    public var fileSize: Int64

    public init(
        id: UUID = UUID(),
        url: URL,
        index: Int,
        title: String,
        duration: TimeInterval,
        fileSize: Int64
    ) {
        self.id = id
        self.url = url
        self.index = index
        self.title = title
        self.duration = duration
        self.fileSize = fileSize
    }
}

public struct Audiobook: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var folder: URL
    public var title: String
    public var author: String
    public var narrator: String
    public var bookDescription: String
    public var genre: String
    public var coverURL: URL?
    public var coverJPEG: Data?
    public var chapters: [Chapter]
    public var selected: Bool

    public init(
        id: UUID = UUID(),
        folder: URL,
        title: String,
        author: String,
        narrator: String = "",
        bookDescription: String = "",
        genre: String = "Audiobook",
        coverURL: URL? = nil,
        coverJPEG: Data? = nil,
        chapters: [Chapter] = [],
        selected: Bool = true
    ) {
        self.id = id
        self.folder = folder
        self.title = title
        self.author = author
        self.narrator = narrator
        self.bookDescription = bookDescription
        self.genre = genre
        self.coverURL = coverURL
        self.coverJPEG = coverJPEG
        self.chapters = chapters
        self.selected = selected
    }

    public var chapterCount: Int { chapters.count }

    public var totalDuration: TimeInterval {
        chapters.reduce(0) { $0 + $1.duration }
    }

    public var suggestedFileName: String {
        let base = "\(title) - \(author)"
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
        return base.trimmingCharacters(in: .whitespacesAndNewlines) + ".m4b"
    }
}

public struct ExportSettings: Sendable, Equatable {
    public var outputDirectory: URL?
    public var bitrate: Int
    public var overwrite: Bool
    public var writeNextToBook: Bool

    public init(
        outputDirectory: URL? = nil,
        bitrate: Int = 64_000,
        overwrite: Bool = false,
        writeNextToBook: Bool = true
    ) {
        self.outputDirectory = outputDirectory
        self.bitrate = bitrate
        self.overwrite = overwrite
        self.writeNextToBook = writeNextToBook
    }

    public func outputURL(for book: Audiobook) -> URL {
        let dir = writeNextToBook ? book.folder : (outputDirectory ?? book.folder)
        return dir.appendingPathComponent(book.suggestedFileName)
    }
}

public struct BuildProgress: Sendable, Equatable {
    public var bookTitle: String
    public var bookIndex: Int
    public var bookCount: Int
    public var fraction: Double
    public var detail: String

    public init(bookTitle: String, bookIndex: Int, bookCount: Int, fraction: Double, detail: String) {
        self.bookTitle = bookTitle
        self.bookIndex = bookIndex
        self.bookCount = bookCount
        self.fraction = fraction
        self.detail = detail
    }
}

public enum BinderError: Error, LocalizedError, Sendable {
    case noAudioFiles(URL)
    case noBooksFound(URL)
    case exportFailed(String)
    case cancelled
    case outputExists(URL)

    public var errorDescription: String? {
        switch self {
        case .noAudioFiles(let url):
            return "No audio files found in \(url.path)"
        case .noBooksFound(let url):
            return "No books found in \(url.path)"
        case .exportFailed(let message):
            return message
        case .cancelled:
            return "Cancelled"
        case .outputExists(let url):
            return "Already exists: \(url.lastPathComponent)"
        }
    }
}

public enum DurationFormat {
    public static func string(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval > 0 else { return "—" }
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
