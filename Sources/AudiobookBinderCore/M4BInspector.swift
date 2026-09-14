import AVFoundation
import Foundation

public struct M4BInspection: Sendable, Equatable {
    public var url: URL
    public var duration: TimeInterval
    public var chapters: [ChapterMark]
    public var fileSize: Int64
    public var modificationDate: Date?
    public var fileResourceIdentifier: Data?
    public var bookID: UUID?

    public init(
        url: URL,
        duration: TimeInterval,
        chapters: [ChapterMark],
        fileSize: Int64,
        modificationDate: Date? = nil,
        fileResourceIdentifier: Data? = nil,
        bookID: UUID? = nil
    ) {
        self.url = url
        self.duration = duration
        self.chapters = chapters
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.fileResourceIdentifier = fileResourceIdentifier
        self.bookID = bookID
    }

    /// Snapshot dest identity at inspect time so cleanup can detect replace/delete.
    public static func capturingIdentity(
        url: URL,
        duration: TimeInterval,
        chapters: [ChapterMark],
        bookID: UUID? = nil
    ) -> M4BInspection {
        let identity = FileIdentity.read(from: url)
        return M4BInspection(
            url: url,
            duration: duration,
            chapters: chapters,
            fileSize: identity?.fileSize ?? 0,
            modificationDate: identity?.modificationDate,
            fileResourceIdentifier: identity?.fileResourceIdentifier,
            bookID: bookID
        )
    }
}

public enum M4BInspector {
    public static func durationsMatch(
        source: TimeInterval,
        bound: TimeInterval,
        tolerance: TimeInterval? = nil
    ) -> Bool {
        guard source > 0, bound > 0 else { return false }
        let slack = tolerance ?? max(1.5, max(source, bound) * 0.01)
        return abs(source - bound) <= slack
    }

    public static func sourceFilesToRemove(from book: Audiobook) -> [URL] {
        let m4bPath = book.existingM4BURL?.resolvingSymlinksInPath().path
        var seen = Set<String>()
        var urls: [URL] = []
        for chapter in book.chapters {
            let path = chapter.url.resolvingSymlinksInPath().path
            if path == m4bPath { continue }
            if chapter.url.pathExtension.lowercased() == "m4b" { continue }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if seen.insert(path).inserted {
                urls.append(chapter.url)
            }
        }
        return urls
    }

    public static func playableChapters(from inspection: M4BInspection) -> [Chapter] {
        let marks: [ChapterMark]
        if inspection.chapters.isEmpty, inspection.duration > 0 {
            marks = [ChapterMark(start: 0, duration: inspection.duration, title: "Audiobook")]
        } else {
            marks = inspection.chapters
        }
        return marks.enumerated().map { index, mark in
            Chapter(
                url: inspection.url,
                index: index + 1,
                title: mark.title.isEmpty ? "Chapter \(index + 1)" : mark.title,
                duration: mark.duration,
                fileSize: inspection.fileSize,
                startOffset: mark.start
            )
        }
    }

    public static func inspect(_ url: URL, bookID: UUID? = nil) async -> M4BInspection {
        let info = AudioMetadata.fileInfo(of: url)
        var chapters = await avChapters(url)
        if chapters.isEmpty {
            chapters = neroChapters(in: url, duration: info.duration)
        }
        if chapters.isEmpty, info.duration > 0 {
            chapters = [ChapterMark(start: 0, duration: info.duration, title: "Audiobook")]
        }
        return M4BInspection.capturingIdentity(
            url: url,
            duration: info.duration,
            chapters: chapters,
            bookID: bookID
        )
    }

