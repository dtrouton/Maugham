import Foundation

/// The keyboard shortcuts surfaced via Help ▸ Syntax & Keyboard Shortcuts'
/// Keyboard tab, and the list `docs/guide/reference.md` sends readers to as
/// the full one.
///
/// **Every key the menus bind has a line here** — read off the real menu bar,
/// not the source (`MenuBarCensusTests.test_everyKeyTheMenusBindHasACheatSheetLineAndAReferenceRow`),
/// so a key bound outside `MaughamApp.swift` (⌃⌘1/2/3, ⌃⌘L) is held to it
/// too; and every menu family's line names a key the menus bind
/// (`test_everyMenuKeyTheCheatSheetTeachesIsBound`). The Mac's own keys
/// (⌘Q, ⌘H, ⌘C…) are macOS's to document. The Binder and Canvas keys are
/// their own views', listed by hand (`KeyboardShortcutsTests`).
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
            Entry(label: "Save Checkpoint",         shortcut: "⌘S"),
            Entry(label: "Save Checkpoint As…",     shortcut: "⌘⇧S"),
            Entry(label: "Check Writing",           shortcut: "⌘R"),
            Entry(label: "Reread",                  shortcut: "⌘⇧R"),
            Entry(label: "Run the pass's round",    shortcut: "⌘⌃R"),
            Entry(label: "The round, with fresh eyes", shortcut: "⌘⌃⇧R"),
            Entry(label: "Promote Canvas Selection…", shortcut: "⌘⇧↩"),
            Entry(label: "Settings…",               shortcut: "⌘,"),
            Entry(label: "Project Settings…",       shortcut: "⌘⇧,"),
        ]),
        Category(category: "Edit", items: [
            Entry(label: "Undo",                    shortcut: "⌘Z"),
            Entry(label: "Redo",                    shortcut: "⌘⇧Z"),
            Entry(label: "Find in Editor",          shortcut: "⌘F"),
            Entry(label: "Find Next",               shortcut: "⌘G"),
            Entry(label: "Find Previous",           shortcut: "⌘⇧G"),
            Entry(label: "Find in Project…",        shortcut: "⌘⌥F"),
            Entry(label: "Comment… on the selection", shortcut: "⌘⇧K"),
            Entry(label: "Translator's Note…",      shortcut: "⌘⌥C"),
            Entry(label: "Restore Last Deletion",   shortcut: "⌘⌥Z"),
        ]),
        // The Insert menu (plan 3a R-3a-1).
        Category(category: "Insert", items: [
            Entry(label: "Insert Table",            shortcut: "⌘⇧T"),
            Entry(label: "Insert Footnote",         shortcut: "⌘⇧N"),
            Entry(label: "Insert Figure…",          shortcut: "⌘⇧I"),
            Entry(label: "Insert Citation…",        shortcut: "⌘⇧C"),
            Entry(label: "Insert Cross-Reference…", shortcut: "⌘⇧X"),
            Entry(label: "Convert to Table Figure", shortcut: "⌘⌥⇧T"),
        ]),
        // Format ▸ Table (report plan 7c Task 9): an expanded table grid's
        // inserts and Fill Down, bound on the menu items alone. Fill Right's
        // ⌘R is the grid's while it has the keys (plan 7d R7d-1) — File's
        // Check Writing everywhere else — so its menu item shows no glyph.
        Category(category: "Table", items: [
            Entry(label: "Insert Row Above",        shortcut: "⌘⌥↑"),
            Entry(label: "Insert Row Below",        shortcut: "⌘⌥↓"),
            Entry(label: "Insert Column Left",      shortcut: "⌘⌥←"),
            Entry(label: "Insert Column Right",     shortcut: "⌘⌥→"),
            Entry(label: "Fill Down",               shortcut: "⌘D"),
            Entry(label: "Fill Right (in the table)", shortcut: "⌘R"),
        ]),
        Category(category: "View", items: [
            Entry(label: "Focus Mode",              shortcut: "⌘\\"),
            Entry(label: "Full-Screen Focus",       shortcut: "⌘⇧F"),
            Entry(label: "Start or resume a read-through", shortcut: "⌘⌥⇧R"),
            Entry(label: "Show or hide the Research preview", shortcut: "⌘⇧P"),
            Entry(label: "Show or hide the right column", shortcut: "⌘⌥0"),
            Entry(label: "Read In Next Language",   shortcut: "⌘⌃L"),
            Entry(label: "Show Source Under Translation", shortcut: "⌘⌃⇧L"),
            Entry(label: "To Resolve",              shortcut: "⌘1"),
            Entry(label: "To Resolve: the check's findings", shortcut: "⌘⌥D"),
            Entry(label: "To Resolve: rounds' notes", shortcut: "⌘⌥A"),
            Entry(label: "To Resolve: your own notes and to-dos", shortcut: "⌘⌥T"),
            Entry(label: "To Resolve: a translator's questions", shortcut: "⌘⌥L"),
            Entry(label: "To Resolve: the edition you are reading (else the Source)", shortcut: "⌘⌥K"),
            Entry(label: "Brief",                   shortcut: "⌘2"),
            Entry(label: "Write the line",          shortcut: "⌘⌥I"),
            Entry(label: "Write what the piece is going for", shortcut: "⌘⌥N"),
            Entry(label: "Pulled Up",               shortcut: "⌘3"),
            Entry(label: "Pull up What I've Learned", shortcut: "⌘⌥G"),
            Entry(label: "Pull up First Reader",    shortcut: "⌘⌥Y"),
            Entry(label: "Pull up Visual Language", shortcut: "⌘⌥V"),
            Entry(label: "Pull up History",         shortcut: "⌘⌃H"),
            Entry(label: "Back",                    shortcut: "⌘["),
            Entry(label: "Show the piece's fold in the binder", shortcut: "⌘⌥E"),
            Entry(label: "Go to the Book",          shortcut: "⌘⌥O"),
            Entry(label: "Go to Research",          shortcut: "⌘⌥R"),
            Entry(label: "Go to Palette",           shortcut: "⌘⌥P"),
            Entry(label: "Go to Inbox",             shortcut: "⌘⌥B"),
            Entry(label: "View as Cards (an edition: Book)", shortcut: "⌘⌃1"),
            Entry(label: "View as Outline",         shortcut: "⌘⌃2"),
            Entry(label: "View as Status",          shortcut: "⌘⌃3"),
        ]),
        // The binder's own keys (shell p4 Task 10, `TreeRowKeys`): the
        // `List`'s, never menu equivalents — ⌘↓ as one would take "end of
        // document" from every text view (row 41).
        Category(category: "Binder", items: [
            Entry(label: "Move between rows",       shortcut: "↑↓"),
            Entry(label: "Pull up or put away the row", shortcut: "↩ or Space"),
            Entry(label: "Open in Centre",          shortcut: "⌘↓"),
        ]),
        // The canvas's keys (canvas-keyboard-flow); `KeyboardShortcutsTests`
        // checks them. The first five act inside a scrap, the rest on the canvas.
        Category(category: "Canvas", items: [
            Entry(label: "Finish scrap",            shortcut: "↩"),
            Entry(label: "New line in scrap",       shortcut: "⇧↩"),
            Entry(label: "Finish scrap (Escape)",   shortcut: "⎋"),
            Entry(label: "New joined scrap",        shortcut: "⇥"),
            Entry(label: "New scrap below",         shortcut: "⌘↩"),
            Entry(label: "New scrap / edit selected", shortcut: "↩"),
            Entry(label: "Move selection",          shortcut: "←↑→↓"),
            Entry(label: "Rename region",           shortcut: "↩"),
            Entry(label: "Canvas from binder",        shortcut: "⇥"),
            Entry(label: "Back to binder",            shortcut: "⇧⇥"),
        ]),
        Category(category: "Help", items: [
            Entry(label: "Maugham Help",            shortcut: "⌘?"),
            Entry(label: "Syntax & Keyboard Shortcuts", shortcut: "⌘/"),
        ]),
    ]
}
