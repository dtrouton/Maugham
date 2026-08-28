import XCTest
@testable import Maugham

/// P2 (issue #25): the per-project, per-process mint gate. Pure actor
/// semantics here — the orchestrator/republisher wiring is pinned in
/// `CompileOrchestratorTests` (where the real compile path can overlap) and
/// by the production-call-site census at the bottom of this file.
final class PublishMintGateTests: XCTestCase {

    private func key(
        _ version: String = "0.1",
        _ language: String? = nil,
        _ format: PublishConfig.Format = .epub,
        _ imprint: String? = nil
    ) -> PublishMintGate.Key {
        PublishMintGate.Key(version: version, language: language, format: format, imprint: imprint)
    }

    func test_secondReservationOfTheSameTripleRefuses() async {
        let gate = PublishMintGate()
        let first = await gate.reserve(key())
        let second = await gate.reserve(key())
        XCTAssertTrue(first, "the first reservation of a free triple must be granted")
        XCTAssertFalse(second, "a second reservation of an in-flight triple must refuse")
    }

    func test_releaseMakesTheTripleReservableAgain() async {
        let gate = PublishMintGate()
        _ = await gate.reserve(key())
        await gate.release(key())
        let again = await gate.reserve(key())
        XCTAssertTrue(again, "release must return the triple to the free pool")
    }

    /// Every component of the triple is part of the identity: two keys
    /// differing in ANY one of version / language / format are independent
    /// reservations, so a writer can compile the pdf and the epub of one
    /// edition — or the source and its es rendering — at the same time.
    func test_differentTriplesReserveIndependently() async {
        let gate = PublishMintGate()
        let base = await gate.reserve(key("0.1", nil, .epub))
        let otherVersion = await gate.reserve(key("0.2", nil, .epub))
        let otherLanguage = await gate.reserve(key("0.1", "es", .epub))
        let otherFormat = await gate.reserve(key("0.1", nil, .pdf))
        XCTAssertTrue(base)
        XCTAssertTrue(otherVersion, "version differs")
        XCTAssertTrue(otherLanguage, "language differs")
        XCTAssertTrue(otherFormat, "format differs")
        // …and each of those four is now itself held.
        let repeated = await gate.reserve(key("0.1", "es", .epub))
        XCTAssertFalse(repeated)
    }

    /// Releasing a triple nobody holds is a no-op rather than a trap: the
    /// orchestrator's catch-path release can run for a reservation the
    /// success path already handed back only if the code is wrong, but a
    /// crash there would be a worse failure than a silent no-op.
    func test_releasingAnUnheldTripleIsHarmless() async {
        let gate = PublishMintGate()
        await gate.release(key())
        let reserved = await gate.reserve(key())
        XCTAssertTrue(reserved)
    }

    /// Imprint is a fourth component of the identity: two keys differing
    /// only by imprint (same version/language/format) reserve independently
    /// — a writer can compile the book and a special edition of the same
    /// version at once — and a repeat of either refuses on its own.
    func test_differentImprintsReserveIndependently() async {
        let gate = PublishMintGate()
        let book = await gate.reserve(key("0.1", nil, .pdf, nil))
        let special = await gate.reserve(key("0.1", nil, .pdf, "special-edition"))
        XCTAssertTrue(book)
        XCTAssertTrue(special, "imprint differs")
        let repeatedBook = await gate.reserve(key("0.1", nil, .pdf, nil))
        let repeatedSpecial = await gate.reserve(key("0.1", nil, .pdf, "special-edition"))
        XCTAssertFalse(repeatedBook, "the book's own triple is already in flight")
        XCTAssertFalse(repeatedSpecial, "the imprint's own triple is already in flight")
    }

    /// A release of one triple must not free another.
    func test_releaseIsScopedToItsOwnTriple() async {
        let gate = PublishMintGate()
        _ = await gate.reserve(key("0.1", nil, .epub))
        _ = await gate.reserve(key("0.1", nil, .pdf))
        await gate.release(key("0.1", nil, .pdf))
        let epubStillHeld = await gate.reserve(key("0.1", nil, .epub))
        let pdfFreed = await gate.reserve(key("0.1", nil, .pdf))
        XCTAssertFalse(epubStillHeld, "the epub reservation must survive the pdf release")
        XCTAssertTrue(pdfFreed)
    }

    // MARK: - Production call-site census
    //
    /// P2: a bilingual compile's identity is a triple of its own. "sr" and
    /// "en+sr" are two different documents, so one must never hold the other's
    /// reservation — nor be refused by it.
    func test_aJoinedIdentityIsItsOwnTriple() async {
        let gate = PublishMintGate()
        let sr = PublishMintGate.Key(version: "0.1", language: "sr", format: .epub)
        let both = PublishMintGate.Key(version: "0.1", language: "en+sr", format: .epub)
        XCTAssertNotEqual(sr, both)
        let first = await gate.reserve(sr)
        let second = await gate.reserve(both)
        XCTAssertTrue(first, "the single-tongue edition reserves")
        XCTAssertTrue(second, "and the bilingual one is not refused by it")
    }

    // The gate is a DEFAULTED constructor parameter, so a production site that
    // forgets it still compiles — and silently gets a private gate that can
    // never see the other caller's reservation, which is exactly the bug this
    // task fixes. The compiler cannot catch that; this census can. It is a
    // census, not an allow/deny list: when a new production construction site
    // appears, it must pass the shared gate through.

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Publish
            .deletingLastPathComponent()   // MaughamTests
            .deletingLastPathComponent()   // repo root
    }

    func test_everyProductionCompilerConstructionPassesTheSharedGate() throws {
        let appDir = repoRoot.appendingPathComponent("Maugham", isDirectory: true)
        let files = FileManager.default.enumerator(
            at: appDir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []

        var offenders: [String] = []
        var sites = 0
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for constructor in ["CompileOrchestrator(", "Republisher("] {
                var search = text.startIndex..<text.endIndex
                while let found = text.range(of: constructor, range: search) {
                    search = found.upperBound..<text.endIndex
                    // Walk to the call's own closing paren, counting depth —
                    // both sites nest another constructor in their argument
                    // list (`ProjectStoreASTSource(…)`), so the first `)` is
                    // not the end of the call.
                    var depth = 1
                    var args = ""
                    for ch in text[found.upperBound...] {
                        if ch == "(" { depth += 1 }
                        if ch == ")" {
                            depth -= 1
                            if depth == 0 { break }
                        }
                        args.append(ch)
                    }
                    sites += 1
                    if !args.contains("mintGate:") {
                        offenders.append(
                            "\(file.lastPathComponent): \(constructor) without mintGate:")
                    }
                }
            }
        }
        XCTAssertEqual(sites, 2,
                       "expected exactly the two production construction sites (CompileTools, PublicationTools); found \(sites)")
        XCTAssertTrue(offenders.isEmpty,
                      "every production construction must pass PublishingStores' shared gate:\n" +
                      offenders.joined(separator: "\n"))
    }
}
