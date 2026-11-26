import Foundation
import MaughamCore

/// **What the centre itself holds that has details**, shown in the pulled-up
/// position while nothing is pulled up (owner, 2026-11-18): the canvas's
/// selected card or region, a figure, a research item, a Collection
/// reference piece.
enum CentreDetails: Equatable {
    case canvas
    case figure(String)
    case research(String)
    case referencePiece(String)
}

/// The Book statements and the one History a key or a Brief link pulls up
/// (Tasks 5 and 9 wire them).
public enum PullUpRequest: String, CaseIterable, Sendable {
    case lessons, firstReader, visualLanguage, historyOfTheFaces
}

/// **What the right column shows: one exhaustive answer** (shell plan 3, "What
/// each right-column position shows"). Pure over the subject and the
/// remembered position; the column renders it with one `switch`.
enum RightColumnContent: Equatable {
    /// To resolve (`ResolvePane`) — an edition's included (shell p4 Task 6),
    /// and a piece read in a language, whose list is that language's (shell
    /// p4 Task 9: the reading language is the list's scope, never a pane of
    /// its own).
    case resolve
    case brief(BriefScope)
    /// The thing pulled up (`subject.beside`).
    case pulledUp(PulledUp)
    /// Nothing pulled up: the centre's own details.
    case centreDetails(CentreDetails)
    /// Nothing pulled up and nothing in the centre with details. The position
    /// is not offered while this is its answer (`offersPulledUp`).
    case nothingPulledUp

    static func of(position: RightColumnPosition, subject: WindowSubject,
                   structure: [StructureItem],
                   projectType: ProjectType) -> RightColumnContent {
        switch position {
        case .resolve:
            return .resolve
        case .brief:
            return .brief(BriefScope.of(subject.faces, structure: structure,
                                        projectType: projectType))
        case .pulledUp:
            if let beside = subject.beside { return .pulledUp(beside) }
            if let details = centreDetails(subject, structure: structure,
                                           projectType: projectType) {
                return .centreDetails(details)
            }
            return .nothingPulledUp
        }
    }

    /// **What the centre holds that has details**, from `open` and nothing
    /// else — the centre's own routing rules, asked rather than restated: the
    /// canvas, a figure or research item that takes the centre, a Collection's
    /// reference piece.
    static func centreDetails(_ subject: WindowSubject, structure: [StructureItem],
                              projectType: ProjectType) -> CentreDetails? {
        if subject.open == .canvas { return .canvas }
        if let id = subject.open.figureID { return .figure(id) }
        if let id = subject.open.researchID { return .research(id) }
        if let piece = ProjectWindow.referencePiece(for: subject.open, in: structure) {
            return .referencePiece(piece.id)
        }
        return nil
    }

    /// **The centre's details drawn above the pulled-up thing** (appraisal
    /// wave): with something pulled up and a figure, a research item or a
    /// Collection reference piece in the centre, the centre's own details
    /// stand above it as a section, so neither is out of reach. Nil with
    /// nothing pulled up (the details are the whole position, as before),
    /// with the canvas the centre (its own rule: a selection covers,
    /// `canvasDetailsCover`), and where what is pulled up IS the centre's item
    /// (its own view already draws those details — one mount). Pure.
    static func centreDetailsAbovePulledUp(_ subject: WindowSubject, structure: [StructureItem],
                                           projectType: ProjectType) -> CentreDetails? {
        guard let beside = subject.beside,
              let details = centreDetails(subject, structure: structure, projectType: projectType)
        else { return nil }
        switch details {
        case .canvas: return nil
        case .figure(let id): return beside == .figure(id) ? nil : details
        case .research(let id): return beside == .research(id) ? nil : details
        case .referencePiece: return details
        }
    }

    /// **Whether the canvas's details cover the pulled-up thing** (owner,
    /// 2026-11-20; narrowed by the ruling on review I1, 2026-11-21): with the
    /// canvas the centre and something pulled up, the position shows the
    /// canvas's selected card, region or line while there is one AND it was
    /// made after the last pull-up (`PulledUpMemory.canvasSelectionIsNewer`),
    /// so a pull-up made over a standing selection — a fold row, a key, Back —
    /// shows what was asked for, and the writer's next selection covers it
    /// again. Covering is drawing only: `subject.beside` is never touched, so
    /// the `.pulledUp(_)` answer above stands and the control keeps its title.
    /// Asked by `CanvasDetailsCover` (the drawing) and `PulledUpEscape` (an
    /// Escape over the cover is not the hidden thing's). Pure.
    static func canvasDetailsCover(canvasIsTheCentre: Bool, somethingIsPulledUp: Bool,
                                   canvasHasASelection: Bool,
                                   selectionIsNewerThanPullUp: Bool) -> Bool {
        canvasIsTheCentre && somethingIsPulledUp && canvasHasASelection && selectionIsNewerThanPullUp
    }

