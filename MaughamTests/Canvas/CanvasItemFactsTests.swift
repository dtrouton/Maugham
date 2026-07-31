import AppKit
import XCTest
import MaughamCore
@testable import Maugham

/// Spec §8A.1: what an item node SAYS it is — a title, a kind glyph and, when
/// there is a picture, the project-relative path to it.
///
/// Everything here is pure. The resolver is handed an index and never reaches
/// for a `ProjectStore`, which is what makes these assertions possible without
/// a project on disk — `Promotion`/`ArtifactIndex`'s own shape, and the reason
/// `CanvasAuthorLine` documents a store read from a `body` as a failure.
final class CanvasItemFactsTests: XCTestCase {

    // MARK: - The manifest these tests read

    /// The four things a canvas can point at, built the way production builds
    /// them: a palette card inside the role-stamped palette group, a plain
    /// note, an image with a path, and the group itself.
    private func research() -> [ResearchItem] {
        let card = ResearchItem(id: "res-card", title: "Act II fog", type: .asset,
                                kind: .document, path: "research/palette/act-ii-fog.md")
        let group = ResearchItem(id: "res-palette", title: "Palette", type: .group,
                                 path: PaletteConvention.folderPath,
                                 children: [card], role: .paletteGroup)
        let note = ResearchItem(id: "res-note", title: "The falls at night", type: .asset,
                                kind: .document, path: "research/the-falls-at-night.md")
        let photo = ResearchItem(id: "res-photo", title: "The gorge from above",
                                 type: .asset, kind: .image,
                                 path: "research/research_assets/gorge.jpg")
        return [group, note, photo]
    }

    private func index() -> CanvasItemIndex {
        CanvasItemIndex.over(research: research())
    }

    private func facts(_ id: String) -> CanvasItemFacts {
        CanvasItemFacts.resolve(.project(id: id), in: index())
    }

    // MARK: - A referenced item

    /// The headline: the manifest's own title, never the id.
    func test_aReferencedItemTakesItsTitleFromTheManifest() {
        XCTAssertEqual(facts("res-note").title, "The falls at night")
        XCTAssertEqual(facts("res-card").title, "Act II fog")
        XCTAssertEqual(facts("res-photo").title, "The gorge from above")
    }

    /// A note, a palette card and an image must be tellable apart at a glance —
    /// which is the whole job of the glyph. Asserted as three-way inequality
    /// rather than against three literals, so a re-spelling of one symbol name
    /// stays green and a *collapse* of two kinds onto one symbol goes red.
    func test_theKindGlyphDiffersBetweenANoteAPaletteCardAndAnImage() {
        let note = facts("res-note").glyph
        let card = facts("res-card").glyph
        let photo = facts("res-photo").glyph
        XCTAssertNotEqual(note, card)
        XCTAssertNotEqual(note, photo)
        XCTAssertNotEqual(card, photo)
        // Control: the three are not merely distinct, they are non-empty —
        // `Image(systemName: "")` draws nothing and would pass every
        // inequality above.
        for glyph in [note, card, photo] { XCTAssertFalse(glyph.isEmpty) }
    }

    /// The path Task 3's cache is keyed on: the item's OWN path out of the
    /// manifest, project-relative, never an absolute URL.
    func test_anImageCarriesItsProjectRelativePathAndOtherKindsCarryNone() throws {
        let path = try XCTUnwrap(facts("res-photo").thumbnailPath)
        XCTAssertEqual(path, "research/research_assets/gorge.jpg")
        XCTAssertFalse(path.hasPrefix("/"))
        // A note has no picture, so there is nothing to draw and nothing to
        // queue a decode for. `CanvasThumbnails` would memo a permanent
        // failure for every one of them.
        let note = facts("res-note")
        XCTAssertNil(note.thumbnailPath)
    }

    /// A group is IN the project, so it must not read as deleted. `over` walks
    /// every node the manifest holds, groups included, for exactly this.
    func test_anItemPointingAtAGroupResolvesRatherThanReadingAsDeleted() {
        let group = facts("res-palette")
        XCTAssertEqual(group.title, "Palette")
        XCTAssertNotEqual(group.title, CanvasItemFacts.missingTitle)
        XCTAssertNil(group.thumbnailPath)
    }

    // MARK: - A referenced item the writer deleted

    /// **The assertion is that no id appears** — not that the sentence is
    /// non-empty. An id is not something the writer can read, and
    /// `PromotedArtifactSection.contributionArtifactMissing` set that precedent.
    func test_anItemTheWriterDeletedSaysSoAndNamesNoId() {
        let gone = CanvasItemFacts.resolve(.project(id: "res-3f2a"), in: index())
        XCTAssertFalse(gone.title.contains("res-3f2a"))
        XCTAssertFalse(gone.title.contains("3f2a"))
        XCTAssertEqual(gone.title, CanvasItemFacts.missingTitle)
        XCTAssertNil(gone.thumbnailPath)

        // **The control the negative assertion needs.** `contains` finding
        // nothing proves nothing on its own — the same two assertions pass
        // against a title that is the empty string, against a resolver that
        // returns a fixed word, and against a test that built the wrong id. So:
        // the same apparatus, aimed at an item that IS in the manifest, finds
        // what it is looking for.
        let present = CanvasItemFacts.resolve(.project(id: "res-note"), in: index())
        XCTAssertTrue(present.title.contains("falls"))
    }

