import Foundation
import MaughamCore

/// **The window's cached `ReferenceIndex`** (report foundations plan 3b
/// Task 1). The project window owns one (report plan 8a Task 2), so the
/// Figures listing numbers with no editor mounted; `ReferenceIndexWiring`
/// attaches it and carries the window's edges, and `EditorHost` is handed it
/// as a plain `let` — a reference, deliberately not observable (tripwire 6).
/// The coordinator reads `index` through a closure; nothing here runs per
/// keystroke.
///
/// **What makes it rebuild** (`invalidate(_:)` and `noteSettled`):
/// - the research tree changing (`.research`; no text is re-read) — the window;
/// - the binder changing (`.all`) — the window; a document switch (`.all`,
///   and `.piece` for the piece just left, flushed) — `EditorHost`;
/// - a closed piece's op log changing (`.piece`, from `maughamAnnotationsChanged`,
///   which `DocumentStore` posts for a change to a document nothing has open)
///   — the window;
/// - the open document's text settling: the coordinator's 350 ms metrics edge,
///   never a keystroke (`noteSettled`) — `EditorHost`.
///
/// **What runs where** (whole-branch review I2). One rebuild is three steps:
/// 1. *Main actor:* the binder's pieces, and the live text of every
///    invalidated piece a window has open. Memory reads only.
/// 2. *Off the main actor:* the op-log tokens of the invalidated CLOSED pieces
///    (`DerivedManuscriptCache.tokens(forDocIds:in:)`: ONE listing of
///    `.maugham/ops` per rebuild, plus a stat per file) and the book's element
///    words, re-read every rebuild so a language change in Publish shows at
///    the next one (M3).
/// 3. *Main actor:* the derived text of a closed piece whose token moved
///    (`DerivedManuscriptCache` is main-actor only; tripwire 20: never the
///    `.md`), then *off the main actor* the parse and the index. Each piece's
///    summary is kept beside the text it came from, so the build re-parses
///    only a piece whose text changed.
///
/// The result is published back on the main actor, and the version bumps only
/// when the sources or targets actually changed (or on the first build, even
/// of an empty project), which is when `onVersionChange` fires. A build that
/// moved only lines (`ReferenceIndex.hasSameLines`) replaces the index at the
/// same version, so the editor repaints nothing; `onPublish` fires for both.
///
/// Before that first build, `labelsDefined(excluding:)` walks the project
/// synchronously, so a command minting a label never trusts the empty index
/// (whole-branch review I1).
@MainActor
final class ReferenceIndexHost {

    /// How the host reads the project. `ReferenceIndexWiring` builds it over
    /// the window's stores (`window(store:documentStore:)`); tests hand in
    /// plain closures.
    struct Project {
        var structure: () -> [StructureItem]
        var research: () -> [ResearchItem]
        /// A piece's live text when a `Document` has it open, else nil.
        var liveText: (_ path: String) -> String?
        /// Closed pieces' op-log tokens, asked OFF the main actor once per
        /// rebuild with every closed piece to check: derives nothing, and
        /// lists `.maugham/ops` once (`DerivedManuscriptCache.tokens`).
        var tokens: @Sendable (_ docIds: [String]) -> [String: DerivedManuscriptCache.Token]
        /// A closed piece's derived display text (tripwire 20: never the `.md`).
        /// Main actor: the derived cache is.
        var derivedText: (_ docId: String) -> String?
        /// The default book's element words ("Figure", "Slika"), asked off
        /// the main actor at every rebuild.
        var words: @Sendable () -> ElementWords
    }

    enum Scope: Equatable {
        /// Re-read every piece (cheaply: a closed piece only when its token moved).
        case all
        /// Re-read one piece.
        case piece(String)
        /// The research tree changed; no text is re-read.
        case research
    }

    /// What one background build is handed: plain values only.
    struct Snapshot: Sendable {
        /// Publishable pieces in publishing order; a nil text contributes
        /// nothing (a screenplay, an unreadable piece).
        let pieces: [(docId: String, text: String?)]
        let research: [ResearchItem]
        let words: ElementWords
    }

    /// One piece's summary and the text it was read from.
    struct Memo: Sendable {
        let text: String
        let summary: ReferenceIndex.PieceSummary
    }

