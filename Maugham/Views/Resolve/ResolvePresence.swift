import SwiftUI
import MaughamCore

/// **Which rows of the tree have something to resolve** (shell plan 4, Task
/// 3; ADR 0035's "one 'to resolve' dot on rows"). Pure: one read of the
/// Book's scope (`ResolveReader`) in, the marked rows out. A row asks
/// `rowMark` of its own id; nothing is computed per row (tripwire 4).
///
/// - A piece is marked when an open note, an open to-do or a live strain is
///   on it — a figure's notes on the piece that owns it (`countsOn`).
/// - A Part is marked when any piece under it is (`partHasMark`), worked out
///   here, never by the row.
/// - The Book is marked when its own to-dos or an unowned figure's notes
///   wait, and when anything inside it does (owner, 2026-11-21: "a collapsed
///   Part or the Book should show it when anything inside does").
/// - In a screenplay, a scene is marked when an item's paragraph falls in it;
///   items before the first slugline mark the script row only.
/// - A reference piece is never marked.
/// - **A piece that would not read is never quiet** (RULING-54; controller's
///   ruling, fix round 1): with nothing listed on it, it is `unknown` and
///   draws a hollow ring ("Could not be read"); with something listed it
///   carries the dot — a filled dot wins. A Part or the Book over an unknown
///   piece rolls up as unknown only when nothing inside is marked. The same
///   pieces Status draws an em dash for (`ProjectStore.unknownCounts`: the
///   unreadable piece, and the owner of an unreadable figure).
enum ResolvePresence {

    struct Marks: Equatable {
        /// Marked pieces and Parts, by structure id.
        var pieces: Set<String>
        /// The Book row.
        var book: Bool
        /// Marked scenes, indexed as `FountainScript.sceneSummaries()` is.
        var scenes: Set<Int>
        /// Pieces and Parts that could not be read and carry no dot.
        var unknown: Set<String> = []
        /// The Book row, when it carries no dot and something in it would
        /// not read.
        var bookUnknown: Bool = false
        /// Edition rows whose To resolve holds anything, by language (shell
        /// p4 Task 6; `ResolveEditionItems.markedEditions`).
        var editions: Set<String> = []
        /// Edition rows a brief proposal waits for, by lowercased language
        /// (fix round I4; the watch reads `StatementProposalStore`).
        var proposedBriefs: Set<String> = []

        static let none = Marks(pieces: [], book: false, scenes: [])
    }

    /// The marks `snapshot` (the Book's scope) puts on the tree.
    ///
    /// - Parameters:
    ///   - figureOwners: `ProjectStore.figureNoteOwners(manifest.figures)`.
    ///   - sceneIndex: `ParagraphOffsets.sceneIndex` of the screenplay's one
    ///     script (`sceneIndex(_:scope:script:)`), nil elsewhere.
    @MainActor
    static func marks(_ snapshot: ResolveSnapshot, structure: [StructureItem],
                      figureOwners: [String: String?], sceneIndex: [String: Int]?) -> Marks {
        let markable = Set(TreeWalk.collect(in: structure) {
            $0.type == .document && $0.pieceKind != .reference
        }.map(\.id))
        var pieces: Set<String> = []
        var bookOwn = false
        var scenes: Set<Int> = []

        for item in snapshot.items {
            let docId = item.docId
            if docId == ProjectStore.projectTasksDocId { bookOwn = true; continue }
            guard let owner = ProjectStore.countsOn(docId, owners: figureOwners) else {
                // A figure no piece owns: the Book's.
                bookOwn = true
                continue
            }
            guard markable.contains(owner) else { continue }
            pieces.insert(owner)
            if let sceneIndex, owner == docId,
               let paragraph = item.paragraphId, let scene = sceneIndex[paragraph] {
                scenes.insert(scene)
            }
        }

        // What would not read: the piece itself, or the owner of a figure.
        var unknown: Set<String> = []
        var bookUnreadable = false
        for docId in snapshot.unreadableDocIds {
            guard let owner = ProjectStore.countsOn(docId, owners: figureOwners) else {
                bookUnreadable = true
                continue
            }
            if markable.contains(owner), !pieces.contains(owner) { unknown.insert(owner) }
        }

        var marks = Marks(pieces: pieces, book: bookOwn || !pieces.isEmpty, scenes: scenes)
        let parts = TreeWalk.collect(in: structure) { $0.type == .group }.map(\.id)
        for part in parts where partHasMark(part, marks: marks, structure: structure) {
            marks.pieces.insert(part)
        }
        for part in parts where !marks.pieces.contains(part)
            && partHolds(part, any: unknown, structure: structure) {
            marks.unknown.insert(part)
        }
        marks.unknown.formUnion(unknown)
        marks.bookUnknown = !marks.book && (bookUnreadable || !unknown.isEmpty)
        return marks
    }

