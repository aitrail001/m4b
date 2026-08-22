import Foundation

public struct OPFMetadata: Sendable, Equatable {
    public var title: String?
    public var author: String?
    public var description: String?
    public var coverHref: String?

    public init(title: String? = nil, author: String? = nil, description: String? = nil, coverHref: String? = nil) {
        self.title = title
        self.author = author
        self.description = description
        self.coverHref = coverHref
    }
}

public enum OPFParser {
    public static func parse(_ xml: String) -> OPFMetadata {
        var meta = OPFMetadata()
        meta.title = firstTag(xml, names: ["dc:title", "title"])
        meta.author = firstTag(xml, names: ["dc:creator", "creator"])
        meta.description = firstTag(xml, names: ["dc:description", "description"])
        if let href = attribute(xml, tagHint: #"type="cover""#, attribute: "href") {
            meta.coverHref = href
        } else if let href = attribute(xml, tagHint: "reference", attribute: "href"), xml.contains("cover") {
            meta.coverHref = href
        }
        return meta
    }

    public static func load(from url: URL) -> OPFMetadata? {
        guard let xml = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(xml)
    }

    public static func loadFromEPUB(_ epub: URL) -> OPFMetadata? {
        let unzip = "/usr/bin/unzip"
        guard FileManager.default.isExecutableFile(atPath: unzip) else { return nil }
        guard let container = run(unzip, ["-p", epub.path, "META-INF/container.xml"]) else { return nil }
        let opfPath = attribute(container, tagHint: "rootfile", attribute: "full-path")
            ?? firstMatch(container, pattern: #"full-path="([^"]+)""#)
        guard let opfPath, let opf = run(unzip, ["-p", epub.path, opfPath]) else { return nil }
        return parse(opf)
    }

    private static func firstTag(_ xml: String, names: [String]) -> String? {
        for name in names {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            let pattern = "<\(escaped)(?:\\s[^>]*)?>([\\s\\S]*?)</\(escaped)>"
            if let raw = firstMatch(xml, pattern: pattern) {
                let text = stripTags(unescape(raw)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    private static func attribute(_ xml: String, tagHint: String, attribute: String) -> String? {
        firstMatch(xml, pattern: "\(tagHint)[\\s\\S]{0,200}?\(attribute)=\"([^\"]+)\"")
            ?? firstMatch(xml, pattern: "\(attribute)=\"([^\"]+)\"[^>]{0,80}\(tagHint)")
    }

    private static func firstMatch(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[r])
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    private static func run(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
