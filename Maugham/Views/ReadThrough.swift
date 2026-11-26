import Foundation
import SwiftUI
import MaughamCore

/// **Read-through**: a piece its writer reads as a reviewer would — typing
/// off, every deliberate act (comment, suggest, answer, accept, reject,
/// resolve) on — entered and left by intent, remembered on this Mac
/// (`ReadThroughStore`), with a checkpoint on entry (`ReadThroughVerbs.start`).
///
/// Read-through only ever ADDS refusals: every site asks it beside the posture
/// and the share, never in their place, and no permission reads it.
enum ReadThrough {
    /// **The one predicate**: true only for a non-nil id in the set. Every
    /// surface — the gate, the offer, the editor — asks this.
    static func isOn(_ pieceId: String?, in pieces: Set<String>) -> Bool {
        guard let pieceId else { return false }
        return pieces.contains(pieceId)
    }

    /// The pieces that may be in read-through: the documents that load as a
    /// manuscript (`EditorHost.loadsAsAManuscript`). A deleted, trashed or
    /// promoted piece leaves this set; a renamed or moved one keeps its id.
    @MainActor
    static func eligibleIds(in structure: [StructureItem]) -> Set<String> {
        var ids: Set<String> = []
        func walk(_ items: [StructureItem]) {
            for item in items {
                if EditorHost.loadsAsAManuscript(item) { ids.insert(item.id) }
                if let children = item.children { walk(children) }
            }
        }
        walk(structure)
        return ids
    }

    /// What `prune` keeps, or nil while the manifest has not loaded — an
    /// absent structure is not an empty one, and pruning against it would
    /// forget every piece.
    @MainActor
    static func keeping(for structure: [StructureItem]?) -> Set<String>? {
        structure.map(eligibleIds(in:))
    }

    /// The checkpoint's name: "Read-through, 22 Nov — Chapter Three" — the day
    /// and abbreviated month in the writer's locale, and the piece's title so
    /// two chapters' read-throughs are told apart in History (owner's R3).
    static func checkpointLabel(at date: Date, title: String,
                                locale: Locale = .current) -> String {
        let day = date.formatted(
            Date.FormatStyle(locale: locale).day().month(.abbreviated))
        return "Read-through, \(day) — \(title)"
    }

    /// A request to start or resume one piece's read-through.
    struct Request: Equatable {
        let docId: String
        let on: Bool
    }

    static let docIdKey = "doc_id"
    static let onKey = "on"

    /// **The one sender** for every route (menu, key, padlock): the key
    /// window's `ReadThroughModifier` receives it.
    static func post(_ request: Request) {
        MaughamEvent.post(.maughamSetReadThrough, to: .keyWindow,
                          payload: [docIdKey: request.docId, onKey: request.on])
    }

    /// The request a post carried, or nil for a malformed one.
    static func request(of userInfo: [AnyHashable: Any]?) -> Request? {
        guard let docId = userInfo?[docIdKey] as? String,
              let on = userInfo?[onKey] as? Bool else { return nil }
        return Request(docId: docId, on: on)
    }
}

/// What a read-through may be asked about: a piece, a research item, a figure.
enum ReadThroughTarget: Equatable {
    case piece(String)
    case research(String)
    case figure(String)
}

/// **Whether a target refuses edits because its piece is in read-through** —
/// the value every non-editor surface asks, built once per change by the
/// window (`ReadThroughModifier.gate`) and handed to the session's figure
/// windows (`FigureWindows.setReadThrough`). A piece owns itself; **a research
/// item belongs to every piece whose fold draws it** (`ResearchHomes`): the
/// Collection piece whose folder holds it, and — since shell p5 Task 4a,
/// confirmed by the owner 2026-11-25 (ADR 0039 §2) — every chapter that links it, or
/// links the group it is in. Refused while ANY of them is in read-through
/// (the union rule figures use). The book's research and a book-wide figure
/// no line places belong to no piece and are refused by nothing.
///
/// **A figure's pieces — the one rule, asked everywhere** (the centre's grid,
/// a figure window, an editor's grid in place, the inspector, the tree's row,
/// what is pulled up): the piece it was made in (`FigureRecord.piece`, the
/// permit's owner) AND every piece whose text holds one of its lines
/// (`FigureListing.Row.usedIn`). Read-through only adds refusals, so a figure
/// whose line moved to another piece is refused while EITHER is in
/// read-through — never editable in one surface and read-only in the next.
struct ReadThroughGate: Equatable {
    let pieces: Set<String>
    private let researchOwners: [String: Set<String>]
    private let figureOwners: [String: Set<String>]
    /// Each loose piece's research folder prefix → its id: the research rule
    /// (`owner(ofResearchPath:)`), asked of a root path here and of a file's
    /// path by Find & Replace.
    private let researchFolders: [(prefix: String, pieceId: String)]
    /// The pieces in read-through, in tree order, with their titles: what a
    /// refusal names (`refusal(_:)`).
    private let order: [String]
    private let titles: [String: String]

