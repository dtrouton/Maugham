import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// **The menu bar as the app actually holds it** (shell p5 Task 7): the real
/// `NSApp.mainMenu` of the test host, walked recursively — the system's own
/// items included — rather than the source text, so a key bound outside
/// `MaughamApp.swift` (⌃⌘1/2/3, ⌃⌘L) or one SwiftUI silently dropped (⌘⌥H,
/// which the app menu's Hide Others already holds) is seen as the writer sees
/// it. The walk is synchronous: the commands exist before any window does.
@MainActor
final class MenuBarCensusTests: XCTestCase {

    // MARK: - The walk

    struct WalkedItem: Equatable {
        /// "View ▸ Go to Research".
        let path: String
        let title: String
        /// "⌘⌥R"; nil for an item with no key.
        let token: String?
        let isHidden: Bool
        /// A modifier set with no key: the key was asked for and somebody
        /// else's item already held it, so SwiftUI bound nothing.
        let lostItsKey: Bool
        /// An item AppKit itself puts in the menu (`systemInjected`), known
        /// by its action, never by its title.
        let isSystemInjected: Bool
    }

    /// An item AppKit injects into the Edit menu of any app, named by the
    /// action selector it carries.
    struct SystemInjected {
        let action: String
        let reason: String
    }

    /// **The items macOS adds, which no census of Maugham's keys judges** —
    /// their keys and their count are the OS version's, not ours. They are
    /// set aside only from each other: a Maugham item sharing their key is
    /// still a duplicate (`duplicates`).
    static let systemInjected: [SystemInjected] = [
        SystemInjected(action: "startDictation:", reason:
            "Edit ▸ Start Dictation…: a visible item plus hidden fn-D twins; macOS 27.2 adds one twin, "
            + "the CI runner's macOS 27.0 two; a full gate once saw it bound to 🎤"),
        SystemInjected(action: "orderFrontCharacterPalette:", reason:
            "Edit ▸ Emoji & Symbols: ⌘Space, with hidden ⌃⌘Space and fn-E alternates"),
    ]

    static func isSystemInjected(action: Selector?) -> Bool {
        guard let action else { return false }
        let name = NSStringFromSelector(action)
        return systemInjected.contains { $0.action == name }
    }

    /// The guide's glyph for a function-key character.
    static let keyGlyphs: [String: String] = [
        "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→",
        "\r": "↩", " ": "Space", "\u{1B}": "⎋", "\t": "⇥", "\u{8}": "⌫", "\u{7F}": "⌫",
    ]

    /// The guide's spelling of a key equivalent: ⌘ first, then ⌃⌥⇧, then
    /// the key, uppercased (an uppercase letter implies ⇧, as AppKit reads it).
    static func token(key: String, mask: NSEvent.ModifierFlags) -> String? {
        guard !key.isEmpty else { return nil }
        var shift = mask.contains(.shift)
        let glyph: String
        if let named = keyGlyphs[key] {
            glyph = named
        } else {
            if key.count == 1, key.uppercased() == key, key.lowercased() != key { shift = true }
            glyph = key.uppercased()
        }
        var token = ""
        if mask.contains(.command) { token += "⌘" }
        if mask.contains(.control) { token += "⌃" }
        if mask.contains(.option) { token += "⌥" }
        if shift { token += "⇧" }
        if mask.contains(.function) { token = "fn" + token }
        return token + glyph
    }

    static func walk(_ menu: NSMenu?, path: String = "") -> [WalkedItem] {
        var out: [WalkedItem] = []
        for item in menu?.items ?? [] where !item.isSeparatorItem {
            let here = path.isEmpty ? item.title : "\(path) ▸ \(item.title)"
            let extra = item.keyEquivalentModifierMask.intersection([.control, .option, .shift])
            out.append(WalkedItem(
                path: here, title: item.title,
                token: token(key: item.keyEquivalent, mask: item.keyEquivalentModifierMask),
                isHidden: item.isHidden,
                lostItsKey: item.keyEquivalent.isEmpty && !extra.isEmpty && item.submenu == nil,
                isSystemInjected: isSystemInjected(action: item.action)))
            out += walk(item.submenu, path: here)
        }
        return out
    }

    var menuBar: [WalkedItem] { Self.walk(NSApp.mainMenu) }

    // MARK: - Every key once

    /// Items that may share a key — keyed by the token AND the exact items,
    /// so an allowance never covers a later item (fix round 1, I1).
    struct AllowedOverlap {
        let token: String
        let paths: Set<String>
        let reason: String
    }

    /// None today. ⌘R is Check Writing's alone: Format ▸ Table ▸ Fill Right
    /// shows no key (the grid's own keyDown answers ⌘R while it has the keys,
    /// R7d-1) — asserted in `test_everyMenuKeyIsBoundOnce`, not allowed here.
    static let allowedOverlaps: [AllowedOverlap] = []

