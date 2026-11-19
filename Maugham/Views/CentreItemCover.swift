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
    let onClose: () -> Void

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
            let title = TreeWalk.find(id: docId, in: structure)?.title ?? docId
            return "History of “\(title)”"
        }
    }

    static let closeTitle = "Close"

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
                .keyboardShortcut(.cancelAction)
                .help("Close, and show what the centre showed (Esc)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
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
