import Foundation

enum MP4Box {
    static func u8(_ v: UInt8) -> Data { Data([v]) }

    static func u16(_ v: UInt16) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 2)
    }

    static func u32(_ v: UInt32) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 4)
    }

    static func u64(_ v: UInt64) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 8)
    }

    static func i16(_ v: Int16) -> Data { u16(UInt16(bitPattern: v)) }

    static func i32(_ v: Int32) -> Data { u32(UInt32(bitPattern: v)) }

    static func fourcc(_ type: String) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4)
        for scalar in type.unicodeScalars {
            if scalar == "©" {
                bytes.append(0xA9)
            } else {
                bytes.append(UInt8(truncatingIfNeeded: scalar.value))
            }
        }
        precondition(bytes.count == 4, "FourCC must be 4 bytes: \(type) -> \(bytes)")
        return Data(bytes)
    }

    static func box(_ type: String, _ payload: Data) -> Data {
        let size = UInt32(8 + payload.count)
        return u32(size) + fourcc(type) + payload
    }

    static func boxes(_ type: String, _ children: Data...) -> Data {
        box(type, children.reduce(into: Data(), { $0.append($1) }))
    }

    static func cString(_ s: String) -> Data {
        Data(s.utf8) + Data([0])
    }
}

struct MP4AtomHeader: Sendable {
    var offset: UInt64
    var headerSize: UInt64
    var size: UInt64
    var type: String

    var payloadOffset: UInt64 { offset + headerSize }
    var payloadSize: UInt64 { size - headerSize }
    var end: UInt64 { offset + size }
}

enum MP4AtomIO {
    static let containers: Set<String> = [
        "moov", "trak", "mdia", "minf", "stbl", "udta", "dinf",
        "edts", "mvex", "ilst", "moof", "traf", "skip", "meta"
    ]
    static let maxHeadersPerParse = 10_000
    static let ioChunkSize = 1_048_576
    /// Largest atom `readAtom` will allocate (moov / metadata). Larger headers throw.
    static let maxMetadataAtomBytes = 8 * 1024 * 1024
    /// Largest Nero `chpl` atom the inspector will load.
    static let maxChapterAtomBytes = 1 * 1024 * 1024
    /// Max nested container depth when walking a file for a specific atom.
    static let maxAtomTraversalDepth = 32