    /// Whether the pulled-up position is offered (hidden, never disabled,
    /// otherwise — Global Constraints).
    static func offersPulledUp(_ subject: WindowSubject, structure: [StructureItem],
                               projectType: ProjectType) -> Bool {
        of(position: .pulledUp, subject: subject,
           structure: structure, projectType: projectType) != .nothingPulledUp
    }

    /// **The position a subject change leaves the column on**, first matching
    /// rule:
    /// 1. something new pulled up, or what is already pulled up made the part
    ///    clicked last again ("show me this": a find result, a board chip, a
    ///    key on what is already there — `ClickRule.navigate`, `pullUp`) → the
    ///    pulled-up position (`ResearchRevealModifier.isAnArrival`'s rule);
    /// 2. the pulled-up position left with nothing to show (what was pulled up
    ///    put away with no centre details under it, or the centre moving off
    ///    its details) → `previousFace`, the face before it;
    /// 3. the faces moving onto the canvas (whose details the position shows)
    ///    → the pulled-up position;
    /// 4. otherwise unchanged.
    ///
    /// Replaces `revealResearchColumn`'s segment write and plan 1's "leaving an
    /// edition takes the desk" rule: an edition's To resolve is To resolve's
    /// own list (shell p4 Task 6), so there is nothing left to coerce.
    static func positionAfterSubjectChange(_ position: RightColumnPosition,
                                           from old: WindowSubject, to new: WindowSubject,
                                           previousFace: RightColumnPosition,
                                           structure: [StructureItem],
                                           projectType: ProjectType) -> RightColumnPosition {
        if let beside = new.beside,
           beside != old.beside || (new.besideIsLatest && !old.besideIsLatest) {
            return .pulledUp
        }
        if position == .pulledUp,
           !offersPulledUp(new, structure: structure, projectType: projectType) {
            return previousFace == .pulledUp ? .resolve : previousFace
        }
        if new.faces == .canvas, old.faces != .canvas,
           centreDetails(new, structure: structure, projectType: projectType) != nil {
            return .pulledUp
        }
        return position
    }

    /// What a key or a Brief link pulls up. History is of the faces' piece,
    /// else of the open piece, else the PROJECT's — its checkpoints, what the
    /// old History pane showed on the Book (owner's ruling, Task 9 fix 1).
    ///
    /// Takes `structure`, which the brief's signature did not: a Part in the
    /// faces is not a piece, and its History is not a thing.
    ///
    /// `piece` names the piece a History is of (a tree row's History, appraisal
    /// 6): that piece's, ahead of the faces, where it is a piece; ignored by
    /// every other request.
    static func pulledUp(for request: PullUpRequest, subject: WindowSubject,
                         structure: [StructureItem], piece: String? = nil) -> PulledUp {
        switch request {
        case .lessons: return .lessons
        case .firstReader: return .firstReader
        case .visualLanguage: return .visualLanguage
        case .historyOfTheFaces:
            if let piece, ClickRule.isPiece(piece, in: structure) { return .history(docId: piece) }
            return facesPiece(subject, structure: structure).map { .history(docId: $0) }
                ?? .projectHistory
        }
    }

    /// The faces' piece, else the open one; nil where neither is a piece (a
    /// Part, the Book, the canvas with nothing faced). History's piece and
    /// the one ⌘⌥E opens the fold of.
    static func facesPiece(_ subject: WindowSubject, structure: [StructureItem]) -> String? {
        for part in [subject.faces, subject.open] {
            if case .item(let id) = part, ClickRule.isPiece(id, in: structure) { return id }
        }
        return nil
    }

    /// **A click on the line above the prose** (`IntentStrip`): the line is
    /// about `open`, so the faces go to the open piece and Brief shows it.
    /// Anything else open moves nothing.
    static func facesForTheStrip(_ subject: WindowSubject,
                                 structure: [StructureItem]) -> WindowSubject {
        guard case .item(let id) = subject.open, ClickRule.isPiece(id, in: structure),
              subject.faces != subject.open else { return subject }
        var next = subject
        next.faces = subject.open
        return next
    }
}
