import Foundation
import MaughamCore

/// **The window's cached `ReferenceIndex`, rebuilt off the main thread**
/// (report foundations plan 3b Task 1). `EditorHost` owns one, the way it owns
/// `EditorHostLoadGeneration`: a plain reference, deliberately not observable
/// (tripwire 6). The coordinator reads `index` through a closure; nothing here
/// runs per keystroke.
///
/// **What makes it rebuild** (`invalidate(_:)` and `noteSettled`):
/// - the research tree changing (`.research`; no text is re-read);
/// - the binder changing, a document switch or the host appearing (`.all`);
/// - a closed piece's op log changing (`.piece`, from `maughamAnnotationsChanged`,
///   which `DocumentStore` posts for a change to a document nothing has open);
/// - the open document's text settling: the coordinator's 350 ms metrics edge,
///   never a keystroke (`noteSettled`).
///
/// **What a rebuild re-reads**: only what was invalidated. A piece open in a
/// window gives its live text. A closed piece is asked its op-log token
/// (`DerivedManuscriptCache.token`) first, and its derived text is read again
/// only when the token moved. Each piece's summary is kept beside the text it
/// came from, so the background build re-parses only a piece whose text
/// changed. The build runs in a detached task; the result is published back on
/// the main actor, and the version bumps only when the sources or targets
/// actually changed, which is when `onVersionChange` fires.
@MainActor
final class ReferenceIndexHost {

    /// How the host reads the project. `EditorHost` builds it over its store
    /// and document store; tests hand in plain closures.
    struct Project {
        var structure: () -> [StructureItem]
        var research: () -> [ResearchItem]
        /// A piece's live text when a `Document` has it open, else nil.
        var liveText: (_ path: String) -> String?
        /// A closed piece's op-log token: cheap, derives nothing.
        var token: (_ docId: String) -> DerivedManuscriptCache.Token?
        /// A closed piece's derived display text (tripwire 20: never the `.md`).
        var derivedText: (_ docId: String) -> String?
        /// The default book's element words ("Figure", "Slika").
        var words: () -> ElementWords
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
    /// the index. `EditorHost` writes it to `EditorControl.referenceIndexVersion`.
    var onVersionChange: ((Int) -> Void)?

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
    private var words: ElementWords?
    private var staleAll = true
    private var stale = Set<String>()
    private var dirty = false
    private var building: Task<Void, Never>?
    /// Bumped by `attach`, so a drain started for an earlier project neither
    /// publishes into the new one nor clears the new drain's `building`.
    private var generation = 0

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
        words = nil
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
        scheduleRebuild()
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
        while dirty, generation == self.generation, let snapshot = makeSnapshot() {
            dirty = false
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
        guard !built.hasSameContents(as: index) else { return }
        index = built.versioned(index.version + 1)
        onVersionChange?(index.version)
    }

    /// The inputs of one build, read on the main actor: re-reads only the
    /// invalidated pieces, and a closed one only when its op-log token moved.
    private func makeSnapshot() -> Snapshot? {
        guard let project else { return nil }
        if staleAll || words == nil { words = project.words() }
        var pieces: [(docId: String, text: String?)] = []
        var kept: [String: Entry] = [:]
        for item in ProjectStoreASTSource.publishablePieces(in: project.structure()) {
            guard let path = item.path, !DocumentFormat.ofManuscript(path: path).isScreenplay else {
                pieces.append((item.id, nil))
                continue
            }
            var entry = entries[item.id]
            if entry == nil || staleAll || stale.contains(item.id) {
                entry = read(item.id, path: path, previous: entry, project: project)
            }
            kept[item.id] = entry
            pieces.append((item.id, entry?.text))
        }
        entries = kept
        staleAll = false
        stale.removeAll()
        return Snapshot(pieces: pieces, research: project.research(), words: words ?? .english)
    }

    private func read(_ docId: String, path: String, previous: Entry?, project: Project) -> Entry {
        if let live = project.liveText(path) { return Entry(text: live, token: nil) }
        let token = project.token(docId)
        if let previous, let held = previous.token, held == token { return previous }
        return Entry(text: project.derivedText(docId), token: token)
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
