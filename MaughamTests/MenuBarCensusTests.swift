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
                lostItsKey: item.keyEquivalent.isEmpty && !extra.isEmpty && item.submenu == nil))
            out += walk(item.submenu, path: here)
        }
        return out
    }

    var menuBar: [WalkedItem] { Self.walk(NSApp.mainMenu) }

    // MARK: - Every key once

    /// A key two items may share, each with its reason.
    struct AllowedOverlap {
        let token: String
        let reason: String
    }

    static let allowedOverlaps: [AllowedOverlap] = [
        // Never two menu items: Format ▸ Table ▸ Fill Right shows no glyph,
        // because ⌘R is File ▸ Check Writing's; the expanded grid answers ⌘R
        // in its own keyDown while it has the keys (R7d-1).
        AllowedOverlap(token: "⌘R", reason: "Fill Right is the grid's keyDown, not a menu equivalent"),
    ]

    /// Each token bound by more than one item, with the items, minus the
    /// allow-listed.
    static func duplicates(_ items: [WalkedItem], allowed: [AllowedOverlap] = allowedOverlaps) -> [String] {
        let bound = items.compactMap { item in item.token.map { ($0, item) } }
        return Dictionary(grouping: bound, by: { $0.0 })
            .filter { group in group.value.count > 1 && !allowed.contains { $0.token == group.key } }
            .map { "\($0.key): " + $0.value.map(\.1.path).joined(separator: " / ") }
            .sorted()
    }

    func test_everyMenuKeyIsBoundOnce() {
        let items = menuBar
        // Premise: the walk reached the app's own commands, not an empty bar.
        XCTAssertTrue(items.contains { $0.token == "⌘S" }, "premise: File ▸ Save is in the walk")
        XCTAssertTrue(items.contains { $0.token == "⌘⌃1" }, "premise: a key bound outside MaughamApp.swift is seen")
        XCTAssertGreaterThan(items.filter { $0.token != nil }.count, 50, "the walk read almost nothing")
        XCTAssertEqual(Self.duplicates(items), [], "one key, two items")
        XCTAssertEqual(items.filter(\.lostItsKey).map(\.path), [],
                       "an item asked for a key another item already holds, and got none")
    }

    /// The control: a planted duplicate is reported; an allowed one is not;
    /// a dropped key is seen.
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
        XCTAssertEqual(Self.duplicates(items), ["⌘J: One / Two"])
        XCTAssertEqual(Self.duplicates(items, allowed: []), ["⌘J: One / Two", "⌘R: Three / Four"])
        XCTAssertEqual(items.filter(\.lostItsKey).map(\.title), ["Lost"])
        XCTAssertEqual(Self.token(key: "Z", mask: .command), "⌘⇧Z")
        XCTAssertEqual(Self.token(key: "\u{F700}", mask: [.command, .option]), "⌘⌥↑")
        XCTAssertEqual(Self.token(key: "r", mask: [.command, .control, .shift]), "⌘⌃⇧R")
    }

    // MARK: - Every key listed

    /// The Mac's own keys, documented by macOS rather than by Maugham —
    /// "🎤" is Edit ▸ Start Dictation's key, which AppKit binds once the Edit
    /// menu has been updated (seen in a full gate, not a lone class).
    static let systemTokens: Set<String> = [
        "⌘Q", "⌘H", "⌘⌥H", "⌘W", "⌘⌥W", "⌘M", "⌘X", "⌘C", "⌘V", "⌘A", "⌘Space", "🎤",
    ]

    static func unlisted(_ tokens: [String], in listed: [String]) -> [String] {
        Array(Set(tokens.filter { !systemTokens.contains($0) && !listed.contains($0) })).sorted()
    }

    func test_everyKeyTheMenusBindHasACheatSheetLineAndAReferenceRow() throws {
        let tokens = menuBar.filter { !$0.isHidden }.compactMap(\.token)
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
    /// every other File, Edit and View item the app adds asks the focused
    /// window: read from the item structs' source, each `Button`/`Toggle`
    /// followed by its own `.disabled(`, or named here with why.
    func test_everyWindowItemAsksTheFocusedWindow() throws {
        let app = SourceScan.codeLines(of: try SourceTree.read("Maugham/MaughamApp.swift"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        let unasked: [String: String] = [
            "New Project…": "opens with or without a project",
            "Open Project…": "opens with or without a project",
            "Dump Coordinator Leak Probe (dev)": "a dev build's instrument, about every window",
        ]
        func items(of type: String) throws -> [String] {
            let start = try XCTUnwrap(app.range(of: "private struct \(type): View {"))
            let rest = app[start.upperBound...]
            let end = rest.range(of: "private struct ")?.lowerBound ?? rest.endIndex
            return Self.ungatedItems(in: String(rest[..<end]))
        }
        for type in ["FileMenuItems", "EditMenuItems", "ViewMenuItems"] {
            XCTAssertEqual(try items(of: type).filter { unasked[$0] == nil }, [], "\(type): an item no window gates")
        }
        let runs = try XCTUnwrap(app.range(of: "private struct RunButtons: View {"))
        let runEnd = try XCTUnwrap(app.range(of: "private struct EditMenuItems", range: runs.upperBound..<app.endIndex))
        let runBody = app[runs.upperBound..<runEnd.lowerBound]
        XCTAssertFalse(runBody.contains(".disabled("), "Run's four are never greyed")
    }

    /// The `Button("…")`/`Toggle("…")` items in `body` with no `.disabled(`
    /// before the next item.
    static func ungatedItems(in body: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"(?:Button|Toggle)\("([^"]*)"\)?"#)
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        var out: [String] = []
        for (i, match) in matches.enumerated() {
            let next = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let span = ns.substring(with: NSRange(location: match.range.location, length: next - match.range.location))
            if !span.contains(".disabled(") { out.append(ns.substring(with: match.range(at: 1))) }
        }
        return out
    }

    func test_theUngatedCensusFiresOnAPlantedOffender() {
        let planted = #"Button("A") { x() } .disabled(!enabled()) Button("B") { y() } .keyboardShortcut("b") Toggle("C", isOn: z) .disabled(q)"#
        XCTAssertEqual(Self.ungatedItems(in: planted), ["B"])
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
        let chapter = StructureItem(id: "c1", title: "One", type: .document, path: "one.md")
        let novel = PieceNoun.Book(type: .novel)
        func offer(reading: String?, faces: BinderSubject, may: Bool = true, any: Bool = true) -> TranslateMenuOffer? {
            TranslateMenuOffer.of(readingLanguage: reading, openPiece: chapter, faces: faces,
                                  sourceLanguage: "en", book: novel, mayTranslate: { _ in may },
                                  mayTranslateAny: any)
        }
        XCTAssertEqual(offer(reading: "sr", faces: .item("c1"))?.title,
                       "Translate This Chapter into \(LanguageName.title("sr"))")
        XCTAssertEqual(offer(reading: nil, faces: .edition(language: "sr"))?.title,
                       "Translate Whole Book into \(LanguageName.title("sr"))")
        XCTAssertNil(offer(reading: nil, faces: .edition(language: "en")), "the Source edition translates nothing")
        XCTAssertNil(offer(reading: nil, faces: .item("c1")), "a piece read in Source")
        XCTAssertNil(offer(reading: "sr", faces: .item("c1"), may: false), "the translator may not")
        XCTAssertNil(offer(reading: nil, faces: .edition(language: "sr"), any: false))
        XCTAssertEqual(TranslateMenuOffer.elsewhereTitle, "Translate\u{2026}")

        // The menu posts; the window shows To resolve and asks its head; the
        // pane hands the ask to the head, which presses its own Run.
        func flat(_ text: String) -> String {
            SourceScan.codeLines(of: text).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }
        let app = flat(try SourceTree.read("Maugham/MaughamApp.swift"))
        XCTAssertTrue(app.contains("MaughamEvent.post(.maughamTranslateFromMenu, to: .keyWindow) } .disabled(!enabled(chrome?.translate != nil))"))
        let window = flat(try SourceTree.sourceOfType("ProjectWindow", under: ["Maugham"]))
        XCTAssertTrue(window.contains(
            ".onKeyWindowCommand(.maughamTranslateFromMenu, window: window) { _ in ProjectWindow.selectPosition(.resolve, showInspector: $showInspector, position: $position) resolveRequest = .translate }"))
        let pane = flat(try SourceTree.read("Maugham/Views/Resolve/ResolvePane.swift"))
        XCTAssertTrue(pane.contains("if case .translate = pending { translateAsk = true return }"))
        XCTAssertTrue(pane.contains("translateAsk = false"), "a new scope spends the ask: it never fires minutes later")
        let piece = flat(try SourceTree.read("Maugham/Views/Resolve/ResolvePieceInLanguage.swift"))
        XCTAssertTrue(piece.contains("if runState.canRun { runThisPiece() } else { notice = runState.refusal }"))
        let edition = flat(try SourceTree.read("Maugham/Views/Resolve/ResolveEditionItems.swift"))
        XCTAssertTrue(edition.contains("if runState.canRunBook { runBook() } else { notice = runState.bookRefusal }"))
        XCTAssertEqual(ResolvePane.apply(.translate, groups: [], sceneIndex: nil, chips: [], activePassId: nil,
                                         dense: false, selection: [.mine], choices: [:]).selection, [.mine],
                       "the list's selection is not the translate ask's")
        let item = try XCTUnwrap(menuBar.first { $0.path == "File ▸ Translate…" })
        XCTAssertNil(item.token, "no key")
    }
}
