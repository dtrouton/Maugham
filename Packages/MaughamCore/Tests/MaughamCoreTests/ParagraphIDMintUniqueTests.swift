import XCTest
@testable import MaughamCore

/// Pins the 2026-06-10 paste-crash fix: `ParagraphID.mintUnique(excluding:)`
/// must never return a member of the exclusion set. Plain `mint()` is 4
/// random chars over a 32⁴ ≈ 1.05M space, so high-volume mint sites
/// (Bootstrap, paste-path restorePairs) collide with existing ids with high
/// probability at manuscript scale — the collision fed
/// `Dictionary(uniqueKeysWithValues:)` in TaskAnchorAlignment and trapped.
final class ParagraphIDMintUniqueTests: XCTestCase {

    private static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")

    /// THE exhaustive pin: exclude every id in the space EXCEPT one — the
    /// only possible return value is the survivor. This forces the retry
    /// loop through (on average) ~1M rejected draws, deterministically
    /// proving both termination and the exclusion contract.
    func test_mintUnique_returnsTheOnlyFreeId() {
        let survivor = "ztz9"
        var used = Set<String>(minimumCapacity: 1_100_000)
        var buf = [Character](repeating: "0", count: 4)
        for a in Self.alphabet {
            buf[0] = a
            for b in Self.alphabet {
                buf[1] = b
                for c in Self.alphabet {
                    buf[2] = c
                    for d in Self.alphabet {
                        buf[3] = d
                        used.insert(String(buf))
                    }
                }
            }
        }
        XCTAssertEqual(used.count, 32 * 32 * 32 * 32)
        used.remove(survivor)

        let minted = ParagraphID.mintUnique(excluding: used)
        XCTAssertEqual(minted, survivor,
                       "the only un-excluded id must be the one minted")
    }

    /// Accumulation contract: callers insert each result before the next
    /// call; the resulting stream is duplicate-free by construction. 10k
    /// mints against a growing set — any repeat fails.
    func test_mintUnique_streamIsDuplicateFree() {
        var used = Set<String>()
        for i in 0..<10_000 {
            let id = ParagraphID.mintUnique(excluding: used)
            XCTAssertFalse(used.contains(id), "duplicate at mint \(i)")
            XCTAssertNotNil(ParagraphID.parseComment("<!-- ¶\(id) -->"),
                            "minted id must stay alphabet-valid")
            used.insert(id)
        }
    }
}
