import XCTest
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The right column's appraisal wave (2026-11-20)**: the pure rules behind
/// each finding, and the View menu's shape. No window is mounted here; the
/// control's fit is measured in `RightColumnMountingTests`.
///
/// Paragraph ids are 4-char from `ParagraphID`'s alphabet (tripwire 8).
@MainActor
final class RightColumnAppraisalTests: XCTestCase {

    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    private func note(_ id: String, on docId: String) -> ResolveItem {
        .note(ProjectAnnotation(docId: docId, annotation: Annotation(
            id: id, kind: .comment, paragraphId: nil, body: id, suggestedText: nil, priorText: nil,
            createdAt: t, createdBySession: nil, status: .open,
            userResponse: nil, resolvedAt: nil, isStale: false, author: nil)))
    }

    private func todo(_ id: String, on docId: String) -> ResolveItem {
        .todo(WriterTask(id: id, kind: .paneCreated,
                         anchor: TaskAnchor(docId: docId, paragraphId: nil),
                         body: id, status: .open, priority: 0, parentTaskId: nil,
                         createdAt: t, createdBySession: nil))
    }

    private func finding(_ id: String, on docId: String) -> ResolveItem {
        .finding(docId: docId, Diagnostic(
            id: id, docId: docId, anchor: nil,
            body: id, category: nil, runId: "run-1", kind: .conformanceStrain))
    }

    // MARK: - 1. Notes that cannot be acted on say why

    func test_aPieceThatIsNotOpenSaysWhyItsNotesHaveNoButtons() {
        XCTAssertEqual(ResolveHead.openThePieceLine(noun: "chapter", hasItemsToAnswer: true),
                       "Open this chapter to answer its notes")
        XCTAssertEqual(ResolveHead.openThePieceLine(noun: "script", hasItemsToAnswer: false),
                       "Open this script to run a check or a round on it")
        // Notes and to-dos need the piece open; a finding's Answer does not.
        XCTAssertTrue(ResolveHead.hasItemsToAnswer([note("n1", on: "ch-1")], docId: "ch-1"))
        XCTAssertTrue(ResolveHead.hasItemsToAnswer([todo("t1", on: "ch-1")], docId: "ch-1"))
        XCTAssertFalse(ResolveHead.hasItemsToAnswer([finding("f1", on: "ch-1")], docId: "ch-1"))
        XCTAssertFalse(ResolveHead.hasItemsToAnswer([note("n1", on: "ch-2")], docId: "ch-1"),
                       "another piece's notes are not this one's")

        // A Book list's group: a piece not open, with notes, offers its piece.
        let notes = ResolveGroup(key: .piece(docId: "ch-2"), title: "Two",
                                 items: [note("n2", on: "ch-2")])
        XCTAssertEqual(ResolveHead.groupOpensItsPiece(notes, mayAct: { _ in false }), "ch-2")
        XCTAssertNil(ResolveHead.groupOpensItsPiece(notes, mayAct: { $0 == "ch-2" }),
                     "the open piece's rows have their verbs; nothing to say")
        let findings = ResolveGroup(key: .piece(docId: "ch-2"), title: "Two",
                                    items: [finding("f2", on: "ch-2")])
        XCTAssertNil(ResolveHead.groupOpensItsPiece(findings, mayAct: { _ in false }),
                     "findings are answered from anywhere")
        let paragraph = ResolveGroup(key: .paragraph(docId: "ch-2", paragraphId: "ab12"),
                                     title: "A paragraph", items: [note("n3", on: "ch-2")])
        XCTAssertNil(ResolveHead.groupOpensItsPiece(paragraph, mayAct: { _ in false }),
                     "only a Book or Part list's piece group carries the line")

        // The noun is the project's word for a piece.
        let chapter = StructureItem(id: "ch-1", title: "One", type: .document, path: "one.md")
        XCTAssertEqual(FiledUnder.pieceNoun(chapter, projectType: .novel), "chapter")
        XCTAssertEqual(FiledUnder.pieceNoun(chapter, projectType: .collection), "piece")
    }

    // MARK: - 2. The faces' subject, named

