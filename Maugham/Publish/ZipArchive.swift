import Foundation
import Compression

/// A small zip writer and reader, in Swift over Apple's Compression framework, so
/// the DOCX packager and a writer's `reference.docx` need no process spawn.
///
/// `COMPRESSION_ZLIB` is raw RFC 1951 DEFLATE (no zlib header), which is exactly
/// what zip method 8 stores. The writer is deterministic (fixed 1980-01-01 DOS
/// timestamp), writes entries in the order given, UTF-8 names, no data
/// descriptors, no ZIP64. The reader sizes every entry from the central
/// directory, validates the CRC, and refuses ZIP64, encryption and unsafe names.
enum ZipArchive {

    struct Entry {
        let path: String
        let data: Data
        let compress: Bool
    }

    enum WriteError: Error, Equatable {
        /// A zip without ZIP64 holds at most 65 535 entries of under 4 GiB.
        case tooLarge
    }

    enum ReadError: Error, Equatable {
        case notAZip
        case truncated
        case unsupported(String)
        case unsafeName(String)
        case duplicateName(String)
        case crcMismatch(String)
        case badData(String)
    }

    /// Entries larger than this are refused on read (a zip bomb guard).
    static let maxEntryBytes = 512 * 1024 * 1024

    // MARK: CRC-32 (IEEE 802.3, reflected 0xEDB88320; the zip polynomial)

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFFFFFF
    }

    // MARK: Write

    private static let dosDate: UInt16 = (0 << 9) | (1 << 5) | 1   // 1980-01-01
    private static let dosTime: UInt16 = 0

    static func write(_ entries: [Entry], to url: URL) throws {
        try Data(encode(entries)).write(to: url, options: .atomic)
    }

    static func encode(_ entries: [Entry]) throws -> [UInt8] {
        guard entries.count <= 0xFFFF else { throw WriteError.tooLarge }
        var out = [UInt8]()
        var central = [UInt8]()
        for e in entries {
            guard e.data.count < 0xFFFF_FFFF, out.count < 0xFFFF_FFFF else { throw WriteError.tooLarge }
            let name = Array(e.path.utf8)
            guard name.count <= 0xFFFF else { throw WriteError.tooLarge }
            let crc = crc32(e.data)
            var method: UInt16 = 0
            var payload = e.data
            if e.compress, let d = deflate(e.data), d.count < e.data.count {
                method = 8
                payload = d
            }
            let offset = UInt32(out.count)
            // Local file header.
            put32(&out, 0x04034b50); put16(&out, 20); put16(&out, 0x0800)
            put16(&out, method); put16(&out, dosTime); put16(&out, dosDate)
            put32(&out, crc); put32(&out, UInt32(payload.count)); put32(&out, UInt32(e.data.count))
            put16(&out, UInt16(name.count)); put16(&out, 0)
            out += name
            out += payload
            // Central directory header.
            put32(&central, 0x02014b50); put16(&central, 20); put16(&central, 20)
            put16(&central, 0x0800); put16(&central, method)
            put16(&central, dosTime); put16(&central, dosDate)
            put32(&central, crc); put32(&central, UInt32(payload.count)); put32(&central, UInt32(e.data.count))
            put16(&central, UInt16(name.count)); put16(&central, 0); put16(&central, 0)
            put16(&central, 0); put16(&central, 0); put32(&central, 0)
            put32(&central, offset)
            central += name
        }
        guard out.count + central.count < 0xFFFF_FFFF else { throw WriteError.tooLarge }
        let cdOffset = UInt32(out.count)
        out += central
        put32(&out, 0x06054b50); put16(&out, 0); put16(&out, 0)
        put16(&out, UInt16(entries.count)); put16(&out, UInt16(entries.count))
        put32(&out, UInt32(central.count)); put32(&out, cdOffset); put16(&out, 0)
        return out
    }

    private static func put16(_ a: inout [UInt8], _ v: UInt16) {
        a.append(UInt8(v & 0xFF)); a.append(UInt8(v >> 8))
    }

    private static func put32(_ a: inout [UInt8], _ v: UInt32) {
        for s in stride(from: 0, to: 32, by: 8) { a.append(UInt8((v >> UInt32(s)) & 0xFF)) }
    }

    /// Raw DEFLATE, or nil when the encoder cannot fit the result in the input's size
    /// (incompressible data is then stored).
    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var dst = [UInt8](repeating: 0, count: data.count)
        let n = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&dst, dst.count, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard n > 0 else { return nil }
        return Data(dst[0..<n])
    }

    // MARK: Read

    /// Every file entry by path. Directory entries (a trailing `/`) are skipped.
    static func read(_ url: URL) throws -> [String: Data] {
        let file = try Data(contentsOf: url) // adr-0018-ok: a zip archive's bytes, not a manuscript
        return try decode(Data([UInt8](file)))
    }

    static func decode(_ z: Data) throws -> [String: Data] {
        let bytes = [UInt8](z)
        func u16(_ o: Int) throws -> Int {
            guard o >= 0, o + 2 <= bytes.count else { throw ReadError.truncated }
            return Int(bytes[o]) | Int(bytes[o + 1]) << 8
        }
        func u32(_ o: Int) throws -> Int {
            guard o >= 0, o + 4 <= bytes.count else { throw ReadError.truncated }
            return Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24
        }
        guard bytes.count >= 22 else { throw ReadError.notAZip }
        // The end-of-central-directory record: scan back past a possible comment.
        var eocd = -1
        var i = bytes.count - 22
        let floor = max(0, bytes.count - 22 - 0xFFFF)
        while i >= floor {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i; break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ReadError.notAZip }
        let count = try u16(eocd + 10)
        let cdSize = try u32(eocd + 12)
        let cdOffset = try u32(eocd + 16)
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            throw ReadError.unsupported("zip64")
        }
        guard cdOffset + cdSize <= eocd else { throw ReadError.truncated }

        var result = [String: Data]()
        var p = cdOffset
        for _ in 0..<count {
            guard try u32(p) == 0x02014b50 else { throw ReadError.badData("central directory") }
            let flags = try u16(p + 8)
            let method = try u16(p + 10)
            let crc = UInt32(try u32(p + 16))
            let csize = try u32(p + 20)
            let usize = try u32(p + 24)
            let nlen = try u16(p + 28), xlen = try u16(p + 30), clen = try u16(p + 32)
            let lho = try u32(p + 42)
            guard p + 46 + nlen <= bytes.count else { throw ReadError.truncated }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
            p += 46 + nlen + xlen + clen

            if flags & 0x1 != 0 || flags & 0x40 != 0 { throw ReadError.unsupported("encrypted") }
            if csize == 0xFFFF_FFFF || usize == 0xFFFF_FFFF || lho == 0xFFFF_FFFF {
                throw ReadError.unsupported("zip64")
            }
            if isUnsafe(name) { throw ReadError.unsafeName(name) }
            if name.hasSuffix("/") { continue }
            guard usize <= maxEntryBytes else { throw ReadError.unsupported("entry too large") }
            guard result[name] == nil else { throw ReadError.duplicateName(name) }

            guard try u32(lho) == 0x04034b50 else { throw ReadError.badData(name) }
            let start = lho + 30 + (try u16(lho + 26)) + (try u16(lho + 28))
            guard start + csize <= cdOffset else { throw ReadError.truncated }
            let raw = bytes[start..<(start + csize)]

            let data: Data
            switch method {
            case 0:
                guard csize == usize else { throw ReadError.badData(name) }
                data = Data(raw)
            case 8:
                data = try inflate(Array(raw), expecting: usize, name: name)
            default:
                throw ReadError.unsupported("method \(method)")
            }
            guard crc32(data) == crc else { throw ReadError.crcMismatch(name) }
            result[name] = data
        }
        return result
    }

    private static func inflate(_ raw: [UInt8], expecting size: Int, name: String) throws -> Data {
        if size == 0 { return Data() }
        guard !raw.isEmpty else { throw ReadError.badData(name) }
        var dst = [UInt8](repeating: 0, count: size)
        let n = compression_decode_buffer(&dst, size, raw, raw.count, nil, COMPRESSION_ZLIB)
        guard n == size else { throw ReadError.badData(name) }
        return Data(dst)
    }

    /// Absolute names and any `..` component (either slash direction) escape the archive.
    private static func isUnsafe(_ name: String) -> Bool {
        if name.isEmpty || name.hasPrefix("/") || name.hasPrefix("\\") || name.contains("\0") { return true }
        if name.count >= 2, name.dropFirst().first == ":" { return true }
        return name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..")
    }
}
