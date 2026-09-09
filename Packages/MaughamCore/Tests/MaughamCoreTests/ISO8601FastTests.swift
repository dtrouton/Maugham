import XCTest
@testable import MaughamCore

/// `ISO8601Fast` against the formatter it stands in front of. The parser is
/// allowed to be narrow — it takes the two shapes the app itself writes and
/// refuses everything else — but where it answers at all it must answer what
/// `ISO8601DateFormatter` would, because a cold open decodes dates the app
/// wrote in an older build and the two answers are compared as one value.
final class ISO8601FastTests: XCTestCase {

    private func fractionalFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    // MARK: - Equivalence with the formatter

    func test_theFastParserAgreesWithTheFormatterOverTheShapesTheAppWrites() throws {
        let corpus = [
            "1970-01-01T00:00:00Z",
            "1970-01-01T00:00:00.000Z",
            "2000-02-29T12:00:00.500Z",
            "2024-02-29T23:59:59.999Z",
            "2026-09-09T00:00:00.001Z",
            "2099-12-31T23:59:59Z",
            "1969-12-31T23:59:59Z",
            "2026-03-01T00:00:00Z",
        ]
        let fractional = fractionalFormatter()
        let whole = ISO8601DateFormatter()

        for string in corpus {
            let formatter = string.contains(".") ? fractional : whole
            let expected = try XCTUnwrap(
                formatter.date(from: string), "formatter refused \(string)")
            let actual = try XCTUnwrap(
                ISO8601Fast.date(utf8: string.utf8), "fast parser refused \(string)")
            XCTAssertLessThan(
                abs(actual.timeIntervalSinceReferenceDate
                    - expected.timeIntervalSinceReferenceDate),
                1e-6,
                "\(string): fast \(actual) vs formatter \(expected)")
        }
    }

    // MARK: - Refusals

    func test_everyShapeOutsideTheTwoIsRefused() {
        let refusals = [
            "2026-09-09T12:00:00+01:00",
            "2026-09-09T12:00:00.123+00:00",
            "2026-09-09 12:00:00Z",
            "2026-09-09T12:00:00",
            "2026-13-01T00:00:00Z",
            "2026-02-30T00:00:00Z",
            "2026-09-09T24:00:00Z",
            "2026-09-09T12:60:00Z",
            "1757000000",
            "2026-09-09T12:00:00z",
            "",
        ]
        for string in refusals {
            XCTAssertNil(
                ISO8601Fast.date(utf8: string.utf8),
                "fast parser accepted \(string.isEmpty ? "<empty>" : string)")
        }
    }

    // MARK: - Property

    func test_tenThousandRandomDatesRoundTripThroughTheFormattersOwnSpelling() throws {
        let formatter = fractionalFormatter()
        // Seeded, so a failure is reproducible rather than a once-a-month flake.
        var generator = SplitMix64(seed: 0x4D61_7567_6861_6D01)
        // 1970-01-01 .. 2100-01-01, drawn at microsecond resolution so the
        // formatter's own rounding to milliseconds is part of what's asserted.
        let upperMicroseconds: UInt64 = 4_102_444_800_000_000

        for _ in 0..<10_000 {
            let seconds = Double(generator.next() % upperMicroseconds) / 1_000_000
            let date = Date(timeIntervalSince1970: seconds)
            let string = formatter.string(from: date)
            let parsed = try XCTUnwrap(
                ISO8601Fast.date(utf8: string.utf8), "fast parser refused \(string)")
            // The formatter's own spelling rounds to milliseconds.
            XCTAssertLessThan(
                abs(parsed.timeIntervalSince1970 - seconds), 1e-3,
                "\(string) parsed as \(parsed.timeIntervalSince1970), wanted \(seconds)")
        }
    }
}
