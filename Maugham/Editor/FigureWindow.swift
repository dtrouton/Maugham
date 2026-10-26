import SwiftUI
import AppKit
import MaughamCore

// MARK: - The figure window (report plan 7d Task 8)
//
// A table can pop out into its own window: the same grid in a different
// frame, against the project window's `DocumentStore` (one figure host per
// store). The window takes NO borrow of the project's session — it closes
// with its project (Denver 2026-10-25) and never restores on relaunch, so a
// figure window without its project never exists.

/// **Which figure a figure window shows**: its project and the figure's id.
/// The value of the `figure` `WindowGroup`, so opening a figure already in a
/// window brings that window to the front rather than opening a second.
struct FigureWindowKey: Codable, Hashable {
    /// The `WindowGroup`'s id, spelled once.
    static let sceneID = "figure"

    let projectURL: URL
    let figureId: String
}

/// **The figure windows open on one project** (R7d-5, R7d-9), held by its
/// `ProjectSession`. A figure window registers here instead of borrowing the
/// session, with the verb that closes it; the session closes every one when
/// its last project window detaches (`ProjectSession.detachWindow`), and at
/// its close. `isOpen` is what a card asks before it says "Editing in window".
@MainActor
@Observable
final class FigureWindows {
    /// One window's place here, owed one `closed`.
    struct Registration: Hashable {
        let figureId: String
        fileprivate let serial: Int
    }

    /// **What the grid opening a window hands it** (plan 7d Task 9): the
    /// figure line's "Table N" and caption as the text writes them (shown
    /// read-only in the window, R7d-6), the piece whose Research Send to
    /// Research defaults to, and the editor's typography — what only the
    /// project window's editor knows. The number and caption then follow
    /// the book (`lineChanged`).
    struct Handoff: Equatable {
        var number: String
        var caption: String
        var piece: String?
        var typography: TypographySettings
    }

    /// **The share is view-only** — set by the project windows' editors from
    /// their control plane whenever it changes (`EditorCoordinator.
    /// setShareIsReadOnly`); a figure window's gate reads it live.
    @ObservationIgnored private(set) var shareIsReadOnly = false

    /// A figure window's grid listening for its line and its access.
    struct Listener: Hashable {
        let figureId: String
        fileprivate let serial: Int
    }
    private struct Listening {
        let line: @MainActor (_ number: String, _ caption: String) -> Void
        let access: @MainActor () -> Void
    }
    @ObservationIgnored private var listeners: [Listener: Listening] = [:]

    /// The figures a window is open on now.
    private(set) var openFigureIds: Set<String> = []
    @ObservationIgnored private var closers: [Registration: @MainActor () -> Void] = [:]
    @ObservationIgnored private var focusers: [Registration: @MainActor () -> Void] = [:]
    @ObservationIgnored private var handoffs: [String: Handoff] = [:]
    @ObservationIgnored private var serial = 0

    func isOpen(_ figureId: String) -> Bool { openFigureIds.contains(figureId) }

    /// A figure window is open on `figureId`; `close` closes it, `focus`
    /// brings it front and makes it key.
    func opened(_ figureId: String, focus: @escaping @MainActor () -> Void = {},
                close: @escaping @MainActor () -> Void) -> Registration {
        serial += 1
        let registration = Registration(figureId: figureId, serial: serial)
        closers[registration] = close
        focusers[registration] = focus
        recount()
        return registration
    }

    /// The window holding `registration` went. A second call does nothing.
    func closed(_ registration: Registration) {
        focusers[registration] = nil
        guard closers.removeValue(forKey: registration) != nil else { return }
        recount()
    }

    /// **R7d-9**: the window open on `figureId` comes front and takes the
    /// keys — a double-click or Return on its card asks this instead of
    /// expanding. False when no window is open on it.
    @discardableResult
    func focus(_ figureId: String) -> Bool {
        guard let focus = focusers.first(where: { $0.key.figureId == figureId })?.value else { return false }
        focus()
        return true
    }

    /// The grid about to open `figureId` in a window leaves what it knows.
    func handOff(_ figureId: String, _ handoff: Handoff) { handoffs[figureId] = handoff }

    /// What the last grid to open `figureId` in a window left, if any (its
    /// number and caption as last told).
    func handoff(for figureId: String) -> Handoff? { handoffs[figureId] }

    /// A figure window's grid listens: `line` with the figure line's "Table
    /// N" and caption when the book's index says they changed, `access`
    /// when the share flips.
    func listen(_ figureId: String, line: @escaping @MainActor (String, String) -> Void,
                access: @escaping @MainActor () -> Void) -> Listener {
        serial += 1
        let listener = Listener(figureId: figureId, serial: serial)
        listeners[listener] = Listening(line: line, access: access)
        return listener
    }

