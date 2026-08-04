import SwiftUI
import MaughamCore
import AppKit
import UniformTypeIdentifiers
import os

private let _statementEditorLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "StatementEditor")

/// Where a statement's text goes on its way from the editor to the op log
/// (M1A, spec §4.2).
///
/// **One binding, two destinations, never both.** A statement's `Document`
/// cannot exist before the writer types — absence is valid, and the pane must
/// not mint a file just because someone looked at it (§4.3). So until the first
/// keystroke there is nothing to write to, and the text lives here as `draft`;
/// from the moment a `Document` is bound, every write goes to it and `draft` is
/// empty and stays empty. The two are mutually exclusive by construction, which
/// is what keeps this from being the second text mirror tripwire 6 forbids —
/// `text` has exactly one source at any instant.
///
/// **Words with no file yet belong to the SCOPE they were typed for, not to the
/// pane that was showing it** (issue #21). See `typedBeforeItsFileExisted`.
///
/// It is a reference type on purpose. `EditorSurface.makeCoordinator()` captures
/// its `Binding` **once**, at mount; a binding closing over a `@State Document?`
/// would keep writing to the nil it saw then. Routing through this box is what
/// lets the mint happen *without remounting the editor mid-keystroke*, which is
/// the shape that loses characters.
@MainActor
final class StatementTextTarget {

    private(set) var document: Document?
    /// The statement the bound `Document` belongs to, so the host can withdraw
    /// its registration from `ProjectStore` without threading the id through a
    /// second piece of view state.
    private(set) var statementID: String?

    /// The words typed for a scope whose file does not exist yet, **keyed by the
    /// scope they were typed for**.
    ///
    /// Still one copy of any given run of characters, and still not the second
    /// text mirror tripwire 6 forbids: an entry is *removed* in the same
    /// statement that writes it into a `Document` (`deposit`), so the words are
    /// here or in the file and never in both, and `text` reads exactly one of
    /// them at any instant. Two entries are two different scopes' words, which is
    /// not a mirror of anything.
    ///
    /// **Keyed rather than a single `draft`, and that is the whole of issue
    /// #21.** A single value had to be emptied when the pane moved on, and
    /// `reconcile`'s `release()` emptied it *mid-mint* — while the detached
    /// `Task` that was creating the file for those very characters was still in
    /// flight. Type one character into a chapter with no intent, click another
    /// row, and the statement was created and the character was not in it. No
    /// error, nothing in the op log.
    ///
    /// Keyed, there is nothing to empty. `draft` reads the entry for the scope
    /// the pane is on NOW, so the outgoing scope's words stop being *visible* the
    /// moment `wantedScope` moves — which is all `release()` was ever trying to
    /// achieve — while the words themselves wait, under their own scope's name,
    /// for the mint that is already on its way to collect them. The obvious
    /// repair (snapshot the draft at `mintAndBind` and hand it to `bind`) is the
    /// one this deliberately is not: a snapshot is a value that keeps describing
    /// what the box held at a past instant, which is the exact family of defect
    /// this file has produced seven of.
    ///
    /// An entry outliving a FAILED mint is correct rather than a leak: the pane
    /// returning to that scope shows those words again and the next keystroke
    /// retries the mint, which is what `onUnboundWrite` firing on every write is
    /// for.
    private var typedBeforeItsFileExisted: [String: String] = [:]

    /// The scope key this box is currently FOR, or nil when the pane has left.
    ///
    /// **A destination, named up front, and not a proxy for one.** It is set by
    /// `reconcile` before its first suspension and cleared by `leave()`, and an
    /// in-flight `load` compares the scope it was started for against it before
    /// binding — see `StatementEditorHost.loadMayBind`. It lives here rather
    /// than in the host's `@State` because it is a fact about THIS box: the box
    /// is what two overlapping loads share (`StatementPane` mounts the host
    /// without `.id()`, deliberately), so the answer to "who owns you now"
    /// belongs on the thing being written into rather than on a view value a
    /// superseded task holds a copy of.
    ///
    /// It is also the key `draft` reads and `write` files under: the scope this
    /// box is FOR is, by definition, the scope the writer's keystrokes are for.
    var wantedScope: String?

    /// Fired on every write that lands in `draft` — i.e. while the statement
    /// still has no file. The host guards it; firing on every write (rather
    /// than only the first) is what lets a failed mint retry on the next
    /// keystroke instead of stranding the writer's words in memory.
    var onUnboundWrite: (() -> Void)?

    /// What the editor shows. One source at a time: the Document once bound,
    /// the pre-mint draft before that.
    var text: String { document?.displayText ?? draft }

    /// The words typed for the scope this box is currently FOR, and not yet in
    /// any file. Empty for a scope nobody has typed into, and empty for a box
    /// that has left (`leave()` clears `wantedScope`) — the words of the scope it
    /// left are still in the map, addressed by their own name.
    var draft: String {
        guard let wantedScope else { return "" }
        return typedBeforeItsFileExisted[wantedScope] ?? ""
    }

    /// Whether any words are waiting for `scope`'s file to exist.
    ///
    /// A predicate rather than an accessor on purpose: nothing outside this box
    /// takes the text out except by handing over the `Document` it goes into.
    func hasWordsWaiting(for scope: String) -> Bool {
        !(typedBeforeItsFileExisted[scope] ?? "").isEmpty
    }

    /// The statement whose **live** `Document` this box holds, or nil.
    ///
    /// The question a load re-asks after taking the open gate — see
    /// `StatementEditorHost.gateArrival`. Live rather than merely present,
    /// because the invariant is about two `Document`s writing one path: a
    /// closed one is husked and weightless (`setFullText` no-ops on it), so a
    /// box holding one is a box a load may fill.
    ///
    /// It can answer with `statementID` because `document` and `statementID`
    /// are set and cleared as a PAIR — `bind` takes both, `release()` drops
    /// both, and there is no third writer of either.
    var liveStatementID: String? {
        guard let document, !document.isClosed else { return nil }
        return statementID
    }

