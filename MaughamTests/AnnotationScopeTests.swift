import XCTest
import MaughamCore
@testable import Maugham

/// **The queue's cross-document scope** (M3 P2 Task 7).
///
/// The pane widens from *this piece* to *all pieces*, grouped by piece in the
/// board's own order. Three separable rules live behind that sentence, and all
/// three are pure so the whole truth table is assertable with no window, no
/// store and no project on disk:
///
/// 1. **Which sections there are** (`AnnotationScopeSections.build`) — board
///    order, a header only where a descendant actually has notes, references
///    absent, and within a piece the queue order that piece's OWN sequence
///    gives (the snapshot carries per-document sequences precisely so a
///    cross-document sort never degrades to derive order).
/// 2. **What a row's verbs may do** (`AnnotationScopePolicy.verbsEnabled`) — a
///    closed piece's notes are readable and not actable, disabled WITH a reason
///    rather than enabled and silently inert (RULING-35).
/// 3. **What a click means** (`AnnotationScopePolicy.click`) — a row of the
///    piece already centred jumps to its paragraph; a row of another piece
///    travels to that piece. Travel writes the window's SUBJECT and nothing
///    else: Review's centre shows documents, so a navigation inside Review must
///    never move the persona (the ejection trap, `ManuscriptNavigationTests`).
///
/// The censuses at the foot are the fourth thing: the pure rules above are only
/// worth anything if the pane is wired to them, and each of those wirings has
/// no other guard.
final class AnnotationScopeTests: XCTestCase {

    // MARK: - Fixtures

    /// Tripwire 8: 4-char ids from `[0-9a-hjkmnp-tv-z]` — these paragraph ids
    /// cross the `.md` ↔ op log boundary in production.
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func doc(_ id: String, _ title: String? = nil,
                     kind: PieceKind? = nil,
                     children: [StructureItem]? = nil) -> StructureItem {
        StructureItem(id: id, title: title ?? id, type: .document,
                      path: "\(id).md", pieceKind: kind, children: children)
    }

    private func group(_ id: String, _ children: [StructureItem]) -> StructureItem {
        StructureItem(id: id, title: id, type: .group, children: children)
    }

    private func note(_ id: String, paragraph: String?,
                      triage: TriageMark? = nil,
                      offset: TimeInterval = 0) -> Annotation {
        Annotation(
            id: id, kind: .comment, paragraphId: paragraph,
            body: "body", suggestedText: nil, priorText: nil,
            createdAt: t0.addingTimeInterval(offset), createdBySession: nil,
            status: .open, userResponse: nil, resolvedAt: nil,
            isStale: false, triage: triage)
    }

    private func entry(_ docId: String, _ annotation: Annotation) -> ProjectAnnotation {
        ProjectAnnotation(docId: docId, annotation: annotation)
    }

    private func build(
        _ structure: [StructureItem],
        _ annotations: [ProjectAnnotation],
        sequences: [String: [String]] = [:]
    ) -> [AnnotationScopeSections.Section] {
        AnnotationScopeSections.build(
            rows: ReviewBoardRows.derive(structure: structure),
            annotations: annotations,
            sequences: sequences)
    }

    // MARK: - Which sections there are

    /// **The board's order, and the board's own walk.** The sections are
    /// `ReviewBoardRows.derive`'s rows with the un-annotated ones dropped — not
    /// a second walk of the manifest, and not the order the annotations arrived
    /// in. A reviewer reads the queue the way they read the binder.
    func test_sectionsFollowTheBoardsOwnOrder() {
        let structure = [
            doc("front"),
            group("PartOne", [doc("ch1"), doc("ch2")]),
            doc("back"),
        ]
        // Deliberately handed in reverse: the input order must not survive.
        let sections = build(structure, [
            entry("back", note("n4", paragraph: "aaaa")),
            entry("ch2", note("n3", paragraph: "aaaa")),
            entry("ch1", note("n2", paragraph: "aaaa")),
            entry("front", note("n1", paragraph: "aaaa")),
        ])

        XCTAssertEqual(sections.map(\.id),
                       ["front", "PartOne", "ch1", "ch2", "back"])
    }

    /// A piece nobody has annotated is not a section. The queue is a list of
    /// work; an empty heading per chapter is forty rows of nothing on a novel.
    func test_aPieceWithNoMatchingNotesGetsNoSection() {
        let sections = build([doc("ch1"), doc("ch2")],
                             [entry("ch2", note("n1", paragraph: "aaaa"))])

        XCTAssertEqual(sections.map(\.id), ["ch2"])
    }

