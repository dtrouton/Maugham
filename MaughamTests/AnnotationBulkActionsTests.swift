import XCTest
@testable import MaughamCore
@testable import Maugham

/// **Bulk operations over the queue** (M3 P2 Task 5). A writer who has just
/// triaged forty notes should not have to click forty times to act on them.
///
/// Two halves, and the split is the point:
///
/// - `AnnotationBulkActions.plan` is PURE — the truth table of which notes a
///   verb honestly reaches is assertable without mounting `AnnotationsPane`,
///   which is what lets the bar promise "Accept 4 of 6" before it acts.
/// - `AnnotationBulkActions.perform` runs on a real `Document`, sequentially,
///   one verb per note. What that costs and what it buys is pinned here rather
///   than asserted in prose: a bulk stet leaves one undo step PER NOTE, and a
///   bulk accept of suggestions leaves exactly ONE, because
///   `acceptAnnotation`'s `removeAllActions` choreography (ADR 0023 D1) clears
///   the stack on the way in and no wrapper may change that.
@MainActor
final class AnnotationBulkActionsTests: XCTestCase {

    // MARK: - Pure fixtures (no Document)

    // Tripwire 8: 4-char ids from `[0-9a-hjkmnp-tv-z]` — these cross the
    // `.md` ↔ op log boundary in production even though this half is pure.
    private func note(
        id: String,
        kind: AnnotationKind = .comment,
        status: AnnotationStatus = .open,
        triage: TriageMark? = nil,
        isStale: Bool = false
    ) -> Annotation {
        Annotation(
            id: id, kind: kind, paragraphId: "aaaa",
            body: "body", suggestedText: kind == .suggestedChange ? "x" : nil,
            priorText: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdBySession: nil, status: status, userResponse: nil,
            resolvedAt: nil, isStale: isStale, triage: triage)
    }

    // MARK: - plan: accept

    /// Accept reaches exactly where the row's own Accept reaches. A resolved
    /// row does not offer it at all (`AnnotationRow.showsReopen` replaces the
    /// dispositions with Reopen), so neither does the bar.
    func test_acceptPlansOpenNotesAndSkipsEveryResolution() {
        let notes = [
            note(id: "aaaa", status: .open),
            note(id: "bbbb", status: .accepted),
            note(id: "cccc", status: .rejected),
            note(id: "dddd", status: .archived),
            note(id: "eeee", status: .stetted),
        ]
        XCTAssertEqual(
            AnnotationBulkActions.plan(notes, verb: .accept), ["aaaa"])
    }

    /// A STALE suggestion is skipped, and this is the prose-safety arm: the
    /// row's Accept gates a stale suggestion behind an "Apply anyway" confirm
    /// (it would overwrite text the writer has since edited), and a bulk run
    /// cannot ask forty times. Skipping leaves that note exactly where it was —
    /// still open, still one click away from the confirm it deserves.
    func test_acceptSkipsAStaleSuggestionBecauseTheRowWouldHaveAskedFirst() {
        let notes = [
            note(id: "aaaa", kind: .suggestedChange, isStale: true),
            note(id: "bbbb", kind: .suggestedChange, isStale: false),
        ]
        XCTAssertEqual(
            AnnotationBulkActions.plan(notes, verb: .accept), ["bbbb"])
    }

    /// …and only for a SUGGESTION. The row's gate is
    /// `kind == .suggestedChange && isStale`; a stale comment has no
    /// replacement text to misplace, so "Got it" applies to it unasked.
    func test_aStaleCommentIsStillAccepted() {
        let notes = [
            note(id: "aaaa", kind: .comment, isStale: true),
            note(id: "bbbb", kind: .craftNote, isStale: true),
        ]
        XCTAssertEqual(
            AnnotationBulkActions.plan(notes, verb: .accept),
            ["aaaa", "bbbb"])
    }