    /// The sanctioned binding shape, and the only mutation path
    /// (`EditorHost.swift:13-15`): `Document.setFullText` writes `displayText`
    /// exactly once at the end, which is what keeps the milestone-1e
    /// binding-loop race closed.
    func write(_ newText: String) {
        if let document {
            document.setFullText(newText)
            return
        }
        guard let wantedScope else {
            // Unreachable while the editor is mounted: `reconcile` sets
            // `wantedScope` before `resolvedScope`, and `resolvedScope` is the
            // whole mount condition, so a surface that can be typed into always
            // has a scope to file its words under. Logged rather than assumed,
            // because the alternative is a keystroke with nowhere to go.
            _statementEditorLog.error(
                "a statement keystroke arrived with no scope to file it under")
            return
        }
        typedBeforeItsFileExisted[wantedScope] = newText
        guard !newText.isEmpty else { return }
        onUnboundWrite?()
    }

    /// Put the words typed for `scope` into the file that now exists for it, and
    /// take them out of the box in the same statement.
    ///
    /// **Appended to whatever the document already holds; never a replacement.**
    /// `setFullText` is whole-text replacement, and this used to hand it the
    /// draft alone on the stated grounds that a just-minted statement's document
    /// is empty — which was true while the pane was the only thing that could
    /// create one. **M1A Task 7 made the canvas a second creator**, and
    /// `createStatement` is idempotent: a promotion into a scope this pane is
    /// mounted on but has not bound (no statement existed when `reconcile` ran,
    /// and nothing re-runs it) creates the statement WITH the promoted card in
    /// it, and the writer's next keystroke arrives here as a one-character draft.
    /// Replacing left them holding that character and nothing else. **No timing
    /// window is involved** — promote, leave, come back, type.
    ///
    /// **Addressed by scope, which is what makes it safe to call from every
    /// arrival** (issue #21). It used to be a `carryingDraft` flag on `bind`, and
    /// a flag is a claim about *whose* words are in the box that the box itself
    /// could not check: the caller had to be right. Keyed, the box answers — a
    /// deposit for one scope cannot take another scope's words even if the pane
    /// has moved twice since, and a scope with nothing waiting is a no-op, so the
    /// caller no longer has to know which case it is in.
    func deposit(into document: Document, for scope: String) {
        guard let words = typedBeforeItsFileExisted.removeValue(forKey: scope),
              !words.isEmpty else { return }
        let existing = document.displayText
        document.setFullText(existing.isEmpty ? words : existing + "\n\n" + words)
    }

    /// Bind the loaded `Document` for `scope`, and hand it whatever was typed
    /// for that scope before it existed.
    ///
    /// It is fixed here rather than at `mintAndBind` because this is the one
    /// place a draft meets a document: the caller-side fix ("look the statement
    /// up first and don't carry the draft") closes the one door that exists today
    /// and throws the writer's keystroke away doing it, while this keeps both
    /// texts and closes the door for the next creator too. In the case this was
    /// written for — a genuinely new statement, whose file is empty scaffolding —
    /// the behaviour is unchanged, byte for byte.
    ///
    /// (`reconcile`'s own comment describes this failure arriving through a
    /// different door: a stale `resolvedScope` leaving the pane bound to
    /// nothing over real content. That door is closed by clearing the marker;
    /// this one cannot be, because the pane's belief was true when it formed.)
    func bind(_ document: Document, id: String, for scope: String) {
        deposit(into: document, for: scope)
        self.document = document
        self.statementID = id
    }

    /// Let go of the previous scope's `Document`.
    ///
    /// Called only while the pane is showing its placeholder — i.e. after the
    /// scope changed and before the new one has resolved. Calling it while the
    /// editor is mounted would put an empty surface over real content, and the
    /// next keystroke would write into the wrong statement. **The caller must
    /// have closed the document first**; this only drops the reference.
    ///
    /// **It no longer empties the draft, and that is issue #21's fix at this
    /// end.** It used to, and the words it emptied were the ones a mint was at
    /// that moment creating a file for — the one instant they existed nowhere
    /// else. Nothing needs emptying now: `reconcile` has already moved
    /// `wantedScope` on, so `draft` reads the new scope's entry (empty, for a
    /// scope nobody has typed into) and the outgoing scope's words are addressed
    /// by their own name until their mint collects them.
    func release() {
        document = nil
        statementID = nil
    }
}

/// The editor for one statement — the writer's intent for a document or the
/// project, or the project's visual language (M1A, spec §4.2).
///
/// **Mounts `EditorSurface`, not `EditorHost`.** `EditorSurface` is the clean
/// seam: a `@Binding var text` plus one grouped configuration. This host owns
/// the `Document` and supplies exactly the sanctioned binding and nothing else.
/// A second host with a single binding is not parallel observable state on the
/// first one (tripwire 6); a second *mirror* of the text would be, and there
/// isn't one — see `StatementTextTarget`.
///
/// It adds **no caller of `EditorSurface.applyExternalText`** (tripwire 7): the
/// one production call site stays inside `EditorSurface.updateNSView`.
struct StatementEditorHost: View {
    @Bindable var store: ProjectStore
    let documentStore: DocumentStore
    let kind: Statement.Kind
    let scope: Statement.Scope

    @Environment(UserPreferences.self) private var userPreferences

