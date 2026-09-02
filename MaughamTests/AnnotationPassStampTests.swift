import XCTest
import MaughamCore
@testable import Maugham

/// **The active pass reaches the queue** (M3 P2 Task 8).
///
/// Three separable things, and each is tested at the level it lives at:
///
/// 1. **The stamp.** A note created while a pass is active carries that pass's
///    id on its creation op's provenance — from the editor's review toolbar and
///    from the four MCP creation tools alike. Created with no pass active, or
///    against a piece the editor does not have open, it carries nothing. That
///    nil is a designed answer, not a gap: see `activeReviewPassId`.
/// 2. **The filter.** Selecting a pass shows the notes written under it AND
///    every unstamped note — legacy notes, and notes written outside any pass,
///    belong to every pass's queue rather than to none (spec). Pure, so the
///    truth table needs no pane.
/// 3. **The wiring.** The pure rules are worth nothing if the surfaces do not
///    call them, and each of those wirings has no other guard.
///
/// Tripwire 8: paragraph ids here cross the `.md` ↔ op log boundary, so they
/// come from the document's own `sequence` or from the 4-char alphabet.
@MainActor
final class AnnotationPassStampTests: XCTestCase {

    // MARK: - Fixture

    private struct Fixture {
        let projectURL: URL
        let docPath: String
        let docId: String
        let projectStore: ProjectStore
        let documentStore: DocumentStore
        let registry: ProjectRegistry
        let projectId: String
    }

    /// A one-document project, registered so the MCP helpers can resolve it.
    /// `PresenterRoutingTests.makeProject`'s shape.
    private func makeProject(
        initialMd: String = "<!-- ¶a3f9 -->\n\nFirst.\n\n<!-- ¶b21c -->\n\nSecond.\n",
        docId: String = "doc-pass-stamp",
        passes: [ReviewPass] = []
    ) async throws -> Fixture {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("APS-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        let docPath = "manuscript/c1.md"
        try initialMd.write(
            to: tmp.appendingPathComponent(docPath),
            atomically: true, encoding: .utf8)

        let item = StructureItem(
            id: docId, title: "C1", type: .document, path: docPath)
        var manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [item], research: [])
        manifest.reviewPasses = passes
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let projectStore = try await ProjectStore.load(from: tmp)
        let documentStore = try await DocumentStore.open(url: tmp)
        projectStore.documentStore = documentStore
        let registry = ProjectRegistry()
        registry.register(url: tmp, store: projectStore)

        return Fixture(
            projectURL: tmp, docPath: docPath, docId: docId,
            projectStore: projectStore, documentStore: documentStore,
            registry: registry, projectId: ProjectIdentifier.id(for: tmp))
    }

    /// Load the fixture's document and register it — this is what puts the MCP
    /// helper's ARM 1 (the doc is open in the editor) under the test.
    private func openDocument(_ fx: Fixture) async throws -> Document {
        let doc = try await Document.load(
            url: fx.projectURL.appendingPathComponent(fx.docPath),
            device: "test", session: "s", presenter: fx.documentStore.presenter)
        fx.documentStore.register(document: doc, for: fx.docPath)
        return doc
    }

    private func craftNotes(in doc: Document) -> [Annotation] {
        doc.annotations(filter: AnnotationFilter(statuses: nil))
            .filter { $0.kind == .craftNote }
    }

    private func note(
        _ id: String, pass: String?, paragraph: String? = "a3f9"
    ) -> Annotation {
        Annotation(
            id: id, kind: .comment, paragraphId: paragraph,
            body: "body", suggestedText: nil, priorText: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdBySession: nil, status: .open, userResponse: nil,
            resolvedAt: nil, isStale: false, reviewPassId: pass)
    }

    // MARK: - 1. The stamp, at the Document funnel

    func test_aReviewerNoteCreatedUnderAPassCarriesThatPass() async throws {
        let fx = try await makeProject()
        let doc = try await openDocument(fx)
        let paragraphId = try XCTUnwrap(doc.sequence.first)

        _ = try await doc.addReviewerAnnotation(
            kind: .comment, paragraphId: paragraphId, span: nil,
            body: "tighten this", authorName: "Denver",
            reviewPassId: "line")

        let created = try XCTUnwrap(
            doc.annotations(filter: AnnotationFilter(statuses: nil)).first)
        XCTAssertEqual(created.reviewPassId, "line")
        await doc.close()
    }