    /// **A query is never in an accept plan.** Its row has no Accept affordance
    /// at all — `AnnotationRow.dispositions`' `.query` case offers *Reply…*,
    /// which opens a sheet and calls `acceptAnnotation(id:userResponse:)` with
    /// the writer's own words. Bulk accept would call it with
    /// `userResponse: nil`: the question leaves the default `[.open]` queue
    /// with the empty answer recorded against it, and `.accepted` has no
    /// Reopen arm. (Denver's 2026-08-18 ruling made a textless accept
    /// undoable, so ⌘Z is now a way back — but only for a writer who notices
    /// in the same breath, which is not what a batch of forty affords.) Reply
    /// is the verb; a reply is text; text is what a batch cannot supply.
    func test_aQueryIsNeverInAnAcceptPlan() {
        let notes = [
            note(id: "aaaa", kind: .query),
            note(id: "bbbb", kind: .query, isStale: true),
            note(id: "cccc", kind: .comment),
        ]
        XCTAssertEqual(
            AnnotationBulkActions.plan(notes, verb: .accept), ["cccc"])
    }

    /// …and the OTHER verbs still reach it. Excluding the query from accept is
    /// about Reply being the query's verb, not about queries being untouchable:
    /// a writer can still stet a question ("read, considered, no change") or
    /// mark it `discuss` in bulk. Without this control the accept fix could
    /// quietly become "bulk skips queries", which is a different rule.
    func test_theOtherVerbsStillReachAQuery() {
        let notes = [note(id: "aaaa", kind: .query)]
        XCTAssertEqual(AnnotationBulkActions.plan(notes, verb: .stet), ["aaaa"])
        XCTAssertEqual(
            AnnotationBulkActions.plan(notes, verb: .triage(.discuss)), ["aaaa"])
    }

    // MARK: - plan: stet

    /// Stet is a resolution like the others: the row offers it on an open note
    /// and offers Reopen instead once the note is settled. An already-stetted
    /// note is the special case the brief names, and it falls out of the same
    /// rule rather than being a clause of its own.
    func test_stetPlansOpenNotesOnly_theStettedOneAmongThem() {
        let notes = [
            note(id: "aaaa", status: .open),
            note(id: "bbbb", status: .stetted),
            note(id: "cccc", status: .archived),
            note(id: "dddd", status: .open, isStale: true),
        ]
        XCTAssertEqual(
            AnnotationBulkActions.plan(notes, verb: .stet), ["aaaa", "dddd"],
            "staleness gates nothing here — a stet moves no text")
    }

    // MARK: - plan: triage

    /// A mark is not a resolution (`triageAnnotation`'s own doc comment): a
    /// resolved note takes one too, deliberately. So triage reaches every row
    /// the queue is showing…
    func test_triageReachesEveryStatus() {
        let notes = [
            note(id: "aaaa", status: .open),
            note(id: "bbbb", status: .accepted),
            note(id: "cccc", status: .stetted),
        ]
        XCTAssertEqual(
            AnnotationBulkActions.plan(notes, verb: .triage(.do)),
            ["aaaa", "bbbb", "cccc"])
    }

    /// …except the one place the ROW itself refuses. The row's triage menu
    /// disables the mark a note already holds, because re-applying it appends
    /// an op whose ⌘Z undoes nothing the writer can see. Forty of those is the
    /// same defect forty times over, so the plan declines them and the count
    /// says how many it declined.
    func test_triageSkipsANoteThatAlreadyCarriesThatMark() {
        let notes = [
            note(id: "aaaa", triage: .do),
            note(id: "bbbb", triage: .decline),
            note(id: "cccc", triage: nil),
        ]
        XCTAssertEqual(
            AnnotationBulkActions.plan(notes, verb: .triage(.do)),
            ["bbbb", "cccc"])
    }

    /// Clearing is the same rule with `nil` as the target mark: an untriaged
    /// note has nothing to clear.
    func test_clearingSkipsTheAlreadyUntriaged() {
        let notes = [
            note(id: "aaaa", triage: .do),
            note(id: "bbbb", triage: nil),
        ]
        XCTAssertEqual(
            AnnotationBulkActions.plan(notes, verb: .triage(nil)), ["aaaa"])
    }

    // MARK: - The bar's own words

