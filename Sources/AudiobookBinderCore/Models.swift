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
    /// Why this chapter was auto-deselected, if it was. Nil when included.
    public var exclusionReason: String?
    /// Start time inside `url` when this chapter is a range of a single .m4b.
    public var startOffset: TimeInterval
    /// Bound chapter from an inspected .m4b — a time range inside a container, including start == 0.
    public var isEmbedded: Bool

    public init(
        id: UUID = UUID(),
        url: URL,
        index: Int,
        title: String,
        duration: TimeInterval,
        fileSize: Int64,
        audioInfo: AudioInfo = AudioInfo(),
        included: Bool = true,
        exclusionReason: String? = nil,
        startOffset: TimeInterval = 0,
        isEmbedded: Bool = false
    ) {
        self.id = id
        self.url = url
        self.index = index
        self.title = title
        self.duration = duration
        self.fileSize = fileSize
        self.audioInfo = audioInfo
        self.included = included
        self.exclusionReason = exclusionReason
        self.startOffset = startOffset
        self.isEmbedded = isEmbedded
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

    /// Unique destination per book. Same title/author from different folders, and
    /// names that collide after `suggestedFileName` sanitization, get distinct paths.
    /// Honors a validated owned dest (`existingM4BURL` or `.audiobookbinder-output`)
    /// and never assigns an on-disk path this book does not own.
    public func plannedOutputs(for books: [Audiobook]) -> [UUID: URL] {
        var reserved = Set<String>()
        var owned: [UUID: URL] = [:]
        owned.reserveCapacity(books.count)
        for book in books {
            guard let dest = ownedDestination(for: book) else { continue }
            let key = Self.destinationKey(dest)
            guard !reserved.contains(key) else { continue }
            reserved.insert(key)
            owned[book.id] = dest
        }

        var plan: [UUID: URL] = [:]
        plan.reserveCapacity(books.count)
        for book in books {
            if let dest = owned[book.id] {
                plan[book.id] = dest
            } else {
                plan[book.id] = uniqueOutputURL(for: book, reserved: &reserved)
            }
        }
        return plan
    }

    func owns(_ url: URL, for book: Audiobook) -> Bool {
        guard let dest = ownedDestination(for: book) else { return false }
        return Self.destinationKey(dest) == Self.destinationKey(url)
    }

    private func ownedDestination(for book: Audiobook) -> URL? {
        let dir = resolvedOutputDirectory(for: book).standardizedFileURL
        let candidates = [book.existingM4BURL, OutputAssociation.load(inBookFolder: book.folder)]
            .compactMap { $0 }
        for candidate in candidates {
            let dest = candidate.standardizedFileURL
            guard isInOutputDirectory(dest, directory: dir) else { continue }
            guard Self.destinationMatchesCurrentNaming(dest.lastPathComponent, book: book) else { continue }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDirectory), isDirectory.boolValue {
                continue
            }
            return dest
        }
        return nil
    }

    private func isInOutputDirectory(_ file: URL, directory: URL) -> Bool {
        Self.destinationKey(file.deletingLastPathComponent()) == Self.destinationKey(directory)
    }

    private static func destinationMatchesCurrentNaming(_ name: String, book: Audiobook) -> Bool {
        let stem = (book.suggestedFileName as NSString).deletingPathExtension.lowercased()
        let destStem = (name as NSString).deletingPathExtension.lowercased()
        if destStem == stem { return true }
        if destStem.hasPrefix(stem + " - ") { return true }
        if destStem.hasPrefix(stem + " ") { return true }
        return false
    }

    private func uniqueOutputURL(for book: Audiobook, reserved: inout Set<String>) -> URL {
        let dir = resolvedOutputDirectory(for: book).standardizedFileURL
        let primary = book.suggestedFileName
        if let url = claim(dir.appendingPathComponent(primary), reserved: &reserved) {
            return url
        }

        let stem = (primary as NSString).deletingPathExtension
        let folder = Self.sanitizedPathComponent(book.folder.lastPathComponent)
        if !folder.isEmpty {
            if let url = claim(dir.appendingPathComponent("\(stem) - \(folder).m4b"), reserved: &reserved) {
                return url
            }
            var n = 2
            while n < 10_000 {
                if let url = claim(dir.appendingPathComponent("\(stem) - \(folder) \(n).m4b"), reserved: &reserved) {
                    return url
                }
                n += 1
            }
        } else {
            var n = 2
            while n < 10_000 {
                if let url = claim(dir.appendingPathComponent("\(stem) \(n).m4b"), reserved: &reserved) {
                    return url
                }
                n += 1
            }
        }
        return dir.appendingPathComponent("\(stem) - \(UUID().uuidString).m4b")
    }

    private func claim(_ url: URL, reserved: inout Set<String>) -> URL? {
        let key = Self.destinationKey(url)
        guard !reserved.contains(key) else { return nil }
        if FileManager.default.fileExists(atPath: url.path) {
            reserved.insert(key)
            return nil
        }
        reserved.insert(key)
        return url
    }

    private static func destinationKey(_ url: URL) -> String {
        url.standardizedFileURL.path.lowercased()
    }

    private static func sanitizedPathComponent(_ name: String) -> String {
        name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ExportOutcome: Sendable, Equatable {
    case created
    case replaced
    case skippedExisting
    case failed(String)

    public var isPublished: Bool {
        switch self {
        case .created, .replaced: return true
        case .skippedExisting, .failed: return false
        }
    }
}

public struct BookExportResult: Sendable, Equatable {
    public var bookID: UUID
    public var url: URL
    public var outcome: ExportOutcome

    public init(bookID: UUID, url: URL, outcome: ExportOutcome) {
        self.bookID = bookID
        self.url = url
        self.outcome = outcome
    }
}

public struct JobProgress: Sendable, Equatable {
    public var label: String
    public var index: Int
    public var count: Int
    public var fraction: Double
    public var detail: String

    public init(label: String, index: Int, count: Int, fraction: Double, detail: String) {
        self.label = label
        self.index = index
        self.count = count
        self.fraction = fraction
        self.detail = detail
    }

    public static func looking(in folder: URL) -> JobProgress {
        let name = folder.lastPathComponent
        return JobProgress(label: name, index: 0, count: 0, fraction: 0, detail: "Looking in \(name)…")
    }

    public static func checking(_ folder: URL) -> JobProgress {
        let name = folder.lastPathComponent
        return JobProgress(label: name, index: 0, count: 0, fraction: 0, detail: "Checking \(name)…")
    }

    public static func reading(_ folder: URL, index: Int, count: Int) -> JobProgress {
        let name = folder.lastPathComponent
        return JobProgress(
            label: name,
            index: index,
            count: count,
            fraction: count > 0 ? Double(index - 1) / Double(count) : 0,
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
    case missingChapters([URL])

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
        case .missingChapters(let urls):
            let names = urls.map(\.lastPathComponent).joined(separator: ", ")
            if urls.count == 1 {
                return "Missing selected chapter: \(names)"
            }
            return "Missing selected chapters: \(names)"
        }
    }
}

public enum DurationFormat {
    // DateComponentsFormatter emits 0:01:05 for 65s; we want 1:05.
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

public enum BinderCopy {
    public static func createdAudiobooks(titles: [String]) -> String {
        let names = titles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        switch names.count {
        case 0:
            return "Created 0 audiobooks."
        case 1:
            return "Created 1 audiobook — \(names[0]). Verify the .m4b in the editor."
        default:
            return "Created \(names.count) audiobooks — \(names.joined(separator: ", ")). Verify the .m4b files in the editor."
        }
    }

    public static func exportSummary(_ items: [(title: String, outcome: ExportOutcome)]) -> String {
        var created: [String] = []
        var replaced: [String] = []
        var skipped: [String] = []
        var failed: [String] = []

        for item in items {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            switch item.outcome {
            case .created:
                created.append(title)
            case .replaced:
                replaced.append(title)
            case .skippedExisting:
                skipped.append(title)
            case .failed(let message):
                let reason = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty {
                    failed.append(reason)
                } else if reason.isEmpty {
                    failed.append(title)
                } else {
                    failed.append("\(title) (\(reason))")
                }
            }
        }

        if replaced.isEmpty && skipped.isEmpty && failed.isEmpty {
            return createdAudiobooks(titles: created)
        }

        var parts: [String] = []
        if !created.isEmpty {
            parts.append(countPhrase("Created", count: created.count, singular: "audiobook", plural: "audiobooks", names: created))
        }
        if !replaced.isEmpty {
            parts.append(countPhrase("Replaced", count: replaced.count, singular: "audiobook", plural: "audiobooks", names: replaced))
        }
        if !skipped.isEmpty {
            parts.append(countPhrase("Skipped", count: skipped.count, singular: "existing audiobook", plural: "existing audiobooks", names: skipped))
        }
        if !failed.isEmpty {
            parts.append(countPhrase("Failed", count: failed.count, singular: "audiobook", plural: "audiobooks", names: failed))
        }
        if parts.isEmpty {
            return createdAudiobooks(titles: [])
        }

        var summary = parts.joined(separator: " ")
        if !created.isEmpty || !replaced.isEmpty {
            let published = created.count + replaced.count
            summary += published == 1
                ? " Verify the .m4b in the editor."
                : " Verify the .m4b files in the editor."
        }
        return summary
    }

    private static func countPhrase(
        _ verb: String,
        count: Int,
        singular: String,
        plural: String,
        names: [String]
    ) -> String {
        let noun = count == 1 ? singular : plural
        let labeled = names.filter { !$0.isEmpty }
        if labeled.isEmpty {
            return "\(verb) \(count) \(noun)."
        }
        return "\(verb) \(count) \(noun) — \(labeled.joined(separator: ", "))."
    }

    public static func exportSummary(results: [BookExportResult], books: [Audiobook]) -> String {
        let titles = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0.title) })
        return exportSummary(results.map { (titles[$0.bookID] ?? "", $0.outcome) })
    }
}
