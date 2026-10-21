import XCTest
@testable import Maugham

final class ZipArchiveTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = TestTemp.root.appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func run(_ tool: String, _ args: [String], in cwd: URL? = nil) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = cwd
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self))
    }

    private func text(_ n: Int) -> Data {
        Data(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: n).utf8)
    }

    func test_roundTrip_storedAndDeflated() throws {
        let url = dir.appendingPathComponent("a.zip")
        let entries = [
            ZipArchive.Entry(path: "[Content_Types].xml", data: Data("<x/>".utf8), compress: false),
            ZipArchive.Entry(path: "word/document.xml", data: text(200), compress: true),
            ZipArchive.Entry(path: "word/é ü.xml", data: Data("héllo".utf8), compress: true),
        ]
        try ZipArchive.write(entries, to: url)
        let back = try ZipArchive.read(url)
        XCTAssertEqual(Set(back.keys), Set(entries.map(\.path)))
        for e in entries { XCTAssertEqual(back[e.path], e.data) }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        XCTAssertLessThan(size, 2000, "the repetitive entry must actually deflate")
    }

    func test_unzipAcceptsOurOutput() throws {
        let url = dir.appendingPathComponent("b.zip")
        let big = text(5000)
        try ZipArchive.write([
            ZipArchive.Entry(path: "[Content_Types].xml", data: Data("<x/>".utf8), compress: false),
            ZipArchive.Entry(path: "word/document.xml", data: big, compress: true),
            ZipArchive.Entry(path: "empty.txt", data: Data(), compress: true),
        ], to: url)
        let (code, out) = try run("/usr/bin/unzip", ["-t", url.path])
        XCTAssertEqual(code, 0, out)
        XCTAssertTrue(out.contains("No errors detected"), out)
        let (c2, listing) = try run("/usr/bin/unzip", ["-Z1", url.path])
        XCTAssertEqual(c2, 0)
        XCTAssertEqual(listing.split(separator: "\n").first.map(String.init), "[Content_Types].xml")
        // And the bytes unzip extracts equal what we put in.
        let ex = dir.appendingPathComponent("ex")
        _ = try run("/usr/bin/unzip", ["-q", url.path, "-d", ex.path])
        XCTAssertEqual(try Data(contentsOf: ex.appendingPathComponent("word/document.xml")), big)
    }

    func test_readerReadsAZipMadeByUsrBinZip() throws {
        let src = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let body = text(300)
        try body.write(to: src.appendingPathComponent("sub/a.txt"))
        try Data("tiny".utf8).write(to: src.appendingPathComponent("b.txt"))
        try Data().write(to: src.appendingPathComponent("empty.txt"))
        let url = dir.appendingPathComponent("c.zip")
        let (code, out) = try run("/usr/bin/zip", ["-Xqr9", url.path, "sub", "b.txt", "empty.txt"], in: src)
        XCTAssertEqual(code, 0, out)
        let back = try ZipArchive.read(url)
        XCTAssertEqual(back["sub/a.txt"], body)
        XCTAssertEqual(back["b.txt"], Data("tiny".utf8))
        XCTAssertEqual(back["empty.txt"], Data())
        XCTAssertNil(back["sub/"], "directory entries are not files")
    }

    func test_crcAgreesWithUsrBinZip() throws {
        // zip stores the CRC; our writer's stored CRC must make unzip -t pass,
        // and the reader must accept zip's. Cross-check via a known vector.
        XCTAssertEqual(ZipArchive.crc32(Data("123456789".utf8)), 0xCBF43926)
        XCTAssertEqual(ZipArchive.crc32(Data()), 0)
    }

    func test_crcMismatchIsRejected() throws {
        let url = dir.appendingPathComponent("d.zip")
        try ZipArchive.write([ZipArchive.Entry(path: "a.txt", data: Data("hello world".utf8), compress: false)], to: url)
        var bytes = try Data(contentsOf: url)
        let r = bytes.range(of: Data("hello world".utf8))!
        bytes[r.lowerBound] ^= 0x01
        try bytes.write(to: url)
        XCTAssertThrowsError(try ZipArchive.read(url)) {
            XCTAssertEqual($0 as? ZipArchive.ReadError, .crcMismatch("a.txt"))
        }
    }

    func test_pathEscapeIsRejected() throws {
        for bad in ["../evil.txt", "a/../../evil.txt", "/abs.txt", "a\\..\\b"] {
            let url = dir.appendingPathComponent("e.zip")
            try ZipArchive.write([ZipArchive.Entry(path: bad, data: Data("x".utf8), compress: false)], to: url)
            XCTAssertThrowsError(try ZipArchive.read(url), bad) {
                XCTAssertEqual($0 as? ZipArchive.ReadError, .unsafeName(bad))
            }
        }
    }

    func test_emptyEntryRoundTrips() throws {
        let url = dir.appendingPathComponent("f.zip")
        try ZipArchive.write([
            ZipArchive.Entry(path: "e1", data: Data(), compress: true),
            ZipArchive.Entry(path: "e2", data: Data(), compress: false),
        ], to: url)
        let back = try ZipArchive.read(url)
        XCTAssertEqual(back["e1"], Data())
        XCTAssertEqual(back["e2"], Data())
        XCTAssertEqual(try run("/usr/bin/unzip", ["-t", url.path]).0, 0)
    }

    func test_largeIncompressibleEntry() throws {
        var rng = SystemRandomNumberGenerator()
        let img = Data((0..<(5 * 1024 * 1024)).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let url = dir.appendingPathComponent("g.zip")
        try ZipArchive.write([ZipArchive.Entry(path: "word/media/image1.png", data: img, compress: true)], to: url)
        XCTAssertEqual(try ZipArchive.read(url)["word/media/image1.png"], img)
        XCTAssertEqual(try run("/usr/bin/unzip", ["-t", url.path]).0, 0)
    }

    func test_largeCompressibleEntry() throws {
        let big = text(150_000) // ~6.7 MB
        let url = dir.appendingPathComponent("h.zip")
        try ZipArchive.write([ZipArchive.Entry(path: "big.xml", data: big, compress: true)], to: url)
        XCTAssertEqual(try ZipArchive.read(url)["big.xml"], big)
    }

    func test_sameInputGivesSameBytes() throws {
        let a = dir.appendingPathComponent("1.zip"), b = dir.appendingPathComponent("2.zip")
        let es = [ZipArchive.Entry(path: "x", data: text(50), compress: true)]
        try ZipArchive.write(es, to: a)
        try ZipArchive.write(es, to: b)
        XCTAssertEqual(try Data(contentsOf: a), try Data(contentsOf: b))
    }

    func test_malformedInputsThrowAndDoNotCrash() throws {
        let url = dir.appendingPathComponent("m.zip")
        try ZipArchive.write([ZipArchive.Entry(path: "a", data: text(20), compress: true)], to: url)
        let good = try Data(contentsOf: url)
        var cases: [Data] = [Data(), Data("not a zip".utf8), good.prefix(10), good.prefix(good.count - 5)]
        for cut in stride(from: 4, to: good.count, by: 7) { cases.append(good.prefix(cut)) }
        // Corrupt the deflate stream.
        var bad = good
        bad[40] ^= 0xFF; bad[41] ^= 0xFF
        cases.append(bad)
        for (i, c) in cases.enumerated() {
            let u = dir.appendingPathComponent("bad\(i).zip")
            try c.write(to: u)
            XCTAssertThrowsError(try ZipArchive.read(u), "case \(i)")
        }
    }

    func test_encryptedFlagIsRefused() throws {
        let url = dir.appendingPathComponent("enc.zip")
        try ZipArchive.write([ZipArchive.Entry(path: "a", data: Data("x".utf8), compress: false)], to: url)
        var bytes = try Data(contentsOf: url)
        // Central directory header flags at +8 from its signature 0x02014b50.
        let r = bytes.range(of: Data([0x50, 0x4b, 0x01, 0x02]))!
        bytes[r.lowerBound + 8] |= 0x01
        try bytes.write(to: url)
        XCTAssertThrowsError(try ZipArchive.read(url)) {
            XCTAssertEqual($0 as? ZipArchive.ReadError, .unsupported("encrypted"))
        }
    }
}
