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

    static func readHeaders(of file: URL) throws -> [MP4AtomHeader] {
        let data = try Data(contentsOf: file, options: [.mappedIfSafe])
        return parseHeaders(data, range: 0..<data.count)
    }

    static func parseHeaders(_ data: Data, range: Range<Int>) -> [MP4AtomHeader] {
        var atoms: [MP4AtomHeader] = []
        var i = range.lowerBound
        let end = range.upperBound
        while i + 8 <= end {
            let size32 = readU32(data, i)
            let type = readFourCC(data, i + 4)
            var headerSize = 8
            var size = UInt64(size32)
            if size32 == 1 {
                guard i + 16 <= end else { break }
                size = readU64(data, i + 8)
                headerSize = 16
            } else if size32 == 0 {
                size = UInt64(end - i)
            }
            if size < UInt64(headerSize) { break }
            atoms.append(
                MP4AtomHeader(
                    offset: UInt64(i),
                    headerSize: UInt64(headerSize),
                    size: size,
                    type: type
                )
            )
            let next = i + Int(size)
            if next <= i { break }
            i = next
        }
        return atoms
    }

    static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        let b = data
        return (UInt32(b[offset]) << 24) | (UInt32(b[offset + 1]) << 16) | (UInt32(b[offset + 2]) << 8) | UInt32(b[offset + 3])
    }

    static func readU64(_ data: Data, _ offset: Int) -> UInt64 {
        (UInt64(readU32(data, offset)) << 32) | UInt64(readU32(data, offset + 4))
    }

    static func readFourCC(_ data: Data, _ offset: Int) -> String {
        let slice = data[offset..<offset + 4]
        return String(bytes: slice, encoding: .isoLatin1) ?? "????"
    }

    static func slice(_ data: Data, _ header: MP4AtomHeader) -> Data {
        let start = Int(header.offset)
        let end = Int(header.end)
        return data.subdata(in: start..<min(end, data.count))
    }
}
