import AVFoundation
import Foundation

public struct M4BInspection: Sendable, Equatable {
    public var url: URL
    public var duration: TimeInterval
    public var chapters: [ChapterMark]
    public var fileSize: Int64

    public init(url: URL, duration: TimeInterval, chapters: [ChapterMark], fileSize: Int64) {
        self.url = url
        self.duration = duration
        self.chapters = chapters
        self.fileSize = fileSize
    }
}

public enum DurationComparison: Sendable, Equatable {
    case match(source: TimeInterval, bound: TimeInterval)
    case mismatch(source: TimeInterval, bound: TimeInterval)
    case noBoundFile
    case noSource

    public var durationsMatch: Bool {
        if case .match = self { return true }
        return false
    }
}

public enum M4BInspector {
    public static func compareDurations(
        source: TimeInterval,
        bound: TimeInterval,
        tolerance: TimeInterval? = nil
    ) -> DurationComparison {
        guard source > 0 else { return .noSource }
        guard bound > 0 else { return .noBoundFile }
        let slack = tolerance ?? max(1.5, max(source, bound) * 0.01)
        if abs(source - bound) <= slack {
            return .match(source: source, bound: bound)
        }
        return .mismatch(source: source, bound: bound)
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

    public static func trash(_ urls: [URL]) throws {
        for url in urls {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
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

    public static func inspect(_ url: URL) async -> M4BInspection {
        let info = AudioMetadata.fileInfo(of: url)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        var chapters = await avChapters(url)
        if chapters.isEmpty {
            chapters = neroChapters(in: url, duration: info.duration)
        }
        if chapters.isEmpty, info.duration > 0 {
            chapters = [ChapterMark(start: 0, duration: info.duration, title: "Audiobook")]
        }
        return M4BInspection(url: url, duration: info.duration, chapters: chapters, fileSize: size)
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
        let payloadStart = Int(chpl.payloadOffset)
        let payloadEnd = Int(chpl.end)
        guard payloadStart + 8 <= payloadEnd, payloadEnd <= data.count else { return [] }
        var offset = payloadStart + 4
        let count = Int(MP4AtomIO.readU32(data, offset))
        offset += 4
        var starts: [(TimeInterval, String)] = []
        for _ in 0..<count {
            guard offset + 9 <= payloadEnd else { break }
            let start100ns = MP4AtomIO.readU64(data, offset)
            offset += 8
            let titleLen = Int(data[offset])
            offset += 1
            guard offset + titleLen <= payloadEnd else { break }
            let title = String(data: data[offset..<(offset + titleLen)], encoding: .utf8) ?? "Chapter"
            offset += titleLen
            starts.append((Double(start100ns) / 10_000_000.0, title))
        }
        guard !starts.isEmpty else { return [] }
        var marks: [ChapterMark] = []
        for i in starts.indices {
            let start = starts[i].0
            let end = i + 1 < starts.count ? starts[i + 1].0 : max(duration, start)
            marks.append(ChapterMark(start: start, duration: max(0, end - start), title: starts[i].1))
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
                let start = Int(atom.payloadOffset)
                let end = Int(atom.end)
                if start < end, end <= data.count {
                    stack.append(contentsOf: MP4AtomIO.parseHeaders(data, range: start..<end))
                }
            }
            i += 1
        }
        return nil
    }
}
