import Foundation
import MaughamCore

/// **What the window's centre column shows: one exhaustive answer**
/// (foundations plan 4, Task 3).
///
/// Before this type two mechanisms decided the centre, and neither checked it
/// covered every case: an if/else chain in `editorPane` (palette wall, research,
/// canvas, reference, editor) and independent `if` layers inside the editor
/// arm's `ZStack` (altitude, Review's board, then the publish switch), where
/// which surface the writer saw was decided by layer ORDER. Now
/// `ProjectWindow.centreRoute(…)` answers the whole question once, as a value,
/// and the window renders it with one `switch`.
///
/// **The cases are in the old chain's order, and the order is load-bearing for
/// view identity**: SwiftUI builds a `switch` as nested conditional content in
/// case order, so the canvas stays the third branch it always was — ONE mount
/// (tripwire 27/30) — and every overlay change happens INSIDE `.editor`, whose
/// associated value is not part of the branch's identity. That is what keeps
/// `EditorHost` mounted across a project ↔ chapter hop (tripwire 6).
enum CentreRoute: Equatable {
    /// The palette wall, deliberately entered, over everything else.
    case paletteWall
    /// A research item that takes the centre (`researchSubjectPlacement`).
    case research(id: String)
    /// The planning canvas — mounted once, in a branch of its own.
    case canvas
    /// A Collection's placeholder for a linked-project reference piece.
    case reference(piece: StructureItem)
    /// The manuscript editor, with at most ONE surface drawn over it.
    case editor(overlay: CentreOverlay?)
}

/// **The one surface drawn over the editor**, or none. The editor stays mounted
/// beneath every one of them; only this value changes.
///
/// Each case is opaque and fills the column, so exactly one is ever drawn —
/// where the old stack layered the board or the book OVER a still-mounted
/// corkboard, the winner is now chosen here rather than by z-order.
enum CentreOverlay: Equatable {
    /// The project at altitude (stage 3a) — and, in Publish with no book to
    /// show, the banner saying WHICH kind of nothing it is. The notice is not an
    /// overlay of its own: it is translucent, takes no clicks, and exists only
    /// to explain the corkboard under it (`PublishCentreNoticeBanner`), and
    /// `publishCentre` only ever answers `.notice` where altitude is already
    /// true. Carrying it here makes "a notice over nothing" unrepresentable and
    /// keeps the corkboard's identity when a notice comes or goes.
    case altitude(notice: PublishCentreNotice?)
    /// Review's passes board (M3 P1 Task 6).
    case reviewBoard
    /// The compiled book, newest first (stage 3b Task 5).
    case books([Publication])
    /// The design gate over a proposal the writer pressed Show on (P4 Task 5).
    case designGate(DesignProposalStore.Proposal)
    /// A translation round's report — the one overlay that also draws over a
    /// chapter (Denver's 2026-09-02 ruling).
    case translationRound(TranslationRound)
}

extension ProjectWindow {

    /// **The centre column's route, composed from the window's existing
    /// decisions — none of them restated.**
    ///
    /// The precedence is the old chain's, then the old stack's top layer:
    /// the palette wall (`showsPaletteWallCentre`), a research subject that
    /// takes the centre (`researchSubjectPlacement`), the canvas and the
    /// Collection reference (`editorRoute`), and otherwise the editor with the
    /// surface that USED to be the top of its stack: Publish's
    /// (`publishCentre`), else Review's board (`reviewCentreShowsBoard`), else
    /// altitude (`subjectShowsAltitude`). The board and Publish's surface are
    /// never both offered (each predicate is true of one persona), which
    /// `CentreRouteTests` asserts over the whole product rather than leaving to
    /// this comment.
    static func centreRoute(persona: Persona,
                            subject: BinderSubject?,
                            projectType: ProjectType,
                            structure: [StructureItem],
                            showsPaletteWall: Bool,
                            preview: PublishPreviewResolution,
                            proposal: DesignProposalStore.Proposal? = nil,
                            round: TranslationRound? = nil) -> CentreRoute {
        if showsPaletteWallCentre(showsPaletteWall: showsPaletteWall, persona: persona) {
            return .paletteWall
        }
        if let id = researchSubjectPlacement(persona: persona, subject: subject).centreItemID {
            return .research(id: id)
        }
        let piece = referencePiece(for: subject, in: structure)
        switch editorRoute(persona: persona, projectType: projectType,
                           selectedPieceIsReference: piece != nil) {
        case .canvas:
            return .canvas
        case .collectionReference:
            // `selectedPieceIsReference` was `piece != nil`, so the piece is in
            // hand; the `if` only spares a force-unwrap.
            if let piece { return .reference(piece: piece) }
        case .editor:
            break
        }
        // The editor's one overlay: the surface that was the TOP of the old
        // stack. Publish's answer first (it was the last layer), then the
        // board, then altitude; a `.notice` folds into altitude, which it only
        // ever stood over.
        switch publishCentre(persona: persona, subject: subject, structure: structure,
                             preview: preview, proposal: proposal, round: round) {
        case .translationRound(let round): return .editor(overlay: .translationRound(round))
        case .designProposal(let proposal): return .editor(overlay: .designGate(proposal))
        case .books(let publications): return .editor(overlay: .books(publications))
        case .notice(let notice): return .editor(overlay: .altitude(notice: notice))
        case .none: break
        }
        if reviewCentreShowsBoard(persona: persona, subject: subject, structure: structure) {
            return .editor(overlay: .reviewBoard)
        }
        if subjectShowsAltitude(persona: persona, subject: subject, structure: structure) {
            return .editor(overlay: .altitude(notice: nil))
        }
        return .editor(overlay: nil)
    }

    /// The selected piece when it is a Collection's reference piece. A
    /// top-level lookup, as the window's always was: a Collection's pieces are
    /// its manifest's top level.
    static func referencePiece(for subject: BinderSubject?,
                               in structure: [StructureItem]) -> StructureItem? {
        guard let id = subject?.itemID,
              let piece = structure.first(where: { $0.id == id }),
              piece.pieceKind == .reference
        else { return nil }
        return piece
    }
}
