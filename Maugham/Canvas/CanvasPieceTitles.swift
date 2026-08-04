import Foundation
import MaughamCore

/// **Piece id → the title the binder shows, for every row in the project** —
/// and the one resolution of §4.2's question, *"whose is this rectangle?"*
///
/// **The canvas is handed the ANSWER, never the question** (§4.1's task-1
/// principle, and `CanvasSubject`'s own doc comment at length). The canvas holds
/// no manifest and must not start: this is built in `ProjectWindow` beside
/// `pieceChoices`, on a body that re-evaluates when the manifest changes and
/// never on the canvas's, which re-evaluates on every drag, coast and straighten
/// frame (tripwire 4). `CanvasItemIndex` is the shape this copies, down to the
/// fingerprint, and the two are separate because they are indexes over different
/// halves of the manifest — `research` and `structure`.
///
/// **Built over the WHOLE structure and never over the routable offer.**
/// `ProjectWindow.pieceChoices` narrows to `ProjectStore.researchScopeTargets()`,
/// correctly, for a picker whose every row must be a promotion destination. A
/// title lookup built from that narrowed list would call a Collection reference
/// piece — sitting in the writer's binder, in front of them — a missing one,
/// which is the exact defect `ScrapInspector.PieceAssociation.keepsNoResearch`
/// was minted to fix one surface over. Groups are collected too, for
/// `CanvasItemIndex.over`'s stated reason: `boundPieceID` should only ever hold a
/// document, and a sidecar that disagrees must not turn a row in the binder into
/// "Missing piece".
///
/// **It is the same table `RegionInspector` resolves its unofferable binding
/// through.** That pane asks `ScrapInspector.unoffered`, which is a function of
/// exactly this lookup and nothing else, so `ProjectWindow` hands it
/// `title(of:)` rather than a walk of its own — otherwise the pane and the
/// canvas hold two answers to "does this piece still exist" with nothing keeping
/// them together.
///
/// **What is NOT shared is `PieceAssociation.label`, and that is deliberate.**
/// Those strings are a Form row's: *"Chapter Three · keeps no research of its
/// own"* is a fact about where a **promotion** would land, and it is false by
/// irrelevance on a chrome bar — a region bound to a piece that keeps no
/// research binds and refuses sweeps exactly like any other, so drawing the
/// routing caveat would give the writer the wrong reason for the refusal.
/// *"Missing piece · gone-9"* keeps the id because the inspector's writer can
/// act on it; at 11 pt on a chrome bar it is a code nobody can read and nobody
/// can clear. One resolution, two voices.
struct CanvasPieceTitles: Equatable, Sendable {

    /// What a region bound to a piece the project no longer holds says.
    ///
    /// **Not silence, and this is the case §4.2 turns on.** A region bound to a
    /// since-deleted chapter still refuses the sweep — `boundPieceID` is
    /// non-nil, and the never-re-bind rule looks no further — so a label that
    /// went quiet here would be lying in the one case it matters most. It is the
    /// inspector's own noun phrase minus the id, so the two surfaces name the
    /// state with the same words and the pane adds what only it can act on.
    static let missingPieceName = "Missing piece"

    private let titlesByID: [String: String]

    /// The cache key for anything that holds a resolved answer from this table —
    /// `CanvasItemIndex.fingerprint`'s reasoning applies whole and is not
    /// repeated here, including why it is `StableHash.fnv1a64Hex` over sorted
    /// entries rather than `hashValue` over a dictionary.
    ///
    /// **What it buys here is tripwire 22's rule applied to a name.** The DRAWN
    /// label follows a rename for free, because this is a property of
    /// `CanvasView` and a new value re-runs its body. The SPOKEN one does not:
    /// `CanvasAccessibility`'s element list is cached in `@State` against the
    /// structural counter, and renaming a chapter moves nothing on the canvas —
    /// so without a trigger keyed on this, a chapter renamed while the board is
    /// filtered is announced under its old title for the rest of the session.
    let fingerprint: String

    init(titlesByID: [String: String]) {
        self.titlesByID = titlesByID
        // Control characters, so no id or title can spell a separator and make
        // two different binders hash alike.
        self.fingerprint = StableHash.fnv1a64Hex(
            titlesByID.sorted { $0.key < $1.key }
                .map { "\($0.key)\u{1}\($0.value)" }
                .joined(separator: "\u{2}"))
    }

    /// No project behind it — what a canvas hosted without a window has, which is
    /// a real state and therefore a hazard: see `CanvasView.pieceTitles`.
    static let empty = CanvasPieceTitles(titlesByID: [:])

    /// One walk, and it is spelled exactly as `ProjectWindow.pieceTitle` spelled
    /// it before this type existed, so the pane's answer did not change when the
    /// canvas gained one.
    static func over(structure: [StructureItem]) -> CanvasPieceTitles {
        CanvasPieceTitles(titlesByID: Dictionary(
            TreeWalk.collect(in: structure, where: { _ in true }).map { ($0.id, $0.title) },
            uniquingKeysWith: { _, later in later }))
    }

    func title(of id: String) -> String? { titlesByID[id] }

    /// **§4.2's whole rule, in one place**: what a region says about a binding
    /// that is not the subject's — drawn on its chrome bar, spoken in its
    /// accessibility label, and `nil` when there is nothing to say.
    ///
    /// The rule that falls out of it is the one the writer relies on, so it is
    /// worth stating as the biconditional it is: **on a dimmed board, no name on
    /// a region means a sweep there will work.**
    ///
    /// - `isDimmed` is `CanvasHighlight.isDimmed(region:)`, which is already
    ///   false everywhere on an unfiltered board. **Only the regions bound
    ///   ELSEWHERE** (Denver, §4.2): a lit region is bound to the piece the tree
    ///   already names, so labelling it repeats the binder — and, worse, a name
    ///   that could appear on a lit region would stop meaning anything about the
    ///   gesture. On a filtered board `isDimmed && boundPieceID != nil` IS "bound
    ///   elsewhere", because `CanvasHighlight.resolve` lights every region bound
    ///   to a piece the subject names.
    /// - A binding the table cannot resolve is a deleted chapter, and it answers
    ///   `missingPieceName` rather than `nil` — see there.
    ///
    /// **Both consumers call this rather than re-deriving the predicate.** The
    /// drawn name and the spoken name disagreeing about one rectangle is the
    /// divergence this directory has two deliberate instances of, and both were
    /// decided rather than discovered.
    func boundElsewhere(_ region: CanvasRegion, isDimmed: Bool) -> String? {
        guard isDimmed, let piece = region.boundPieceID else { return nil }
        return title(of: piece) ?? Self.missingPieceName
    }
}