    func stopListening(_ listener: Listener) { listeners[listener] = nil }

    /// **The figure line's number or caption, as the book now has them**
    /// (the project editors' `ReferenceIndex`, at each of its versions): the
    /// hand-off follows, and each window on the figure is told.
    func lineChanged(_ figureId: String, number: String, caption: String) {
        if var handoff = handoffs[figureId], handoff.number != number || handoff.caption != caption {
            handoff.number = number
            handoff.caption = caption
            handoffs[figureId] = handoff
        }
        for (listener, listening) in listeners where listener.figureId == figureId {
            listening.line(number, caption)
        }
    }

    /// The share turned view-only, or back: every figure window asks its gate again.
    func setShareIsReadOnly(_ readOnly: Bool) {
        guard shareIsReadOnly != readOnly else { return }
        shareIsReadOnly = readOnly
        for listening in listeners.values { listening.access() }
    }

    /// The project's last window went: every figure window closes. Forgotten
    /// first, so a window's own `closed` arriving during its close is a no-op.
    func closeAll() {
        let closing = Array(closers.values)
        closers = [:]
        focusers = [:]
        recount()
        for close in closing { close() }
    }

    private func recount() {
        let ids = Set(closers.keys.map(\.figureId))
        if ids != openFigureIds { openFigureIds = ids }
    }
}

/// **The grid in a figure window** (plan 7d Tasks 8–9): the same visit the
/// in-place card opens (`FigureGridController`, the grid's one writer) in
/// the same panel (`FigureGridPanel`), against the project window's
/// `DocumentStore` — one figure host per store, so the card and the window
/// share it. What differs is the frame:
///
/// - **Its own undo for its life** (R7d-5): the controller's `gridUndo`,
///   answered by the grid and the panel; the host records no visit here, so
///   closing the window adds no step to any text's stack.
/// - **The caption is read-only** (R7d-6: it is the figure line's text,
///   which needs the editor); the name may be changed. The bottom bar shows
///   "Table N" and the caption the opening grid handed over, then whatever
///   the book's index says as it changes (`FigureWindows.lineChanged`).
/// - **It never goes stale.** Its own card cache, attached to the store's
///   figure triggers as a project window's is, reseeds the values at each
///   version (another figure this one reads changed) and asks the gate
///   again (a park); the gate is asked of the window's door (`.editFigure`,
///   observed by the controller), the host (parked, closed) and the share
///   as the project windows last told it (`FigureWindows.shareIsReadOnly`).
///   There is no review mode here.
/// - **Done closes the window**, and ⌘W; Esc with nothing to cancel does
///   nothing. Send to Research closes it first (R7d-7).
/// - **Closing ends the visit** (`finish`, from the window's `willClose`):
///   an open edit committed (or said), the writes landed, the visit closed.
///
/// Format ▸ Table reaches it through `presence` (the window's focused value)
/// and `perform`.
@MainActor
final class FigureWindowGrid {
    let presence = FigureGridPresence()
    var perform: (@MainActor (FigureTableCommand) -> Void)?
    /// The view the panel is mounted in (the window's content).
    let container = FigureWindowGridContainer()
    /// The visit, once it has opened.
    private(set) var controller: FigureGridController?
    private(set) var panel: FigureGridPanel?
    /// Opening the visit (a test awaits it).
    private(set) var opening: Task<Void, Never>?
    /// The visit ending after the window closed (a test awaits it).
    private(set) var finishing: Task<Void, Never>?
    /// The reseed the last card version scheduled (a test awaits it).
    private(set) var reseeding: Task<Void, Never>?
    private(set) var isFinished = false
    private weak var store: DocumentStore?
    private weak var windows: FigureWindows?
    private var listener: FigureWindows.Listener?
    /// The window's figure cards, filled from the store's triggers.
    private var cards: FigureCardCache?
    /// The line as last told, for a visit still opening.
    private var line: (number: String, caption: String)?

