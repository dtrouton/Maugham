import SwiftUI

/// Whose hand made a thing on the canvas, in the inspector — **the one
/// implementation both arms are handed** (spec §8A.2, 1C-c3).
///
/// **It began as `ScrapInspector.Origin` and only cards had it.** A card and a
/// region are both drawn straight when Claude made them, both announced with
/// `CanvasAccessibility.claudeTerm`, and both inspectable in a pane — and for one
/// round only the card's pane said so, which is CLAUDE.md rule 8 failing for the
/// other half of exactly the same field. `PromotedArtifactSection`'s doc comment
/// records the previous slice's version of this defect and the ruling it produced:
/// the fix is one implementation both arms are handed, never a second copy. That
/// is what this file is; a parallel resolver on the region arm would be a second
/// spelling of the wording *and* of the one-source rule below.
///
/// **It is not `PromotedArtifactSection`, and must not move inside it.** A thing
/// being Claude's is an ATTRIBUTE, not an event: under a promotion heading the
/// sentence starts reading as a mark, and a mark is what
/// `Promotion.existingArtifact` reads to offer **Rewrite**. Both arms render this
/// beside the thing's own name instead — the card's words, the region's label.
enum CanvasAuthorLine: Equatable {
    /// `author` is nil, which **means the writer** (`CanvasNode.author`). The pane
    /// says nothing at all: a line reading "made by you" is chrome stating the
    /// default, on every card and every region on every canvas made before 1C-c3.
    case writer
    /// Claude's, with no source page the canvas can name.
    case claude
    /// Claude's, off a research item the region still holds.
    case claudeReadFrom(title: String)

    /// Nil is not an empty string: it is the difference between a thing with
    /// nothing to declare and a row rendering as blank space.
    ///
    /// **One wording for one fact.** "from Claude" is
    /// `CanvasAccessibility.claudeTerm`, the region a batch lands in is
    /// `CanvasClaudePlacement.defaultRegionLabel` ("From Claude") and the undo step
    /// is `CanvasClaudeWrite.undoStepName` ("Add Scraps from Claude") — so this
    /// reuses those words rather than coining a fifth phrasing, and it is one
    /// sentence for both subjects rather than a sixth for the region. The second
    /// sentence names the page; two sentences rather than one clause because the
    /// source is a separate fact and plenty of these have none.
    var sentence: String? {
        switch self {
        case .writer: return nil
        case .claude: return "From Claude."
        case .claudeReadFrom(let title):
            return "From Claude. Read from “\(title)”."
        }
    }

    // MARK: - Resolving it

    /// A card: **`author == .claude`, the predicate `CanvasRenderer.paper(for:)`
    /// and `CanvasAccessibility` already use** — not `author != nil`, so a card
    /// explicitly marked `.human` reads as the writer's rather than as a third
    /// state this pane would have to invent a sentence for.
    ///
    /// The source page is the card's HOME region's, because that is where
    /// `CanvasClaudePlacement` puts it. A card cited in a Claude region inherits
    /// nothing — §4.3's rule, the same one `Promotion.piece` follows.
    static func forCard(_ nodeID: CanvasNodeID, in scene: CanvasScene,
                        title: (String) -> String?) -> CanvasAuthorLine {
        guard scene.node(nodeID)?.author == .claude else { return .writer }
        guard let homeID = CanvasMembership.homeRegion(of: nodeID, in: scene),
              let home = scene.region(homeID) else { return .claude }
        return read(from: home, in: scene, title: title)
    }

    /// A region: the same author predicate on `CanvasRegion.author`, and its own
    /// members for the source. A region carries no tint at all — no paper, no ink
    /// of its own — so its 1° lean is the whole of its drawn provenance, and a lean
    /// is not something a pane can show.
    static func forRegion(_ regionID: CanvasRegionID, in scene: CanvasScene,
                          title: (String) -> String?) -> CanvasAuthorLine {
        guard let region = scene.region(regionID),
              region.author == .claude else { return .writer }
        return read(from: region, in: scene, title: title)
    }

    /// **The source is the region's item member, and the region records no
    /// "source" role.** `CanvasClaudePlacement` puts the page Claude read in the
    /// same region as the cards — created and homed there, adopted if it was
    /// already loose, or cited if the writer had already given it a home — so all
    /// three cases are found by asking which of the region's members is an item
    /// node. It is read from the MEMBERSHIP rather than from a field because there
    /// is no field: a page-to-cards relationship is not in the data model, and
    /// inventing one for a sentence would be a schema change for a caption.
    ///
    /// **Exactly one, or the line says nothing** — which is the shape the planner
    /// produces (a call carries at most one `source_item_id`) and the reason this
    /// does not need to pick. With two item members in the region there is no fact
    /// here to state: a writer who later drops a second research item into
    /// Claude's region would otherwise have this name whichever one sorted first,
    /// which is a caption asserting something nothing in the model knows. Silence
    /// is right for that case, and it removes the misattribution rather than
    /// documenting it.
    ///
    /// **The title is the deferred lookup both panes already hold** — the same one
    /// the promoted mark and the contribution record resolve through, so a page the
    /// writer has since deleted falls back to the plain sentence instead of
    /// printing an id. A `store` is never read from a `body` or from anything a
    /// `body` calls.
    private static func read(from region: CanvasRegion, in scene: CanvasScene,
                             title: (String) -> String?) -> CanvasAuthorLine {
        let sources = region.homeMembers.union(region.appearances)
            .compactMap { member -> String? in
                guard case .item(let reference) = scene.node(member)?.kind else {
                    return nil
                }
                return reference
            }
        guard sources.count == 1, let resolved = title(sources[0]) else { return .claude }
        return .claudeReadFrom(title: resolved)
    }
}

/// The one row both inspector arms render for it, so the two cannot drift into
/// styling one fact two ways — `PromotedArtifactSection` is the precedent for
/// sharing the rendering as well as the decision.
///
/// It renders nothing for the writer's own things. Which arm of a
/// `_ConditionalContent` renders cannot be asserted and a `Form`'s contents are
/// not inspectable, which is why the decision is `CanvasAuthorLine` — a value a
/// test can drive — rather than an `if` written twice inside two bodies.
struct CanvasAuthorLineRow: View {

    let line: CanvasAuthorLine

    var body: some View {
        if let sentence = line.sentence {
            Text(sentence)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