    /// The default is nil at the funnel itself, so every caller that has not
    /// been taught about passes keeps writing unstamped notes rather than
    /// inventing one.
    func test_aNoteCreatedWithNoPassCarriesNone() async throws {
        let fx = try await makeProject()
        let doc = try await openDocument(fx)
        let paragraphId = try XCTUnwrap(doc.sequence.first)

        _ = try await doc.addReviewerAnnotation(
            kind: .comment, paragraphId: paragraphId, span: nil,
            body: "tighten this", authorName: "Denver")

        let created = try XCTUnwrap(
            doc.annotations(filter: AnnotationFilter(statuses: nil)).first)
        XCTAssertNil(created.reviewPassId)
        await doc.close()
    }

    // MARK: - 2. Resolving the stamp for an MCP call

    /// ARM 1 — the piece is open in the editor, so the window's remembered
    /// active pass for it is reachable and the note is stamped.
    func test_mcpResolution_stampsWhenThePieceIsOpenAndHasAnActivePass() async throws {
        let fx = try await makeProject()
        let doc = try await openDocument(fx)
        fx.documentStore.updateUIState {
            $0.activePassMemory.record(piece: fx.docId, passId: "copyedit")
        }

        XCTAssertEqual(
            activeReviewPassId(projectId: fx.projectId, documentId: fx.docId,
                               registry: fx.registry),
            "copyedit")
        await doc.close()
    }

    /// ARM 2 — the piece is not open. There is no window, so there is no
    /// active pass to read, and the note is written unstamped BY DESIGN
    /// (M5-AN-048: a craft note appended to a closed document must keep
    /// working, and it does — it simply belongs to no pass).
    func test_mcpResolution_isNilForAClosedPiece() async throws {
        let fx = try await makeProject()
        // The memory holds a pass for this piece; the piece is still closed.
        fx.documentStore.updateUIState {
            $0.activePassMemory.record(piece: fx.docId, passId: "copyedit")
        }
        XCTAssertNil(
            activeReviewPassId(projectId: fx.projectId, documentId: fx.docId,
                               registry: fx.registry))
    }

    func test_mcpResolution_isNilWhenNoPassWasEverRecorded() async throws {
        let fx = try await makeProject()
        let doc = try await openDocument(fx)
        XCTAssertNil(
            activeReviewPassId(projectId: fx.projectId, documentId: fx.docId,
                               registry: fx.registry))
        await doc.close()
    }

    /// The validated read, all the way through: a remembered pass the project
    /// no longer has is not a stamp. Writing it would put notes into a queue
    /// with no column to show them in.
    func test_mcpResolution_isNilForAPassTheProjectRetired() async throws {
        let fx = try await makeProject(
            passes: [ReviewPass(id: "line", name: "Line")])
        let doc = try await openDocument(fx)
        fx.documentStore.updateUIState {
            $0.activePassMemory.record(piece: fx.docId, passId: "structural")
        }
        XCTAssertNil(
            activeReviewPassId(projectId: fx.projectId, documentId: fx.docId,
                               registry: fx.registry))
        await doc.close()
    }

    func test_mcpResolution_isNilForAnUnknownProject() async throws {
        let fx = try await makeProject()
        XCTAssertNil(
            activeReviewPassId(projectId: "no-such-project",
                               documentId: fx.docId, registry: fx.registry))
    }

    // MARK: - 3. The stamp end-to-end through a real MCP tool

    func test_addComment_stampsTheOpenPiecesActivePass() async throws {
        let fx = try await makeProject()
        let doc = try await openDocument(fx)
        let paragraphId = try XCTUnwrap(doc.sequence.first)
        fx.documentStore.updateUIState {
            $0.activePassMemory.record(piece: fx.docId, passId: "proof")
        }

        let params = Data("""
        {"project_id":"\(fx.projectId)","document_id":"\(fx.docId)",
         "paragraph_id":"\(paragraphId)","body":"a note"}
        """.utf8)
        _ = try await AddCommentTool.handle(paramsJSON: params, registry: fx.registry)

        let created = try XCTUnwrap(
            doc.annotations(filter: AnnotationFilter(statuses: nil))
                .first { $0.kind == .comment })
        XCTAssertEqual(created.reviewPassId, "proof")
        await doc.close()
    }

