import XCTest
@testable import Maugham

/// The third arm of the canvas inspector. Which SwiftUI arm renders cannot be
/// asserted (`_ConditionalContent` is branch-invariant), so the decision the
/// view makes is lifted into `artifactState` and pinned here — the same shape
/// `RegionInspector.citeAffordance` uses.
@MainActor
final class ScrapInspectorTests: XCTestCase {

    private let a = CanvasNodeID("a")

    private func model(promoted: String? = nil) -> CanvasModel {
        let m = CanvasModel()
        m.withScene { s in
            s.insert(CanvasNode(id: a, kind: .scrap, origin: .zero,
                                width: 240, cachedHeight: 80,
                                promotedItemID: promoted))
        }
        m.setScrapText("The falls at night\n\nSodium light.", for: a)
        return m
    }

    func test_theSelectedNodeResolvesThroughTheSceneAndNotTheRawId() {
        let m = model()
        XCTAssertNil(m.selectedNode, "no selection")
        m.selection = .node(a)
        XCTAssertEqual(m.selectedNode?.id, a)
        m.withScene { $0.remove(a) }
        XCTAssertNil(m.selectedNode,
                     "a stale id left by an undo answers nil rather than being "
                     + "handed out as a card that no longer exists")
    }

    func test_aRegionSelectionIsNotANodeSelection() {
        let m = model()
        m.selection = .region(CanvasRegionID("r1"))
        XCTAssertNil(m.selectedNode)
    }

    /// An item node has no arm of its own until 1C-d, and it must not take the
    /// card's: every sentence in `ScrapInspector` is wrong for a reference —
    /// "The words live on the card", "Promoting takes a copy" — and an item node
    /// cannot be promoted at all. The pane routed every `selectedNode` there.
    ///
    /// `selectedNode` itself still resolves; the guard is the `case .scrap` in
    /// `RegionInspectorPane`, and this is the fact that guard reads.
    func test_anItemNodeIsResolvedAndIsNotAScrap() {
        let m = CanvasModel()
        let ref = CanvasNodeID.item("r-9")
        m.withScene { s in
            s.insert(CanvasNode(id: ref, kind: .item(referenceId: "r-9"),
                                origin: .zero, width: 180, cachedHeight: 120))
        }
        m.selection = .node(ref)
        let node = m.selectedNode
        XCTAssertNotNil(node)
        if case .scrap = node?.kind {
            XCTFail("an item node must not answer the scrap arm's guard")
        }
    }

    // MARK: - What the pane says

    func test_anUnpromotedCardSaysSoRatherThanShowingNothing() {
        XCTAssertEqual(
            PromotedArtifactSection.artifactState(promotedItemID: nil, title: nil),
            .notPromoted)
    }

    func test_aPromotedCardNamesWhatItBecame() {
        XCTAssertEqual(
            PromotedArtifactSection.artifactState(promotedItemID: "res-a",
                                                  title: "The falls at night"),
            .promoted(itemID: "res-a", title: "The falls at night"))
    }

    /// The dangling mark: the note was deleted after the promotion. The pane has
    /// to say so — silently showing "not promoted" would be a lie the writer
    /// cannot check, and showing a raw id would be one they cannot read.
    func test_aMarkWhoseArtifactIsGoneSaysThatRatherThanPretendingItIsUnpromoted() {
        XCTAssertEqual(
            PromotedArtifactSection.artifactState(promotedItemID: "res-gone", title: nil),
            .artifactMissing(itemID: "res-gone"))
    }

    // MARK: - Both arms, one section