    /// The empty gate: refuses nothing.
    static let writing = ReadThroughGate(
        pieces: [], structure: [], research: [], projectType: .novel, figures: [], figureLines: [])

    /// Builds the owner maps only when some piece is in read-through — the
    /// common case asks nothing of the structure. `figureLines` is the
    /// window's figure listing (`FigureListingModel.rows`).
    init(pieces: Set<String>, structure: [StructureItem], research: [ResearchItem],
         projectType: ProjectType, figures: [FigureRecord], figureLines: [FigureListing.Row]) {
        self.pieces = pieces
        guard !pieces.isEmpty else {
            researchOwners = [:]
            figureOwners = [:]
            researchFolders = []
            order = []
            titles = [:]
            return
        }
        var order_: [String] = []
        var titles_: [String: String] = [:]
        func walk(_ items: [StructureItem]) {
            for item in items {
                if pieces.contains(item.id) {
                    order_.append(item.id)
                    titles_[item.id] = item.title
                }
                walk(item.children ?? [])
            }
        }
        walk(structure)
        order = order_
        titles = titles_
        researchFolders = ProjectStore.researchFolders(in: structure)
        // Whose each item is — the tree's own answer (`ResearchHomes`), one
        // walk: its folder's piece and every piece linking it or its group.
        let homes = ResearchHomes.derive(structure: structure, research: research,
                                         projectType: projectType)
        var research_: [String: Set<String>] = [:]
        for item in TreeWalk.collect(in: research, where: { _ in true }) {
            let owners = homes.homes(of: item.id)
            if !owners.isEmpty { research_[item.id] = Set(owners) }
        }
        researchOwners = research_
        var figures_: [String: Set<String>] = [:]
        for figure in figures {
            if let piece = figure.piece { figures_[figure.id, default: []].insert(piece) }
        }
        for row in figureLines {
            for use in row.usedIn { figures_[row.figureId, default: []].insert(use.docId) }
        }
        figureOwners = figures_
    }

    private init(pieces: Set<String>, researchOwners: [String: Set<String>],
                 figureOwners: [String: Set<String>],
                 researchFolders: [(prefix: String, pieceId: String)],
                 order: [String], titles: [String: String]) {
        self.pieces = pieces
        self.researchOwners = researchOwners
        self.figureOwners = figureOwners
        self.researchFolders = researchFolders
        self.order = order
        self.titles = titles
    }

    /// **This gate with every other gate's owners added** — the session's one
    /// gate over several windows (`FigureWindows.setReadThrough(_:from:)`):
    /// the set, titles and order are this (the newest) gate's; a figure's
    /// line known to any window keeps its piece, so a window whose listing has
    /// not built yet can never unrefuse it. Only adds refusals.
    func addingOwners(of others: [ReadThroughGate]) -> ReadThroughGate {
        guard !pieces.isEmpty else { return self }
        var figures = figureOwners
        var research = researchOwners
        for other in others {
            for (id, owners) in other.figureOwners { figures[id, default: []].formUnion(owners) }
            for (id, owners) in other.researchOwners { research[id, default: []].formUnion(owners) }
        }
        return ReadThroughGate(pieces: pieces, researchOwners: research, figureOwners: figures,
                               researchFolders: researchFolders, order: order, titles: titles)
    }

    static func == (lhs: ReadThroughGate, rhs: ReadThroughGate) -> Bool {
        lhs.pieces == rhs.pieces && lhs.researchOwners == rhs.researchOwners
            && lhs.figureOwners == rhs.figureOwners && lhs.order == rhs.order && lhs.titles == rhs.titles
            && lhs.researchFolders.map(\.prefix) == rhs.researchFolders.map(\.prefix)
            && lhs.researchFolders.map(\.pieceId) == rhs.researchFolders.map(\.pieceId)
    }