    func test_addCraftNote_stampsTheOpenPiecesActivePass() async throws {
        let fx = try await makeProject()
        let doc = try await openDocument(fx)
        fx.documentStore.updateUIState {
            $0.activePassMemory.record(piece: fx.docId, passId: "line")
        }

        let params = Data("""
        {"project_id":"\(fx.projectId)","document_id":"\(fx.docId)",
         "body":"her voice never apologises"}
        """.utf8)
        _ = try await AddCraftNoteTool.handle(paramsJSON: params, registry: fx.registry)

        XCTAssertEqual(craftNotes(in: doc).first?.reviewPassId, "line")
        await doc.close()
    }

    /// The closed-doc arm, driven through the tool that is pinned to work on a
    /// closed document (M5-AN-048). It still works, and the note it writes
    /// carries no pass.
    func test_addCraftNote_toAClosedPiece_writesAnUnstampedNote() async throws {
        let fx = try await makeProject()
        fx.documentStore.updateUIState {
            $0.activePassMemory.record(piece: fx.docId, passId: "line")
        }

        let params = Data("""
        {"project_id":"\(fx.projectId)","document_id":"\(fx.docId)",
         "body":"written with the piece closed"}
        """.utf8)
        _ = try await AddCraftNoteTool.handle(paramsJSON: params, registry: fx.registry)

        // Open it afterwards and read what landed in the op log.
        let doc = try await openDocument(fx)
        let created = try XCTUnwrap(craftNotes(in: doc).first)
        XCTAssertEqual(created.body, "written with the piece closed",
                       "M5-AN-048: the closed-doc append still works")
        XCTAssertNil(created.reviewPassId)
        await doc.close()
    }

    // MARK: - 4. The pass filter (pure)

    func test_selectingAPassShowsTheNotesWrittenUnderIt() {
        XCTAssertTrue(AnnotationPassFilter.matches(note("a", pass: "line"), passId: "line"))
    }

    /// The spec's rule, and the one that keeps the feature from hiding a
    /// writer's existing work the day it ships: an unstamped note is in EVERY
    /// pass's queue.
    func test_anUnstampedNoteIsInEveryPassesQueue() {
        for pass in ReviewPass.presets {
            XCTAssertTrue(
                AnnotationPassFilter.matches(note("a", pass: nil), passId: pass.id),
                "an unstamped note must show under \(pass.id)")
        }
    }

    func test_aNoteFromAnotherPassIsHidden() {
        XCTAssertFalse(
            AnnotationPassFilter.matches(note("a", pass: "structural"), passId: "line"))
    }

    func test_allPassesShowsEverything() {
        XCTAssertTrue(AnnotationPassFilter.matches(note("a", pass: "structural"), passId: nil))
        XCTAssertTrue(AnnotationPassFilter.matches(note("b", pass: nil), passId: nil))
    }

    /// **The coach's lane is never filtered out** (editorial letter P1,
    /// Task 6, controller ruling 1).
    ///
    /// Her notes are stamped with her own lane id, and she is deliberately
    /// not a selectable lane — she is not in `effectiveReviewPasses`, so the
    /// toolbar's pass menu cannot offer her and `AnnotationPassFilter.resolved`
    /// can never answer her id. Filter her out under a stage and there is NO
    /// selection left that brings her back: assign a coached piece to a pass
    /// and every letter she wrote about it disappears from the queue, with
    /// no control on screen to say why. So her stamp behaves like an
    /// unstamped note: in every pass's queue.
    func test_theCoachsNotesSurviveEveryFilterValue() {
        let letter = note("a", pass: ReviewPass.coachPreset.id)
        XCTAssertTrue(
            AnnotationPassFilter.matches(letter, passId: "line"),
            "a coached piece assigned to Line must keep her letter in view")
        for pass in ReviewPass.presets {
            XCTAssertTrue(AnnotationPassFilter.matches(letter, passId: pass.id),
                          "her notes must show under \(pass.id)")
        }
        XCTAssertTrue(AnnotationPassFilter.matches(letter, passId: nil),
                      "and under every pass")
    }

