import SwiftUI

struct OutlinePane: View {
    @Bindable var store: ProjectStore
    @Binding var layout: OutlineLayout
    @Binding var selectedItemId: String?

    var body: some View {
        Text("Outline (T8)")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
