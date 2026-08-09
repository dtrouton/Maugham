import Foundation
import MaughamCore

/// **Where the parsed screenplay a window is showing comes from when no editor
/// is mounted to parse it.**
///
/// `ProjectWindow.lastParsedScript` had exactly one producer: a mounted
/// `EditorCoordinator`, which exists only inside `EditorHost`, which
/// `ProjectWindow.editorPane` mounts only when the centre column is a document.
/// Plan centres the canvas, so a screenplay's `SceneNavigatorPane` in Plan got
/// `script: nil` and drew *"No scenes yet — Open the script, then type INT. or
/// EXT."* over a script with ninety scenes. One visit to Author populated the
/// value for the rest of the window's life, which made a deterministic defect
/// look intermittent (slice 2 review, F1).
///
/// **This is a second PRODUCER, not a second value.** `lastParsedScript` stays
/// the window's one piece of state and the one thing `BinderPaneToggle` reads;
/// the two producers are ordered by `needsDerivation`, which is false the moment
/// anything has produced a parse. The editor therefore always wins, which is
/// right — it sees keystrokes the op log has not absorbed yet (the burst window)
/// — and there is no pair of values that can disagree. Tripwire 6 is about
/// exactly the other shape.
///
/// **ADR 0018 / tripwire 20: the `.fountain` on disk is never read.** An OPEN
/// document answers from its live `Document.displayText`; a closed one from the
/// op log through `ProjectStore.derivedCache`, whose validity token is the op-log
/// file set's `(path, mtime, size)`. The `.md`/`.fountain` lags the op log by the
/// autosave debounce and, since ADR 0019, carries no anchors to reconcile
/// against — reading it here would reopen the disagreement ADR 0018 closed.
///
/// **Tripwire 4: one parse per arrival, not one per row and not one per body
/// pass.** `derive` is called from a `.task(id:)` keyed on `needsDerivation`, so
/// it runs when the surface that needs it appears and not again;
/// `SceneNavigatorPane` then computes every scene's page and length in its own
/// single O(document) pass. The op-log decode behind it is cached per
/// (doc, op-log-file-set), so a segment flipped away from and back to costs
/// nothing even if the parse is re-requested.
enum ScreenplayScriptSource {

    /// Whether the window must derive the script itself.
    ///
    /// Three conditions, and each one is load-bearing. The census over the whole
    /// `(persona, project type)` product —
    /// `ScreenplayScriptSourceTests.test_onlySluglineSurfacesWithNoEditorBehindThemDerive`
    /// — is what holds them to exactly one derive, and it has now caught a
    /// widening twice.
    ///
    /// - `existing == nil` — the precedence rule. A mounted editor's parse is
    ///   fresher by construction, so the derivation is a fallback and never an
    ///   overwrite.
    /// - the project's tree IS the slugline navigator
    ///   (`TreePane(for:) == .sceneNavigator`) — a novel's tree and a
    ///   Collection's pieces list have no use for a Fountain parse, and deriving
    ///   one would be an op-log decode nobody reads. **This is where
    ///   `BinderSegment.showsSceneNavigator(for:)` went** (stage 2b Task 6): it
    ///   asked the segment a question only the project type could answer.
    /// - the persona centres the canvas — which is what says *there is no editor
    ///   here to produce it*. Author shows the same navigator but mounts
    ///   `EditorHost` beside it, so the coordinator posts within a frame and a
    ///   derivation there would be duplicate work racing a fresher value.
    ///
    /// **A fourth condition died with the strip in Task 7**, and it is worth
    /// recording why it was ever there. Plan's left column was four panes, and
    /// only one of them drew `TreePane`'s answer — the Canvas tab put the old
    /// research pane there instead — so the term was `interimSegment == .tree`,
    /// spelled as the case rather than through a predicate because the obvious
    /// predicate ("is the left pane a tree") was wrong and the census caught it:
    /// the manuscript segment mounted `BinderView` unconditionally, so on a
    /// screenplay it showed a one-row novel binder and never sluglines. With one
    /// left column per persona, a Plan screenplay's left column IS the navigator
    /// and the term has nothing left to exclude.
    static func needsDerivation(persona: Persona,
                                projectType: ProjectType,
                                existing: FountainScript?) -> Bool {
        existing == nil
            && TreePane(for: projectType) == .sceneNavigator
            && persona.centresTheCanvas
    }

    /// The project's one script, parsed — or `nil` when the project has no
    /// document at all (a state `SceneNavigatorPane` already draws, with no
    /// script row).
    ///
    /// **One document, because a screenplay is one `.fountain`** (the Phase 3d
    /// invariant). The same `TreeWalk.first` derivation `BinderPaneToggle` uses
    /// for the script row's `documentID`, so the parse and the row can never be
    /// about different files.
    ///
    /// The open-document lookup mirrors `DocumentTools.emitManuscriptDoc`
    /// exactly, including the path fallback and its identity check: the registry
    /// is keyed by path, and a rename can update the manifest before the registry
    /// is re-keyed, so resolving by path alone would silently take a different
    /// document's text (tripwire 22's window, from the registry side).
    @MainActor
    static func derive(store: ProjectStore) -> FountainScript? {
        guard let item = TreeWalk.first(in: store.manifest.structure,
                                        where: { $0.type == .document })
        else { return nil }
        let text: String
        if let ds = store.documentStore,
           let doc = ds.document(forDocId: item.id)
               ?? item.path.flatMap({ ds.document(for: $0) })
                   .flatMap({ $0.docId == item.id ? $0 : nil }) {
            // The live document's DISPLAY form — the same string the editor's
            // own coordinator tokenizes, so a slugline's line location means the
            // same thing to both producers.
            text = doc.displayText
        } else {
            // RULING-54 lenient, reason recorded: the Scenes sidebar has no
            // per-doc error surface; an unreadable doc lists no scenes here
            // and refuses loudly the moment the writer opens it.
            guard let derived = try? store.derivedCache.displayText(
                forDocId: item.id, in: store.url) else { return FountainScript() }
            text = derived
        }
        return FountainTokenizer().parse(text)
    }
}