    /// Whether the Part `groupId` carries the mark: a piece anywhere under it
    /// does.
    static func partHasMark(_ groupId: String, marks: Marks, structure: [StructureItem]) -> Bool {
        partHolds(groupId, any: marks.pieces, structure: structure)
    }

    private static func partHolds(_ groupId: String, any ids: Set<String>,
                                  structure: [StructureItem]) -> Bool {
        guard !ids.isEmpty, let group = TreeWalk.find(id: groupId, in: structure),
              group.type == .group else { return false }
        return !TreeWalk.collect(in: group.children ?? []) {
            $0.type == .document && ids.contains($0.id)
        }.isEmpty
    }

    // MARK: - What a row draws

    /// A row of the tree, as the mark knows it.
    enum Row: Equatable {
        /// A chapter, a Part, a Collection piece or a screenplay's script.
        case item(String)
        /// The Book row.
        case book
        /// A screenplay's scene, by its `sceneSummaries()` index.
        case scene(Int)
        /// An edition, by its language.
        case edition(String)
    }

    enum RowMark: Equatable {
        case quiet
        /// Something to resolve: the filled dot.
        case something
        /// Could not be read: the hollow ring.
        case unknown
    }

    /// **What a row draws** — the one decision every row calls
    /// (`ResolvePresenceMark`); a filled dot wins over a ring.
    static func rowMark(_ row: Row, in marks: Marks) -> RowMark {
        switch row {
        case .item(let id):
            if marks.pieces.contains(id) { return .something }
            return marks.unknown.contains(id) ? .unknown : .quiet
        case .book:
            if marks.book { return .something }
            return marks.bookUnknown ? .unknown : .quiet
        case .scene(let index):
            return marks.scenes.contains(index) ? .something : .quiet
        case .edition(let language):
            return marks.editions.contains(language) ? .something : .quiet
        }
    }

    /// **Whether a row carries the "Proposed" word** (fix round I4) — beside,
    /// never instead of, `rowMark`'s dot. Only an edition row has one.
    static func proposalMark(_ row: Row, in marks: Marks) -> Bool {
        guard case .edition(let language) = row else { return false }
        return marks.proposedBriefs.contains(language.lowercased())
    }

    /// The languages a pending edition-brief proposal names, lowercased.
    static func proposedBriefLanguages(_ proposals: [StatementProposalStore.Proposal]) -> Set<String> {
        Set(proposals.compactMap {
            if case .editionBrief(let language) = $0.kind { return language.lowercased() }
            return nil
        })
    }

    /// **What the presence read also answers for the editions** (shell p4
    /// Task 5 fix round): each piece's open questions (`.query` and
    /// `.craftNote`, open — `EditionStatus`'s own filter), the pieces that
    /// would not read, and every piece's paragraph order. Read off the main
    /// actor by the walk the window already runs, so neither an edition's
    /// Status nor its book loads a chapter. A piece the walk has not reached
    /// yet is absent until it lands.
    struct BookReading: Equatable {
        var openQuestions: [String: [Annotation]] = [:]
        var unreadable: Set<String> = []
        var sequences: [String: [String]] = [:]
        /// Every open note with a language on the book's pieces — an
        /// edition's questions (`ResolveEditionItems.questionLanguage`), for
        /// an edition's To resolve (shell p4 Task 6 fix round, review I4).
        var languageNotes: [ProjectAnnotation] = []

        /// Whether the window's first walk has read the whole book
        /// (`ResolvePresenceReader.hasFinishedAWalk`): until it has, an
        /// absent question may be one not yet reached.
        var isComplete = false

        /// The language notes as the walk's shape, for `ResolveReader.read`.
        var languageNotesSnapshot: ProjectAnnotationsSnapshot {
            ProjectAnnotationsSnapshot(annotations: languageNotes,
                                       unreadableDocIds: unreadable.sorted(), sequences: sequences)
        }
    }

    static func bookReading(_ snapshot: ResolveSnapshot, complete: Bool = true) -> BookReading {
        var questions: [String: [Annotation]] = [:]
        var languageNotes: [ProjectAnnotation] = []
        for case .note(let note) in snapshot.items {
            if [.query, .craftNote].contains(note.annotation.kind) && note.annotation.status == .open {
                questions[note.docId, default: []].append(note.annotation)
            }
            if !DocumentClass.isFigureDocId(note.docId),
               ResolveEditionItems.questionLanguage(of: note.annotation) != nil {
                languageNotes.append(note)
            }
        }
        return BookReading(openQuestions: questions, unreadable: Set(snapshot.unreadableDocIds),
                           sequences: snapshot.sequences, languageNotes: languageNotes,
                           isComplete: complete)
    }

