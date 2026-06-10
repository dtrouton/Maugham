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
}
