import SwiftUI

/// Stub — full implementation in Task 14.
struct AddResearchLinkSheet: View {
    let onAdd: (_ title: String, _ url: String) -> Void
    let onCancel: () -> Void

    @State private var title: String = ""
    @State private var urlString: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Link").font(.headline)
            TextField("Title", text: $title)
            TextField("URL", text: $urlString)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Add") { onAdd(title, urlString) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.isEmpty || urlString.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
