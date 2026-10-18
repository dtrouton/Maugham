import SwiftUI

/// The one-line outcome alert for a **translator's note** that could not be
/// written — `restoreOutcome`'s alert, its own word. A modifier because an
/// `.alert` with a derived `Binding` inline has pushed `ProjectWindow.body`
/// over the type-check ceiling before.
@MainActor
struct NoteOutcomeAlert: ViewModifier {
    @Binding var outcome: String?

    func body(content: Content) -> some View {
        content.alert(
            "Translator\u{2019}s Note",
            isPresented: Binding(get: { outcome != nil },
                                 set: { if !$0 { outcome = nil } })
        ) {
            Button("OK", role: .cancel) { outcome = nil }
        } message: {
            Text(outcome ?? "")
        }
    }
}
