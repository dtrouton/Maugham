import Foundation

/// Curated catalog of keyboard shortcuts surfaced via the Help → Syntax
/// Reference sheet's Keyboard tab. Hand-maintained; manual smoke at tag
/// time verifies parity with MaughamApp.commands.
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
            Entry(label: "Project Settings…",       shortcut: "⌘⇧,"),
        ]),
        Category(category: "Edit", items: [
            Entry(label: "Find in Editor",          shortcut: "⌘F"),
            Entry(label: "Find Next",               shortcut: "⌘G"),
            Entry(label: "Find Previous",           shortcut: "⌘⇧G"),
            Entry(label: "Find in Project…",        shortcut: "⌘⌥F"),
            Entry(label: "Restore Last Deleted Item", shortcut: "⌘⌥Z"),
        ]),
        Category(category: "View", items: [
            Entry(label: "Toggle Focus Mode",       shortcut: "⌘\\"),
            Entry(label: "Toggle Full-Screen Focus", shortcut: "⌘⇧F"),
            Entry(label: "Toggle Research Preview", shortcut: "⌘⇧P"),
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
            Entry(label: "Toggle inspector column", shortcut: "⌘⌥0"),
        ]),
        Category(category: "Help", items: [
            Entry(label: "Syntax Reference",        shortcut: "⌘/"),
        ]),
    ]
}
