import Darwin
import Foundation

enum BoundedFileRead {
    static let maxPathLength = 4_096

    /// Streams at most `maxBytes + 1` bytes from a regular file opened with
    /// `O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC`. Returns nil if missing,
    /// empty, unreadable, not a regular file, a final-component symlink, or
    /// larger than `maxBytes`. Never truncates to accept.
    static func read(from url: URL, maxBytes: Int) -> Data? {
        guard maxBytes > 0, maxBytes < Int.max else { return nil }
        return url.withUnsafeFileSystemRepresentation { cPath in
            guard let cPath else { return nil }
            let fd = open(cPath, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var info = stat()
            guard fstat(fd, &info) == 0 else { return nil }
            guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }

            let cap = maxBytes + 1
            var buffer = Data(count: cap)
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                var total = 0
                while total < cap {
                    let chunk = Darwin.read(fd, base.advanced(by: total), cap - total)
                    if chunk < 0 {
                        if errno == EINTR { continue }
                        return -1
                    }
                    if chunk == 0 { break }
                    total += chunk
                }
                return total
            }
            guard n > 0, n <= maxBytes else { return nil }
            buffer.count = n
            return buffer
        }
    }

    static func isAllowedPath(_ path: String, maxLength: Int = maxPathLength) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maxLength
    }
}