    /// **Each piece's open to-dos, for Status's column** (shell p4 Task 4),
    /// counted from the same Book-scope read as the marks — no third walk. A
    /// figure's to-do counts on its owner (`countsOn`); the Book's own count
    /// under `ProjectStore.projectTasksDocId`, which is no row's id — Status's
    /// footer reads it (fix round 1) — and an unowned figure's on nothing.
    static func openToDos(_ items: [ResolveItem], figureOwners: [String: String?]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for case .todo(let task) in items where task.status == .open {
            let docId = task.anchor?.docId ?? ProjectStore.projectTasksDocId
            if docId == ProjectStore.projectTasksDocId {
                counts[docId, default: 0] += 1
                continue
            }
            guard let owner = ProjectStore.countsOn(docId, owners: figureOwners) else { continue }
            counts[owner, default: 0] += 1
        }
        return counts
    }

    /// The screenplay's paragraph → scene map, To resolve's own rule
    /// (`ResolvePane.regroup`): only where the Book's scope is the one script
    /// and a parse is in hand.
    static func sceneIndex(_ snapshot: ResolveSnapshot, scope: ResolveScope,
                           script: FountainScript?) -> [String: Int]? {
        guard case .piece(let docId, _) = scope, let script else { return nil }
        let starts = ParagraphOffsets.starts(sequence: snapshot.sequences[docId] ?? [],
                                             paragraphs: snapshot.paragraphText)
        return ParagraphOffsets.sceneIndex(
            starts: starts, sceneStarts: script.sceneSummaries().map(\.line.range.location))
    }
}

// MARK: - The rows' value

private struct ResolvePresenceKey: EnvironmentKey {
    static let defaultValue = ResolvePresence.Marks.none
}

extension EnvironmentValues {
    /// The window's marks, handed to every tree row at the `List`
    /// (`treeRowStates`), from `BinderTreeSectionsState.presence`.
    var resolvePresence: ResolvePresence.Marks {
        get { self[ResolvePresenceKey.self] }
        set { self[ResolvePresenceKey.self] = newValue }
    }
}

/// **The mark itself**, at the row's trailing edge, never a number: a filled
/// dot for something to resolve, a hollow ring of the same size for a piece
/// that could not be read, nothing for a quiet row. Accent ink, so it never
/// reads as the stage dot (a draft's is grey and leads a chapter row); on a
/// selected row's accent fill it turns `.primary` (white), as the row's text
/// does.
struct ResolvePresenceMark: View {
    /// The words each mark says to VoiceOver.
    static let somethingLabel = "Something to resolve"
    static let unknownLabel = "Could not be read"
    static let diameter: CGFloat = 5

    let mark: ResolvePresence.RowMark

    init(_ mark: ResolvePresence.RowMark) { self.mark = mark }

    @Environment(\.backgroundProminence) private var prominence

    private var ink: AnyShapeStyle {
        prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.accentColor)
    }

    var body: some View {
        switch mark {
        case .quiet:
            EmptyView()
        case .something:
            Circle()
                .fill(ink)
                .frame(width: Self.diameter, height: Self.diameter)
                .accessibilityElement()
                .accessibilityLabel(Self.somethingLabel)
        case .unknown:
            Circle()
                .strokeBorder(ink, lineWidth: 1)
                .frame(width: Self.diameter, height: Self.diameter)
                .accessibilityElement()
                .accessibilityLabel(Self.unknownLabel)
        }
    }
}

// MARK: - The window's read

/// **The presence read, mounted on the window** (`ProjectWindow.body`), so it
/// runs whether or not the tree is drawn. Load-bearing: without the mount
/// line no row is ever marked and Status's to-dos column is empty
/// (`ResolvePresenceTests.test_theRowsAndTheWindowAreWired`).
struct ResolvePresenceWiring: ViewModifier {
    let store: ProjectStore?
    let documentStore: DocumentStore?
    let url: URL
    let window: NSWindow?
    let state: BinderTreeSectionsState
    let diagnostics: DiagnosticsStore?
    /// The window's `lastParsedScript`.
    let script: FountainScript?
    /// Whether the window's last compile was stopped by problems
    /// (`ResolveEditionItems.stoppingProblems`, the list's own predicate) —
    /// in every edition's list, so every edition row's mark.
    var compileProblems: Bool = false

    func body(content: Content) -> some View {
        content.background {
            if let store, let documentStore {
                ResolvePresenceWatch(store: store, documentStore: documentStore, url: url,
                                     window: window, state: state, diagnostics: diagnostics,
                                     script: script, compileProblems: compileProblems)
            }
        }
    }
}