    /// **Open the visit** on `figureId` through the project window's stores,
    /// with what the opening grid handed over (`windows.handoff`); the grid
    /// mounts when it has opened. `close` closes the window. Once only.
    func open(figureId: String, store: DocumentStore, projectStore: ProjectStore, windows: FigureWindows,
              close: @escaping @MainActor () -> Void) {
        guard opening == nil, !isFinished else { return }
        self.store = store
        self.windows = windows
        let handoff = windows.handoff(for: figureId)
        listener = windows.listen(figureId, line: { [weak self] number, caption in
            self?.refreshLine(number: number, caption: caption)
        }, access: { [weak self] in
            self?.refreshAccess()
        })
        let line = FigureGridController.Line(
            number: handoff?.number ?? ElementWords.english.table,
            caption: handoff?.caption ?? "",
            commitCaption: { _ in false })   // R7d-6: the caption is the text's
        opening = Task { @MainActor [weak self] in
            do {
                let controller = try await FigureGridController.open(
                    figureId: figureId, store: store, projectStore: projectStore,
                    typography: handoff?.typography ?? .defaults, line: line)
                guard let self, !self.isFinished else {
                    controller.close()
                    return
                }
                self.mount(controller, piece: handoff?.piece, close: close)
            } catch {
                guard let self, !self.isFinished else { return }
                self.container.show(message: "The table couldn\u{2019}t be opened: \(error.localizedDescription)")
            }
        }
    }

    private func mount(_ controller: FigureGridController, piece: String?,
                       close: @escaping @MainActor () -> Void) {
        self.controller = controller
        controller.researchPiece = piece
        controller.foldsOnEscape = false   // Esc closes no window
        controller.onFold = close   // Done
        controller.onSendToResearch = close   // the window goes first (R7d-7)
        controller.onAccessMayHaveChanged = { [weak self] in self?.refreshAccess() }
        controller.onMenuStateChange = { [weak self] state in
            guard let self, !self.isFinished else { return }
            self.presence.show(state)
        }
        if let line { controller.refreshLine(number: line.number, caption: line.caption) }
        perform = { [weak controller] command in controller?.performTableCommand(command) }
        refreshAccess()
        presence.expanded()
        presence.show(controller.menuState)
        watchTheBook()
        let panel = FigureGridPanel(bars: controller.bars, gridView: controller.gridView)
        self.panel = panel
        container.mount(panel)
        controller.gridView.reloadData()
        container.window?.makeFirstResponder(controller.gridView)
    }

    /// The window's own card cache over the store, as a project window's:
    /// each version reseeds the values and asks the gate again.
    private func watchTheBook() {
        guard let store else { return }
        let cards = FigureCardCache()
        cards.onVersionChange = { [weak self] _ in
            guard let self, !self.isFinished, let controller = self.controller else { return }
            self.refreshAccess()
            self.reseeding = Task { @MainActor in await controller.figureCardsChanged() }
        }
        store.attachFigureCardCache(cards)
        cards.attach(FigureCardCache.Source(read: { [weak store] in await store?.figureCardInputs() }))
        self.cards = cards
    }

    /// **The figure line's "Table N" and caption changed** in the book.
    func refreshLine(number: String, caption: String) {
        guard !isFinished else { return }
        line = (number, caption)
        controller?.refreshLine(number: number, caption: caption)
    }

    /// **The gate, asked again** over the window's door, the host and the
    /// share. The caption stays locked (R7d-6).
    func refreshAccess() {
        guard let controller, !isFinished else { return }
        let mode = FigureGridGate.mode(
            figureMayEdit: store?.posture(forDocId: controller.figureId).allows(.editFigure) ?? false,
            parked: controller.host.state.parked != nil, hostClosed: controller.host.isClosed,
            shareIsReadOnly: windows?.shareIsReadOnly ?? false, isReviewMode: false, isTranslationReview: false)
        let access: FigureGridGate.Mode = mode == .noExpand ? .readOnly(.closed) : mode
        guard access != controller.mode || controller.captionMayEdit else { return }
        controller.setAccess(access, captionMayEdit: false)
    }

    /// **The window is closing**: an open edit that reads is committed, one
    /// that will not is said with its text; the visit closes once its
    /// writes have landed. No step is registered anywhere (R7d-5). Once only.
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        opening?.cancel()
        presence.folded()
        if let listener { windows?.stopListening(listener) }
        if let cards {
            cards.attach(nil)
            store?.detachFigureCardCache(cards)
        }
        guard let controller else { return }
        controller.onFold = nil
        controller.onSendToResearch = nil
        controller.foldForced()
        controller.didFold()
        panel?.removeFromSuperview()
        finishing = Task { @MainActor in
            await controller.settleWrites()
            controller.close()
        }
    }
}

/// **The figure window's content view**: the grid's panel filling it, or a
/// line saying the table is opening or could not be opened.
final class FigureWindowGridContainer: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var message: String { label.stringValue }

    func show(message: String) {
        label.stringValue = message
        label.isHidden = false
        layoutLabel()
    }

    func mount(_ panel: FigureGridPanel) {
        label.isHidden = true
        panel.frame = bounds
        panel.autoresizingMask = [.width, .height]
        addSubview(panel)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutLabel()
    }

    private func layoutLabel() {
        let height = label.intrinsicContentSize.height
        label.frame = CGRect(x: 16, y: (bounds.height - height) / 2, width: max(0, bounds.width - 32), height: height)
    }
}

