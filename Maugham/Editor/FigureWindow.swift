import SwiftUI
import AppKit

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

    /// The figures a window is open on now.
    private(set) var openFigureIds: Set<String> = []
    @ObservationIgnored private var closers: [Registration: @MainActor () -> Void] = [:]
    @ObservationIgnored private var serial = 0

    func isOpen(_ figureId: String) -> Bool { openFigureIds.contains(figureId) }

    /// A figure window is open on `figureId`; `close` closes it.
    func opened(_ figureId: String, close: @escaping @MainActor () -> Void) -> Registration {
        serial += 1
        let registration = Registration(figureId: figureId, serial: serial)
        closers[registration] = close
        recount()
        return registration
    }

    /// The window holding `registration` went. A second call does nothing.
    func closed(_ registration: Registration) {
        guard closers.removeValue(forKey: registration) != nil else { return }
        recount()
    }

    /// The project's last window went: every figure window closes. Forgotten
    /// first, so a window's own `closed` arriving during its close is a no-op.
    func closeAll() {
        let closing = Array(closers.values)
        closers = [:]
        recount()
        for close in closing { close() }
    }

    private func recount() {
        let ids = Set(closers.keys.map(\.figureId))
        if ids != openFigureIds { openFigureIds = ids }
    }
}

/// **What Format ▸ Table reaches in a figure window**: the window's own
/// `FigureGridPresence`, published as its focused value so the menu reads
/// THIS window's grid while it is key, and the verb a posted command goes to.
/// The grid mounted in the window sets both.
@MainActor
final class FigureWindowGrid {
    let presence = FigureGridPresence()
    var perform: (@MainActor (FigureTableCommand) -> Void)?
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
        Text(title)
            .font(.title3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                guard let window, note.object as? NSWindow === window, let registration else { return }
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
        let entry = session.figureWindows.opened(key.figureId) { [weak window] in
            window?.close()
        }
        registration = (session.figureWindows, entry)
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
