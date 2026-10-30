import SwiftUI
import AppKit
import MaughamCore

// MARK: - A Research table in the grid (report plan 8b Task 7)
//
// A Research CSV selected in the tree opens in the table figures' grid
// (`FigureGridController` over a `ResearchTableHost`) — in the centre, or in
// Plan's right column beside the canvas — and saves back to its file. Not a
// figure: no `FigureWindows` hold, no figure line, none of the figure's own
// commands.

/// **One visit to a Research table's grid**: the host opened off the main
/// path, the controller and its panel mounted in `container`, the gate asked
/// over Review and the share, Format ▸ Table armed while the grid has the
/// window's keys. Leaving (the subject moved on, the window closing) commits
/// an open edit, lets the writes land and writes the file
/// (`ResearchTableHost.close`). Once only.
@MainActor
@Observable
final class ResearchTableMount {
    enum Phase: Equatable {
        case opening
        case open
        /// The file could not be read: said, never shown as an empty grid.
        case unreadable(String)
        /// Too large for the grid: shown read-only as text, with this line.
        case tooLarge(String)
    }

    let itemId: String
    private(set) var phase: Phase = .opening

    /// The view the panel is mounted in.
    @ObservationIgnored let container = FigureWindowGridContainer()
    @ObservationIgnored private(set) var host: ResearchTableHost?
    @ObservationIgnored private(set) var controller: FigureGridController?
    /// Opening the visit (a test awaits it).
    @ObservationIgnored private(set) var opening: Task<Void, Never>?
    /// The visit ending after the mount left (a test awaits it).
    @ObservationIgnored private(set) var finishing: Task<Void, Never>?
    @ObservationIgnored private(set) var hasLeft = false
    @ObservationIgnored private(set) var readOnly: Bool
    @ObservationIgnored private(set) var shareIsReadOnly: Bool
    @ObservationIgnored private let presence: FigureGridPresence?
    @ObservationIgnored private var panel: FigureGridPanel?
    @ObservationIgnored private var keysWatch: NSKeyValueObservation?
    @ObservationIgnored private var bookWatch: Task<Void, Never>?
    @ObservationIgnored private weak var store: DocumentStore?
    /// This grid's settler on the shared host (`ResearchTableHost.addSettler`).
    @ObservationIgnored private let settlerId = UUID()
    @ObservationIgnored private var focusWatch: NSObjectProtocol?

    init(itemId: String, readOnly: Bool, shareIsReadOnly: Bool, presence: FigureGridPresence?) {
        self.itemId = itemId
        self.readOnly = readOnly
        self.shareIsReadOnly = shareIsReadOnly
        self.presence = presence
    }

    /// **Open the visit**: the host reads the file (writing nothing), the
    /// controller opens over it, and the grid mounts with the gate asked.
    func open(title: String, store: DocumentStore, projectStore: ProjectStore, typography: TypographySettings) {
        guard opening == nil, !hasLeft else { return }
        container.show(message: "Opening \(title)\u{2026}")
        self.store = store
        opening = Task { @MainActor [weak self, itemId] in
            let host: ResearchTableHost
            do {
                host = try await store.openResearchTable(itemId: itemId)
            } catch let tooLarge as ResearchTableHost.TooLarge {
                self?.phase = .tooLarge(tooLarge.localizedDescription)
                return
            } catch {
                self?.phase = .unreadable(error.localizedDescription)
                return
            }
            guard let self, !self.hasLeft else { return await store.releaseResearchTable(host) }
            self.host = host
            do {
                let controller = try await FigureGridController.open(
                    researchTable: host, title: title, store: store, projectStore: projectStore,
                    typography: typography)
                guard !self.hasLeft else {
                    controller.close()
                    return await store.releaseResearchTable(host)
                }
                self.mount(controller, host: host, store: store)
            } catch {
                self.phase = .unreadable(error.localizedDescription)
                self.host = nil
                await store.releaseResearchTable(host)
            }
        }
    }

    private func mount(_ controller: FigureGridController, host: ResearchTableHost, store: DocumentStore) {
        self.controller = controller
        // ⌘S, ⌘Q and a verb about to read the file commit what is typed here first.
        host.addSettler(settlerId) { [weak controller] in
            guard let controller else { return }
            controller.commitWhatIsTyped()
            await controller.settleWrites()
        }
        controller.foldsOnEscape = false   // Esc leaves no centre
        controller.bars.doneButton.isHidden = true   // nothing to close
        controller.onAccessMayHaveChanged = { [weak self] in self?.refreshAccess() }
        controller.onMenuStateChange = { [weak self] _ in self?.showPresence() }
        refreshAccess()
        let panel = FigureGridPanel(bars: controller.bars, gridView: controller.gridView)
        self.panel = panel
        container.mount(panel)
        controller.gridView.reloadData()
        phase = .open
        watchTheKeys()
        watchTheBook(store)
        Task { @MainActor in await host.fileMayHaveChanged() }
    }

    /// **The gate**: Review (`!Persona.editsResearchInTheCentre`) and a
    /// view-only share read the table. The share is the project's, so the
    /// shared host refuses every edit under it too; Review is this window's,
    /// so it is this grid's gate alone (as a figure's is).
    func refreshAccess() {
        guard let controller, let host, !hasLeft else { return }
        let mode = FigureGridGate.mode(
            figureMayEdit: true, parked: false, hostClosed: host.isClosed,
            shareIsReadOnly: shareIsReadOnly, isReviewMode: readOnly, isTranslationReview: false)
        host.refusal = shareIsReadOnly ? .viewOnlyShare : nil
        guard mode != controller.mode else { return }
        controller.setAccess(mode, captionMayEdit: false)
    }

