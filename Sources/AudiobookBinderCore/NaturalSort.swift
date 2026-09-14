import Foundation

enum NaturalSort {
    static let options: String.CompareOptions = [.numeric, .caseInsensitive, .diacriticInsensitive]

    static func leadingIndex(_ name: String) -> Int? {
        let stem = (name as NSString).deletingPathExtension
        guard let match = stem.range(of: #"^\s*(\d{1,4})\b"#, options: .regularExpression) else {
            return nil
        }
        return Int(stem[match].trimmingCharacters(in: .whitespaces))
    }

    static func trailingIndex(_ name: String) -> Int? {
        let stem = (name as NSString).deletingPathExtension
        guard let match = stem.range(of: #"\b(\d{1,4})\s*$"#, options: .regularExpression) else {
            return nil
        }
        return Int(stem[match].trimmingCharacters(in: .whitespaces))
    }
}