    /// Each token bound by more than one item, with the items, minus an
    /// allowance naming exactly those items. A token only AppKit's own items
    /// share (`systemInjected`) is the OS's; one a Maugham item shares with
    /// anything is reported.
    static func duplicates(_ items: [WalkedItem], allowed: [AllowedOverlap] = allowedOverlaps) -> [String] {
        let bound = items.compactMap { item in item.token.map { ($0, item) } }
        return Dictionary(grouping: bound, by: { $0.0 })
            .filter { group in
                group.value.count > 1 && group.value.contains { !$0.1.isSystemInjected } && !allowed.contains {
                    $0.token == group.key && $0.paths == Set(group.value.map(\.1.path))
                }
            }
            .map { "\($0.key): " + $0.value.map(\.1.path).joined(separator: " / ") }
            .sorted()
    }

    func test_everyMenuKeyIsBoundOnce() throws {
        let items = menuBar
        // Premise: the walk reached the app's own commands, not an empty bar.
        XCTAssertTrue(items.contains { $0.token == "⌘S" }, "premise: File ▸ Save is in the walk")
        XCTAssertTrue(items.contains { $0.token == "⌘⌃1" }, "premise: a key bound outside MaughamApp.swift is seen")
        XCTAssertGreaterThan(items.filter { $0.token != nil }.count, 50, "the walk read almost nothing")
        XCTAssertTrue(items.contains { $0.isSystemInjected && $0.token != nil },
                      "premise: AppKit's own keyed Edit items are in the walk, known by their action")
        XCTAssertEqual(Self.duplicates(items), [], "one key, two items")
        XCTAssertEqual(items.filter(\.lostItsKey).map(\.path), [],
                       "an item asked for a key another item already holds, and got none")
        // ⌘R's other claimant is the grid's keyDown, never a menu item.
        let fillRight = try XCTUnwrap(items.first { $0.path == "Format ▸ Table ▸ Fill Right" })
        XCTAssertNil(fillRight.token, "Fill Right shows no key: ⌘R is Check Writing's")
    }

    /// The control: a planted duplicate is reported; one allowed by exactly
    /// its items is not, and the same allowance does not cover a third; a
    /// dropped key is seen.
    func test_theKeyCensusFiresOnAPlantedDuplicate() {
        let menu = NSMenu(title: "Planted")
        menu.addItem(withTitle: "One", action: nil, keyEquivalent: "j")
        menu.addItem(withTitle: "Two", action: nil, keyEquivalent: "j")
        menu.addItem(withTitle: "Three", action: nil, keyEquivalent: "r")
        menu.addItem(withTitle: "Four", action: nil, keyEquivalent: "r")
        menu.addItem(withTitle: "Five", action: nil, keyEquivalent: "k")
        let lost = menu.addItem(withTitle: "Lost", action: nil, keyEquivalent: "")
        lost.keyEquivalentModifierMask = [.command, .option]
        let items = Self.walk(menu)
        let allowed = [AllowedOverlap(token: "⌘R", paths: ["Three", "Four"], reason: "planted")]
        XCTAssertEqual(Self.duplicates(items, allowed: allowed), ["⌘J: One / Two"])
        XCTAssertEqual(Self.duplicates(items), ["⌘J: One / Two", "⌘R: Three / Four"])
        menu.addItem(withTitle: "Six", action: nil, keyEquivalent: "r")
        XCTAssertEqual(Self.duplicates(Self.walk(menu), allowed: allowed),
                       ["⌘J: One / Two", "⌘R: Three / Four / Six"], "an allowance covers its items only")
        XCTAssertEqual(items.filter(\.lostItsKey).map(\.title), ["Lost"])
        XCTAssertEqual(Self.token(key: "Z", mask: .command), "⌘⇧Z")
        XCTAssertEqual(Self.token(key: "\u{F700}", mask: [.command, .option]), "⌘⌥↑")
        XCTAssertEqual(Self.token(key: "r", mask: [.command, .control, .shift]), "⌘⌃⇧R")
    }

