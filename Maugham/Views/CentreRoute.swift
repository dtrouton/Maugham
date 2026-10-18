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
/// and the window renders it with one `switch` per level.
///
/// **The cases are in the old chain's order, and the order is load-bearing for
/// view identity**: SwiftUI builds a `switch` as nested conditional content in
/// case order, so the canvas stays the third branch it always was — ONE mount
/// (tripwires 27/30) — and every altitude or cover change happens INSIDE
/// `.editor`, whose associated values are not part of the branch's identity.
/// That is what keeps `EditorHost` mounted across a project ↔ chapter hop
/// (tripwire 6).
enum CentreRoute: Equatable {
    /// The palette wall, deliberately entered, over everything else.
    case paletteWall
    /// A research item that takes the centre (`researchSubjectPlacement`).
    case research(id: String)
    /// The planning canvas — mounted once, in a branch of its own.
    case canvas
    /// A Collection's placeholder for a linked-project reference piece.
    case reference(piece: StructureItem)
    /// The manuscript editor; over it, the project at altitude when the subject
    /// names no document (`subjectShowsAltitude`); over both, at most one
    /// cover.
    ///
    /// **Altitude is its own layer rather than a cover**, because the old stack
    /// kept it mounted beneath the board, the book, the gate and the round, and
    /// what it holds survives that way: `OutlineTable`'s writers (a verified
    /// registry read on `.task`), its scroll position and its column widths.
    /// A cover coming or going must not remount it.
    case editor(altitude: Bool, cover: CentreCover?)
}

/// **The one surface drawn over the editor and altitude**, or none — the top
/// layer of the old stack, chosen here rather than by z-order. Every case but
/// `.notice` is opaque and fills the column.
enum CentreCover: Equatable {
    /// Publish with no book: a banner saying WHICH kind of nothing it is,
    /// standing over the corkboard and taking no clicks. Only ever offered
    /// where altitude is true (`publishCentre` guards on it).
    case notice(PublishCentreNotice)
    /// Review's passes board (M3 P1 Task 6).
    case reviewBoard
    /// The compiled book, newest first (stage 3b Task 5).
    case books([Publication])
    /// The design gate over a proposal the writer pressed Show on (P4 Task 5).
    case designGate(DesignProposalStore.Proposal)
    /// A translation round's report — the one cover that also draws over a
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
    /// Collection reference (`editorRoute`), and otherwise the editor, with
    /// altitude beneath (`subjectShowsAltitude`) and the cover that USED to be
    /// the top of its stack: Publish's (`publishCentre`), else Review's board
    /// (`reviewCentreShowsBoard`). The board and Publish's surface are
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
        // The editor's layers: altitude where the subject names no document,
        // and the cover that was the TOP of the old stack — Publish's answer
        // first (it was the last layer), then the board.
        let altitude = subjectShowsAltitude(persona: persona, subject: subject,
                                            structure: structure)
        let cover: CentreCover?
        switch publishCentre(persona: persona, subject: subject, structure: structure,
                             preview: preview, proposal: proposal, round: round) {
        case .translationRound(let round): cover = .translationRound(round)
        case .designProposal(let proposal): cover = .designGate(proposal)
        case .books(let publications): cover = .books(publications)
        case .notice(let notice): cover = .notice(notice)
        case .none:
            cover = reviewCentreShowsBoard(persona: persona, subject: subject,
                                           structure: structure) ? .reviewBoard : nil
        }
        return .editor(altitude: altitude, cover: cover)
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