    /// **A group header appears only when a descendant piece has notes** — and
    /// "descendant" means the group's own subtree, at any depth, because a flat
    /// row list cannot say where a group ends (depth rides on groups alone, so a
    /// root-level piece after a nested group is indistinguishable from one
    /// inside it). Depth travels with the header so the queue is indented the
    /// way the board is.
    func test_aGroupHeaderAppearsOnlyWhenADescendantPieceHasNotes() {
        let structure = [
            group("PartOne", [
                group("ActOne", [doc("ch1")]),
                doc("ch2"),
            ]),
            group("PartTwo", [doc("ch3")]),
        ]
        // Only the deeply-nested ch1 is annotated.
        let sections = build(structure, [entry("ch1", note("n1", paragraph: "aaaa"))])

        XCTAssertEqual(sections.map(\.id), ["PartOne", "ActOne", "ch1"],
                       "the annotated piece's ancestors, and no other group")
        XCTAssertEqual(sections.map(\.kind), [
            .group(depth: 0), .group(depth: 1), .piece,
        ])
    }

    /// The complement, which is what makes the rule above discriminating: with
    /// nothing annotated inside it, an ancestor of an annotated piece elsewhere
    /// stays out.
    func test_anEmptyGroupIsNotAHeaderEvenWhenItsSiblingIs() {
        let structure = [group("PartOne", [doc("ch1")]),
                         group("PartTwo", [doc("ch2")])]
        let sections = build(structure, [entry("ch2", note("n1", paragraph: "aaaa"))])

        XCTAssertEqual(sections.map(\.id), ["PartTwo", "ch2"])
    }

    /// **A Collection's reference piece is never a section.** Its notes live in
    /// the project it points at and are adjudicated in ITS window — P1's board
    /// made the same choice for the same reason (`ReviewBoardRows.Row.reference`
    /// carries no chips).
    func test_referencePiecesAreNeverASection() {
        let structure = [doc("linked", kind: .reference), doc("ch1")]
        let sections = build(structure, [
            entry("linked", note("n1", paragraph: "aaaa")),
            entry("ch1", note("n2", paragraph: "aaaa")),
        ])

        XCTAssertEqual(sections.map(\.id), ["ch1"])
    }

    /// And a reference cannot keep its group alive either — a header over a row
    /// that is never drawn is an empty section with extra steps.
    func test_aGroupWhoseOnlyAnnotatedChildIsAReferenceGetsNoHeader() {
        let structure = [group("PartOne", [doc("linked", kind: .reference)])]
        let sections = build(structure,
                             [entry("linked", note("n1", paragraph: "aaaa"))])

        XCTAssertTrue(sections.isEmpty)
    }

    func test_noAnnotationsMeansNoSections() {
        XCTAssertTrue(build([group("PartOne", [doc("ch1")])], []).isEmpty)
    }

    /// An annotation whose piece is not in the manifest at all (a stale id) has
    /// nowhere to be drawn, and inventing a section for it would put a row in
    /// the queue the writer cannot navigate to.
    func test_anAnnotationOnAPieceTheManifestDoesNotHaveIsDropped() {
        XCTAssertTrue(build([doc("ch1")],
                            [entry("ghost", note("n1", paragraph: "aaaa"))]).isEmpty)
    }

    // MARK: - Order within a section (the controller's FINDING-1 ruling)

    /// **Each piece's notes are in THAT piece's queue order** — triaged-`do`
    /// first, then that document's own paragraph order, from the sequence the
    /// snapshot carries. The sequences exist for exactly this: without them a
    /// closed document's notes would fall back to derive order and the
    /// cross-document queue would read in a different order from the same
    /// piece's own queue one click away.
    func test_withinAPieceTheOrderIsThatPiecesOwnQueueOrder() {
        let sections = build(
            [doc("ch1")],
            [entry("ch1", note("n1", paragraph: "dddd")),
             entry("ch1", note("n2", paragraph: "aaaa")),
             entry("ch1", note("n3", paragraph: "cccc", triage: .do))],
            sequences: ["ch1": ["aaaa", "bbbb", "cccc", "dddd"]])

        XCTAssertEqual(sections.first?.annotations.map(\.id), ["n3", "n2", "n1"],
                       "the `do` note leads; the rest in document order")
    }