    typealias Builder = @Sendable (Snapshot, [String: Memo]) -> (ReferenceIndex, [String: Memo])

    /// The cached index. Cheap to read; never built on the caller's turn.
    private(set) var index: ReferenceIndex = .empty
    /// Called on the main actor with the new version after a rebuild changed
    /// the index. The window writes it to `EditorControl.referenceIndexVersion`.
    var onVersionChange: ((Int) -> Void)?
    /// Called on the main actor after any build that replaced `index` — a new
    /// version, or the same version with lines moved. The window refreshes
    /// its `FigureListingModel` here.
    var onPublish: (() -> Void)?

    private var project: Project?
    private let builder: Builder

    private struct Entry {
        let text: String?
        /// The op-log token the text was derived at; nil for live text, which
        /// is re-read whenever its piece is invalidated.
        let token: DerivedManuscriptCache.Token?
    }
    private var entries: [String: Entry] = [:]
    private var memo: [String: Memo] = [:]
    /// Pieces whose open text settled while a rebuild's token step was off
    /// the main actor: that step's answer for them is older than the
    /// settled text, which stands.
    private var settledDuringLookup = Set<String>()
    private var staleAll = true
    private var stale = Set<String>()
    private var dirty = false
    private var building: Task<Void, Never>?
    /// Bumped by `attach`, so a drain started for an earlier project neither
    /// publishes into the new one nor clears the new drain's `building`.
    private var generation = 0
    /// Whether any build has published yet.
    private var hasPublished = false

    init(builder: @escaping Builder = ReferenceIndexHost.build) {
        self.builder = builder
    }

    /// Point the host at a project (or at none, `nil`, which stops it) and
    /// rebuild from scratch.
    func attach(_ project: Project?) {
        self.project = project
        generation += 1
        entries.removeAll()
        memo.removeAll()
        settledDuringLookup.removeAll()
        building?.cancel()
        building = nil
        dirty = false
        guard project != nil else { return }
        invalidate(.all)
    }

    func invalidate(_ scope: Scope) {
        switch scope {
        case .all: staleAll = true
        case .piece(let docId): stale.insert(docId)
        case .research: break
        }
        scheduleRebuild()
    }

    /// The open document's text has settled (the metrics edge): it is the
    /// piece's text from now on, with no disk read.
    func noteSettled(docId: String, text: String) {
        if let current = entries[docId], current.token == nil, current.text == text { return }
        entries[docId] = Entry(text: text, token: nil)
        stale.remove(docId)
        settledDuringLookup.insert(docId)
        scheduleRebuild()
    }

    /// The labels the project's manuscripts other than `docId` define, for a
    /// command that mints or checks one (Insert Table, Insert Figure, the
    /// grid's label). The cached index once a build has published; before
    /// that (version 0) the index is empty, so this walks every other piece
    /// now, as plan 3a did — its live text, else its op-log-derived text —
    /// rather than let a command mint a label another chapter already has
    /// (whole-branch review I1). Per command, never per keystroke.
    func labelsDefined(excluding docId: String) -> Set<ManuscriptLabel> {
        guard index.version == 0, let project else { return index.labelsDefined(excluding: docId) }
        return ReportInsert.labelsElsewhere(in: project.structure(), excluding: docId) { item, path in
            project.liveText(path) ?? project.derivedText(item.id)
        }
    }

    /// Returns once no rebuild is pending or running (tests; a host never waits).
    func idle() async {
        while let task = building { await task.value }
    }

    // MARK: - Rebuilding

    private func scheduleRebuild() {
        guard project != nil else { return }
        dirty = true
        guard building == nil else { return }
        let generation = generation
        building = Task { [weak self] in await self?.drain(generation) }
    }