    func test_theSubjectLineNamesWhatThePanesAreAbout() {
        let structure = [
            StructureItem(id: "ch-1", title: "Chapter Three", type: .document, path: "three.md"),
            StructureItem(id: "part-1", title: "Part Two", type: .group, children: [
                StructureItem(id: "ch-2", title: "  ", type: .document, path: "two.md"),
            ]),
        ]
        let figures = [FigureRecord(id: "fig-0000aaaa", name: "cashflow", kind: .table,
                                    piece: nil, path: "figures/cashflow.csv")]
        func title(_ faces: BinderSubject, book: String = "The Long Way") -> String? {
            RightColumnSubjectLine.title(of: faces, structure: structure, bookTitle: book, figures: figures)
        }
        XCTAssertEqual(title(.item("ch-1")), "Chapter Three")
        XCTAssertEqual(title(.item("part-1")), "Part Two")
        XCTAssertEqual(title(.item("ch-2")), "Untitled", "a blank title is never a blank line")
        XCTAssertEqual(title(.project), "The Long Way")
        XCTAssertEqual(title(.project, book: ""), "The book")
        XCTAssertEqual(title(.figure("fig-0000aaaa")), "cashflow")
        XCTAssertEqual(title(.edition(language: "es")),
                       "\(TreeEditionRows.title(forLanguage: "es")) edition")
        for nothing: BinderSubject in [.canvas, .inbox, .palette, .research("r1"), .item("gone")] {
            XCTAssertNil(title(nothing), "\(nothing) names nothing the panes are about")
        }
        // It is drawn over To resolve (and its interim answer) and Brief,
        // from the faces — never over the pulled-up position.
        let lines = SourceScan.codeLines(of: try! SourceTree.read("Maugham/Views/RightColumn.swift"))
        XCTAssertEqual(lines.filter { $0.trimmingCharacters(in: .whitespaces) == "subjectLine" }.count, 3,
                       "To resolve (an edition's included), the review and Brief each lead with the line")
        XCTAssertTrue(lines.contains { $0.contains("of: subject.faces,") })
    }

    // MARK: - 4. ⌘3 with nothing to show is not a dead end

    /// Every key the empty state names is the View menu's pull-up key — read
    /// back out of `MaughamApp.swift`, so a key moved in the menu reds this.
    func test_nothingPulledUpSaysHowToPullSomethingUp() throws {
        let hint = PulledUpView.nothingPulledUpHint
        XCTAssertTrue(hint.contains("fold"), "the fold is the way in")
        let keys = hint.components(separatedBy: "\u{2318}\u{2325}").dropFirst().map { String($0.prefix(1)) }
        XCTAssertEqual(keys, ["G", "Y", "V", "H"])
        let app = SourceScan.codeLines(of: try SourceTree.read("Maugham/MaughamApp.swift"))
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        for key in keys {
            let pattern = #"Button\("[^"]*"\) \{ MaughamEvent\.postPullUp\(\.\w+\) \} \.keyboardShortcut\(""#
                + key.lowercased() + #"", modifiers: \[\.command, \.option\]\)"#
            XCTAssertNotNil(app.range(of: pattern, options: .regularExpression),
                            "⌘⌥\(key) is not a pull-up key in the View menu")
        }
        // The control: a key that is not a pull-up does not pass.
        let planted = #"Button\("[^"]*"\) \{ MaughamEvent\.postPullUp\(\.\w+\) \} \.keyboardShortcut\("d", modifiers: \[\.command, \.option\]\)"#
        XCTAssertNil(app.range(of: planted, options: .regularExpression))
        // A ContentUnavailableView's description, under tripwire 15's frames.
        let view = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/PulledUpView.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(view.contains("Text(Self.nothingPulledUpHint)"))
    }

    // MARK: - 14. A covered pulled-up thing is named

    func test_whatTheCanvasDetailsCoverIsNamedAndShowItClearsTheSelection() {
        XCTAssertEqual(CanvasDetailsCover<EmptyView>.coveredLine("Notes on Rome"),
                       "Notes on Rome is pulled up")
        XCTAssertEqual(CanvasDetailsCover<EmptyView>.coveredLine(""),
                       "\(PulledUpView.canvasCardTitle) is pulled up", "never a sentence with no subject")
        let model = CanvasModel()
        model.selection = .region(CanvasRegionID("r1"))
        XCTAssertTrue(RightColumnContent.canvasDetailsCover(
            canvasIsTheCentre: true, somethingIsPulledUp: true, canvasHasASelection: model.selection != nil,
            selectionIsNewerThanPullUp: true))
        CanvasDetailsCover<EmptyView>.showIt(model)
        XCTAssertNil(model.selection)
        XCTAssertFalse(RightColumnContent.canvasDetailsCover(
            canvasIsTheCentre: true, somethingIsPulledUp: true, canvasHasASelection: model.selection != nil,
            selectionIsNewerThanPullUp: true),
            "Show it lifts the cover")
    }