/// **The presence read's decisions, held between keys** (fix rounds 1 and
/// 2): a class the watch holds and the tests drive exactly as the watch
/// does, with no view.
///
/// - **No step of it holds the main actor for a walk** (fix round 2). The
///   closed pieces are read off the main actor, a chunk at a time
///   (`ResolveChunkedWalk`); `update` only decides what is stale and asks
///   for it (`pendingRequest`), and `apply` folds each chunk in. A piece not
///   yet read draws nothing — never the ring — and the marks fill in as the
///   chunks land.
/// - **What is read, and when**: every closed piece when the coalesced
///   annotation-event token moves (a closed piece, a figure, a peer's sync);
///   a piece the scope gained; the figures with the token or when the
///   figures change. **Never on a piece opening or closing**: an open piece
///   is read off its `Document` (`ResolveReader.overlaying`), and a piece
///   closing folds its last live state into what is held. A Book's own to-do
///   re-reads only the Book's own log (`ProjectStore.projectLevelTasks`).
/// - **A change arriving mid-walk is neither lost nor counted twice**: a
///   chunk replaces its pieces' entries (never adds); a chunk from a walk the
///   token has since moved past is dropped (its generation is old) and the
///   new walk reads every piece again; a piece open at any point during a
///   walk keeps its live or folded state over what the walk read.
/// - A diagnostics or pass change re-gathers over what is held; a new parse
///   re-reads the script's text; an open piece's note or to-do change is the
///   live splice. None walks.
/// - **The marks and Status's to-dos come from one snapshot**, recomputed on
///   every step and on any change of the tree's shape or the figures'
///   owners (moving a chapter between Parts moves no read key).
@MainActor
final class ResolvePresenceReader {

    /// One open piece's live inputs.
    struct LiveVersion: Equatable {
        let annotations: Int
        let tasks: Int
    }

    /// Everything the presence depends on.
    struct Key: Equatable {
        /// To resolve's read key at the Book's scope, with no open pieces in
        /// it: opening and closing a piece is not a read.
        let read: ResolveReadKey
        let script: FountainScript?
        /// The open in-scope pieces and their live versions.
        let open: [String: LiveVersion]
        let structure: [StructureItem]
        let figureOwners: [String: String?]
    }

    /// How long a burst of closed-piece events waits before its one walk.
    static let coalesce: Duration = .milliseconds(250)

    static func key(store: ProjectStore, documentStore: DocumentStore,
                    diagnostics: DiagnosticsStore?, annotationsToken: Int,
                    script: FountainScript?) -> Key {
        let structure = store.manifest.structure
        let scope = ResolveScope.of(.project, readIn: nil,
                                    sourceLanguage: PublishConfig.Metadata().language,
                                    structure: structure, projectType: store.manifest.type)
        let inScope = Set(scope.docIds)
        var open: [String: LiveVersion] = [:]
        for doc in documentStore.allOpenDocuments() where inScope.contains(doc.docId) {
            open[doc.docId] = LiveVersion(annotations: doc.annotationsVersion, tasks: doc.tasksVersion)
        }
        return Key(
            read: ResolveReadKey(
                scope: scope, annotationsToken: annotationsToken, openPieces: [],
                projectTasksVersion: store.projectTasksVersion,
                diagnosticsVersion: diagnostics?.version ?? 0,
                passes: store.manifest.effectiveReviewPasses,
                // The local name only sorts To resolve's chips; never read here.
                localName: ""),
            script: ResolvePane.script(for: scope, structure: structure, openDocId: nil, script: script),
            open: open, structure: structure,
            figureOwners: ProjectStore.figureNoteOwners(store.manifest.figures ?? []))
    }

    private(set) var marks: ResolvePresence.Marks = .none
    private(set) var openToDos: [String: Int] = [:]
    private(set) var snapshot: ResolveSnapshot = .empty
    /// The walk the held reads are waiting on; nil when nothing is stale.
    private(set) var pendingRequest: ResolveChunkedWalk.Request?
    /// Test seam: closed pieces read by walks so far (what "no walk" counts).
    private(set) var piecesRead = 0
    /// Test seam: walks asked for so far.
    private(set) var walksRequested = 0

    // What is held, per piece — replaced, never added to.
    private var notes: [String: [ProjectAnnotation]] = [:]
    private var tasks: [String: [WriterTask]] = [:]
    private var sequences: [String: [String]] = [:]
    private var paragraphs: [String: [String: String]] = [:]
    /// A closed piece's file-set fingerprint at its read; nil after a fold
    /// (its text is then read through the cache on demand).
    private var tokens: [String: DerivedManuscriptCache.Token] = [:]
    private var unreadable: Set<String> = []
    private var figureNotes: [String: [ProjectAnnotation]] = [:]
    private var figureUnreadable: [String] = []
    private var figureCells: [String: SuggestionDisplay.FigureCells] = [:]
    private var registryUnreadable: String?
    /// The trust the held reads were judged under.
    private var heldTrust: TrustTable?
    private var heldFacts: DocumentClass.Facts?
    private var bookTasks: [WriterTask] = []
    private var bookTasksVersion: Int?

    private var stale: Set<String> = []
    private var figuresStale = true
    private var heldFigureIds: [String] = []
    private var walkedToken: Int?
    private var generation = 0
    /// Pieces open at any point during the current walk: their live or
    /// folded state stands over what the walk read.
    private var touched: Set<String> = []
    /// The open pieces as read at the last update — held so a piece that
    /// closes is folded in from its last live state (a closed `Document` is
    /// husked, so it cannot be asked afterwards).
    private var lastLive: [String: ResolveLivePiece] = [:]
    private var last: Key?

