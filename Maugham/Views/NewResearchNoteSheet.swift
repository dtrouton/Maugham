import SwiftUI

/// Minimal title prompt for creating a research note from the right pane
/// (which has no inline-rename affordance, unlike the binder rows).
struct NewResearchNoteSheet: View {
    @State private var title: String = ""
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Research Note").font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 300)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    onCreate(title.trimmingCharacters(in: .whitespaces).isEmpty
                             ? "Untitled Note" : title)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}
