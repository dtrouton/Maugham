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
/// the value every non-editor surface asks. A piece owns itself; a research
/// item belongs to the Collection piece whose folder holds it (nested items
/// through their root, `ProjectStore.researchRootPath`); a figure follows its
/// `FigureRecord.piece`. Shared research and a book-wide figure belong to no
/// piece and are refused by nothing.
struct ReadThroughGate: Equatable {
    let pieces: Set<String>
    private let researchOwners: [String: String]
    private let figureOwners: [String: String]

    /// The empty gate: refuses nothing.
    static let writing = ReadThroughGate(
        pieces: [], structure: [], research: [], figures: [])

    /// Builds the owner maps only when some piece is in read-through — the
    /// common case asks nothing of the structure.
    init(pieces: Set<String>, structure: [StructureItem], research: [ResearchItem],
         figures: [FigureRecord]) {
        self.pieces = pieces
        guard !pieces.isEmpty else {
            researchOwners = [:]
            figureOwners = [:]
            return
        }
        var research_: [String: String] = [:]
        for root in research {
            // Every descendant's root is this top-level item, so one root path
            // per top-level item answers for the whole subtree.
            let rootPath = ProjectStore.researchRootPath(ofItemId: root.id, in: research)
            guard let owner = ProjectStore.researchScopePieceId(
                ofPath: rootPath, structure: structure) else { continue }
            func mark(_ item: ResearchItem) {
                research_[item.id] = owner
                for child in item.children ?? [] { mark(child) }
            }
            mark(root)
        }
        researchOwners = research_
        var figures_: [String: String] = [:]
        for figure in figures {
            if let piece = figure.piece { figures_[figure.id] = piece }
        }
        figureOwners = figures_
    }

    /// The piece a target belongs to, or nil for one that belongs to none.
    func owner(of target: ReadThroughTarget) -> String? {
        switch target {
        case .piece(let id): return id
        case .research(let id): return researchOwners[id]
        case .figure(let id): return figureOwners[id]
        }
    }

    func refusesEdits(_ target: ReadThroughTarget) -> Bool {
        ReadThrough.isOn(owner(of: target), in: pieces)
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

    static let postureRefusal =
        "This Mac may not change this piece’s text, so there is nothing to start."
    static let shareRefusal =
        "This piece is shared with you to view, so there is nothing to start."
    static let translationRefusal = "Read Source to start a read-through."

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
        isOn && lacksCheckpoint ? ReadThrough.Request(docId: docId, on: true) : nil
    }

    /// The offer for a piece in read-through: Resume is always enabled,
    /// whatever the posture, the share or a translation.
    static func on(docId: String, lacksCheckpoint: Bool) -> ReadThroughOffer {
        ReadThroughOffer(docId: docId, isOn: true, isEnabled: true, reason: nil,
                         lacksCheckpoint: lacksCheckpoint)
    }

    /// nil where no manuscript piece is open. **Resume** is always enabled
    /// while the piece is in read-through; **Start** only where the posture
    /// (the drawing one the window already shows) `allows(.writeText)`, the
    /// share is writable and no translation is being read.
    @MainActor
    static func of(docId: String?, item: StructureItem?, posture: Posture?,
                   shareIsReadOnly: Bool, isReadingTranslation: Bool,
                   pieces: Set<String>,
                   lackingCheckpoint: Set<String> = []) -> ReadThroughOffer? {
        guard let docId, let item, item.id == docId,
              EditorHost.loadsAsAManuscript(item) else { return nil }
        if ReadThrough.isOn(docId, in: pieces) {
            return .on(docId: docId, lacksCheckpoint: lackingCheckpoint.contains(docId))
        }
        let reason: String?
        if !(posture?.allows(.writeText) ?? false) {
            reason = postureRefusal
        } else if shareIsReadOnly {
            reason = shareRefusal
        } else if isReadingTranslation {
            reason = translationRefusal
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