    /// Bring the presence up to `key` without walking: fold closed pieces,
    /// decide what is stale (`pendingRequest`), re-read the Book's own
    /// to-dos when they moved, and re-gather over what is held. Returns
    /// whether `marks` or `openToDos` changed.
    @discardableResult
    func update(_ key: Key, store: ProjectStore, documentStore: DocumentStore,
                diagnostics: DiagnosticsStore?) -> Bool {
        guard key != last else { return false }
        let scope = key.read.scope
        let live = ResolvePane.livePieces(scope: scope, documentStore: documentStore)
        var dataMoved = false

        // A piece that closed: its last live state. Every note or to-do change
        // on an open piece moves its versions, and so the key, so that state
        // is its final one unless a change and the close land in one turn.
        let closed = lastLive.filter { live[$0.key] == nil }
        for (docId, piece) in closed { fold(docId, piece) }
        if !closed.isEmpty { dataMoved = true }
        lastLive = live
        touched.formUnion(live.keys)

        // What a walk must read.
        let readable = readableDocIds(scope: scope, structure: key.structure)
        let previousStale = stale
        // The token moved: whatever a walk in flight has read may predate
        // the change, so every piece is read again, by a new walk.
        var mustWalk = false
        if walkedToken != key.read.annotationsToken {
            walkedToken = key.read.annotationsToken
            // Open pieces are read off their `Document`s, never their logs.
            stale = readable.subtracting(live.keys)
            figuresStale = true
            mustWalk = true
        } else {
            let held = Set(notes.keys).union(unreadable)
            stale.formUnion(readable.subtracting(held).subtracting(live.keys))
        }
        stale.formIntersection(readable)
        let figureIds = (store.manifest.figures ?? []).map(\.id)
        if figureIds != heldFigureIds { figuresStale = true }
        // Drop what the scope no longer holds.
        for docId in Set(notes.keys).union(unreadable).subtracting(readable) {
            forget(docId)
            dataMoved = true
        }
        if mustWalk || stale != previousStale || (figuresStale && pendingRequest == nil) {
            requestWalk(order: scope.docIds)
        }

        if bookTasksVersion != key.read.projectTasksVersion {
            bookTasks = store.projectLevelTasks()
            bookTasksVersion = key.read.projectTasksVersion
            dataMoved = true
        }

        if let last, !dataMoved, last.read == key.read {
            var held = snapshot
            if last.script != key.script {
                held = ResolveReader.rereadText(held, scope: scope, store: store, documentStore: documentStore)
            }
            if last.open != key.open || last.script != key.script {
                held = ResolvePane.splicing(held, scope: scope, live: live)
            }
            snapshot = held
        } else {
            snapshot = gather(scope: scope, live: live, store: store, documentStore: documentStore,
                              diagnostics: diagnostics)
        }
        last = key
        return remark()
    }

    /// Fold one step of the walk `generation` in. A step from a walk the
    /// token has since moved past is dropped. Returns whether `marks` or
    /// `openToDos` changed.
    @discardableResult
    func apply(_ step: ResolveChunkedWalk.Step, generation: Int, store: ProjectStore,
               documentStore: DocumentStore, diagnostics: DiagnosticsStore?) -> Bool {
        guard generation == self.generation, let key = last else { return false }
        switch step {
        case .trust(let table, let facts, let name):
            // Reads judged under another trust or other manifest facts are
            // not "unchanged" however still their files are: forget their
            // fingerprints.
            if (heldTrust != nil && heldTrust != table) || (heldFacts != nil && heldFacts != facts) {
                tokens = [:]
            }
            heldTrust = table
            heldFacts = facts
            guard registryUnreadable != name else { return false }
            registryUnreadable = name
        case .pieces(let reads):
            for read in reads where stale.contains(read.docId) {
                stale.remove(read.docId)
                if case .unchanged = read { continue }
                piecesRead += 1
                // Open during this walk: its live or folded state stands.
                guard !touched.contains(read.docId) else { continue }
                switch read {
                case .read(let docId, let docNotes, let docTasks, let sequence, let text, let token):
                    notes[docId] = docNotes.map { ProjectAnnotation(docId: docId, annotation: $0) }
                    tasks[docId] = docTasks
                    sequences[docId] = sequence
                    paragraphs[docId] = text
                    tokens[docId] = token
                    unreadable.remove(docId)
                case .unreadable(let docId):
                    forget(docId)
                    unreadable.insert(docId)
                case .unchanged:
                    break
                }
            }
        case .figures(let reads):
            figureNotes = reads.notes.reduce(into: [:]) { out, pair in
                out[pair.key] = pair.value.map { ProjectAnnotation(docId: pair.key, annotation: $0) }
            }
            figureUnreadable = reads.unreadable
            figureCells = reads.cells
            // What the walk read, not what the manifest says now: a figure
            // added or removed while it ran makes the figures stale again.
            heldFigureIds = reads.figureIds
            figuresStale = (store.manifest.figures ?? []).map(\.id) != reads.figureIds
        }
        let scope = key.read.scope
        snapshot = gather(scope: scope,
                          live: ResolvePane.livePieces(scope: scope, documentStore: documentStore),
                          store: store, documentStore: documentStore, diagnostics: diagnostics)
        return remark()
    }

