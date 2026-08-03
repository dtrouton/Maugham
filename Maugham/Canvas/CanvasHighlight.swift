import Foundation

/// What the tree's subject lights on the canvas, and by omission what is dimmed
/// (spec §4).
///
/// **A resolved value, cached by `CanvasView` and handed to `CanvasRenderer` —
/// never derived inside a draw.** It is scene-proportional in both halves: the
/// projection walks every region and unions every region's `homeMembers`, and
/// the region half walks the regions again. `CanvasView.body` runs on every
/// scroll event, every drag frame and every momentum tick, so deriving this
/// there is tripwire 30 exactly — the same defect the accessibility tree once
/// shipped, which sorted the scene and copied every scrap's string at 60–120 Hz.
/// `CanvasAccessibility`'s cached element list is the precedent to read.
///
/// **Every question it answers is a set membership**, which is what makes it
/// safe to ask per node, per region and per line inside the draw. Nothing here
/// is computed at draw time.
struct CanvasHighlight: Equatable {

    /// §4 row one: nothing is dimmed because nothing is filtered.
    ///
    /// **Not "the lit set is empty"** — that is a chapter with nothing bound,
    /// which dims the whole board. The two states have to be distinguishable or
    /// the project row and an unbound chapter would look identical.
    static let undimmed = CanvasHighlight(isFiltering: false,
                                          nodes: [], regions: [], lines: [])

    /// Whether anything is dimmed at all. When false every `isDimmed` answer is
    /// false regardless of the sets, which is what keeps the undimmed board free
    /// of any lookup that could be wrong.
    let isFiltering: Bool

    /// The lit cards — `RegionBinding.references(forPiece:in:)`, unioned over
    /// every piece the subject names.
    let nodes: Set<CanvasNodeID>

    /// The lit regions. **The projection does not give you these**: it dissolves
    /// the regions away and returns a flat card set, so §4's *"its bound regions
    /// **and** their resident cards lit"* needs this second derivation. It is the
    /// only place outside `RegionBinding` that reads `boundPieceID` to decide
    /// what a piece owns, and it is deliberately the *same* predicate the
    /// projection filters on — if that ever stops being true, the regions drawn
    /// lit and the cards drawn lit are answering two different questions.
    let regions: Set<CanvasRegionID>

    /// The lit lines: a line is lit when **both** of its endpoints are. §4 dims
    /// "everything else", and a line is not in the projection — but a dimmed
    /// line between two lit cards would cut the lit cluster into pieces, which
    /// says the opposite of what lighting it said. A line with one end outside
    /// the piece's context is dimmed, because it leads somewhere the subject
    /// does not name.
    let lines: Set<CanvasLineID>

    func isDimmed(node: CanvasNodeID) -> Bool { isFiltering && !nodes.contains(node) }
    func isDimmed(region: CanvasRegionID) -> Bool { isFiltering && !regions.contains(region) }
    func isDimmed(line: CanvasLineID) -> Bool { isFiltering && !lines.contains(line) }

    /// The subject names something, and nothing on the canvas answers to it —
    /// §4's third row, the state that offers the next move.
    ///
    /// **Regions as well as cards**, because a bound region that is empty (or
    /// collapsed, or holds only visitors) is still something the tree's subject
    /// owns on this canvas, and offering to bind a fresh region while one is
    /// already bound and lit would be the offer contradicting the board.
    var litNothing: Bool { isFiltering && nodes.isEmpty && regions.isEmpty }

    /// The whole derivation, run once per structural change and once per tree
    /// click — never per frame.
    ///
    /// **It CALLS the projection rather than re-deriving its two rules**
    /// (residents only, unioned across regions). Re-spelling them here is
    /// tripwire 19's mistake one layer down, and the failure it produces is
    /// specific: `home ∪ appearances` lights a card that is merely *visiting* a
    /// bound region, so the writer is shown a card as part of a chapter's
    /// context that the reference rail will not carry. The cost of calling it
    /// per piece is one region walk per piece, which for a group is
    /// `O(documents × regions)` — accepted, because this is on the structural
    /// path beside an accessibility rebuild that already sorts the whole scene,
    /// and the alternative is a third spelling of the rule.
    static func resolve(subject: CanvasSubject, in scene: CanvasScene) -> CanvasHighlight {
        guard subject.dimsTheBoard else { return .undimmed }

        let pieces = Set(subject.pieces)
        var nodes: Set<CanvasNodeID> = []
        for piece in subject.pieces {
            nodes.formUnion(RegionBinding.references(forPiece: piece, in: scene))
        }

        // `unorderedRegions`, never `regions`: that accessor sorts the whole set
        // on every access.
        var regions: Set<CanvasRegionID> = []
        for region in scene.unorderedRegions {
            if let bound = region.boundPieceID, pieces.contains(bound) { regions.insert(region.id) }
        }

        // `scene.lines` sorts, and this is the one place that cost is accepted:
        // it is paid once per structural change rather than per frame, and there
        // is no unordered accessor to reach for. A line is looked at once here
        // so the draw never has to look one up.
        var lines: Set<CanvasLineID> = []
        for line in scene.lines where nodes.contains(line.from) && nodes.contains(line.to) {
            lines.insert(line.id)
        }

        return CanvasHighlight(isFiltering: true, nodes: nodes, regions: regions, lines: lines)
    }
}
