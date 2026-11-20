import XCTest
import MaughamCore
@testable import Maugham

/// **A row's click goes to its place** (shell plan 2 Task 4): the payload a
/// To resolve row posts always names its document and a paragraph, so
/// `ManuscriptNavigation` opens that piece on that paragraph whatever the
/// centre was — which is how a row on a piece that is not open becomes a row
/// that can act. Pure (tripwire 33), plus a census that the posts go through
/// `MaughamEvent` (tripwire 21).
@MainActor
final class ResolveNavigationTests: XCTestCase {

    private let t = Date(timeIntervalSince1970: 1_700_000_000)
    private let docKey = ManuscriptNavigation.docIdKey

    private func note(_ id: String, on docId: String, pid: String?) -> ResolveItem {
        .note(ProjectAnnotation(docId: docId, annotation: Annotation(
            id: id, kind: .comment, paragraphId: pid, body: id, suggestedText: nil, priorText: nil,
            createdAt: t, createdBySession: nil, status: .open, userResponse: nil,
            resolvedAt: nil, isStale: false)))
    }

    private func finding(_ id: String, on docId: String, pid: String?) -> ResolveItem {
        .finding(docId: docId, Diagnostic(
            id: id, docId: docId, anchor: pid.map { .init(paragraphId: $0, anchorText: "x") },
            body: id, category: nil, runId: "run-1", kind: .conformanceStrain))
    }

    private func todo(_ id: String, on docId: String?, pid: String?) -> ResolveItem {
        .todo(WriterTask(id: id, kind: .paneCreated,
                         anchor: docId.map { TaskAnchor(docId: $0, paragraphId: pid) },
                         body: id, status: .open, priority: 0, parentTaskId: nil,
                         createdAt: t, createdBySession: nil))
    }

    // MARK: - A row's click inside the Book or a Part (owner's ruling, review I1)

    private let structure: [StructureItem] = [
        StructureItem(id: "doc-a", title: "Arrival", type: .document, path: "manuscript/a.md"),
        StructureItem(id: "part-1", title: "Part One", type: .group, children: [
            StructureItem(id: "doc-b", title: "Breakfast", type: .document, path: "manuscript/b.md"),
        ]),
    ]

    /// The window's receiver, as production runs it (`ParagraphNavModifier`).
    private func receive(_ payload: [String: Any]?, current: WindowSubject,
                         control: EditorControl) -> WindowSubject {
        ManuscriptNavigation.holdingThePlace(payload: payload, current: current,
                                             structure: structure, control: control)
    }

    /// What the pane posts for a row's click in `faces`' list.
    private func clickPayload(_ item: ResolveItem, faces: BinderSubject) -> [String: Any]? {
        let scope = ResolveScope.of(faces, structure: structure, projectType: .novel)
        return ResolveNavigation.opensInsideTheFaces(docId: item.docId, scope: scope)
            ? ResolveNavigation.insideTheFacesPayload(for: item, firstParagraph: "aa11")
            : ResolveNavigation.payload(for: item, firstParagraph: "aa11")
    }

    /// Book scope → click a row: the piece is open, the faces are still the
    /// Book (and so the list), the clicked-last part is still the Book, the
    /// place is held for the editor, and the row's verbs are then offered.
    func test_aRowClickInTheBookListOpensThePieceAndLeavesTheFaces() throws {
        for faces in [BinderSubject.project, .item("part-1")] {
            let current = WindowSubject(open: .project, faces: faces)
            let before = ResolveScope.of(faces, structure: structure, projectType: .novel)
            let row = note("n1", on: "doc-b", pid: "bb22")
            let control = EditorControl()
            let next = receive(clickPayload(row, faces: faces), current: current, control: control)
            XCTAssertEqual(next.open, .item("doc-b"), "\(faces): the row's piece takes the centre")
            XCTAssertEqual(next.faces, faces, "\(faces): the faces stay")
            XCTAssertEqual(next.lastClicked, faces, "\(faces): what was clicked last is still the faces")
            XCTAssertEqual(ResolveScope.of(next.faces, structure: structure, projectType: .novel), before,
                           "\(faces): so the list stays")
            XCTAssertEqual(control.pendingPlace?.docId, "doc-b", "\(faces): the place is held for the load")
            XCTAssertEqual(control.pendingPlace?.target, .paragraph(id: "bb22", offset: nil),
                           "\(faces): on the row's paragraph")
            XCTAssertTrue(ResolveVerbGate.mayAct(onDocId: "doc-b", subject: next, isRegistered: { _ in true }),
                          "\(faces): once registered, the opened piece's rows act inside the list")
            XCTAssertFalse(ResolveVerbGate.mayAct(onDocId: "doc-a", subject: next, isRegistered: { _ in true }),
                           "\(faces): and only its rows")
        }
    }

