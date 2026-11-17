import Foundation
import MaughamCore

/// **What the window's centre column shows: one exhaustive answer.**
/// `ProjectWindow.centreRoute(…)` answers the whole question once, as a
/// value, and `CentreColumn` renders it with one `switch` per level — never
/// by layer ORDER.
///
/// **The case order is load-bearing for view identity**: SwiftUI builds a
/// `switch` as nested conditional content in case order, so the canvas stays
/// the fourth branch — ONE mount (tripwires 27/30) — and every altitude or
/// cover change happens INSIDE `.editor`, whose associated values are not
/// part of the branch's identity. That is what keeps `EditorHost` mounted
/// across a project ↔ chapter hop (tripwire 6).
enum CentreRoute: Equatable {
    /// The palette wall: the subject's `open` is `.palette`.
    case paletteWall
    /// A research item that takes the centre (`researchSubjectPlacement`).
    case research(id: String)
    /// A figure that takes the centre (`figureSubjectPlacement`).
    case figure(id: String)
    /// The planning canvas — mounted once, in a branch of its own.
    case canvas
    /// A Collection's placeholder for a linked-project reference piece.
    case reference(piece: StructureItem)
    /// The manuscript editor; over it, the Book (or a Part, or an edition's
    /// book) in one of its views when `open` names no document
    /// (`altitudeView`); over both, at most one cover.
    ///
    /// **Altitude is its own layer rather than a cover**, so what it holds
    /// survives a cover coming or going: `OutlineTable`'s writers (a verified
    /// registry read on `.task`), its scroll position and its column widths.
    /// **Which view it shows is an associated value, never a branch**: Cards,
    /// Outline and Status are one layer, so switching between them never
    /// remounts `EditorHost`.
    case editor(altitude: BookView?, cover: CentreCover?)
    /// The Inbox's captures. Last, so adding it moved no other branch.
    case inbox
}

/// **The one surface drawn over the editor and altitude**, or none — chosen
/// here rather than by z-order. Every case but `.notice` is opaque and fills
/// the column. Every case belongs to an edition: Status is a view of the Book,
/// never a cover.
enum CentreCover: Equatable {
    /// An edition with no book: a banner saying WHICH kind of nothing it is,
    /// standing over the Book's view and taking no clicks.
    case notice(PublishCentreNotice)
    /// The compiled book, newest first.
    case books([Publication])
    /// The design gate over a proposal the writer pressed Show on.
    case designGate(DesignProposalStore.Proposal)
    /// A translation round's report — the one cover that also draws over a
    /// chapter (Denver's 2026-09-02 ruling).
    case translationRound(TranslationRound)
    /// The desk's publish problems — over a chapter too, as the round is.
    case publishProblems([TectonicLogParser.Diagnostic])
}

extension ProjectWindow {

    /// **The centre column's route, asked of the window's subject — one
    /// answer, composed from named decisions, none of them restated.**
    ///
    /// The precedence: the palette wall (`open == .palette`), a research item or
    /// a figure that takes the centre (`researchSubjectPlacement`,
    /// `figureSubjectPlacement`), the Inbox, the canvas and the Collection
    /// reference (`editorRoute`), and otherwise the editor, with the Book's view
    /// beneath where `open` names no document (`altitudeView`) and an edition's
    /// one cover (`publishCentre`). Status is a view and never a cover
    /// (`CentreRouteTests`).
    static func centreRoute(subject: WindowSubject, bookView: BookView,
                            projectType: ProjectType, structure: [StructureItem],
                            preview: PublishPreviewResolution,
                            proposal: DesignProposalStore.Proposal? = nil,
                            round: TranslationRound? = nil,
                            problems: [TectonicLogParser.Diagnostic]? = nil) -> CentreRoute {
        if showsPaletteWallCentre(subject: subject) {
            return .paletteWall
        }
        if let id = researchSubjectPlacement(subject: subject).centreItemID {
            return .research(id: id)
        }
        if let id = figureSubjectPlacement(subject: subject).centreFigureID {
            return .figure(id: id)
        }
        if subject.open == .inbox {
            return .inbox
        }
        let piece = referencePiece(for: subject.open, in: structure)
        switch editorRoute(subject: subject, projectType: projectType,
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
        let altitude = altitudeView(subject: subject, bookView: bookView,
                                    structure: structure)
        let cover: CentreCover?
        switch publishCentre(subject: subject, preview: preview, proposal: proposal,
                             round: round, problems: problems) {
        case .problems(let problems): cover = .publishProblems(problems)
        case .translationRound(let round): cover = .translationRound(round)
        case .designProposal(let proposal): cover = .designGate(proposal)
        case .books(let publications): cover = .books(publications)
        case .notice(let notice): cover = .notice(notice)
        case .none: cover = nil
        }
        return .editor(altitude: altitude, cover: cover)
    }

    /// The opened piece when it is a Collection's reference piece. A
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

extension BinderSubject {
    /// Whether this names an edition, whatever its language.
    var isEdition: Bool {
        if case .edition = self { return true }
        return false
    }
}