    private func drain(_ generation: Int) async {
        while dirty, generation == self.generation, let plan = makePlan() {
            dirty = false
            settledDuringLookup.removeAll()
            // Off the main actor: one listing of the ops directory for every
            // closed piece to check, and the book's words (I2, M3).
            let tokensOf = plan.project.tokens, wordsOf = plan.project.words
            let closed = plan.closed
            let (tokens, words) = await Task.detached(priority: .utility) {
                (closed.isEmpty ? [:] : tokensOf(closed), wordsOf())
            }.value
            guard generation == self.generation else { return }
            let snapshot = finish(plan, tokens: tokens, words: words)
            let builder = self.builder, memo = self.memo
            let (built, nextMemo) = await Task.detached(priority: .utility) {
                builder(snapshot, memo)
            }.value
            guard generation == self.generation else { return }
            self.memo = nextMemo
            publish(built)
        }
        if generation == self.generation { building = nil }
    }

    private func publish(_ built: ReferenceIndex) {
        // The first build always publishes, even an empty one, so version 0
        // means "not built yet": the editor's problem marks wait for it
        // rather than calling every key unknown (plan 3b Task 6).
        let contentsMoved = !hasPublished || !built.hasSameContents(as: index)
        guard contentsMoved || !built.hasSameLines(as: index) else { return }
        hasPublished = true
        index = built.versioned(index.version + (contentsMoved ? 1 : 0))
        if contentsMoved { onVersionChange?(index.version) }
        onPublish?()
    }

    /// Step 1 of a rebuild, on the main actor and from memory only: the
    /// readable pieces in publishing order, the live text of each invalidated
    /// open piece, and which invalidated pieces are closed (their tokens are
    /// asked off the main actor next).
    private struct Plan {
        let project: Project
        /// Each readable piece's id and path (nil: contributes no text).
        let pieces: [(docId: String, path: String?)]
        /// Invalidated pieces no window has open.
        let closed: [String]
    }

    private func makePlan() -> Plan? {
        guard let project else { return nil }
        var pieces: [(docId: String, path: String?)] = []
        var closed: [String] = []
        for (item, readablePath) in ReferenceIndex.readablePieces(in: project.structure()) {
            pieces.append((item.id, readablePath))
            guard let path = readablePath,
                  entries[item.id] == nil || staleAll || stale.contains(item.id) else { continue }
            if let live = project.liveText(path) {
                entries[item.id] = Entry(text: live, token: nil)
            } else {
                closed.append(item.id)
            }
        }
        staleAll = false
        stale.removeAll()
        return Plan(project: project, pieces: pieces, closed: closed)
    }

    /// Step 3's main-actor half: a closed piece's text is derived again only
    /// when its op-log token moved (and not when its open text settled while
    /// the tokens were being read); then the snapshot, in publishing order.
    private func finish(_ plan: Plan, tokens: [String: DerivedManuscriptCache.Token],
                        words: ElementWords) -> Snapshot {
        for docId in plan.closed where !settledDuringLookup.contains(docId) {
            let token = tokens[docId]
            if let previous = entries[docId], let held = previous.token, held == token { continue }
            entries[docId] = Entry(text: plan.project.derivedText(docId), token: token)
        }
        var kept: [String: Entry] = [:]
        var pieces: [(docId: String, text: String?)] = []
        for piece in plan.pieces {
            guard piece.path != nil else {
                pieces.append((piece.docId, nil))
                continue
            }
            let entry = entries[piece.docId]
            kept[piece.docId] = entry
            pieces.append((piece.docId, entry?.text))
        }
        entries = kept
        return Snapshot(pieces: pieces, research: plan.project.research(), words: words)
    }

    /// The production builder: each piece's summary from the memo when its
    /// text is unchanged, else parsed afresh; then the index. Runs off the
    /// main actor.
    nonisolated static func build(_ snapshot: Snapshot,
                                  _ memo: [String: Memo]) -> (ReferenceIndex, [String: Memo]) {
        var next: [String: Memo] = [:]
        let pieces = snapshot.pieces.map { piece -> ReferenceIndex.Piece in
            guard let text = piece.text else { return (piece.docId, .empty) }
            if let held = memo[piece.docId], held.text == text {
                next[piece.docId] = held
                return (piece.docId, held.summary)
            }
            let summary = ReferenceIndex.PieceSummary(text: text)
            next[piece.docId] = Memo(text: text, summary: summary)
            return (piece.docId, summary)
        }
        return (ReferenceIndex.build(pieces: pieces, research: snapshot.research,
                                     words: snapshot.words), next)
    }
}