    /// Every kind of row, and the finding's chip, go inside the faces.
    func test_everyRowKindOpensInsideTheBook() {
        let book = WindowSubject(open: .project, faces: .project)
        for row in [note("n1", on: "doc-a", pid: "aa11"), finding("s1", on: "doc-a", pid: "aa11"),
                    todo("t1", on: "doc-a", pid: "aa11")] {
            let next = receive(clickPayload(row, faces: .project), current: book, control: EditorControl())
            XCTAssertEqual(next, WindowSubject(open: .item("doc-a"), faces: .project), row.id)
        }
    }

    /// At a piece's own scope nothing changes: open = faces = piece.
    func test_aRowClickAtPieceScopeIsTheOrdinaryPlace() {
        let current = WindowSubject(open: .canvas, faces: .item("doc-a"))
        let row = note("n1", on: "doc-a", pid: "aa11")
        XCTAssertFalse(ResolveNavigation.opensInsideTheFaces(
            docId: "doc-a", scope: ResolveScope.of(.item("doc-a"), structure: structure, projectType: .novel)))
        let next = receive(clickPayload(row, faces: .item("doc-a")), current: current, control: EditorControl())
        XCTAssertEqual(next.open, .item("doc-a"))
        XCTAssertEqual(next.faces, .item("doc-a"))
    }

    /// Every OTHER going-to-a-place path keeps `open = faces = piece`: a find
    /// result (a plain paragraph payload) over the Book still moves the faces.
    /// And the marked payload where the faces do not hold the piece falls back
    /// to the same.
    func test_aFindResultStillMovesTheFaces() {
        let book = WindowSubject(open: .project, faces: .project)
        let find: [String: Any] = [docKey: "doc-b", "paragraph_id": "bb22"]
        let next = receive(find, current: book, control: EditorControl())
        XCTAssertEqual(next.open, .item("doc-b"))
        XCTAssertEqual(next.faces, .item("doc-b"), "a find result moves the faces with the piece")

        let elsewhere = WindowSubject(open: .project, faces: .item("part-1"))
        let marked = ResolveNavigation.insideTheFacesPayload(for: note("n", on: "doc-a", pid: "aa11"),
                                                             firstParagraph: nil)
        let fallback = receive(marked, current: elsewhere, control: EditorControl())
        XCTAssertEqual(fallback, WindowSubject(open: .item("doc-a"), faces: .item("doc-a")),
                       "a Part that does not hold the piece: the ordinary place")
        XCTAssertNil(ClickRule.openInsideTheFaces("doc-a", current: WindowSubject(open: .project,
                                                                                   faces: .figure("fig-aaaa1111")),
                                                  structure: structure), "a figure's faces hold no piece")
    }

