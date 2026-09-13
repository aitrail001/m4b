import Foundation

public enum TitleCleanup {
    public static func folderTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"\s*\((?i:unabridged|abridged)\)"#,
            #"\s*\(\d+\)\s*$"#
        ]
        for pattern in patterns {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "_", with: ":")
        return collapseSpaces(s)
    }

    public static func stripEdition(_ title: String) -> String {
        var s = title
        s = s.replacingOccurrences(
            of: #"\s*\((?i:unabridged|abridged)\)"#,
            with: "",
            options: .regularExpression
        )
        return collapseSpaces(s)
    }

    public static func fromEbookFilename(_ filename: String) -> (title: String?, author: String?) {
        let stem = (filename as NSString).deletingPathExtension
            .replacingOccurrences(of: "_", with: ":")
        let parts = stem.components(separatedBy: " - ").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard parts.count >= 2 else {
            return (parts.first.map(collapseSpaces), nil)
        }
        let author = parts.last
        let title = parts.dropLast().joined(separator: " - ")
        return (collapseSpaces(title), author)
    }

    public static func collapseSpaces(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func looksLikeGenericChapter(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.count <= 2 { return true }
        let lowered = t.lowercased()
        let generic: Set<String> = [
            "t", "audio", "track", "chapter", "untitled", "unknown",
            "new track", "title"
        ]
        return generic.contains(lowered)
    }

    public static func looksLikeCatalogTitle(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.range(of: #"_ep\d+_[A-Z0-9]{8,}"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        let hasSpaces = t.contains(" ")
        if !hasSpaces, t.range(of: "AudioCollection", options: .caseInsensitive) != nil {
            return true
        }
        if !hasSpaces, t.count >= 20, t.range(of: #"[a-z][A-Z]"#, options: .regularExpression) != nil {
            return true
        }
        if t.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    public static func preferredTitle(candidates: [String], folderTitle: String) -> String {
        let cleaned = candidates.map { stripEdition(collapseSpaces($0)) }
        return cleaned.first { $0.count >= 3 && !looksLikeCatalogTitle($0) } ?? folderTitle
    }
}
