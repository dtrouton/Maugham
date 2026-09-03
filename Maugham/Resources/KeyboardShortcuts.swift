import Foundation

/// Curated catalog of keyboard shortcuts surfaced via the Help → Syntax
/// Reference sheet's Keyboard tab, and the list `docs/guide/reference.md`
/// sends readers to as the full one.
///
/// Curated, so it is deliberately not every binding `MaughamApp.commands`
/// declares — but the ⌘⌥ family is no longer left to a manual smoke:
/// `DocSyncTests.test_paneShortcutsDocumentedInTheInAppCheatsheet` requires
/// every ⌘⌥ shortcut in `MaughamApp.swift` to appear here, `.shift`-carrying
/// ones included. That guard exists because Toggle Review Mode moved to ⌘⌥⇧R
/// in the persona shell and vanished from this list and from `docs/guide/`
/// together, with the older, narrower guard unable to see it.
/// Everything outside that family is still hand-maintained.
public enum KeyboardShortcuts {
    public struct Category {
        public let category: String
        public let items: [Entry]
    }
    public struct Entry {
        public let label: String
        public let shortcut: String
    }

    public static let all: [Category] = [
        Category(category: "File", items: [
            Entry(label: "New Project…",            shortcut: "⌘N"),
            Entry(label: "Open Project…",           shortcut: "⌘O"),
            Entry(label: "Save",                    shortcut: "⌘S"),
            // Both added 2026-08-04, from the sweep that found Toggle Review
            // Mode missing. Neither is in the ⌘⌥ family the guard covers, so
            // nothing would have caught their absence — `Promote…` in
            // particular is a primary canvas verb with a great deal of
            // documentation and had no entry on either surface.
            Entry(label: "Save Checkpoint As…",     shortcut: "⌘⇧S"),
            Entry(label: "Check Writing",           shortcut: "⌘R"),
            // Same reason as the two above: ⌘⇧R is outside the ⌘⌥ family
            // `DocSyncTests`' cheatsheet guard covers, so nothing would report
            // its absence (M3-P3 Task 6).
            Entry(label: "Fresh Eyes",              shortcut: "⌘⇧R"),
            Entry(label: "Promote…",                shortcut: "⌘⇧↩"),
            Entry(label: "Project Settings…",       shortcut: "⌘⇧,"),
        ]),
        Category(category: "Edit", items: [
            Entry(label: "Find in Editor",          shortcut: "⌘F"),
            Entry(label: "Find Next",               shortcut: "⌘G"),
            Entry(label: "Find Previous",           shortcut: "⌘⇧G"),
            Entry(label: "Find in Project…",        shortcut: "⌘⌥F"),
            Entry(label: "Translator's Note…",      shortcut: "⌘⌥C"),
            Entry(label: "Restore Last Deletion",   shortcut: "⌘⌥Z"),
        ]),
        Category(category: "View", items: [
            Entry(label: "Toggle Focus Mode",       shortcut: "⌘\\"),
            Entry(label: "Toggle Full-Screen Focus", shortcut: "⌘⇧F"),
            Entry(label: "Toggle Research Preview", shortcut: "⌘⇧P"),
            // The editor posture, NOT the ⌘3 persona below — the View menu
            // spells both "Review". `DocSyncTests
            // .test_paneShortcutsDocumentedInTheInAppCheatsheet` is why this
            // row cannot go missing again; it shipped absent from here AND from
            // docs/guide/ when the persona shell moved it off ⌘⌥R.
            Entry(label: "Toggle Review Mode (annotate-only)", shortcut: "⌘⌥⇧R"),
            Entry(label: "Plan mode", shortcut: "⌘1"),
            Entry(label: "Author mode", shortcut: "⌘2"),
            Entry(label: "Review mode", shortcut: "⌘3"),
            Entry(label: "Publish mode", shortcut: "⌘4"),
            Entry(label: "Inspector pane", shortcut: "⌘⌥I"),
            Entry(label: "Research pane", shortcut: "⌘⌥R"),
            Entry(label: "Outline pane", shortcut: "⌘⌥O"),
            Entry(label: "Annotations pane", shortcut: "⌘⌥A"),
            Entry(label: "History pane", shortcut: "⌘⌥H"),
            Entry(label: "Tasks pane", shortcut: "⌘⌥T"),
            Entry(label: "Inbox pane", shortcut: "⌘⌥B"),
            Entry(label: "Palette pane", shortcut: "⌘⌥P"),
            Entry(label: "Translation pane", shortcut: "⌘⌥L"),
            Entry(label: "Intent pane", shortcut: "⌘⌥N"),
            Entry(label: "What I've Learned pane", shortcut: "⌘⌥G"),
            Entry(label: "Visual Language pane", shortcut: "⌘⌥V"),
            Entry(label: "Diagnostics pane", shortcut: "⌘⌥D"),
            Entry(label: "References pane", shortcut: "⌘⌥E"),
            Entry(label: "Department pane", shortcut: "⌘⌥K"),
            Entry(label: "Toggle inspector column", shortcut: "⌘⌥0"),
        ]),
        Category(category: "Help", items: [
            Entry(label: "Syntax Reference",        shortcut: "⌘/"),
        ]),
    ]
}
