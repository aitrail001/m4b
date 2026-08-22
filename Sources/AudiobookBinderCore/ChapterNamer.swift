import Foundation

public enum ChapterNamer {
    public static func title(
        filename: String,
        index: Int,
        bookTitle: String,
        album: String?,
        id3Title: String?,
        paddedWidth: Int
    ) -> String {
        let stem = (filename as NSString).deletingPathExtension
        if let fromName = distinctiveFilenameTitle(stem, bookTitle: bookTitle, album: album) {
            return fromName
        }
        if let id3Title {
            let cleaned = TitleCleanup.collapseSpaces(id3Title)
            if !TitleCleanup.looksLikeGenericChapter(cleaned),
               !isBookTitle(cleaned, bookTitle: bookTitle, album: album) {
                return cleaned
            }
        }
        return String(format: "Chapter %0\(paddedWidth)d", index)
    }

    public static func distinctiveFilenameTitle(_ stem: String, bookTitle: String, album: String?) -> String? {
        var rest = stem
        rest = rest.replacingOccurrences(of: #"^\s*\d{1,4}\s*[-._)]\s*"#, with: "", options: .regularExpression)
        rest = rest.replacingOccurrences(of: #"^\s*\d{1,4}\s+"#, with: "", options: .regularExpression)
        rest = TitleCleanup.collapseSpaces(rest)
        if TitleCleanup.looksLikeGenericChapter(rest) { return nil }
        if isBookTitle(rest, bookTitle: bookTitle, album: album) { return nil }
        let stripped = stripSharedPrefix(rest, bookTitle: bookTitle)
        if let stripped, !TitleCleanup.looksLikeGenericChapter(stripped) {
            return stripped
        }
        return rest
    }

    public static func isBookTitle(_ value: String, bookTitle: String, album: String?) -> Bool {
        let n = normalize(TitleCleanup.stripEdition(value))
        if n.isEmpty { return true }
        let titles = [bookTitle, album ?? "", TitleCleanup.stripEdition(bookTitle), TitleCleanup.folderTitle(bookTitle)]
        return titles.contains { !$0.isEmpty && n == normalize(TitleCleanup.stripEdition($0)) }
    }

    private static func stripSharedPrefix(_ rest: String, bookTitle: String) -> String? {
        let candidates = [bookTitle, TitleCleanup.stripEdition(bookTitle), TitleCleanup.folderTitle(bookTitle)]
        for candidate in candidates {
            let prefix = normalize(candidate)
            let value = normalize(rest)
            if value.hasPrefix(prefix) {
                var leftover = String(rest.dropFirst(min(rest.count, candidate.count)))
                leftover = leftover.replacingOccurrences(of: #"^\s*[-–—:]\s*"#, with: "", options: .regularExpression)
                leftover = TitleCleanup.stripEdition(leftover)
                leftover = TitleCleanup.collapseSpaces(leftover)
                if leftover.count >= 3, !TitleCleanup.looksLikeGenericChapter(leftover) { return leftover }
            }
        }
        return nil
    }

    private static func normalize(_ s: String) -> String {
        TitleCleanup.collapseSpaces(s)
            .lowercased()
            .replacingOccurrences(of: #"[\p{P}\p{S}]"#, with: "", options: .regularExpression)
    }
}
