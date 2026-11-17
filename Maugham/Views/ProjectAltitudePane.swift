import SwiftUI
import MaughamCore

/// **The Book — or a Part, a small Book over its own chapters — in one of its
/// three views**: Cards, Outline, Status. The header's picker is the one
/// control that moves `bookView`; Status is the passes board, a view of the
/// Book and never a cover (`CentreRoute.editor(altitude:cover:)`).
///
/// The board arrives as a view built by its one mount (`CentreColumn`, which
/// owns its open-notes counts and verbs); this pane only places it.
struct ProjectAltitudePane<Status: View>: View {
    @Bindable var store: ProjectStore
    /// The view the route chose (`ProjectWindow.altitudeView`) — what draws.
    let view: BookView
    /// The window's remembered view — what the picker writes.
    @Binding var bookView: BookView
    @Binding var selectedSubject: BinderSubject?
    let title: String
    /// The pieces this view lays out: the whole manuscript, or a Part's own.
    let structure: [StructureItem]
    /// Whether the picker offers Status: an edition's book stands over Cards
    /// or Outline only.
    var offersStatus: Bool = true
    @ViewBuilder let status: () -> Status

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch view {
            case .status:
                status()
            case .outline, .cards:
                if structure.isEmpty {
                    ContentUnavailableView {
                        Label("No items yet", systemImage: "list.bullet.indent")
                    } description: {
                        Text("Add chapters or scenes from the Manuscript binder")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if view == .outline {
                    OutlineTable(
                        items: TreeWalk.collect(in: structure, where: { $0.type == .document }),
                        store: store,
                        selectedSubject: $selectedSubject)
                } else {
                    CorkboardGrid(
                        items: TreeWalk.collect(in: structure, where: { $0.type == .document }),
                        store: store,
                        selectedSubject: $selectedSubject)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Picker("View", selection: $bookView) {
                Image(systemName: "rectangle.grid.2x2").tag(BookView.cards)
                    .help("Cards")
                Image(systemName: "list.bullet").tag(BookView.outline)
                    .help("Outline")
                if offersStatus {
                    Image(systemName: "checklist").tag(BookView.status)
                        .help("Status")
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(8)
        .onChange(of: bookView) { _, newValue in
            store.documentStore?.updateUIState { $0.bookView = newValue }
        }
    }

}