    /// The one text destination. `@State` so it survives re-renders; not
    /// observable, so nothing here re-renders per keystroke.
    @State private var target = StatementTextTarget()
    /// The scope this host has finished RESOLVING — either its `Document` is
    /// bound, or it has been established that the scope holds no statement at
    /// all. `nil` until the first reconcile, and re-derived on every scope
    /// change. It is the whole mount condition; see `shouldMount`.
    @State private var resolvedScope: String?
    /// The scopes with a mint in flight — **a set rather than a flag, for the
    /// same reason the words are keyed** (issue #21).
    ///
    /// It stops a burst of keystrokes from starting a second attempt at the same
    /// statement. It was a `Bool`, which made that claim about the HOST: while
    /// one scope's mint was in flight (parked behind a promotion on the open
    /// gate, say) a keystroke into a second undeclared scope started no mint at
    /// all, and its words waited in the box for a collector that a second
    /// keystroke would have to summon. A writer typing on has one; a writer who
    /// types one word and clicks away does not, and that is the whole shape of
    /// this issue.
    ///
    /// Two mints in flight for two scopes share nothing: each holds its own
    /// statement's open gate, each deposits under its own scope's name, and
    /// `loadMayBind` can be true for at most one of them.
    @State private var mintingScopes: Set<String> = []
    @State private var editorControl = EditorControl()
    @State private var isDropTargeted = false
    /// Why the last picture did not land, or nil.
    ///
    /// **Cleared in `reconcile`, and that is not housekeeping.** This host is
    /// deliberately not remounted on a scope change (see `reconcile`'s comment on
    /// `.id()`), so every `@State` here outlives one. A refusal left behind is a
    /// sentence about a file the writer dropped on another scope's editor.
    @State private var pictureMessage: String?

    /// Session id stable for the lifetime of this app launch, stamped onto every
    /// op. Declared here rather than shared with `EditorHost`, whose pair is
    /// private; a statement's ops grouping by its own session is harmless (the
    /// session id exists so multi-instance edits can be merged, not to tie a
    /// statement to the manuscript beside it).
    private static let sessionId: String = UUID().uuidString
    private static let deviceId: String = MacDeviceID.current

    /// The registered statement for this scope, or nil. Absence is valid and
    /// mints nothing — `ProjectStore.statement(kind:scope:)` is a pure lookup.
    private var statement: Statement? { store.statement(kind: kind, scope: scope) }

    /// The scope the pane is currently asking for.
    private var scopeKey: String { "\(kind.rawValue)|\(scope.rawValue)" }

    /// Whether there is something to type into: exactly "this scope has been
    /// resolved", and nothing else.
    ///
    /// **It is deliberately NOT derived from the live statement + document.**
    /// That shape — `isBound || statement == nil` — was the first cut, and it is
    /// false for the whole of the mint: `createStatement` appends to
    /// `manifest.statements` and then suspends at `await saveManifest()`, and
    /// `mintAndBind` suspends again at `await Document.load`, so across two
    /// suspensions the statement exists and no `Document` is bound yet. Any body
    /// pass landing in that window unmounts the `EditorSurface` — caret, first
    /// responder and the pane's own undo stack with it — and rebuilds a fresh
    /// one when the bind lands, on the first character of every new statement.
    /// (Measured 2026-08-01: SwiftUI coalesced past the window on this machine
    /// with an empty project, so it did not reproduce as a remount — the
    /// intermediate state was real and simply never rendered. That is timing,
    /// not a guarantee: `saveManifest` writes and coordinates the whole manifest.)
    ///
    /// `resolvedScope` cannot flicker: the mint does not touch it, so once a
    /// scope is mounted it stays mounted until the SCOPE ITSELF changes — which
    /// is the one case that genuinely wants a fresh `Document`, and which
    /// `reconcile` handles by closing the outgoing one first.
    ///
    /// Static and pure so the invariant is asserted deterministically rather
    /// than through a race — `StatementPaneTests` drives it directly.
    static func shouldMount(resolvedScope: String?, scopeKey: String) -> Bool {
        resolvedScope == scopeKey
    }

    /// Whether a `Document` that has just finished loading may be bound into the
    /// pane's one text target (whole-branch review, C1).
    ///
    /// **Two overlapping loads share one `StatementTextTarget`.** `StatementPane`
    /// mounts this host without `.id()` (deliberately — it is how the
    /// close/open ordering was made sequential), so a scope change does not
    /// remount and does not replace `target`. Nothing between `Document.load`'s
    /// suspension and `target.bind` used to ask whether the load was still
    /// wanted, and the ordinary case needs no race the writer has to lose: the
    /// outgoing chapter HAS an intent so its reconcile suspends in file I/O,
    /// while the incoming project scope has none so its reconcile is wholly
    /// synchronous and finishes first, every time. The chapter's `Document` then
    /// landed in the box the pane was showing for the project, nothing
    /// invalidated the body, and one keystroke arrived as
    /// `chapterDocument.setFullText("y")`.
    ///
    /// **Both signals, because neither covers both doors.** `reconcile` is a
    /// `.task(id:)` body and IS cancelled when the scope changes; `mintAndBind`
    /// runs a detached `Task { @MainActor in }` that nothing ever cancels, so on
    /// that path `cancelled` is false forever and only the named destination can
    /// refuse. That is Task 12's lesson — *name your destination, do not ask a
    /// proxy* — applied to the one path Task 12 did not revisit. `resolvedScope`
    /// is exactly the proxy that cannot serve here: during a legitimate load it
    /// is nil, and after a superseding one it is *correct* (it names the new
    /// scope) while the target is what is wrong.
    ///
    /// A nil `paneWants` is the pane having LEFT (`leave()` clears it). Binding
    /// then would register a `Document` in `openStatementDocuments` that nothing
    /// is left to close, which `take`'s own comment records as a live defect
    /// once already.
    ///
    /// Static and pure like `shouldMount`, so the rule is asserted over the
    /// product of its inputs rather than only through the two races that reach
    /// it.
    static func loadMayBind(loadedScope: String, paneWants: String?, cancelled: Bool) -> Bool {
        !cancelled && paneWants == loadedScope
    }

    /// What a load finds when it re-asks the box **after** taking the
    /// statement's open gate.
    enum GateArrival: Equatable {
        /// Nothing live is in the box. Load, and bind as planned.
        case load
        /// This statement's own `Document` is already in the box. There is
        /// nothing to load: the caller's destination is already there, and a
        /// second `Document` on that path is the defect.
        case alreadyBound
        /// Some other statement's live `Document` is in the box. Not ours to
        /// displace.
        case refuse
    }

