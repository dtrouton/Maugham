import XCTest
import AppKit
import SwiftUI
import Observation
import MaughamCore
@testable import Maugham

/// What a hand-over probe shows in the centre: nothing, or one item.
@Observable
@MainActor
final class CentreItemProbe {
    var centreItem: CentreItem?
    /// Stands for a publish cover or the Book's view over the editor.
    var coveredByAnotherSurface = false
    init() {}
}

/// `manuscriptEditor`'s stack in small: the host underneath, the cover over
/// it, and `CentreKeys` behind both, with the production views. (The real
/// stack's shape is censused in `test_whatCoversTheEditor…`.)
@MainActor
private struct EditorUnderTheCover: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    let docId: String
    let probe: CentreItemProbe
    @State private var control = EditorControl()
    @State private var referenceIndex = ReferenceIndexHost()
    @State private var window: NSWindow?

    var body: some View {
        ZStack {
            EditorHost(store: store, documentStore: documentStore,
                       selectedItemId: docId, control: control, referenceIndex: referenceIndex)
            if probe.coveredByAnotherSurface {
                Color(nsColor: .windowBackgroundColor)
            }
            if let item = probe.centreItem {
                CentreItemCover(store: store, documentStore: documentStore, item: item,
                                bible: nil, world: nil, window: window, findIsUp: false,
                                onClose: { probe.centreItem = nil })
            }
        }
        .background(WindowAccessor(window: $window))
        .background(CentreKeys(
            isCovered: { probe.centreItem != nil || probe.coveredByAnotherSurface },
            claim: CentreItemCover.claim(for: probe.centreItem.map(CentreCover.centreItem))))
    }
}

/// The tree beside the centre, in small: an outline view that takes the keys
/// when clicked, as the binder's does.
private struct TreeStandIn: NSViewRepresentable {
    /// An empty outline view declines the keys; the binder's, with rows, takes them.
    final class Outline: NSOutlineView {
        override var acceptsFirstResponder: Bool { true }
    }
    func makeNSView(context: Context) -> Outline { Outline() }
    func updateNSView(_ view: Outline, context: Context) {}
}

/// Brief in the right column beside the centre's cover, as the window lays
/// them out — the cover only while the probe holds an item.
@MainActor
private struct BriefBesideTheCentre: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    let docId: String
    let probe: CentreItemProbe

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.clear
                if let item = probe.centreItem {
                    CentreItemCover(store: store, documentStore: documentStore, item: item,
                                    bible: nil, world: nil, window: nil, findIsUp: false,
                                    onClose: { probe.centreItem = nil })
                }
            }
            .frame(width: 500)
            BriefPane(store: store, documentStore: documentStore, scope: .piece(docId: docId),
                      diagnostics: nil, bible: nil, world: nil, centreItem: probe.centreItem,
                      onOpenInCentre: { _ in }, onPullUp: { _ in },
                      onShowStrain: { _ in }, onOpenBrief: { _ in })
                .frame(width: 320)
        }
    }
}