    /// Two different missing ids produce the SAME sentence, which is the
    /// strongest available statement that no id leaked in through some other
    /// spelling (a suffix, a truncation, a debug interpolation).
    func test_twoDifferentDeletedItemsSayTheSameThing() {
        let one = CanvasItemFacts.resolve(.project(id: "res-3f2a"), in: index())
        let two = CanvasItemFacts.resolve(.project(id: "res-90zz"), in: index())
        XCTAssertEqual(one, two)
    }

    /// **The register is pinned against the precedent itself, not against a
    /// literal.** `PromotedArtifactSection.Subject.contributionArtifactMissing`
    /// is the existing sentence for a dangling record, and this one is
    /// deliberately its predicate with the subject elided — so the two are
    /// asserted against each other, and a rewording of either that leaves them
    /// speaking differently about the same fact goes red. **Every subject's
    /// wording, since 1C-d Task 8 gave the picture its own**: they differ in
    /// their subject and must not differ in this.
    func test_theMissingSentenceIsThePaneSOwnPredicate() {
        for subject: PromotedArtifactSection.Subject in [.card, .region, .picture] {
            XCTAssertTrue(subject.contributionArtifactMissing
                .lowercased()
                .hasSuffix(CanvasItemFacts.missingTitle.lowercased()),
                          "found: \(subject.contributionArtifactMissing)")
        }
        // A sentence, not a fragment or a label.
        XCTAssertTrue(CanvasItemFacts.missingTitle.hasSuffix("."))
    }

    // MARK: - An owned item

    /// An owned image has no manifest entry and never will — so it resolves
    /// against an EMPTY index, which is the strongest form of "needs no
    /// manifest" a test can state.
    func test_anOwnedImageResolvesWithNoManifestAtAll() throws {
        let empty = CanvasItemIndex(entriesByID: [:])
        let owned = CanvasItemFacts.resolve(
            .owned(path: "canvas_assets/image-20260730-220430.png"), in: empty)

        XCTAssertEqual(owned.title, CanvasItemFacts.ownedTitle)
        XCTAssertNotEqual(owned.title, CanvasItemFacts.missingTitle)
        XCTAssertEqual(try XCTUnwrap(owned.thumbnailPath),
                       "canvas_assets/image-20260730-220430.png")
        XCTAssertEqual(owned.glyph, CanvasItemFacts.resolve(.project(id: "res-photo"),
                                                            in: index()).glyph)
    }

    /// **The title names no path**, which is the failure the 1C-d plan calls
    /// out by name: `Item · canvas_assets/photo-20260730-121314.png` is the
    /// storage answer to a question about content.
    func test_anOwnedImagesTitleNamesNoPath() {
        let owned = CanvasItemFacts.resolve(
            .owned(path: "canvas_assets/image-20260730-220430.png"), in: index())
        XCTAssertFalse(owned.title.contains("canvas_assets"))
        XCTAssertFalse(owned.title.contains("image-20260730-220430"))
        XCTAssertFalse(owned.title.contains("/"))
        XCTAssertFalse(owned.title.contains(".png"))
    }

    // MARK: - The control: determinism

    /// Task 5 measures CACHING. A resolver that answered differently on the
    /// second call would make its cache test unfalsifiable — it would go green
    /// on nondeterminism. All three provenances, because the missing arm and
    /// the owned arm each build their answer from a constant and could each
    /// acquire a clock or a counter.
    func test_resolvingTwiceReturnsEqualFacts() {
        let idx = index()
        for reference: CanvasItemReference in [.project(id: "res-note"),
                                               .project(id: "res-photo"),
                                               .project(id: "res-gone"),
                                               .owned(path: "canvas_assets/a.png")] {
            XCTAssertEqual(CanvasItemFacts.resolve(reference, in: idx),
                           CanvasItemFacts.resolve(reference, in: idx))
        }
    }

    // MARK: - The cache key

    /// **The property the whole cache key rests on.** Two builds over the same
    /// manifest must fingerprint the same, or a key holding it is invalidated
    /// on every window body pass and caches nothing — the index is rebuilt
    /// eagerly, exactly as `ProjectWindow.pieceChoices` is.
    func test_twoBuildsOverTheSameManifestFingerprintTheSame() {
        XCTAssertEqual(CanvasItemIndex.over(research: research()).fingerprint,
                       CanvasItemIndex.over(research: research()).fingerprint)
    }

    /// **The failure `sceneRevision` alone cannot see.** The writer renames the
    /// research note a card points at; nothing on the canvas moved, so the
    /// scene counter does not budge — and without this the card goes on showing
    /// the old title for the rest of the session.
    func test_renamingAnItemMovesTheFingerprint() {
        var renamed = research()
        renamed[1].title = "The falls, at night"
        XCTAssertNotEqual(CanvasItemIndex.over(research: research()).fingerprint,
                          CanvasItemIndex.over(research: renamed).fingerprint)
        // And the rename actually reaches the facts, or the fingerprint above
        // is measuring something the resolver does not read.
        XCTAssertEqual(CanvasItemFacts
            .resolve(.project(id: "res-note"),
                     in: CanvasItemIndex.over(research: renamed)).title,
                       "The falls, at night")
    }