    /// The control for the rule above: a STAGE's stamp is still hidden under
    /// another stage. The coach's exemption is hers alone, and a filter that
    /// stopped filtering would pass the test above for the wrong reason.
    func test_aStageStampIsStillHiddenUnderAnotherStage() {
        XCTAssertFalse(
            AnnotationPassFilter.matches(note("a", pass: "line"), passId: "structural"))
    }

    // MARK: - 5. What the queue defaults to

    /// The end of the board's click-through (P1 wires the chip to record the
    /// pass, then open the piece): the writer lands in the queue already
    /// filtered to the pass they clicked.
    func test_theDefaultSelectionIsThePiecesActivePass() {
        var memory = ActivePassMemory.empty
        memory.record(piece: "piece-1", passId: "copyedit")
        XCTAssertEqual(
            AnnotationPassFilter.resolved(
                .followActivePass, piece: "piece-1",
                memory: memory, passes: ReviewPass.presets),
            "copyedit")
    }

    func test_aPieceWithNoActivePassDefaultsToAllPasses() {
        XCTAssertNil(AnnotationPassFilter.resolved(
            .followActivePass, piece: "piece-1",
            memory: .empty, passes: ReviewPass.presets))
    }

    /// Project scope has no single piece to take an active pass from, so the
    /// default there is the whole project's notes. An explicit choice still
    /// applies across every piece — see the next test.
    func test_projectScopeWithNoPieceDefaultsToAllPasses() {
        var memory = ActivePassMemory.empty
        memory.record(piece: "piece-1", passId: "copyedit")
        XCTAssertNil(AnnotationPassFilter.resolved(
            .followActivePass, piece: nil,
            memory: memory, passes: ReviewPass.presets))
    }

    func test_anExplicitChoiceBeatsThePiecesActivePass() {
        var memory = ActivePassMemory.empty
        memory.record(piece: "piece-1", passId: "copyedit")
        XCTAssertEqual(
            AnnotationPassFilter.resolved(
                .pass("proof"), piece: "piece-1",
                memory: memory, passes: ReviewPass.presets),
            "proof")
        XCTAssertNil(AnnotationPassFilter.resolved(
            .allPasses, piece: "piece-1",
            memory: memory, passes: ReviewPass.presets))
    }

    /// An explicit choice survives having no piece at all — this is what makes
    /// the pass filter apply across pieces in project scope.
    func test_anExplicitChoiceAppliesWithNoPiece() {
        XCTAssertEqual(
            AnnotationPassFilter.resolved(
                .pass("proof"), piece: nil, memory: .empty,
                passes: ReviewPass.presets),
            "proof")
    }

    /// `effectiveAuthorFilter`'s self-healing shape: a selection whose pass the
    /// writer has since removed from the project would otherwise hide every
    /// stamped note with no control left to say so.
    func test_aSelectionOfARetiredPassHealsToAllPasses() {
        XCTAssertNil(AnnotationPassFilter.resolved(
            .pass("structural"), piece: nil, memory: .empty,
            passes: [ReviewPass(id: "line", name: "Line")]))
    }

    func test_theDefaultForARetiredActivePassIsAllPasses() {
        var memory = ActivePassMemory.empty
        memory.record(piece: "piece-1", passId: "structural")
        XCTAssertNil(AnnotationPassFilter.resolved(
            .followActivePass, piece: "piece-1", memory: memory,
            passes: [ReviewPass(id: "line", name: "Line")]))
    }