    /// **The research rule**: a path inside a loose piece's own research
    /// folder belongs to that piece (`ProjectStore.pieceResearchPrefix`, as
    /// `researchScopePieceId` reads it); anything else is the book's.
    private static func owner(ofResearchPath path: String?,
                              in folders: [(prefix: String, pieceId: String)]) -> String? {
        guard let path else { return nil }
        return folders.first { path.hasPrefix($0.prefix) }?.pieceId
    }

    /// The pieces a target belongs to; empty for one that belongs to none.
    func owners(of target: ReadThroughTarget) -> Set<String> {
        switch target {
        case .piece(let id): return [id]
        case .research(let id): return researchOwners[id] ?? []
        case .figure(let id): return figureOwners[id] ?? []
        }
    }

    /// **The one answer**: true while any piece the target belongs to is in
    /// read-through.
    func refusesEdits(_ target: ReadThroughTarget) -> Bool {
        owners(of: target).contains { ReadThrough.isOn($0, in: pieces) }
    }

    /// **Why a target is refused, naming the piece** — the first of its
    /// pieces in read-through, in tree order, and how many more; nil where it
    /// is not refused. Every refusing surface says this, so a writer refused
    /// because of a piece they cannot see is told which, and how to resume.
    func refusal(_ target: ReadThroughTarget) -> ReadThroughRefusal? {
        refusal(among: owners(of: target))
    }

    /// The same, over a research FILE's path (Find & Replace's research arm),
    /// by the gate's own research rule.
    func refusal(researchPath path: String) -> ReadThroughRefusal? {
        refusal(among: Self.owner(ofResearchPath: path, in: researchFolders).map { [$0] } ?? [])
    }

    /// The refusal among `owners` — those in read-through, the first in tree
    /// order named (a piece the structure lost is named by its id, last).
    func refusal(among owners: Set<String>) -> ReadThroughRefusal? {
        let on = owners.filter { ReadThrough.isOn($0, in: pieces) }
        guard !on.isEmpty else { return nil }
        let first = order.first(where: on.contains) ?? on.sorted()[0]
        return ReadThroughRefusal(pieceId: first, title: titles[first] ?? first, others: on.count - 1)
    }
}

/// **Which piece's read-through refuses something** — named in every refusal
/// and on every research surface's line, with the piece Resume writing acts on.
struct ReadThroughRefusal: Equatable, Hashable {
    /// The first refusing piece, in tree order: what Resume writing resumes.
    let pieceId: String
    let title: String
    /// How many more of the target's pieces are in read-through.
    let others: Int

    /// "“Chapter Three”", or "“Chapter Three” and 2 more".
    var named: String {
        others == 0 ? "\u{201C}\(title)\u{201D}" : "\u{201C}\(title)\u{201D} and \(others) more"
    }

    /// "“Chapter Three” is in read-through" / "… and 2 more are in read-through".
    var sentence: String { "\(named) \(others == 0 ? "is" : "are") in read-through" }

    /// "“Chapter Three” is in read-through — resume writing it to change
    /// this figure." ("… and 2 more are … resume writing them …") — what a
    /// surface refused for it says, the pieces it names the ones to resume.
    func because(_ what: String) -> String {
        "\(sentence) \u{2014} resume writing \(others == 0 ? "it" : "them") to change \(what)."
    }

    /// Resume writing for the named piece — always allowed.
    var resumeOffer: ReadThroughOffer {
        var offer = ReadThroughOffer.on(docId: pieceId, lacksCheckpoint: false, mayTakeCheckpoint: false)
        offer.pieceTitle = title
        return offer
    }
}

/// **What the window offers for the open piece**: Start Read-through or Resume
/// Writing, enabled or not, and why not — and, for a piece in read-through
/// whose checkpoint was not saved, Save one. Pure, so every refusal is pinned
/// without a window. **Every route posts only what an offer gives it**
/// (`toggleRequest`, `resumeRequest`, `saveCheckpointRequest`): nothing
/// downstream asks again.
struct ReadThroughOffer: Equatable {
    let docId: String
    let isOn: Bool
    let isEnabled: Bool
    let reason: String?
    /// In read-through with no checkpoint saved and none being taken
    /// (`ReadThroughStore.piecesLackingCheckpoint`).
    var lacksCheckpoint: Bool = false
    /// **Save one is offered**: the checkpoint is missing AND a Start's
    /// checkpoint could land here — the posture allows `.checkpoint` and the
    /// share is writable. Elsewhere the line only says none was saved.
    var offersSaveOne: Bool = false
    /// The piece's title, where the offer is for a piece that is NOT the open
    /// one — a read-through piece's research is in front of the writer
    /// (`ReadThroughRefusal.resumeOffer`) — so the padlock names it.
    var pieceTitle: String? = nil