    /// **Each piece is sorted against ITS OWN sequence**, never a neighbour's.
    /// One shared sequence would put every other document's notes in the
    /// unanchored tail — the same bug shape as `AnnotationQueueOrder`'s missing
    /// paragraph, spread across a project.
    ///
    /// The ids are chosen so that the queue's UNANCHORED tail order (newest,
    /// then id, both descending) is the reverse of each document's own order.
    /// A piece sorted against a neighbour's sequence has every note in the
    /// tail, so it comes out backwards — whichever neighbour's sequence was
    /// borrowed. Without that, "one shared sequence" passes half the time on a
    /// dictionary's iteration order, which is how this test was written first
    /// and what the planted-offender run caught.
    func test_eachPieceIsSortedAgainstItsOwnSequence() {
        let sections = build(
            [doc("ch1"), doc("ch2")],
            [entry("ch1", note("a1", paragraph: "aaaa")),
             entry("ch1", note("a2", paragraph: "dddd")),
             entry("ch2", note("b1", paragraph: "cccc")),
             entry("ch2", note("b2", paragraph: "bbbb"))],
            sequences: ["ch1": ["aaaa", "dddd"], "ch2": ["cccc", "bbbb"]])

        XCTAssertEqual(sections.map { $0.annotations.map(\.id) },
                       [["a1", "a2"], ["b1", "b2"]],
                       "ch2's order is ch2's sequence — reversed relative to "
                       + "ch1's, so a shared sequence cannot produce it")
    }

    /// A piece the walk could not derive a sequence for still renders: every
    /// note lands in the tail group and is ordered by the queue's own tiebreak
    /// rather than crashing or vanishing.
    func test_aPieceWithNoSequenceStillOrdersItsNotes() {
        let sections = build(
            [doc("ch1")],
            [entry("ch1", note("n1", paragraph: "aaaa", offset: 0)),
             entry("ch1", note("n2", paragraph: "bbbb", offset: 60))])

        XCTAssertEqual(sections.first?.annotations.map(\.id), ["n2", "n1"],
                       "newest first, the queue's tiebreak")
    }

    // MARK: - Pieces the walk could not read (RULING-54's honesty half)

    /// `unreadableDocIds` is the aggregation's promise that a short answer is
    /// never a silent one. In the queue that promise is a footnote naming the
    /// pieces — a reviewer who sees no notes for Chapter Three must be told the
    /// difference between "none" and "unknown".
    func test_theUnreadableNoticeNamesThePiecesRatherThanSayingNothing() throws {
        let rows = ReviewBoardRows.derive(
            structure: [doc("ch1", "Chapter One"), doc("ch3", "Chapter Three")])
        let notice = try XCTUnwrap(AnnotationScopeSections.unreadableNotice(
            unreadableDocIds: ["ch3"], rows: rows))

        XCTAssertTrue(notice.contains("Chapter Three"),
                      "the piece is named, by title: \(notice)")
        XCTAssertFalse(notice.contains("Chapter One"),
                       "and only the piece that could not be read")
    }

    func test_thereIsNoNoticeWhenEverythingWasReadable() {
        let rows = ReviewBoardRows.derive(structure: [doc("ch1")])
        XCTAssertNil(AnnotationScopeSections.unreadableNotice(
            unreadableDocIds: [], rows: rows))
    }

    // MARK: - What a row's verbs may do

    /// **RULING-35's shape: disabled with a reason, never enabled and inert.**
    /// A closed piece has no live `Document`, so accepting a suggestion there
    /// would either do nothing or mutate a transient document ⌘Z cannot reach.
    /// Reading the note is still worth the row — clicking it opens the piece,
    /// and the flow is the affordance.
    func test_verbsAreEnabledOnlyWhereTheDocumentIsOpen() {
        XCTAssertTrue(AnnotationScopePolicy.verbsEnabled(documentIsOpen: true))
        XCTAssertFalse(AnnotationScopePolicy.verbsEnabled(documentIsOpen: false))
        // Anti-degeneracy: a rule answering a constant would satisfy either
        // line above on its own.
        XCTAssertNotEqual(AnnotationScopePolicy.verbsEnabled(documentIsOpen: true),
                          AnnotationScopePolicy.verbsEnabled(documentIsOpen: false))
        XCTAssertFalse(AnnotationScopePolicy.closedPieceReason.isEmpty,
                       "a disabled control that cannot say why is the half of "
                       + "RULING-35 that costs the writer the most")
    }

    // MARK: - What a click means (the ejection trap)

    func test_aRowOfThePieceAlreadyCentredJumpsAndAnyOtherTravels() {
        XCTAssertEqual(
            AnnotationScopePolicy.click(rowDocId: "ch1", activeDocId: "ch1"),
            .jump)
        XCTAssertEqual(
            AnnotationScopePolicy.click(rowDocId: "ch2", activeDocId: "ch1"),
            .travel("ch2"))
        // Nothing open at all: the click is still a travel, which is what opens
        // the piece the row belongs to.
        XCTAssertEqual(
            AnnotationScopePolicy.click(rowDocId: "ch2", activeDocId: nil),
            .travel("ch2"))
    }