    /// **Run `request`'s walk**: off the main actor, each step folded in as
    /// one main-actor step, yielding between steps so a keystroke or a frame
    /// queued behind one runs before the next. What the watch's walk task
    /// does, and what the tests drive.
    func run(_ request: ResolveChunkedWalk.Request, store: ProjectStore, documentStore: DocumentStore,
             diagnostics: DiagnosticsStore?, chunkSize: Int = ResolveChunkedWalk.chunkSize,
             onProducerExit: (@Sendable () -> Void)? = nil,
             onChange: () -> Void = {}) async {
        var inputs = ResolveChunkedWalk.inputs(for: request, store: store)
        inputs.chunkSize = chunkSize
        await run(request, steps: ResolveChunkedWalk.steps(inputs, onExit: onProducerExit), store: store,
                  documentStore: documentStore, diagnostics: diagnostics, onChange: onChange)
    }

    /// The loop over any source of steps — the walk's stream in production,
    /// a source that never suspends in the test that pins the yield.
    func run<Steps: AsyncSequence>(
        _ request: ResolveChunkedWalk.Request, steps: Steps, store: ProjectStore,
        documentStore: DocumentStore, diagnostics: DiagnosticsStore?, onChange: () -> Void = {}
    ) async where Steps.Element == ResolveChunkedWalk.Step, Steps.Failure == Never {
        for await step in steps {
            // A cancelled walk applies nothing more, even what is buffered.
            if Task.isCancelled { break }
            if apply(step, generation: request.generation, store: store,
                     documentStore: documentStore, diagnostics: diagnostics) { onChange() }
            await Task.yield()
        }
        guard !Task.isCancelled else { return }
        finish(generation: request.generation)
    }

    /// The walk `generation` ended (or was cut short): ask again for
    /// whatever is still stale.
    func finish(generation: Int) {
        guard generation == self.generation else { return }
        pendingRequest = nil
        if let last, !stale.isEmpty || figuresStale {
            requestWalk(order: last.read.scope.docIds)
        } else {
            hasFinishedAWalk = true
        }
    }

    /// **Whether the window's first walk has read every piece** (shell p4
    /// Task 6 fix round 2, N4). Until then a piece not yet reached is simply
    /// absent from the snapshot, so "nothing here" is not yet an answer.
    /// Monotonic: a later walk replaces entries and never drops one.
    private(set) var hasFinishedAWalk = false

    // MARK: - Helpers

    /// The scope's pieces a walk can read: those with a file (the store's
    /// walk skips a path-less item the same way).
    private func readableDocIds(scope: ResolveScope, structure: [StructureItem]) -> Set<String> {
        if let held = readableHeld, held.structure == structure { return held.ids }
        let withFile = Set(TreeWalk.collect(in: structure) { $0.type == .document && $0.path != nil }.map(\.id))
        let ids = Set(scope.docIds).intersection(withFile)
        readableHeld = (structure, ids)
        return ids
    }
    private var readableHeld: (structure: [StructureItem], ids: Set<String>)?

    private func requestWalk(order: [String]) {
        generation += 1
        touched = Set(lastLive.keys)
        walksRequested += 1
        // Pieces never read (or whose fingerprint was dropped) first, then
        // those held, which the walk only checks: a walk restarted by a steady
        // cadence of events always makes progress on what it has not read.
        let wanted = order.filter(stale.contains)
        let docIds = wanted.filter { tokens[$0] == nil } + wanted.filter { tokens[$0] != nil }
        pendingRequest = ResolveChunkedWalk.Request(
            generation: generation, docIds: docIds, readsFigures: figuresStale,
            known: tokens, knownTrust: heldTrust, knownFacts: heldFacts)
    }

    private func fold(_ docId: String, _ piece: ResolveLivePiece) {
        notes[docId] = piece.notes.map { ProjectAnnotation(docId: docId, annotation: $0) }
        tasks[docId] = piece.todos
        sequences[docId] = piece.sequence
        paragraphs[docId] = piece.paragraphs
        tokens[docId] = nil
        unreadable.remove(docId)
        stale.remove(docId)
    }

    private func forget(_ docId: String) {
        notes[docId] = nil
        tasks[docId] = nil
        sequences[docId] = nil
        paragraphs[docId] = nil
        tokens[docId] = nil
        unreadable.remove(docId)
    }

