import SwiftUI

struct LinkedResearchPane: View {
    @Bindable var store: ProjectStore
    let activeDocumentId: String?

    var body: some View {
        Text("Linked Research (T5)")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