/// **A statement or History in the centre** (shell plan 3 Task 5): the
/// `.centreItem` cover over the editor, what clears it, the one host per
/// statement across the hand-over, and the marks that never reach it. Pure
/// values, censuses and mounted measurements (nothing is pressed).
@MainActor
final class CentreItemCoverTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var fixtures: [StatementMountFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures { await fixture.closeAndTearDown() }
        fixtures.removeAll()
        try await super.tearDown()
    }

    private func fixture(_ name: String) async throws -> StatementMountFixture {
        let made = try await StatementMountFixture.novel(named: name)
        fixtures.append(made)
        return made
    }

    private let structure: [StructureItem] = [
        StructureItem(id: "ch-1", title: "One", type: .document, path: "one.md"),
    ]

    // MARK: - The cover, over the editor

    /// The item is a cover inside `.editor` — the same branch as without it
    /// — so `EditorHost` (the stack's first child) and the Book's view keep
    /// their mounts when it comes and goes; the canvas is a branch of its own
    /// that the cover never touches.
    func test_aStatementInTheCentreIsACoverOverTheEditor() throws {
        let intent = CentreItem.statement(kind: .intent, scope: .document("ch-1"))
        for subject in [WindowSubject(open: .item("ch-1"), faces: .item("ch-1")), .book] {
            for item in [intent, .statement(kind: .lessons, scope: .project), .history(docId: "ch-1")] {
                let without = route(subject, centreItem: nil)
                guard case .editor(let altitude, nil) = without else {
                    return XCTFail("premise: \(subject) is the bare editor, got \(without)")
                }
                XCTAssertEqual(route(subject, centreItem: item),
                               .editor(altitude: altitude, cover: .centreItem(item)),
                               "a cover of the same branch, the Book's view kept beneath")
            }
        }
        // The canvas keeps its own branch; an item never draws over it.
        let canvas = WindowSubject(open: .canvas, faces: .item("ch-1"))
        XCTAssertEqual(route(canvas, centreItem: intent), .canvas)

        XCTAssertEqual(CentreRouteSource.stackFaults(in: try CentreRouteSource.editorArm()), [])
        let cover = try XCTUnwrap(CentreRouteSource.switchArms(
            in: try CentreRouteSource.editorArm(), over: "switch cover"))
        XCTAssertTrue(cover.arm("centreItem").contains("CentreItemCover("),
                      "the item is drawn in the cover switch's own arm")
        let pane = SourceScan.codeLines(of: try CentreRouteSource.pane()).joined(separator: "\n")
        XCTAssertTrue(pane.contains("centreItem: centreItem"), "the column asks the route with the window's item")
        XCTAssertTrue(try CentreRouteSource.windowArgument("centreItem")?.contains("$centreItem") == true,
                      "the window hands the column its one centre item")
    }

    func test_closingTheCoverOrMovingTheCentreClearsIt() throws {
        let intent = CentreItem.statement(kind: .intent, scope: .document("ch-1"))
        // Any move of `open` clears it…
        for moved in [BinderSubject.project, .canvas, .item("ch-2"), .edition(language: "es")] {
            XCTAssertNil(ProjectWindow.centreItemAfterOpenChange(intent, from: .item("ch-1"), to: moved),
                         "\(moved)")
        }
        XCTAssertEqual(ProjectWindow.centreItemAfterOpenChange(intent, from: .item("ch-1"), to: .item("ch-1")),
                       intent)
        // …except the move that opened it: `openInCentre` writes the subject
        // and the item in one update, and the window's `.onChange` sees it.
        let lessons = CentreItem.statement(kind: .lessons, scope: .project)
        for from in [BinderSubject.canvas, .item("ch-1"), .edition(language: "es")] {
            let opened = ProjectWindow.openingInCentre(lessons, subject: WindowSubject(open: from, faces: from))
            XCTAssertEqual(ProjectWindow.centreItemAfterOpenChange(lessons, from: from, to: opened.open),
                           lessons, "opening from \(from) keeps the item it opened")
            XCTAssertEqual(route(opened, centreItem: lessons).cover, .centreItem(lessons))
        }
        XCTAssertNil(ProjectWindow.centreItemAfterOpenChange(nil, from: .canvas, to: .project))

        // The window applies the rule on every change of `open`; Close writes nil.
        let window = SourceScan.codeLines(
            of: try SourceTree.sourceOfType("ProjectWindow", under: ["Maugham"])).joined(separator: "\n")
        XCTAssertTrue(window.contains(".onChange(of: subject.open)"))
        XCTAssertTrue(window.contains("Self.centreItemAfterOpenChange(centreItem, from: old, to: new)"))
        let arm = try XCTUnwrap(CentreRouteSource.switchArms(
            in: try CentreRouteSource.editorArm(), over: "switch cover")).arm("centreItem")
        XCTAssertTrue(arm.contains("onClose: { closeCentreItem() }"), "Close is the column's one close")
        let close = try SourceTree.declaration(named: "func closeCentreItem(", under: "Maugham")
        XCTAssertTrue(close.contains("centreItem = nil"), "Close clears the window's item")
        let coverSource = SourceScan.codeLines(of: try GoingForTests.source("Maugham/Views/CentreItemCover.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(coverSource.contains("CentreKeys.returnKeysToTheManuscript(in: window)"),
                      "the cover's disappearance hands the keys back to the manuscript")
    }

    // MARK: - Esc, through the window's one arbiter (review I1)

    func test_escapeClosesTheCoverThroughTheArbiterInItsPlace() throws {
        XCTAssertEqual(WindowEscapeArbiter.Consumer.allCases, [.pulledUp, .centreItem, .canvasDim])
        let window = TestWindow.make(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                                     contentView: NSView(frame: .zero), present: .unshown)
        defer { window.close() }
        var closed = 0
        let escape = CentreItemEscape()
        escape.sync(window: window, findIsUp: false, close: { closed += 1 })
        XCTAssertTrue(escape.isInstalled)
        let arbiter = WindowEscapeArbiter.arbiter(for: window)

        // The pulled-up thing, beside the cover, takes Esc first.
        var dismissed = 0
        arbiter.register(.pulledUp, claim: { dismissed += 1; return true })
        XCTAssertTrue(arbiter.offerEscape())
        XCTAssertEqual(dismissed, 1)
        XCTAssertEqual(closed, 0, "the pulled-up thing's Esc is not the cover's")
        arbiter.resign(.pulledUp)

        XCTAssertTrue(arbiter.offerEscape(), "then Esc closes the cover")
        XCTAssertEqual(closed, 1)

        // The find overlay's Esc is its own: the cover declines and the key travels on.
        escape.sync(window: window, findIsUp: true, close: { closed += 1 })
        XCTAssertFalse(arbiter.offerEscape())
        XCTAssertEqual(closed, 1)

        // A field or a text view being typed in keeps Esc before any consumer
        // is asked: a ruling's edit field, the rename, the statement's editor.
        XCTAssertTrue(CanvasEscapeMonitor.isEditingText(NSTextField()))
        XCTAssertTrue(CanvasEscapeMonitor.isEditingText(NSTextView()))

        escape.stop()
        XCTAssertFalse(escape.isInstalled)
        XCTAssertFalse(arbiter.isArmed, "nothing left watching")

        let cover = SourceScan.codeLines(of: try GoingForTests.source("Maugham/Views/CentreItemCover.swift"))
            .joined(separator: "\n")
        XCTAssertFalse(cover.contains(".keyboardShortcut("), "Esc is never a key equivalent here")
        XCTAssertTrue(cover.contains(".onDisappear {\n            escape.stop()"), "registered only while the cover stands")
    }

    // MARK: - The keys under a cover (review C1)

    func test_whatCoversTheEditorHidesItAndTheCentreItemAsksForTheKeys() throws {
        // The one question: only the bare editor is the editor the writer sees.
        XCTAssertTrue(ProjectWindow.manuscriptIsVisible(route: .editor(altitude: nil, cover: nil)))
        XCTAssertFalse(ProjectWindow.manuscriptIsVisible(route: .editor(altitude: .cards, cover: nil)),
                       "the Book's view")
        XCTAssertFalse(ProjectWindow.manuscriptIsVisible(
            route: .editor(altitude: .cards, cover: .notice(.neverCompiled))))
        for cover: CentreCover in [.books([]), .publishProblems([]),
                                   .centreItem(.history(docId: "ch-1"))] {
            XCTAssertFalse(ProjectWindow.manuscriptIsVisible(route: .editor(altitude: nil, cover: cover)),
                           "\(cover)")
        }
        for route: CentreRoute in [.canvas, .inbox, .paletteWall, .research(id: "r"), .figure(id: "f")] {
            XCTAssertFalse(ProjectWindow.manuscriptIsVisible(route: route), "\(route)")
        }
        XCTAssertFalse(ProjectWindow.manuscriptIsVisible(route: nil))
        // The Insert menu asks it, with the window's centre item.
        XCTAssertFalse(InsertMenuGate.isEnabled(
            posture: .author, format: DocumentFormat.ofManuscript(path: "a.md"), manualReview: false,
            shareIsReadOnly: false, isReadingTranslation: false, gridHoldsTheKeys: false,
            route: route(WindowSubject(open: .item("ch-1"), faces: .item("ch-1")),
                         centreItem: .history(docId: "ch-1"))),
                       "Insert is disabled under the History cover")
        XCTAssertTrue(InsertMenuGate.isEnabled(
            posture: .author, format: DocumentFormat.ofManuscript(path: "a.md"), manualReview: false,
            shareIsReadOnly: false, isReadingTranslation: false, gridHoldsTheKeys: false,
            route: route(WindowSubject(open: .item("ch-1"), faces: .item("ch-1")), centreItem: nil)),
                      "premise: enabled over the bare chapter")
        let intent = CentreItem.statement(kind: .intent, scope: .document("ch-1"))
        XCTAssertEqual(CentreItemCover.claim(for: .centreItem(intent))?.prefersEditor, true,
                       "a statement: its own editor")
        XCTAssertEqual(CentreItemCover.claim(for: .centreItem(.history(docId: "ch-1")))?.prefersEditor, false,
                       "History: the cover itself")
        XCTAssertNil(CentreItemCover.claim(for: .books([])), "a publish cover asks for nothing; the guard holds")
        XCTAssertNil(CentreItemCover.claim(for: nil))

        XCTAssertTrue(CentreKeys.mayClaim(from: nil))
        XCTAssertTrue(CentreKeys.mayClaim(from: NSButton()), "nothing typed in")
        XCTAssertFalse(CentreKeys.mayClaim(from: NSTextView()), "never from the writer's typing elsewhere")

        // What the cover gives back when it goes is only what it held (R3).
        XCTAssertTrue(CentreKeys.coverHeldTheKeys(nil))
        let bare = TestWindow.make(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                   contentView: NSView(frame: .zero), present: .unshown)
        defer { bare.close() }
        XCTAssertTrue(CentreKeys.coverHeldTheKeys(bare), "the window itself: nothing has the keys")
        XCTAssertTrue(CentreKeys.coverHeldTheKeys(CentreKeysView()), "the guard")
        XCTAssertTrue(CentreKeys.coverHeldTheKeys(MaughamTextView()), "the cover's editor, orphaned by its removal")
        XCTAssertFalse(CentreKeys.coverHeldTheKeys(NSOutlineView()), "the tree, where a click put the keys")
        XCTAssertFalse(CentreKeys.coverHeldTheKeys(NSButton()))
        XCTAssertFalse(CentreKeys.coverHeldTheKeys(NSTextView()), "a field the writer is typing in")
        let handBack = try SourceTree.declaration(named: "static func returnKeysToTheManuscript(", under: "Maugham")
        XCTAssertTrue(handBack.contains("coverHeldTheKeys(window.firstResponder)"))
        XCTAssertFalse(handBack.contains("mayClaim("), "the hand-back is not a claim")

        // At the one place the centre decides a cover is up.
        let arm = SourceScan.codeLines(of: try CentreRouteSource.editorArm()).joined(separator: "\n")
        XCTAssertTrue(arm.contains(".background(CentreKeys(isCovered: { editorIsCovered(store: store) },"))
        XCTAssertTrue(arm.contains("claim: CentreItemCover.claim(for: cover)"))
        let covered = try SourceTree.declaration(named: "func editorIsCovered(", under: "Maugham")
        XCTAssertTrue(covered.contains("ProjectWindow.manuscriptIsVisible(route: route)"))
    }

    /// The writer types in the chapter, opens the intent in the centre and
    /// keeps typing: the keys are the cover's editor's, not the covered
    /// manuscript's; a load re-asserting the manuscript under the cover is
    /// turned away; Close hands them back. A measurement: nothing is pressed.
    func test_theCoversEditorTakesTheKeysAndCloseGivesThemBack() async throws {
        let f = try await fixture("CentreKeys")
        let docId = f.documentItemId
        let statement = try await f.store.createStatement(kind: .intent, scope: .document(docId))
        try await f.store.mutateStatementText(of: statement, session: "centre-test") { _ in "Turns on a lie." }
        let probe = CentreItemProbe()
        let window = f.hostView(AnyView(EditorUnderTheCover(
            store: f.store, documentStore: f.documentStore, docId: docId, probe: probe)), width: 600)
        await pumpUntil(deadline: 5) { Self.manuscript(in: window, f) != nil }
        let manuscript = try XCTUnwrap(Self.manuscript(in: window, f), "premise: the chapter is open")
        window.makeFirstResponder(manuscript)
        XCTAssertTrue(window.firstResponder === manuscript, "premise: the writer is typing in the chapter")

        probe.centreItem = .statement(kind: .intent, scope: .document(docId))
        await pumpUntil(deadline: 5) { Self.coverEditor(window.firstResponder) }
        XCTAssertTrue(Self.coverEditor(window.firstResponder),
                      "the keys are the cover's statement editor's, got \(String(describing: window.firstResponder))")
        XCTAssertFalse(window.firstResponder === manuscript)
        XCTAssertNotNil(f.store.openStatementDocument(id: statement.id), "and it is the bound statement's")

        // Something under the cover (a load's caret, a navigation's) takes the keys back.
        window.makeFirstResponder(manuscript)
        await pumpUntil(deadline: 5) { !(window.firstResponder === manuscript) }
        XCTAssertTrue(Self.coverEditor(window.firstResponder), "turned away to the cover's editor")

        // Close with the cover's editor still holding the keys (review N4's
        // gap): the hand-back runs from the cover's own disappearance.
        XCTAssertTrue(Self.coverEditor(window.firstResponder), "premise: the cover's editor has the keys")
        probe.centreItem = nil
        await pumpUntil(deadline: 5) { window.firstResponder === manuscript }
        XCTAssertTrue(window.firstResponder === manuscript, "the keys go back to the chapter the centre shows")
    }

    /// **A tree click that clears the cover leaves the keys in the tree**
    /// (fix 4, R3): the click moved the keys to the outline and changed
    /// `open`, which cleared the item; the cover's disappearance hands back
    /// only keys the cover held, so the writer's next keys are the tree's,
    /// exactly as the same click leaves them with no cover up. A measurement:
    /// the tree is a stand-in outline view beside the centre, nothing is
    /// pressed, and the item is cleared as the window's `open` change clears it.
    func test_aTreeClickThatClearsTheCoverLeavesTheKeysInTheTree() async throws {
        let f = try await fixture("CentreKeysTree")
        let docId = f.documentItemId
        let statement = try await f.store.createStatement(kind: .intent, scope: .document(docId))
        try await f.store.mutateStatementText(of: statement, session: "centre-test") { _ in "Turns on a lie." }
        let probe = CentreItemProbe()
        let window = f.hostView(AnyView(HStack(spacing: 0) {
            TreeStandIn().frame(width: 60)
            EditorUnderTheCover(store: f.store, documentStore: f.documentStore, docId: docId, probe: probe)
        }), width: 660)
        await pumpUntil(deadline: 5) { Self.manuscript(in: window, f) != nil }
        let manuscript = try XCTUnwrap(Self.manuscript(in: window, f))
        let tree = try XCTUnwrap(CentreKeysView.all(NSOutlineView.self, in: try XCTUnwrap(window.contentView)).first,
                                 "premise: the stand-in tree is mounted")

        for item in [CentreItem.statement(kind: .intent, scope: .document(docId)), .history(docId: docId)] {
            window.makeFirstResponder(manuscript)
            probe.centreItem = item
            await pumpUntil(deadline: 5) {
                Self.coverEditor(window.firstResponder) || window.firstResponder is CentreKeysView
            }
            XCTAssertFalse(window.firstResponder === manuscript, "premise: the cover took the keys (\(item))")

            XCTAssertTrue(window.makeFirstResponder(tree), "premise: the click gives the tree the keys")
            XCTAssertTrue(window.firstResponder === tree, "premise: the keys are the tree's")
            probe.centreItem = nil
            await waitOut(0.3)   // past the hand-back's hop
            XCTAssertTrue(window.firstResponder === tree,
                          "the cover's going took the keys from the tree (\(item)): got "
                          + String(describing: window.firstResponder))
        }
    }

    /// With a publish surface (or the Book's view) over the editor, the keys
    /// are never the manuscript's.
    func test_anOpaqueCoverKeepsTheKeysOffTheManuscript() async throws {
        let f = try await fixture("CentreKeysPublish")
        let probe = CentreItemProbe()
        let window = f.hostView(AnyView(EditorUnderTheCover(
            store: f.store, documentStore: f.documentStore, docId: f.documentItemId, probe: probe)), width: 600)
        await pumpUntil(deadline: 5) { Self.manuscript(in: window, f) != nil }
        let manuscript = try XCTUnwrap(Self.manuscript(in: window, f))
        window.makeFirstResponder(manuscript)
        XCTAssertTrue(window.firstResponder === manuscript, "premise")

        probe.coveredByAnotherSurface = true
        await pumpUntil(deadline: 5) { !(window.firstResponder === manuscript) }
        XCTAssertFalse(window.firstResponder === manuscript, "the covered manuscript lost the keys")
        XCTAssertTrue(window.firstResponder is CentreKeysView, "the guard holds them")
        window.makeFirstResponder(manuscript)
        await pumpUntil(deadline: 5) { !(window.firstResponder === manuscript) }
        XCTAssertFalse(window.firstResponder === manuscript, "and keeps turning them away")
    }

    /// Controller rulings (fix 2): a double-click on the open piece's own
    /// row closes the cover (any other open moves `open` and clears it there);
    /// an annotation jump closes it even with no paragraph to go to.
    func test_openingTheOpenPieceOrJumpingToAnAnnotationClosesTheCover() throws {
        let open = WindowSubject(open: .item("ch-1"), faces: .item("ch-1"))
        XCTAssertTrue(TreeTravelModifier.closesTheCentreItem(.item("ch-1"), clickCount: 2, current: open))
        XCTAssertFalse(TreeTravelModifier.closesTheCentreItem(.item("ch-1"), clickCount: 1, current: open),
                       "a single click is not an open")
        XCTAssertFalse(TreeTravelModifier.closesTheCentreItem(.item("ch-2"), clickCount: 2, current: open),
                       "another piece moves `open`, which clears the item on its own")
        let travel = SourceScan.codeLines(of: try GoingForTests.source("Maugham/Views/TreeTravel.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(travel.contains("Self.closesTheCentreItem(clicked, clickCount: clicks, current: subject)"))
        let nav = SourceScan.codeLines(of: try GoingForTests.source("Maugham/Views/ParagraphNavModifier.swift"))
        let receiver = try XCTUnwrap(nav.firstIndex { $0.contains(".onKeyWindowCommand(.maughamNavigateToAnnotation") })
        XCTAssertTrue(nav[receiver + 1].contains("if centreItem != nil { centreItem = nil }"))
    }

    // MARK: - Nothing under a cover writes the manuscript (fix 2)

    /// **⌘Z under a cover** (fix 3, controller ruling): the centre item's
    /// cover arriving drops the hidden chapter's typing undo from the window's
    /// stack (as `detach` does when a piece leaves the centre), so ⌘Z from
    /// the guard — or the tree, or a right-column field — has nothing of the
    /// chapter's to undo; a Rewind done from the History cover registers on
    /// the window's manager after that and IS undone by ⌘Z (ADR 0023); under
    /// a statement the statement's editor answers on its own manager. The
    /// control is the bare chapter, where the same ⌘Z runs the chapter's step.
    func test_undoUnderACover() async throws {
        let f = try await fixture("CentreUndo")
        let docId = f.documentItemId
        let statement = try await f.store.createStatement(kind: .intent, scope: .document(docId))
        try await f.store.mutateStatementText(of: statement, session: "centre-test") { _ in "Turns on a lie." }
        let probe = CentreItemProbe()
        let window = f.hostView(AnyView(EditorUnderTheCover(
            store: f.store, documentStore: f.documentStore, docId: docId, probe: probe)), width: 600)
        await pumpUntil(deadline: 5) { Self.manuscript(in: window, f) != nil }
        let manuscript = try XCTUnwrap(Self.manuscript(in: window, f))
        let shared = try XCTUnwrap(manuscript.undoManager, "premise: the manuscript's manager")
        XCTAssertTrue(shared === window.undoManager, "premise: it is the window's shared manager")
        let undo = Selector(("undo:"))

        // Control: the bare chapter's own ⌘Z path is unchanged — typing, then ⌘Z.
        window.makeFirstResponder(manuscript)
        let original = manuscript.string
        manuscript.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
        manuscript.insertText(" Typed.", replacementRange: manuscript.selectedRange())
        await waitOut(0.2)
        XCTAssertTrue(manuscript.string.hasSuffix(" Typed."), "premise: the typing landed")
        XCTAssertTrue(shared.canUndo, "premise: the typing is on the window's stack")
        XCTAssertTrue(manuscript.tryToPerform(undo, with: nil))
        await pumpUntil(deadline: 2) { manuscript.string == original }
        XCTAssertEqual(manuscript.string, original, "⌘Z over the bare chapter undoes the typing")

        // A place in the piece's history to Rewind to later: the op log as it
        // stands before the next typing.
        let doc = try XCTUnwrap(f.documentStore.document(forDocId: docId))
        try await doc.flushBurstNow()
        let history = try await doc.opLog()
        let mark = try XCTUnwrap(history.last?.opId, "premise: the piece has a history")

        // Typing again, then the History cover arrives: the chapter's typing goes.
        manuscript.insertText(" Typed again.", replacementRange: manuscript.selectedRange())
        await waitOut(0.2)
        XCTAssertTrue(shared.canUndo, "premise: typing on the stack before the cover")
        probe.centreItem = .history(docId: docId)
        await pumpUntil(deadline: 5) { window.firstResponder is CentreKeysView }
        XCTAssertFalse(shared.canUndo, "the cover's arrival dropped the hidden chapter's typing undo")
        let typed = manuscript.string
        let guardView = try XCTUnwrap(window.firstResponder as? CentreKeysView)
        XCTAssertFalse(guardView.responds(to: undo), "the guard does not swallow ⌘Z")
        _ = guardView.tryToPerform(undo, with: nil)
        await waitOut(0.2)
        XCTAssertEqual(manuscript.string, typed, "⌘Z under History reached nothing of the chapter's")

        // A Rewind from the History cover: the window's environment manager, as
        // `RewindModifier` passes it. ⌘Z from the guard undoes it.
        try await doc.flushBurstNow()
        _ = try await doc.restoreToOpUndoable(opId: mark, undoManager: window.undoManager)
        await waitOut(0.2)
        XCTAssertTrue(shared.canUndo, "premise: the Rewind registered on the window's manager")
        let rewound = doc.displayText
        XCTAssertNotEqual(rewound, typed, "premise: the Rewind moved the text")
        XCTAssertTrue(guardView.tryToPerform(undo, with: nil), "⌘Z under the cover reaches the window's manager")
        await doc.awaitPendingUndoWork()
        await pumpUntil(deadline: 3) { doc.displayText != rewound }
        XCTAssertNotEqual(doc.displayText, rewound, "⌘Z undid the Rewind (ADR 0023)")
        XCTAssertTrue(shared.canRedo)

        // A statement's cover: its own editor answers, on its own manager.
        probe.centreItem = .statement(kind: .intent, scope: .document(docId))
        await pumpUntil(deadline: 5) { Self.coverEditor(window.firstResponder) }
        let coverEditor = try XCTUnwrap(window.firstResponder as? MaughamTextView)
        XCTAssertFalse(coverEditor.undoManager === shared, "the statement's ⌘Z is the statement's")
        XCTAssertTrue(coverEditor.responds(to: undo))
    }

    /// **N2: an Insert command under a cover writes nothing**: the
    /// manuscript's coordinator asks `manuscriptCommandContext` and does not
    /// answer, as with no document open. The control (the bare chapter) takes
    /// the same post. A key window: the command is `.keyWindow`-scoped.
    func test_anInsertCommandUnderACoverWritesNothing() async throws {
        let f = try await fixture("CentreInsert")
        let docId = f.documentItemId
        let probe = CentreItemProbe()
        let window = TestWindow.mount(
            AnyView(EditorUnderTheCover(store: f.store, documentStore: f.documentStore,
                                        docId: docId, probe: probe).environment(f.preferences)),
            size: CGSize(width: 600, height: 700), as: KeyTestWindow.self)
        defer { window.close() }
        await pumpUntil(deadline: 5) { Self.manuscript(in: window, f) != nil }
        let manuscript = try XCTUnwrap(Self.manuscript(in: window, f))
        window.makeFirstResponder(manuscript)
        let before = manuscript.string
        MaughamEvent.post(.maughamInsertFootnote, to: .keyWindow)
        await pumpUntil(deadline: 5) { manuscript.string != before }
        XCTAssertNotEqual(manuscript.string, before, "premise: the bare chapter takes the footnote")

        probe.centreItem = .history(docId: docId)
        await pumpUntil(deadline: 5) { !CentreKeys.manuscriptIsVisible(holding: manuscript) }
        XCTAssertFalse(CentreKeys.manuscriptIsVisible(holding: manuscript), "the editor asks: covered")
        let covered = manuscript.string
        MaughamEvent.post(.maughamInsertFootnote, to: .keyWindow)
        MaughamEvent.post(.maughamInsertTable, to: .keyWindow)
        await waitOut(0.4)
        XCTAssertEqual(manuscript.string, covered, "an Insert under the History cover wrote the hidden chapter")
    }

    /// **N3: a view inside the manuscript loses the keys to the cover** — a
    /// field the manuscript hosts (as the figure grid's cell editor, the
    /// review composer and the find bar are), identified by ancestry.
    func test_aFieldInsideTheManuscriptLosesTheKeysToTheCover() async throws {
        let f = try await fixture("CentreKeysInside")
        let docId = f.documentItemId
        let statement = try await f.store.createStatement(kind: .intent, scope: .document(docId))
        try await f.store.mutateStatementText(of: statement, session: "centre-test") { _ in "Turns on a lie." }
        let probe = CentreItemProbe()
        let window = f.hostView(AnyView(EditorUnderTheCover(
            store: f.store, documentStore: f.documentStore, docId: docId, probe: probe)), width: 600)
        await pumpUntil(deadline: 5) { Self.manuscript(in: window, f) != nil }
        let manuscript = try XCTUnwrap(Self.manuscript(in: window, f))
        let cell = NSTextField(frame: NSRect(x: 20, y: 20, width: 120, height: 22))
        manuscript.addSubview(cell)
        window.makeFirstResponder(cell)
        XCTAssertTrue(CentreKeys.isInsideTheManuscript(window.firstResponder),
                      "premise: the field's editor is inside the manuscript, got \(String(describing: window.firstResponder))")
        XCTAssertFalse(CentreKeys.isManuscriptEditor(window.firstResponder),
                       "premise: and is not the manuscript text view itself")
        XCTAssertFalse(CentreKeys.isInsideTheManuscript(NSTextField()), "a field elsewhere is not")

        probe.centreItem = .statement(kind: .intent, scope: .document(docId))
        await pumpUntil(deadline: 5) { Self.coverEditor(window.firstResponder) }
        XCTAssertTrue(Self.coverEditor(window.firstResponder),
                      "the hidden field kept the keys: \(String(describing: window.firstResponder))")
        // And a re-assertion inside the manuscript (the grid re-taking its keys).
        window.makeFirstResponder(cell)
        await pumpUntil(deadline: 5) { Self.coverEditor(window.firstResponder) }
        XCTAssertTrue(Self.coverEditor(window.firstResponder), "turned away")
    }

    private static func manuscript(in window: NSWindow, _ f: StatementMountFixture) -> MaughamTextView? {
        f.allTextViews(in: window).first { CentreKeys.isManuscriptEditor($0) }
    }

    private static func coverEditor(_ responder: NSResponder?) -> Bool {
        responder is MaughamTextView && !CentreKeys.isManuscriptEditor(responder)
    }

    func test_theCoverMountsTodaysPanes() {
        XCTAssertEqual(CentreItemCover.content(of: .statement(kind: .intent, scope: .document("ch-1"))),
                       .statement(kind: .intent, subject: .item("ch-1")))
        XCTAssertEqual(CentreItemCover.content(of: .statement(kind: .intent, scope: .project)),
                       .statement(kind: .intent, subject: .project))
        XCTAssertEqual(CentreItemCover.content(of: .history(docId: "ch-1")), .history(docId: "ch-1"))
        XCTAssertEqual(CentreItemCover.title(of: .statement(kind: .intent, scope: .document("ch-1")),
                                             structure: structure), "What “One” is going for")
        XCTAssertEqual(CentreItemCover.title(of: .history(docId: "ch-1"), structure: structure),
                       "History of “One”")
    }

    // MARK: - The marks never reach the centre

    /// Constitution must-not #2: the check's marks are Brief's alone. The
    /// cover and the pane it mounts name no mark and read no check.
    func test_theMarksNeverReachTheCentre() throws {
        for path in ["Maugham/Views/CentreItemCover.swift", "Maugham/Views/StatementPane.swift"] {
            let code = SourceScan.codeLines(of: try GoingForTests.source(path)).joined(separator: "\n")
            XCTAssertEqual(Self.markReaders(in: code), [], "\(path) draws the check's marks")
        }
        let arm = try XCTUnwrap(CentreRouteSource.switchArms(
            in: try CentreRouteSource.editorArm(), over: "switch cover")).arm("centreItem")
        XCTAssertEqual(Self.markReaders(in: arm), [])
        XCTAssertEqual(Self.markReaders(in: "GoingForView(store: s, marks: BriefPane.marks(essay: e))").count, 3,
                       "the census sees a planted mark")
    }

    static func markReaders(in code: String) -> [String] {
        ["ClauseMark", "GoingForView(", "BriefPane.marks(", "BriefPane(", "lastCheck(", "clauseStatuses",
         "marks:"].filter { code.contains($0) }
    }

    // MARK: - One host per statement

    /// Review Focus 3: opening the intent in the centre while Brief's own
    /// editor holds it hands the `Document` over through the open gate —
    /// Brief's closed before the cover's loads, never two on one path — and
    /// Brief goes on reading it (the placeholder over the live text).
    func test_openingInTheCentreHandsBriefsEditorOver() async throws {
        let f = try await fixture("CentreHandOver")
        let docId = f.documentItemId
        let statement = try await f.store.createStatement(kind: .intent, scope: .document(docId))
        try await f.store.mutateStatementText(of: statement, session: "centre-test") { _ in
            "Chapter one turns on a lie."
        }
        let probe = CentreItemProbe()
        let window = f.hostView(AnyView(BriefBesideTheCentre(
            store: f.store, documentStore: f.documentStore, docId: docId, probe: probe)), width: 820)
        await pumpUntil(deadline: 5) {
            f.store.openStatementDocument(id: statement.id) != nil && f.firstTextView(in: window) != nil
        }
        let first = try XCTUnwrap(f.store.openStatementDocument(id: statement.id),
                                  "premise: Brief's Going for holds the intent")
        await f.type(" More words.", into: try f.textView(in: window))
        XCTAssertTrue(first.displayText.contains("More words."), "premise: the typing reached Brief's host")

        var events: [StatementGateEvent] = []
        f.store.onStatementGateEvent = { events.append($0) }
        defer { f.store.onStatementGateEvent = nil }
        probe.centreItem = .statement(kind: .intent, scope: .document(docId))
        await pumpUntil(deadline: 5) {
            guard let now = f.store.openStatementDocument(id: statement.id) else { return false }
            return now !== first && f.allTextViews(in: window).count == 1
        }

        let id = statement.id
        let closed = try XCTUnwrap(events.firstIndex(of: .closed(id)), "Brief's host let go under the gate: \(events)")
        let loading = try XCTUnwrap(events.lastIndex(of: .loading(id)), "the cover loaded: \(events)")
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: .closing(id))), closed)
        XCTAssertLessThan(closed, loading, "the cover loaded beside Brief's open Document: \(events)")
        XCTAssertTrue(first.isClosed)
        let second = try XCTUnwrap(f.store.openStatementDocument(id: statement.id))
        XCTAssertFalse(second === first)
        XCTAssertTrue(second.displayText.contains("More words."), "the typing was flushed before the hand-over")
        XCTAssertEqual(f.allTextViews(in: window).count, 1, "one editor: the cover's")

        await pumpUntil(deadline: 5) { f.shows(GoingForView.inTheCentreLine, in: window) }
        XCTAssertTrue(f.shows(GoingForView.inTheCentreLine, in: window))
        XCTAssertTrue(f.shows("More words.", in: window), "Brief reads the statement the centre holds")

        // **And back** (review M1): typed in the cover, then Close. The
        // cover's host lets go under the gate before Brief's loads, and
        // Brief's editor has every key.
        await f.type(" And a storm.", into: try f.textView(in: window))
        XCTAssertTrue(second.displayText.contains("And a storm."), "premise: the typing reached the cover's host")
        events.removeAll()
        probe.centreItem = nil
        await pumpUntil(deadline: 5) {
            guard let now = f.store.openStatementDocument(id: statement.id) else { return false }
            return now !== second && f.allTextViews(in: window).count == 1
        }
        let backClosed = try XCTUnwrap(events.firstIndex(of: .closed(id)), "the cover let go: \(events)")
        let backLoading = try XCTUnwrap(events.lastIndex(of: .loading(id)), "Brief loaded: \(events)")
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: .closing(id))), backClosed)
        XCTAssertLessThan(backClosed, backLoading, "Brief loaded beside the cover's open Document: \(events)")
        XCTAssertTrue(second.isClosed)
        let third = try XCTUnwrap(f.store.openStatementDocument(id: statement.id))
        XCTAssertTrue(third.displayText.contains("And a storm."), "no key lost on the way back")
        XCTAssertEqual(f.allTextViews(in: window).count, 1, "one editor: Brief's")
        XCTAssertFalse(f.shows(GoingForView.inTheCentreLine, in: window))
    }

    /// Review Focus 3: What I've Learned in the centre and pulled up at once.
    /// The pulled-up view (Task 7) asks `statementIsInTheCentre` and draws a
    /// placeholder; even a host that did not ask binds nothing beside the
    /// cover's — the gate's load waits.
    func test_whatIveLearnedPulledUpAndInTheCentreBindsOnce() async throws {
        let f = try await fixture("CentreLessonsTwice")
        let statement = try await f.store.createStatement(kind: .lessons, scope: .project)
        try await f.store.mutateStatementText(of: statement, session: "centre-test") { _ in
            "I overwrite endings."
        }
        let lessons = CentreItem.statement(kind: .lessons, scope: .project)
        XCTAssertTrue(ProjectWindow.statementIsInTheCentre(kind: .lessons, scope: .project, centreItem: lessons),
                      "the pulled-up view's question answers placeholder")
        XCTAssertEqual(PulledUp.lessons.centreItem, lessons, "and the pulled-up thing names the same item")

        // The pulled-up view as Task 7 builds it: it asks, and draws a
        // placeholder while the centre holds the ledger.
        let pulledUpAsks = ProjectWindow.statementIsInTheCentre(kind: .lessons, scope: .project,
                                                                centreItem: lessons)
        let window = f.hostView(AnyView(HStack(spacing: 0) {
            CentreItemCover(store: f.store, documentStore: f.documentStore, item: lessons,
                            bible: nil, world: nil, window: nil, findIsUp: false, onClose: {})
                .frame(width: 400)
            Group {
                if pulledUpAsks {
                    Text(GoingForView.inTheCentreLine)
                } else {
                    StatementEditorHost(store: f.store, documentStore: f.documentStore,
                                        kind: .lessons, scope: .project, posture: .author)
                }
            }
            .frame(width: 300)
        }), width: 700)
        await pumpUntil(deadline: 5) { f.store.openStatementDocument(id: statement.id) != nil }
        await waitOut(0.3)
        XCTAssertEqual(f.allTextViews(in: window).count, 1, "exactly one host binds the ledger")
        let editor = try XCTUnwrap(f.firstTextView(in: window))
        XCTAssertLessThan(CentreKeysView.visibleFrame(of: editor).midX, 400,
                          "the cover's host holds the ledger; the pulled-up view reads a placeholder")

        // A host that did not ask still never opens a second Document beside
        // the cover's: whichever loads first holds it, the other waits.
        let rogue = f.hostView(AnyView(StatementEditorHost(
            store: f.store, documentStore: f.documentStore,
            kind: .lessons, scope: .project, posture: .author)), width: 300)
        let held = try XCTUnwrap(f.store.openStatementDocument(id: statement.id))
        await waitOut(0.5)
        XCTAssertTrue(f.allTextViews(in: rogue).isEmpty, "the late host waits; no second editor")
        XCTAssertTrue(f.store.openStatementDocument(id: statement.id) === held, "one Document throughout")
    }

    // MARK: - Helpers

    private func route(_ subject: WindowSubject, centreItem: CentreItem?) -> CentreRoute {
        ProjectWindow.centreRoute(subject: subject, bookView: .outline, projectType: .novel,
                                  structure: structure, preview: .nothingCompiled,
                                  centreItem: centreItem)
    }
}

private extension CentreRoute {
    var cover: CentreCover? {
        if case .editor(_, let cover) = self { return cover }
        return nil
    }
}
