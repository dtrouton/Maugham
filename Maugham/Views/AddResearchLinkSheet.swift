import SwiftUI

struct AddResearchLinkSheet: View {
    let onAdd: (_ title: String, _ url: String) -> Void
    let onCancel: () -> Void

    @State private var title: String = ""
    @State private var urlString: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Link").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Title").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $title)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("URL").font(.caption).foregroundStyle(.secondary)
                TextField("https://example.com", text: $urlString)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add") { onAdd(title, urlString) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 380)
    }

    private var isValid: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return URL(string: urlString) != nil && !urlString.isEmpty
    }
}
