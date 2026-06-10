import XCTest
import MaughamCore
@testable import Maugham

final class ULIDTests: XCTestCase {
    func test_generate_produces26CharacterString() {
        let u = ULID.generate()
        XCTAssertEqual(u.count, 26)
    }

    func test_generate_usesCrockfordBase32Alphabet() {
        let u = ULID.generate()
        let allowed = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        XCTAssertTrue(u.allSatisfy { allowed.contains($0) },
            "ULID contained out-of-alphabet character: \(u)")
    }

    func test_generate_isSortableByCreationTime() async throws {
        let a = ULID.generate()
        try await Task.sleep(for: .milliseconds(2))
        let b = ULID.generate()
        XCTAssertLessThan(a, b, "earlier ULID should sort before later one")
    }

    // Pinned after SequenceKeyframingTests T5 flaked on its fresh-reload
    // assertion: Deriver.derive sorts ops by opId for last-write-wins, so
    // same-millisecond ULIDs must preserve generation order — otherwise two
    // bursts flushed in the same millisecond derive in reverse ~50% of the
    // time and the OLDER paragraph text wins.
    func test_generate_isStrictlyMonotonic_withinSameMillisecond() {
        let many = (0..<10_000).map { _ in ULID.generate() }
        for i in 1..<many.count {
            XCTAssertLessThan(many[i - 1], many[i],
                "generation order must match lexicographic order (index \(i): \(many[i - 1]) !< \(many[i]))")
        }
    }

    func test_generate_isUniqueAcrossManyCalls() {
        let many = (0..<10_000).map { _ in ULID.generate() }
        XCTAssertEqual(Set(many).count, many.count, "no duplicates expected")
    }

    func test_timestampPrefix_decodesBackToMilliseconds() {
        let before = Date().timeIntervalSince1970 * 1000
        let u = ULID.generate()
        let after = Date().timeIntervalSince1970 * 1000
        let ms = ULID.timestampMillis(of: u)
        XCTAssertNotNil(ms)
        XCTAssertGreaterThanOrEqual(Double(ms!), before - 5)
        XCTAssertLessThanOrEqual(Double(ms!), after + 5)
    }
}