/// The container, as SwiftUI shows it.
private struct FigureWindowGridHost: NSViewRepresentable {
    let container: FigureWindowGridContainer
    func makeNSView(context: Context) -> FigureWindowGridContainer { container }
    func updateNSView(_ nsView: FigureWindowGridContainer, context: Context) {}
}

/// **A figure window's root view.** It finds its project's session without
/// borrowing it (`ProjectSessionRegistry.session(for:)`) and registers with
/// the session's `FigureWindows`; with no project window open on the session
/// — a relaunch, or a project closed meanwhile — it closes at once.
struct FigureWindow: View {
    let key: FigureWindowKey
    @Environment(ProjectSessionRegistry.self) private var sessions
    @State private var window: NSWindow?
    @State private var grid: FigureWindowGrid
    /// Where this window is registered, once it is.
    @State private var registration: (windows: FigureWindows, entry: FigureWindows.Registration)?

    /// `grid` is a test's; the window makes its own.
    @MainActor
    init(key: FigureWindowKey, grid: FigureWindowGrid? = nil) {
        self.key = key
        _grid = State(initialValue: grid ?? FigureWindowGrid())
    }

    /// The session a project window holds open, or nil: a figure window never
    /// outlives its project's windows.
    private var session: ProjectSession? {
        guard let session = sessions.session(for: key.projectURL),
              session.attachment != nil else { return nil }
        return session
    }

    private var title: String {
        session?.projectStore.manifest.figures?.first { $0.id == key.figureId }?.name ?? "Table"
    }

    var body: some View {
        FigureWindowGridHost(container: grid.container)
            .frame(minWidth: 480, minHeight: 320)
            .background(WindowAccessor(window: $window))
            .navigationTitle(title)
            .modifier(FigureTableMenuModifier(presence: grid.presence))
            .onKeyWindowCommand(.maughamFigureTableCommand, window: window) { note in
                guard let command = note.userInfo?[MaughamEvent.figureTableCommandKey] as? FigureTableCommand
                else { return }
                grid.perform?(command)
            }
            .onChange(of: window.map(ObjectIdentifier.init), initial: true) { seat() }
            // The close itself, not `.onDisappear`: a window closed by its
            // project, by the writer or by a test leaves the list at once.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
                guard let window, note.object as? NSWindow === window else { return }
                grid.finish()   // the visit ends with the window
                guard let registration else { return }
                registration.windows.closed(registration.entry)
                self.registration = nil
            }
    }

    /// Once the window is known: an orphan closes, any other registers and is
    /// made never to restore (the scene says so too).
    private func seat() {
        guard let window, registration == nil else { return }
        window.isRestorable = false
        guard let session else {
            window.close()
            return
        }
        let entry = session.figureWindows.opened(key.figureId, focus: { [weak window] in
            window?.makeKeyAndOrderFront(nil)
        }, close: { [weak window] in
            window?.close()
        })
        registration = (session.figureWindows, entry)
        grid.container.show(message: "Opening \(title)\u{2026}")
        grid.open(figureId: key.figureId, store: session.documentStore, projectStore: session.projectStore,
                  windows: session.figureWindows, close: { [weak window] in window?.close() })
    }
}

// MARK: - Opening

extension MaughamEvent {
    static let figureWindowFigureIdKey = "figure_window_figure_id"

    /// **The one spelling of the open-in-window post**: the key window opens
    /// `figureId` in its own figure window, or brings the open one front.
    static func postOpenFigureWindow(figureId: String) {
        post(.maughamOpenFigureWindow, to: .keyWindow, payload: [figureWindowFigureIdKey: figureId])
    }
}

/// The project window's answer to `maughamOpenFigureWindow`: `openWindow`
/// lives in SwiftUI's environment, which the editor's coordinator has not.
struct FigureWindowOpenModifier: ViewModifier {
    let projectURL: URL
    let window: NSWindow?
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onKeyWindowCommand(.maughamOpenFigureWindow, window: window) { note in
            guard let key = Self.key(for: note, projectURL: projectURL) else { return }
            openWindow(id: FigureWindowKey.sceneID, value: key)
        }
    }

    /// The window a post asks for, on this window's project.
    static func key(for note: Notification, projectURL: URL) -> FigureWindowKey? {
        guard let figureId = note.userInfo?[MaughamEvent.figureWindowFigureIdKey] as? String
        else { return nil }
        return FigureWindowKey(projectURL: projectURL, figureId: figureId)
    }
}
