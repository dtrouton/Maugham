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
            Entry(label: "Toggle Inspector",        shortcut: "⌘⌥I"),
            Entry(label: "Inspector mode",          shortcut: "⌘⌥1"),
            Entry(label: "Linked Research mode",    shortcut: "⌘⌥2"),
            Entry(label: "Outline mode",            shortcut: "⌘⌥3"),
            Entry(label: "Toggle Research Preview", shortcut: "⌘⇧P"),
        ]),
        Category(category: "Help", items: [
            Entry(label: "Syntax Reference",        shortcut: "⌘/"),
        ]),
    ]
}
