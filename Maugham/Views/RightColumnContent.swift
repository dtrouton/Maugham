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
/// each right-column position shows"). Pure over the subject, the remembered
/// position and translation review; the column renders it with one `switch`.
enum RightColumnContent: Equatable {
    /// To resolve (`ResolvePane`).
    case resolve
    /// To resolve while translation review is on over the faces' open piece
    /// (`TranslationReviewPane`, interim until plan 4).
    case translationReview
    /// To resolve while an edition is the faces (`DepartmentPaneHost`,
    /// interim until plan 4).
    case desk(language: String)
    case brief(BriefScope)
    /// The thing pulled up (`subject.beside`).
    case pulledUp(PulledUp)
    /// Nothing pulled up: the centre's own details.
    case centreDetails(CentreDetails)
    /// Nothing pulled up and nothing in the centre with details. The position
    /// is not offered while this is its answer (`offersPulledUp`).
    case nothingPulledUp

    static func of(position: RightColumnPosition, subject: WindowSubject,
                   translationLanguage: String?, structure: [StructureItem],
                   projectType: ProjectType) -> RightColumnContent {
        switch position {
        case .resolve:
            if translationLanguage != nil, subject.faces == subject.open,
               case .item(let id) = subject.open, ClickRule.isPiece(id, in: structure) {
                return .translationReview
            }
            if case .edition(let language) = subject.faces {
                return .desk(language: language)
            }
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

    /// Whether the pulled-up position is offered (hidden, never disabled,
    /// otherwise — Global Constraints).
    static func offersPulledUp(_ subject: WindowSubject, structure: [StructureItem],
                               projectType: ProjectType) -> Bool {
        of(position: .pulledUp, subject: subject, translationLanguage: nil,
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
    /// edition takes the desk" rule: the desk is To resolve's own answer while
    /// an edition is the faces, so there is nothing left to coerce.
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
    /// else of the open piece, else nil (the key is then inert).
    ///
    /// Takes `structure`, which the brief's signature did not: a Part in the
    /// faces is not a piece, and its History is not a thing.
    static func pulledUp(for request: PullUpRequest, subject: WindowSubject,
                         structure: [StructureItem]) -> PulledUp? {
        switch request {
        case .lessons: return .lessons
        case .firstReader: return .firstReader
        case .visualLanguage: return .visualLanguage
        case .historyOfTheFaces:
            for part in [subject.faces, subject.open] {
                if case .item(let id) = part, ClickRule.isPiece(id, in: structure) {
                    return .history(docId: id)
                }
            }
            return nil
        }
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
