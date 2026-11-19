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
    init() {}
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
                                    bible: nil, world: nil, onClose: { probe.centreItem = nil })
                }
            }
            .frame(width: 500)
            BriefPane(store: store, documentStore: documentStore, scope: .piece(docId: docId),
                      diagnostics: nil, bible: nil, world: nil, centreItem: probe.centreItem,
                      onOpenInCentre: { _ in }, onPullUp: { _ in },
                      onShowStrain: { _, _ in }, onOpenBrief: { _ in })
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
        for fixture in fixtures { fixture.tearDown() }
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
        XCTAssertTrue(arm.contains("onClose: { centreItem = nil }"), "Close clears the window's item")
        let cover = try GoingForTests.source("Maugham/Views/CentreItemCover.swift")
        XCTAssertTrue(cover.contains(".keyboardShortcut(.cancelAction)"), "Esc closes it too")
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

        let window = f.hostView(AnyView(HStack(spacing: 0) {
            CentreItemCover(store: f.store, documentStore: f.documentStore, item: lessons,
                            bible: nil, world: nil, onClose: {})
                .frame(width: 400)
            StatementEditorHost(store: f.store, documentStore: f.documentStore,
                                kind: .lessons, scope: .project, posture: .author)
                .frame(width: 300)
        }), width: 700)
        await pumpUntil(deadline: 5) { f.store.openStatementDocument(id: statement.id) != nil }
        await waitOut(0.5)

        XCTAssertEqual(f.allTextViews(in: window).count, 1, "exactly one host binds the ledger")
        XCTAssertNotNil(f.store.openStatementDocument(id: statement.id))
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