    /// The count is honest before the click, which is the whole reason `plan`
    /// is separable: "Accept all 6" when it means six, "Accept 4 of 6" the
    /// moment two of them are out of reach.
    func test_theButtonSaysWhatItWillActuallyDo() {
        XCTAssertEqual(
            AnnotationBulkActions.buttonTitle(
                .accept, planned: 6, targetCount: 6, hasSelection: false),
            "Accept all 6")
        XCTAssertEqual(
            AnnotationBulkActions.buttonTitle(
                .accept, planned: 3, targetCount: 3, hasSelection: true),
            "Accept 3 selected")
        XCTAssertEqual(
            AnnotationBulkActions.buttonTitle(
                .accept, planned: 4, targetCount: 6, hasSelection: false),
            "Accept 4 of 6")
        XCTAssertEqual(
            AnnotationBulkActions.buttonTitle(
                .accept, planned: 0, targetCount: 6, hasSelection: true),
            "Accept 0 of 6",
            "a verb that reaches nothing says so rather than lying about six")
        XCTAssertEqual(
            AnnotationBulkActions.buttonTitle(
                .stet, planned: 2, targetCount: 2, hasSelection: true),
            "Stet 2 selected")
        XCTAssertEqual(
            AnnotationBulkActions.buttonTitle(
                .triage(.do), planned: 5, targetCount: 7, hasSelection: false),
            "Do 5 of 7")
        XCTAssertEqual(
            AnnotationBulkActions.buttonTitle(
                .triage(nil), planned: 1, targetCount: 1, hasSelection: false),
            "Clear all 1")
    }

    // MARK: - The summary notice

    /// A clean run says nothing. A notice on every batch would make the one
    /// that matters invisible by making it ordinary (the stet-undo decline's
    /// control, in the bar's key).
    func test_aCleanRunPostsNoNotice() {
        let outcome = AnnotationBulkActions.Outcome(
            verb: .accept, succeeded: ["aaaa", "bbbb"])
        XCTAssertNil(outcome.notice)
    }

    /// One notice for the whole batch, never an alert per item — and never
    /// silence. It counts what happened, says why the rest did not, and points
    /// at the recourse.
    func test_anchorLostFailuresCollectIntoOneSummary() throws {
        let outcome = AnnotationBulkActions.Outcome(
            verb: .accept, succeeded: ["aaaa", "bbbb"], anchorLost: ["cccc"])
        let notice = try XCTUnwrap(outcome.notice)
        XCTAssertTrue(notice.hasPrefix("2 of 3 accepted."), notice)
        XCTAssertTrue(notice.contains("no longer in its paragraph"), notice)
        XCTAssertTrue(notice.contains("stay open"), notice)
    }

    func test_anUnexpectedFailureIsCountedTooRatherThanSwallowed() throws {
        let outcome = AnnotationBulkActions.Outcome(
            verb: .stet, succeeded: ["aaaa"], failed: ["bbbb", "cccc"])
        let notice = try XCTUnwrap(outcome.notice)
        XCTAssertTrue(notice.hasPrefix("1 of 3 stetted."), notice)
        XCTAssertTrue(notice.contains("2"), notice)
    }

    // MARK: - Integration harness

    private struct Harness {
        let doc: Document
        let pids: [String]
    }

    private func makeHarness(
        prefix: String, initialMd: String = "One.\n\nTwo.\n\nThree.\n"
    ) async throws -> Harness {
        let (_, docURL) = try makeTestProject(prefix: prefix, initialMd: initialMd)
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        return Harness(doc: doc, pids: doc.sequence)
    }

    /// Across ALL statuses — `annotations()` defaults to `[.open]`, which hides
    /// the very notes under test (M5-AN-002, the documented footgun).
    private func status(_ doc: Document, _ id: String) -> AnnotationStatus? {
        doc.annotations(filter: AnnotationFilter(statuses: nil))
            .first { $0.id == id }?.status
    }

    private func triage(_ doc: Document, _ id: String) -> TriageMark? {
        doc.annotations(filter: AnnotationFilter(statuses: nil))
            .first { $0.id == id }?.triage
    }

    /// One `⌘Z` over a coalesced batch fires SEVERAL undo closures, each hopping
    /// its op-log append onto a fresh task — and `_lastUndoWorkTask` only holds
    /// the most recent one, so a single `awaitPendingUndoWork()` can return with
    /// its siblings still in flight. Drain them.
    private func settle(_ doc: Document) async {
        for _ in 0..<6 {
            await doc.awaitPendingUndoWork()
            await Task.yield()
        }
    }

    private func threeComments(_ h: Harness) async throws -> [String] {
        var ids: [String] = []
        for pid in h.pids {
            ids.append(try await h.doc.addAnnotation(
                kind: .comment, paragraphId: pid, body: "note on \(pid)"))
        }
        return ids
    }

    // MARK: - Integration: bulk stet