    /// **A region's mark had no surface at all for one slice.** The card arm
    /// said what it became, offered Open and rendered the dangling case; the
    /// region arm — same field, same drawn stripe, same VoiceOver term — said
    /// nothing, so a writer met a permanent stripe on a region's chrome bar with
    /// no way to learn what it produced. The section is now one implementation
    /// both arms are handed, and the copy is honest for each.
    func test_theRegionArmNamesThePaletteCardAndTheCardArmDoesNot() {
        XCTAssertEqual(PromotedArtifactSection.Subject.region.became("Act II fog"),
                       "Became the palette card “Act II fog”",
                       "a region's mark can only ever name a palette card — a "
                       + "piece binding produces no artifact and leaves no mark")
        XCTAssertEqual(PromotedArtifactSection.Subject.card.became("Act II fog"),
                       "Became “Act II fog”",
                       "a card's may name a note, a palette card or the craft "
                       + "intent, and this arm is not told which")
    }

    func test_theDanglingSentenceNamesWhichThingWasPromoted() {
        XCTAssertEqual(PromotedArtifactSection.Subject.card.noun, "card")
        XCTAssertEqual(PromotedArtifactSection.Subject.region.noun, "region")
    }

    /// The census that would have caught the omission: both arms mount the
    /// shared section, and both are handed the two closures that make **Open**
    /// work. A green suite cannot tell a rendered section from an absent one
    /// (`_ConditionalContent` is branch-invariant and a `Form`'s contents are
    /// not inspectable), and this directory's four unreachable halves were every
    /// one of them found by counting production sites.
    func test_bothInspectorArmsMountTheSharedPromotedSection() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        for file in ["Maugham/Canvas/ScrapInspector.swift",
                     "Maugham/Canvas/RegionInspector.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file),
                                  encoding: .utf8)
            XCTAssertTrue(text.contains("PromotedArtifactSection(state:"),
                          "\(file) must render the shared section — a mark with no "
                          + "surface is CLAUDE.md rule 8 failing, and it failed for "
                          + "the region arm for a whole slice")
            XCTAssertTrue(text.contains("onOpen: onOpenResearchItem"),
                          "\(file) must wire Open, or the section names an artifact "
                          + "the writer cannot reach")
        }
        // Self-check: the scan can report an absence. Without this the two
        // assertions above are a census over a REQUIRED token, which is exactly
        // the shape that passes while blind.
        let unrelated = try String(
            contentsOf: root.appendingPathComponent("Maugham/Canvas/LineInspector.swift"),
            encoding: .utf8)
        XCTAssertFalse(unrelated.contains("PromotedArtifactSection(state:"),
                       "a line promotion writes text into somebody else's note and "
                       + "leaves no mark, so the line arm has nothing to show — and "
                       + "this proves the scan above reads the file rather than "
                       + "always answering true")
    }

    /// **The pane routes only a scrap to the card arm**, and this is the
    /// instrument that pins it.
    ///
    /// Which `_ConditionalContent` arm *renders* cannot be asserted — the type
    /// is branch-invariant — but the line's PRESENCE can be, and a deletion is
    /// what would remove it. Every sentence in `ScrapInspector` is wrong for a
    /// reference ("The words live on the card", "Promoting takes a copy") and an
    /// item node cannot be promoted at all, so the guard is the difference
    /// between an honest empty state and a pane telling the writer to promote
    /// something that already exists as itself.
    func test_thePaneRoutesOnlyAScrapToTheCardArm() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let text = try String(
            contentsOf: root.appendingPathComponent("Maugham/Canvas/RegionInspector.swift"),
            encoding: .utf8)
        XCTAssertTrue(text.contains("case .scrap = node.kind"),
                      "RegionInspectorPane must guard the selectedNode branch on the "
                      + "node's KIND — without it every node reaches ScrapInspector, "
                      + "whose whole copy assumes a scrap")
        // The companion: prove the scan reports an absent token rather than
        // always answering true. A census over a REQUIRED token is exactly the
        // shape that passes while blind, and the plant names a spelling that
        // cannot exist in production.
        XCTAssertFalse(text.contains("case .notARealKind = node.kind"),
                       "the scan reads the file rather than always answering true")
    }
}