    // MARK: - 5. The View menu, grouped by destination

    /// The View menu's own group (`CommandGroup(after: .toolbar)`), as the
    /// items' titles in order with a `|` for each divider.
    private static func viewMenuSequence(_ app: String) -> [String] {
        guard let start = app.range(of: "CommandGroup(after: .toolbar) {"),
              let end = app.range(of: "CommandGroup(after: .pasteboard) {", range: start.upperBound..<app.endIndex)
        else { return [] }
        let body = String(app[start.upperBound..<end.lowerBound])
        let regex = try! NSRegularExpression(pattern: #"Button\("([^"]*)"\)|Divider\(\)|(Focused\w+)\(\)"#)
        let ns = body as NSString
        return regex.matches(in: body, range: NSRange(location: 0, length: ns.length)).map { match in
            if match.range(at: 1).location != NSNotFound { return ns.substring(with: match.range(at: 1)) }
            if match.range(at: 2).location != NSNotFound { return ns.substring(with: match.range(at: 2)) }
            return "|"
        }
    }

    /// The groups between dividers.
    private static func groups(_ sequence: [String]) -> [[String]] {
        sequence.split(separator: "|").map(Array.init)
    }

    static let toResolveGroup = [
        "To Resolve", "To Resolve: Checks", "To Resolve: Rounds", "To Resolve: Mine",
        "To Resolve: Questions", "FocusedEditionResolveButton",
    ]
    static let briefGroup = ["Brief", "Brief: the Line", "Brief: Going For"]
    static let pullUpGroup = [
        "Pulled Up", "Pull Up What I've Learned", "Pull Up First Reader",
        "Pull Up Visual Language", "Pull Up History", "FocusedPullUpPreviousButton",
    ]

    func test_theViewMenuGroupsTheRightColumnByWhereEachItemLands() throws {
        let app = SourceScan.codeLines(of: try SourceTree.read("Maugham/MaughamApp.swift"))
            .joined(separator: "\n")
        let groups = Self.groups(Self.viewMenuSequence(app))
        XCTAssertGreaterThan(groups.count, 3, "premise: the View menu's group is read: \(groups)")
        for expected in [Self.toResolveGroup, Self.briefGroup, Self.pullUpGroup] {
            XCTAssertTrue(groups.contains(expected), "no group is exactly \(expected): \(groups)")
        }
        // In the one order the control draws: To resolve, Brief, Pulled up.
        let positions = [Self.toResolveGroup, Self.briefGroup, Self.pullUpGroup]
            .compactMap { groups.firstIndex(of: $0) }
        XCTAssertEqual(positions, positions.sorted())
        // The window toggles, titled for the right column and the Lock.
        let toggles = try XCTUnwrap(groups.first)
        XCTAssertTrue(toggles.contains("FocusedRightColumnToggle"))
        XCTAssertTrue(toggles.contains("FocusedLockToggle"))
        XCTAssertFalse(Self.viewMenuSequence(app).contains("Toggle Inspector"),
                       "the item names a panel that no longer exists")
        XCTAssertEqual(RightColumn.toggleTitle(shown: true), "Hide Right Column")
        XCTAssertEqual(RightColumn.toggleTitle(shown: false), "Show Right Column")

        // The planted offender: Brief: the Line moved into To resolve's group.
        let planted = app.replacingOccurrences(
            of: #"Button("Brief: the Line") { MaughamEvent.postBriefField(.line) }"#,
            with: "")
            .replacingOccurrences(
                of: #"Button("To Resolve: Mine") { MaughamEvent.postResolve(.mine) }"#,
                with: #"Button("To Resolve: Mine") { MaughamEvent.postResolve(.mine) } Button("Brief: the Line") { }"#)
        XCTAssertNotEqual(planted, app, "premise: the plant applies")
        let plantedGroups = Self.groups(Self.viewMenuSequence(planted))
        XCTAssertFalse(plantedGroups.contains(Self.toResolveGroup)
                       && plantedGroups.contains(Self.briefGroup),
                       "control: the census sees an item in the wrong group")
    }
}

/// **The toolbar's right-column button** (`RightColumnToggle`): drawn on the
/// window toolbar's trailing edge whether the column shows or not, hidden with
/// that toolbar in `⌘\` focus mode, and flipping the one state ⌘⌥0's receiver
/// flips. Read from the source and asked of the pure rules — never pressed
/// (tripwire 33).
@MainActor
final class RightColumnToggleTests: XCTestCase {

    /// `file`'s code on one line, whitespace collapsed.
    private static func flat(_ file: String) throws -> String {
        SourceScan.codeLines(of: try SourceTree.read(file)).joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func test_theButtonSaysWhatAPressDoesAndNamesItsKey() {
        XCTAssertEqual(RightColumnToggle.symbol, "sidebar.right")
        XCTAssertEqual(RightColumnToggle.tooltip(shown: true), "Hide Right Column (\u{2318}\u{2325}0)")
        XCTAssertEqual(RightColumnToggle.tooltip(shown: false), "Show Right Column (\u{2318}\u{2325}0)")
        let source = try? Self.flat("Maugham/Views/RightColumnToggle.swift")
        XCTAssertTrue(source?.contains(".accessibilityLabel(RightColumn.toggleTitle(shown: showInspector))") ?? false,
                      "the accessibility label is the menu item's title")
    }

    /// **On the trailing edge, in the toolbar `⌘\` hides, unconditionally**:
    /// the item sits in `TopChromeModifier`'s `.toolbar`, beside the Lock,
    /// whose visibility is `windowToolbarIsVisible` — and no `if` guards it,
    /// so it is drawn with the column hidden as well as shown.
    func test_theButtonRidesTheWindowToolbarOnItsTrailingEdge() throws {
        let window = try Self.flat("Maugham/Views/ProjectWindow.swift")
        XCTAssertTrue(window.contains(
            ".toolbar { ToolbarItem(placement: .navigation) { LockToggle(isLocked: $isLocked) } "
            + "if centreViewOffer != .none { ToolbarItem(placement: .primaryAction) { "
            + "CentreViewSwitchControl(offer: centreViewOffer, choose: chooseCentreView) } } "
            + "ToolbarItem(placement: .primaryAction) { RightColumnToggle(showInspector: $showInspector) } } "
            + ".toolbar(toolbarVisibility, for: .windowToolbar)"),
            "the button is the window toolbar's trailing item, after the centre's view "
            + "switch (shell p4 Task 4), hidden with it")
        XCTAssertFalse(ProjectWindow.windowToolbarIsVisible(isNoChromeOn: true))
        XCTAssertTrue(ProjectWindow.windowToolbarIsVisible(isNoChromeOn: false))
        XCTAssertTrue(window.contains("TopChromeModifier( projectURL: url, store: store, "
                                      + "isNoChromeOn: isNoChromeOn, isLocked: $isLocked, "
                                      + "window: window, showInspector: $showInspector,"),
                      "the button is bound to the window's own showInspector")
    }

    /// **One write, two doors**: the only flips of the column in production
    /// are ⌘⌥0's receiver and the button, both `showInspector.toggle()` —
    /// and the button writes nothing else, so the column's width and
    /// position survive a hide and show.
    func test_theButtonAndTheMenuFlipTheOneState() throws {
        var flips: [String: Int] = [:]
        for file in try SourceTree.swiftFiles(under: "Maugham") {
            let n = SourceScan.codeLines(of: try SourceTree.read(file))
                .filter { $0.contains("showInspector.toggle()") }.count
            if n > 0 { flips[file] = n }
        }
        XCTAssertEqual(flips, ["Maugham/Views/ProjectWindow.swift": 1,
                               "Maugham/Views/RightColumnToggle.swift": 1])
        let window = try Self.flat("Maugham/Views/ProjectWindow.swift")
        XCTAssertTrue(window.contains(
            ".onKeyWindowCommand(.maughamToggleInspector, window: window) { _ in showInspector.toggle() }"),
            "⌘⌥0's receiver")
        let button = try Self.flat("Maugham/Views/RightColumnToggle.swift")
        for other in ["detailColumnWidth", "rightColumnPosition", "position", "width", "stash"] {
            XCTAssertFalse(button.contains(other), "the button touches \(other)")
        }
    }

    /// **The canvas's collapse does not take back a column a writer showed**:
    /// collapsed (the stash set), a show answers `.unchanged`, as ⌘⌥0's does,
    /// and leaving the canvas hands back what was stashed.
    func test_aShowUnderTheCanvasCollapseStands() {
        XCTAssertEqual(ProjectWindow.canvasCollapse(route: .canvas, isNoChromeOn: true,
                                                    showInspector: true, stash: true), .unchanged)
        XCTAssertEqual(ProjectWindow.canvasCollapse(route: .canvas, isNoChromeOn: true,
                                                    showInspector: false, stash: nil),
                       .collapse(columnVisibility: .doubleColumn, showInspector: false, stash: false),
                       "control: a fresh collapse does hide it")
    }
}
