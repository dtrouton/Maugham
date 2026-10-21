// MaughamTests/Editor/InsertCommandTests.swift
import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// The Insert menu end to end (plan 3a Task 4): the command posted as the menu
/// posts it, answered by a mounted `EditorSurface` through Route A. Each insert
/// is one ⌘Z step that leaves the writer's earlier typing undoable; the
/// membrane refuses it in a read-only posture, review mode and translation
/// review; and a surface that is not a manuscript (a research note, a
/// statement) never answers. No clicks, no waits after a post: delivery is
/// synchronous on the main thread, so the test posts, then asserts.
@MainActor
final class InsertCommandTests: XCTestCase {
    override class func setUp() { FontWarmup.ensure() }

    // MARK: - Fixture

    /// The text a mounted surface's binding holds, and how often it was written.
    final class Box {
        var text: String
        var writes = 0
        init(_ text: String) { self.text = text }
    }

    struct Mounted {
        let box: Box
        let window: KeyTestWindow
        let textView: NSTextView
        let coordinator: EditorCoordinator
    }

    /// An `EditorSurface` mounted in a window that reports itself key, with the
    /// configuration a host would build. `answersInsertCommands` is what
    /// `EditorHost` says for a Markdown manuscript; the default (false) is what
    /// `ResearchNoteEditor` and `StatementEditorHost` build.
    private func mount(_ text: String, answersInsertCommands: Bool = true,
                       labelsElsewhere: (() -> Set<ManuscriptLabel>)? = nil) throws -> Mounted {
        let box = Box(text)
        let binding = Binding(get: { box.text },
                              set: { box.text = $0; box.writes += 1 })
        var configuration = EditorSurfaceConfiguration(
            presentation: .init(theme: .light, typography: .defaults, mode: ProseMode(),
                                typewriterScroll: false, sentenceFocus: false,
                                paragraphFocus: false, showElementGutter: false),
            control: EditorControl())
        configuration.answersInsertCommands = answersInsertCommands
        configuration.paragraphProviders.projectLabelsElsewhere = labelsElsewhere
        let window = TestWindow.mount(EditorSurface(text: binding, configuration: configuration),
                                      size: CGSize(width: 700, height: 500),
                                      as: KeyTestWindow.self)
        addTeardownBlock { @MainActor in
            window.reportsKey = false
            window.close()
        }
        let textView = try XCTUnwrap(Self.textView(in: window.contentView),
                                     "the mounted surface has no text view")
        let coordinator = try XCTUnwrap(textView.delegate as? EditorCoordinator)
        XCTAssertTrue(window.isKeyWindow,
                      "the window must report key, or a .keyWindow post reaches nothing "
                      + "and every refusal below proves nothing")
        return Mounted(box: box, window: window, textView: textView, coordinator: coordinator)
    }

