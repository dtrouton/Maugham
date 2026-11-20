import SwiftUI
import MaughamCore

/// **A statement or a piece's History, open in the centre** (shell plan 3
/// Task 5) — the `.centreItem` cover, drawn over `EditorHost` and the Book's
/// view inside `manuscriptEditor`'s one cover switch, so neither unmounts
/// when it comes or goes (tripwires 6, 27, 30). For writing an intent at
/// length.
///
/// **Today's panes, unchanged**: a statement is `StatementPane` (its editor
/// host, its rulings and readings, its proposal gate), History is
/// `HistoryPane`. A header names what is open and closes it (Close, or Esc);
/// closing clears the window's centre item and the centre shows what it
/// showed underneath.
///
/// **No mark is ever drawn here** (constitution must-not #2, ADR 0027 §1):
/// the check's marks live only in Brief's Going for, in the right column.
/// This file and `StatementPane` name no mark
/// (`CentreItemCoverTests.test_theMarksNeverReachTheCentre`).
///
/// **One host per statement**: the cover's `StatementEditorHost` is the
/// statement's while it stands; Brief and the pulled-up view draw a
/// placeholder for it (`ProjectWindow.statementIsInTheCentre`), and the
/// open gate orders the hand-over (`ProjectStore.closeStatementDocument`).
struct CentreItemCover: View {
    @Bindable var store: ProjectStore
    let documentStore: DocumentStore
    let item: CentreItem
    let bible: BibleStore?
    let world: DeclaredWorldStore?
    /// The window, for the Escape arbiter.
    let window: NSWindow?
    /// The tree's find overlay is up: Esc closes it first.
    let findIsUp: Bool
    let onClose: () -> Void

    @State private var escape = CentreItemEscape()

    /// What the cover mounts for an item. Pure.
    enum Content: Equatable {
        /// `StatementPane`, with the subject its scope resolves from.
        case statement(kind: Statement.Kind, subject: BinderSubject)
        case history(docId: String)
    }

    static func content(of item: CentreItem) -> Content {
        switch item {
        case .statement(let kind, .document(let docId)):
            return .statement(kind: kind, subject: .item(docId))
        case .statement(let kind, _):
            // The project, and a newer build's scope this one cannot name.
            return .statement(kind: kind, subject: .project)
        case .history(let docId):
            return .history(docId: docId)
        }
    }

    /// The header's title.
    static func title(of item: CentreItem, structure: [StructureItem]) -> String {
        switch item {
        case .statement(let kind, let scope):
            return StatementPane.headerCaption(kind: kind, scope: scope, structure: structure)
        case .history(let docId):
            if docId == BinderSubject.noDocumentSubject { return projectHistoryTitle }
            let title = TreeWalk.find(id: docId, in: structure)?.title ?? docId
            return "History of “\(title)”"
        }
    }

    static let projectHistoryTitle = "Project History"
    static let closeTitle = "Close"

    /// **The keys this cover asks for when it appears** (`CentreKeys`): a
    /// statement's own editor once its host binds; History, the cover. Nil
    /// for every other cover. Pure.
    static func claim(for cover: CentreCover?) -> CentreKeys.Claim? {
        guard case .centreItem(let item) = cover else { return nil }
        switch content(of: item) {
        case .statement: return .init(id: String(describing: item), prefersEditor: true)
        case .history: return .init(id: String(describing: item), prefersEditor: false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(Self.title(of: item, structure: store.manifest.structure))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Label(Self.closeTitle, systemImage: "xmark")
                }
                .buttonStyle(.borderless)
                // Esc through the window's one arbiter, never a key
                // equivalent (`CentreItemEscape`).
                .help("Close, and show what the centre showed (Esc)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        // Registered exactly while the cover is mounted, which is exactly
        // while the route draws it.
        .onAppear { syncEscape() }
        .onChange(of: window) { _, _ in syncEscape() }
        .onChange(of: findIsUp) { _, _ in syncEscape() }
        .onDisappear {
            escape.stop()
            // **The keys go back once the cover has gone** (review N4's gap):
            // driven by the cover's own disappearance, after its editor has
            // left the window, whatever closed it (Close, Esc, a place).
            CentreKeys.returnKeysToTheManuscript(in: window)
        }
    }

    private func syncEscape() {
        escape.sync(window: window, findIsUp: findIsUp, close: onClose)
    }

    @ViewBuilder
    private var content: some View {
        switch Self.content(of: item) {
        case .statement(let kind, let subject):
            StatementPane(store: store, documentStore: documentStore, kind: kind,
                          subject: subject, bible: bible, world: world)
                // One statement per mount: another item in the centre is
                // another host, never this one rebound in place.
                .id(String(describing: item))
        case .history(let docId):
            HistoryPane(
                projectURL: store.url,
                activeDocId: docId,
                allDocIds: ProjectWindow.documentIds(in: store.manifest.structure),
                device: _checkpointDeviceId,
                session: _checkpointSessionId,
                docPaths: ProjectWindow.documentPaths(in: store.manifest.structure),
                documentStore: documentStore)
                .id(String(describing: item))
        }
    }
}

/// **Escape closes the centre item's cover, as a consumer of the window's one
/// `WindowEscapeArbiter`** (review I1) — never a `.keyboardShortcut(.cancelAction)`,
/// a key equivalent AppKit consults before the responder chain, which would
/// take Esc from a ruling's edit field in the cover, the binder's inline
/// rename and the find bar (`PulledUpEscape`'s note).
///
/// Through the arbiter the cover inherits `CanvasEscapeMonitor.disposition`'s
/// refusals: while a field or a text view is being typed in (the cover's own
/// `StratumEditField`, the rename, the find field — and the statement's own
/// editor), Esc travels on to it. The claim also declines while the tree's
/// find overlay is up, whose Esc is its own. Only then does Esc close the cover.
@MainActor
final class CentreItemEscape {
    private weak var arbiter: WindowEscapeArbiter?
    private var findIsUp = false
    private var close: (() -> Void)?

    var isInstalled: Bool {
        guard let arbiter else { return false }
        return arbiter.isRegistered(.centreItem) && arbiter.isArmed
    }

    func sync(window: NSWindow?, findIsUp: Bool, close: @escaping () -> Void) {
        self.findIsUp = findIsUp
        self.close = close
        guard let window else {
            stop()
            return
        }
        let target = WindowEscapeArbiter.arbiter(for: window)
        if let previous = arbiter, previous !== target { previous.resign(.centreItem) }
        target.register(.centreItem, claim: { [weak self] in self?.performEscape() ?? false })
        arbiter = target
    }

    func stop() {
        arbiter?.resign(.centreItem)
        arbiter = nil
        close = nil
    }

    /// The arbiter's offer: close the cover and claim the key, or decline (the
    /// find overlay is up, or the cover has gone) so the offer passes on.
    @discardableResult
    func performEscape() -> Bool {
        guard let close, !findIsUp else { return false }
        close()
        return true
    }
}