    /// Three notes, three stets, **three separate undo registrations** — and
    /// the executor opens no group of its own, by ruling (a group would have to
    /// cover accept too, and accept clears the stack from inside: ADR 0023 D1).
    ///
    /// What that costs the writer in ⌘Z presses is `NSUndoManager`'s decision,
    /// not the executor's: `groupsByEvent` coalesces registrations made within
    /// one event into a single top-level group, and it does so here — ONE ⌘Z
    /// reopens the batch. That is the behaviour a writer wants from one
    /// deliberate click, so nothing fights it; the plan's "⌘Z peels one at a
    /// time" was written against a premise the platform does not hold to.
    ///
    /// The per-note registration is still the load-bearing claim, and it is
    /// asserted where it is visible: **three** compensating `annotationReopen`
    /// ops are appended, one per note (ADR 0023 — undo appends, never
    /// truncates). A single batch-wide inverse would append one.
    func test_bulkStetSettlesEachNoteAndRegistersItsOwnCompensatingUndo() async throws {
        let h = try await makeHarness(prefix: "Bulk-Stet")
        let ids = try await threeComments(h)
        let um = UndoManager()

        let outcome = await AnnotationBulkActions.perform(
            .stet, on: ids, in: h.doc, undoManager: um)

        XCTAssertEqual(outcome.succeeded, ids)
        XCTAssertNil(outcome.notice, "a clean run is quiet")
        for id in ids {
            XCTAssertEqual(status(h.doc, id), .stetted)
        }
        XCTAssertEqual(h.doc.annotations().count, 0,
                       "all three have left the open queue")
        XCTAssertEqual(
            h.doc._opLogMirror.filter { $0.kind == .annotationStet }.count, 3)

        XCTAssertTrue(um.canUndo)
        um.undo()
        await settle(h.doc)

        XCTAssertEqual(h.doc.annotations().count, 3, "all three are back")
        for id in ids {
            XCTAssertEqual(status(h.doc, id), .open)
        }
        XCTAssertEqual(
            h.doc._opLogMirror.filter { $0.kind == .annotationReopen }.count, 3,
            "one compensating op per note — three registrations ran, not one")
        XCTAssertTrue(
            h.doc._opLogMirror.filter { $0.kind == .annotationStet }.count == 3,
            "the stets themselves survive their own undo")
        XCTAssertFalse(um.canUndo,
                       "NSUndoManager coalesced the batch into one event group")
    }

    // MARK: - Integration: bulk accept over textless notes

    /// **Minor 7 (2026-08-18 review) — the stet test's shape, for accept.**
    /// Accepting three comments registers three undo actions where it used to
    /// register none, and `NSUndoManager` coalesces them the way it coalesces
    /// three stets: ONE ⌘Z puts all three back open, three compensating
    /// `annotationReopen` ops appended, nothing truncated. No `removeAllActions`
    /// runs on this path — that is the suggestion arm's — so nothing wipes
    /// anything and the batch is whole.
    func test_bulkAcceptOverTextlessNotesCoalescesToOneUndo() async throws {
        let h = try await makeHarness(prefix: "Bulk-AcceptNotes")
        let ids = try await threeComments(h)
        let um = UndoManager()

        let outcome = await AnnotationBulkActions.perform(
            .accept, on: ids, in: h.doc, undoManager: um)

        XCTAssertEqual(outcome.succeeded, ids)
        XCTAssertNil(outcome.notice, "a clean run is quiet")
        for id in ids { XCTAssertEqual(status(h.doc, id), .accepted) }
        XCTAssertEqual(h.doc.annotations().count, 0,
                       "all three have left the open queue")

        XCTAssertTrue(um.canUndo,
                      "a batch of textless accepts registered nothing at all "
                      + "before Denver's 2026-08-18 ruling")
        um.undo()
        await settle(h.doc)

        XCTAssertEqual(h.doc.annotations().count, 3, "all three are back")
        for id in ids { XCTAssertEqual(status(h.doc, id), .open) }
        XCTAssertEqual(
            h.doc._opLogMirror.filter { $0.kind == .annotationReopen }.count, 3,
            "one compensating op per note — three registrations ran, not one")
        XCTAssertEqual(
            h.doc._opLogMirror.filter { $0.kind == .claudeAccept }.count, 3,
            "the accepts themselves survive their own undo")
        XCTAssertFalse(um.canUndo,
                       "NSUndoManager coalesced the batch into one event group")
    }

