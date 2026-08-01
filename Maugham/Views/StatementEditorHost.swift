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
    ///
    /// **A carried draft is APPENDED to whatever the document already holds; it
    /// never replaces it.** `setFullText` is whole-text replacement, and this
    /// line used to hand it the draft alone on the stated grounds that a
    /// just-minted statement's document is empty — which was true while the pane
    /// was the only thing that could create one. **M1A Task 7 made the canvas a
    /// second creator**, and `createStatement` is idempotent: a promotion into a
    /// scope this pane is mounted on but has not bound (no statement existed when
    /// `reconcile` ran, and nothing re-runs it) creates the statement WITH the
    /// promoted card in it, and the writer's next keystroke arrives here as a
    /// one-character draft. Replacing left them holding that character and
    /// nothing else. **No timing window is involved** — promote, leave, come
    /// back, type.
    ///
    /// It is fixed here rather than at `mintAndBind` because this is the one
    /// place a draft meets a document: the caller-side fix ("look the statement
    /// up first and pass `carryingDraft: false`") closes the one door that
    /// exists today and throws the writer's keystroke away doing it, while this
    /// keeps both texts and closes the door for the next creator too. In the
    /// case this was written for — a genuinely new statement, whose file is
    /// empty scaffolding — the behaviour is unchanged, byte for byte.
    ///
    /// (`reconcile`'s own comment describes this failure arriving through a
    /// different door: a stale `resolvedScope` leaving the pane bound to
    /// nothing over real content. That door is closed by clearing the marker;
    /// this one cannot be, because the pane's belief was true when it formed.)
    func bind(_ document: Document, id: String, carryingDraft: Bool) {
        if carryingDraft, !draft.isEmpty {
            let existing = document.displayText
            document.setFullText(
                existing.isEmpty ? draft : existing + "\n\n" + draft)
        }
        draft = ""
        self.document = document
        self.statementID = id
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
        statementID = nil
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
        // writer's existing intent as EMPTY, and the first keystroke mints
        // `carryingDraft: true` over it — one character replacing the lot
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
        // **Held across the load AND the registration**, so that the window
        // between "the registry says nobody has this" and "I have registered
        // mine" is not one a transient writer can open a second `Document` in.
        // See `ProjectStore.lockStatementOpen(_:)`; it is over the opening only,
        // so this is released as soon as the registry can answer for us.
        await store.lockStatementOpen(statement.id)
        defer { store.unlockStatementOpen(statement.id) }
        do {
            let document = try await Document.load(
                url: store.url.appendingPathComponent(statement.path),
                device: Self.deviceId,
                session: Self.sessionId,
                presenter: documentStore.presenter)
            target.bind(document, id: statement.id, carryingDraft: carryingDraft)
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
    /// The second half is correctness rather than tidiness. `reconcile` releases
    /// the outgoing target and then suspends at `Document.load`; a drop landing
    /// in that window writes its ref into `draft`, and the
    /// `bind(carryingDraft: false)` waiting at the end of `reconcile` clears the
    /// draft without carrying it — so the picture is in the well and the ref is
    /// gone. There is no editor to take a keystroke in that window either, and
    /// this is the same answer for the same reason.
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

    /// Where a finished ingest's ref goes.
    enum PictureDelivery: Equatable {
        /// Through the pane's own binding. Visible immediately, and it mints the
        /// statement when the drop is what created it.
        case throughThePane
        /// By statement id, through the seam promotion uses. The pane has moved
        /// on while the file was being copied, so its `target` names another
        /// scope's `Document` — or none at all.
        case byStatementID
    }

    /// Which route a ref takes, decided at the moment the ingest FINISHES.
    ///
    /// **This is the M1A Task 12 review's I1, and it is a keystroke rather than
    /// a race against the machine.** `showsPictureWell` stops a drop from
    /// *starting* while the editor is unmounted; it says nothing about one that
    /// started while mounted and completes during a `reconcile` — and that window
    /// is a manifest write plus a file copy wide. Two landing places, both wrong:
    /// before intent's `bind`, the ref sits in `draft` and
    /// `bind(carryingDraft: false)` clears it, so the writer sees an accepted
    /// drop and no text; after it, `target.document` is *intent's*, and a
    /// `visual-language_assets/` ref is appended to their intent prose.
    ///
    /// Every prior defect on this file was a value still trusted after the thing
    /// it described had moved, which is exactly what the captured `kind`/`scope`
    /// are here. So the pane's route is taken only while the pane is still
    /// resolved on the scope the ingest started from — and otherwise the ref goes
    /// in by id, which is lossless. Nothing is dropped and nothing lands in the
    /// wrong document.
    ///
    /// Static and pure so it is asserted over the product of its inputs rather
    /// than through a race, like `shouldMount` and `showsPictureWell`.
    static func delivery(
        kind: Statement.Kind, scopeKeyAtStart: String, resolvedScopeAtFinish: String?
    ) -> PictureDelivery {
        showsPictureWell(kind: kind,
                         resolvedScope: resolvedScopeAtFinish,
                         scopeKey: scopeKeyAtStart)
            ? .throughThePane : .byStatementID
    }

    /// Run one ingest and put its ref where it belongs, or say why not.
    ///
    /// `scopeKey` is read **before** the suspension and compared after, which is
    /// `reconcile`'s own idiom one function over.
    private func take(_ ingest: () async throws -> StatementPicture) async {
        let startedOn = scopeKey
        do {
            let landed = try await ingest()
            await deliver(landed, startedOn: startedOn)
            pictureMessage = nil
        } catch {
            pictureMessage = ImagePasteHandler.failureMessage(for: error)
        }
    }

    /// Put a Markdown ref into the statement's text.
    ///
    /// **Never by writing the `.md`** (contract 7), on either route: a statement
    /// is a `Document` and its file is derived output, so a direct write would be
    /// discarded on the next re-materialize.
    ///
    /// The pane route goes through `target.write`, the same binding every
    /// keystroke takes — and when the statement has no `Document` yet the ref
    /// lands in `draft` and fires the pane's own mint, which carries it in, so a
    /// picture dropped into an empty visual language is what declares it to
    /// exist. The by-id route reaches the same op log through
    /// `ProjectStore.appendToStatement`, whose live arm writes into the pane's
    /// own `Document` when a pane has one.
    ///
    /// Appended rather than inserted at the caret, because a drop has no caret
    /// and the well is not the editor. `⌘V` inside the editor does insert at the
    /// caret; see `makeImagePasteHandler`.
    private func deliver(_ landed: StatementPicture, startedOn: String) async {
        switch Self.delivery(kind: kind, scopeKeyAtStart: startedOn,
                             resolvedScopeAtFinish: resolvedScope) {
        case .throughThePane:
            let existing = target.text
            target.write(existing.isEmpty ? landed.ref : existing + "\n\n" + landed.ref)
        case .byStatementID:
            try? await store.appendToStatement(landed.ref, to: landed.statement,
                                               session: Self.sessionId)
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