    /// **Review I3.** "Open the queue" on a translation round report (drawn
    /// over an edition, which To resolve has no list for) opens the round's
    /// piece — open = faces = piece — and then asks for Questions, in that
    /// order, so the request waits for the piece's list.
    func test_openTheQueueOpensTheRoundsPieceThenAsksForQuestions() throws {
        var posts: [(Notification.Name, [AnyHashable: Any])] = []
        let names: [Notification.Name] = [.maughamNavigateToParagraph, .maughamSetRightColumn]
        let tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in // adr-0021-ok: a test's synchronous recorder of the posts' order
                posts.append((note.name, note.userInfo ?? [:]))
            }
        }
        defer { tokens.forEach(NotificationCenter.default.removeObserver) }

        TranslationRoundReport.openQueue(docId: "doc-b")

        XCTAssertEqual(posts.map(\.0), names, "the piece first, then To resolve")
        let place = try XCTUnwrap(posts.first?.1)
        let edition = WindowSubject(open: .edition(language: "es"), faces: .edition(language: "es"))
        XCTAssertEqual(ResolveScope.of(edition.faces, structure: structure, projectType: .novel), .outside,
                       "premise: the edition's faces have no list")
        let next = receive(place.reduce(into: [String: Any]()) { $0[String(describing: $1.key)] = $1.value },
                           current: edition, control: EditorControl())
        XCTAssertEqual(next.open, .item("doc-b"))
        XCTAssertEqual(next.faces, .item("doc-b"), "the round's piece is on the faces: its list")
        XCTAssertEqual(posts.last?.1[MaughamEvent.resolveFilterKey] as? String, ResolveKeyFilter.questions.rawValue)

        let view = SourceScan.codeLines(of: try SourceTree.read(
            "Maugham/Views/Publish/TranslationRoundReportView.swift")).joined(separator: "\n")
        XCTAssertTrue(view.contains("TranslationRoundReport.openQueue(docId: round.docId)"),
                      "the report's button is this door")
        XCTAssertFalse(view.contains("postResolve("), "and asks for no filter of its own")
    }

    func test_aRowPayloadAlwaysNamesItsDocument() {
        for item in [note("n1", on: "doc-b", pid: "bb22"),
                     finding("s1", on: "doc-b", pid: "bb22"),
                     todo("t1", on: "doc-b", pid: "bb22")] {
            XCTAssertEqual(ResolveNavigation.payload(for: item, firstParagraph: "aa11"),
                           [docKey: "doc-b", "paragraph_id": "bb22"],
                           "\(item.id) names its own document and its own paragraph")
        }
    }

    func test_aWholePieceRowLandsOnTheFirstParagraph() {
        for item in [note("n1", on: "doc-b", pid: nil),
                     finding("s1", on: "doc-b", pid: nil),
                     todo("t1", on: "doc-b", pid: nil)] {
            XCTAssertEqual(ResolveNavigation.payload(for: item, firstParagraph: "aa11"),
                           [docKey: "doc-b", "paragraph_id": "aa11"],
                           "\(item.id) points at no paragraph: the piece's first")
            XCTAssertNil(ResolveNavigation.payload(for: item, firstParagraph: nil),
                         "a piece with no paragraph has no place to name")
        }
        XCTAssertNil(ResolveNavigation.payload(
            for: todo("b1", on: ProjectStore.projectTasksDocId, pid: nil), firstParagraph: "aa11"),
            "a Book-level to-do has no place in the manuscript")
        XCTAssertNil(ResolveNavigation.payload(for: todo("b2", on: nil, pid: nil), firstParagraph: "aa11"),
                     "nor one with no anchor")
        XCTAssertNil(ResolveNavigation.payload(for: note("f1", on: "fig-aaaa1111", pid: nil),
                                               firstParagraph: "aa11"),
                     "a figure's note goes to its figure, not to a paragraph")
    }

    /// The posts go through the typed wrapper, a note's annotation event
    /// first — the receivers are unchanged.
    func test_goPostsThroughMaughamEventOnly() throws {
        let code = try SourceTree.read("Maugham/Views/Resolve/ResolveNavigation.swift")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("NotificationCenter"), "tripwire 21: MaughamEvent only")
        let annotation = try XCTUnwrap(code.range(of: "MaughamEvent.post(.maughamNavigateToAnnotation"))
        let paragraph = try XCTUnwrap(code.range(of: "MaughamEvent.post(.maughamNavigateToParagraph"))
        XCTAssertLessThan(annotation.lowerBound, paragraph.lowerBound,
                          "a note's annotation event is posted before the paragraph's")
    }

    /// One spelling of the payload (fix round 1, M4): the head's "Open the
    /// piece…" and its letter's jumps use the same builder as a row.
    func test_aPlaceWithoutAParagraphOnlyOpensThePiece() throws {
        let docKey = ManuscriptNavigation.docIdKey
        XCTAssertEqual(ResolveNavigation.payload(docId: "doc-b", paragraphId: nil),
                       [docKey: "doc-b"])
        XCTAssertEqual(ResolveNavigation.payload(docId: "doc-b", paragraphId: "bb22"),
                       [docKey: "doc-b", "paragraph_id": "bb22"])
        for file in ["Maugham/Views/Resolve/ResolveHead.swift",
                     "Maugham/Views/Resolve/ResolvePane.swift"] {
            let code = SourceScan.codeLines(of: try SourceTree.read(file)).joined(separator: "\n")
            XCTAssertFalse(code.contains("\"paragraph_id\""),
                           "\(file) spells no paragraph payload of its own")
        }
    }
}
