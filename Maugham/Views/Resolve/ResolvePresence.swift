import SwiftUI
import MaughamCore

/// **Which rows of the tree have something to resolve** (shell plan 4, Task
/// 3; ADR 0035's "one 'to resolve' dot on rows"). Pure: one read of the
/// Book's scope (`ResolveReader`) in, the marked rows out. A row looks its
/// own id up in `Marks`; nothing is computed per row (tripwire 4).
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
/// - A reference piece is never marked; an unreadable piece carries no mark
///   and no claim of emptiness (RULING-54).
enum ResolvePresence {

    struct Marks: Equatable {
        /// Marked pieces and Parts, by structure id.
        var pieces: Set<String>
        /// The Book row.
        var book: Bool
        /// Marked scenes, indexed as `FountainScript.sceneSummaries()` is.
        var scenes: Set<Int>

        static let none = Marks(pieces: [], book: false, scenes: [])
    }

    /// The marks `snapshot` (the Book's scope) puts on the tree.
    ///
    /// - Parameters:
    ///   - figureOwners: `ProjectStore.figureNoteOwners(manifest.figures)`.
    ///   - sceneIndex: `ParagraphOffsets.sceneIndex` of the screenplay's one
    ///     script (`sceneIndex(_:scope:script:)`), nil elsewhere.
    static func marks(_ snapshot: ResolveSnapshot, structure: [StructureItem],
                      figureOwners: [String: String?], sceneIndex: [String: Int]?) -> Marks {
        let markable = Set(TreeWalk.collect(in: structure) {
            $0.type == .document && $0.pieceKind != .reference
        }.map(\.id))
        let unreadable = Set(snapshot.unreadableDocIds)
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
            guard markable.contains(owner), !unreadable.contains(owner) else { continue }
            pieces.insert(owner)
            if let sceneIndex, owner == docId,
               let paragraph = item.paragraphId, let scene = sceneIndex[paragraph] {
                scenes.insert(scene)
            }
        }

        var marks = Marks(pieces: pieces, book: bookOwn || !pieces.isEmpty, scenes: scenes)
        let parts = TreeWalk.collect(in: structure) { $0.type == .group }.map(\.id)
        for part in parts where partHasMark(part, marks: marks, structure: structure) {
            marks.pieces.insert(part)
        }
        return marks
    }

    /// Whether the Part `groupId` carries the mark: a piece anywhere under it
    /// does.
    static func partHasMark(_ groupId: String, marks: Marks, structure: [StructureItem]) -> Bool {
        guard let group = TreeWalk.find(id: groupId, in: structure), group.type == .group else {
            return false
        }
        return !TreeWalk.collect(in: group.children ?? []) {
            $0.type == .document && marks.pieces.contains($0.id)
        }.isEmpty
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

/// **The mark itself**: one small dot at the row's trailing edge, never a
/// number. Accent ink, so it never reads as the stage dot (a draft's is grey
/// and leads a chapter row); on a selected row's accent fill it turns
/// `.primary` (white), as the row's text does. With nothing waiting, nothing
/// is drawn.
struct ResolvePresenceDot: View {
    /// The words the dot says to VoiceOver.
    static let label = "Something to resolve"
    static let diameter: CGFloat = 5

    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Circle()
            .fill(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.accentColor))
            .frame(width: Self.diameter, height: Self.diameter)
            .accessibilityElement()
            .accessibilityLabel(Self.label)
    }
}

// MARK: - The window's read

/// **The presence read, mounted on the window** (`ProjectWindow.body`), so it
/// runs whether or not the tree is drawn. Load-bearing: without the mount
/// line every pure test stays green and no row ever carries the mark.
struct ResolvePresenceWiring: ViewModifier {
    let store: ProjectStore?
    let documentStore: DocumentStore?
    let url: URL
    let window: NSWindow?
    let state: BinderTreeSectionsState
    let diagnostics: DiagnosticsStore?
    /// The window's `lastParsedScript`.
    let script: FountainScript?

    func body(content: Content) -> some View {
        content.background {
            if let store, let documentStore {
                ResolvePresenceWatch(store: store, documentStore: documentStore, url: url,
                                     window: window, state: state, diagnostics: diagnostics,
                                     script: script)
            }
        }
    }
}

/// **One read per key, on the window** (tripwires 4, 30): To resolve's own
/// refresh at the Book's scope — its read key (the scope, the annotation
/// event token, the open pieces, the Book's to-dos, the sidecar, the
/// passes), the open pieces' note and to-do versions (the live splice) and
/// the parsed script — with the walks held between keys exactly as the pane
/// holds them. Writes `BinderTreeSectionsState.presence` only when the marks
/// change. Draws nothing.
struct ResolvePresenceWatch: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    let url: URL
    let window: NSWindow?
    let state: BinderTreeSectionsState
    let diagnostics: DiagnosticsStore?
    let script: FountainScript?

    @State private var annotationsToken = 0
    @State private var walks = ResolveWalkHold()
    @State private var held = ResolveSnapshot.empty
    @State private var lastKey: ResolveListKey?

    private var scope: ResolveScope {
        ResolveScope.of(.project, structure: store.manifest.structure,
                        projectType: store.manifest.type)
    }

    private var key: ResolveListKey {
        let scope = scope
        // The local name only sorts To resolve's own chips; the marks never
        // read it, so it is held constant here.
        return ResolvePane.listKey(
            scope: scope, annotationsToken: annotationsToken, store: store,
            documentStore: documentStore, diagnostics: diagnostics, localName: "",
            script: ResolvePane.script(for: scope, structure: store.manifest.structure,
                                       openDocId: nil, script: script))
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: key) { refresh(key) }
            // The sidecars the strains are read from — never from `body`; a
            // load moves `diagnostics.version`, which moves the key.
            .task(id: scope) {
                if let diagnostics { ResolveReader.loadFindings(scope: scope, diagnostics: diagnostics) }
            }
            // A note changed where no window holds the document — a closed
            // piece, a figure's stream, a peer's sync. To resolve's rule.
            .onProjectEvent(.maughamAnnotationsChanged, url: url, window: window) { note in
                if ResolvePane.annotationsEventMovesTheWalk(
                    docId: note.userInfo?[MaughamEvent.annotationDocIdKey] as? String,
                    documentStore: documentStore) {
                    annotationsToken &+= 1
                }
            }
    }

    private func refresh(_ key: ResolveListKey) {
        let step = ResolvePane.refreshStep(key, last: lastKey)
        var walks = walks
        let fresh = ResolvePane.refreshed(held, step: step, key: key.regroup.read, walks: &walks,
                                          store: store, documentStore: documentStore,
                                          diagnostics: diagnostics)
        self.walks = walks
        held = fresh
        lastKey = key
        let scope = key.regroup.read.scope
        let marks = ResolvePresence.marks(
            fresh, structure: store.manifest.structure,
            figureOwners: ProjectStore.figureNoteOwners(store.manifest.figures ?? []),
            sceneIndex: ResolvePresence.sceneIndex(fresh, scope: scope, script: key.regroup.script))
        if state.presence != marks { state.presence = marks }
    }
}