    static let postureRefusal =
        "This Mac may not change this piece’s text, so there is nothing to start."
    static let shareRefusal =
        "This piece is shared with you to view, so there is nothing to start."
    static let translationRefusal = "Read Source to start a read-through."
    static let hiddenTextRefusal = "Open the piece’s text to start a read-through."

    /// The View menu item's two titles.
    static let startTitle = "Start Read-through"
    static let resumeTitle = "Resume Writing"

    /// What the View menu item and the key say for this offer.
    var menuTitle: String { isOn ? Self.resumeTitle : Self.startTitle }

    /// What the menu item and the key post: Start or Resume, nil where the
    /// offer is disabled.
    var toggleRequest: ReadThrough.Request? {
        isEnabled ? ReadThrough.Request(docId: docId, on: !isOn) : nil
    }

    /// The line's Resume writing: only for a piece in read-through.
    var resumeRequest: ReadThrough.Request? {
        isOn ? ReadThrough.Request(docId: docId, on: false) : nil
    }

    /// The line's Save one: a Start for a piece already in read-through, which
    /// takes only the missing checkpoint (`ReadThroughVerbs.start`).
    var saveCheckpointRequest: ReadThrough.Request? {
        isOn && offersSaveOne ? ReadThrough.Request(docId: docId, on: true) : nil
    }

    /// **Whether a Start's checkpoint could land**: the posture allows
    /// `.checkpoint` — what `CheckpointCapture` itself refuses on — and the
    /// share is writable (`CheckpointFlashDecision.labelledCapture`).
    static func mayTakeCheckpoint(posture: Posture?, shareIsReadOnly: Bool) -> Bool {
        (posture?.allows(.checkpoint) ?? false) && !shareIsReadOnly
    }

    /// The offer for a piece in read-through: Resume is always enabled,
    /// whatever the posture, the share, a translation or the centre; Save one
    /// only where `mayTakeCheckpoint`.
    static func on(docId: String, lacksCheckpoint: Bool,
                   mayTakeCheckpoint: Bool) -> ReadThroughOffer {
        ReadThroughOffer(docId: docId, isOn: true, isEnabled: true, reason: nil,
                         lacksCheckpoint: lacksCheckpoint,
                         offersSaveOne: lacksCheckpoint && mayTakeCheckpoint)
    }

    /// nil where no manuscript piece is open. **Resume** is always enabled
    /// while the piece is in read-through; **Start** only where the posture
    /// (the drawing one the window already shows) `allows(.writeText)`, the
    /// share is writable, no translation is being read, and the piece's text
    /// is what the centre shows (`isTextVisible`) — a writer never enters a
    /// state whose line she cannot see.
    @MainActor
    static func of(docId: String?, item: StructureItem?, posture: Posture?,
                   shareIsReadOnly: Bool, isReadingTranslation: Bool, isTextVisible: Bool,
                   pieces: Set<String>, lackingCheckpoint: Set<String>) -> ReadThroughOffer? {
        guard let docId, let item, item.id == docId,
              EditorHost.loadsAsAManuscript(item) else { return nil }
        if ReadThrough.isOn(docId, in: pieces) {
            return .on(docId: docId, lacksCheckpoint: lackingCheckpoint.contains(docId),
                       mayTakeCheckpoint: mayTakeCheckpoint(posture: posture,
                                                            shareIsReadOnly: shareIsReadOnly))
        }
        let reason: String?
        if !(posture?.allows(.writeText) ?? false) {
            reason = postureRefusal
        } else if shareIsReadOnly {
            reason = shareRefusal
        } else if isReadingTranslation {
            reason = translationRefusal
        } else if !isTextVisible {
            reason = hiddenTextRefusal
        } else {
            reason = nil
        }
        return ReadThroughOffer(docId: docId, isOn: false, isEnabled: reason == nil,
                                reason: reason)
    }
}

// MARK: - The View menu

struct FocusedReadThroughOfferKey: FocusedValueKey { typealias Value = ReadThroughOffer }
extension FocusedValues {
    /// The key window's offer for its open piece (`ReadThroughModifier`), for
    /// View ▸ Start Read-through / Resume Writing and ⌘⌥⇧R.
    var readThroughOffer: ReadThroughOffer? {
        get { self[FocusedReadThroughOfferKey.self] }
        set { self[FocusedReadThroughOfferKey.self] = newValue }
    }
}
