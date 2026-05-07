import SwiftUI

/// Milestone-1a placeholder editor. Just a SwiftUI TextEditor bound to the
/// manuscript text. Replaced by EditorSurface in milestone 1b.
struct PlaceholderEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 16, weight: .regular, design: .serif))
            .lineSpacing(4)
            .padding(24)
            .background(Color(NSColor.textBackgroundColor))
    }
}

#Preview {
    @Previewable @State var text = "Once upon a time..."
    return PlaceholderEditor(text: $text)
        .frame(width: 600, height: 400)
}
