import Compression
import Foundation

/// Reads the files out of a zip archive held in memory: stored and deflated entries, which
/// is everything Java's `ZipOutputStream` writes. Apple's SDKs have no zip reader of their own.
///
/// Sizes come from the central directory, never from local headers, which a streamed zip
/// leaves at zero. A file someone picked isn't trusted: entries and the total are capped, so
/// a zip claiming a huge size fails instead of exhausting memory.
struct ZipReader {
    enum ZipError: Error {
        case notAZip
        case unsupported
        case tooLarge
        case damaged
    }

    private let data: Data
    static let maxEntryBytes = 32 << 20
    static let maxTotalBytes = 256 << 20

    init(_ data: Data) {
        self.data = data
    }

    /// Every file in the archive, by its path inside it. Folders are left out.
    func files() throws -> [String: Data] {
        let (count, directoryOffset) = try endOfCentralDirectory()
        var files: [String: Data] = [:]
        var total = 0
        var offset = directoryOffset
        for _ in 0..<count {
            guard try uint32(at: offset) == 0x0201_4B50 else { throw ZipError.damaged }
            let flags = try uint16(at: offset + 8)
            let method = try uint16(at: offset + 10)
            let compressedSize = Int(try uint32(at: offset + 20))
            let size = Int(try uint32(at: offset + 24))
            let nameLength = Int(try uint16(at: offset + 28))
            let extraLength = Int(try uint16(at: offset + 30))
            let commentLength = Int(try uint16(at: offset + 32))
            let localOffset = Int(try uint32(at: offset + 42))
            let name = String(decoding: try bytes(at: offset + 46, count: nameLength), as: UTF8.self)
            offset += 46 + nameLength + extraLength + commentLength

            guard !name.hasSuffix("/") else { continue }
            // Encrypted, or ZIP64 sizes (only past 4 GB): neither is a backup Koda wrote.
            guard flags & 1 == 0, size != 0xFFFF_FFFF, compressedSize != 0xFFFF_FFFF else { throw ZipError.unsupported }
            guard size <= Self.maxEntryBytes, total + size <= Self.maxTotalBytes else { throw ZipError.tooLarge }
            total += size

            guard try uint32(at: localOffset) == 0x0403_4B50 else { throw ZipError.damaged }
            let start = localOffset + 30 + Int(try uint16(at: localOffset + 26)) + Int(try uint16(at: localOffset + 28))
            let packed = try bytes(at: start, count: compressedSize)
            switch method {
            case 0: files[name] = packed
            case 8: files[name] = try inflate(packed, size: size)
            default: throw ZipError.unsupported
            }
        }
        return files
    }

    /// The entry count and where the central directory starts, from the record at the end,
    /// which may be followed by a comment of up to 64 KB.
    private func endOfCentralDirectory() throws -> (Int, Int) {
        guard data.count >= 22 else { throw ZipError.notAZip }
        var offset = data.count - 22
        let lowest = max(0, data.count - 22 - 0xFFFF)
        while offset >= lowest {
            if try uint32(at: offset) == 0x0605_4B50 {
                return (Int(try uint16(at: offset + 10)), Int(try uint32(at: offset + 16)))
            }
            offset -= 1
        }
        throw ZipError.notAZip
    }

    /// A deflate stream (RFC 1951, no zlib header) back to its `size` bytes.
    private func inflate(_ packed: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { out in
            packed.withUnsafeBytes { input in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, size,
                                          input.bindMemory(to: UInt8.self).baseAddress!, packed.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ZipError.damaged }
        return output
    }

    private func bytes(at offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset + count <= data.count else { throw ZipError.damaged }
        let start = data.startIndex + offset
        return data.subdata(in: start..<start + count)
    }

    private func uint16(at offset: Int) throws -> UInt16 {
        let b = try bytes(at: offset, count: 2)
        return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8
    }

    private func uint32(at offset: Int) throws -> UInt32 {
        let b = try bytes(at: offset, count: 4)
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[b.startIndex + $1]) << (8 * UInt32($1)) }
    }
}