    /// Whether a load that now holds the open gate should still open a
    /// `Document` (M1A residual 1).
    ///
    /// **`loadMayBind` is not enough, because the two loads can agree.** The
    /// mint's load is uncancellable and names the scope it was started for; the
    /// pane's `reconcile` names the scope it is going to. A writer who types
    /// into an undeclared scope, leaves, and comes BACK gives both of them the
    /// same true answer — no cancellation, and a destination that matches — so
    /// both bind, and the first `Document` is dropped from the box **unclosed**:
    /// two live `Document`s on one path, each with its own `PendingBuffer`,
    /// which is the paragraph loss `ProjectStore.lockStatementOpen` exists to
    /// prevent. It is the same family as the superseded-load defect one level
    /// down — that one was the WRONG scope's document, this one is two of the
    /// right scope's.
    ///
    /// **Re-asked after the gate, which is what makes it a fix rather than a
    /// delay** — `ProjectStore.appendToStatement`'s transient arm is the
    /// discipline being copied. `bind` and `noteStatementDocumentOpened` both
    /// happen inside the gate, so whoever arrives second sees the first's
    /// answer; asked BEFORE the gate the question is the same one the pane
    /// already asked and is no more current for being repeated.
    ///
    /// It asks the BOX rather than the registry, and that distinction is
    /// load-bearing: the registry is store-wide and a live `Document` in it may
    /// belong to somebody else entirely, and `.alreadyBound` claims the caller
    /// can mount over what is there. Only the pane's own box can honour that.
    ///
    /// Static and pure like `shouldMount` and `loadMayBind`, so the rule is
    /// asserted over the product of its inputs rather than only through the
    /// race that reaches it.
    static func gateArrival(liveStatementID: String?, loading id: String) -> GateArrival {
        guard let liveStatementID else { return .load }
        return liveStatementID == id ? .alreadyBound : .refuse
    }