    /// Deleting one moves it too — the other half of what a manifest change is.
    func test_deletingAnItemMovesTheFingerprint() {
        let fewer = Array(research().dropLast())
        XCTAssertNotEqual(CanvasItemIndex.over(research: research()).fingerprint,
                          CanvasItemIndex.over(research: fewer).fingerprint)
    }

    /// **The key is content-derived, not a save counter, and this is the
    /// difference.** A manifest change that touches nothing the resolver reads
    /// leaves the fingerprint alone, so the cache survives it. A counter on
    /// every manifest write would throw the whole canvas's resolution away
    /// because the writer tagged a note.
    func test_aChangeTheFactsDoNotReadLeavesTheFingerprintAlone() {
        var tagged = research()
        tagged[1].tags = ["fog", "act-ii"]
        XCTAssertEqual(CanvasItemIndex.over(research: research()).fingerprint,
                       CanvasItemIndex.over(research: tagged).fingerprint)
    }

    /// **Every field the facts read has to be in the join, and nothing checks
    /// that for free any more** *(Task 5 re-review, D1)*.
    ///
    /// The fingerprint was `entriesByID.hashValue`, which covered every field of
    /// `Entry` whether or not anyone remembered it. It is a hand-rolled join over
    /// `(id, title, kind, path)` now — the cost of not seeding it — so a fourth
    /// field on `Entry`, or a dropped term, is a silent hole: the cache would
    /// serve a stale fact until something else moved the key. Dropping
    /// `entry.kind.rawValue` from the join today leaves every other test in this
    /// file green.
    ///
    /// The title's term is covered by `test_renamingAnItemMovesTheFingerprint`
    /// above; these are the other two.
    func test_aChangeOfKindMovesTheFingerprint() {
        var converted = research()
        // The note becomes a photograph — same id, same title, same path.
        converted[1].kind = .image
        XCTAssertNotEqual(CanvasItemIndex.over(research: research()).fingerprint,
                          CanvasItemIndex.over(research: converted).fingerprint,
                          "the kind is not in the fingerprint's join, so a card would "
                          + "go on drawing a document glyph over a photograph")
        // Control: the change really does reach the facts, or the assertion above
        // is measuring a field the resolver never reads.
        XCTAssertEqual(CanvasItemFacts
            .resolve(.project(id: "res-note"),
                     in: CanvasItemIndex.over(research: converted)).glyph,
                       CanvasItemKind.image.glyph)
    }

    /// The thumbnail PATH is the third term, and it is the one whose staleness is
    /// invisible: a card would go on drawing the picture that used to be there.
    func test_aChangeOfImagePathMovesTheFingerprint() {
        var moved = research()
        moved[2].path = "research/research_assets/gorge-2.jpg"
        XCTAssertNotEqual(CanvasItemIndex.over(research: research()).fingerprint,
                          CanvasItemIndex.over(research: moved).fingerprint,
                          "the thumbnail path is not in the fingerprint's join, so a "
                          + "card keeps drawing the photograph that used to be at it")
        XCTAssertEqual(CanvasItemFacts
            .resolve(.project(id: "res-photo"),
                     in: CanvasItemIndex.over(research: moved)).thumbnailPath,
                       "research/research_assets/gorge-2.jpg")
    }

    /// **Every glyph name has to be a symbol that exists**, and nothing else in
    /// the tree can see that it does *(Task 5's review, M3)*. `drawItemContent`
    /// resolves `Image(systemName:)` per card; a typo draws **nothing at all**
    /// on that one kind, on that one card kind only, and the raster fixtures
    /// exercise two of the eight names. `CanvasItemKind` is `CaseIterable`
    /// precisely so this can walk it rather than list them here — a written-down
    /// list would go stale on the next case, which is the failure this whole
    /// slice kept meeting in prose.
    ///
    /// `missingGlyph` is checked beside them because it is not a case: it is a
    /// `static let` deliberately kept off the enum, so `allCases` cannot reach it
    /// and it is exactly as typo-able.
    func test_everyKindGlyphIsARealSymbol() {
        for kind in CanvasItemKind.allCases {
            XCTAssertNotNil(
                NSImage(systemSymbolName: kind.glyph, accessibilityDescription: nil),
                "`\(kind.rawValue)` names the SF Symbol \"\(kind.glyph)\", which does "
                + "not exist — an item card of this kind draws no glyph at all, and "
                + "only a raster fixture for this exact kind would have seen it")
        }
        XCTAssertNotNil(
            NSImage(systemSymbolName: CanvasItemKind.missingGlyph,
                    accessibilityDescription: nil),
            "`missingGlyph` names a symbol that does not exist, so a card pointing "
            + "at a deleted research item draws its sentence with nothing beside it")
    }
}