    private static func avChapters(_ url: URL) async -> [ChapterMark] {
        let asset = AVURLAsset(url: url)
        do {
            let locales = try await asset.load(.availableChapterLocales)
            let languages = locales.map(\.identifier)
            guard !languages.isEmpty else { return [] }
            let groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: languages)
            return groups.enumerated().compactMap { index, group in
                let seconds = group.timeRange.start.seconds
                let duration = group.timeRange.duration.seconds
                guard seconds.isFinite, duration.isFinite else { return nil }
                let title = group.items.first(where: { $0.commonKey == .commonKeyTitle })?.stringValue
                    ?? "Chapter \(index + 1)"
                return ChapterMark(start: max(0, seconds), duration: max(0, duration), title: title)
            }
        } catch {
            return []
        }
    }

    static func neroChapters(in url: URL, duration: TimeInterval) -> [ChapterMark] {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return [] }
        guard let chpl = findAtom(data, type: "chpl") else { return [] }
        guard let payloadStart = Int(exactly: chpl.payloadOffset),
              let payloadSize = Int(exactly: chpl.payloadSize),
              payloadStart >= 0,
              payloadStart <= data.count,
              data.count - payloadStart >= payloadSize,
              payloadSize >= 5
        else { return [] }
        let parsed = MP4AudiobookTagger.parseChpl(
            data.subdata(in: payloadStart..<(payloadStart + payloadSize))
        )
        guard !parsed.isEmpty else { return [] }
        var marks: [ChapterMark] = []
        for i in parsed.indices {
            let start = parsed[i].start
            let end = i + 1 < parsed.count ? parsed[i + 1].start : max(duration, start)
            marks.append(ChapterMark(start: start, duration: max(0, end - start), title: parsed[i].title))
        }
        return marks
    }

    private static func findAtom(_ data: Data, type: String) -> MP4AtomHeader? {
        var stack = MP4AtomIO.parseHeaders(data, range: 0..<data.count)
        var i = 0
        while i < stack.count {
            let atom = stack[i]
            if atom.type == type { return atom }
            if MP4AtomIO.containers.contains(atom.type) {
                if let start = Int(exactly: atom.payloadOffset),
                   let size = Int(exactly: atom.payloadSize),
                   start >= 0,
                   start <= data.count,
                   data.count - start >= size,
                   size > 0
                {
                    stack.append(contentsOf: MP4AtomIO.parseHeaders(data, range: start..<(start + size)))
                }
            }
            i += 1
        }
        return nil
    }
}

public struct ChapterCompareRow: Equatable, Sendable {
    public var index: Int
    public var original: Chapter?
    public var bound: Chapter?

    public var durationsMatch: Bool? {
        guard let original, let bound else { return nil }
        return M4BInspector.durationsMatch(source: original.duration, bound: bound.duration)
    }
}

public struct ChapterCompareSummary: Equatable, Sendable {
    public var originalCount: Int
    public var boundCount: Int
    public var originalDuration: TimeInterval
    public var boundDuration: TimeInterval
    public var countsMatch: Bool
    public var totalsMatch: Bool
    public var mismatchedIndexes: [Int]

    public var allMatch: Bool {
        countsMatch && totalsMatch && mismatchedIndexes.isEmpty
    }

    public var detail: String {
        if originalCount == 0 {
            return "No original audio left to compare."
        }
        if boundCount == 0 {
            return "Could not read chapters from the .m4b."
        }
        if allMatch {
            let noun = originalCount == 1 ? "chapter" : "chapters"
            return "\(originalCount) \(noun) and duration match (\(DurationFormat.string(originalDuration)) vs \(DurationFormat.string(boundDuration)))."
        }
        var parts: [String] = []
        if !countsMatch {
            parts.append("Chapter count differs: \(originalCount) original vs \(boundCount) in the .m4b")
        }
        if mismatchedIndexes.count == 1 {
            parts.append("Duration differs on chapter \(mismatchedIndexes[0])")
        } else if mismatchedIndexes.count > 1 {
            parts.append("Duration differs on chapters \(mismatchedIndexes.map(String.init).joined(separator: ", "))")
        } else if !totalsMatch {
            parts.append(
                "Total duration differs: original \(DurationFormat.string(originalDuration)), .m4b \(DurationFormat.string(boundDuration))"
            )
        }
        return parts.joined(separator: ". ") + "."
    }
}

public enum ChapterCompare {
    public static func rows(original: [Chapter], bound: [Chapter]) -> [ChapterCompareRow] {
        let count = max(original.count, bound.count)
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            let orig = i < original.count ? original[i] : nil
            let boundChapter = i < bound.count ? bound[i] : nil
            return ChapterCompareRow(
                index: orig?.index ?? boundChapter?.index ?? (i + 1),
                original: orig,
                bound: boundChapter
            )
        }
    }

    public static func summary(
        original: [Chapter],
        bound: [Chapter],
        boundDuration: TimeInterval? = nil
    ) -> ChapterCompareSummary {
        let originalDuration = original.reduce(0) { $0 + $1.duration }
        let resolvedBound = boundDuration ?? bound.reduce(0) { $0 + $1.duration }
        return ChapterCompareSummary(
            originalCount: original.count,
            boundCount: bound.count,
            originalDuration: originalDuration,
            boundDuration: resolvedBound,
            countsMatch: original.count == bound.count,
            totalsMatch: M4BInspector.durationsMatch(source: originalDuration, bound: resolvedBound),
            mismatchedIndexes: rows(original: original, bound: bound).compactMap { row in
                row.durationsMatch == false ? row.index : nil
            }
        )
    }
}