    /// **The pane's own file writes no persona.** Mirrors
    /// `ReviewBoardRoutingTests.test_theBoardsOwnFileWritesNoPersona`: the queue
    /// is a surface Review shows, never a thing that decides Review is showing.
    /// A reviewer clicking a note about Chapter Nine must land in Chapter Nine
    /// with their notes still beside them.
    func test_thePanesOwnFileWritesNoPersona() throws {
        let source = try Self.source(of: "Views/AnnotationsPane.swift")
        for shape in ["persona = ", "persona.wrappedValue = ", "$0.persona = "] {
            XCTAssertFalse(source.contains(shape),
                           "`AnnotationsPane` writes the window's persona "
                           + "(`\(shape)`) — the closed set of decision sites is "
                           + "`ManuscriptNavigation`, `PersonaModifier`, "
                           + "`CanvasClaudeArrivalModifier` and `TreeTravel`")
        }
    }

    /// And the closure the pane is HANDED, which lives in the mount: a subject
    /// write, and no persona riding along with it.
    func test_theMountsTravelClosureWritesTheSubjectAndNothingElse() throws {
        let source = try Self.source(of: "Views/DetailPaneToggle.swift")
        let arm = try XCTUnwrap(
            Self.declaration(named: "private var annotationsPane:", in: source),
            "the annotations arm must still be a readable declaration")
        let code = SourceScan.codeLines(of: arm).joined(separator: "\n")

        XCTAssertTrue(code.contains("selectedSubject = .item("),
                      "travelling to a piece IS the window's subject write")
        XCTAssertFalse(code.contains("persona"),
                       "the queue's travel closure moves the window's PERSONA — "
                       + "the ejection trap the whole of M3 is written around")
    }

    // MARK: - The pane is wired to the rules above

    /// The project-scope row must pass BOTH halves of the gate — the predicate
    /// and the reason — or a closed piece's row is a set of live controls that
    /// do nothing.
    func test_theProjectRowIsGatedOnTheOpenDocumentAndCarriesTheReason() throws {
        let source = try Self.source(of: "Views/AnnotationsPane.swift")
        XCTAssertTrue(source.contains("AnnotationScopePolicy.verbsEnabled("),
                      "the row's gate is the pure predicate, not a second "
                      + "spelling of it in the view")
        XCTAssertTrue(source.contains("AnnotationScopePolicy.closedPieceReason"),
                      "and the disabled row says why")
        XCTAssertTrue(source.contains("AnnotationScopePolicy.click("),
                      "and the click's meaning is the pure rule's, not the "
                      + "view's own comparison")
    }

    /// **Bulk stays document-scope.** `AnnotationBulkActions.perform` runs
    /// against ONE document, and a bar whose counts spanned pieces it cannot
    /// act on would be a lie in the one place the writer is trusting a number.
    /// The honest version of cross-document bulk is a batch per document with
    /// its own undo story; it is not this task.
    func test_bulkAffordancesAreDocumentScopeOnly() throws {
        XCTAssertTrue(AnnotationScopePolicy.showsBulkAffordances(.document))
        XCTAssertFalse(
            AnnotationScopePolicy.showsBulkAffordances(.project(focusPiece: nil)))
        XCTAssertFalse(
            AnnotationScopePolicy.showsBulkAffordances(.project(focusPiece: "ch1")))

        let source = try Self.source(of: "Views/AnnotationsPane.swift")
        XCTAssertTrue(source.contains("AnnotationScopePolicy.showsBulkAffordances("),
                      "the bar and its door both ask the predicate")
    }

    // MARK: - Reactivity (the obligation Task 6's review left behind)

