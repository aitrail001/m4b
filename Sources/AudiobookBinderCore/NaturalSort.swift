import Foundation

public enum NaturalSort {
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [.numeric, .caseInsensitive, .diacriticInsensitive])
    }

    public static func sorted<T>(_ items: [T], key: (T) -> String) -> [T] {
        items.sorted { compare(key($0), key($1)) == .orderedAscending }
    }

    /// Leading track index from names like "001 - Title", "01-Title", "Book - 003".
    public static func leadingIndex(_ name: String) -> Int? {
        let stem = (name as NSString).deletingPathExtension
        let pattern = #"^\s*(\d{1,4})\b"#
        if let match = stem.range(of: pattern, options: .regularExpression) {
            return Int(stem[match].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    public static func trailingIndex(_ name: String) -> Int? {
        let stem = (name as NSString).deletingPathExtension
        let pattern = #"\b(\d{1,4})\s*$"#
        if let match = stem.range(of: pattern, options: .regularExpression) {
            return Int(stem[match].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
