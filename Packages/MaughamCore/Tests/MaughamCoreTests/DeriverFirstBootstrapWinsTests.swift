import XCTest
@testable import MaughamCore

/// F3 — first-bootstrap-wins in the Deriver.
///
/// Post-migration `.md` files are clean, so "op log is empty" is the sole
/// bootstrap signal. iCloud delivering the `.md` before `.maugham/ops/` makes
/// device B re-mint every ¶id; when the real log finally merges in, a naive
/// fold would apply the re-mint bootstrap on top of the real history — its
/// fresh ids replacing the originals, mass-orphaning paragraph-anchored
/// annotations. The Deriver now honors only the FIRST `.bootstrap` op (ULID
/// order) and skips any later one entirely (changes AND sequence), making the
/// re-mint inert once the real log syncs in.
final class DeriverFirstBootstrapWinsTests: XCTestCase {

    private func op(
        _ opId: String, _ kind: OpKind,
        changes: [Op.ParagraphChange], sequence: [String]?
    ) -> Op {
        Op(opId: opId, docId: "doc-1", at: Date(), device: "m", session: "s",
           kind: kind, changes: changes, sequence: sequence)
    }

    // MARK: - (a) re-mint after a real history is inert

    func test_reMintBootstrapAfterHistory_isInert_derive() {
        let bootstrap = op("01AAAA", .bootstrap, changes: [
            .init(paragraphId: "aaaa", prior: nil, next: "Alpha."),
            .init(paragraphId: "bbbb", prior: nil, next: "Bravo."),
        ], sequence: ["aaaa", "bbbb"])
        // Real drafting history on top of the original ids.
        let typing = op("02BBBB", .typingBurst, changes: [
            .init(paragraphId: "aaaa", prior: "Alpha.", next: "Alpha edited."),
            .init(paragraphId: "cccc", prior: nil, next: "Charlie."),
        ], sequence: ["aaaa", "bbbb", "cccc"])
        // Device B's partial-sync re-mint: same content, FRESH ids, later opId.
        let reMint = op("03CCCC", .bootstrap, changes: [
            .init(paragraphId: "wwww", prior: nil, next: "Alpha edited."),
            .init(paragraphId: "xxxx", prior: nil, next: "Bravo."),
            .init(paragraphId: "yyyy", prior: nil, next: "Charlie."),
        ], sequence: ["wwww", "xxxx", "yyyy"])

        let before = Deriver.derive(ops: [bootstrap, typing])
        let after = Deriver.derive(ops: [bootstrap, typing, reMint])

        XCTAssertEqual(after, before,
            "a re-mint bootstrap appended after real history must be fully inert")
        // Belt-and-suspenders: the re-minted ids never appear.
        XCTAssertEqual(after.sequence, ["aaaa", "bbbb", "cccc"])
        XCTAssertNil(after.paragraphs["wwww"])
        XCTAssertNil(after.paragraphs["yyyy"])
    }

    // MARK: - (b) single bootstrap is unchanged

    func test_singleBootstrap_unchanged_derive() {
        let bootstrap = op("01AAAA", .bootstrap, changes: [
            .init(paragraphId: "aaaa", prior: nil, next: "Alpha."),
            .init(paragraphId: "bbbb", prior: nil, next: "Bravo."),
        ], sequence: ["aaaa", "bbbb"])
        let derived = Deriver.derive(ops: [bootstrap])
        XCTAssertEqual(derived.sequence, ["aaaa", "bbbb"])
        XCTAssertEqual(derived.paragraphs["aaaa"], "Alpha.")
        XCTAssertEqual(derived.paragraphs["bbbb"], "Bravo.")
    }

    // MARK: - (c) applies to deriveWithSequenceFallback too

    func test_reMintBootstrapAfterHistory_isInert_deriveWithSequenceFallback() {
        let bootstrap = op("01AAAA", .bootstrap, changes: [
            .init(paragraphId: "aaaa", prior: nil, next: "Alpha."),
            .init(paragraphId: "bbbb", prior: nil, next: "Bravo."),
        ], sequence: ["aaaa", "bbbb"])
        let typing = op("02BBBB", .typingBurst, changes: [
            .init(paragraphId: "cccc", prior: nil, next: "Charlie."),
        ], sequence: ["aaaa", "bbbb", "cccc"])
        let reMint = op("03CCCC", .bootstrap, changes: [
            .init(paragraphId: "wwww", prior: nil, next: "Alpha."),
            .init(paragraphId: "xxxx", prior: nil, next: "Bravo."),
            .init(paragraphId: "yyyy", prior: nil, next: "Charlie."),
        ], sequence: ["wwww", "xxxx", "yyyy"])

        let before = Deriver.deriveWithSequenceFallback(ops: [bootstrap, typing])
        let after = Deriver.deriveWithSequenceFallback(
            ops: [bootstrap, typing, reMint])

        XCTAssertEqual(after, before,
            "deriveWithSequenceFallback must also skip a re-mint bootstrap")
        XCTAssertEqual(after.sequence, ["aaaa", "bbbb", "cccc"])
        XCTAssertNil(after.paragraphs["wwww"])
    }

    func test_singleBootstrap_unchanged_deriveWithSequenceFallback() {
        let bootstrap = op("01AAAA", .bootstrap, changes: [
            .init(paragraphId: "aaaa", prior: nil, next: "Alpha."),
        ], sequence: ["aaaa"])
        let derived = Deriver.deriveWithSequenceFallback(ops: [bootstrap])
        XCTAssertEqual(derived.sequence, ["aaaa"])
        XCTAssertEqual(derived.paragraphs["aaaa"], "Alpha.")
    }

    // MARK: - order-independence: re-mint stays inert regardless of input order

    func test_reMint_inert_regardlessOfInputOrder() {
        let bootstrap = op("01AAAA", .bootstrap, changes: [
            .init(paragraphId: "aaaa", prior: nil, next: "Alpha."),
        ], sequence: ["aaaa"])
        let typing = op("02BBBB", .typingBurst, changes: [
            .init(paragraphId: "bbbb", prior: nil, next: "Bravo."),
        ], sequence: ["aaaa", "bbbb"])
        let reMint = op("03CCCC", .bootstrap, changes: [
            .init(paragraphId: "wwww", prior: nil, next: "Alpha."),
            .init(paragraphId: "xxxx", prior: nil, next: "Bravo."),
        ], sequence: ["wwww", "xxxx"])

        // Deriver sorts by opId internally, so a shuffled input still folds the
        // re-mint (highest opId) last and skips it.
        let shuffled = Deriver.derive(ops: [reMint, typing, bootstrap])
        XCTAssertEqual(shuffled.sequence, ["aaaa", "bbbb"])
        XCTAssertNil(shuffled.paragraphs["wwww"])
        XCTAssertNil(shuffled.paragraphs["xxxx"])
    }
}
