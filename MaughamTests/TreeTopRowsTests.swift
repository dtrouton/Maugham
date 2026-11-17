import XCTest
import MaughamCore
@testable import Maugham

/// **The tree's rows and the click** (shell p1 Task 3): the order the rows
/// stand in, the Inbox row's condition, and the two row states.
@MainActor
final class TreeTopRowsTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        temp.cleanup()
        temp = nil
    }

    // MARK: - The order

    /// **The spec's order**, with every conditional row present — and each
    /// condition taking only its own row away.
    func test_rowOrderIsBookInboxCanvasManuscriptFiguresResearchPaletteEditions() throws {
        XCTAssertEqual(
            TreeRowSlot.order(hasInbox: true, showsFigures: true, showsEditions: true),
            [.book, .inbox, .canvas, .manuscript, .figures, .research, .palette, .editions])
        XCTAssertEqual(
            TreeRowSlot.order(hasInbox: false, showsFigures: false, showsEditions: false),
            [.book, .canvas, .manuscript, .research, .palette])

        // Every host draws in that order: the Book row, the top rows, its
        // manuscript, then the sections — read off its own `List`.
        let hosts: [(file: String, manuscript: String)] = [
            ("Maugham/Views/BinderView.swift", "outline(items: store.manifest.structure)"),
            ("Maugham/Views/CollectionPiecesPane.swift", "ForEach(store.manifest.structure)"),
            ("Maugham/Views/SceneNavigatorPane.swift", "scriptRow"),
        ]
        for host in hosts {
            let text = try code(host.file)
            let list = try XCTUnwrap(text.range(of: "List(selection:"),
                                     "\(host.file) has no tree `List`")
            let body = String(text[list.lowerBound...])
            try assertInOrder(["projectRow", "TreeTopRows(hasInbox:", host.manuscript,
                               "BinderTreeSections(store:"], in: body, host.file)
        }
        // …and the sections draw Figures, Research, Palette, Editions.
        let sections = try code("Maugham/Views/BinderTreeSections.swift")
        let body = try XCTUnwrap(sections.range(of: "var body: some View {"))
        try assertInOrder(["figuresSection", "researchSection", "paletteSection",
                           "TreeEditionRows(rows:"],
                          in: String(sections[body.lowerBound...]), "BinderTreeSections")
    }

    // MARK: - The Inbox row

    /// **The Inbox row shows only when the project has an inbox** — a capture
    /// manifest from any device — or when the Inbox is what is open.
    func test_theInboxRowShowsOnlyWhenTheProjectHasAnInbox() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "Inbox-\(UUID().uuidString.prefix(6))", in: temp.url)
        XCTAssertFalse(InboxStore.projectHasInbox(projectURL: url),
                       "a fresh project has no captures")
        let store = try await ProjectStore.load(from: url)
        let state = BinderTreeSectionsState()
        XCTAssertFalse(TreeTopRows.hasInbox(state: state, store: store, subject: .book))
        XCTAssertTrue(TreeTopRows.hasInbox(state: state, store: store,
                                           subject: SubjectSamples.opened(.inbox)),
                      "a row that is open is always drawn")

        let inbox = url.appendingPathComponent(".maugham/inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try Data().write(to: inbox.appendingPathComponent("inbox.dev-1.jsonl"))
        XCTAssertTrue(InboxStore.projectHasInbox(projectURL: url))
        state.projectHasInbox = InboxStore.projectHasInbox(projectURL: url)
        XCTAssertTrue(TreeTopRows.hasInbox(state: state, store: store, subject: .book))
    }

    // MARK: - The Inbox row's dot

    /// **The Inbox row carries one dot while a capture awaits triage, none at
    /// zero, and it clears when the capture is dealt with** — the signal the
    /// deleted picker badge gave, over the same `entries` it counted.
    func test_theInboxDotShowsWhileACaptureWaitsAndClearsWhenItIsDealtWith() async throws {
        XCTAssertFalse(TreeTopRows.hasNewCaptures(inbox: nil), "no inbox, no dot")

        let root = TestTemp.root.appendingPathComponent("inbox-dot-\(UUID().uuidString)")
        let dir = root.appendingPathComponent(".maugham/inbox")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let inbox = InboxStore(projectURL: root, deviceId: "mac")
        await inbox.refresh()
        XCTAssertTrue(inbox.entries.isEmpty, "premise: nothing waiting")
        XCTAssertFalse(TreeTopRows.hasNewCaptures(inbox: inbox), "hidden at zero")

        func entry(_ status: InboxEntry.Status, at seconds: TimeInterval) -> InboxEntry {
            InboxEntry(id: "c1", createdAt: Date(timeIntervalSince1970: seconds),
                       deviceId: "phone", kind: .text, inlineText: "a thought",
                       transcript: nil, transcriptionState: .none, status: status)
        }
        let phone = JSONLAppendStore<InboxEntry>(
            fileURL: dir.appendingPathComponent("inbox.phone.jsonl"))
        try await phone.append(entry(.new, at: 100))
        await inbox.refresh()
        XCTAssertEqual(inbox.entries.count, 1, "premise: the old badge would read 1")
        XCTAssertTrue(TreeTopRows.hasNewCaptures(inbox: inbox), "shown while one waits")

        let mac = JSONLAppendStore<InboxEntry>(
            fileURL: dir.appendingPathComponent("inbox.mac.jsonl"))
        try await mac.append(entry(.promoted, at: 200))
        await inbox.refresh()
        XCTAssertTrue(inbox.entries.isEmpty, "premise: the old badge would clear")
        XCTAssertFalse(TreeTopRows.hasNewCaptures(inbox: inbox), "cleared once dealt with")
    }

    /// The dot is a dot, said to VoiceOver, and every tree host hands it in.
    func test_theDotIsLabelledAndEveryHostHandsItIn() throws {
        XCTAssertEqual(TreeTopRows.newCapturesLabel, "New captures")
        let rows = try code("Maugham/Views/TreeTopRows.swift")
        XCTAssertTrue(rows.contains(".accessibilityLabel(Self.newCapturesLabel)"))
        XCTAssertTrue(rows.contains("Circle()"), "one dot")
        for host in ["Maugham/Views/BinderView.swift", "Maugham/Views/CollectionPiecesPane.swift",
                     "Maugham/Views/SceneNavigatorPane.swift"] {
            XCTAssertTrue(try code(host).contains("hasNewCaptures: TreeTopRows.hasNewCaptures(store: store)"),
                          "\(host) hands the Inbox row its dot")
        }
    }

    // MARK: - The click and the two states

    /// **A click on a research row opens it beside**, through the tree's own
    /// resolution, and what is open does not move — and the Book row, no
    /// longer the one the `List` draws, carries the open mark.
    func test_aClickOnAResearchRowOpensItBeside() {
        let current = SubjectSamples.opened(.item(SubjectSamples.pieceID))
        let shownBefore = BinderTreeSelection.shown([], subject: current, clickedAt: nil)
        let out = BinderTreeSelection.resolved(
            written: [.research(SubjectSamples.researchID)], stored: [],
            shown: shownBefore, subject: current,
            structure: SubjectSamples.structure, research: [], figures: [],
            projectType: .novel)
        XCTAssertEqual(out.subject.open, current.open)
        XCTAssertEqual(out.subject.faces, current.faces)
        XCTAssertEqual(out.subject.beside, .research(SubjectSamples.researchID))
        let shown = BinderTreeSelection.shown(out.selection, subject: out.subject,
                                              clickedAt: out.subject)
        XCTAssertEqual(shown, [.research(SubjectSamples.researchID)],
                       "the note the writer clicked is the `List`'s selection")
        XCTAssertEqual(BinderTreeSelection.openMark(shown: shown, subject: out.subject),
                       current.open, "the piece still open is marked as open")
    }

    /// **Two row states, visibly different**: the faces the writer clicked
    /// while the canvas or an edition keeps the centre is the `List`'s
    /// selection, and the open row carries the open mark; what is beside, when
    /// neither, is outlined.
    func test_theFacesRowIsMarkedWhenItDiffersFromTheOpenRow() {
        let piece = BinderSubject.item(SubjectSamples.pieceID)
        for open in [BinderSubject.canvas, .edition(language: "es")] {
            let before = SubjectSamples.opened(open)
            let out = BinderTreeSelection.resolved(
                written: [piece], stored: [],
                shown: BinderTreeSelection.shown([], subject: before, clickedAt: nil),
                subject: before, structure: SubjectSamples.structure,
                research: [], figures: [], projectType: .novel)
            XCTAssertEqual(out.subject, WindowSubject(open: open, faces: piece))
            let shown = BinderTreeSelection.shown(out.selection, subject: out.subject,
                                                  clickedAt: out.subject)
            XCTAssertEqual(shown, [piece], "the faces the writer clicked are selected")
            XCTAssertEqual(BinderTreeSelection.openMark(shown: shown, subject: out.subject),
                           open, "\(open) stays the centre, and is marked so")
        }
        // A note beside, the Book row clicked after it: the note is outlined.
        let withNote = WindowSubject(open: .project, faces: .project,
                                     beside: .research(SubjectSamples.researchID))
        XCTAssertEqual(BinderTreeSelection.outlined(shown: [.project], subject: withNote),
                       [.research(SubjectSamples.researchID)])
        // Control: over the Book a piece click opens it — one row, no marks.
        let opened = SubjectSamples.opened(piece)
        let shown = BinderTreeSelection.shown([piece], subject: opened, clickedAt: opened)
        XCTAssertNil(BinderTreeSelection.openMark(shown: shown, subject: opened))
        XCTAssertEqual(BinderTreeSelection.outlined(shown: shown, subject: opened), [])
    }

    /// **The outline is drawn by every row that names a subject**: the mark
    /// each row's label carries draws it, so no row can be clicked into the
    /// faces without being able to show it.
    func test_theRowMarkDrawsTheOutlinedState() throws {
        let travel = try code("Maugham/Views/TreeTravel.swift")
        let mark = try XCTUnwrap(travel.range(of: "func treeTravelOnDoubleClick("))
        XCTAssertTrue(travel[mark.lowerBound...].contains("TreeRowStateMark(subject: subject)"))
        for host in ["Maugham/Views/BinderView.swift", "Maugham/Views/CollectionPiecesPane.swift",
                     "Maugham/Views/SceneNavigatorPane.swift"] {
            XCTAssertTrue(try code(host).contains(".treeRowStates(state: treeState, subject: subject)"),
                          "\(host) hands its rows the outlined set")
        }
    }

    // MARK: - Helpers

    private func code(_ path: String) throws -> String {
        let text = try String(contentsOf: SourceTree.repoRoot.appendingPathComponent(path),
                              encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func assertInOrder(_ needles: [String], in text: String, _ where_: String,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        var cursor = text.startIndex
        for needle in needles {
            let found = try XCTUnwrap(text.range(of: needle, range: cursor..<text.endIndex),
                                      "\(where_): `\(needle)` is missing or out of order",
                                      file: file, line: line)
            cursor = found.upperBound
        }
    }
}
