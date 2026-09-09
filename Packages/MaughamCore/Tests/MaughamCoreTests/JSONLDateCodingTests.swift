import XCTest
@testable import MaughamCore

/// The store's date STRATEGY, pinned at the level the chain depends on it.
///
/// Every remembered chain head is a SHA-256 over encoded bytes, and
/// `mergeSortedDedup` re-encodes ops with `dateEncoding` as a sort tiebreaker,
/// so a date that decodes to a value the encoder spells differently silently
/// moves a hash. The fast path in front of the formatter is therefore allowed
/// to be quicker but never to be a hair off: encode, decode, re-encode, and the
/// bytes are the SAME bytes.
final class JSONLDateCodingTests: XCTestCase {

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        return e
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
        return d
    }

    /// Encode → decode → re-encode, asserting byte equality of the two encodings.
    private func assertStableReEncoding(
        of json: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let first = Data(json.utf8)
        let dates = try decoder().decode([Date].self, from: first)
        let encoded = try encoder().encode(dates)
        let again = try encoder().encode(decoder().decode([Date].self, from: encoded))
        XCTAssertEqual(
            encoded, again,
            "re-encoding moved: \(String(decoding: encoded, as: UTF8.self)) "
                + "vs \(String(decoding: again, as: UTF8.self))",
            file: file, line: line)
    }

    func test_aFractionalDateReEncodesToTheSameBytes() throws {
        let date = Date(timeIntervalSince1970: 1_757_000_000.123)
        let encoded = try encoder().encode([date])
        XCTAssertEqual(
            String(decoding: encoded, as: UTF8.self), "[\"2025-09-04T15:33:20.123Z\"]")
        let again = try encoder().encode(decoder().decode([Date].self, from: encoded))
        XCTAssertEqual(encoded, again)
    }

    func test_aWholeSecondDateTheEncoderNeverWritesStillReEncodesStably() throws {
        // Hand-written: `dateEncoding` always spells the fraction, so this shape
        // only ever arrives from an older build or another writer.
        try assertStableReEncoding(of: "[\"2026-09-09T12:00:00Z\"]")

        let decoded = try decoder().decode(
            [Date].self, from: Data("[\"2026-09-09T12:00:00Z\"]".utf8))
        let expected = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-09-09T12:00:00Z"))
        XCTAssertEqual(decoded.first, expected)
    }

    func test_anEpochStringStillDecodesAndReEncodesStably() throws {
        let decoded = try decoder().decode(
            [Date].self, from: Data("[\"1757000000.5\"]".utf8))
        XCTAssertEqual(decoded.first, Date(timeIntervalSince1970: 1_757_000_000.5))
        try assertStableReEncoding(of: "[\"1757000000.5\"]")
    }

    /// The gap the review found: a fraction longer than three digits.
    /// `ISO8601DateFormatter` truncates it to the first three, so a fast path
    /// that read all nine would decode a different instant AND re-encode to a
    /// different second — a moved hash on a foreign line. The parser refuses
    /// every fraction length but three, which puts the answer back where it has
    /// always been. Asserted at the STRATEGY, because that is the level at which
    /// nothing may have changed for any input.
    func test_theStrategysAnswerIsUnchangedForFractionLengthsTheAppNeverWrites() throws {
        let strings = [
            "2026-09-09T12:00:00.999999999Z",
            "2026-09-09T12:00:00.5Z",
            "2026-09-09T12:00:00.1234Z",
        ]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()

        for string in strings {
            let viaStrategy = try XCTUnwrap(
                decoder().decode([Date].self, from: Data("[\"\(string)\"]".utf8)).first)
            let viaFormatter = try XCTUnwrap(
                fractional.date(from: string) ?? whole.date(from: string),
                "neither formatter parsed \(string)")
            XCTAssertEqual(viaStrategy, viaFormatter, "\(string)")
            XCTAssertEqual(
                try encoder().encode([viaStrategy]),
                try encoder().encode([viaFormatter]),
                "\(string) re-encodes differently")
        }
    }

    func test_anOffsetDateStillTakesTheFormatterFallback() throws {
        let decoded = try decoder().decode(
            [Date].self, from: Data("[\"2026-09-09T12:00:00+02:00\"]".utf8))
        let expected = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-09-09T12:00:00+02:00"))
        XCTAssertEqual(decoded.first, expected)
    }
}
