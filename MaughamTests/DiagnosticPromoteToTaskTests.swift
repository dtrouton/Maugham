import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **A note the writer wants to keep becomes a task** (M2 Task 9). The
/// compiler's notes are per-device derived state that the next run wholly
/// supersedes; a task is op-logged, syncs, and survives. Promotion is the one
/// hop between them.
///
/// The ¶ anchor rides the `.taskCreate` op's EXISTING `changes` field — the
/// same anchor-plus-snapshot shape a paragraph-scoped annotation already uses
/// (`Document.addAnnotation`) — so nothing about the wire format moves and
/// `ProjectManifest.currentSchemaVersion` does not bump. Two of the tests
/// below are about exactly that, because a promotion that quietly widened the
/// schema would be an old build's problem, not this milestone's.
@MainActor
final class DiagnosticPromoteToTaskTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.contentView = NSView(frame: .zero) }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeDocument(
        initialMd: String = "The fog came in on little cat feet."
    ) async throws -> (doc: Document, root: URL) {
        let (root, docURL) = try makeTestProject(
            prefix: "PROMOTE", initialMd: initialMd)
        let doc = try await Document.load(
            url: docURL, device: "macA", session: "s1", presenter: nil)
        return (doc, root)
    }

    private func firstParagraphId(of doc: Document) throws -> String {
        try XCTUnwrap(doc.sequence.first, "the fixture document has no paragraphs")
    }

    /// Every fixture carries a `kind`, because a diagnostic without one is by
    /// definition a v1 record and `DiagnosticsStore.load` drops those as
    /// superseded — and the pane calls `load` on appear, so a kind-less
    /// fixture would vanish before the mounted view ever sees it.
    private func makeDiagnostic(
        docId: String, paragraphId: String?, anchorText: String = "",
        body: String = "The rhythm flattens across these three sentences.",
        category: String? = "rhythm", kind: DiagnosticKind = .continuity
    ) -> Diagnostic {
        Diagnostic(
            id: ULID.generate(), docId: docId,
            anchor: paragraphId.map {
                Diagnostic.Anchor(paragraphId: $0, anchorText: anchorText)
            },
            body: body, category: category, runId: ULID.generate(), kind: kind)
    }

    /// Noon on a fixed day **in the runner's own calendar**, so the stamp the
    /// provenance line renders is `2026-07-24` wherever this runs. A fixed
    /// `timeIntervalSince1970` would be a different date in Auckland than in
    /// Los Angeles, and CI does not share the developer machine's timezone.
    private static let fixedRunDate = Calendar.current.date(
        from: DateComponents(year: 2026, month: 7, day: 24, hour: 12))!

    private func makeRun(
        model: String = "sonnet", intentSnapshot: String? = nil,
        at: Date = DiagnosticPromoteToTaskTests.fixedRunDate
    ) -> CompilerRun {
        CompilerRun(
            id: ULID.generate(), at: at, model: model, lastOpId: "op1",
            deltaSummary: "1 new, 0 revised \u{00b6}", intentSnapshot: intentSnapshot)
    }

    // MARK: - The anchor rides the op, through the REAL deriver

    /// The whole point of the slice: a promoted note's task knows which ¶ it
    /// was raised against, and it knows it after a full round-trip through
    /// `TaskDeriver` — not from the synthetic preview `createPaneTask` returns,
    /// which could agree with itself and be wrong.
    func test_aPromotedTaskIsParagraphAnchored() async throws {
        let (doc, _) = try await makeDocument()
        let pid = try firstParagraphId(of: doc)

        let preview = doc.createPaneTask(
            body: "Fix the rhythm here.", parentTaskId: nil, paragraphId: pid)

        // Straight off the deriver's own projection, not the preview.
        let (derived, _, _) = TaskDeriver.derive(
            ops: try await doc.opLog(), paragraphs: doc.paragraphs, docId: doc.docId)
        let task = try XCTUnwrap(
            derived.first { $0.id == preview.id },
            "the promoted task never came back out of TaskDeriver")

        XCTAssertEqual(task.kind, .paneCreated)
        XCTAssertEqual(task.anchor?.docId, doc.docId)
        XCTAssertEqual(
            task.anchor?.paragraphId, pid,
            "a promoted task must carry the \u{00b6} it was raised against — that is "
            + "what makes it navigable once the note it came from is gone")
        // And the live read agrees with the raw derive.
        let live = doc.tasks(filter: .init(scope: .document(docId: doc.docId)))
        XCTAssertEqual(live.first { $0.id == preview.id }?.anchor?.paragraphId, pid)
    }

    /// The defaulted parameter is not a behaviour change for anyone who does
    /// not pass it: `TasksPane`'s New Task still makes a doc-scoped task.
    func test_paneCreatedTasksWithoutParagraphStayDocScoped() async throws {
        let (doc, _) = try await makeDocument()

        let preview = doc.createPaneTask(body: "draft act 2", parentTaskId: nil)

        let (derived, _, _) = TaskDeriver.derive(
            ops: try await doc.opLog(), paragraphs: doc.paragraphs, docId: doc.docId)
        let task = try XCTUnwrap(derived.first { $0.id == preview.id })
        XCTAssertEqual(task.anchor?.docId, doc.docId)
        XCTAssertNil(
            task.anchor?.paragraphId,
            "a task created from the pane anchors to the document, not to whatever "
            + "paragraph happened to be under the cursor")
        XCTAssertNil(preview.anchor?.paragraphId, "the preview must agree with the derive")
    }

    // MARK: - Schema: the anchor changes nothing on the wire

    /// **On the record.** The ¶ anchor uses `changes[0].paragraphId`, a field
    /// every op has carried since the first one. Encoded and decoded with the
    /// shipped op-log codec, a promoted task's op comes back whole and its
    /// kind is a named case — not `.unknown`, the fallback an unrecognised
    /// wire value would produce — and the manifest schema version is where it
    /// was.
    func test_promotedTaskOpsDecodeUnderTheCurrentSchema() async throws {
        let (doc, root) = try await makeDocument()
        let pid = try firstParagraphId(of: doc)
        doc.createPaneTask(body: "Fix the rhythm here.", parentTaskId: nil, paragraphId: pid)
        await doc.close()

        // Through the real store: the production encoder wrote the line, the
        // production decoder read it back.
        let store = OpLogStore(projectURL: root)
        let reloaded = try await store.load(docId: doc.docId)
        let created = try XCTUnwrap(
            reloaded.first { $0.kind == .taskCreate },
            "the .taskCreate op did not survive the round-trip to disk")

        XCTAssertNotEqual(
            created.kind, .unknown,
            "a promoted task's op must decode to a named kind — `.unknown` would mean "
            + "the wire format moved and every older build reads this op as inert")
        XCTAssertEqual(created.changes.count, 1)
        XCTAssertEqual(created.changes.first?.paragraphId, pid)
        XCTAssertEqual(created.provenance?.taskBody, "Fix the rhythm here.")
        XCTAssertEqual(created.provenance?.taskKind, TaskKind.paneCreated.rawValue)
        XCTAssertNil(
            created.sequence,
            "a task op must not assert an ordering — a stale sequence here would "
            + "revert a peer's reorder (see the merge/derive contract)")

        XCTAssertEqual(
            ProjectManifest.currentSchemaVersion, 4,
            "promoting a diagnostic adds no key to the op wire format, so it must not "
            + "bump the schema version; if this is failing because a DIFFERENT change "
            + "bumped it, that change owns the migration story, not this one")
    }

    /// A task op is non-manuscript (`Deriver.appliesToManuscript`), so giving
    /// it a `changes` entry must not move one byte of derived prose. Asserted
    /// against the same log before and after, because the fold is the thing
    /// that would silently absorb an anchor as an edit.
    func test_aPromotedTaskOpDoesNotPerturbDerivedParagraphs() async throws {
        let (doc, _) = try await makeDocument(
            initialMd: "The fog came in.\n\nIt sat looking over harbour and city.")
        let pid = try firstParagraphId(of: doc)

        let before = Deriver.derive(ops: try await doc.opLog())
        doc.createPaneTask(body: "Fix the rhythm here.", parentTaskId: nil, paragraphId: pid)
        let after = Deriver.derive(ops: try await doc.opLog())

        XCTAssertEqual(
            before.paragraphs, after.paragraphs,
            "a task op's change entry is an ANCHOR, never an edit — folding it into "
            + "derived text would silently blank the paragraph it points at")
        XCTAssertEqual(before.sequence, after.sequence)
        XCTAssertFalse(before.paragraphs.isEmpty, "the fixture derived nothing to compare")
        XCTAssertFalse(
            Deriver.appliesToManuscript(.taskCreate),
            "the guarantee above is this switch's, not this test's")
    }

    // MARK: - What the task says

    func test_theTaskBodyCarriesProvenanceNotPlumbing() {
        let diagnostic = makeDiagnostic(
            docId: "d1", paragraphId: "a1b2",
            body: "The rhythm flattens across these three sentences.")
        let run = makeRun(
            model: "sonnet",
            intentSnapshot: "A ghost story told in weather.\nNo one says the word ghost.")

        let body = DiagnosticPromotion.taskBody(for: diagnostic, run: run)

        XCTAssertTrue(
            body.hasPrefix("The rhythm flattens across these three sentences."),
            "the note's own words come first: \(body)")
        XCTAssertTrue(
            body.contains("\u{2014} compiler, 2026-07-24, sonnet, from continuity, "
                          + "checked against: \u{201C}A ghost story told in weather.\u{201D}"),
            "the provenance line must say who checked, when, in what model, which section "
            + "raised it, and against what: \(body)")
        XCTAssertFalse(
            body.contains("No one says the word ghost"),
            "only the intent's first line belongs in a task body")
        XCTAssertFalse(
            body.contains("a1b2"),
            "the \u{00b6} id is plumbing — it lives in the task's anchor, and a writer "
            + "reading their own task list should never see one")
    }

    /// **A heading is not what the run checked against.**
    ///
    /// The statement Answer (and bless) mints on a piece that had only project
    /// intent is an empty essay above a `## Rulings` heading — so a
    /// first-non-empty-line rule wrote `checked against: "## Rulings"` into a
    /// durable, op-logged task the writer reads months later. The real answer
    /// for that statement is the first ruling: the sentence the run genuinely
    /// was checked against.
    ///
    /// The heading skip is `IntentStrip.line(from:)`'s, reused rather than
    /// re-spelled — a third answer to "what is a heading" is the drift the
    /// shared block parser was extracted to end.
    func test_theProvenanceLineSkipsAHeadingForTheSentenceUnderIt() {
        let snapshot = "## Rulings\n\n- Kelly never lies \u{2014} ruled 7 Aug 2026, from a run\n"
        let body = DiagnosticPromotion.taskBody(
            for: makeDiagnostic(docId: "d1", paragraphId: nil, body: "Drift."),
            run: makeRun(model: "opus", intentSnapshot: snapshot))

        XCTAssertFalse(body.contains("## Rulings"),
                       "the task recorded a markdown heading as the writer's intent: \(body)")
        XCTAssertTrue(body.contains("checked against: \u{201C}Kelly never lies"),
                      "the first real line under the heading is what the run was checked "
                      + "against: \(body)")
    }

    /// A statement that is nothing but headings has no line to quote, so the
    /// clause is omitted rather than filled with the nearest markup.
    func test_aStatementOfNothingButHeadingsClaimsNoIntent() {
        let body = DiagnosticPromotion.taskBody(
            for: makeDiagnostic(docId: "d1", paragraphId: nil, body: "Drift."),
            run: makeRun(model: "opus", intentSnapshot: "# Intent\n\n## Rulings\n\n"))
        XCTAssertFalse(body.contains("checked against"), body)
    }

    /// A run with nothing to say about what it checked against says nothing —
    /// no empty quotes, no "checked against: (none)".
    func test_theProvenanceLineOmitsAnAbsentIntent() {
        let body = DiagnosticPromotion.taskBody(
            for: makeDiagnostic(docId: "d1", paragraphId: nil, body: "Drift."),
            run: makeRun(model: "opus", intentSnapshot: "   \n"))
        XCTAssertTrue(body.contains("\u{2014} compiler, 2026-07-24, opus"))
        XCTAssertFalse(body.contains("checked against"), body)
    }

    /// No run record, no provenance to claim. The note's words stand alone
    /// rather than gaining a line with holes in it.
    func test_withoutARunRecordTheBodyIsJustTheNote() {
        let body = DiagnosticPromotion.taskBody(
            for: makeDiagnostic(docId: "d1", paragraphId: nil, body: "Drift."), run: nil)
        XCTAssertEqual(body, "Drift.")
    }

    /// The record names which section raised the note (spec §5's fates line:
    /// "body cites the section it came from") — the pane's own words for each
    /// of the three sectioned kinds.
    func test_theProvenanceLineNamesTheSectionItCameFrom() {
        for (kind, label) in [
            (DiagnosticKind.conformanceStrain, "conformance"),
            (DiagnosticKind.continuity, "continuity"),
            (DiagnosticKind.readerReport, "the reader"),
        ] {
            let body = DiagnosticPromotion.taskBody(
                for: makeDiagnostic(docId: "d1", paragraphId: nil, body: "Drift.", kind: kind),
                run: makeRun())
            XCTAssertTrue(
                body.contains("from \(label)"), "expected \(label) for \(kind): \(body)")
        }
    }

    /// A `kind == nil` record — the mark of a diagnostic from before the
    /// sectioned contract — cites no section, because there is none to cite.
    func test_aKindlessRecordCitesNoSection() {
        let diagnostic = Diagnostic(
            id: ULID.generate(), docId: "d1", anchor: nil, body: "Drift.",
            category: nil, runId: ULID.generate())
        XCTAssertNil(diagnostic.kind, "the fixture must actually be kindless")
        let body = DiagnosticPromotion.taskBody(for: diagnostic, run: makeRun())
        XCTAssertFalse(body.contains("from "), body)
    }

    /// A long intent is cut, and the cut is visible.
    func test_aLongIntentIsTruncatedVisibly() {
        let long = String(repeating: "weather ", count: 40)
        let body = DiagnosticPromotion.taskBody(
            for: makeDiagnostic(docId: "d1", paragraphId: nil, body: "Drift."),
            run: makeRun(intentSnapshot: long))
        XCTAssertTrue(body.contains("\u{2026}\u{201D}"), body)
        XCTAssertLessThan(body.count, long.count)
    }

    // MARK: - The pane's own button, pressed for real

    func test_promoteDismissesTheNote() async throws {
        let (doc, root) = try await makeDocument()
        let pid = try firstParagraphId(of: doc)
        let store = DiagnosticsStore(
            projectRoot: root, device: DeviceSlug.make(from: "test-mac"))
        let note = makeDiagnostic(
            docId: doc.docId, paragraphId: pid, anchorText: doc.paragraph(id: pid) ?? "")
        store.replace(run: makeRun(), diagnostics: [note], docId: doc.docId)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: store, docId: doc.docId,
            currentText: { [weak doc] in doc?.paragraph(id: $0) },
            compilerModel: .standard,
            activeDocument: { doc })))
        pump(0.2)

        let promote = try button(labelled: "Promote to Task", in: window)
        _ = promote.perform(NSSelectorFromString("accessibilityPerformPress"))
        pump(0.3)

        XCTAssertTrue(
            store.live(docId: doc.docId, currentText: { doc.paragraph(id: $0) }).isEmpty,
            "a promoted note has become durable elsewhere — leaving it on the pane "
            + "asks the writer to answer it twice")
        let tasks = doc.tasks(filter: .init(scope: .document(docId: doc.docId)))
        XCTAssertEqual(tasks.count, 1, "the press must have made exactly one task")
        XCTAssertEqual(tasks.first?.anchor?.paragraphId, pid)
        XCTAssertTrue(
            tasks.first?.body.hasPrefix(note.body) == true,
            "the task carries the note's words: \(tasks.first?.body ?? "<none>")")
    }

    /// A drift note has no ¶ to carry, and promoting one must still work —
    /// it is the note most worth keeping, and it lands doc-scoped.
    func test_aDriftNotePromotesDocScoped() async throws {
        let (doc, root) = try await makeDocument()
        let store = DiagnosticsStore(
            projectRoot: root, device: DeviceSlug.make(from: "test-mac"))
        store.replace(
            run: makeRun(),
            diagnostics: [makeDiagnostic(
                docId: doc.docId, paragraphId: nil,
                body: "The outline promised a scene that never got written.",
                category: nil)],
            docId: doc.docId)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: store, docId: doc.docId,
            currentText: { [weak doc] in doc?.paragraph(id: $0) },
            compilerModel: .standard,
            activeDocument: { doc })))
        pump(0.2)

        let promote = try button(labelled: "Promote to Task", in: window)
        _ = promote.perform(NSSelectorFromString("accessibilityPerformPress"))
        pump(0.3)

        let tasks = doc.tasks(filter: .init(scope: .document(docId: doc.docId)))
        XCTAssertEqual(tasks.count, 1)
        XCTAssertNil(tasks.first?.anchor?.paragraphId)
    }

    // MARK: - Undo

    /// ⌘Z takes the task back. It does NOT bring the note back, and that is
    /// the intended shape rather than an oversight: the store is per-device
    /// derived state with no undo of its own, and the next run repopulates it.
    func test_undoTakesBackTheTaskAndTheNoteDoesNotReturn() async throws {
        let (doc, root) = try await makeDocument()
        let pid = try firstParagraphId(of: doc)
        let store = DiagnosticsStore(
            projectRoot: root, device: DeviceSlug.make(from: "test-mac"))
        let note = makeDiagnostic(
            docId: doc.docId, paragraphId: pid, anchorText: doc.paragraph(id: pid) ?? "")
        store.replace(run: makeRun(), diagnostics: [note], docId: doc.docId)

        let undoManager = UndoManager()
        doc.createPaneTask(
            body: DiagnosticPromotion.taskBody(for: note, run: store.lastRun(docId: doc.docId)),
            parentTaskId: nil, paragraphId: pid, undoManager: undoManager)
        store.dismiss(note.id, docId: doc.docId)

        XCTAssertEqual(
            doc.tasks(filter: .init(scope: .document(docId: doc.docId), statuses: [.open])).count, 1)

        undoManager.undo()
        await doc.awaitPendingUndoWork()

        XCTAssertTrue(
            doc.tasks(filter: .init(scope: .document(docId: doc.docId), statuses: [.open])).isEmpty,
            "\u{2318}Z must take back the task the promotion created")
        XCTAssertTrue(
            store.live(docId: doc.docId, currentText: { doc.paragraph(id: $0) }).isEmpty,
            "the note staying gone is INTENDED: dismissing it is store-side, and the "
            + "diagnostics sidecar is per-device derived state with no undo of its own "
            + "\u{2014} the next run raises the note again if it still stands")
    }

    // MARK: - Hosting + accessibility (mirrors DiagnosticsPaneTests')

    private func mount(_ view: AnyView) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 420, height: 700)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump()
        return window
    }

    private func pump(_ seconds: TimeInterval = 0.2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func axAttribute(_ element: AnyObject, _ attribute: String) -> Any? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(attribute)) else { return nil }
        return object.value(forKey: attribute)
    }

    private func axElements(under root: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 40 else { return [] }
        let children = axAttribute(root, "accessibilityChildren") as? [AnyObject] ?? []
        return [root] + children.flatMap { axElements(under: $0, depth: depth + 1) }
    }

    private func axTree(in window: NSWindow) throws -> [AnyObject] {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process, so SwiftUI "
                + "never built the tree this test presses through")
        }
        return axElements(under: try XCTUnwrap(window.contentView))
    }

    private func button(labelled label: String, in window: NSWindow) throws -> NSObject {
        var lastAll: [AnyObject] = []
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            lastAll = try axTree(in: window)
                .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            if let match = lastAll.first(
                where: { (axAttribute($0, "accessibilityLabel") as? String) == label }) as? NSObject {
                return match
            }
            pump(0.05)
        }
        return try XCTUnwrap(
            lastAll.first { (axAttribute($0, "accessibilityLabel") as? String) == label } as? NSObject,
            "no button labelled \u{201C}\(label)\u{201D} reached the hosted pane after "
            + "retrying. Buttons found on the last attempt: "
            + "\(lastAll.map { axAttribute($0, "accessibilityLabel") as? String ?? "nil" })")
    }
}
