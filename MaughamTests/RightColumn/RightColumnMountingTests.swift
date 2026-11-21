import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The right column, finished** (shell plan 3 Task 9): three positions and
/// nothing else. What is pinned here:
/// - the keys — ⌘1/⌘2/⌘3 and where each old pane's ⌘⌥ letter lands — read out
///   of `MaughamApp.swift`, the one place a right-column key is declared;
/// - the window's verbs for a position (`selectPosition`, `pullUp`,
///   `openBrief`, `showStrain`, a statement mark's destination);
/// - the control (its segments, its dots, its fit at the column's floor with
///   a 200-character title);
/// - what a subject change does to the position, and that a restore does not;
/// - Escape: the pulled-up thing's claim, and the canvas's dim leaving a
///   pulled-up thing that is not its own preview where it is;
/// - the deleted types, censused gone;
/// - mounted, as measurements only (tripwire 33): each arm of
///   `RightColumnContent` draws what the table says.
///
/// The rules the pane picker's order suite held — the one order, the desk
/// only with an edition, a requested position landing under every subject,
/// every position and pull-up having a menu key, the unread dot on To resolve
/// — are re-made here and in `RightColumnContentTests`.
@MainActor
final class RightColumnMountingTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var fixtures: [StatementMountFixture] = []
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        await waitOut(0.05)
        windows.removeAll()
        for fixture in fixtures { await fixture.closeAndTearDown() }
        fixtures.removeAll()
        try await super.tearDown()
    }

    private func fixture(_ name: String) async throws -> StatementMountFixture {
        let made = try await StatementMountFixture.novel(named: name)
        fixtures.append(made)
        return made
    }

    /// `source`'s code (comments stripped) on one line, whitespace collapsed,
    /// so a token reads the same however the call is wrapped.
    private static func flat(_ source: String) -> String {
        SourceScan.codeLines(of: source).joined(separator: "\n")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private let structure: [StructureItem] = [
        StructureItem(id: "ch-1", title: "One", type: .document, path: "one.md"),
        StructureItem(id: "part-1", title: "Part", type: .group, children: [
            StructureItem(id: "ch-2", title: "Two", type: .document, path: "two.md"),
        ]),
    ]

    private static let piece = WindowSubject(open: .item("ch-1"), faces: .item("ch-1"))

    /// Every kind of subject the window can hold.
    private static let subjects: [WindowSubject] = [
        .book,
        piece,
        WindowSubject(open: .item("part-1"), faces: .item("part-1")),
        WindowSubject(open: .canvas, faces: .canvas),
        WindowSubject(open: .canvas, faces: .item("ch-1")),
        WindowSubject(open: .edition(language: "es"), faces: .edition(language: "es")),
        WindowSubject(open: .edition(language: "es"), faces: .item("ch-1")),
        WindowSubject(open: .research("r1"), faces: .research("r1")),
        WindowSubject(open: .figure("f1"), faces: .figure("f1")),
        WindowSubject(open: .inbox, faces: .inbox),
        WindowSubject(open: .palette, faces: .palette),
        WindowSubject(open: .item("ch-1"), faces: .item("ch-1"), beside: .research("r1")),
        WindowSubject(open: .item("ch-1"), faces: .item("ch-1"), beside: .lessons),
    ]

    // MARK: - The keys (read out of the View menu)

    /// One View-menu item: its action's code and its key.
    private struct MenuKey: Equatable {
        let title: String
        let action: String
        let key: String
        let modifiers: String
    }

    /// Every `Button("…") { action }.keyboardShortcut("k", modifiers: m)` in
    /// `text`, with whitespace collapsed so wrapping never matters.
    private static func menuKeys(in text: String) -> [MenuKey] {
        let code = Self.flat(text)
        let pattern = #"Button\("([^"]*)"\)\s*\{\s*([^{}]*?)\s*\}\s*\.keyboardShortcut\("(.)",\s*modifiers:\s*(\[[^\]]*\]|\.[a-z]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = code as NSString
        return regex.matches(in: code, range: NSRange(location: 0, length: ns.length)).map {
            MenuKey(title: ns.substring(with: $0.range(at: 1)),
                    action: ns.substring(with: $0.range(at: 2))
                        .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " "),
                    key: ns.substring(with: $0.range(at: 3)),
                    modifiers: ns.substring(with: $0.range(at: 4)).replacingOccurrences(of: " ", with: ""))
        }
    }

    private static func action(for key: String, modifiers: String, in keys: [MenuKey]) -> [String] {
        keys.filter { $0.key == key && $0.modifiers == modifiers }.map(\.action)
    }

    private static let commandOption = "[.command,.option]"

    /// **Where each old pane's key lands** (owner, 2026-11-18).
    private static let paneKeyMap: [(key: String, action: String)] = [
        ("a", "MaughamEvent.postResolve(.rounds)"),
        ("d", "MaughamEvent.postResolve(.checks)"),
        ("t", "MaughamEvent.postResolve(.mine)"),
        ("i", "MaughamEvent.postBriefField(.line)"),
        ("n", "MaughamEvent.postBriefField(.goingFor)"),
        ("g", "MaughamEvent.postPullUp(.lessons)"),
        ("y", "MaughamEvent.postPullUp(.firstReader)"),
        ("v", "MaughamEvent.postPullUp(.visualLanguage)"),
        ("h", "MaughamEvent.postPullUp(.historyOfTheFaces)"),
        ("e", "MaughamEvent.postShowPieceFold()"),
        ("l", "MaughamEvent.postTranslationReviewPosition()"),
        ("k", "MaughamEvent.postDeskPosition()"),
    ]

    /// **Each item is titled for what its key does** (owner's ruling, Task 9
    /// fix 1), not for the pane the key used to open.
    private static let menuTitles: [(key: String, modifiers: String, title: String)] = [
        ("1", ".command", "To Resolve"),
        ("2", ".command", "Brief"),
        ("3", ".command", "Pulled Up"),
        ("a", commandOption, "To Resolve: Rounds"),
        ("d", commandOption, "To Resolve: Checks"),
        ("t", commandOption, "To Resolve: Mine"),
        ("i", commandOption, "Brief: the Line"),
        ("n", commandOption, "Brief: Going For"),
        ("g", commandOption, "Pull Up What I've Learned"),
        ("y", commandOption, "Pull Up First Reader"),
        ("v", commandOption, "Pull Up Visual Language"),
        ("h", commandOption, "Pull Up History"),
        ("e", commandOption, "Open the Piece's Fold"),
        ("l", commandOption, "To Resolve: Translation Review"),
        ("k", commandOption, "To Resolve: Department Desk"),
    ]

    /// What disagrees between a View menu and the map: a key bound to
    /// something else, bound twice, or not bound.
    private static func paneKeyProblems(in app: String) -> [String] {
        let keys = menuKeys(in: app)
        return paneKeyMap.compactMap { entry in
            let found = action(for: entry.key, modifiers: commandOption, in: keys)
            return found == [entry.action] ? nil : "⌘⌥\(entry.key.uppercased()) → \(found), expected \(entry.action)"
        }
    }

    func test_commandOneTwoThreeSelectThePositions() throws {
        let keys = Self.menuKeys(in: try SourceTree.read("Maugham/MaughamApp.swift"))
        XCTAssertGreaterThan(keys.count, 20, "premise: the View menu's items are being read")
        for position in RightColumnPosition.allCases {
            XCTAssertEqual(
                Self.action(for: String(position.keyEquivalent), modifiers: ".command", in: keys),
                ["MaughamEvent.postPosition(.\(position.rawValue))"],
                "⌘\(position.keyEquivalent) selects \(position)")
        }
        // The post's payload is what the window's receiver reads back.
        for position in RightColumnPosition.allCases {
            XCTAssertEqual(
                ProjectWindow.position(in: [MaughamEvent.positionKey: position.rawValue]), position)
        }
        XCTAssertNil(ProjectWindow.position(in: [MaughamEvent.positionKey: "inspector"]),
                     "a payload this build cannot read selects nothing")
        XCTAssertNil(ProjectWindow.position(in: nil))

        // The one selection act: the column is shown, on that position.
        var shown = false
        var position = RightColumnPosition.resolve
        ProjectWindow.selectPosition(
            .brief, showInspector: Binding(get: { shown }, set: { shown = $0 }),
            position: Binding(get: { position }, set: { position = $0 }))
        XCTAssertTrue(shown, "every key reveals a hidden column")
        XCTAssertEqual(position, .brief)
    }

    func test_eachOldPaneKeyLandsWhereTheMapSays() throws {
        let app = try SourceTree.read("Maugham/MaughamApp.swift")
        XCTAssertEqual(Self.paneKeyProblems(in: app), [])
        // No right-column key is left on the pane picker's old event.
        XCTAssertFalse(app.contains("postSegment("), "the pane picker's post is gone")

        // Each item says what its key does; no item is titled for a pane
        // that is gone.
        let keys = Self.menuKeys(in: app)
        for entry in Self.menuTitles {
            XCTAssertEqual(keys.filter { $0.key == entry.key && $0.modifiers == entry.modifiers }.map(\.title),
                           [entry.title], "the item on \(entry.modifiers) \(entry.key)")
        }
        for gone in ["Inspector", "Intent", "Annotations", "Diagnostics", "Tasks", "History",
                     "References", "Translation", "Department", "What I've Learned",
                     "First Reader", "Visual Language"] {
            XCTAssertFalse(keys.contains { $0.title == gone }, "an item is still titled “\(gone)”")
        }
        // ⌘⌥E is disabled, not inert, where the window has no piece.
        let flat = Self.flat(app)
        XCTAssertTrue(flat.contains(
            #"Button("Open the Piece's Fold") { MaughamEvent.postShowPieceFold() } .keyboardShortcut("e", modifiers: [.command, .option]) .disabled(offered != true)"#),
            "the fold item lost its enablement")
        XCTAssertTrue(flat.contains("@FocusedValue(\\.pieceFoldIsOffered) private var offered"))
        let observer = Self.flat(try SourceTree.sourceOfType("ResearchRevealModifier", under: ["Maugham"]))
        XCTAssertTrue(observer.contains(
            ".focusedSceneValue(\\.pieceFoldIsOffered, ProjectWindow.foldPiece( subject: subject ?? .book, "
            + "structure: store?.manifest.structure ?? []) != nil)"),
            "the window no longer says whether it has a piece whose fold can open: \(observer)")

        // The planted offender: ⌘⌥H bound to Brief.
        let planted = app.replacingOccurrences(
            of: #"Button("Pull Up History") { MaughamEvent.postPullUp(.historyOfTheFaces) }"#,
            with: #"Button("Pull Up History") { MaughamEvent.postPosition(.brief) }"#)
        XCTAssertNotEqual(planted, app, "premise: the History item is spelled as the plant expects")
        XCTAssertEqual(Self.paneKeyProblems(in: planted).count, 1,
                       "\(Self.paneKeyProblems(in: planted))")
    }

    /// Every position and every pull-up has a View-menu key (the pane
    /// picker's "every segment has a menu shortcut", re-made).
    func test_everyPositionAndPullUpHasAMenuShortcut() throws {
        let keys = Self.menuKeys(in: try SourceTree.read("Maugham/MaughamApp.swift"))
        for position in RightColumnPosition.allCases {
            XCTAssertTrue(keys.contains { $0.action == "MaughamEvent.postPosition(.\(position.rawValue))" },
                          "\(position) has no menu item")
        }
        for request in PullUpRequest.allCases {
            XCTAssertTrue(keys.contains { $0.action == "MaughamEvent.postPullUp(.\(request.rawValue))" },
                          "\(request) has no menu item")
            XCTAssertEqual(ProjectWindow.pullUpRequest(in: [MaughamEvent.pullUpKey: request.rawValue]),
                           request, "the receiver reads the post's own payload")
        }
        XCTAssertNil(ProjectWindow.pullUpRequest(in: [MaughamEvent.pullUpKey: "references"]))
    }

    // MARK: - The one order, and what each subject is offered

    /// The control's segments are `RightColumnPosition.allCases` in order,
    /// with the pulled-up one left out while it would show nothing — never a
    /// reorder — and To resolve leads under every subject.
    func test_theControlIsTheOneOrderUnderEverySubject() {
        XCTAssertEqual(RightColumnPosition.allCases, [.resolve, .brief, .pulledUp])
        for subject in Self.subjects {
            for selected in RightColumnPosition.allCases {
                let offers = RightColumnContent.offersPulledUp(
                    subject, structure: structure, projectType: .novel)
                let segments = RightColumnControl.segments(offersPulledUp: offers, selected: selected)
                XCTAssertEqual(segments, RightColumnPosition.allCases.filter(segments.contains),
                               "\(subject): the order is never anything but the one order")
                XCTAssertEqual(segments.first, .resolve)
                XCTAssertTrue(segments.contains(.brief), "Brief is always offered")
                XCTAssertTrue(segments.contains(selected),
                              "\(subject): the selected position is always drawn")
                XCTAssertEqual(segments.contains(.pulledUp), offers || selected == .pulledUp,
                               "\(subject): the pulled-up position is hidden while it would show nothing")
                XCTAssertEqual(Set(segments).count, segments.count, "no segment is drawn twice")
            }
        }
        // The planted offender: the same members with Brief and the pulled-up
        // position swapped — same first element. Only the order guard sees it.
        let reordered: [RightColumnPosition] = [.resolve, .pulledUp, .brief]
        XCTAssertNotEqual(reordered, RightColumnPosition.allCases.filter(reordered.contains),
                          "the guard accepted a permutation — it is asserting membership, not order")
        // Every position names itself, for VoiceOver and for its tooltip.
        for position in RightColumnPosition.allCases {
            XCTAssertFalse(RightColumnControl.name(of: position).isEmpty)
            XCTAssertTrue(position.helpText.hasPrefix(RightColumnControl.name(of: position))
                          || position == .pulledUp, "\(position): the tooltip leads with the name")
            XCTAssertTrue(position.helpText.contains("\u{2318}\(position.keyEquivalent)"),
                          "\(position): the tooltip carries its key")
        }
    }

    /// A requested position lands under every subject: whatever is asked for
    /// is what `RightColumnContent.of` answers about, and none of the three
    /// is coerced to another.
    func test_everyRequestedPositionLandsUnderEverySubject() {
        for subject in Self.subjects {
            for position in RightColumnPosition.allCases {
                let content = RightColumnContent.of(
                    position: position, subject: subject, translationLanguage: nil,
                    structure: structure, projectType: .novel)
                switch (position, content) {
                case (.resolve, .resolve), (.resolve, .translationReview),
                     (.brief, .brief),
                     (.pulledUp, .pulledUp), (.pulledUp, .centreDetails), (.pulledUp, .nothingPulledUp):
                    break
                default:
                    XCTFail("\(position) under \(subject) answered \(content)")
                }
            }
        }
    }

    /// Shell p4 Task 6 (re-made from the desk's answer): with an edition
    /// faced, To resolve is its own list like every other subject's — no
    /// subject answers anything else outside translation review.
    func test_everySubjectsToResolveIsTheList() {
        for subject in Self.subjects {
            let content = RightColumnContent.of(
                position: .resolve, subject: subject, translationLanguage: nil,
                structure: structure, projectType: .novel)
            XCTAssertEqual(content, .resolve, "\(subject)")
        }
    }

    // MARK: - The control: dots, title, fit

    func test_theUnreadDotLandsOnToResolve() async throws {
        for position in RightColumnPosition.allCases {
            XCTAssertEqual(
                RightColumnControl.showsDot(on: position, checksUnread: true, proposalPending: false),
                position == .resolve, "\(position)")
            XCTAssertFalse(
                RightColumnControl.showsDot(on: position, checksUnread: false, proposalPending: false))
        }
        // A dot, never a number.
        XCTAssertTrue(UnreadDot.shows(unreadChecks: 40))
        XCTAssertFalse(UnreadDot.shows(unreadChecks: 0))

        // The dot is about the doc id To resolve clears: the faces' piece at
        // a piece scope, else none — so it never stands where the list could
        // not clear it.
        let f = try await fixture("UnreadDot")
        let piece = WindowSubject(open: .item(f.documentItemId), faces: .item(f.documentItemId))
        XCTAssertEqual(RightColumnControl.unreadDocId(subject: piece, store: f.store),
                       f.documentItemId)
        XCTAssertNil(RightColumnControl.unreadDocId(subject: .book, store: f.store),
                     "the Book's list clears no one piece's checks")
        var facesOnly = WindowSubject(open: .canvas, faces: .canvas)
        facesOnly.faces = .item(f.documentItemId)
        XCTAssertEqual(RightColumnControl.unreadDocId(subject: facesOnly, store: f.store),
                       f.documentItemId, "the faces' piece, whether or not it is open")
        let scope = ResolveScope.of(piece.faces, readIn: nil, sourceLanguage: "en", structure: f.store.manifest.structure,
                                    projectType: f.store.manifest.type)
        XCTAssertEqual(RightColumnControl.unreadDocId(subject: piece, store: f.store),
                       ResolvePane.unreadDocId(scope: scope),
                       "the control's dot and the list's clear ask one function")

        // The wiring: the control reads the store's unread count for that id.
        let control = try SourceTree.sourceOfType("RightColumnControl", under: ["Maugham"])
        let flat = Self.flat(control)
        XCTAssertTrue(flat.contains("diagnostics.unreadCount(docId: unreadDocId)"), flat)
        XCTAssertTrue(flat.contains("unreadDocId = Self.unreadDocId(subject: new, store: store)"),
                      "resolved once per subject change, never per render")
    }

    func test_theProposalDotLandsOnBrief() throws {
        for position in RightColumnPosition.allCases {
            XCTAssertEqual(
                RightColumnControl.showsDot(on: position, checksUnread: false, proposalPending: true),
                position == .brief, "\(position)")
        }
        XCTAssertTrue(RightColumnControl.showsDot(on: .resolve, checksUnread: true, proposalPending: true),
                      "both dots can stand together")
        XCTAssertTrue(RightColumnControl.showsDot(on: .brief, checksUnread: true, proposalPending: true))
        // The wiring: the dot follows the proposal slot and its changed event.
        let source = try SourceTree.read("Maugham/Views/RightColumnControl.swift")
        let flat = Self.flat(source)
        for token in [".pending(for: .visualLanguage) != nil",
                      ".onProjectEvent(.maughamStatementProposalsChanged,",
                      "VisualLanguageProposalModifier( projectURL: store.url, window: window, proposed: $visualLanguageProposed)"] {
            XCTAssertTrue(flat.contains(token), "the proposal dot lost \(token)")
        }
    }

    /// **Review Focus 5**: a 200-character pulled-up title at 240, 280 and
    /// 480. The control takes the width it is offered (the title truncates in
    /// the middle); below the title's floor the segment is its icon alone.
    func test_theControlFitsAt240WithALongTitle() async throws {
        let f = try await fixture("ControlFit")
        let title = String(repeating: "A very long research note title ", count: 7).prefix(200)
        XCTAssertEqual(title.count, 200)
        let note = try await f.store.addResearchTextNote(parentId: nil, title: String(title))
        var subject = WindowSubject(open: .item(f.documentItemId), faces: .item(f.documentItemId))
        subject.beside = .research(note.id)
        XCTAssertEqual(RightColumnControl.pulledUpTitle(subject: subject, store: f.store), String(title))

        for column in [240.0, 280.0, 480.0] {
            let pane = CGFloat(column) - RightColumn.resizeHandleWidth
            for position in RightColumnPosition.allCases {
                let control = RightColumnControlFixture.control(
                    store: f.store, position: .constant(position), subject: subject,
                    width: pane, canvasModel: CanvasModel())
                let hosted = NSHostingController(rootView: control)
                _ = hosted.view
                let size = hosted.sizeThatFits(in: CGSize(width: pane, height: 400))
                XCTAssertLessThanOrEqual(size.width, pane + 0.5,
                                         "the control wants \(size.width)pt in a \(pane)pt pane")
                XCTAssertLessThan(size.height, 44, "one row, at \(column)pt")
            }
            XCTAssertTrue(RightColumnControl.showsTitle(String(title), paneWidth: pane),
                          "the title is drawn across the column's whole range (\(column)pt)")
        }
        // The planted offender: the same title, unbroken, does not fit.
        let overWide = NSHostingController(rootView: Text(String(title)).fixedSize())
        _ = overWide.view
        XCTAssertGreaterThan(overWide.sizeThatFits(in: CGSize(width: 232, height: 400)).width, 232,
                             "control: the instrument sees a title that does not truncate")

        // Below the floor, and with nothing pulled up, the icon alone.
        XCTAssertFalse(RightColumnControl.showsTitle(String(title),
                                                     paneWidth: RightColumnControl.titleFloor - 1))
        XCTAssertFalse(RightColumnControl.showsTitle(nil, paneWidth: 472))
        XCTAssertFalse(RightColumnControl.showsTitle("", paneWidth: 472))
        XCTAssertNil(RightColumnControl.pulledUpTitle(subject: .book, store: f.store))
        // The whole title is the segment's tooltip.
        XCTAssertTrue(RightColumnControl.help(for: .pulledUp, title: String(title)).hasPrefix(String(title)))
        XCTAssertEqual(RightColumnControl.help(for: .pulledUp, title: nil),
                       RightColumnPosition.pulledUp.helpText)
        XCTAssertEqual(RightColumnControl.help(for: .brief, title: String(title)),
                       RightColumnPosition.brief.helpText)
        let source = try SourceTree.read("Maugham/Views/RightColumnControl.swift")
        XCTAssertTrue(source.contains(".truncationMode(.middle)"), "the middle goes, not the end")
    }

    /// **To resolve and Brief are written out when there is room**
    /// (appraisal 3). Measured, never pressed (tripwire 33): at every pane
    /// width across the column's range and every shape of the row — the two
    /// segments alone; beside the pulled-up icon; beside its title — the
    /// control fits in one row with the names drawn whole where the rule says
    /// they are. The premise is read off the hosting view, never assumed.
    func test_theControlWritesItsNamesWhereTheyFit() async throws {
        let f = try await fixture("ControlNames")
        let title = String(repeating: "A long research note title ", count: 8)
        let note = try await f.store.addResearchTextNote(parentId: nil, title: title)
        let piece = WindowSubject(open: .item(f.documentItemId), faces: .item(f.documentItemId))
        var beside = piece
        beside.beside = .research(note.id)
        let canvas = WindowSubject(open: .canvas, faces: .canvas)   // details, no title

        let range = UIState.detailColumnWidthRange
        for column in [range.lowerBound, 280, 320, 360, 420, range.upperBound] {
            let pane = CGFloat(column) - RightColumn.resizeHandleWidth
            for subject in [piece, beside, canvas] {
                let offers = RightColumnContent.offersPulledUp(
                    subject, structure: f.store.manifest.structure, projectType: f.store.manifest.type)
                let segments = RightColumnControl.segments(offersPulledUp: offers, selected: .resolve)
                let titled = RightColumnControl.showsTitle(
                    RightColumnControl.pulledUpTitle(subject: subject, store: f.store), paneWidth: pane)
                    && segments.contains(.pulledUp)
                let names = RightColumnControl.showsNames(
                    paneWidth: pane, segmentCount: segments.count, pulledUpTitleDrawn: titled)
                let control = RightColumnControlFixture.control(
                    store: f.store, position: .constant(.resolve),
                    subject: subject, width: pane, canvasModel: CanvasModel())
                let hosted = NSHostingController(rootView: control)
                _ = hosted.view
                let size = hosted.sizeThatFits(in: CGSize(width: pane, height: 400))
                XCTAssertLessThanOrEqual(size.width, pane + 0.5,
                    "\(subject) at \(pane)pt (names \(names), title \(titled)) wants \(size.width)pt")
                XCTAssertLessThan(size.height, 44, "one row, at \(pane)pt")
            }
        }
        // Where the column is at its narrowest with nothing pulled up, the
        // names are written: the common case is never icons alone.
        XCTAssertTrue(RightColumnControl.showsNames(
            paneWidth: CGFloat(range.lowerBound) - RightColumn.resizeHandleWidth,
            segmentCount: 2, pulledUpTitleDrawn: false))
        // Beside a title, the title keeps the room below its floor.
        XCTAssertFalse(RightColumnControl.showsNames(
            paneWidth: RightColumnControl.namesFloorBesideTitle - 1, segmentCount: 3,
            pulledUpTitleDrawn: true))
        XCTAssertTrue(RightColumnControl.showsNames(
            paneWidth: RightColumnControl.namesFloorBesideTitle, segmentCount: 3,
            pulledUpTitleDrawn: true))
        XCTAssertFalse(RightColumnControl.showsNames(
            paneWidth: RightColumnControl.namesFloorBesideIcon - 1, segmentCount: 3,
            pulledUpTitleDrawn: false))
        XCTAssertTrue(RightColumnControl.namesFloorAlone < RightColumnControl.namesFloorBesideIcon
                      && RightColumnControl.namesFloorBesideIcon < RightColumnControl.namesFloorBesideTitle)
        // The control: unfixed, the same names in a pane too narrow for them
        // would be clipped rather than overflow, and the fit above would not
        // see it — the names are drawn whole or not at all.
        let source = try SourceTree.read("Maugham/Views/RightColumnControl.swift")
        XCTAssertTrue(source.contains("Text(Self.name(of: segment))\n                        .lineLimit(1)\n                        .fixedSize()"))
    }

    // MARK: - The window's verbs

    func test_theStripOpensTheOpenPiecesBrief() throws {
        // The strip's click, end to end: a piece open under faces that are
        // somewhere else — the Book, say — becomes that piece's Brief, with
        // the column shown.
        var subject = WindowSubject(open: .item("ch-1"), faces: .project, beside: .lessons)
        var shown = false
        var position = RightColumnPosition.resolve
        ProjectWindow.showBriefOfTheOpenPiece(
            subject: Binding(get: { subject }, set: { subject = $0 }),
            showInspector: Binding(get: { shown }, set: { shown = $0 }),
            position: Binding(get: { position }, set: { position = $0 }),
            structure: structure)
        XCTAssertEqual(subject.faces, .item("ch-1"), "the faces go to the open piece")
        XCTAssertEqual(subject.open, .item("ch-1"))
        XCTAssertEqual(subject.beside, .lessons, "what is pulled up stays")
        XCTAssertTrue(shown, "a hidden column is revealed")
        XCTAssertEqual(position, .brief)
        XCTAssertEqual(RightColumnContent.of(
            position: position, subject: subject, translationLanguage: nil,
            structure: structure, projectType: .novel), .brief(.piece(docId: "ch-1")))

        // The hand-off goes through the one selection act, after the faces.
        let hand = try SourceTree.declaration(named: "static func showBriefOfTheOpenPiece(",
                                              under: "Maugham")
        let flat = Self.flat(hand)
        let faces = try XCTUnwrap(flat.range(of: "RightColumnContent.facesForTheStrip("))
        let select = try XCTUnwrap(flat.range(of: "Self.selectPosition( .brief,"),
                                   "the strip's hand-off goes through the one selection act: \(flat)")
        XCTAssertLessThan(faces.lowerBound, select.lowerBound, "the faces move before Brief shows")

        // The post is a key-window command: only the focused window moves.
        var received: [Notification] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: capture-only observer inspecting the exact scoped Notification the strip posts
            forName: .maughamShowOpenPieceBrief, object: nil, queue: nil
        ) { received.append($0) }
        defer { NotificationCenter.default.removeObserver(token) }
        MaughamEvent.postBriefOfTheOpenPiece()
        XCTAssertEqual(received.count, 1)
        let note = try XCTUnwrap(received.first)
        XCTAssertTrue(MaughamEvent.shouldDeliver(note, to: EventReceiverContext(
            kind: .keyWindow, isWindowLive: true, isWindowKey: true)))
        XCTAssertFalse(MaughamEvent.shouldDeliver(note, to: EventReceiverContext(
            kind: .keyWindow, isWindowLive: true, isWindowKey: false)),
            "control: a non-key window must not act on it")
    }

    func test_aStatementMarkOpensBriefOrPullsUp() async throws {
        // The rule, over every kind and scope a statement can have.
        func destination(_ kind: Statement.Kind, _ scope: Statement.Scope) -> ProjectWindow.MarkDestination? {
            ProjectWindow.statementDestination(
                for: Statement(id: "s1", kind: kind, scope: scope, path: "statements/s1.md"))
        }
        XCTAssertEqual(destination(.intent, .document("ch-1")), .brief(.item("ch-1")),
                       "a piece's intent is that piece's Brief")
        XCTAssertEqual(destination(.intent, .project), .brief(.project),
                       "the Book's intent is the Book's Brief")
        XCTAssertNil(destination(.intent, .unknown("part:p1")), "a scope a newer build wrote")
        XCTAssertEqual(destination(.visualLanguage, .project), .pullUp(.visualLanguage))
        XCTAssertEqual(destination(.lessons, .project), .pullUp(.lessons))
        XCTAssertEqual(destination(.firstReader, .project), .pullUp(.firstReader))
        XCTAssertNil(destination(.editionBrief("es"), .project),
                     "an edition's brief is reached from its edition's row")
        XCTAssertNil(destination(.unknown("mood"), .project), "a kind a newer build wrote")

        // …and over a real project's manifest.
        let f = try await fixture("MarkDestination")
        let store = f.store
        let docId = f.documentItemId
        let note = try await store.addResearchTextNote(parentId: nil, title: "A note")
        let chapter = try await store.createStatement(kind: .intent, scope: .document(docId))
        XCTAssertEqual(ProjectWindow.statementDestination(forMark: chapter.id, in: store),
                       .brief(.item(docId)))
        XCTAssertNil(ProjectWindow.statementDestination(forMark: note.id, in: store),
                     "a research item is Research's")
        XCTAssertNil(ProjectWindow.statementDestination(forMark: "nope", in: store))

        // A Brief destination moves the faces and nothing else.
        let onTheCanvas = WindowSubject(open: .canvas, faces: .canvas, beside: .research("r1"))
        let faced = ProjectWindow.facesForABrief(.item(docId), subject: onTheCanvas)
        XCTAssertEqual(faced.open, .canvas, "`open` does not move")
        XCTAssertEqual(faced.faces, .item(docId))
        XCTAssertEqual(faced.beside, .research("r1"), "what is pulled up stays")
        XCTAssertEqual(ProjectWindow.facesForABrief(.canvas, subject: onTheCanvas), onTheCanvas,
                       "already faced: nothing is written")

        // The wiring.
        let open = try SourceTree.declaration(named: "func openPromotedArtifact(", under: "Maugham")
        let flat = Self.flat(open)
        for token in ["Self.statementDestination(forMark: itemId, in: store)",
                      "openBrief(faces)", "Self.pullUp(", "request, subject: subjectBinding",
                      "openResearchItem(itemId)"] {
            XCTAssertTrue(flat.contains(token), "Open on a mark lost \(token)")
        }
        let brief = try SourceTree.declaration(named: "func openBrief(_ target: BinderSubject)",
                                               under: "Maugham")
        let briefFlat = Self.flat(brief)
        for token in ["Self.facesForABrief(target, subject: subject)", "showInspector = true",
                      "rightColumnPosition = .brief"] {
            XCTAssertTrue(briefFlat.contains(token), "openBrief lost \(token)")
        }
    }

    /// ⌘⌥G/Y/V/H and the Describe… hand-off: the item goes beside, the
    /// column shows, on the pulled-up position — also when it was already
    /// pulled up, which no subject observer can see.
    func test_aPullUpKeyPullsTheItemUpAndShowsIt() {
        for request in PullUpRequest.allCases {
            var subject = Self.piece
            var shown = false
            var position = RightColumnPosition.brief
            let pull = {
                ProjectWindow.pullUp(
                    request,
                    subject: Binding(get: { subject }, set: { subject = $0 }),
                    showInspector: Binding(get: { shown }, set: { shown = $0 }),
                    position: Binding(get: { position }, set: { position = $0 }),
                    structure: self.structure, memory: nil)
            }
            pull()
            XCTAssertEqual(subject.beside, RightColumnContent.pulledUp(
                for: request, subject: Self.piece, structure: structure), "\(request)")
            XCTAssertNotNil(subject.beside)
            XCTAssertEqual(subject.open, Self.piece.open)
            XCTAssertEqual(subject.faces, Self.piece.faces)
            XCTAssertTrue(shown)
            XCTAssertEqual(position, .pulledUp)

            // Pressed again on what is already there, from another position.
            position = .resolve
            shown = false
            let before = subject
            pull()
            XCTAssertEqual(subject, before, "pulling up what is there never puts it away")
            XCTAssertEqual(position, .pulledUp)
            XCTAssertTrue(shown)
        }
        // History with no piece in the faces or the centre is the PROJECT's
        // (its checkpoints, as the old History pane showed on the Book).
        var subject = WindowSubject.book
        var shown = false
        var position = RightColumnPosition.brief
        ProjectWindow.pullUp(
            .historyOfTheFaces,
            subject: Binding(get: { subject }, set: { subject = $0 }),
            showInspector: Binding(get: { shown }, set: { shown = $0 }),
            position: Binding(get: { position }, set: { position = $0 }),
            structure: structure, memory: nil)
        XCTAssertEqual(subject.beside, .projectHistory)
        XCTAssertEqual(subject.open, .project)
        XCTAssertTrue(shown)
        XCTAssertEqual(position, .pulledUp)
        XCTAssertEqual(RightColumnContent.of(
            position: .pulledUp, subject: subject, translationLanguage: nil,
            structure: structure, projectType: .novel), .pulledUp(.projectHistory))
    }

    /// **Brief's pull-up links are the keys' own act** (review I1). With the
    /// item already pulled up the subject does not change, so no observer
    /// moves the position: a link that only wrote the subject left the writer
    /// on Brief with nothing happening.
    func test_aBriefLinkToWhatIsAlreadyPulledUpStillShowsIt() throws {
        for item in [PulledUp.visualLanguage, .lessons, .firstReader] {
            // ⌘⌥V, then ⌘2 to the Book's Brief, then the link.
            var subject = ClickRule.pullUp(item, current: .book)
            var shown = true
            var position = RightColumnPosition.brief
            let before = subject
            XCTAssertEqual(ClickRule.pullUp(item, current: subject), before,
                           "premise: the subject does not change, so no observer fires")
            XCTAssertEqual(RightColumnContent.positionAfterSubjectChange(
                position, from: before, to: before, previousFace: .brief,
                structure: structure, projectType: .novel), .brief,
                "premise: the subject's rule alone leaves the column on Brief")

            ProjectWindow.pullUp(
                item,
                subject: Binding(get: { subject }, set: { subject = $0 }),
                showInspector: Binding(get: { shown }, set: { shown = $0 }),
                position: Binding(get: { position }, set: { position = $0 }), memory: nil)
            XCTAssertEqual(position, .pulledUp, "\(item): the link shows what it names")
            XCTAssertEqual(subject, before)

            // A hidden column is shown too.
            shown = false
            position = .brief
            ProjectWindow.pullUp(
                item,
                subject: Binding(get: { subject }, set: { subject = $0 }),
                showInspector: Binding(get: { shown }, set: { shown = $0 }),
                position: Binding(get: { position }, set: { position = $0 }), memory: nil)
            XCTAssertTrue(shown)
            XCTAssertEqual(position, .pulledUp)
        }
        // The wiring: Brief is handed the window's verb, never a bare
        // subject write.
        let column = Self.flat(try SourceTree.sourceOfType("RightColumn", under: ["Maugham"]))
        XCTAssertTrue(column.contains("onPullUp: pullUp,"), column)
        XCTAssertFalse(column.contains("onPullUp: { subject = ClickRule.pullUp("),
                       "Brief's links write the subject and nothing else again")
        let window = Self.flat(try SourceTree.windowSource())
        XCTAssertTrue(window.contains("pullUp: { pullUpItem($0) },"))
        let hand = Self.flat(try SourceTree.declaration(named: "func pullUpItem(_ item: PulledUp)",
                                                        under: "Maugham"))
        XCTAssertTrue(hand.contains(
            "Self.pullUp(item, subject: subjectBinding, showInspector: $showInspector, position: $rightColumnPosition, memory: pulledUpMemory)"),
            hand)
    }

    // MARK: - A filter key on every ground (shell p4 Task 6; was review I3)

    /// ⌘⌥A/D/T hand their filter over wherever To resolve's list shows — an
    /// edition's included: the desk's interim loss ended. Only over the
    /// translation review (interim until Task 9; no list mounted to spend it)
    /// the key still selects the position and the filter is DROPPED, never
    /// left to fire the next time the list mounts. Over an edition a filter
    /// whose chip is absent selects nothing (`ResolveEditionTests
    /// .test_keyFiltersApplyWithAnEditionOnTheFaces`).
    func test_aFilterKeyIsHandedOverOnEveryGroundButTheReview() throws {
        for filter in [ResolveKeyFilter.rounds, .checks, .mine, .questions] {
            let userInfo: [AnyHashable: Any] = [
                MaughamEvent.positionKey: RightColumnPosition.resolve.rawValue,
                MaughamEvent.resolveFilterKey: filter.rawValue]
            XCTAssertEqual(ProjectWindow.position(in: userInfo), .resolve,
                           "the key selects the position in every state")
            XCTAssertEqual(ProjectWindow.positionAsk(in: userInfo, shows: .resolve).request,
                           .filter(filter), "over the list, the filter is handed over")
            XCTAssertNil(ProjectWindow.positionAsk(in: userInfo, shows: .translationReview).request,
                         "\(filter) over the review must not be left to fire later")
        }
        // The states, as the table answers them: an edition is the list.
        XCTAssertEqual(RightColumnContent.of(
            position: .resolve,
            subject: WindowSubject(open: .edition(language: "es"), faces: .edition(language: "es")),
            translationLanguage: nil, structure: structure, projectType: .novel),
            .resolve)
        XCTAssertEqual(RightColumnContent.of(
            position: .resolve, subject: Self.piece, translationLanguage: "es",
            structure: structure, projectType: .novel), .translationReview)
        // A plain position post asks for nothing.
        XCTAssertEqual(ProjectWindow.positionAsk(
            in: [MaughamEvent.positionKey: "resolve"], shows: .resolve),
            ProjectWindow.PositionAsk(request: nil, explains: nil))

        // The receiver sets the request only from the ask.
        let receiver = Self.flat(try SourceTree.declaration(
            named: "onKeyWindowCommand(.maughamSetRightColumn, window: window) { note in",
            under: "Maugham"))
        XCTAssertTrue(receiver.contains("if let request = ask.request { resolveRequest = request }"),
                      receiver)
        XCTAssertFalse(receiver.contains("resolveRequest = .filter("),
                       "the receiver sets a filter without asking what the position shows")
        XCTAssertTrue(receiver.contains("translationLanguage: translationLanguage,"))
    }

    /// **⌘⌥L outside translation review** (appraisal 5): To resolve shows,
    /// with one line saying how to get to what the key names — the old
    /// Translation pane's sentence — until the writer moves on. Over the
    /// review itself, no line. (⌘⌥K's desk line went with the desk, shell p4
    /// Task 6: ⌘⌥K is To resolve, an edition's own list where one is faced.)
    func test_theTranslationKeyExplainsHowToGetThere() throws {
        let userInfo: [AnyHashable: Any] = [
            MaughamEvent.positionKey: RightColumnPosition.resolve.rawValue,
            MaughamEvent.explainsKey: RightColumn.ResolveHint.translationReview.rawValue]
        XCTAssertEqual(ProjectWindow.position(in: userInfo), .resolve)
        XCTAssertEqual(ProjectWindow.positionAsk(in: userInfo, shows: .resolve).explains, .translationReview)
        XCTAssertNil(ProjectWindow.positionAsk(in: userInfo, shows: .translationReview).explains,
                     "in review the pane itself shows")
        XCTAssertNil(ProjectWindow.positionAsk(
            in: [MaughamEvent.positionKey: "resolve"], shows: .resolve).explains,
            "⌘1 explains nothing")
        XCTAssertNil(ProjectWindow.positionAsk(
            in: [MaughamEvent.positionKey: "resolve", MaughamEvent.explainsKey: "desk"],
            shows: .resolve).explains, "the desk's old hint, or any this build cannot read, says nothing")

        let ground = RightColumn.hintStandsOver(position: .resolve, subject: Self.piece,
                                                translationLanguage: nil)
        let asked = RightColumn.AskedHint(hint: .translationReview, ground: ground)
        XCTAssertEqual(RightColumn.shownHint(asked, ground: ground, shown: .resolve), .translationReview)
        XCTAssertNil(RightColumn.shownHint(nil, ground: ground, shown: .resolve))
        XCTAssertNil(RightColumn.shownHint(asked, ground: ground, shown: .translationReview))
        XCTAssertNil(RightColumn.shownHint(asked, ground: ground, shown: .brief(.book)))
        XCTAssertTrue(RightColumn.ResolveHint.translationReview.line.contains("Translation Review…"),
                      "the line names the menu item that enters review")

        // It stands over one position, one subject and "not in review": any
        // of the three changing clears it.
        XCTAssertNotEqual(ground, RightColumn.hintStandsOver(
            position: .brief, subject: Self.piece, translationLanguage: nil))
        XCTAssertNotEqual(ground, RightColumn.hintStandsOver(
            position: .resolve, subject: .book, translationLanguage: nil))
        XCTAssertNotEqual(ground, RightColumn.hintStandsOver(
            position: .resolve, subject: Self.piece, translationLanguage: "es"))

        // The posts, the receiver's write and the column's clear.
        var received: [Notification] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: capture-only observer inspecting the exact scoped Notification ⌘⌥L and ⌘⌥K post
            forName: .maughamSetRightColumn, object: nil, queue: nil
        ) { received.append($0) }
        defer { NotificationCenter.default.removeObserver(token) }
        MaughamEvent.postTranslationReviewPosition()
        MaughamEvent.postDeskPosition()
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.map { ProjectWindow.position(in: $0.userInfo) }, [.resolve, .resolve])
        XCTAssertEqual(received.map { ProjectWindow.positionAsk(in: $0.userInfo, shows: .resolve).explains },
                       [.translationReview, nil], "⌘⌥K asks for To resolve and explains nothing")
        let receiver = Self.flat(try SourceTree.declaration(
            named: "onKeyWindowCommand(.maughamSetRightColumn, window: window) { note in",
            under: "Maugham"))
        XCTAssertTrue(receiver.contains("resolveHint = ask.explains.map {"))
        XCTAssertTrue(receiver.contains("RightColumn.hintStandsOver(position: asked,"),
                      "the receiver records the ground it asked over")
        let column = Self.flat(try SourceTree.sourceOfType("RightColumn", under: ["Maugham"]))
        for token in ["if let hint = Self.shownHint(",
                      "Text(hint.line)",
                      "resolveHint = Self.hint(asked: resolveHint, groundNow: now)"] {
            XCTAssertTrue(column.contains(token), "the column lost \(token)")
        }
    }

    /// **⌘⌥I and ⌘⌥N put the keys in their field** (appraisal 5): each posts
    /// Brief with its field, and the receiver hands the field over only where
    /// the faces' Brief draws it — a piece has both, the Book only Going for,
    /// anything else neither — so no request stands over a Brief that cannot
    /// take it.
    func test_theBriefKeysAskForTheirField() throws {
        var received: [Notification] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: capture-only observer inspecting the exact scoped Notification ⌘⌥I and ⌘⌥N post
            forName: .maughamSetRightColumn, object: nil, queue: nil
        ) { received.append($0) }
        defer { NotificationCenter.default.removeObserver(token) }
        MaughamEvent.postBriefField(.line)
        MaughamEvent.postBriefField(.goingFor)
        XCTAssertEqual(received.map { ProjectWindow.position(in: $0.userInfo) }, [.brief, .brief])

        let piece = RightColumnContent.brief(.piece(docId: "ch-1"))
        let fields = received.map {
            ProjectWindow.positionAsk(in: $0.userInfo, shows: .resolve, briefShows: piece).briefField
        }
        XCTAssertEqual(fields, [.line, .goingFor])
        for (field, scope, offered) in [
            (BriefField.line, BriefScope.piece(docId: "ch-1"), true),
            (.goingFor, .piece(docId: "ch-1"), true),
            (.line, .book, false),
            (.goingFor, .book, true),
            (.line, .part(groupId: "part-1", docIds: ["ch-2"]), false),
            (.goingFor, .part(groupId: "part-1", docIds: ["ch-2"]), false),
            (.goingFor, .edition(language: "es"), false),
            (.goingFor, .outside, false),
        ] {
            XCTAssertEqual(field.isOffered(in: scope), offered, "\(field) in \(scope)")
            let info: [AnyHashable: Any] = [MaughamEvent.positionKey: "brief",
                                            MaughamEvent.briefFieldKey: field.rawValue]
            XCTAssertEqual(ProjectWindow.positionAsk(in: info, shows: .resolve,
                                                     briefShows: .brief(scope)).briefField,
                           offered ? field : nil, "\(field) over \(scope)")
        }
        XCTAssertNil(ProjectWindow.positionAsk(in: [MaughamEvent.positionKey: "brief"],
                                               shows: .resolve, briefShows: piece).briefField,
                     "⌘2 asks for no field")

        // The receiver hands the field to the window's request; the column
        // gives it to Brief; each field consumes it.
        let receiver = Self.flat(try SourceTree.declaration(
            named: "onKeyWindowCommand(.maughamSetRightColumn, window: window) { note in",
            under: "Maugham"))
        XCTAssertTrue(receiver.contains("if let field = ask.briefField { briefFocus = field }"), receiver)
        let column = Self.flat(try SourceTree.sourceOfType("RightColumn", under: ["Maugham"]))
        XCTAssertTrue(column.contains(".environment(\\.briefFocus, briefFocus)"))
        for type in ["BriefPieceView", "GoingForView"] {
            let source = Self.flat(try SourceTree.sourceOfType(type, under: ["Maugham"]))
            XCTAssertTrue(source.contains("focusRequest.wrappedValue = nil"),
                          "\(type) does not consume the request it takes")
        }

        // Going for takes the keys where the editor is up, or where Edit is
        // offered (the key presses it); never over the cover or an unread
        // intent.
        XCTAssertTrue(GoingForView.takesTheKeys(.editing, offersEdit: false))
        XCTAssertTrue(GoingForView.takesTheKeys(.reading, offersEdit: true))
        XCTAssertFalse(GoingForView.takesTheKeys(.reading, offersEdit: false))
        XCTAssertFalse(GoingForView.takesTheKeys(.inTheCentre, offersEdit: true))
        XCTAssertFalse(GoingForView.takesTheKeys(.unreadable, offersEdit: true))
    }

    /// **⌘⌥L's line survives the position change that shows it** (final
    /// wave; Task 9's re-review A). The receiver selects To resolve and sets
    /// the hint in one handler; the column's `onChange(of: hintStandsOver…)`
    /// then sees the position change. Modelled in that order through the
    /// column's own reducer: from Brief (the common path) the line shows, and
    /// the next move clears it for good.
    func test_theTranslationKeysLineSurvivesThePositionChangeThatShowsIt() {
        func ground(_ position: RightColumnPosition, _ subject: WindowSubject = Self.piece,
                    review: String? = nil) -> RightColumn.HintGround {
            RightColumn.hintStandsOver(position: position, subject: subject, translationLanguage: review)
        }
        func asked(_ position: RightColumnPosition, _ subject: WindowSubject = Self.piece)
            -> RightColumn.AskedHint {
            RightColumn.AskedHint(hint: .translationReview, ground: ground(position, subject))
        }
        var position: RightColumnPosition = .brief
        var hint: RightColumn.AskedHint? = nil
        var lastGround = ground(position)
        // The column's `onChange`: fires only when the ground changed.
        func columnObserves() {
            let now = ground(position)
            guard now != lastGround else { return }
            lastGround = now
            hint = RightColumn.hint(asked: hint, groundNow: now)
        }

        // ⌘⌥L on Brief: the receiver's two writes, then the column's update.
        position = .resolve
        hint = asked(.resolve)
        columnObserves()
        XCTAssertEqual(RightColumn.shownHint(hint, ground: ground(position), shown: .resolve),
                       .translationReview,
                       "the line shows after the position change that it came with")

        // The writer moves on: gone, and it does not come back on return.
        position = .brief
        columnObserves()
        XCTAssertNil(hint)
        position = .resolve
        columnObserves()
        XCTAssertNil(RightColumn.shownHint(hint, ground: ground(position), shown: .resolve))

        // A subject change, and entering review, clear it too.
        hint = asked(.resolve)
        lastGround = ground(.resolve)
        XCTAssertNil(RightColumn.hint(asked: hint, groundNow: ground(.resolve, .book)))
        XCTAssertNil(RightColumn.hint(asked: hint, groundNow: ground(.resolve, review: "es")))
    }

    /// ⌘⌥E opens the fold of the faces' piece, else the open one — History's
    /// rule — and nothing for a Part or the Book.
    func test_theFoldKeyNamesTheFacesPieceElseTheOpenOne() throws {
        XCTAssertEqual(ProjectWindow.foldPiece(subject: Self.piece, structure: structure), "ch-1")
        XCTAssertEqual(ProjectWindow.foldPiece(
            subject: WindowSubject(open: .item("ch-1"), faces: .project), structure: structure), "ch-1")
        XCTAssertEqual(ProjectWindow.foldPiece(
            subject: WindowSubject(open: .canvas, faces: .item("ch-2")), structure: structure), "ch-2")
        XCTAssertNil(ProjectWindow.foldPiece(subject: .book, structure: structure))
        XCTAssertNil(ProjectWindow.foldPiece(
            subject: WindowSubject(open: .item("part-1"), faces: .item("part-1")),
            structure: structure), "a Part has no fold of its own")

        // **The key reveals a hidden tree** (review I4): a collapsed sidebar
        // comes back; one that shows is left as it is.
        for visibility in [NavigationSplitViewVisibility.doubleColumn, .detailOnly, .all, .automatic] {
            XCTAssertEqual(ProjectWindow.revealingTheTree(visibility), .all, "\(visibility)")
        }

        let window = try SourceTree.windowSource()
        let flat = Self.flat(window)
        let receiver = try XCTUnwrap(flat.range(of: ".onKeyWindowCommand(.maughamShowPieceFold, window: window)"))
        let after = String(flat[receiver.upperBound...].prefix(520))
        for token in ["guard !treeFindActive", "Self.foldPiece(subject: subject",
                      "columnVisibility = Self.revealingTheTree(columnVisibility)",
                      "treeState.expandedPieceFolds.insert(id)", "treeState.scrollRequest = .row(.item(id))"] {
            XCTAssertTrue(after.contains(token), "⌘⌥E's receiver lost \(token): \(after)")
        }
    }

    // MARK: - A subject change, and a restore

    /// The observer's two decisions beside `positionAfterSubjectChange`
    /// (pinned in `RightColumnContentTests`): what reveals the column, and
    /// what `previousFace` remembers.
    func test_anArrivalRevealsTheColumnAndThePreviousFaceIsTheLastThatWasNotPulledUp() {
        let withNote = WindowSubject(open: .item("ch-1"), faces: .item("ch-1"), beside: .research("r1"))
        XCTAssertTrue(ResearchRevealModifier.reveals(from: Self.piece, to: withNote))
        XCTAssertTrue(ResearchRevealModifier.reveals(
            from: Self.piece,
            to: WindowSubject(open: .item("ch-1"), faces: .item("ch-1"), beside: .lessons)),
            "every pulled-up kind reveals")
        XCTAssertFalse(ResearchRevealModifier.reveals(from: nil, to: withNote),
                       "the restore is not an arrival")
        XCTAssertFalse(ResearchRevealModifier.reveals(from: withNote, to: Self.piece),
                       "putting it away is not an arrival")
        var moved = withNote
        moved.faces = .item("ch-2")
        XCTAssertFalse(ResearchRevealModifier.reveals(from: withNote, to: moved),
                       "the faces moving under what stays pulled up is not an arrival")
        XCTAssertFalse(ResearchRevealModifier.reveals(
            from: Self.piece, to: WindowSubject(open: .research("r1"), faces: .research("r1"))),
            "an item the centre opens reveals nothing")

        XCTAssertEqual(ResearchRevealModifier.previousFace(.resolve, after: .brief), .brief)
        XCTAssertEqual(ResearchRevealModifier.previousFace(.brief, after: .pulledUp), .brief,
                       "moving onto the pulled-up position keeps the face before it")
        XCTAssertEqual(ResearchRevealModifier.previousFace(.brief, after: .resolve), .resolve)
    }

    /// **A restored window opens on its remembered position** (controller
    /// ruling 4): `positionAfterSubjectChange` is not run over the restore.
    /// Its rule 1 WOULD move a restored Brief to the pulled-up position for a
    /// subject restored with something beside — which is why the observer
    /// must not see the restore.
    func test_theRestoreDoesNotMoveTheRememberedPosition() throws {
        let restored = WindowSubject(open: .item("ch-1"), faces: .item("ch-1"), beside: .research("r1"))
        XCTAssertEqual(RightColumnContent.positionAfterSubjectChange(
            .brief, from: .book, to: restored, previousFace: .brief,
            structure: structure, projectType: .novel), .pulledUp,
            "premise: run over the restore, the rule would eat the remembered position")

        // The observer's guard: no predecessor, no move.
        let observer = try SourceTree.sourceOfType("ResearchRevealModifier", under: ["Maugham"])
        let flat = Self.flat(observer)
        let change = try XCTUnwrap(flat.range(of: ".onChange(of: subject) { previous, next in"))
        let guardAt = try XCTUnwrap(flat.range(of: "guard let previous, let next else { return }"))
        let rule = try XCTUnwrap(flat.range(of: "RightColumnContent.positionAfterSubjectChange("))
        XCTAssertLessThan(change.lowerBound, guardAt.lowerBound)
        XCTAssertLessThan(guardAt.lowerBound, rule.lowerBound,
                          "the rule runs only for a change that has a predecessor")
        XCTAssertEqual(flat.components(separatedBy: "positionAfterSubjectChange(").count - 1, 1,
                       "one caller in the observer")

        // `load()` seeds the position verbatim, beside the subject whose
        // predecessor is nil, and before the stores are published.
        let window = Self.flat(try SourceTree.sourceOfType("ProjectWindow", under: ["Maugham"]))
        let loadStart = try XCTUnwrap(window.range(of: "private func load() async {"))
        let loadEnd = try XCTUnwrap(window.range(of: "loadError = error.localizedDescription",
                                                 range: loadStart.upperBound..<window.endIndex))
        let loadFlat = String(window[loadStart.lowerBound..<loadEnd.upperBound])
        let seedSubject = try XCTUnwrap(loadFlat.range(of: "self.subjectState = Self.validatedSubject("))
        let seedPosition = try XCTUnwrap(loadFlat.range(
            of: "self.rightColumnPosition = ds.uiState.rightColumnPosition"))
        let publish = try XCTUnwrap(loadFlat.range(of: "self.store = s"))
        XCTAssertLessThan(seedSubject.lowerBound, publish.lowerBound)
        XCTAssertLessThan(seedPosition.lowerBound, publish.lowerBound,
                          "seeded before any body pass can draw the default")
        XCTAssertFalse(loadFlat.contains("positionAfterSubjectChange"),
                       "the restore never runs the subject-change rule")
        XCTAssertEqual(ProjectWindow.previousFace(restoring: .brief), .brief)
        XCTAssertEqual(ProjectWindow.previousFace(restoring: .resolve), .resolve)
        XCTAssertEqual(ProjectWindow.previousFace(restoring: .pulledUp), .resolve)

        // The position has ONE persisting writer: the observer.
        let writers = try SourceTree.codeOccurrences(of: "$0.rightColumnPosition =", under: "Maugham")
        XCTAssertEqual(writers.values.reduce(0, +), 1, "\(writers)")
    }

    /// The forced entries' reveal: the column, on the pulled-up position —
    /// and nothing where the centre already shows the item.
    func test_revealingWhatIsPulledUpShowsItsPosition() {
        var shown = false
        var position = RightColumnPosition.brief
        ProjectWindow.revealPulledUp(
            subject: WindowSubject(open: .item("ch-1"), faces: .item("ch-1"), beside: .research("r1")),
            showInspector: &shown, position: &position)
        XCTAssertTrue(shown)
        XCTAssertEqual(position, .pulledUp)

        shown = false
        position = .brief
        ProjectWindow.revealPulledUp(
            subject: WindowSubject(open: .research("r1"), faces: .research("r1")),
            showInspector: &shown, position: &position)
        XCTAssertFalse(shown, "an item the centre shows moves nothing")
        XCTAssertEqual(position, .brief)
    }

    // MARK: - Escape

    func test_escapeClosesThePulledUpThing() throws {
        // The claim, over the product of its inputs.
        for pulled in [PulledUp?.none, .research("r1"), .lessons, .history(docId: "ch-1"),
                       .canvasScrap(nodeId: "n1")] {
            for position in RightColumnPosition.allCases {
                for shown in [true, false] {
                    for noChrome in [true, false] {
                        XCTAssertEqual(
                            PulledUpEscapeModifier.claims(pulledUp: pulled, position: position,
                                                          showInspector: shown, isNoChromeOn: noChrome),
                            pulled != nil && position == .pulledUp && shown && !noChrome,
                            "\(String(describing: pulled)) \(position) \(shown) \(noChrome)")
                    }
                }
            }
        }

        // The consumer: it closes while presented, and declines otherwise.
        let escape = PulledUpEscape()
        var subject = WindowSubject(open: .item("ch-1"), faces: .item("ch-1"), beside: .lessons)
        let close = { subject = ProjectWindow.closingBeside(subject) }
        escape.sync(isPresented: false, window: nil, close: close)
        XCTAssertFalse(escape.performEscape(), "nothing on screen: the key travels on")
        XCTAssertEqual(subject.beside, .lessons)
        escape.sync(isPresented: true, window: nil, close: close)
        XCTAssertFalse(escape.isInstalled, "no window, no registration")
        XCTAssertTrue(escape.performEscape())
        XCTAssertNil(subject.beside, "Esc put the pulled-up thing away")
        XCTAssertEqual(subject.open, .item("ch-1"), "and moved nothing else")

        // Through the window's arbiter, in its declared place. The count is
        // process-wide, and an earlier suite in this worker may still hold
        // live armed windows (the canvas-mounting family leaves eight, seen
        // in a full gate 2026-11-21): what this test arms, it must disarm.
        let armedBefore = WindowEscapeArbiter.armedWindowCount
        let window = TestWindow.make(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                                     present: .unshown)
        windows.append(window)
        subject.beside = .history(docId: "ch-1")
        escape.sync(isPresented: true, window: window, close: close)
        let arbiter = WindowEscapeArbiter.arbiter(for: window)
        XCTAssertTrue(arbiter.isRegistered(.pulledUp))
        XCTAssertTrue(escape.isInstalled)
        var dimLifted = false
        arbiter.register(.canvasDim) { dimLifted = true; return true }
        XCTAssertTrue(arbiter.offerEscape())
        XCTAssertNil(subject.beside, "the first Escape is the pulled-up thing's")
        XCTAssertFalse(dimLifted, "and the dim is left for the next")
        escape.sync(isPresented: false, window: window, close: close)
        XCTAssertFalse(arbiter.isRegistered(.pulledUp), "nothing on screen holds no claim")
        XCTAssertTrue(arbiter.offerEscape())
        XCTAssertTrue(dimLifted, "the next Escape lifts the dim")
        arbiter.resign(.canvasDim)
        XCTAssertFalse(arbiter.isArmed, "nothing is left watching")
        XCTAssertEqual(WindowEscapeArbiter.armedWindowCount, armedBefore, "nothing is left watching")

        // The mount: one line on the window's body.
        let source = try SourceTree.windowSource()
        XCTAssertTrue(Self.flat(source)
            .contains(".modifier(PulledUpEscapeModifier("), "Esc's mount line is gone")
    }

    /// **Escape on a dimmed canvas leaves a pulled-up thing that is not its
    /// own preview** (carried from Task 3's review, M1).
    func test_escapeOnTheCanvasPutsAwayOnlyItsOwnPreview() throws {
        // A research row clicked last is what dims the board: it goes.
        let previewing = WindowSubject(open: .canvas, faces: .canvas, beside: .research("r1"))
        XCTAssertEqual(previewing.lastClicked, .research("r1"), "premise: the note lights the board")
        let left = ProjectWindow.leavingTheCanvasDim(previewing)
        XCTAssertNil(left.beside)
        XCTAssertEqual(left.faces, .project)
        XCTAssertEqual(left.open, .canvas, "the canvas stays")
        XCTAssertEqual(left.lastClicked, .project, "nothing dims the board")

        // A piece clicked after the note dims the board; the note stays.
        var pieceLast = previewing
        pieceLast.faces = .item("ch-1")
        XCTAssertEqual(pieceLast.lastClicked, .item("ch-1"))
        let kept = ProjectWindow.leavingTheCanvasDim(pieceLast)
        XCTAssertEqual(kept.beside, .research("r1"), "pulled up before the faces moved: not the dim's")
        XCTAssertEqual(kept.faces, .project)
        XCTAssertEqual(kept.lastClicked, .project, "and it no longer lights the board")

        // A statement, History and a canvas card are never the canvas's
        // preview, whichever was written last.
        for pulled in [PulledUp.lessons, .firstReader, .visualLanguage, .history(docId: "ch-1"),
                       .canvasScrap(nodeId: "n1"), .canvasPhoto(path: "canvas_assets/a.png")] {
            var subject = WindowSubject(open: .canvas, faces: .item("ch-1"))
            subject.beside = pulled
            let after = ProjectWindow.leavingTheCanvasDim(subject)
            XCTAssertEqual(after.beside, pulled, "\(pulled) stays pulled up")
            XCTAssertEqual(after.faces, .project)
            XCTAssertEqual(after.lastClicked, .project)
        }
        // A figure clicked last is a tree row like a note.
        XCTAssertNil(ProjectWindow.leavingTheCanvasDim(
            WindowSubject(open: .canvas, faces: .canvas, beside: .figure("f1"))).beside)

        // The wiring: the canvas's Escape is that rule and writes no `beside`.
        let centre = try SourceTree.sourceOfType("CentreColumn", under: ["Maugham"])
        let flat = Self.flat(centre)
        XCTAssertTrue(flat.contains(
            "selectTheProjectRow: { subject = ProjectWindow.leavingTheCanvasDim(subject) }"), flat)
        XCTAssertFalse(flat.contains("subject.beside = nil"),
                       "the centre column never puts the pulled-up thing away on its own")
    }

    /// **A double-click on a tree row closes the centre item's cover, every
    /// row kind** (controller ruling 4): `open` moving clears it
    /// (`centreItemAfterOpenChange`), and where `open` does not move the
    /// receiver's own rule does (`closesTheCentreItem`).
    func test_aDoubleClickOnAnyRowKindClosesTheCentreItemsCover() {
        let rows: [BinderSubject] = [
            .project, .item("ch-1"), .item("part-1"), .item("ch-2"), .research("r1"),
            .figure("f1"), .inbox, .canvas, .palette, .edition(language: "es"),
        ]
        let covers: [(CentreItem, WindowSubject)] = [
            (.statement(kind: .intent, scope: .document("ch-1")), Self.piece),
            (.history(docId: "ch-1"), Self.piece),
            (.statement(kind: .lessons, scope: .project), .book),
            (.statement(kind: .intent, scope: .project), .book),
        ]
        for (item, standing) in covers {
            XCTAssertEqual(ProjectWindow.openingInCentre(item, subject: standing).open, standing.open,
                           "premise: the cover stands over its own place")
            for row in rows {
                let next = TreeTravel.openInCentre(row, current: standing,
                                                   structure: structure, projectType: .novel)
                let byTheReceiver = TreeTravelModifier.closesTheCentreItem(
                    row, clickCount: 2, current: standing)
                let byTheOpenChange = ProjectWindow.centreItemAfterOpenChange(
                    item, from: standing.open, to: next.open) == nil
                XCTAssertTrue(byTheReceiver || byTheOpenChange,
                              "a double-click on \(row) left \(item) covering the centre")
                XCTAssertEqual(byTheReceiver, next.open == standing.open,
                               "\(row): the receiver closes exactly where `open` does not move")
            }
        }
        XCTAssertFalse(TreeTravelModifier.closesTheCentreItem(.item("ch-1"), clickCount: 1,
                                                              current: Self.piece),
                       "a single click is not Open in Centre")
    }

    // MARK: - Brief mints nothing; the pulled-up view renders through what ships

    /// **Showing a Brief creates nothing** (the old inspectors' Open Intent
    /// row had this pin: absence is valid, and the intent's empty editor is
    /// what mints, on the first keystroke). Brief for the Book, for a chapter
    /// and for a Collection's loose piece each draw Going for over an intent
    /// that does not exist — and leave it not existing.
    func test_showingABriefMintsNoStatement() async throws {
        try requireAssistiveClient()
        let f = try await fixture("BriefMintsNothing")
        let probe = RightColumnFixture.Probe(position: .brief, subject: .book)
        let window = TestWindow.mount(
            RightColumnFixture.pane(store: f.store, documentStore: f.documentStore, probe: probe)
                .environment(f.preferences),
            size: CGSize(width: 320, height: 700))
        windows.append(window)
        for subject in [WindowSubject.book,
                        WindowSubject(open: .item(f.documentItemId), faces: .item(f.documentItemId)),
                        WindowSubject(open: .canvas, faces: .item(f.documentItemId))] {
            probe.subject = subject
            let drawn = await pumpUntil(deadline: 5) {
                (try? self.everythingRead(in: window).contains(GoingForView.heading)) ?? false
            }
            XCTAssertTrue(drawn, "\(subject): Brief draws Going for")
            await waitOut(0.3)   // an absence: nothing may have been minted
            XCTAssertTrue(f.store.manifest.statements.isEmpty,
                          "\(subject): showing Brief minted a statement. Absence is valid "
                          + "and the empty editor is what mints, on the first keystroke")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: f.projectURL.appendingPathComponent("research/craft-intent.md").path),
            "the old seam's research note was created")

        // The scope Brief shows is the faces': a chapter's own, the Book's
        // for the project, and a Collection's loose piece's own (never the
        // project's while the piece is what the writer is looking at).
        let structure = [StructureItem(id: "p1", title: "Story A", type: .document,
                                       path: "pieces/a.md", pieceKind: .loose)]
        XCTAssertEqual(BriefScope.of(.item("p1"), structure: structure, projectType: .collection),
                       .piece(docId: "p1"))
        XCTAssertEqual(BriefScope.of(.project, structure: structure, projectType: .collection), .book)
    }

    /// **The format caption** (owner's ruling: the old piece inspector's
    /// "Prose" / "Screenplay" label): a Collection's loose piece says what it
    /// is written as at the head of its Brief; every other piece says nothing.
    func test_aCollectionsLoosePieceSaysWhatItIsWrittenAsAtTheHeadOfItsBrief() throws {
        func piece(_ path: String?, _ kind: PieceKind?) -> [StructureItem] {
            [StructureItem(id: "p1", title: "Piece", type: .document, path: path, pieceKind: kind)]
        }
        XCTAssertEqual(BriefPane.formatCaption(docId: "p1", structure: piece("pieces/a.md", .loose),
                                               projectType: .collection), "Prose")
        XCTAssertEqual(BriefPane.formatCaption(docId: "p1", structure: piece("pieces/a.fountain", .loose),
                                               projectType: .collection), "Screenplay")
        XCTAssertEqual(BriefPane.formatCaption(docId: "p1", structure: piece("pieces/A.FOUNTAIN", .loose),
                                               projectType: .collection), "Screenplay",
                       "the extension is compared case-insensitively, as the op log parses it")
        XCTAssertEqual(BriefPane.formatCaption(docId: "p1", structure: piece(nil, .loose),
                                               projectType: .collection), "Prose",
                       "a path-less piece is prose")
        XCTAssertEqual(BriefPane.formatCaption(docId: "p1", structure: piece("pieces/a.md", nil),
                                               projectType: .collection), "Prose",
                       "a piece with no kind recorded is a loose piece")
        XCTAssertNil(BriefPane.formatCaption(docId: "p1", structure: piece("pieces/a.md", .reference),
                                             projectType: .collection),
                     "a reference piece's Brief is its own project's")
        XCTAssertNil(BriefPane.formatCaption(docId: "gone", structure: piece("pieces/a.md", .loose),
                                             projectType: .collection))
        for type in ProjectType.allCases where !type.holdsPieces {
            XCTAssertNil(BriefPane.formatCaption(docId: "p1", structure: piece("ch/a.md", nil),
                                                 projectType: type),
                         "\(type): every piece is the project's own kind; a caption would be noise")
        }
        // The wiring: Brief hands the piece's view the caption, which draws it first.
        let pane = try SourceTree.sourceOfType("BriefPane", under: ["Maugham"])
        XCTAssertTrue(Self.flat(pane)
            .contains("formatCaption: Self.formatCaption("), "Brief no longer passes the caption")
        let view = try SourceTree.sourceOfType("BriefPieceView", under: ["Maugham"])
        let flat = Self.flat(view)
        let caption = try XCTUnwrap(flat.range(of: "if let formatCaption {"))
        let line = try XCTUnwrap(flat.range(of: "line(offers)"))
        XCTAssertLessThan(caption.lowerBound, line.lowerBound, "the caption is at the head")
    }

    /// **The pulled-up view carries no renderer of its own** (the study
    /// column's census, on the view that took its place). A markdown renderer
    /// here would compile, look right, and disagree with the research preview
    /// the first time a writer used a table or a fence — the drift
    /// `MarkdownBlockParser` was extracted to end. Every arm hands off to a
    /// surface that already ships.
    func test_thePulledUpViewCarriesNoRendererOfItsOwn() throws {
        let source = try SourceTree.read("Maugham/Views/PulledUpView.swift")
        let code = SourceScan.codeLines(of: source).joined(separator: "\n")
        for banned in ["MarkdownBlockParser", "AttributedString(markdown:"] {
            XCTAssertFalse(code.contains(banned),
                           "PulledUpView.swift parses markdown itself (`\(banned)`). Hand off "
                           + "to a surface that ships — a second renderer is the defect "
                           + "MarkdownBlockParser exists to prevent.")
        }
        // The control: the census is reading the real file, and the hand-offs
        // are there.
        XCTAssertTrue(source.contains("struct PulledUpView"))
        for handOff in ["ResearchSubjectInspector(", "FigureSubjectSurface(", "FigureInspector(",
                        "ImagePreview(", "StatementPane(", "HistoryPane(", "ReferencePieceInspector("] {
            XCTAssertTrue(code.contains(handOff), "the pulled-up view no longer hands off to \(handOff)")
        }
    }

    // MARK: - The deleted types

    /// The types and verbs the picker died with, as tokens: each must be
    /// gone from `Maugham/` — code, comments and area guides alike — and
    /// never the START of a longer name (`ReferencePieceInspector` is not
    /// `PieceInspector`).
    private static let deleted = [
        "DetailSegment", "DetailPaneToggle", "InspectorView", "PieceInspector",
        "IntentAffordanceRow", "AssistantColumn", "ReferencesPane",
        "postDetailSegment", "selectDetailSegment",
    ]

    private static func survivors(of names: [String], in files: [(path: String, text: String)]) -> [String] {
        var found: [String] = []
        for name in names {
            guard let regex = try? NSRegularExpression(
                pattern: "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: name)) else { continue }
            for file in files {
                let ns = file.text as NSString
                if regex.firstMatch(in: file.text, range: NSRange(location: 0, length: ns.length)) != nil {
                    found.append("\(name) in \(file.path)")
                }
            }
        }
        return found
    }

    private static func everyFileUnderMaugham() throws -> [(path: String, text: String)] {
        let root = SourceTree.repoRoot.appendingPathComponent("Maugham")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [(path: String, text: String)] = []
        for case let url as URL in walker where ["swift", "md"].contains(url.pathExtension) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            files.append((url.path.replacingOccurrences(of: root.path + "/", with: ""), text))
        }
        return files
    }

    func test_noDeletedTypeSurvives() throws {
        let files = try Self.everyFileUnderMaugham()
        XCTAssertGreaterThan(files.count, 400, "premise: the tree is being read")
        XCTAssertEqual(Self.survivors(of: Self.deleted, in: files), [])
        for gone in ["Models/DetailSegment.swift", "Views/DetailPaneToggle.swift", "Views/InspectorView.swift",
                     "Views/PieceInspector.swift", "Views/IntentAffordanceRow.swift",
                     "Views/InspectorLinksSection.swift", "Views/AssistantColumn.swift",
                     "Views/ReferencesPane.swift"] {
            XCTAssertFalse(files.contains { $0.path == gone }, "\(gone) is still in the tree")
        }
        // The phone and the shared core name none of them either (tripwire 19).
        for root in ["MaughamPhone", "Packages/MaughamCore/Sources"] {
            let shared = try SourceTree.sources(under: root)
            XCTAssertFalse(shared.isEmpty, "premise: \(root) is being read")
            XCTAssertEqual(Self.survivors(of: Self.deleted, in: shared), [], root)
        }

        // The planted control: a use, a mention in a comment, and a longer
        // name that merely contains one.
        let planted: [(path: String, text: String)] = [
            ("Planted.swift", "let pane = DetailPaneToggle(store: store)"),
            ("Comment.swift", "/// as `InspectorView` used to"),
            ("Innocent.swift", "ReferencePieceInspector(store: store, pieceId: id) // detailSegment"),
        ]
        XCTAssertEqual(Self.survivors(of: Self.deleted, in: planted),
                       ["DetailPaneToggle in Planted.swift", "InspectorView in Comment.swift"])
    }

    // MARK: - Mounted: each arm draws what the table says

    /// One probe per arm of `RightColumnContent`: the real `RightColumn`,
    /// mounted on a position and a subject, read through the accessibility
    /// tree. Nothing is pressed (tripwire 33).
    func test_theRightColumnShowsWhatTheContentTableSays() async throws {
        try requireAssistiveClient()
        let f = try await fixture("ContentTable")
        let docId = f.documentItemId
        let note = try await f.store.addResearchTextNote(parentId: nil, title: "Tide tables")
        let piece = WindowSubject(open: .item(docId), faces: .item(docId))
        var withNote = piece
        withNote.beside = .research(note.id)
        let onTheCanvas = WindowSubject(open: .canvas, faces: .canvas)
        let onAnEdition = WindowSubject(open: .edition(language: "es"), faces: .edition(language: "es"))

        struct Arm {
            let name: String
            let position: RightColumnPosition
            let subject: WindowSubject
            let expected: RightColumnContent
            /// A string only this arm draws.
            let reads: String
        }
        let arms: [Arm] = [
            Arm(name: "To resolve", position: .resolve, subject: piece, expected: .resolve,
                reads: "New To-do"),
            // Shell p4 Task 6: an edition's own To resolve, its empty line.
            Arm(name: "an edition's To resolve", position: .resolve, subject: onAnEdition,
                expected: .resolve,
                reads: ResolveEditionItems.clearLine(language: "es", isSource: false, hasRounds: false)),
            Arm(name: "Brief", position: .brief, subject: piece,
                expected: .brief(.piece(docId: docId)), reads: GoingForView.heading),
            Arm(name: "Brief, outside", position: .brief, subject: onTheCanvas,
                expected: .brief(.outside), reads: BriefPane.outsideLine),
            Arm(name: "pulled up", position: .pulledUp, subject: withNote,
                expected: .pulledUp(.research(note.id)), reads: "Tide tables"),
            Arm(name: "the canvas's details", position: .pulledUp, subject: onTheCanvas,
                expected: .centreDetails(.canvas), reads: "Select something on the canvas"),
            Arm(name: "nothing pulled up", position: .pulledUp, subject: piece,
                expected: .nothingPulledUp, reads: PulledUpView.nothingPulledUpTitle),
        ]
        let everyProbe = Set(arms.map(\.reads))
        XCTAssertEqual(everyProbe.count, arms.count, "each arm is read by a string of its own")

        let probe = RightColumnFixture.Probe()
        let window = TestWindow.mount(
            RightColumnFixture.pane(store: f.store, documentStore: f.documentStore, probe: probe)
                .environment(f.preferences),
            size: CGSize(width: 320, height: 700))
        windows.append(window)

        for arm in arms {
            XCTAssertEqual(RightColumnContent.of(
                position: arm.position, subject: arm.subject, translationLanguage: nil,
                structure: f.store.manifest.structure, projectType: f.store.manifest.type),
                arm.expected, "premise: the table's answer for \(arm.name)")
            probe.subject = arm.subject
            probe.position = arm.position
            let found = await pumpUntil(deadline: 5) {
                (try? self.everythingRead(in: window).contains(arm.reads)) ?? false
            }
            let read = try everythingRead(in: window)
            XCTAssertTrue(found, "\(arm.name) did not draw \"\(arm.reads)\"; the column reads \(read)")
            for other in everyProbe.subtracting([arm.reads]) {
                XCTAssertFalse(read.contains(other),
                               "\(arm.name) also draws another arm's \"\(other)\"")
            }
            // The control is over every arm.
            let identifiers = try axIdentifiers(in: window)
            XCTAssertTrue(identifiers.contains("right-column-resolve"), "\(arm.name): \(identifiers)")
            XCTAssertTrue(identifiers.contains("right-column-brief"), arm.name)
            XCTAssertEqual(identifiers.contains("right-column-pulledUp"),
                           arm.position == .pulledUp
                            || RightColumnContent.offersPulledUp(
                                arm.subject, structure: f.store.manifest.structure,
                                projectType: f.store.manifest.type),
                           "\(arm.name): the pulled-up segment is hidden while it would show nothing")
        }
    }

    /// The translation review is To resolve's answer while review is on over
    /// the open piece, and To resolve itself until the piece's document is
    /// there to review.
    func test_translationReviewTakesToResolveWhileItIsOn() async throws {
        try requireAssistiveClient()
        let f = try await fixture("ReviewArm")
        let docId = f.documentItemId
        let piece = WindowSubject(open: .item(docId), faces: .item(docId))
        let control = EditorControl()
        control.translationLanguage = "es"
        XCTAssertEqual(RightColumnContent.of(
            position: .resolve, subject: piece, translationLanguage: "es",
            structure: f.store.manifest.structure, projectType: f.store.manifest.type),
            .translationReview)

        let probe = RightColumnFixture.Probe(position: .resolve, subject: piece)
        let window = TestWindow.mount(
            RightColumnFixture.pane(store: f.store, documentStore: f.documentStore, probe: probe,
                                    editorControl: control)
                .environment(f.preferences),
            size: CGSize(width: 320, height: 700))
        windows.append(window)
        // No `Document` is registered for the piece: To resolve stands in.
        XCTAssertNil(f.documentStore.document(forDocId: docId), "premise")
        let resolve = await pumpUntil(deadline: 5) {
            (try? self.everythingRead(in: window).contains("New To-do")) ?? false
        }
        let read = try everythingRead(in: window)
        XCTAssertTrue(resolve, "with nothing to review yet, To resolve shows: \(read)")

        // Entering review selects To resolve from wherever the column was.
        let source = try SourceTree.sourceOfType("RightColumn", under: ["Maugham"])
        let flat = Self.flat(source)
        XCTAssertTrue(flat.contains(
            ".onChange(of: editorControl.translationLanguage) { _, lang in if lang != nil { position = .resolve } }"),
            flat)
    }

    /// Everything the mounted column says: its texts, button labels and
    /// tooltips.
    private func everythingRead(in window: NSWindow) throws -> Set<String> {
        var read = Set(try axTexts(in: window))
        read.formUnion(try axButtonLabels(in: window))
        for element in try axElements(in: window) {
            for attribute in ["accessibilityHelp", "accessibilityLabel", "accessibilityTitle",
                              "accessibilityValue"] {
                if let value = axAttribute(element, attribute) as? String, !value.isEmpty {
                    read.insert(value)
                }
            }
        }
        return read
    }
}