    /// The view's inputs changed: the gate is asked again.
    func update(readOnly: Bool, shareIsReadOnly: Bool) {
        guard readOnly != self.readOnly || shareIsReadOnly != self.shareIsReadOnly else { return }
        self.readOnly = readOnly
        self.shareIsReadOnly = shareIsReadOnly
        refreshAccess()
    }

    /// **Format ▸ Table**, while the grid has the keys.
    func perform(_ command: FigureTableCommand) {
        guard hasTheKeys else { return }
        controller?.performTableCommand(command)
    }

    /// **The mount leaves** — the subject moved on or the window is closing:
    /// an open edit that reads is committed (one that will not is said), the
    /// writes land, and the file is written once more if anything is pending.
    func leave() {
        guard !hasLeft else { return }
        hasLeft = true
        keysWatch = nil
        container.onWindowChange = nil
        bookWatch?.cancel()
        if let focusWatch { NotificationCenter.default.removeObserver(focusWatch) }
        focusWatch = nil
        presence?.folded()
        guard let controller, let host else { return }
        host.removeSettler(settlerId)
        controller.onAccessMayHaveChanged = nil
        controller.onMenuStateChange = nil
        controller.foldForced()
        controller.didFold()
        panel?.removeFromSuperview()
        let store = store
        let finishing = Task { @MainActor [weak self] in
            await controller.settleWrites()
            controller.close()
            await host.flush()
            await store?.releaseResearchTable(host)
            self?.controller = nil
            self?.panel = nil
        }
        self.finishing = finishing
        host.addEndingVisit(finishing)
    }

    // MARK: The keys and the book

    /// The grid, its cell editor or its bars have the window's keys.
    var hasTheKeys: Bool {
        guard let panel, let responder = container.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: panel)
    }

    /// The window's presence says what Format ▸ Table may do while the grid
    /// has the keys, and nothing while it has not.
    private func showPresence() {
        guard let presence, let controller, !hasLeft else { return }
        if hasTheKeys {
            presence.expanded()
            presence.show(controller.menuState)
        } else {
            presence.folded()
        }
    }

    private func watchTheKeys() {
        let observe = { [weak self] (window: NSWindow?) in
            guard let self else { return }
            // The window coming front: a file changed outside meanwhile is read again.
            if let focusWatch = self.focusWatch { NotificationCenter.default.removeObserver(focusWatch) }
            self.focusWatch = window.map { window in
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, !self.hasLeft, let host = self.host else { return }
                        Task { @MainActor in await host.fileMayHaveChanged() }
                    }
                }
            }
            self.keysWatch = window?.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.showPresence() }
            }
            self.showPresence()
        }
        container.onWindowChange = observe
        observe(container.window)
    }

    /// Another figure — or this table's own save — may have changed what its
    /// formulas read: each `figureRevision` edge reseeds the values.
    private func watchTheBook(_ store: DocumentStore) {
        guard !hasLeft else { return }
        weak let store = store
        withObservationTracking {
            _ = store?.figureRevision
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.hasLeft else { return }
                self.bookWatch = Task { @MainActor [weak self] in
                    guard let self, !self.hasLeft, let store else { return }
                    await self.controller?.figureCardsChanged()
                    self.watchTheBook(store)
                }
            }
        }
    }
}

/// **A Research table in the grid** — `ResearchSubjectCentre`'s `.table`
/// route, and the Plan right column's preview of one. The file that cannot be
/// read says why; it never shows an empty grid. Mount with `.id(itemId)`.
struct ResearchTableGrid: View {
    let itemId: String
    let title: String
    let store: ProjectStore
    let documentStore: DocumentStore
    let typography: TypographySettings
    /// `!Persona.editsResearchInTheCentre` — Review reads, never edits.
    let readOnly: Bool
    let shareIsReadOnly: Bool
    /// The project window's presence, which Format ▸ Table reads.
    var presence: FigureGridPresence? = nil
    /// The project window, whose close and key-window posts reach this grid.
    var window: NSWindow? = nil

    @State private var mount: ResearchTableMount?

    private struct Access: Equatable {
        let readOnly: Bool, shareIsReadOnly: Bool
    }

    var body: some View {
        ZStack {
            if case .unreadable(let message)? = mount?.phase {
                ContentUnavailableView {
                    Label("This table can’t be read", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("\(message)\n\nIt has not been changed.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .tooLarge(let line)? = mount?.phase,
                      let item = TreeWalk.find(id: itemId, in: store.manifest.research) {
                // Past the grid's ceiling: read-only text, as before the grid.
                VStack(spacing: 0) {
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(8)
                    ResearchPreview(projectURL: store.url, item: item)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if let mount {
                FigureWindowGridHost(container: mount.container)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            let mount = ResearchTableMount(
                itemId: itemId, readOnly: readOnly, shareIsReadOnly: shareIsReadOnly, presence: presence)
            self.mount = mount
            mount.open(title: title, store: documentStore, projectStore: store, typography: typography)
        }
        .onDisappear { mount?.leave() }
        .onChange(of: Access(readOnly: readOnly, shareIsReadOnly: shareIsReadOnly)) { _, next in
            mount?.update(readOnly: next.readOnly, shareIsReadOnly: next.shareIsReadOnly)
        }
        // The window's close: the grid's last edit is written before the store closes.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard let window, note.object as? NSWindow === window else { return }
            mount?.leave()
        }
        .onKeyWindowCommand(.maughamFigureTableCommand, window: window) { note in
            guard let command = note.userInfo?[MaughamEvent.figureTableCommandKey] as? FigureTableCommand
            else { return }
            mount?.perform(command)
        }
    }
}
