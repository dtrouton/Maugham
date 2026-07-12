import XCTest
@testable import MaughamCore

final class OpLogSegmentTests: XCTestCase {

    private let jsonl = Data("""
    {"op_id":"01A","doc_id":"doc-1","next":"hello"}
    {"op_id":"01B","doc_id":"doc-1","next":"world"}

    """.utf8)

    // T8 — encode → decode → byte-identical JSONL; checksum verifies.
    func test_roundTrip() throws {
        for algo in [OpLogSegment.Algorithm.lzfse, .lzma] {
            let container = try OpLogSegment.encode(jsonl: jsonl, algorithm: algo)
            XCTAssertEqual(container.prefix(4), Data("MZS1".utf8))
            let result = OpLogSegment.decodeVerifying(container)
            XCTAssertTrue(result.isVerified, "\(algo)")
            XCTAssertEqual(result.jsonl, jsonl, "byte-identical round-trip (\(algo))")
        }
    }

    func test_emptyPayload_roundTrips() throws {
        let container = try OpLogSegment.encode(jsonl: Data())
        let result = OpLogSegment.decodeVerifying(container)
        XCTAssertTrue(result.isVerified)
        XCTAssertEqual(result.jsonl, Data())
    }

    func test_truncatedHeader_failsClosed() {
        let result = OpLogSegment.decodeVerifying(Data("MZS".utf8))
        XCTAssertEqual(result.failure, .truncatedHeader)
        XCTAssertNil(result.jsonl)
    }

    func test_badMagic_failsClosed() throws {
        var container = try OpLogSegment.encode(jsonl: jsonl)
        container.replaceSubrange(0..<4, with: Data("NOPE".utf8))
        XCTAssertEqual(OpLogSegment.decodeVerifying(container).failure, .badMagic)
    }

    func test_unknownAlgorithm_failsClosed() throws {
        var container = try OpLogSegment.encode(jsonl: jsonl)
        container[4] = 99
        XCTAssertEqual(OpLogSegment.decodeVerifying(container).failure,
                       .unknownAlgorithm(99))
    }

    // Tamper in the PAYLOAD → decompression or checksum failure; salvage may
    // or may not yield bytes, but isVerified must be false.
    func test_flippedPayloadByte_failsVerification() throws {
        var container = try OpLogSegment.encode(jsonl: jsonl)
        container[container.count - 1] ^= 0xFF
        XCTAssertFalse(OpLogSegment.decodeVerifying(container).isVerified)
    }

    // Tamper in the stored DIGEST → decompression succeeds, checksum fails,
    // and the salvaged bytes are still surfaced (best-effort, spec §5.3).
    func test_flippedDigestByte_failsChecksumButSalvages() throws {
        var container = try OpLogSegment.encode(jsonl: jsonl)
        container[16] ^= 0xFF   // first digest byte
        let result = OpLogSegment.decodeVerifying(container)
        XCTAssertEqual(result.failure, .checksumMismatch)
        XCTAssertEqual(result.jsonl, jsonl, "salvage must surface the decompressed bytes")
    }

    // A lying header claiming an unreasonably large uncompressed size must
    // fail CONTAINED before decompression is ever attempted — never inflate
    // first and check after (that would defeat the bound).
    func test_lyingExpectedByteCount_failsClosed_withoutInflating() throws {
        var container = try OpLogSegment.encode(jsonl: jsonl)
        var lyingCount = UInt64(1_000_000_000_000).littleEndian  // 1 TB
        withUnsafeBytes(of: &lyingCount) { bytes in
            container.replaceSubrange(8..<16, with: bytes)
        }
        let result = OpLogSegment.decodeVerifying(container)
        XCTAssertEqual(result.failure, .expectedByteCountTooLarge(1_000_000_000_000))
        XCTAssertNil(result.jsonl, "must not surface bytes from a rejected header")
        XCTAssertFalse(result.isVerified)
    }

    // A header exactly at the ceiling is still a header claim, not real
    // decompressed bytes — the real payload here is tiny, so this exercises
    // the boundary without needing to build a genuine 64 MB fixture.
    func test_expectedByteCountAtCeiling_stillGoesThroughLengthCheck() throws {
        var container = try OpLogSegment.encode(jsonl: jsonl)
        var ceiling = OpLogSegment.maxExpectedByteCount.littleEndian
        withUnsafeBytes(of: &ceiling) { bytes in
            container.replaceSubrange(8..<16, with: bytes)
        }
        let result = OpLogSegment.decodeVerifying(container)
        // Passes the pre-check (== ceiling, not > ceiling), decompresses the
        // real (tiny) payload, then fails the existing post-inflate
        // actual-vs-expected check — proving both guards are independently wired.
        XCTAssertEqual(
            result.failure,
            .lengthMismatch(expected: OpLogSegment.maxExpectedByteCount,
                             actual: UInt64(jsonl.count)))
    }
}