    private var canMount: Bool {
        Self.shouldMount(resolvedScope: resolvedScope, scopeKey: scopeKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if canMount {
                    EditorSurface(
                        // The sanctioned binding, and nothing else. It stays inline
                        // here — this is the fragile data-plane seam (tripwires
                        // 2/3/6/7) and is deliberately not packaged into the
                        // configuration, exactly as `EditorHost` keeps it.
                        text: Binding(
                            get: { target.text },
                            set: { target.write($0) }),
                        configuration: makeSurfaceConfiguration())
                } else {
                    loadingPlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if Self.showsPictureWell(
                kind: kind, resolvedScope: resolvedScope, scopeKey: scopeKey) {
                pictureWell
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { seedControl() }
        .onChange(of: userPreferences.theme) { _, theme in editorControl.theme = theme }
        .onChange(of: effectiveTypography) { _, typography in
            editorControl.typography = typography
        }
        // ONE task per scope, and the only place a Document is opened or closed
        // while the pane lives. See `reconcile`.
        .task(id: scopeKey) { await reconcile() }
        .onDisappear {
            // Leaving the pane (a segment switch, a persona switch, window
            // close) flushes the pending typing burst. `Document.close()` is
            // idempotent, so a spurious fire costs nothing.
            //
            // The registration goes first: a `Document` on its way to being
            // closed must stop being the one a promotion writes into, and the
            // close below is asynchronous.
            if let id = target.statementID { store.forgetStatementDocument(id: id) }
            if let document = target.document {
                Task { await document.close() }
            }
            leave()
        }
        // The manuscript's belt, worn here too: `DocumentStore.close()` closes
        // every REGISTERED Document at quit (`ProjectWindow`'s own
        // `.onGlobalEvent`), and a statement is deliberately in no registry —
        // registering one would put it in `allOpenDocuments()`, which is step 1a
        // of the project Tasks aggregation, contradicting spec §8. So it takes
        // the same best-effort flush directly. Like ProjectWindow's, this is
        // fire-and-forget: NSApplication may give us ~100ms. The real
        // crash-safety net for both is `PendingBuffer`'s 750ms disk mirror.
        .onGlobalEvent(.maughamAppWillTerminate) { _ in
            if let id = target.statementID { store.forgetStatementDocument(id: id) }
            if let document = target.document {
                Task { await document.close() }
            }
            leave()
        }
    }

    /// Stop claiming to be resolved once the `Document` is on its way to being
    /// closed.
    ///
    /// **`resolvedScope` described the resolved SCOPE and not whether this host
    /// was mounted, and nothing cleared it on the way out** (review round 2). A
    /// marker left set over a husked `Document` is a lie with two readers:
    /// `canMount` says yes, and anything asking "is the pane still here" gets the
    /// wrong answer. `⌘⌥N` is what exposed it — `DetailPaneToggle.segmentContent`
    /// gives `.intent` and `.visualLanguage` separate `case` arms, so switching
    /// between them TEARS THIS HOST DOWN rather than reconciling it, and
    /// `.onDisappear` ran while the marker went on naming the scope it had left.
    ///
    /// Cheap and correct on its own terms — the close above is what makes the
    /// claim false, so it is unset in the same breath.
    private func leave() {
        resolvedScope = nil
        // And nothing may bind into the box on the way out. `.task(id:)` is
        // cancelled when this host disappears, so `reconcile`'s own load is
        // covered — but the mint's detached `Task` is not cancelled by anything,
        // and a bind from a dead view registers a `Document` in
        // `openStatementDocuments` that nothing is left to close. See
        // `loadMayBind`.
        target.wantedScope = nil
    }

    private var loadingPlaceholder: some View {
        VStack {
            Text("Loading…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading and minting

    private var effectiveTypography: TypographySettings {
        ProjectStore.effectiveTypography(
            override: store.manifest.typography,
            userDefault: userPreferences.typography)
    }

    private func seedControl() {
        // `onChange` fires on transitions only, so seed from the current
        // sources here. The three off-switches below are constants for this
        // surface, not mirrors: a pane is not the writing surface (§4.2).
        editorControl.theme = userPreferences.theme
        editorControl.typography = effectiveTypography
        editorControl.typewriterScroll = false
        editorControl.sentenceFocus = false
        editorControl.paragraphFocus = false
    }

    /// Bring this host onto the scope the pane is asking for: close whatever was
    /// open, then open what is wanted, **in one function, sequentially**.
    ///
    /// That ordering is the whole point, and it is `EditorHost`'s
    /// (`loadDocumentIfNeeded`, which awaits `prior.close()` before
    /// `Document.load` and says why: closing flushes the pending typing burst,
    /// so a fast-fingered switch never drops unflushed paragraph changes). The
    /// first cut split the two across a `.id()`-driven remount — the outgoing
    /// view's `.onDisappear` firing an unstructured close while the incoming
    /// view's `.task` started a load — with no ordering between them at all. On
    /// an `.id` change SwiftUI inserts the new subtree and removes the old in
    /// the same update, so the load routinely started first, and two `Document`s
    /// could be live on one path, each with its own `PendingBuffer` writing the
    /// same file. Here that is not a race that is won; it is unreachable.
    ///
    /// **Not keyed on the path, and that is tripwire 22 satisfied rather than
    /// dodged.** The tripwire is about a Document binding that must RELOAD when
    /// its file moves; a statement's path does not move when the document it is
    /// about is renamed — identity is the manifest `id` and the path is derived
    /// from the title once, at creation (spec §2.2), which
    /// `test_renamingTheDocumentLeavesItsIntentWhereItIs` drives end to end. If
    /// a mover ever does relocate a statement, the key here becomes the path and
    /// that test is where it will fail.
    private func reconcile() async {
        let key = scopeKey
        // **Re-wired here, per scope, and ABOVE the guard — it was `.onAppear`,
        // once, and that was a live defect.** `mintAndBind` is a method on this
        // view, which is a STRUCT, so `{ mintAndBind() }` captures the whole
        // value — including `scope` — from the body pass that made it. Wired
        // once at appear it went on naming that first scope for the pane's whole
        // life: switch from the project to a chapter, type into the chapter's
        // empty editor, and `createStatement` was asked for the PROJECT's
        // statement and the writer's chapter sentence went into it.
        // (`test_typingIntoANewlySelectedScopeMintsThatScopesStatement`.)
        //
        // `.task(id: scopeKey)`'s closure is rebuilt every body pass, so the
        // `self` reaching here is current — and no keystroke can outrun it,
        // because the editor mounts only on `resolvedScope`, which nothing but
        // this function sets. Above the guard because a `.task` restart that
        // early-returns (the writer left the pane and came back to the same
        // scope) must still leave the wiring pointing at a live value.
        target.onUnboundWrite = { mintAndBind() }
        guard resolvedScope != key else { return }
        // **Cleared before the first suspension, and this line is load-bearing.**
        // Everything below can exit early — a cancelled task, a load that fails —
        // and every one of those exits happens AFTER the outgoing `Document` has
        // been closed and released. A marker left naming the outgoing scope is
        // then a lie that survives: `.task(id:)` restarts when the writer returns
        // to that scope, the guard above sees a match and does nothing, and
        // `shouldMount` says yes over an emptied target. The pane shows the
        // writer's existing intent as EMPTY, and the first keystroke mints and
        // deposits over it — one character replacing the lot
        // (`test_aFailedScopeChangeDoesNotLeaveTheOldScopeLookingResolved`,
        // which reproduced exactly that before this line existed). The two
        // cancellation exits reach the same place holding another scope's
        // `Document`, or one `close()` has already husked.
        //
        // Safe against the mint (the C1 fix this could most easily undo):
        // `reconcile` runs on first appear, where this is already nil, and on a
        // SCOPE change, where the editor must come down anyway. The mint changes
        // no scope, so it never re-enters here — instrumented and confirmed.
        resolvedScope = nil
        // **Claimed before the first suspension, and it is the destination every
        // in-flight load checks itself against** (whole-branch review, C1). One
        // `StatementTextTarget` is shared by every reconcile this host ever runs
        // — the pane mounts it without `.id()` — so a load that has been
        // superseded is otherwise free to bind into the box the NEW scope is
        // using. See `loadMayBind`.
        target.wantedScope = key
        // See `pictureMessage`: this host is not remounted on a scope change, so
        // a refusal that is not cleared here follows the writer to the next scope.
        pictureMessage = nil
        if let prior = target.document {
            // Withdrawn BEFORE the close, so no window exists in which the
            // registry offers a `Document` that is on its way to being a husk.
            if let id = target.statementID { store.forgetStatementDocument(id: id) }
            await prior.close()
        }
        // A cancelled reconcile has been superseded by another scope change; its
        // own task will do the work. Leaving `resolvedScope` stale keeps the
        // placeholder up, which is the safe state.
        guard !Task.isCancelled else { return }
        target.release()

        if let statement {
            // A statement that already has content must never be typed over, so
            // the scope counts as resolved only if its Document really loaded. A
            // failed load leaves the placeholder up rather than an empty editor
            // whose first keystroke would mint a draft over the writer's prose.
            guard await load(statement, for: key) else { return }
        }
        guard !Task.isCancelled else { return }
        resolvedScope = key
    }

    /// The first keystroke into an undeclared scope. Find-or-create is
    /// idempotent, so a second arrival cannot mint a second file;
    /// `mintingScopes` stops a burst of keystrokes from starting a second
    /// attempt at the same scope, and a failed attempt is retried by the next
    /// keystroke rather than losing the words.
    ///
    /// **Its destination is named here, before either suspension.** Nothing
    /// cancels this `Task` — it is detached from the `.task(id:)` that `reconcile`
    /// runs under — so `Task.isCancelled` is false on this path forever and the
    /// named scope is the only thing that can refuse a bind whose pane has moved
    /// on. `scopeKey` is correct to read at this instant and only at this
    /// instant: `reconcile` re-wires `onUnboundWrite` with the current `self` on
    /// every scope, so the keystroke that got here belongs to the scope this
    /// value names.
    private func mintAndBind() {
        let wanted = scopeKey
        guard !mintingScopes.contains(wanted), target.document == nil else { return }
        mintingScopes.insert(wanted)
        Task { @MainActor in
            defer { mintingScopes.remove(wanted) }
            do {
                let created = try await store.createStatement(kind: kind, scope: scope)
                _ = await load(created, for: wanted)
            } catch {
                _statementEditorLog.error(
                    "Could not create statement: \(error, privacy: .public)")
            }
        }
    }

    /// `Document.load` is the contract surface — it is what reaches
    /// `Bootstrap.run`, and no other way of constructing a `Document` is
    /// sanctioned (`BootstrapWiringTests`). Returns whether it bound; the caller
    /// decides what a failure means (see `reconcile`).
    ///
    /// `wanted` is the scope this load is FOR, and the caller names it before
    /// suspending. Between `Document.load`'s suspension and `target.bind` the
    /// pane may have moved on, and this function must not bind or register a
    /// `Document` it no longer owns — see `loadMayBind` for the two doors and
    /// why neither signal covers both. A refused `Document` is CLOSED here: it
    /// was never registered, nothing else holds it strongly, and one left to
    /// deallocate unclosed strands its pending buffer.
    ///
    /// **Two refusals, asking different questions on either side of the load.**
    /// `gateArrival`, before it, asks whether this statement is already in the
    /// box — a load that goes ahead there ends with two live `Document`s on one
    /// path even though both loads wanted the same scope, so `loadMayBind`
    /// cannot see it (`gateArrival`). `loadMayBind`, after it, asks whether the
    /// pane still wants this scope at all.
    ///
    /// **Both refusals are about BINDING, and neither is about the words**
    /// (issue #21). Every arrival here — bound, already bound, or turned away —
    /// deposits whatever was typed for `wanted` into `wanted`'s own file, because
    /// that is where those characters were always going: the pane is only where
    /// they were typed. A refusal that also dropped them was the loss, and it had
    /// two shapes. `loadMayBind` refuses a mint whose pane has left (`⌘⌥N` tears
    /// this host down, so `release()` never runs and the words are in an orphaned
    /// box) and used to close the file it had just created without writing them
    /// into it. `gateArrival` refuses one whose box another scope's `Document`
    /// has taken — the ordinary case of clicking onto a chapter that HAS an
    /// intent — and refuses *before* the load, so it has no `Document` to deposit
    /// into at all; that one loads its own, deposits, and closes it, and does so
    /// only when there are words waiting, so a refusal with nothing to deliver
    /// still costs no file I/O.
    @discardableResult
    private func load(_ statement: Statement, for wanted: String) async -> Bool {
        // **Held across the load AND the registration**, so that the window
        // between "the registry says nobody has this" and "I have registered
        // mine" is not one a transient writer can open a second `Document` in.
        // See `ProjectStore.lockStatementOpen(_:)`; it is over the opening only,
        // so this is released as soon as the registry can answer for us.
        await store.lockStatementOpen(statement.id)
        defer { store.unlockStatementOpen(statement.id) }
        // **Asked AGAIN now that the gate is ours**, because waiting for it is
        // a suspension like any other and the box may have been filled while we
        // queued — by this host's OTHER load, which is the only other thing that
        // can fill it. See `gateArrival`: `alreadyBound` is a success with
        // nothing to LOAD (the caller's destination is already there), and it is
        // returned rather than loaded because a second `Document` on this path
        // is the whole defect.
        //
        // **No arm returns without delivering the words** (issue #21).
        //
        // `refuse` is the door: somebody else's live `Document` has the box,
        // which is a reason not to BIND and no reason to lose a keystroke — the
        // ordinary case is clicking from a chapter with no intent onto one that
        // has an intent, and it is turned away BEFORE the load, so it has no
        // `Document` to deposit into. It opens this statement's own under the
        // gate it is already holding, deposits, and closes it below. Only when
        // words are waiting, so a refusal with nothing to deliver still costs no
        // file I/O — and `Document.load` bootstraps, which is a write.
        //
        // `alreadyBound` is belt rather than a door, and the difference is worth
        // stating so nobody later reads it as a fixed bug: nothing can be waiting
        // for `wanted` here today. `write` files words only while the box holds
        // no `Document`, and the load that filled the box deposited on its way in
        // (`bind`), so a full box has an empty entry by construction. It is here
        // because that argument is about `bind`, one function away, and the cost
        // of being wrong about it is a writer's sentence.
        //
        // A planted offender for each of the two real refusals is in
        // `StatementDraftHandoffTests`; the deposit below is the one they share.
        let arrival = Self.gateArrival(liveStatementID: target.liveStatementID,
                                       loading: statement.id)
        switch arrival {
        case .load: break
        case .alreadyBound:
            if let bound = target.document { target.deposit(into: bound, for: wanted) }
            return true
        case .refuse:
            guard target.hasWordsWaiting(for: wanted) else { return false }
        }
        do {
            let document = try await Document.load(
                url: store.url.appendingPathComponent(statement.path),
                device: Self.deviceId,
                session: Self.sessionId,
                presenter: documentStore.presenter)
            guard arrival == .load,
                  Self.loadMayBind(loadedScope: wanted,
                                   paneWants: target.wantedScope,
                                   cancelled: Task.isCancelled) else {
                // Refused the binding, not the writing. The deposit and the close
                // are both inside the open gate, so nothing can open a second
                // `Document` on this path between them.
                target.deposit(into: document, for: wanted)
                await document.close()
                return false
            }
            target.bind(document, id: statement.id, for: wanted)
            // **Announce it, or a promotion opens a second `Document` on this
            // path** (M1A Task 7). A statement is in no `DocumentStore` registry
            // by design, so this is the only way anything else can find the one
            // the writer is typing into. Registered AFTER `bind`, so the
            // registry never names a `Document` the pane has not taken.
            store.noteStatementDocumentOpened(document, id: statement.id)
            return true
        } catch {
            _statementEditorLog.error(
                "Could not load statement \(statement.id, privacy: .public): \(error, privacy: .public)")
            return false
        }
    }

    // MARK: - Pictures (M1A Task 12, spec §7)

    /// Only visual language takes pictures. An intent is prose *about* the
    /// writing; the umbrella spec's §3.2 calls visual language *mixed — images,
    /// references and prose*, and it is the one artifact whose subject is how the
    /// book looks. `StatementImageIngestTests.test_intentTakesNoPicturesAtAll` is
    /// the control on this being a switch rather than an oversight.
    static func takesPictures(_ kind: Statement.Kind) -> Bool {
        if case .visualLanguage = kind { return true }
        return false
    }

    /// Whether the drop well is on screen: visual language, **and only while the
    /// editor is mounted**.
    ///
    /// **The second half is UI coherence, and it is deliberately no longer
    /// carrying any correctness** (review round 2). It was written to close a
    /// window in which a ref could be lost, which made it the kind of guard that
    /// has to be right about the pane's lifecycle — and it was not, because
    /// `resolvedScope` describes the resolved SCOPE rather than whether the host
    /// is mounted. `take` now names its destination outright and reads no view
    /// state after suspending, so a drop that starts or finishes at any moment
    /// reaches the right statement. What is left here is only that a drop target
    /// under a "Loading…" placeholder is nonsense to look at.
    ///
    /// Static and pure, like `shouldMount`, so the rule is asserted over the
    /// product of its inputs rather than through a race.
    static func showsPictureWell(
        kind: Statement.Kind, resolvedScope: String?, scopeKey: String
    ) -> Bool {
        takesPictures(kind) && shouldMount(resolvedScope: resolvedScope, scopeKey: scopeKey)
    }

    /// The drop target, **beside the editor rather than over it**.
    ///
    /// `EditorSurface` mounts a real `NSTextView`, which is the deeper AppKit
    /// view and therefore the one a drag is offered to first; a SwiftUI
    /// `.onDrop` laid over it is a target whose delivery nobody here can
    /// predict. A well of its own is `PaletteCardEditor`'s shape, it is
    /// unambiguous on screen, and it says what it takes. `⌘V` inside the editor
    /// is the other half and needs no chrome — see `makeSurfaceConfiguration`.
    ///
    /// `[.fileURL, .image]` providers and NEVER `.dropDestination(for: URL.self)`,
    /// which silently rejects a browser's rendered bitmap with nothing logged and
    /// nothing red (`DropClassification`).
    private var pictureWell: some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                .foregroundStyle(isDropTargeted
                                 ? AnyShapeStyle(Color.accentColor)
                                 : AnyShapeStyle(.separator))
                .frame(height: 40)
                .overlay(
                    Label("Drop pictures here", systemImage: "photo")
                        .font(.caption).foregroundStyle(.secondary))
                .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
                    ingest(providers)
                    return true
                }
            if let pictureMessage {
                Text(pictureMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    /// Take every provider a drop carried, in order.
    private func ingest(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            for provider in providers {
                switch DropClassification.action(
                    hasFileURL: provider.hasItemConformingToTypeIdentifier(
                        UTType.fileURL.identifier),
                    canLoadImage: provider.canLoadObject(ofClass: NSImage.self)) {
                case .fileURL:
                    guard let url = await DropClassification.fileURL(from: provider) else {
                        pictureMessage = ImagePasteHandler.failureMessage(for: LoadFailed())
                        continue
                    }
                    await take { try await store.addImage(
                        toStatement: kind, scope: scope, fileURL: url) }
                case .image:
                    guard let image = await DropClassification.image(from: provider) else {
                        pictureMessage = ImagePasteHandler.failureMessage(for: LoadFailed())
                        continue
                    }
                    await take { try await store.addImage(
                        toStatement: kind, scope: scope, image: image) }
                case .ignore:
                    continue
                }
            }
        }
    }

    /// A drag that carried a file URL or a bitmap and then would not hand it
    /// over. It has no sentence of its own — `failureMessage` gives it the
    /// generic one, which is the honest answer: we do not know what it was.
    private struct LoadFailed: Error {}

    /// Run one ingest and put its ref where it belongs, or say why not.
    ///
    /// **The destination is a value this function already holds, and after the
    /// suspension it reads NO view state to find one** (review round 2). That is
    /// the whole of the fix, and it is a narrower surface rather than a better
    /// guard: round 1 routed on `resolvedScope`, which describes the resolved
    /// SCOPE and not whether the host is mounted — and `⌘⌥N` is not a scope
    /// change on this host at all. `DetailPaneToggle.segmentContent` gives
    /// `.intent` and `.visualLanguage` separate `case` arms, so the structural
    /// identity differs and the visual-language host is **torn down**: its
    /// `.onDisappear` forgets the registration and closes the `Document`, and
    /// leaves `resolvedScope` naming the scope it just left. A route decided on
    /// that proxy wrote into a husked `Document` (a logged no-op — accepted drop,
    /// picture on disk, no text) or, unbound, fired `mintAndBind` from a dead
    /// view and registered a `Document` nothing would ever close.
    ///
    /// There is no proxy to go stale now because there is no proxy: the ingest
    /// returns the statement it saved the picture beside (`StatementPicture`),
    /// and `appendToStatement` writes into **that** statement's op log — its live
    /// arm finding the pane's own `Document` when a pane still has one, so a
    /// mounted editor shows the picture immediately, and its transient arm
    /// loading one under the open gate when none does. `deliver` was deleted
    /// rather than corrected; the choice it made is the thing that could be
    /// wrong.
    ///
    /// The one behaviour this gave up: a picture dropped into a visual language
    /// that has no statement yet reaches the op log but is not *shown* until the
    /// pane binds — the writer's next keystroke, or the next time they arrive on
    /// the pane. The words are safe either way, which the old route could not
    /// promise.
    ///
    /// **Never by writing the `.md`** (contract 7): a statement is a `Document`
    /// and its file is derived output, so a direct write would be discarded on
    /// the next re-materialize.
    ///
    /// Appended rather than inserted at the caret, because a drop has no caret
    /// and the well is not the editor. `⌘V` inside the editor does insert at the
    /// caret when it can; see `makeImagePasteHandler`.
    ///
    /// **Nothing here binds the pane, and the version that did was dangerous.**
    /// A picture that lands in a scope with no statement leaves `target` unbound
    /// — `reconcile` established there was none and nothing re-runs it — so the
    /// editor goes on showing its empty `draft` until the pane is next opened on
    /// that scope, when `makeNSView` seeds it from the `Document`. Calling
    /// `mintAndBind` here to close that gap was written, measured and removed: it
    /// binds, but **no body pass follows** (nothing in `body` reads `mintingScopes`,
    /// so writing it invalidates nothing), leaving a bound `Document` holding the
    /// ref behind a text view holding "" — and the writer's next keystroke then
    /// goes through the binding as `setFullText("a")` and **takes the ref with
    /// it**. Unbound, the same keystroke lands in `draft` and the mint's
    /// `deposit` MERGES it with what the document already has.
    /// The gap is a picture you cannot see yet; the fix for it was a picture you
    /// lose.
    ///
    /// One `do`/`catch` over both steps, so a throwing append cannot be followed
    /// by the `pictureMessage = nil` that a separate success path would run —
    /// which would be an accepted drop, no text and no sentence.
    private func take(_ ingest: () async throws -> StatementPicture) async {
        do {
            let landed = try await ingest()
            try await store.appendToStatement(landed.ref, to: landed.statement,
                                              session: Self.sessionId)
            pictureMessage = nil
        } catch {
            pictureMessage = ImagePasteHandler.failureMessage(for: error)
        }
    }

    /// `⌘V` of a picture inside the editor.
    ///
    /// **The closure captures `kind` and `scope` from the body pass that built
    /// it, and that is safe here for a reason worth stating** — `reconcile`'s own
    /// comment records the live defect from getting this wrong once, where a
    /// handler wired at `.onAppear` went on naming the pane's first scope for its
    /// whole life. This one is rebuilt on every body pass and re-assigned by
    /// `EditorSurface.updateNSView`, and no paste can outrun it: a scope change
    /// unmounts the editor entirely (`canMount` goes false) until `reconcile`
    /// sets `resolvedScope` again, which is itself a body pass.
    ///
    /// **Synchronous by contract** (`MaughamTextView.paste(_:)` inserts what this
    /// returns at the caret), which is why the two branches differ. With a
    /// statement already on disk its well is known and the ref goes in at the
    /// caret, where the writer put it. Without one, the well cannot be derived at
    /// all — `vacantStatementPath` steers around an occupied
    /// `visual-language.md`, so the path is find-or-create's answer rather than a
    /// constant — so this returns nil and finishes on the same route the drop
    /// takes. Nothing is lost: the statement is minted, the picture is saved and
    /// the ref is appended. It appends rather than inserting, and in the only
    /// case that reaches it those are the same place — there is no statement, so
    /// there is nothing in the editor to be after.
    private func makeImagePasteHandler() -> ((NSImage) -> String?)? {
        guard Self.takesPictures(kind) else { return nil }
        return { image in
            if let statement = store.statement(kind: kind, scope: scope) {
                do {
                    // Through the seam, never the saver: where a statement's
                    // pictures live is `ProjectStore+StatementAssets`' decision,
                    // and a second call to the saver from here is a second answer.
                    return try store.addImage(to: statement, image: image)
                } catch {
                    pictureMessage = ImagePasteHandler.failureMessage(for: error)
                    return nil
                }
            }
            Task { @MainActor in
                await take { try await store.addImage(
                    toStatement: kind, scope: scope, image: image) }
            }
            return nil
        }
    }

    // MARK: - Configuration

    /// Prose, with wiki links on and every writing-surface affordance off.
    ///
    /// **Prose mode always**: a screenplay's intent is prose *about* a
    /// screenplay, so Fountain tokenization never applies to a statement. Wiki
    /// links resolve, because `[[Chapter 9]]` in an intent is the same reference
    /// it is anywhere else — and `list_all_links` / `find_references` scan
    /// statements for exactly that reason (whole-branch review, I1: they scanned
    /// manuscript documents and research-note bodies only, so adoption moved
    /// every link in a legacy craft-intent note *out* of the graph in the same
    /// pass that moved the prose). **⌘⌥F still does not reach a statement** —
    /// `ProjectSearchEngine` walks `manifest.structure` and `manifest.research`;
    /// see the roadmap's 1A entry. No element gutter, no focus dim, no
    /// typewriter scroll: a pane is not the writing surface.
    private func makeSurfaceConfiguration() -> EditorSurfaceConfiguration {
        EditorSurfaceConfiguration(
            presentation: .init(
                theme: userPreferences.theme,
                typography: effectiveTypography,
                mode: ProseMode(),
                typewriterScroll: false,
                sentenceFocus: false,
                paragraphFocus: false,
                showElementGutter: false),
            control: editorControl,
            paragraphProviders: .init(
                wikiLinkResolver: { store.resolveDocumentId(forTitle: $0) != nil },
                wikiLinkClickResolver: { store.resolveDocumentId(forTitle: $0) },
                // Scopes a wiki-link click's navigation to this project (ADR
                // 0021). Prose never posts a script update — `lastParsedScript`
                // is nil outside screenplay mode — so this only serves the click.
                scriptOriginProjectId: ProjectIdentifier.id(for: store.url),
                // Nil for an intent, which is what makes `⌘V` of a picture fall
                // through to `super.paste` there — and what keeps the image
                // types out of `readablePasteboardTypes` on that surface.
                imagePasteHandler: makeImagePasteHandler()),
            // The right column's editor sits beside the manuscript's. It answers
            // none of the window's manuscript commands and keeps its own undo
            // stack — see `EditorSurfaceConfiguration.isSecondEditorInItsWindow`
            // for what each of those prevents.
            isSecondEditorInItsWindow: true)
    }
}
