import XCTest
@testable import MaughamCore

/// `ContentHash.ofFile` names a figure image by its bytes (the first 16 hex
/// digits of its SHA-256). The values here are pinned: they are the names
/// pictures already carry in op logs and staged books, so the algorithm may
/// never drift (report plan 6b Task 1, P-6).
final class ContentHashTests: XCTestCase {
    private func write(_ data: Data, named name: String) throws -> URL {
        let url = TestTemp.root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func test_aSmallFileHashesToItsPinnedName() throws {
        let url = try write(Data("Maugham figure fixture\n".utf8), named: "small.bin")
        XCTAssertEqual(try ContentHash.ofFile(url), "23fbb79b71ed07dd")
    }

    /// Larger than one 1 MB read, so the chunked read is exercised.
    func test_aFileLargerThanOneChunkHashesToItsPinnedName() throws {
        let bytes = Data((0..<((1 << 20) + 4097)).map { UInt8($0 % 251) })
        let url = try write(bytes, named: "large.bin")
        XCTAssertEqual(try ContentHash.ofFile(url), "50d9f7d75b88270d")
    }

    func test_anEmptyFileHashesToTheEmptyDigestsPrefix() throws {
        let url = try write(Data(), named: "empty.bin")
        XCTAssertEqual(try ContentHash.ofFile(url), "e3b0c44298fc1c14")
    }

    /// Bytes in hand hash to the same pinned names (report plan 6b Task 6).
    func test_bytesInHandHashLikeTheirFile() {
        XCTAssertEqual(ContentHash.of(Data("Maugham figure fixture\n".utf8)), "23fbb79b71ed07dd")
        XCTAssertEqual(ContentHash.of(Data((0..<((1 << 20) + 4097)).map { UInt8($0 % 251) })), "50d9f7d75b88270d")
        XCTAssertEqual(ContentHash.of(Data()), "e3b0c44298fc1c14")
    }

    func test_aMissingFileThrows() {
        XCTAssertThrowsError(
            try ContentHash.ofFile(TestTemp.root.appendingPathComponent("absent.bin")))
    }
}
