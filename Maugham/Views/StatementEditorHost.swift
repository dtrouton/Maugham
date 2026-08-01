import SwiftUI
import MaughamCore
import AppKit
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
/// It is a reference type on purpose. `EditorSurface.makeCoordinator()` captures
/// its `Binding` **once**, at mount; a binding closing over a `@State Document?`
/// would keep writing to the nil it saw then. Routing through this box is what
/// lets the mint happen *without remounting the editor mid-keystroke*, which is
/// the shape that loses characters.
@MainActor
final class StatementTextTarget {

    private(set) var document: Document?
    private(set) var draft = ""

    /// Fired on every write that lands in `draft` — i.e. while the statement
    /// still has no file. The host guards it; firing on every write (rather
    /// than only the first) is what lets a failed mint retry on the next
    /// keystroke instead of stranding the writer's words in memory.
    var onUnboundWrite: (() -> Void)?

    /// What the editor shows. One source at a time: the Document once bound,
    /// the pre-mint draft before that.
    var text: String { document?.displayText ?? draft }

    /// The sanctioned binding shape, and the only mutation path
    /// (`EditorHost.swift:13-15`): `Document.setFullText` writes `displayText`
    /// exactly once at the end, which is what keeps the milestone-1e
    /// binding-loop race closed.
    func write(_ newText: String) {
        if let document {
            document.setFullText(newText)
            return
        }
        draft = newText
        guard !newText.isEmpty else { return }
        onUnboundWrite?()
    }

    /// Bind the loaded `Document`.
    ///
    /// `carryingDraft` is true only for the mint the writer's own keystroke
    /// triggered — the words typed before the file existed belong in its first
    /// op. It must be false when binding a statement that already has content,
    /// or an empty draft would overwrite what the writer wrote last week.
    func bind(_ document: Document, carryingDraft: Bool) {
        if carryingDraft, !draft.isEmpty {
            document.setFullText(draft)
        }
        draft = ""
        self.document = document
    }

    /// Let go of the previous scope's `Document` and its draft.
    ///
    /// Called only while the pane is showing its placeholder — i.e. after the
    /// scope changed and before the new one has resolved. Calling it while the
    /// editor is mounted would put an empty surface over real content, and the
    /// next keystroke would write the empty draft into the wrong statement.
    /// **The caller must have closed the document first**; this only drops the
    /// reference.
    func release() {
        document = nil
        draft = ""
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
    @State private var isMinting = false
    @State private var editorControl = EditorControl()

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

    private var canMount: Bool {
        Self.shouldMount(resolvedScope: resolvedScope, scopeKey: scopeKey)
    }

    var body: some View {
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
        .onAppear {
            seedControl()
            // Wired before any keystroke can arrive: `.onAppear` runs before
            // the view can take input.
            target.onUnboundWrite = { mintAndBind() }
        }
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
            if let document = target.document {
                Task { await document.close() }
            }
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
            if let document = target.document {
                Task { await document.close() }
            }
        }
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
        guard resolvedScope != key else { return }
        if let prior = target.document {
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
            guard await load(statement, carryingDraft: false) else { return }
        }
        guard !Task.isCancelled else { return }
        resolvedScope = key
    }

    /// The first keystroke into an undeclared scope. Find-or-create is
    /// idempotent, so a second arrival cannot mint a second file; `isMinting`
    /// stops a burst of keystrokes from starting a second attempt, and a failed
    /// attempt is retried by the next keystroke rather than losing the words.
    private func mintAndBind() {
        guard !isMinting, target.document == nil else { return }
        isMinting = true
        Task { @MainActor in
            defer { isMinting = false }
            do {
                let created = try await store.createStatement(kind: kind, scope: scope)
                _ = await load(created, carryingDraft: true)
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
    @discardableResult
    private func load(_ statement: Statement, carryingDraft: Bool) async -> Bool {
        do {
            let document = try await Document.load(
                url: store.url.appendingPathComponent(statement.path),
                device: Self.deviceId,
                session: Self.sessionId,
                presenter: documentStore.presenter)
            target.bind(document, carryingDraft: carryingDraft)
            return true
        } catch {
            _statementEditorLog.error(
                "Could not load statement \(statement.id, privacy: .public): \(error, privacy: .public)")
            return false
        }
    }

    // MARK: - Configuration

    /// Prose, with wiki links on and every writing-surface affordance off.
    ///
    /// **Prose mode always**: a screenplay's intent is prose *about* a
    /// screenplay, so Fountain tokenization never applies to a statement. Wiki
    /// links resolve, because `[[Chapter 9]]` in an intent is the same reference
    /// it is anywhere else, and `list_all_links` / `find_references` already scan
    /// non-manuscript bodies. No element gutter, no focus dim, no typewriter
    /// scroll: a pane is not the writing surface.
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
                scriptOriginProjectId: ProjectIdentifier.id(for: store.url)),
            // The right column's editor sits beside the manuscript's. It answers
            // none of the window's manuscript commands and keeps its own undo
            // stack — see `EditorSurfaceConfiguration.isSecondEditorInItsWindow`
            // for what each of those prevents.
            isSecondEditorInItsWindow: true)
    }
}
