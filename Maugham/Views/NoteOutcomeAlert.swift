import SwiftUI
import MaughamCore
import AppKit
import os

/// The one-line outcome banner for a **translator's note** that could not be
/// written (translation pipeline P2) — `restoreOutcome`'s alert, its own word.
///
/// Extracted as a `ViewModifier` for this file's standing reason:
/// `ProjectWindow.body` sits at SwiftUI's type-checker ceiling, and an
/// `.alert` with a derived `Binding` in line is exactly the shape that has
/// pushed it over before.
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
