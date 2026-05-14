import SwiftUI

// Temporary stub — T6 replaces with the real picker
struct ResearchLinkPickerSheet: View {
    @Bindable var store: ProjectStore
    let documentId: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            Text("Picker (T6)")
            Button("Done") { dismiss() }
        }
        .padding()
        .frame(minWidth: 300, minHeight: 150)
    }
}