    /// The held reads as the store's walk would have returned them, gathered
    /// as To resolve gathers (`ResolveReader.read`'s rule): each open piece
    /// answers for itself, and a closed piece's text is the walk's while its
    /// file set has not moved, else read through the derived cache.
    private func gather(scope: ResolveScope, live: [String: ResolveLivePiece], store: ProjectStore,
                        documentStore: DocumentStore, diagnostics: DiagnosticsStore?) -> ResolveSnapshot {
        guard !scope.docIds.isEmpty || scope.includesBookLevel else { return .empty }
        var annotations: [ProjectAnnotation] = []
        var unreadableIds: [String] = []
        var heldTasks: [WriterTask] = []
        for docId in scope.docIds {
            annotations += notes[docId] ?? []
            heldTasks += tasks[docId] ?? []
            if unreadable.contains(docId) { unreadableIds.append(docId) }
        }
        if let registryUnreadable { unreadableIds.append(registryUnreadable) }
        for figure in store.manifest.figures ?? [] { annotations += figureNotes[figure.id] ?? [] }
        // A figure the manifest no longer holds names nothing (a deleted
        // unreadable figure leaves no ring on the Book).
        let figureIds = Set((store.manifest.figures ?? []).map(\.id))
        unreadableIds += figureUnreadable.filter(figureIds.contains)
        let walk = ProjectAnnotationsSnapshot(annotations: annotations, unreadableDocIds: unreadableIds,
                                              sequences: sequences, figureCells: figureCells)
        let liveFindings: ((String, (String) -> String?) -> [Diagnostic])? = diagnostics.map { diagnostics in
            { docId, currentText in diagnostics.live(docId: docId, currentText: currentText) }
        }
        var currentTokens: [String: DerivedManuscriptCache.Token]?
        let held = paragraphs
        let heldTokens = tokens
        return ResolveReader.gather(
            scope: scope,
            annotations: ResolveReader.overlaying(walk, live: live),
            tasks: ResolveReader.overlaying(heldTasks + bookTasks, live: live),
            figureOwners: ProjectStore.figureNoteOwners(store.manifest.figures ?? []),
            liveFindings: liveFindings,
            paragraphs: { docId in
                if let piece = live[docId] { return piece.paragraphs }
                if let text = held[docId], let token = heldTokens[docId] {
                    if currentTokens == nil {
                        currentTokens = DerivedManuscriptCache.tokens(forDocIds: Array(heldTokens.keys),
                                                                      in: store.url)
                    }
                    if currentTokens?[docId] == token { return text }
                }
                return try currentParagraphState(documentId: docId, store: store,
                                                 documentStore: documentStore, projectURL: store.url).paragraphs
            })
    }

    private func remark() -> Bool {
        guard let key = last else { return false }
        let marks = ResolvePresence.marks(
            snapshot, structure: key.structure, figureOwners: key.figureOwners,
            sceneIndex: ResolvePresence.sceneIndex(snapshot, scope: key.read.scope, script: key.script))
        let toDos = ResolvePresence.openToDos(snapshot.items, figureOwners: key.figureOwners)
        let changed = marks != self.marks || toDos != openToDos
        self.marks = marks
        openToDos = toDos
        return changed
    }
}

