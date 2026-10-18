import SwiftUI

enum ProjectActiveSheet: Identifiable, Hashable {
    case projectSettings
    case claudeDesktop
    /// **Translator's note…** (⌘⌥C) — the paragraph the sheet is about,
    /// resolved off the caret before the sheet exists. Carrying the `Target`
    /// rather than an id keeps the sheet from re-reading a moved caret.
    case translatorsNote(TranslatorsNote.Target)
    var id: Int { hashValue }
}
