import Darwin
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
    /// Captured unzip stdout/stderr is capped at 256 KiB. Larger container.xml / OPF is rejected.
    static let subprocessOutputBudget = 256 * 1024
    /// Loose `.opf` files use the same size cap as EPUB unzip stdout.
    static let maxOPFFileBytes = subprocessOutputBudget
    /// One unzip -p must finish within 3 seconds or the child is terminated.
    static let subprocessDeadline: TimeInterval = 3

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
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              size <= maxOPFFileBytes
        else { return nil }
        guard let xml = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(xml)
    }

    public static func loadFromEPUB(_ epub: URL) -> OPFMetadata? {
        let unzip = "/usr/bin/unzip"
        guard FileManager.default.isExecutableFile(atPath: unzip) else { return nil }
        let containerMember = "META-INF/container.xml"
        guard isSafeArchiveMember(containerMember) else { return nil }
        guard let container = run(unzip, ["-p", epub.path, containerMember]) else { return nil }
        let opfPath = attribute(container, tagHint: "rootfile", attribute: "full-path")
            ?? firstMatch(container, pattern: #"full-path="([^"]+)""#)
        guard let opfPath, isSafeArchiveMember(opfPath) else { return nil }
        guard let opf = run(unzip, ["-p", epub.path, opfPath]) else { return nil }
        return parse(opf)
    }

    /// Relative zip member only: no absolute path, drive letter, or `..` segment.
    static func isSafeArchiveMember(_ path: String) -> Bool {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.utf8.contains(0) else { return false }
        if path.hasPrefix("/") || path.hasPrefix("\\") { return false }
        if path.count >= 2 {
            let second = path[path.index(after: path.startIndex)]
            if path[path.startIndex].isLetter && second == ":" { return false }
        }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        for part in normalized.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part == ".." { return false }
        }
        return true
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

    /// Drain stdout and stderr while the child runs. Over-budget or overtime returns nil.
    static func run(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        // Close the parent write ends so readers see EOF when the child exits.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let state = PipeDrainState(budget: subprocessOutputBudget)
        let group = DispatchGroup()
        let stdoutFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let stderrFD = stderrPipe.fileHandleForReading.fileDescriptor

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            drain(fd: stdoutFD, into: state, stream: .stdout)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            drain(fd: stderrFD, into: state, stream: .stderr)
            group.leave()
        }

        let deadline = Date().addingTimeInterval(subprocessDeadline)
        while process.isRunning && Date() < deadline && !state.exceededBudget {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let timedOut = process.isRunning && !state.exceededBudget

        reap(process)
        if group.wait(timeout: .now() + 1) == .timedOut {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            _ = group.wait(timeout: .now() + 0.5)
        }

        guard !state.exceededBudget, !timedOut, process.terminationStatus == 0 else { return nil }
        return String(data: state.stdoutSnapshot(), encoding: .utf8)
    }

    private static func drain(fd: Int32, into state: PipeDrainState, stream: PipeStream) {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while !state.exceededBudget {
            let n = buffer.withUnsafeMutableBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return Darwin.read(fd, base, ptr.count)
            }
            if n <= 0 { break }
            state.append(Data(buffer[0..<n]), stream: stream)
        }
    }

    private static func reap(_ process: Process) {
        if process.isRunning {
            process.terminate()
        }
        let giveUp = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < giveUp {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

private enum PipeStream {
    case stdout
    case stderr
}

/// Shared counters for concurrent stdout/stderr reads.
private final class PipeDrainState: @unchecked Sendable {
    private let lock = NSLock()
    private let budget: Int
    private var stdout = Data()
    private var stderrCount = 0
    private var exceeded = false

    init(budget: Int) {
        self.budget = budget
    }

    var exceededBudget: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exceeded
    }

    func append(_ chunk: Data, stream: PipeStream) {
        lock.lock()
        defer { lock.unlock() }
        if exceeded { return }
        switch stream {
        case .stdout:
            if stdout.count + chunk.count > budget {
                exceeded = true
                return
            }
            stdout.append(chunk)
        case .stderr:
            if stderrCount + chunk.count > budget {
                exceeded = true
                return
            }
            stderrCount += chunk.count
        }
    }

    func stdoutSnapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return stdout
    }
}
