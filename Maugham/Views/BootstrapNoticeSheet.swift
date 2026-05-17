import SwiftUI

struct BootstrapNoticeSheet: View {
    let onDismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit history is now tracked").font(.headline)
            Text("""
            Maugham now keeps a history of every paragraph edit so you can \
            restore earlier versions. Each manuscript file will have small \
            invisible marker comments added the first time it's opened.

            Existing text is preserved exactly. Compiled output (PDF, EPUB) \
            strips the markers automatically.
            """)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 480)
            HStack {
                Spacer()
                Button("Got it") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