    /// **Important 4 (2026-08-18 review) — the mixed batch, and why `plan`
    /// reorders it.** The Accept tooltip promises "⌘Z reverses the batch —
    /// except for accepted suggestions, where it reaches only the last; use a
    /// row's Revert for the others." In queue order a `[comment, suggestion]`
    /// batch broke both halves of that for the comment: the suggestion's
    /// `removeAllActions` wiped the comment's fresh registration, and an
    /// accepted comment has no **Revert** arm on its row (that arm belongs to
    /// the suggestion) and no Reopen arm either — reachable by nothing.
    ///
    /// `plan` sorts suggestions to the FRONT, so every wipe lands before any
    /// textless accept registers. Driven through `plan` rather than a
    /// hand-ordered array, because the ordering IS the fix and a test that
    /// supplied its own order would pass with the fix reverted.
    func test_aMixedAcceptBatchLeavesTheTrailingCommentUndoable() async throws {
        let h = try await makeHarness(prefix: "Bulk-AcceptMixed")
        // Queue order: the comment FIRST, the suggestion second — the order
        // that used to strand the comment.
        let commentId = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pids[0], body: "got it")
        let suggestionId = try await h.doc.addAnnotation(
            kind: .suggestedChange, paragraphId: h.pids[1], body: "tighter",
            suggestedText: "Two, revised.")
        let asTheQueueHasThem = h.doc.annotations().sorted {
            ($0.id == commentId ? 0 : 1) < ($1.id == commentId ? 0 : 1)
        }
        XCTAssertEqual(asTheQueueHasThem.map(\.id), [commentId, suggestionId],
                       "premise: the comment comes first in the list the writer sees")

        let planned = AnnotationBulkActions.plan(asTheQueueHasThem, verb: .accept)
        XCTAssertEqual(planned, [suggestionId, commentId],
                       "the plan puts the suggestion first so its "
                       + "removeAllActions cannot reach the comment's undo")

        let um = UndoManager()
        let outcome = await AnnotationBulkActions.perform(
            .accept, on: planned, in: h.doc, undoManager: um)
        XCTAssertEqual(Set(outcome.succeeded), Set(planned))
        XCTAssertEqual(status(h.doc, commentId), .accepted)
        XCTAssertEqual(status(h.doc, suggestionId), .accepted)
        XCTAssertEqual(h.doc.paragraphs[h.pids[1]], "Two, revised.")

        XCTAssertTrue(um.canUndo,
                      "the comment's registration must have survived the "
                      + "suggestion's removeAllActions")
        um.undo()
        await settle(h.doc)

