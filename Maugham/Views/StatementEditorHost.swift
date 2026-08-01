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
    /// Render trigger and mount latch. The `Document` itself lives on `target`
    /// (the binding needs it synchronously); this only tells SwiftUI that the
    /// bind happened.
    @State private var isBound = false
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

    /// Whether there is something to type into.
    ///
    /// Two states qualify and they are not the same: a bound `Document`, and a
    /// scope with **no statement at all** — which is an empty editor that mints
    /// on the first keystroke, not a button and not a nag (§4.3). The remaining
    /// state — a statement exists but its `Document` has not loaded — is the
    /// only one that shows anything else, because mounting an editable surface
    /// over content that has not arrived is how a draft overwrites a statement.
    ///
    /// Note it can only ever go false → true: after the mint, `statement` is
    /// non-nil AND `isBound` is true, so the surface is never torn down and
    /// rebuilt under the writer's hands.
    private var canMount: Bool { isBound || statement == nil }

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
        .task { await bindExistingStatement() }
        .onDisappear {
            // The pane's own `.onDisappear` is what flushes the pending typing
            // burst to the op log — `Document.close()` is idempotent, so a
            // spurious fire costs nothing.
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

    /// Load the `Document` for a statement that already exists. A scope with no
    /// statement returns immediately and waits for a keystroke.
    ///
    /// **Not keyed on the path, and that is tripwire 22 satisfied rather than
    /// dodged.** The tripwire is about a Document binding that must RELOAD when
    /// its file moves; a statement's path does not move when the document it is
    /// about is renamed — identity is the manifest `id` and the path is derived
    /// from the title once, at creation (spec §2.2), which
    /// `test_renamingTheDocumentLeavesItsIntentWhereItIs` drives end to end.
    /// `StatementPane` keys the whole host on the SCOPE, so the case that does
    /// need a fresh Document — the writer switching between a chapter's intent
    /// and the book's — remounts. If a mover ever does relocate a statement,
    /// this becomes a path-keyed reload and that test is where it will fail.
    private func bindExistingStatement() async {
        guard !isBound, let statement else { return }
        await load(statement, carryingDraft: false)
    }

    /// The first keystroke into an undeclared scope. Find-or-create is
    /// idempotent, so a second arrival cannot mint a second file; `isMinting`
    /// stops a burst of keystrokes from starting a second attempt, and a failed
    /// attempt is retried by the next keystroke rather than losing the words.
    private func mintAndBind() {
        guard !isMinting, !isBound else { return }
        isMinting = true
        Task { @MainActor in
            defer { isMinting = false }
            do {
                let created = try await store.createStatement(kind: kind, scope: scope)
                await load(created, carryingDraft: true)
            } catch {
                _statementEditorLog.error(
                    "Could not create statement: \(error, privacy: .public)")
            }
        }
    }

    /// `Document.load` is the contract surface — it is what reaches
    /// `Bootstrap.run`, and no other way of constructing a `Document` is
    /// sanctioned (`BootstrapWiringTests`).
    private func load(_ statement: Statement, carryingDraft: Bool) async {
        do {
            let document = try await Document.load(
                url: store.url.appendingPathComponent(statement.path),
                device: Self.deviceId,
                session: Self.sessionId,
                presenter: documentStore.presenter)
            target.bind(document, carryingDraft: carryingDraft)
            isBound = true
        } catch {
            _statementEditorLog.error(
                "Could not load statement \(statement.id, privacy: .public): \(error, privacy: .public)")
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