/// **The watch: the reader, keyed, on the window** (tripwires 4, 30). One
/// `update` per key change, then the walk it asks for, off the main actor,
/// folded in a chunk per step; a burst of closed-piece annotation events is
/// coalesced into one token move (`ResolvePresenceReader.coalesce`), so a
/// round minting into thirty closed chapters costs one walk, not thirty. The
/// sidecars are read off the main actor. Writes `BinderTreeSectionsState
/// .presence` and `.openToDos` (Status's column) only when they change.
/// Draws nothing; the window's first frame and first keystroke never wait
/// on it.
struct ResolvePresenceWatch: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    let url: URL
    let window: NSWindow?
    let state: BinderTreeSectionsState
    let diagnostics: DiagnosticsStore?
    let script: FountainScript?
    var compileProblems: Bool = false

    @State private var reader = ResolvePresenceReader()
    /// The editions' own half (shell p4 Task 6): languages whose latest
    /// rounds leave something, and whether a design proposal waits — read
    /// once per `EditionMarkKey`, the ledgers off the main actor.
    @State private var roundsLeaveSomething: Set<String> = []
    @State private var designPending = false
    /// Languages a brief proposal waits for (fix round I4).
    @State private var proposedBriefs: Set<String> = []
    @State private var editionHeard = 0
    /// The walk the reader asked for.
    @State private var request: ResolveChunkedWalk.Request?
    /// Annotation events heard about documents no window holds open.
    @State private var heard = 0
    /// The token the read is keyed on: `heard`, once a burst has settled.
    @State private var annotationsToken = 0

    private var key: ResolvePresenceReader.Key {
        ResolvePresenceReader.key(store: store, documentStore: documentStore, diagnostics: diagnostics,
                                  annotationsToken: annotationsToken, script: script)
    }

    /// What the editions' half is read on: the edition rows, the book's
    /// pieces and the events heard — values the body already holds. No file
    /// is stat'ed and no tree walked to build it (closing review M2,
    /// tripwire 4): every ledger write this Mac makes is announced
    /// (`.maughamTranslationRoundEnded`, `.maughamTranslationRoundChanged`),
    /// and the pieces are the presence key's own scope, walked once.
    struct EditionMarkKey: Equatable {
        let languages: [String]
        let docIds: [String]
        let heard: Int
    }

    static func editionMarkKey(editionRows: [TreeEditionRows.Row], docIds: [String],
                               heard: Int) -> EditionMarkKey {
        EditionMarkKey(languages: editionRows.filter { !$0.isSource }.map(\.language),
                       docIds: docIds, heard: heard)
    }

    private func publish() {
        var marks = reader.marks
        marks.editions = ResolveEditionItems.markedEditions(
            editions: state.editionRows.map { ($0.language, $0.isSource) },
            questionLanguages: ResolveEditionItems.questionLanguages(reader.snapshot),
            roundsLeaveSomething: roundsLeaveSomething,
            bookLevel: designPending || compileProblems)
        marks.proposedBriefs = proposedBriefs
        if state.presence != marks { state.presence = marks }
        if state.openToDos != reader.openToDos { state.openToDos = reader.openToDos }
        let reading = ResolvePresence.bookReading(reader.snapshot, complete: reader.hasFinishedAWalk)
        if state.bookReading != reading { state.bookReading = reading }
    }

    var body: some View {
        let key = key
        // The Book scope's own pieces — the list's `docIds` (review M2),
        // from the presence key's one walk.
        let editionMarkKey = Self.editionMarkKey(editionRows: state.editionRows,
                                                 docIds: key.read.scope.docIds, heard: editionHeard)
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: key) {
                if reader.update(key, store: store, documentStore: documentStore,
                                 diagnostics: diagnostics) { publish() }
                request = reader.pendingRequest
            }
            // The walk, off the main actor; each chunk is one main-actor step.
            .task(id: request) {
                guard let request else { return }
                await reader.run(request, store: store, documentStore: documentStore,
                                 diagnostics: diagnostics, onChange: publish)
                guard !Task.isCancelled else { return }
                // The walk's end may complete the book's first reading (N4).
                publish()
                self.request = reader.pendingRequest
            }
            // The sidecars the strains are read from, off the main actor; a
            // load moves `diagnostics.version`, which moves the key.
            .task(id: key.read.scope) {
                await diagnostics?.loadInBackground(
                    docIds: key.read.scope.docIds.filter { !DocumentClass.isFigureDocId($0) })
            }
            // The editions' half: the ledgers off the main actor, the
            // proposals' listing on it (a few small files).
            .task(id: editionMarkKey) {
                let key = editionMarkKey
                let leaving = await Task.detached(priority: .utility) {
                    ResolveEditionItems.languagesLeavingSomething(
                        projectURL: url, languages: key.languages, docIds: key.docIds)
                }.value
                guard !Task.isCancelled else { return }
                roundsLeaveSomething = leaving
                designPending = ResolveEditionItems.hasPendingProposal(projectURL: url)
                proposedBriefs = ResolvePresence.proposedBriefLanguages(
                    StatementProposalStore(projectURL: url).pendingAll())
                publish()
            }
            .onChange(of: compileProblems) { _, _ in publish() }
            .onChange(of: state.editionRows) { _, _ in publish() }
            .onProjectEvent(.maughamDesignProposalsChanged, url: url, window: window) { _ in
                editionHeard &+= 1
            }
            // A brief proposed, adopted or discarded: the "Proposed" word.
            .onProjectEvent(.maughamStatementProposalsChanged, url: url, window: window) { _ in
                editionHeard &+= 1
            }
            .onProjectEvent(.maughamTranslationRoundEnded, url: url, window: window) { _ in
                editionHeard &+= 1
            }
            // A verb rewrote a round's record: the edition's mark reads again
            // (review I1 — a dot never stands over an empty list).
            .onProjectEvent(.maughamTranslationRoundChanged, url: url, window: window) { _ in
                editionHeard &+= 1
            }
            // A burst settles before its one walk.
            .task(id: heard) {
                guard heard != annotationsToken else { return }
                try? await Task.sleep(for: ResolvePresenceReader.coalesce)
                guard !Task.isCancelled else { return }
                annotationsToken = heard
            }
            // A note changed where no window holds the document — a closed
            // piece, a figure's stream, a peer's sync. To resolve's rule.
            .onProjectEvent(.maughamAnnotationsChanged, url: url, window: window) { note in
                if ResolvePane.annotationsEventMovesTheWalk(
                    docId: note.userInfo?[MaughamEvent.annotationDocIdKey] as? String,
                    documentStore: documentStore) {
                    heard &+= 1
                }
            }
    }
}