    static func readHeaders(of file: URL) throws -> [MP4AtomHeader] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        return parseHeaders(from: handle, start: 0, end: fileSize)
    }

    static func parseHeaders(from handle: FileHandle, fileSize: UInt64) -> [MP4AtomHeader] {
        parseHeaders(from: handle, start: 0, end: fileSize)
    }

    static func parseHeaders(from handle: FileHandle, start: UInt64, end: UInt64) -> [MP4AtomHeader] {
        var atoms: [MP4AtomHeader] = []
        var offset: UInt64 = start
        while atoms.count < maxHeadersPerParse {
            guard end > offset, end - offset >= 8 else { break }
            let headerBytes: Data
            do {
                try handle.seek(toOffset: offset)
                guard let bytes = try handle.read(upToCount: 16), bytes.count >= 8 else { break }
                headerBytes = bytes
            } catch {
                break
            }
            guard let size32 = readU32(headerBytes, 0),
                  let type = readFourCC(headerBytes, 4)
            else { break }

            let headerSize: UInt64
            let size: UInt64
            if size32 == 1 {
                guard headerBytes.count >= 16, let extended = readU64(headerBytes, 8) else { break }
                headerSize = 16
                size = extended
            } else if size32 == 0 {
                headerSize = 8
                size = end - offset
            } else {
                headerSize = 8
                size = UInt64(size32)
            }

            guard size >= headerSize else { break }
            let remaining = end - offset
            guard size <= remaining else { break }
            guard offset <= UInt64.max - size else { break }

            atoms.append(
                MP4AtomHeader(
                    offset: offset,
                    headerSize: headerSize,
                    size: size,
                    type: type
                )
            )
            offset += size
        }
        return atoms
    }

    static func readHeadersComplete(of file: URL) throws -> [MP4AtomHeader] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        return try parseHeadersComplete(from: handle, fileSize: fileSize)
    }

    static func parseHeadersComplete(from handle: FileHandle, fileSize: UInt64) throws -> [MP4AtomHeader] {
        var atoms: [MP4AtomHeader] = []
        var offset: UInt64 = 0
        while offset < fileSize {
            guard atoms.count < maxHeadersPerParse else {
                throw BinderError.exportFailed("MP4 atom count exceeds parse budget")
            }
            guard fileSize - offset >= 8 else {
                throw BinderError.exportFailed("Trailing incomplete MP4 atom header")
            }
            try handle.seek(toOffset: offset)
            guard let bytes = try handle.read(upToCount: 16), bytes.count >= 8 else {
                throw BinderError.exportFailed("Could not read MP4 atom header")
            }

            guard let size32 = readU32(bytes, 0),
                  let type = readFourCC(bytes, 4)
            else {
                throw BinderError.exportFailed("Malformed MP4 atom header")
            }

            let headerSize: UInt64
            let size: UInt64
            if size32 == 1 {
                guard bytes.count >= 16, let extended = readU64(bytes, 8) else {
                    throw BinderError.exportFailed("Malformed MP4 atom header")
                }
                headerSize = 16
                size = extended
            } else if size32 == 0 {
                headerSize = 8
                size = fileSize - offset
            } else {
                headerSize = 8
                size = UInt64(size32)
            }

            guard size >= headerSize else {
                throw BinderError.exportFailed("Malformed MP4 atom header")
            }
            let remaining = fileSize - offset
            guard size <= remaining else {
                throw BinderError.exportFailed("MP4 atom does not fit in parent")
            }
            guard offset <= UInt64.max - size else {
                throw BinderError.exportFailed("MP4 atom does not fit in parent")
            }

            atoms.append(
                MP4AtomHeader(
                    offset: offset,
                    headerSize: headerSize,
                    size: size,
                    type: type
                )
            )
            offset += size
        }
        return atoms
    }

    static func readAtom(
        _ header: MP4AtomHeader,
        from handle: FileHandle,
        maxBytes: Int = maxMetadataAtomBytes
    ) throws -> Data {
        guard header.size <= UInt64(clamping: maxBytes),
              let count = Int(exactly: header.size),
              count >= 8
        else {
            throw BinderError.exportFailed("Atom is too large to load")
        }
        try handle.seek(toOffset: header.offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw BinderError.exportFailed("Could not read MP4 atom")
        }
        return data
    }

    static func findAtom(
        type: String,
        in handle: FileHandle,
        fileSize: UInt64,
        maxDepth: Int = maxAtomTraversalDepth
    ) -> MP4AtomHeader? {
        var queue: [(header: MP4AtomHeader, depth: Int)] = parseHeaders(
            from: handle,
            start: 0,
            end: fileSize
        ).map { ($0, 0) }
        var i = 0
        var visited = 0
        while i < queue.count, visited < maxHeadersPerParse {
            let item = queue[i]
            i += 1
            visited += 1
            if item.header.type == type { return item.header }
            guard containers.contains(item.header.type),
                  item.depth < maxDepth,
                  item.header.payloadSize > 0
            else { continue }
            let children = parseHeaders(
                from: handle,
                start: item.header.payloadOffset,
                end: item.header.end
            )
            for child in children {
                queue.append((child, item.depth + 1))
            }
        }
        return nil
    }

    static func copyBytes(
        from input: FileHandle,
        offset: UInt64,
        count: UInt64,
        to output: FileHandle,
        cancellation: EncodeCancellation? = nil
    ) throws {
        try input.seek(toOffset: offset)
        var remaining = count
        while remaining > 0 {
            try cancellation?.checkCancelled()
            let chunk = Int(min(remaining, UInt64(ioChunkSize)))
            guard let data = try input.read(upToCount: chunk), !data.isEmpty else {
                throw BinderError.exportFailed("Unexpected end of file while copying MP4 data")
            }
            try output.write(contentsOf: data)
            remaining -= UInt64(data.count)
        }
    }

    static func writeFreeAtom(size: UInt64, to output: FileHandle) throws {
        guard size >= 8, let size32 = UInt32(exactly: size) else {
            throw BinderError.exportFailed("Cannot replace moov with a free atom")
        }
        try output.write(contentsOf: MP4Box.u32(size32) + MP4Box.fourcc("free"))
        var remaining = size - 8
        let zeros = Data(count: min(ioChunkSize, Int(clamping: remaining)))
        while remaining > 0 {
            let n = Int(min(remaining, UInt64(zeros.count)))
            try output.write(contentsOf: zeros.prefix(n))
            remaining -= UInt64(n)
        }
    }

    static func parseHeaders(_ data: Data, range: Range<Int>) -> [MP4AtomHeader] {
        guard range.lowerBound >= 0, range.upperBound <= data.count else { return [] }

        var atoms: [MP4AtomHeader] = []
        var i = range.lowerBound
        let end = range.upperBound
        while atoms.count < maxHeadersPerParse {
            guard i < end, end - i >= 8 else { break }
            guard let size32 = readU32(data, i),
                  let type = readFourCC(data, i + 4)
            else { break }

            let headerSize: Int
            let size: UInt64
            if size32 == 1 {
                guard end - i >= 16, let extended = readU64(data, i + 8) else { break }
                headerSize = 16
                size = extended
            } else if size32 == 0 {
                headerSize = 8
                size = UInt64(end - i)
            } else {
                headerSize = 8
                size = UInt64(size32)
            }

            guard size >= UInt64(headerSize) else { break }
            let remaining = UInt64(end - i)
            guard size <= remaining else { break }
            guard let sizeInt = Int(exactly: size), let offset = UInt64(exactly: i) else { break }

            atoms.append(
                MP4AtomHeader(
                    offset: offset,
                    headerSize: UInt64(headerSize),
                    size: size,
                    type: type
                )
            )
            let next = i + sizeInt
            if next <= i { break }
            i = next
        }
        return atoms
    }

    static func parseHeadersComplete(_ data: Data, range: Range<Int>) throws -> [MP4AtomHeader] {
        guard range.lowerBound >= 0, range.upperBound <= data.count else {
            throw BinderError.exportFailed("MP4 atom range is out of bounds")
        }

        var atoms: [MP4AtomHeader] = []
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            guard atoms.count < maxHeadersPerParse else {
                throw BinderError.exportFailed("MP4 atom count exceeds parse budget")
            }
            guard end - i >= 8 else {
                throw BinderError.exportFailed("Trailing incomplete MP4 atom header")
            }
            guard let size32 = readU32(data, i),
                  let type = readFourCC(data, i + 4)
            else {
                throw BinderError.exportFailed("Malformed MP4 atom header")
            }

            let headerSize: Int
            let size: UInt64
            if size32 == 1 {
                guard end - i >= 16, let extended = readU64(data, i + 8) else {
                    throw BinderError.exportFailed("Malformed MP4 atom header")
                }
                headerSize = 16
                size = extended
            } else if size32 == 0 {
                headerSize = 8
                size = UInt64(end - i)
            } else {
                headerSize = 8
                size = UInt64(size32)
            }

            guard size >= UInt64(headerSize) else {
                throw BinderError.exportFailed("Malformed MP4 atom header")
            }
            let remaining = UInt64(end - i)
            guard size <= remaining else {
                throw BinderError.exportFailed("MP4 atom does not fit in parent")
            }
            guard let sizeInt = Int(exactly: size), let offset = UInt64(exactly: i) else {
                throw BinderError.exportFailed("MP4 atom does not fit in parent")
            }

            atoms.append(
                MP4AtomHeader(
                    offset: offset,
                    headerSize: UInt64(headerSize),
                    size: size,
                    type: type
                )
            )
            let next = i + sizeInt
            if next <= i {
                throw BinderError.exportFailed("MP4 atom does not fit in parent")
            }
            i = next
        }
        return atoms
    }

    static func readU32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, data.count >= 4, offset <= data.count - 4 else { return nil }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    static func readU64(_ data: Data, _ offset: Int) -> UInt64? {
        guard offset >= 0, data.count >= 8, offset <= data.count - 8,
              let high = readU32(data, offset),
              let low = readU32(data, offset + 4)
        else { return nil }
        return (UInt64(high) << 32) | UInt64(low)
    }

    static func readFourCC(_ data: Data, _ offset: Int) -> String? {
        guard offset >= 0, data.count >= 4, offset <= data.count - 4 else { return nil }
        return String(bytes: data[offset..<(offset + 4)], encoding: .isoLatin1) ?? "????"
    }

    static func slice(_ data: Data, _ header: MP4AtomHeader) -> Data {
        guard let start = Int(exactly: header.offset),
              let size = Int(exactly: header.size),
              start >= 0,
              start <= data.count,
              data.count - start >= size
        else { return Data() }
        return data.subdata(in: start..<(start + size))
    }
}
