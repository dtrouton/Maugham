import Foundation
import MaughamCore

/// **What the window's centre column shows: one exhaustive answer.**
/// `ProjectWindow.centreRoute(…)` answers the whole question once, as a
/// value, and `CentreColumn` renders it with one `switch` per level — never
/// by layer ORDER.
///
/// **The case order is load-bearing for view identity**: SwiftUI builds a
/// `switch` as nested conditional content in case order, so the canvas stays
/// the third branch — ONE mount (tripwires 27/30) — and every altitude or
/// cover change happens INSIDE `.editor`, whose associated values are not
/// part of the branch's identity. That is what keeps `EditorHost` mounted
/// across a project ↔ chapter hop (tripwire 6).
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
    /// **Altitude is its own layer rather than a cover**, so what it holds
    /// survives a cover coming or going: `OutlineTable`'s writers (a verified
    /// registry read on `.task`), its scroll position and its column widths.
    case editor(altitude: Bool, cover: CentreCover?)
}

/// **The one surface drawn over the editor and altitude**, or none — chosen
/// here rather than by z-order. Every case but `.notice` is opaque and fills
/// the column.
enum CentreCover: Equatable {
    /// Publish with no book: a banner saying WHICH kind of nothing it is,
    /// standing over the corkboard and taking no clicks. Only ever offered
    /// where altitude is true (`publishCentre` guards on it).
    case notice(PublishCentreNotice)
    /// Review's passes board.
    case reviewBoard
    /// The compiled book, newest first.
    case books([Publication])
    /// The design gate over a proposal the writer pressed Show on.
    case designGate(DesignProposalStore.Proposal)
    /// A translation round's report — the one cover that also draws over a
    /// chapter (Denver's 2026-09-02 ruling).
    case translationRound(TranslationRound)
}

extension ProjectWindow {

    /// **The centre column's route, composed from the window's existing
    /// decisions — none of them restated.**
    ///
    /// The precedence: the palette wall (`showsPaletteWallCentre`), a research
    /// subject that takes the centre (`researchSubjectPlacement`), the canvas
    /// and the Collection reference (`editorRoute`), and otherwise the editor,
    /// with altitude beneath (`subjectShowsAltitude`) and one cover: Publish's
    /// (`publishCentre`), else Review's board (`reviewCentreShowsBoard`). The
    /// board and Publish's surface are never both offered (each predicate is
    /// true of one persona), which `CentreRouteTests` asserts over the whole
    /// product.
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
        // and one cover — Publish's answer first, then the board.
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
    /// top-level lookup: a Collection's pieces are its manifest's top level.
    static func referencePiece(for subject: BinderSubject?,
                               in structure: [StructureItem]) -> StructureItem? {
        guard let id = subject?.itemID,
              let piece = structure.first(where: { $0.id == id }),
              piece.pieceKind == .reference
        else { return nil }
        return piece
    }
}
