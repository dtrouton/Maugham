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

/// **Escape closes the column, delivered by the window-scoped local monitor the
/// canvas already uses.**
///
/// The obvious alternative — a `.keyboardShortcut(.cancelAction)` on the close
/// button — is a *key equivalent*, which AppKit consults before the responder
/// chain: with the column open, Escape would stop cancelling the binder's inline
/// rename (tripwire 16) and stop dismissing the find bar, in every window. That
/// is precisely the hazard `CanvasEscapeMonitor.disposition`'s third refusal
/// exists for, and reusing that decision is what buys it here rather than
/// re-deriving three refusals (not-Escape, not-our-window, a text responder is
/// editing) that have already been measured against a real field editor.
///
/// The monitor is installed **only while a reference is up**, so a window with
/// no column in it eats no keys at all.
@MainActor
final class AssistantColumnEscape {
    private let monitor = CanvasEscapeMonitor()

    /// **Both are read at EVENT time and refreshed by every `sync`**, and
    /// neither is captured into the monitor's closure. `CanvasEscapeMonitor
    /// .install` is idempotent, so the FIRST call's closure is the one that
    /// sticks: a model captured by value there would go on dismissing a
    /// reference the writer replaced ten minutes ago, and a window captured
    /// while `ProjectWindow`'s `WindowAccessor` had not yet reported one would
    /// scope the monitor to `nil` forever — which
    /// `CanvasEscapeMonitor.disposition`'s second refusal reads as "not our
    /// window" and declines every key.
    private weak var model: AssistantColumnModel?
    private var windowSource: () -> NSWindow? = { nil }

    var isInstalled: Bool { monitor.isInstalled }

    /// Install or remove to match the model. Idempotent in both directions, so
    /// the mounting site can call it from an `.onChange` without tracking what
    /// it did last.
    func sync(model: AssistantColumnModel, window: @escaping () -> NSWindow?) {
        self.model = model
        self.windowSource = window
        guard model.studied != nil else {
            monitor.remove()
            return
        }
        monitor.install(window: { [weak self] in self?.windowSource() },
                        canvasUsesIt: { [weak self] in self?.performEscape() ?? false })
    }

    /// Give the key back unconditionally — the window is going away.
    func stop() {
        model = nil
        monitor.remove()
    }

    /// What the monitor does with an Escape it has been offered: dismiss and
    /// claim the key, or decline it so it travels on. `@discardableResult` and
    /// internal so the decision is assertable without an `NSEvent`.
    @discardableResult
    func performEscape() -> Bool {
        guard let model, model.studied != nil else { return false }
        model.dismiss()
        return true
    }

    // No `deinit` of its own: `remove()` is main-actor-isolated and `deinit` is
    // not, and `CanvasEscapeMonitor`'s own `deinit` already removes the token —
    // which is the one teardown path that cannot be reached on demand.
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
        .onChange(of: assistant.studied?.id) { _, _ in
            escape.sync(model: assistant, window: { window })
        }
        .onChange(of: activeDocId) { _, _ in assistant.dismiss() }
        .onDisappear { escape.stop() }
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