    // MARK: - 6. The wirings, which nothing else guards

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
        return try String(
            contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The read rule has ONE spelling. Every production reader calls
    /// `validatedActivePass`; nobody re-derives "is this stored id still a
    /// pass?" inline. The two known re-spellings a reader might reach for are
    /// a `contains(where:)` over the pass list next to an `activePass(` call,
    /// and a `firstIndex(where:)` doing the same job.
    func test_theValidatedReadIsTheOnlyProductionSpellingOfTheRule() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Maugham", isDirectory: true)
        let walker = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var rawReaders: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if code.contains("activePass(forPiece:") || code.contains(".activePass(forPiece") {
                rawReaders.insert(url.lastPathComponent)
            }
        }
        XCTAssertEqual(
            rawReaders, ["ActivePassMemory.swift"],
            "the raw read belongs to the type that owns it; every other reader "
                + "goes through validatedActivePass")
    }

    /// The editor's review toolbar stamps. Without this line a note written
    /// from the margin — the commonest way a writer makes one — belongs to no
    /// pass, and nothing else in the suite would notice.
    func test_theEditorsCreationHandlerPassesTheActivePass() throws {
        let text = try source("Maugham/Views/EditorHost.swift")
        XCTAssertTrue(text.contains("reviewPassId: activeReviewPassId("),
                      "EditorHost's createAnnotationHandler must stamp the pass")
        let window = try source("Maugham/Views/ProjectWindow.swift")
        XCTAssertTrue(window.contains("activeReviewPassId:"),
                      "ProjectWindow must thread the resolver into EditorHost")
    }

    /// All four MCP creation tools, not three. The stamp is per call site, so
    /// a fifth tool added without it would write unstamped notes silently.
    func test_everyMCPCreationToolStamps() throws {
        let text = try source("Maugham/MCP/Tools/AnnotationCreationTools.swift")
        XCTAssertEqual(
            text.components(separatedBy: "reviewPassId: activePass").count - 1, 4,
            "each of add_comment / add_suggested_change / add_query / "
                + "add_craft_note resolves and passes the active pass")
        XCTAssertEqual(
            text.components(separatedBy: "activeReviewPassId(").count - 1, 4)
    }

    /// The pane calls both pure rules. Either one uncalled is a feature that
    /// passes its own truth table and does nothing on screen.
    func test_thePaneAppliesTheFilterAndRendersTheNudge() throws {
        let text = try source("Maugham/Views/AnnotationsPane.swift")
        XCTAssertTrue(text.contains("AnnotationPassFilter.matches"),
                      "the pass filter must join the pane's filter chain")
        XCTAssertTrue(text.contains("AnnotationPassFilter.resolved"),
                      "the pane's selection must resolve through the one rule")
        // `advice`, not `openEarlierPass`: the nudge derives from the piece's
        // recorded active pass, and its entry point takes no filter selection
        // (fix round 1 — `PassOrderAdviceTests` owns that truth table and the
        // pane-side census that the two stay uncoupled).
        XCTAssertTrue(text.contains("PassOrderAdvice.advice("),
                      "the advisory nudge must be rendered")
    }

    /// Reading pass states is fine; WRITING them is a closed set
    /// (`PersonaPaneRegistryTests.passStateWritingFiles`), and this file must
    /// never become a fourth member of it.
    ///
    /// **The nudge gained verbs (2026-08-19) without gaining the write.**
    /// Mark done / Skip route through `onSetPassState`, a closure the host
    /// supplies — so this pane calls THAT, never `store.setPassState`
    /// directly. The negative half (no literal `setPassState` call) is what
    /// keeps the file out of the census; the positive half (the closure IS
    /// wired into the nudge) is what keeps the verbs from being dead code.
    func test_theNudgeRoutesItsVerbsThroughTheClosureAndNeverCallsSetPassStateDirectly() throws {
        let pane = try source("Maugham/Views/AnnotationsPane.swift")
        XCTAssertFalse(pane.contains("setPassState"),
                       "the queue may let the writer rule on a pass, but only "
                       + "through the host's closure — a direct call here "
                       + "would make this file a fourth member of "
                       + "PersonaPaneRegistryTests.passStateWritingFiles")
        XCTAssertTrue(pane.contains("onSetPassState("),
                      "the nudge's Mark done / Skip buttons must call the "
                      + "threaded closure — without this the verbs compile "
                      + "but do nothing")
        let advice = try source("Maugham/Views/PassOrderAdvice.swift")
        XCTAssertFalse(advice.contains("setPassState"))
    }
}
