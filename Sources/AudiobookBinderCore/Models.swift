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

public struct AudioInfo: Sendable, Equatable, Hashable {
    public var bitrate: Int
    public var sampleRate: Double
    public var channelCount: Int
    public var formatName: String

    public init(
        bitrate: Int = 0,
        sampleRate: Double = 0,
        channelCount: Int = 0,
        formatName: String = ""
    ) {
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.formatName = formatName
    }

    public var summary: String {
        var parts: [String] = []
        if bitrate > 0 {
            if bitrate < 1000 {
                parts.append("\(bitrate) bps")
            } else {
                parts.append("\((bitrate + 500) / 1000) kbps")
            }
        }
        if let rate = Self.sampleRateText(sampleRate) {
            parts.append(rate)
        }
        if channelCount == 1 {
            parts.append("mono")
        } else if channelCount == 2 {
            parts.append("stereo")
        } else if channelCount > 0 {
            parts.append("\(channelCount) ch")
        }
        if !formatName.isEmpty {
            parts.append(formatName)
        }
        return parts.joined(separator: " · ")
    }

    private static func sampleRateText(_ sampleRate: Double) -> String? {
        guard sampleRate > 0 else { return nil }
        let hz = Int(sampleRate.rounded())
        guard hz > 0 else { return nil }
        if hz % 1000 == 0 {
            return "\(hz / 1000) kHz"
        }
        let kHz = Double(hz) / 1000.0
        if hz % 100 == 0 {
            return String(format: "%.1f kHz", kHz)
        }
        return String(format: "%.2f kHz", kHz)
    }
}

public struct Chapter: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var url: URL
    public var index: Int
    public var title: String
    public var duration: TimeInterval
    public var fileSize: Int64
    public var audioInfo: AudioInfo
    public var included: Bool
    /// Start time inside `url` when this chapter is a range of a single .m4b.
    public var startOffset: TimeInterval

    public init(
        id: UUID = UUID(),
        url: URL,
        index: Int,
        title: String,
        duration: TimeInterval,
        fileSize: Int64,
        audioInfo: AudioInfo = AudioInfo(),
        included: Bool = true,
        startOffset: TimeInterval = 0
    ) {
        self.id = id
        self.url = url
        self.index = index
        self.title = title
        self.duration = duration
        self.fileSize = fileSize
        self.audioInfo = audioInfo
        self.included = included
        self.startOffset = startOffset
    }

    public var isEmbedded: Bool { startOffset > 0.01 }
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
    public var existingM4BURL: URL?
    public var boundDuration: TimeInterval

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
        selected: Bool = true,
        existingM4BURL: URL? = nil,
        boundDuration: TimeInterval = 0
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
        self.existingM4BURL = existingM4BURL
        self.boundDuration = boundDuration
    }

    public var chapterCount: Int { chapters.count }

    public var includedChapters: [Chapter] { chapters.filter(\.included) }

    public var isAlreadyBound: Bool { existingM4BURL != nil && chapters.isEmpty }

    public var hasBoundFile: Bool { existingM4BURL != nil }

    public var canCleanupSources: Bool { existingM4BURL != nil && !includedChapters.isEmpty }

    public var totalDuration: TimeInterval {
        if chapters.isEmpty { return boundDuration }
        return includedChapters.reduce(0) { $0 + $1.duration }
    }

    public var chapterCountLabel: String {
        let total = chapters.count
        let included = includedChapters.count
        if included == total {
            return total == 1 ? "1 chapter" : "\(total) chapters"
        }
        return "\(included) of \(total) chapters"
    }

    public var suggestedFileName: String {
        let base = "\(title) - \(author)"
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
        return base.trimmingCharacters(in: .whitespacesAndNewlines) + ".m4b"
    }

    public func matches(query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(q)
            || author.localizedCaseInsensitiveContains(q)
            || narrator.localizedCaseInsensitiveContains(q)
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

    public static var defaultOutputDirectory: URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Music", isDirectory: true)
        return music.appendingPathComponent("Audiobooks", isDirectory: true)
    }

    public func resolvedOutputDirectory(for book: Audiobook) -> URL {
        if writeNextToBook { return book.folder }
        return outputDirectory ?? Self.defaultOutputDirectory
    }

    public func outputURL(for book: Audiobook) -> URL {
        resolvedOutputDirectory(for: book).appendingPathComponent(book.suggestedFileName)
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

public struct ScanProgress: Sendable, Equatable {
    public var folderName: String
    public var bookIndex: Int
    public var bookCount: Int
    public var fraction: Double
    public var detail: String

    public init(folderName: String, bookIndex: Int, bookCount: Int, fraction: Double, detail: String) {
        self.folderName = folderName
        self.bookIndex = bookIndex
        self.bookCount = bookCount
        self.fraction = fraction
        self.detail = detail
    }

    public static func looking(in folder: URL) -> ScanProgress {
        let name = folder.lastPathComponent
        return ScanProgress(
            folderName: name,
            bookIndex: 0,
            bookCount: 0,
            fraction: 0,
            detail: "Looking in \(name)…"
        )
    }

    public static func checking(_ folder: URL) -> ScanProgress {
        let name = folder.lastPathComponent
        return ScanProgress(
            folderName: name,
            bookIndex: 0,
            bookCount: 0,
            fraction: 0,
            detail: "Checking \(name)…"
        )
    }

    public static func reading(_ folder: URL, index: Int, count: Int) -> ScanProgress {
        let name = folder.lastPathComponent
        let fraction = count > 0 ? Double(index - 1) / Double(count) : 0
        return ScanProgress(
            folderName: name,
            bookIndex: index,
            bookCount: count,
            fraction: fraction,
            detail: "Reading \(name) (\(index) of \(count))…"
        )
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
