import SwiftUI
import MaughamCore
import AppKit
import os

enum ProjectActiveSheet: Identifiable, Hashable {
    case projectSettings
    case claudeDesktop
    /// **Translator's note…** (⌘⌥C, translation pipeline P2) — the paragraph
    /// the sheet is about, resolved off the caret by the key-window handler
    /// before the sheet exists. Carrying the `Target` rather than an id is
    /// what keeps the sheet from re-reading a caret that has since moved.
    case translatorsNote(TranslatorsNote.Target)
    var id: Int { hashValue }
}