    private static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }

    /// Run `body` as one user event does: in its own top-level undo group.
    ///
    /// In the app, `NSApplication` closes the undo group a keystroke or a menu
    /// item opened when that event ends (`groupsByEvent`). The test host runs no
    /// event loop, so that group never closes — measured: `groupingLevel` stays
    /// 1 after a runloop spin, and the typing and the insert land in one group
    /// that a single ⌘Z takes back together. Bracketing each event by hand is
    /// the app's grouping, stated, not a weaker one.
    private func asOneEvent(_ m: Mounted, _ body: () -> Void) throws {
        let undo = try XCTUnwrap(m.textView.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    /// Type as the keyboard does (`insertText`, typing undo), one event.
    private func type(_ s: String, into m: Mounted) throws {
        m.window.makeFirstResponder(m.textView)
        m.textView.setSelectedRange(NSRange(location: (m.textView.string as NSString).length,
                                            length: 0))
        try asOneEvent(m) {
            m.textView.insertText(s, replacementRange: m.textView.selectedRange())
        }
    }

    // MARK: - One undo step

    func test_insertTableIsOneUndoStepAndTheEarlierTypingSurvivesIt() throws {
        let m = try mount("")
        try type("Intro", into: m)
        let undo = try XCTUnwrap(m.textView.undoManager)
        XCTAssertTrue(undo.canUndo, "the typing registered no undo, so this proves nothing")

        try asOneEvent(m) { MaughamEvent.post(.maughamInsertTable, to: .keyWindow) }

        let table = ReportInsert.table(nextLabelNumber: 1)
        XCTAssertEqual(m.textView.string, "Intro\n\n" + table)
        XCTAssertEqual(m.box.text, m.textView.string,
                       "the insert reached the binding — the op log's door")
        XCTAssertEqual((m.textView.string as NSString).substring(with: m.textView.selectedRange()),
                       "Column 1", "the first header cell is selected")

        undo.undo()
        XCTAssertEqual(m.textView.string, "Intro", "one ⌘Z takes back the whole table")
        XCTAssertTrue(undo.canUndo, "the writer's typing is still undoable after it")
        undo.undo()
        XCTAssertEqual(m.textView.string, "", "and the next ⌘Z takes back the typing")
    }

    func test_insertFootnoteIsOneUndoStepAndTheCaretWaitsAtTheDefinition() throws {
        let m = try mount("")
        try type("A claim.", into: m)
        m.textView.setSelectedRange(NSRange(location: ("A claim" as NSString).length, length: 0))
        let undo = try XCTUnwrap(m.textView.undoManager)

        try asOneEvent(m) { MaughamEvent.post(.maughamInsertFootnote, to: .keyWindow) }

        XCTAssertEqual(m.textView.string, "A claim[^1].\n\n[^1]: ")
        XCTAssertEqual(m.textView.selectedRange(),
                       NSRange(location: ("A claim[^1].\n\n[^1]: " as NSString).length, length: 0),
                       "textDidChange's cursor restore must not pull the caret back")
        XCTAssertEqual(m.box.text, m.textView.string)

        undo.undo()
        XCTAssertEqual(m.textView.string, "A claim.")
        XCTAssertTrue(undo.canUndo, "the typing survives the footnote's undo")
    }

    /// The writer's real flow: type, insert a footnote, type the note. Each is
    /// its own ⌘Z step — the note's typing must not coalesce into the typing
    /// before the insert (whose range the insert has moved).
    func test_typingTheNoteAfterTheInsertIsItsOwnUndoStep() throws {
        let m = try mount("")
        try type("A claim.", into: m)
        try asOneEvent(m) { MaughamEvent.post(.maughamInsertFootnote, to: .keyWindow) }
        try asOneEvent(m) {
            m.textView.insertText("Source.", replacementRange: m.textView.selectedRange())
        }
        XCTAssertEqual(m.textView.string, "A claim.[^1]\n\n[^1]: Source.")
        let undo = try XCTUnwrap(m.textView.undoManager)

        undo.undo()
        XCTAssertEqual(m.textView.string, "A claim.[^1]\n\n[^1]: ", "⌘Z takes back the note")
        undo.undo()
        XCTAssertEqual(m.textView.string, "A claim.", "then the footnote")
        undo.undo()
        XCTAssertEqual(m.textView.string, "", "then the typing before it")
    }

    /// I1: the table's label is unique across the PROJECT. The host's
    /// `projectLabelsElsewhere` (another chapter defines `tbl:table-1`) reaches
    /// the number, asked when the command runs.
    func test_insertTableNumbersPastTheLabelsOtherDocumentsDefine() throws {
        var asked = 0
        let m = try mount("Text.", labelsElsewhere: {
            asked += 1
            return [ManuscriptLabel(reference: "tbl:table-1")!,
                    ManuscriptLabel(reference: "fig:table-2")!]
        })
        XCTAssertEqual(asked, 0, "the walk ran before any command — it must be per command")
        MaughamEvent.post(.maughamInsertTable, to: .keyWindow)
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(m.textView.string.hasSuffix("{#tbl:table-2}"),
                      "table-1 is taken in another chapter; got \(m.textView.string)")
    }

    func test_insertFootnoteNumbersPastTheLabelsTheDocumentUses() throws {
        let m = try mount("One[^1].\n\n[^2]: Two.\n\nThree.")
        m.textView.setSelectedRange(NSRange(location: (m.textView.string as NSString).length,
                                            length: 0))
        MaughamEvent.post(.maughamInsertFootnote, to: .keyWindow)
        XCTAssertEqual(m.textView.string, "One[^1].\n\n[^2]: Two.\n\nThree.[^3]\n\n[^3]: ")
    }

    // MARK: - The membrane refuses

    func test_aReadOnlyPostureRefusesBothInserts() throws {
        try assertRefused { $0.setLockEditing(true) }
    }

    func test_reviewModeRefusesBothInserts() throws {
        try assertRefused { $0.setReviewMode(true) }
    }

    func test_translationReviewRefusesBothInserts() throws {
        try assertRefused { $0.setTranslationReview(true) }
    }

    private func assertRefused(_ posture: (EditorCoordinator) -> Void,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let text = "A sentence."
        let m = try mount(text)
        posture(m.coordinator)
        let writes = m.box.writes
        let undo = try XCTUnwrap(m.textView.undoManager)
        undo.removeAllActions()

        MaughamEvent.post(.maughamInsertTable, to: .keyWindow)
        MaughamEvent.post(.maughamInsertFootnote, to: .keyWindow)

        XCTAssertEqual(m.textView.string, text, "the membrane let an insert through",
                       file: file, line: line)
        XCTAssertEqual(m.box.writes, writes, "a refused insert reached the binding",
                       file: file, line: line)
        XCTAssertFalse(undo.canUndo, "a refused insert left an undo step",
                       file: file, line: line)
    }

    // MARK: - Only a manuscript surface answers

    /// A research note's surface (`answersInsertCommands` left false, as
    /// `ResearchNoteEditor` builds it) is a primary editor that answers the
    /// window's other commands, and must not answer these. The control is the
    /// same mount saying true, so the refusal is about the flag and not about a
    /// post that reached nobody.
    func test_aSurfaceThatIsNotAManuscriptIgnoresTheInsertCommands() throws {
        let note = try mount("Research note.", answersInsertCommands: false)
        XCTAssertNotNil(note.coordinator.receiverContext(.keyWindow),
                        "precondition: the note answers the window's other commands")

        MaughamEvent.post(.maughamInsertTable, to: .keyWindow)
        MaughamEvent.post(.maughamInsertFootnote, to: .keyWindow)
        XCTAssertEqual(note.textView.string, "Research note.",
                       "an Insert command wrote into a research note")

        // Control.
        note.window.reportsKey = false
        let manuscript = try mount("Chapter.")
        MaughamEvent.post(.maughamInsertFootnote, to: .keyWindow)
        XCTAssertNotEqual(manuscript.textView.string, "Chapter.",
                          "the manuscript surface did not answer either — the test above proves nothing")
        XCTAssertEqual(note.textView.string, "Research note.")
    }

    // MARK: - Only the focused editor answers (whole-branch review M1)

    /// A statement pane or a research note in the same window holds the focus:
    /// ⌘⇧T is not the manuscript's, so it neither writes there nor takes the
    /// focus over. The control: the manuscript focused, and a non-text view
    /// (the binder) focused, both answer.
    func test_anotherTextInputWithTheFocusKeepsTheInsertOutOfTheManuscript() throws {
        let m = try mount("Chapter.")
        let sibling = NSTextView(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        m.window.contentView?.addSubview(sibling)
        m.window.makeFirstResponder(sibling)
        XCTAssertTrue(m.window.firstResponder === sibling, "precondition: the sibling has the focus")

        MaughamEvent.post(.maughamInsertTable, to: .keyWindow)
        MaughamEvent.post(.maughamInsertFootnote, to: .keyWindow)
        MaughamEvent.post(.maughamInsertFigure, to: .keyWindow)
        XCTAssertEqual(m.textView.string, "Chapter.", "an insert reached the unfocused manuscript")
        XCTAssertTrue(m.window.firstResponder === sibling, "the insert pulled the focus over")

        m.window.makeFirstResponder(nil)                  // a non-text view: the window itself
        MaughamEvent.post(.maughamInsertFootnote, to: .keyWindow)
        XCTAssertEqual(m.textView.string, "Chapter.[^1]\n\n[^1]: ",
                       "with no text input focused the manuscript still answers")

        m.window.makeFirstResponder(m.textView)
        try asOneEvent(m) { MaughamEvent.post(.maughamInsertTable, to: .keyWindow) }
        XCTAssertTrue(m.textView.string.contains("| Column 1 |"), "the focused manuscript answers")
    }

    // MARK: - Census: who may say "this surface answers Insert"

    /// The files allowed to name `answersInsertCommands`: its two declarations,
    /// the one forward, and `EditorHost`, the one host that sets it.
    static let answersInsertCommandsFiles: Set<String> = [
        "Maugham/Editor/EditorSurface.swift",
        "Maugham/Editor/EditorCoordinator.swift",
        "Maugham/Editor/EditorCoordinator+Insert.swift",
        // The completion list opens on a manuscript surface only (plan 3b Task 2).
        "Maugham/Editor/EditorCoordinator+Completion.swift",
        "Maugham/Views/EditorHost.swift",
    ]

    static func filesNamingTheFlag(in files: [(path: String, text: String)]) -> Set<String> {
        Set(files.filter { $0.text.contains("answersInsertCommands") }.map(\.path))
    }

    func test_onlyEditorHostSaysASurfaceAnswersInsert() throws {
        var files: [(path: String, text: String)] = []
        for root in SourceTree.productionRoots {
            for path in try SourceTree.swiftFiles(under: root) {
                files.append((path, try SourceTree.read(path)))
            }
        }
        XCTAssertGreaterThan(files.count, 100, "the walk found almost nothing — vacuous")
        let naming = Self.filesNamingTheFlag(in: files)
        XCTAssertEqual(naming, Self.answersInsertCommandsFiles,
            "A file outside the named list names `answersInsertCommands`. Only EditorHost — "
            + "the Markdown manuscript's editor — may make a surface answer the Insert menu; "
            + "a research note or statement saying true would take a table or a footnote.")
        let host = try SourceTree.read("Maugham/Views/EditorHost.swift")
        XCTAssertTrue(host.contains("answersInsertCommands: !DocumentFormat.ofManuscript(path: path).isScreenplay"),
                      "EditorHost no longer sets the flag, so no manuscript answers Insert")
        XCTAssertTrue(host.contains("projectLabelsElsewhere: {"),
                      "EditorHost no longer hands the editor the project's other labels, "
                      + "so a table label can repeat another chapter's")
    }

    /// Control: a planted research-note file that sets the flag is reported.
    func test_theSurfaceCensusFiresOnAPlantedOffender() {
        let planted: [(path: String, text: String)] = [
            ("Maugham/Views/EditorHost.swift", "answersInsertCommands: true"),
            ("Maugham/Views/ResearchNoteEditor.swift",
             "EditorSurfaceConfiguration(control: c, answersInsertCommands: true)"),
            ("Maugham/Views/StatementEditorHost.swift", "isSecondEditorInItsWindow: true"),
        ]
        XCTAssertEqual(Self.filesNamingTheFlag(in: planted)
                        .subtracting(Self.answersInsertCommandsFiles),
                       ["Maugham/Views/ResearchNoteEditor.swift"])
    }

    // MARK: - The menu's enabled state

    func test_theMenuIsEnabledOnlyForAWritableMarkdownManuscriptInTheEditor() {
        let author = Posture(.unrestricted)
        let bare = CentreRoute.editor(altitude: false, cover: nil)
        func gate(posture: Posture? = author, format: DocumentFormat? = .markdown,
                  review: Bool = false, share: Bool = false, translation: Bool = false,
                  route: CentreRoute? = bare) -> Bool {
            InsertMenuGate.isEnabled(posture: posture, format: format, manualReview: review,
                                     shareIsReadOnly: share, isTranslationReview: translation,
                                     route: route)
        }
        XCTAssertTrue(gate(), "a writable Markdown chapter in the editor")
        XCTAssertFalse(gate(posture: .settling), "a posture that refuses .writeText")
        XCTAssertFalse(gate(posture: nil), "no manuscript in the editor")
        XCTAssertFalse(gate(review: true), "review mode")
        XCTAssertFalse(gate(translation: true), "translation review")
        XCTAssertFalse(gate(share: true), "a read-only iCloud share")
        XCTAssertFalse(gate(format: .fountain), "a screenplay")
        XCTAssertFalse(gate(format: nil), "no document path")
        XCTAssertFalse(gate(route: nil), "no project store")
    }

    /// Every centre but the bare editor hides the text an insert would land
    /// in — the covers that draw over a CHAPTER (publish problems, a
    /// translation round) included.
    func test_theMenuIsDisabledUnderEveryCoverAndEveryOtherCentre() {
        let problem = TectonicLogParser.Diagnostic(
            level: .error, file: nil, line: nil, message: "a problem",
            contextLines: [], pieceID: "ch-1", paragraphID: "a1b2")
        let reference = StructureItem(id: "piece-ref", title: "Linked", type: .document,
                                      path: "pieces/ref/.maugham-link.json",
                                      pieceKind: .reference)
        let covers: [CentreCover] = [
            .publishProblems([problem]),
            .translationRound(CentreRouteTests.round),
            .designGate(CentreRouteTests.proposal),
            .books([CentreRouteTests.book]),
            .notice(.neverCompiled),
            .reviewBoard,
        ]
        var routes: [CentreRoute] = covers.flatMap {
            [CentreRoute.editor(altitude: false, cover: $0), .editor(altitude: true, cover: $0)]
        }
        routes += [.editor(altitude: true, cover: nil), .canvas, .paletteWall,
                   .research(id: "r1"), .reference(piece: reference)]
        for route in routes {
            XCTAssertFalse(
                InsertMenuGate.isEnabled(posture: Posture(.unrestricted), format: .markdown,
                                         manualReview: false, shareIsReadOnly: false,
                                         isTranslationReview: false, route: route),
                "the Insert menu is enabled under \(route)")
        }
    }

    // MARK: - Shortcut census

    func test_theInsertShortcutsAreBoundOnceAndListed() throws {
        let app = try SourceTree.read("Maugham/MaughamApp.swift")
        let tokens = DocSyncTests.extractShortcutBindings(from: app).map(\.token)
        XCTAssertGreaterThan(tokens.count, 30, "the extractor read almost nothing — vacuous")
        XCTAssertEqual(Self.duplicates(tokens), [],
                       "MaughamApp.swift binds one key to two menu items")
        let cheatsheet = KeyboardShortcuts.all.flatMap(\.items).map(\.shortcut)
        for token in ["⌘⇧T", "⌘⇧N", "⌘⇧I", "⌘⇧C"] {
            XCTAssertEqual(tokens.filter { $0 == token }.count, 1, "\(token) is not bound once")
            XCTAssertTrue(cheatsheet.contains(token), "\(token) is missing from the ⌘/ cheatsheet")
        }
    }

    func test_theDuplicateCheckFiresOnAPlantedOffender() {
        let planted = """
            Button("A") { }.keyboardShortcut("t", modifiers: [.command, .shift])
            Button("B") { }.keyboardShortcut("t", modifiers: [.shift, .command])
            Button("C") { }.keyboardShortcut("n", modifiers: [.command, .shift])
            """
        let tokens = DocSyncTests.extractShortcutBindings(from: planted).map(\.token)
        XCTAssertEqual(Self.duplicates(tokens), ["⌘⇧T"])
    }

    static func duplicates(_ tokens: [String]) -> [String] {
        Dictionary(grouping: tokens, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
    }
}