    /// **`listAnnotationsAcrossProject` is deliberately non-reactive** — its
    /// cache is `@ObservationIgnored`, so nothing re-renders because a note
    /// changed. Project scope therefore arranges its own refresh: every verb
    /// bumps a token the snapshot read is keyed on. Without this a stet in the
    /// cross-document queue leaves its own row on screen unchanged, which is
    /// the surface lying about what just happened.
    ///
    /// A census rather than a mounted drive: each verb is a `Task` on the
    /// pane, and the failure mode is one of them being ADDED without the bump.
    func test_everyVerbBumpsTheRefreshTokenSoProjectScopeReReads() throws {
        let source = try Self.source(of: "Views/AnnotationsPane.swift")
        let verbs = [
            "private func performAccept(",
            "private func replyToQuery(",
            "private func reject(",
            "private func stet(",
            "private func triage(",
            "private func archive(",
            "private func reopen(",
            "private func performRevert(",
            "private func editOwn(",
            "private func withdrawOwn(",
            "private func runBulk(",
        ]
        for header in verbs {
            let body = try XCTUnwrap(Self.declaration(named: header, in: source),
                                     "\(header) is gone or renamed — this census "
                                     + "is stale and must be updated deliberately")
            XCTAssertTrue(body.contains("noteChanged()"),
                          "\(header) does not bump the project-scope refresh "
                          + "token, so a cross-document row it changes stays "
                          + "stale on screen")
        }

        // **And the list itself is checked, because it is hand-maintained and
        // it was one short the first time it was written** (`replyToQuery`,
        // caught in review). A verb list that can silently fall behind is a
        // census that passes by omission — so every MUTATION SITE in the file
        // must fall inside one of the declarations above. Adding a verb
        // without adding it here now fails, which is the whole point.
        let mutationLines = source.split(separator: "\n")
            .map(String.init)
            .filter { $0.contains("await document.")
                   || $0.contains("await AnnotationBulkActions.perform") }
        XCTAssertFalse(mutationLines.isEmpty,
                       "the scan found no mutation sites at all — it has "
                       + "stopped reading the file it is about")
        let covered = verbs.compactMap { Self.declaration(named: $0, in: source) }
        for line in mutationLines {
            XCTAssertTrue(covered.contains { $0.contains(line) },
                          "a document mutation lives outside every verb this "
                          + "census names, so nothing checks that it bumps the "
                          + "token: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    /// **The third half, which Task 7 could not build: a change that happened
    /// somewhere else.**
    ///
    /// The verbs above cover notes the writer resolves in this pane, and the
    /// open document's version counter covers ones they resolve in the editor.
    /// Neither covers a note arriving in a piece this window never opened — a
    /// peer device's sync, or Claude writing into a closed chapter — because
    /// nothing in this process is observing that file. `.maughamAnnotations
    /// Changed` (Task 9) is that channel, and the pane's job is to bump the
    /// same token its own verbs do.
    func test_theQueueReReadsWhenTheProjectSaysItsNotesChanged() throws {
        let source = try Self.source(of: "Views/AnnotationsPane.swift")

        let receiver = try XCTUnwrap(
            source.range(of: ".onProjectEvent(.maughamAnnotationsChanged"),
            "the pane must subscribe to the annotation-change event — without "
            + "it a closed piece's synced-in note never reaches project scope")
        let after = String(source[receiver.upperBound...].prefix(400))
        XCTAssertTrue(after.contains("noteChanged()"),
                      "the receiver must bump the SAME token the verbs bump, "
                      + "not invent a second refresh path")
        XCTAssertTrue(after.contains("window: window") || source.contains("window: window"),
                      "…through the receive helper's window, which is what "
                      + "carries the closed-window liveness guard (ADR 0021)")
        XCTAssertTrue(source.contains("WindowAccessor(window: $window)"),
                      "and the window is resolved the documented way — a "
                      + "cached nil is not a close check (`MaughamEvent.isLive`)")
    }

    /// The other half of the obligation: the snapshot read is keyed on the
    /// token AND on the open document's own version counter, so an edit made in
    /// the margin card or the editor while project scope is up reaches the
    /// queue as well.
    func test_theProjectReadIsKeyedOnTheTokenAndTheOpenDocumentsVersion() throws {
        let source = try Self.source(of: "Views/AnnotationsPane.swift")
        let read = try XCTUnwrap(
            Self.declaration(named: "private var projectSnapshot:", in: source))
        XCTAssertTrue(read.contains("projectRefreshToken"),
                      "the read must observe the token the verbs bump")
        XCTAssertTrue(read.contains("annotationsVersion"),
                      "and the open document's version, for an edit that "
                      + "arrives from the editor rather than from a row here")
    }

    // MARK: - Source access

    private static func source(of relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
        return try String(contentsOf: root.appendingPathComponent(relativePath),
                          encoding: .utf8)
    }

    /// A member declaration, from its opening line to the closing brace at
    /// member indentation — bounded, or a scan over it is really a scan over
    /// the rest of the file.
    private static func declaration(named header: String, in source: String) -> String? {
        guard let start = source.range(of: header) else { return nil }
        let rest = source[start.lowerBound...]
        guard let end = rest.range(of: "\n    }\n") else { return String(rest) }
        return String(rest[..<end.upperBound])
    }
}
