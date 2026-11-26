import SwiftUI
import MaughamCore

/// **The Book — or a Part, a small Book over its own chapters — in one of its
/// three views**: Cards, Outline, Status. The header is the title alone: the
/// switch between the views is the window toolbar's (`CentreViewSwitch`,
/// shell p4 Task 4). Status is the passes board, a view of the Book and never
/// a cover (`CentreRoute.editor(altitude:cover:)`).
///
/// The board arrives as a view built by its one mount (`CentreColumn`, which
/// owns its open-notes counts and verbs); this pane only places it.
struct ProjectAltitudePane<Status: View>: View {
    @Bindable var store: ProjectStore
    /// The view the route chose (`ProjectWindow.altitudeView`) — what draws.
    let view: BookView
    @Binding var selectedSubject: BinderSubject?
    let title: String
    /// The pieces this view lays out: the whole manuscript, or a Part's own.
    let structure: [StructureItem]
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
                        Text("Add your first \(PieceNoun.of(nil, in: store.manifest).singular) from the binder")
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
        }
        .padding(8)
    }

}