        XCTAssertEqual(status(h.doc, commentId), .open,
                       "\u{2318}Z must reach the comment \u{2014} it has no Revert "
                       + "arm and no Reopen arm, so this is its only way back")
        XCTAssertEqual(h.doc.paragraphs[h.pids[1]], "Two.",
                       "…and the one suggestion in the batch is the last one, "
                       + "which the tooltip says ⌘Z does reach")
    }

    // MARK: - Integration: bulk accept with a lost anchor

    /// The brief's second integration claim, staged exactly as production
    /// reaches it: the staleness projection LAGS a typing edit (M5-AN-005 — the
    /// pane's badge can read fresh for up to 30s), so `plan` legitimately
    /// includes a suggestion whose anchor is already gone. The lower layer
    /// refuses it (RULING-5), the run carries on, and the writer is told once.
    func test_bulkAcceptCompletesTheOthersAndReportsTheLostAnchorOnce() async throws {
        let h = try await makeHarness(
            prefix: "Bulk-AcceptLost",
            initialMd: "She was very angry about the whole business.\n\nTwo.\n\nThree.\n")
        let lost = try await h.doc.addReviewerAnnotation(
            kind: .suggestedChange, paragraphId: h.pids[0],
            span: SpanAnchor(quote: "very angry", prefix: "She was ",
                             suffix: " about the", posHint: 8),
            body: "tighter", suggestedText: "furious", authorName: "D")
        let ok1 = try await h.doc.addReviewerAnnotation(
            kind: .suggestedChange, paragraphId: h.pids[1], span: nil,
            body: "b", suggestedText: "Two, revised.", authorName: "D")
        let ok2 = try await h.doc.addReviewerAnnotation(
            kind: .suggestedChange, paragraphId: h.pids[2], span: nil,
            body: "c", suggestedText: "Three, revised.", authorName: "D")

        // The pane renders and warms the projection: nothing is stale yet.
        let asThePaneSawThem = h.doc.annotations()
        XCTAssertEqual(asThePaneSawThem.count, 3)
        XCTAssertTrue(asThePaneSawThem.allSatisfy { !$0.isStale })

        // The writer rewrites the first sentence. The cache lags (M5-AN-005),
        // so the plan below still counts all three.
        h.doc.setParagraph(
            id: h.pids[0], text: "She was livid about the whole business.")

        let planned = AnnotationBulkActions.plan(asThePaneSawThem, verb: .accept)
        XCTAssertEqual(Set(planned), Set([lost, ok1, ok2]),
                       "the advisory gate cannot see it — that is the point")

        let outcome = await AnnotationBulkActions.perform(
            .accept, on: planned, in: h.doc, undoManager: nil)

        XCTAssertEqual(outcome.anchorLost, [lost])
        XCTAssertEqual(Set(outcome.succeeded), Set([ok1, ok2]))
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertEqual(status(h.doc, lost), .open,
                       "the refused suggestion stays open — the writer may ask again")
        XCTAssertEqual(status(h.doc, ok1), .accepted)
        XCTAssertEqual(status(h.doc, ok2), .accepted)
        XCTAssertEqual(h.doc.paragraphs[h.pids[0]],
                       "She was livid about the whole business.",
                       "the writer's own sentence is untouched")
        XCTAssertEqual(h.doc.paragraphs[h.pids[1]], "Two, revised.")

        let notice = try XCTUnwrap(outcome.notice)
        XCTAssertTrue(notice.hasPrefix("2 of 3 accepted."), notice)
        XCTAssertEqual(
            notice.components(separatedBy: "no longer in its paragraph").count - 1, 1,
            "ONE summary, not one alert per refusal")
    }

    /// The consequence the bulk path inherits and must not pretend away:
    /// `acceptAnnotation` calls `removeAllActions` on every suggestion accept
    /// (the ⌘Z-EXC_BAD_ACCESS class — the native typing actions reference
    /// pre-replace text storage). Each accept therefore WIPES the previous
    /// one's registration, so a batch of three leaves exactly one undoable
    /// step: the last. Reverting the others is `Revert`'s job, per row, which
    /// reaches any accepted suggestion at any time.
    ///
    /// Pinned because the tempting "fix" — a manual undo group around the batch
    /// — is an ADR 0023 D1 violation, and because a later reader would
    /// otherwise assume the stet test's one-step-per-note claim covers accept.
    func test_bulkAcceptLeavesExactlyOneUndoStep_theLastOne() async throws {
        let h = try await makeHarness(prefix: "Bulk-AcceptUndo")
        var ids: [String] = []
        for (index, pid) in h.pids.enumerated() {
            ids.append(try await h.doc.addReviewerAnnotation(
                kind: .suggestedChange, paragraphId: pid, span: nil,
                body: "b", suggestedText: "Revised \(index).", authorName: "D"))
        }
        let um = UndoManager()

        let outcome = await AnnotationBulkActions.perform(
            .accept, on: ids, in: h.doc, undoManager: um)
        XCTAssertEqual(outcome.succeeded, ids)

        XCTAssertTrue(um.canUndo)
        um.undo()
        await h.doc.awaitPendingUndoWork()

        XCTAssertEqual(status(h.doc, ids[2]), .open, "the last accept came back")
        XCTAssertEqual(status(h.doc, ids[0]), .accepted)
        XCTAssertEqual(status(h.doc, ids[1]), .accepted)
        XCTAssertFalse(
            um.canUndo,
            "each accept cleared the one before it — this is accept's own choreography, not the bar's")
    }

    /// The same exclusion on the delivery path, where the damage would have
    /// been done: the writer's question is still open and still in the queue
    /// after a bulk Accept over a set that contains it, and the bar's own
    /// button said so before the click ("Accept 1 of 2").
    func test_aBulkAcceptLeavesTheWritersQuestionStandingAndSaysSoFirst() async throws {
        let h = try await makeHarness(prefix: "Bulk-AcceptQuery")
        let question = try await h.doc.addAnnotation(
            kind: .query, paragraphId: h.pids[0],
            body: "is this the same brother as in chapter two?")
        let remark = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pids[1], body: "nicely turned")

        let shown = h.doc.annotations()
        XCTAssertEqual(shown.count, 2)
        let planned = AnnotationBulkActions.plan(shown, verb: .accept)
        XCTAssertEqual(planned, [remark])
        XCTAssertEqual(
            AnnotationBulkActions.buttonTitle(
                .accept, planned: planned.count, targetCount: shown.count,
                hasSelection: false),
            "Accept 1 of 2",
            "the shortfall is visible before the click, not discovered after")

        let outcome = await AnnotationBulkActions.perform(
            .accept, on: planned, in: h.doc, undoManager: nil)

        XCTAssertEqual(outcome.succeeded, [remark])
        XCTAssertNil(outcome.notice, "a skip is not a failure — nothing went wrong")
        XCTAssertEqual(status(h.doc, remark), .accepted)
        XCTAssertEqual(status(h.doc, question), .open,
                       "the question is still a question")
        XCTAssertEqual(
            h.doc.annotations().map(\.id), [question],
            "and it is still in the queue, waiting for a Reply")
    }

    // MARK: - Integration: bulk triage

    /// The mark is not a resolution: the notes stay open and keep their place
    /// in the queue — only the order changes. And a second run over the same
    /// set plans nothing, because every one of them now holds the mark.
    func test_bulkTriageMarksTheBatchAndTheSecondRunHasNothingLeftToDo() async throws {
        let h = try await makeHarness(prefix: "Bulk-Triage")
        let ids = try await threeComments(h)

        let outcome = await AnnotationBulkActions.perform(
            .triage(.do), on: ids, in: h.doc, undoManager: nil)
        XCTAssertEqual(outcome.succeeded, ids)
        for id in ids {
            XCTAssertEqual(triage(h.doc, id), .do)
            XCTAssertEqual(status(h.doc, id), .open,
                           "a mark settles nothing")
        }

        XCTAssertEqual(
            AnnotationBulkActions.plan(h.doc.annotations(), verb: .triage(.do)), [],
            "nothing left for a second Do — the bar will say 0 of 3 and refuse")
    }

    /// The sharp end of per-note registration: undo restores each note's OWN
    /// prior mark rather than blanket-clearing the batch. Two of these were
    /// untriaged before the run and one was already `decline`; ⌘Z has to give
    /// each of them back exactly what it had, which a single batch-wide inverse
    /// could not do.
    func test_bulkTriageUndoRestoresEachNotesOwnPriorMark() async throws {
        let h = try await makeHarness(prefix: "Bulk-TriageUndo")
        let ids = try await threeComments(h)
        // The middle one was already `decline` before the batch.
        try await h.doc.triageAnnotation(id: ids[1], mark: .decline)
        let um = UndoManager()

        _ = await AnnotationBulkActions.perform(
            .triage(.do), on: ids, in: h.doc, undoManager: um)
        XCTAssertEqual(triage(h.doc, ids[1]), .do)

        um.undo()
        await settle(h.doc)

        XCTAssertNil(triage(h.doc, ids[0]))
        XCTAssertEqual(triage(h.doc, ids[1]), .decline,
                       "the mark it already had is not collateral damage")
        XCTAssertNil(triage(h.doc, ids[2]))
    }

    // MARK: - The verb has a face

    /// A verb with no production caller is the shape `RegionBinding.references`
    /// shipped in — correct, tested, reachable by nobody. The bar is the bulk
    /// planner's only caller, and the executor is the only place in production
    /// that loops a writer verb.
    func test_theBulkPlannerAndExecutorAreWiredToThePane() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham")
        let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100, "control: the scan found the sources")

        func callers(of call: String) -> Set<String> {
            var found: Set<String> = []
            for file in files {
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                      text.contains(call) else { continue }
                found.insert(file.lastPathComponent)
            }
            return found
        }

        XCTAssertEqual(callers(of: "AnnotationBulkActions.plan("), [
            "AnnotationsPane.swift",        // the bulk bar's honest counts
        ])
        XCTAssertEqual(callers(of: "AnnotationBulkActions.perform("), [
            "AnnotationsPane.swift",
        ], "the executor is reached from the bar and nowhere else")
    }
}
