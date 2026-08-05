import AppKit
import SwiftUI
import MaughamCore

/// **What is being studied, and how wide** — the assistant column's whole
/// state (M2 spec §6.2).
///
/// An `@Observable` object rather than two `@State` values on `ProjectWindow`
/// for a reason the escape monitor makes concrete: the References pane is in the
/// window's RIGHT column and the assistant column is in its CENTRE, so the
/// selection has to be shared across a boundary that a `Binding` would have to
/// be threaded through `DetailPaneToggle`'s whole initialiser — and the monitor's
/// event-time closure needs something stable to read, which a `Binding` captured
/// once at install time is not (`CanvasModel` and `EditorControl` are the
/// precedents).
@MainActor
@Observable
final class AssistantColumnModel {

    /// The one studied reference, or none. **One at a time**, because two
    /// studied references is a research session rather than writing (§6.2).
    private(set) var studied: PinnedReference?

    /// Read from `UIState` at load and written back on the drag's end.
    var width: Double = UIState.defaultAssistantColumnWidth

    /// Promote a pin, or send it back if it is the one already up.
    ///
    /// **The comparison is on the id, not the value.** `PinnedReferences.pinned`
    /// is a pure function its callers re-run rather than cache, so a title that
    /// changed under the writer — a renamed note, an edited scrap's first line —
    /// would make a second click on the same row promote a "different" reference
    /// instead of dismissing it.
    func study(_ reference: PinnedReference) {
        studied = studied?.id == reference.id ? nil : reference
    }

    func dismiss() { studied = nil }

    /// Whether `reference` is the one on show — what a row draws its selection
    /// from, so the shelf and the column cannot disagree about which pin is up.
    func isStudying(_ reference: PinnedReference) -> Bool {
        studied?.id == reference.id
    }
}

// MARK: - The column

/// One pinned reference, between the binder and the prose, at a width you can
/// read at (M2 spec §6.2).
///
/// **It renders nothing of its own.** Each arm hands off to a surface this app
/// already ships — `ResearchPreview` for anything in the research tree,
/// `PaletteCardReadView` for a card, `ImagePreview` for an owned photograph —
/// and a scrap is the one arm with no existing home, because its words live in
/// `canvas.md` and are drawn nowhere else at reading size. A markdown renderer
/// here would compile, look right, and diverge from the research preview two
/// panes away the first time a writer used a table
/// (`AssistantColumnTests.test_theColumnCarriesNoRendererOfItsOwn`).
struct AssistantColumn: View {
    let store: ProjectStore
    let projectRoot: URL
    @Bindable var assistant: AssistantColumnModel

    /// The close button's label. A constant so the button, its help text and
    /// the test that presses it cannot drift apart.
    static let closeLabel = "Close reference"

    /// **What a studied pin resolves to.** A value rather than four branches
    /// inside `body`, so the resolution can be asked of a project directly —
    /// and so the one case a `body` must not get wrong (a reference that left
    /// the project while it was being studied) is a case rather than a `nil`
    /// that renders as blank.
    enum Subject: Equatable {
        case research(ResearchItem)
        case palette(PaletteCard)
        /// Project-relative, as everything about an owned picture is.
        case photo(path: String)
        /// The scrap's WHOLE text. The pin's title is its truncated first line,
        /// which is the right thing for a shelf row and the wrong thing to
        /// study.
        case scrap(text: String)
        /// The writer deleted it while it was up. An honest empty state beats a
        /// blank pane that reads as a rendering failure.
        case missing
    }

