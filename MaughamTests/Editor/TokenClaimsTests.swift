import XCTest
@testable import Maugham

/// `TokenClaims` replaced the tokenizer's `tokens.contains { $0.range
/// .intersection(c) != nil }` scan. It must answer exactly as that scan did,
/// including `NSRange.intersection`'s zero-length and adjacency edges.
final class TokenClaimsTests: XCTestCase {

    /// The old rule, as the oracle.
    private func oldOverlaps(_ claimed: [NSRange], _ r: NSRange) -> Bool {
        claimed.contains { $0.intersection(r) != nil }
    }

    private func claims(_ ranges: [NSRange]) -> TokenClaims {
        var c = TokenClaims()
        var sink: [Token] = []
        for r in ranges { c.claimIfFree(Token(range: r, kind: .plain), into: &sink) }
        return c
    }

    private func r(_ loc: Int, _ len: Int) -> NSRange { NSRange(location: loc, length: len) }

    func test_zeroLengthCandidateAtTheStartMiddleAndEndOfAClaim() {
        let c = claims([r(2, 4)])                     // covers 2,3,4,5
        XCTAssertTrue(c.overlaps(r(2, 0)), "start: inside")
        XCTAssertTrue(c.overlaps(r(4, 0)), "middle: inside")
        XCTAssertFalse(c.overlaps(r(6, 0)), "end: just past, outside")
        XCTAssertFalse(c.overlaps(r(1, 0)))
    }

    func test_aClaimedZeroLengthRangeBlocksACandidateCoveringIt() {
        let c = claims([r(5, 0)])
        XCTAssertTrue(c.overlaps(r(5, 2)), "starting at it")
        XCTAssertTrue(c.overlaps(r(3, 3)), "covering it")
        XCTAssertFalse(c.overlaps(r(3, 2)), "ending at it")
    }

    func test_twoZeroLengthRangesNeverOverlap() {
        XCTAssertFalse(claims([r(5, 0)]).overlaps(r(5, 0)))
    }

    func test_adjacentRangesDoNotOverlap() {
        let c = claims([r(2, 3)])
        XCTAssertFalse(c.overlaps(r(5, 2)), "after")
        XCTAssertFalse(c.overlaps(r(0, 2)), "before")
        XCTAssertTrue(c.overlaps(r(4, 2)), "sharing one character")
    }

    func test_anOverlappingCandidateIsNotClaimed() {
        var c = TokenClaims()
        var tokens: [Token] = []
        c.claimIfFree(Token(range: r(0, 4), kind: .plain), into: &tokens)
        c.claimIfFree(Token(range: r(3, 4), kind: .code), into: &tokens)
        c.claimIfFree(Token(range: r(4, 4), kind: .code), into: &tokens)
        XCTAssertEqual(tokens.map(\.range), [r(0, 4), r(4, 4)])
    }

    /// Exhaustive over small ranges: every claim set of up to two ranges in
    /// 0..<6 (lengths 0...3) against every candidate agrees with the old scan.
    func test_agreesWithTheOldIntersectionScanEverywhere() {
        var all: [NSRange] = []
        for loc in 0..<6 { for len in 0...3 { all.append(r(loc, len)) } }
        var sets: [[NSRange]] = [[]] + all.map { [$0] }
        for a in all { for b in all { sets.append([a, b]) } }
        for set in sets {
            // Claim as the tokenizer would: only what doesn't overlap.
            var claimedSoFar: [NSRange] = []
            for x in set where !oldOverlaps(claimedSoFar, x) { claimedSoFar.append(x) }
            let c = claims(set)
            for cand in all {
                XCTAssertEqual(c.overlaps(cand), oldOverlaps(claimedSoFar, cand),
                               "claims \(set) vs candidate \(cand)")
            }
        }
    }
}
