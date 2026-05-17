import SwiftUI

struct CheckpointLabelPromptSheet: View {
    @State private var label: String = ""
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name this checkpoint").font(.headline)
            TextField("e.g. end of draft 2", text: $label)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Save") { onConfirm(label) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}