    /// The control for `systemInjected`: AppKit's twins are not judged
    /// against each other; a Maugham item taking their key is reported with
    /// them; and an item is AppKit's by its action alone — one titled "Start
    /// Dictation…" with another action is judged like any of ours. (Planted
    /// on ⌘⌃D: an `NSMenuItem` drops a `.function` mask set from outside
    /// AppKit, so fn-D itself cannot be planted.)
    func test_theKeyCensusSetsAsideOnlyAppKitsOwnItems() {
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String,
                 _ mask: NSEvent.ModifierFlags) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
        }
        let dictation = NSSelectorFromString("startDictation:")
        let menu = NSMenu(title: "Edit")
        add(menu, "Start Dictation…", dictation, "d", [.command, .control])
        add(menu, "Start Dictation…", dictation, "d", [.command, .control])
        add(menu, "Start Dictation…", #selector(NSText.copy(_:)), "j", .command)
        add(menu, "Mine", nil, "j", .command)
        let walked = Self.walk(menu)
        XCTAssertEqual(walked.map(\.isSystemInjected), [true, true, false, false],
                       "AppKit's by the action, not the title")
        XCTAssertEqual(Self.duplicates(walked), ["⌘J: Start Dictation… / Mine"],
                       "the twins pass; a same-titled item of another action is judged")
        add(menu, "Dictate Mine", nil, "d", [.command, .control])
        XCTAssertEqual(Self.duplicates(Self.walk(menu)),
                       ["⌘J: Start Dictation… / Mine",
                        "⌘⌃D: Start Dictation… / Start Dictation… / Dictate Mine"],
                       "a Maugham item taking AppKit's key is reported")
    }

    // MARK: - Every declared key reaches its item (fix round 1, I2)

    /// The system's own items, which a declared key of ours can lose to: the
    /// app menu, the Window menu, and AppKit's Edit and File items. A key
    /// SwiftUI dropped because one of these held it shows on THEIR item, so
    /// it is counted only on ours.
    static let systemMenus: Set<String> = ["Window"]
    static let systemItemPaths: Set<String> = [
        "Edit ▸ Undo", "Edit ▸ Redo", "Edit ▸ Cut", "Edit ▸ Copy", "Edit ▸ Paste", "Edit ▸ Select All",
        "Edit ▸ Emoji & Symbols", "Edit ▸ Start Dictation…", "File ▸ Close", "File ▸ Close All",
    ]

    /// The declared tokens the walk's own items carry fewer times than the
    /// source declares them — a ⌘-only key lost to Hide (⌘H) or Minimize
    /// (⌘M) is otherwise indistinguishable from a keyless item.
    static func undelivered(declared: [String], walked: [WalkedItem], appMenu: String) -> [String] {
        let ours = walked.filter { item in
            let top = item.path.components(separatedBy: " ▸ ").first ?? ""
            return top != appMenu && !systemMenus.contains(top) && !systemItemPaths.contains(item.path)
        }.compactMap(\.token)
        let have = Dictionary(grouping: ours, by: { $0 }).mapValues(\.count)
        let want = Dictionary(grouping: declared, by: { $0 }).mapValues(\.count)
        return want.filter { (have[$0.key] ?? 0) < $0.value }.keys.sorted()
    }

    func test_everyKeyTheSourceDeclaresIsOnItsItem() throws {
        let declared = try DocSyncTests.menuKeySources.flatMap { path in
            DocSyncTests.extractShortcutBindings(
                from: DocSyncTests.resolvingNamedKeys(try SourceTree.read(path))).map(\.token)
        }
        XCTAssertGreaterThan(declared.count, 50, "premise: the extractor read the menu sources")
        XCTAssertTrue(declared.contains("⌘⌃⇧L"), "premise: a key held in a named constant is read")
        let appMenu = try XCTUnwrap(NSApp.mainMenu?.items.first?.title)
        XCTAssertEqual(Self.undelivered(declared: declared, walked: menuBar, appMenu: appMenu), [],
                       "a key the source declares is on no item of ours in the menu bar")
    }

    func test_theUndeliveredCensusFiresOnAPlantedOffender() throws {
        let appMenu = try XCTUnwrap(NSApp.mainMenu?.items.first?.title)
        let planted = DocSyncTests.extractShortcutBindings(from: #"""
            Button("Pull Up Help") { }.keyboardShortcut("h", modifiers: .command)
            Button("Save") { }.keyboardShortcut("s", modifiers: .command)
            """#).map(\.token)
        XCTAssertEqual(Self.undelivered(declared: planted, walked: menuBar, appMenu: appMenu), ["⌘H"],
                       "⌘H is Hide's, on the app menu: our item never got it")
        XCTAssertEqual(Self.undelivered(declared: ["⌘S"], walked: menuBar, appMenu: appMenu), [],
                       "control: Save's ⌘S is on Save")
    }

    // MARK: - Every key listed

    /// The Mac's own keys, documented by macOS rather than by Maugham. The
    /// keys of the items AppKit injects (`systemInjected`) are set aside by
    /// the item, not listed here — a token here would excuse a Maugham item
    /// bound to it too.
    static let systemTokens: Set<String> = [
        "⌘Q", "⌘H", "⌘⌥H", "⌘W", "⌘⌥W", "⌘M", "⌘X", "⌘C", "⌘V", "⌘A",
    ]

    static func unlisted(_ tokens: [String], in listed: [String]) -> [String] {
        Array(Set(tokens.filter { !systemTokens.contains($0) && !listed.contains($0) })).sorted()
    }

    /// The keys the walk's shown items bind, AppKit's own items set aside.
    static func boundTokens(_ items: [WalkedItem]) -> [String] {
        items.filter { !$0.isHidden && !$0.isSystemInjected }.compactMap(\.token)
    }

    func test_everyKeyTheMenusBindHasACheatSheetLineAndAReferenceRow() throws {
        let tokens = Self.boundTokens(menuBar)
        XCTAssertTrue(tokens.contains("⌘⌃1"), "premise: the walk sees ⌘⌃1")
        let cheatSheet = KeyboardShortcuts.all.flatMap(\.items).map(\.shortcut)
        XCTAssertEqual(Self.unlisted(tokens, in: cheatSheet), [],
                       "a key the menus bind with no line on the ⌘/ cheat sheet")
        let reference = try SourceTree.read("docs/guide/reference.md")
        XCTAssertEqual(DocSyncTests.tokensWithoutAReferenceRow(Self.unlisted(tokens, in: []), in: reference), [],
                       "a key the menus bind with no row in docs/guide/reference.md's table")
    }

    func test_theListedCheckFiresOnAPlantedOffender() throws {
        XCTAssertEqual(Self.unlisted(["⌘⌥⇧9", "⌘Q", "⌘S"], in: ["⌘S"]), ["⌘⌥⇧9"])
        // AppKit's shown item is set aside by its action; the same key on an
        // item of ours, even one titled like it, is not (⌘⌃D standing in for
        // fn-D, which a planted item cannot carry).
        let menu = NSMenu(title: "Edit")
        for action in [NSSelectorFromString("startDictation:"), nil] {
            let item = menu.addItem(withTitle: "Start Dictation…", action: action, keyEquivalent: "d")
            item.keyEquivalentModifierMask = [.command, .control]
        }
        XCTAssertEqual(Self.unlisted(Self.boundTokens(Self.walk(menu)), in: []), ["⌘⌃D"])
        XCTAssertEqual(Self.boundTokens(Array(Self.walk(menu).prefix(1))), [],
                       "control: AppKit's own item alone binds nothing of ours")
        let reference = try SourceTree.read("docs/guide/reference.md")
        XCTAssertEqual(DocSyncTests.tokensWithoutAReferenceRow(["⌘⌥⇧9", "⌘S"], in: reference), ["⌘⌥⇧9"])
    }

    /// **No key the cheat sheet teaches for a menu is bound to nothing**:
    /// its menu families (not the canvas's or the binder's own keys).
    func test_everyMenuKeyTheCheatSheetTeachesIsBound() {
        let tokens = Set(menuBar.compactMap(\.token))
        XCTAssertEqual(Self.untaught(KeyboardShortcuts.all, bound: tokens), [],
                       "the cheat sheet teaches a key no menu item binds")
    }

    /// The menu families' keys that no item binds. Fill Right's ⌘R is the
    /// grid's own (its item shows no glyph), and ⌘R is bound by Check Writing.
    static func untaught(_ sheet: [KeyboardShortcuts.Category], bound: Set<String>) -> [String] {
        let menuFamilies: Set<String> = ["File", "Edit", "Insert", "Table", "View", "Help"]
        return sheet.filter { menuFamilies.contains($0.category) }
            .flatMap(\.items).map(\.shortcut)
            .filter { !bound.contains($0) }
    }

    func test_theTaughtCheckFiresOnAPlantedOffender() {
        let sheet = [KeyboardShortcuts.Category(category: "View", items: [
            .init(label: "Planted", shortcut: "⌘⌥⇧9"), .init(label: "Real", shortcut: "⌘S")]),
                     KeyboardShortcuts.Category(category: "Canvas", items: [
            .init(label: "Not a menu's", shortcut: "⇥")])]
        XCTAssertEqual(Self.untaught(sheet, bound: ["⌘S"]), ["⌘⌥⇧9"])
    }

    // MARK: - One title per menu

    /// The verbs a title may lead with that move or show rather than name:
    /// "View as Outline" and "Outline" name one thing.
    static let leadingVerbs = ["view as ", "go to the ", "go to ", "show the ", "show ", "open the ", "open ", "pull up "]

    /// Titles in one menu that name the same thing: equal once case, a
    /// trailing ellipsis and a leading verb of `leadingVerbs` are set aside.
    static func repeatedTitles(_ menu: NSMenu?) -> [String] {
        func name(_ title: String) -> String {
            var name = title.lowercased().replacingOccurrences(of: "\u{2026}", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let verb = leadingVerbs.first(where: { name.hasPrefix($0) }) { name.removeFirst(verb.count) }
            return name
        }
        var out: [String] = []
        let shown = (menu?.items ?? []).filter { !$0.isSeparatorItem && !$0.isHidden && !$0.title.isEmpty }
        let names = shown.map { name($0.title) }
        for (i, a) in names.enumerated() where names[(i + 1)...].contains(a) {
            out.append("\(menu?.title ?? ""): \(a)")
        }
        for item in menu?.items ?? [] { out += repeatedTitles(item.submenu) }
        return out
    }

    func test_noMenuItemTitleRepeatsInOneMenu() {
        XCTAssertEqual(Self.repeatedTitles(NSApp.mainMenu), [])
    }

    func test_theTitleCensusFiresOnAPlantedOffender() {
        let menu = NSMenu(title: "View")
        menu.addItem(withTitle: "Outline", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "View as Outline", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Figure\u{2026}", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Existing Figure\u{2026}", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Brief", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Brief\u{2026}", action: nil, keyEquivalent: "")
        XCTAssertEqual(Self.repeatedTitles(menu), ["View: outline", "View: brief"])
    }

    // MARK: - Enabled state per focused window (row 57)

    func test_anItemThatActsOnAProjectWindowIsDisabledWithNoneInFront() {
        typealias A = MenuBarAvailability
        let table: [(A.Scope, Bool, Bool?, Bool)] = [
            // scope, a project window in front, the item's own offer, enabled
            (.projectWindow, true, nil, true),
            (.projectWindow, false, nil, false),
            (.projectWindow, true, false, false),
            (.projectWindow, true, true, true),
            (.projectWindow, false, true, false),
            (.anywhere, false, nil, true),
            (.anywhere, false, false, false),
            (.run, false, nil, true),
            (.run, false, false, true),
        ]
        for (scope, front, offered, expected) in table {
            XCTAssertEqual(A.isEnabled(scope, projectWindowInFront: front, offered: offered), expected,
                           "\(scope), front \(front), offered \(String(describing: offered))")
        }
    }

    /// **Run's four are never greyed** (`RunButtons`' standing ruling), and
    /// every other item the app adds to a menu asks the focused window: read
    /// from EVERY menu's item structs' source (File, Edit, View, Insert,
    /// Format ▸ Table, the `Focused*` structs, Help — 5b M4), each
    /// `Button`/`Toggle` followed by its own `.disabled(`, or named here with
    /// why. The structs are found by name and shape, and the premise names
    /// the ones that must be found, so a struct renamed out of the walk fails
    /// rather than passing unread.
    ///
    /// **Outside the walk, and rightly ungated** (closing re-review N6): they
    /// act with or without a project window, so none asks the focused one —
    /// - `HelpCommands`' own items (Maugham Help, Welcome to Maugham, Sample
    ///   Projects ▸, Acknowledgements): each opens an app window;
    /// - the inline Find…, Find Next and Find Previous in `MaughamApp.body`'s
    ///   `CommandGroup`: they go to the first responder, whatever window it is;
    /// - `UpdateMenuCommand` (Check for Updates…): app-wide.
    func test_everyWindowItemAsksTheFocusedWindow() throws {
        let unasked: [String: String] = [
            "New Project…": "opens with or without a project",
            "Open Project…": "opens with or without a project",
            "Dump Coordinator Leak Probe (dev)": "a dev build's instrument, about every window",
            // Help's two sheets: with no project window each opens its own
            // window (`HelpSheetRoute`, shell closing A5).
            "SyntaxHelpSheet.title": "opens its own window with no project (A5)",
            "HelpSheetRoute.Item.claudeDesktop.title": "opens its own window with no project (A5)",
            // Read In ▸ Source: gated by its enclosing `Menu`'s `.disabled`.
            "LanguageSwitch.sourceTitle": "inside View ▸ Read In, which is disabled with no offer",
        ]
        let structs = try Self.menuItemStructs()
        for name in Self.menuItemStructNames {
            XCTAssertNotNil(structs[name], "premise: the census reads \(name)")
        }
        for (name, body) in structs {
            XCTAssertEqual(Self.ungatedItems(in: body).filter { unasked[$0] == nil }, [],
                           "\(name): an item no window gates")
        }
        let app = try Self.joinedCode("Maugham/MaughamApp.swift")
        let runs = try XCTUnwrap(app.range(of: "private struct RunButtons: View {"))
        let runEnd = try XCTUnwrap(app.range(of: "private struct EditMenuItems", range: runs.upperBound..<app.endIndex))
        let runBody = app[runs.upperBound..<runEnd.lowerBound]
        XCTAssertFalse(runBody.contains(".disabled("), "Run's four are never greyed")
    }

    /// The item structs every menu mounts — the premise list; the walk below
    /// finds them, and any further struct of the same shape, by name.
    static let menuItemStructNames: Set<String> = [
        "FileMenuItems", "EditMenuItems", "ViewMenuItems", "InsertMenuButtons",
        "FigureTableMenuButtons", "FocusedPullUpPreviousButton", "FocusedEditionResolveButton",
        "FocusedPieceFoldButton", "FocusedReadThroughItem", "HelpWindowItems",
        "FocusedReadingItems", "FocusedMarginItems", "FocusedCentreViewItems",
    ]

    /// The files the menus' item structs live in.
    static let menuItemSources = [
        "Maugham/MaughamApp.swift", "Maugham/Views/LanguageSwitch.swift",
        "Maugham/Views/EditorControlMirror.swift", "Maugham/Views/CentreViewSwitch.swift",
    ]

    static func joinedCode(_ path: String) throws -> String {
        SourceScan.codeLines(of: try SourceTree.read(path))
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    /// Every `struct <Name>: View {` in `menuItemSources` whose name is a menu
    /// item struct's shape (`Focused…`, `…MenuItems`, `…MenuButtons`,
    /// `HelpWindowItems`), sliced to the next struct declaration.
    static func menuItemStructs() throws -> [String: String] {
        menuItemStructs(in: try menuItemSources.map(joinedCode))
    }

    static func menuItemStructs(in codes: [String]) -> [String: String] {
        let decl = try! NSRegularExpression(
            pattern: #"(?:(?:private|fileprivate) )?struct (Focused\w+|\w+MenuItems|\w+MenuButtons|HelpWindowItems): View \{"#)
        let anyStruct = try! NSRegularExpression(pattern: #"(?:(?:private|fileprivate) )?struct \w+"#)
        var out: [String: String] = [:]
        for code in codes {
            let ns = code as NSString
            for match in decl.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                let start = match.range.location + match.range.length
                let next = anyStruct.firstMatch(in: code, range: NSRange(location: start, length: ns.length - start))
                let end = next?.range.location ?? ns.length
                out[ns.substring(with: match.range(at: 1))] = ns.substring(with: NSRange(location: start, length: end - start))
            }
        }
        return out
    }

    /// The control for the walk over every menu's structs (5b M4): an ungated
    /// item planted in a `Focused*` struct is found under that struct, and a
    /// struct of another shape is not read.
    func test_theStructWalkFindsAnUngatedItemInAFocusedStruct() {
        let planted = #"struct FocusedPlantedItems: View { var body: some View { Button("Planted") { x() } } } private struct Unrelated: View { var body: some View { Button("Elsewhere") { } } }"#
        let structs = Self.menuItemStructs(in: [planted])
        XCTAssertEqual(Set(structs.keys), ["FocusedPlantedItems"])
        XCTAssertEqual(Self.ungatedItems(in: structs["FocusedPlantedItems"] ?? ""), ["Planted"])
    }

    /// **Help's two sheets open with no project window** (shell closing A5):
    /// with one in front they are its sheets, as before; with none each opens
    /// its own window scene, and neither is ever greyed. The syntax sheet with
    /// no project opens on Markdown.
    func test_helpsTwoSheetsOpenWithNoProjectWindow() {
        for item in HelpSheetRoute.Item.allCases {
            XCTAssertEqual(HelpSheetRoute.of(item, projectWindowInFront: true), .projectWindowSheet)
            XCTAssertEqual(HelpSheetRoute.of(item, projectWindowInFront: false), .ownWindow(id: item.windowID))
        }
        XCTAssertTrue(MenuBarAvailability.isEnabled(HelpSheetRoute.scope, projectWindowInFront: false))
        XCTAssertEqual(HelpSheetRoute.windowlessSyntaxFormat, .markdown)
        XCTAssertNotEqual(HelpSheetRoute.Item.syntax.windowID, HelpSheetRoute.Item.claudeDesktop.windowID)
    }

    /// The scenes exist: each item's window id is a `Window` scene the app
    /// declares, so `openWindow(id:)` reaches a window and not nothing.
    func test_eachHelpSheetsWindowIsAScene() throws {
        let app = try SourceTree.read("Maugham/MaughamApp.swift")
        for item in ["HelpSheetRoute.Item.syntax.windowID", "HelpSheetRoute.Item.claudeDesktop.windowID"] {
            XCTAssertTrue(app.contains("id: \(item)) {"), "no Window scene for \(item)")
        }
        // Neither restores at launch nor lists itself in the Window menu
        // (which would open it around the route with a project in front).
        let flat = try Self.joinedCode("Maugham/MaughamApp.swift")
        for id in ["HelpSheetRoute.Item.syntax.windowID", "HelpSheetRoute.Item.claudeDesktop.windowID"] {
            let start = try XCTUnwrap(flat.range(of: "id: \(id)) {"))
            let tail = flat[start.upperBound...].prefix(400)
            XCTAssertTrue(tail.contains(".restorationBehavior(.disabled) .commandsRemoved()"), "\(id)")
        }
    }

    /// The `Button(`/`Toggle(` items in `body` — whatever their title, a
    /// literal or not (fix round 1, M2) — with no `.disabled(` before the next
    /// item, named by their first argument's text.
    static func ungatedItems(in body: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"\b(?:Button|Toggle)\(\s*("(?:[^"\\]|\\.)*"|[^,{)]*)"#)
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        var out: [String] = []
        for (i, match) in matches.enumerated() {
            let next = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let span = ns.substring(with: NSRange(location: match.range.location, length: next - match.range.location))
            guard !span.contains(".disabled(") else { continue }
            let name = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            out.append(name.hasPrefix("\"") && name.hasSuffix("\"") && name.count > 1
                       ? String(name.dropFirst().dropLast()) : name)
        }
        return out
    }

    func test_theUngatedCensusFiresOnAPlantedOffender() {
        let planted = #"Button("A") { x() } .disabled(!enabled()) Button("B") { y() } .keyboardShortcut("b") Toggle("C", isOn: z) .disabled(q) Button(Self.title) { w() } Button(other) { v() } .disabled(!enabled())"#
        XCTAssertEqual(Self.ungatedItems(in: planted), ["B", "Self.title"],
                       "a non-literal title is seen, and the next item's gate does not cover it")
    }

    /// ⌃⌘1/2/3: every view a centre offers has its own digit (fix round 1,
    /// M1) — the menu binds no fallback, so no state of the window can bind a
    /// second ⌃⌘1.
    func test_everyCentreViewHasItsOwnDigit() {
        let offers = BookView.allCases.map(CentreViewSwitch.Offer.book)
            + EditionView.allCases.map(CentreViewSwitch.Offer.edition)
        for offer in offers {
            let choices = CentreViewSwitch.choices(for: offer)
            let keyed = CentreViewSwitch.keyedChoices(choices)
            XCTAssertEqual(keyed.map(\.choice), choices, "\(offer): a choice with no digit")
            XCTAssertEqual(Set(keyed.map(\.digit)).count, keyed.count, "\(offer): two choices, one digit")
        }
        XCTAssertTrue(CentreViewSwitch.keyedChoices([.none]).isEmpty, "control: a choice with no digit binds none")
    }

    // MARK: - Titles the table approved

    func test_theRoundsAreTitledForThePassTheyWouldFileIn() {
        XCTAssertEqual(RunCommand.runRound.menuTitle(editorName: "Gould"), "Run Gould\u{2019}s Round")
        XCTAssertEqual(RunCommand.freshEyes.menuTitle(editorName: "Gould"),
                       "Run Gould\u{2019}s Round with Fresh Eyes")
        XCTAssertEqual(RunCommand.runRound.menuTitle(editorName: nil), "Run Round", "no pass: the fixed title")
        XCTAssertEqual(RunCommand.freshEyes.menuTitle(editorName: nil), "Fresh Eyes")
        XCTAssertEqual(RunCommand.checkWriting.menuTitle(editorName: "Gould"), "Check Writing",
                       "a check is nobody's round")
        XCTAssertEqual(RunCommand.reread.menuTitle(editorName: "Gould"), "Reread")
    }

    private func manifest(_ type: ProjectType) -> ProjectManifest {
        ProjectManifest(type: type, title: "T", author: "A", created: Date(), modified: Date(),
                        structure: [], research: [])
    }

    func test_fileOffersTheProjectsOwnCreationVerbs() {
        let novel = manifest(.novel)
        XCTAssertEqual(NewPieceOffer.of(novel, mayStart: true),
                       .binder(piece: "New Chapter", group: "New Part", mayStart: true))
        let story = manifest(.shortStory)
        XCTAssertEqual(NewPieceOffer.of(story, mayStart: false),
                       .binder(piece: "New Story", group: "New Group", mayStart: false))
        XCTAssertEqual(NewPieceOffer.of(manifest(.collection), mayStart: true),
                       .collection(mayStart: true))
        XCTAssertEqual(NewPieceOffer.of(manifest(.screenplay), mayStart: true), .none,
                       "a screenplay's one script is the project")
        XCTAssertEqual(StartAPieceDoor.newProsePieceTitle, "New Prose Piece")
        XCTAssertEqual(StartAPieceDoor.newScriptTitle, "New Script", "File and the + menu say one wording")
        XCTAssertEqual(ViewMenuTitles.researchPreview(shown: true), "Hide Research Preview")
        XCTAssertEqual(ViewMenuTitles.researchPreview(shown: false), "Show Research Preview")
    }

    /// **Go to the Canvas and New Chapter / New Part**: the item posts what
    /// the window's receiver reads, and the receiver does what the Canvas
    /// row's click and the binder's + do (`WiringCensusTests` pins the +).
    func test_theNewPlacesAndVerbsReachTheirReceivers() throws {
        let app = SourceScan.codeLines(of: try SourceTree.read("Maugham/MaughamApp.swift"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        XCTAssertTrue(app.contains(#"Button("Go to the Canvas") { MaughamEvent.post(.maughamOpenCanvas, to: .keyWindow) }"#))
        XCTAssertTrue(app.contains("Button(piece) { MaughamEvent.postAddBinderItem(.piece) }"))
        XCTAssertTrue(app.contains("Button(group) { MaughamEvent.postAddBinderItem(.group) }"))
        let window = SourceScan.codeLines(of: try SourceTree.sourceOfType("ProjectWindow", under: ["Maugham"]))
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        XCTAssertTrue(window.contains(
            ".onKeyWindowCommand(.maughamOpenCanvas, window: window) { _ in subject = ClickRule.resolve(.canvas, gesture: .click,"))
        // The post's payload is what the receiver reads.
        XCTAssertEqual(BinderItemRequest(rawValue: BinderItemRequest.group.rawValue), .group)
    }

    // MARK: - The binder's row menus hold what the click does (rows 64–66)

    func test_theRowMenusHoldTheClicksTwinAndTheDoubleClicks() throws {
        // The title says what the click does now.
        let up = PulledUp.research("r1")
        var subject = WindowSubject(open: .item("c1"), faces: .item("c1"))
        XCTAssertEqual(BinderTreeVerbs.pullUpTitle(up, subject: subject, columnShowsPulledUp: true), "Pull Up")
        subject.beside = up
        XCTAssertEqual(BinderTreeVerbs.pullUpTitle(up, subject: subject, columnShowsPulledUp: true), "Put Away")
        XCTAssertEqual(BinderTreeVerbs.pullUpTitle(up, subject: subject, columnShowsPulledUp: false), "Pull Up",
                       "up but not on show: the click shows it again (`TreeRowKeys.returned`)")
        // Each row's menu reaches the act its click and ⌘↓ reach.
        func flat(_ path: String) throws -> String {
            SourceScan.codeLines(of: try SourceTree.read(path))
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }
        let research = try flat("Maugham/Views/ResearchTree.swift")
        XCTAssertTrue(research.contains("Button(title(item.id)) { pullUp(item.id) } Button(BesideHeader.openInCentreLabel) { openInCentre(item.id) }"),
                      "row 65: a research row's menu leads with Pull Up and Open in Centre")
        XCTAssertFalse(research.contains(#"Button("Add Link…")"#), "row 65: Add Web Link…")
        let sections = try flat("Maugham/Views/BinderTreeSections.swift")
        XCTAssertTrue(sections.contains("Button(title(card.id)) { pullUp(card.id) }"), "row 66: a palette card's Pull Up")
        XCTAssertTrue(sections.contains("bundle.pullUp = { id in pullUpOrPutAway(.research(id)) }"))
        XCTAssertTrue(sections.contains(
            "let next = TreeRowKeys.returned(pulled, subject: subject, columnShowsPulledUp: state.columnShowsPulledUp)"),
            "the menu's Pull Up is Return's act")
        XCTAssertTrue(sections.contains(
            "subject = TreeTravel.openInCentre(.research(id), current: subject,"), "⌘↓'s and the double-click's act")
        XCTAssertFalse(sections.contains(#"Button("Add Link…")"#))
        let fold = try flat("Maugham/Views/BinderPieceFold.swift")
        XCTAssertTrue(fold.contains(
            "columnShowsPulledUp: state.columnShowsPulledUp)) { pullUpOrPutAway(entry) } } Button(BesideHeader.openInCentreLabel) { openInCentre(entry) }"),
            "row 64: a fold row's menu leads with Pull Up / Put Away")
    }

    // MARK: - View ▸ Open in Centre (row 41)

    func test_openInCentreOpensTheSelectedRowElseWhatIsPulledUp() throws {
        let row = TreeRowTag.subject(.item("c1"))
        let note = PulledUp.research("r1")
        XCTAssertEqual(TreeRowKeys.centreOpening(drawn: [row], beside: note), .row(row),
                       "the binder's selected row first, as ⌘↓ opens it")
        XCTAssertEqual(TreeRowKeys.centreOpening(drawn: [], beside: note), .pulledUp(note))
        XCTAssertEqual(TreeRowKeys.centreOpening(drawn: [row, .subject(.item("c2"))], beside: note), .pulledUp(note),
                       "several rows are no one row")
        XCTAssertNil(TreeRowKeys.centreOpening(drawn: [], beside: nil), "nothing to open: disabled")
        // One body for ⌘↓ and the menu; the menu item binds no key.
        let sections = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/BinderTreeSections.swift"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        XCTAssertTrue(sections.contains(
            "case .openInCentre(let row): TreeRowKeys.openInCentre(row, subject: $subject, store: store, windowCanvas: windowCanvas)"))
        let window = SourceScan.codeLines(of: try SourceTree.sourceOfType("ProjectWindow", under: ["Maugham"]))
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        XCTAssertTrue(window.contains(
            "case .row(let row)?: TreeRowKeys.openInCentre(row, subject: subjectBinding, store: store, windowCanvas: canvasModel)"))
        let item = try XCTUnwrap(menuBar.first { $0.path == "View ▸ Open in Centre" }, "the item is in the walk")
        XCTAssertNil(item.token, "⌘↓ stays the binder's: no key on the item")
    }

    // MARK: - File ▸ Translate… (row 7)

    func test_translateIsTitledForWhatItTranslatesAndOfferedWhereTheHeadRunsIt() throws {
        // The offer's table is `TranslateMenuRouteTests`; here, the item.
        XCTAssertEqual(TranslateMenuOffer.elsewhereTitle, "Translate\u{2026}")
        let app = SourceScan.codeLines(of: try SourceTree.read("Maugham/MaughamApp.swift"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        XCTAssertTrue(app.contains("MaughamEvent.post(.maughamTranslateFromMenu, to: .keyWindow) } .disabled(!enabled(chrome?.translate != nil)) .help(chrome?.translate == nil ? (chrome?.translateGreyHelp ?? TranslateMenuOffer.elsewhereHelp) : \"\")"))
        XCTAssertEqual(ResolvePane.apply(.translate(.book(language: "sr")), groups: [], sceneIndex: nil, chips: [],
                                         activePassId: nil, dense: false, selection: [.mine], choices: [:]).selection,
                       [.mine], "the list's selection is not the translate ask's")
        let item = try XCTUnwrap(menuBar.first { $0.path == "File ▸ Translate…" })
        XCTAssertNil(item.token, "no key")
    }

}