    /// Resolve a pin against the project. `@MainActor` and not pure: it reads
    /// the manifest, parses a palette card and — for a scrap — reads whichever
    /// canvas is real. Called from a `.task`, never from a `body`.
    @MainActor
    static func subject(for reference: PinnedReference,
                        store: ProjectStore,
                        projectRoot: URL) -> Subject {
        switch reference.kind {
        case .research(let itemId):
            guard let item = TreeWalk.find(id: itemId, in: store.manifest.research) else {
                return .missing
            }
            return .research(item)
        case .palette(let cardId):
            // `loadPaletteCards()` parses each card's markdown; that is this
            // surface's whole job, and it happens once per promotion rather
            // than per body pass.
            guard let card = store.loadPaletteCards().first(where: { $0.id == cardId }) else {
                return .missing
            }
            return .palette(card)
        case .photo(let path):
            // An owned picture needs no manifest — it exists nowhere else in
            // the project — so it resolves whether or not anything else does.
            return .photo(path: path)
        case .scrap(let nodeId):
            // The same attached-or-sidecar discriminator the pinned set itself
            // was assembled through: with the canvas open the live model is
            // ahead of the sidecar by every keystroke the mounted editor has
            // folded in (tripwire 28).
            let read = CanvasClaudeWrite.readScene(store: store, projectRoot: projectRoot)
            guard let text = read.scraps[CanvasNodeID(nodeId)],
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .missing
            }
            return .scrap(text: text)
        }
    }

    /// **Whether there is a column at all**, over the window's state.
    ///
    /// Pure and asked over the product of its inputs rather than down the one
    /// path the plan named. `isNoChromeOn` is the intent strip's flag (Task 4)
    /// and it vetoes for the same reason: ⌘\ means *nothing but my prose*, and a
    /// reference column that survived it would be the loudest thing left on
    /// screen.
    static func isPresented(studied: PinnedReference?, isNoChromeOn: Bool) -> Bool {
        studied != nil && !isNoChromeOn
    }

    @State private var subject: Subject?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(NSColor.textBackgroundColor))
        // Resolved off the body path, and re-resolved when the writer promotes
        // something else. The id is the pin's, which is stable across a
        // recomputation of the pinned set — see `PinnedReference.id`.
        .task(id: assistant.studied?.id) {
            subject = assistant.studied.map {
                Self.subject(for: $0, store: store, projectRoot: projectRoot)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Text(assistant.studied?.title ?? "")
                .font(.headline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                assistant.dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("\(Self.closeLabel) (esc)")
            .accessibilityLabel(Self.closeLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch subject {
        case .research(let item):
            // Every research kind at once — note, PDF, photograph, recording,
            // link — through the switch the research browser already owns.
            ResearchPreview(projectURL: projectRoot, item: item)
        case .palette(let card):
            PaletteCardReadView(card: card, images: paletteImages(of: card))
        case .photo(let path):
            ImagePreview(fileURL: projectRoot.appendingPathComponent(path))
        case .scrap(let text):
            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        case .missing:
            ContentUnavailableView(
                CanvasItemFacts.missingTitle,
                systemImage: CanvasItemKind.missingGlyph,
                description: Text("It was deleted while you were looking at it."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case nil:
            // The window between promotion and resolution. Deliberately blank
            // rather than a spinner: resolution is a manifest lookup and a file
            // read, and a spinner that flashes for one frame is worse than
            // nothing.
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A card's pictures, loaded once per resolution. `PalettePane`'s own
    /// spelling — `NSImage(contentsOf:)` against the project root — because a
    /// palette's image count is bounded by a card the writer wrote, which is
    /// the reason `CanvasThumbnails`' machinery is the canvas's and not this
    /// surface's.
    private func paletteImages(of card: PaletteCard) -> [NSImage] {
        card.imagePaths.compactMap {
            NSImage(contentsOf: projectRoot.appendingPathComponent($0))
        }
    }
}

// MARK: - Escape

/// **Escape closes the column, as the highest-priority consumer of the window's
/// one `WindowEscapeArbiter`** — the same *instance* the canvas's dim registers
/// with, not merely the same class.
///
/// That distinction is the whole of Task 5's review finding 1, and it was
/// materially wrong here for one commit. This type owned a
/// `CanvasEscapeMonitor()` of its own while `CanvasEventNSView` owned another,
/// and the comment claimed the canvas's monitor was being reused. Both are
/// armable on one window by an ordinary route (dim the board by selecting a
/// chapter in Plan's tree, then ⌘⌥E and click a pin); local `NSEvent` monitors
/// run most-recently-installed-first and a consumed key short-circuits the rest,
/// so whichever armed LAST took Escape and the other never saw it. The arbiter
/// makes the order a decision — see `WindowEscapeArbiter.Consumer`, where the
/// column deliberately precedes the dim.
///
/// The obvious alternative — a `.keyboardShortcut(.cancelAction)` on the close
/// button — is a *key equivalent*, which AppKit consults before the responder
/// chain: with the column open, Escape would stop cancelling the binder's inline
/// rename (tripwire 16) and stop dismissing the find bar, in every window. That
/// is precisely the hazard `CanvasEscapeMonitor.disposition`'s third refusal
/// exists for, and going through the arbiter is what buys those refusals here
/// rather than re-deriving three that have already been measured against a real
/// field editor.
///
/// This consumer registers **only while there is a column on screen** — which is
/// `AssistantColumn.isPresented` and not `studied != nil`; see `sync`.
@MainActor
final class AssistantColumnEscape {

    /// **Read at EVENT time through `self`, and refreshed by every `sync`.** The
    /// arbiter's claim closure captures this object and nothing else, so a model
    /// captured by value — which `CanvasEscapeMonitor.install`'s idempotence
    /// would have frozen at the first call — cannot go on dismissing a reference
    /// the writer replaced ten minutes ago.
    private weak var model: AssistantColumnModel?

    /// The window's chrome flag, refreshed by every `sync` and read at event time
    /// beside the model, for the same reason the model is: a claim answering from
    /// a value frozen at registration answers about a window state that has since
    /// changed.
    private var isNoChromeOn = false

    /// The arbiter this consumer is currently registered with, or nil. Held
    /// weakly: the table in `WindowEscapeArbiter` owns them, keyed by window.
    private weak var arbiter: WindowEscapeArbiter?

    /// **Is THIS consumer watching** — registered, and on a window whose monitor
    /// is armed. Both halves matter: the registration alone would read true after
    /// the window's monitor had gone, and the armed flag alone would read true
    /// merely because the canvas's dim was up on the same window.
    var isInstalled: Bool {
        guard let arbiter else { return false }
        return arbiter.isRegistered(.assistantColumn) && arbiter.isArmed
    }

    /// **The one spelling of "is there a column"** — `AssistantColumn.isPresented`,
    /// the same pure function the mounting site's `if` asks. Both the
    /// registration and the event-time claim go through it, because a second
    /// condition written out here is exactly how the two diverged.
    private var isColumnPresented: Bool {
        AssistantColumn.isPresented(studied: model?.studied, isNoChromeOn: isNoChromeOn)
    }

    /// Register or resign to match **the column's presentation**. Idempotent in
    /// both directions, so the mounting site can call it from an `.onChange`
    /// without tracking what it did last.
    ///
    /// **`isNoChromeOn` and not merely `studied`, and that is the whole of final
    /// review C1.** Whether the column is on screen is
    /// `AssistantColumn.isPresented`, which vetoes on the chrome flag; whether it
    /// held an Escape claim used to be `studied != nil`, and nothing dismisses the
    /// studied reference when the flag flips — deliberately, since the column is
    /// meant to come back when the chrome does. So under ⌘\ or ⌘⇧F (which sets
    /// the same flag on the way into full screen, `ProjectWindow.toggleFullScreen`)
    /// an **invisible** column held the window's highest-priority claim: in full
    /// screen the exit key silently discarded the reference and left full screen
    /// alone; in Plan the dimmed board needed two presses, the first spent on
    /// nothing the writer could see. Both conditions are now the one function.
    ///
    /// **The window is a value rather than a closure now**, because the arbiter
    /// is keyed by window: a consumer has to be registered with a particular
    /// one, and moving means resigning from the old. `ProjectWindow`'s
    /// `WindowAccessor` reports its window asynchronously, so the mounting site
    /// syncs on the window changing as well as on the studied reference — which
    /// also closes the review's finding 3 (the previous comment claimed the
    /// window was read at event time when it was really read at last-sync time).
    func sync(model: AssistantColumnModel, window: NSWindow?, isNoChromeOn: Bool) {
        self.model = model
        self.isNoChromeOn = isNoChromeOn
        guard isColumnPresented, let window else {
            stop()
            return
        }
        let target = WindowEscapeArbiter.arbiter(for: window)
        if let previous = arbiter, previous !== target {
            previous.resign(.assistantColumn)
        }
        target.register(.assistantColumn, claim: { [weak self] in
            self?.performEscape() ?? false
        })
        arbiter = target
    }

    /// Give the key back — nothing is studied, or the window is going away.
    func stop() {
        arbiter?.resign(.assistantColumn)
        arbiter = nil
    }

    /// What the arbiter's offer does: dismiss and claim the key, or decline it so
    /// the offer passes down to the next consumer and, failing all of them,
    /// travels on. `@discardableResult` and internal so the decision is
    /// assertable without an `NSEvent`.
    @discardableResult
    func performEscape() -> Bool {
        guard let model, isColumnPresented else { return false }
        model.dismiss()
        return true
    }

    // No `deinit` of its own: `resign` is main-actor-isolated and `deinit` is
    // not. A consumer that vanished without resigning leaves a claim whose
    // `[weak self]` returns false, which passes the offer on rather than
    // swallowing the key — inert, not wrong.
}

// MARK: - Mounting

/// Puts the assistant column between the binder and the prose, keeps its width
/// in `UIState`, and wires Escape.
///
/// **A `ViewModifier` for `ProjectWindow`'s own reason** — that body has no
/// expression budget left under the Release type-checker, and every one of its
/// neighbours (`CanvasCollapseModifier`, `CanvasClaudeArrivalModifier`,
/// `TranslationReviewModifier`) is here for the same. As with those: deleting
/// the one line that applies this leaves every token in this file present and
/// every test in `AssistantColumnTests` green, and puts nothing on screen.
struct AssistantColumnModifier: ViewModifier {
    let store: ProjectStore?
    let projectURL: URL
    let documentStore: DocumentStore?
    let window: NSWindow?
    let isNoChromeOn: Bool
    /// Clearing on a document change is the honest behaviour: the shelf is
    /// per-document, so a pin studied for chapter one is not pinned to chapter
    /// three and would sit there claiming otherwise.
    let activeDocId: String
    @Bindable var assistant: AssistantColumnModel

    @State private var escape = AssistantColumnEscape()
    /// The drag's running total, so the gesture is smooth and only its END
    /// writes to disk — a `UIState` write per drag frame is 60 writes a second
    /// through the same debounce the manuscript uses.
    @State private var dragStartWidth: Double?

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            if let store,
               AssistantColumn.isPresented(studied: assistant.studied,
                                           isNoChromeOn: isNoChromeOn) {
                AssistantColumn(store: store, projectRoot: projectURL,
                                assistant: assistant)
                    .frame(width: assistant.width)
                resizeHandle
            }
            content
        }
        // **Every input the presentation rule reads gets an `.onChange`**, and
        // the three call one function so a fourth input cannot be added to
        // `isPresented` and forgotten here. `isNoChromeOn` is the one that was
        // missing (final review C1): ⌘\ and ⌘⇧F take the column off screen
        // without touching what is studied, and the claim used to stay behind.
        .onChange(of: assistant.studied?.id) { _, _ in syncEscape() }
        // **The window as well as the reference**, because the arbiter is keyed
        // by window: `WindowAccessor` reports one asynchronously after mount, and
        // a window that arrived after the first sync would otherwise leave the
        // column registered nowhere.
        .onChange(of: window) { _, _ in syncEscape() }
        .onChange(of: isNoChromeOn) { _, _ in syncEscape() }
        .onChange(of: activeDocId) { _, _ in assistant.dismiss() }
        .onDisappear { escape.stop() }
    }

    private func syncEscape() {
        escape.sync(model: assistant, window: window, isNoChromeOn: isNoChromeOn)
    }

    /// A draggable divider. `.resizeLeftRight` on hover, because a divider that
    /// can be dragged and does not say so is a divider nobody drags.
    private var resizeHandle: some View {
        Divider()
            .frame(width: 1)
            .overlay(Color.clear.frame(width: 8).contentShape(Rectangle()))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartWidth ?? assistant.width
                        dragStartWidth = start
                        assistant.width = UIState.clampedAssistantColumnWidth(
                            start + value.translation.width)
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        let width = assistant.width
                        documentStore?.updateUIState { $0.assistantColumnWidth = width }
                    })
    }
}
