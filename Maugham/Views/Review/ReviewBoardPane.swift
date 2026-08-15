import SwiftUI
import MaughamCore

/// **Review's centre column: the pieces × passes board** (M3 P1).
///
/// **This is Task 6's placeholder and Task 7 fills it.** What is real here is
/// everything the ROUTING turns on — the pane exists, it takes the project it
/// is about, it fills the column, and it is OPAQUE — because those are the
/// facts `ProjectWindow.manuscriptEditor`'s layered shape depends on: the
/// altitude view is still mounted underneath, and a translucent board would let
/// the corkboard read through it. What is not here yet is the board itself:
/// the pass-name column headers, the group/piece/reference rows, and the chip
/// per (piece × pass). `ReviewBoardRoutingTests` is about this file's place in
/// the stack; `ReviewBoardPaneTests` (Task 7) will be about its contents.
///
/// The `ScrollView` is not decoration. Task 7's rows scroll inside the pane and
/// never scroll the window, and a placeholder that laid its headline out in a
/// bare `VStack` would let the routing tests measure a shape the finished pane
/// does not have.
struct ReviewBoardPane: View {
    let store: ProjectStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The passes board is coming.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack {
            Text(store.manifest.title).font(.headline)
            Spacer()
        }
        .padding(8)
    }
}
