import XCTest
import MaughamCore
@testable import Maugham

/// CHARACTERISATION of `Maugham/OpLog/Document+Rewind.swift`,
/// `Document+RewindUndo.swift` and `Deriver+Rewind.swift`.
///
/// Every assertion was written from OBSERVED output (`RewindProbe.swift`,
/// `RewindProbe2.swift`), never from what the code looked like it should do.
/// Pinned against HEAD `db1bea2c`. A failure means the behaviour CHANGED, not
/// that it is wrong — several claims pinned here are defects, pinned as such.
///
/// Claim ids `M4-RW-nnn` correspond to `experiment/reconciliation/Rewind.claims.json`.
@MainActor
final class RewindCharacterization: XCTestCase {

    // MARK: - Harness (mirrors RewindUndoTests.makeHarness)

    private struct Harness { let doc: Document; let pid: String }

    private func makeHarness(_ initialMd: String) async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RewindChar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let relativePath = "manuscript/c1.md"
        try initialMd.write(to: tmp.appendingPathComponent(relativePath),
                            atomically: true, encoding: .utf8)
        let item = StructureItem(id: "doc-x", title: "Chapter 1", type: .document,
                                 path: relativePath)
        let manifest = ProjectManifest(type: .novel, title: "Rewind Char", author: "A",
                                       created: Date(), modified: Date(),
                                       structure: [item], research: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let ds = try await DocumentStore.open(url: tmp)
        let doc = try await Document.load(url: tmp.appendingPathComponent(relativePath),
                                          device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: relativePath)
        let pid = try await doc.opLog().first { $0.kind == .bootstrap }!.changes.first!.paragraphId
        return Harness(doc: doc, pid: pid)
    }

    private func annotation(_ doc: Document, _ id: String) -> Annotation? {
        doc.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }
    }

    /// The paragraph id minted by the most recent typing burst for the
    /// paragraph whose text contains `needle`.
    private func paragraphId(in doc: Document, containing needle: String) async throws -> String {
        let burst = try await doc.opLog().last { $0.kind == .typingBurst }
        return try XCTUnwrap(burst?.changes.first { $0.next.contains(needle) }?.paragraphId)
    }

    /// A three-paragraph document with a burst boundary after each.
    private func makeThreeParagraphDoc() async throws -> (Harness, [String]) {
        let h = try await makeHarness("One.")
        h.doc.setFullText("One.\n\nTwo.\n"); try await h.doc.flushBurstNow()
        let afterTwo = try await h.doc.opLog().last!.opId
        h.doc.setFullText("One.\n\nTwo.\n\nThree.\n"); try await h.doc.flushBurstNow()
        let tip = try await h.doc.opLog().last!.opId
        let bootstrap = try await h.doc.opLog().first { $0.kind == .bootstrap }!.opId
        return (h, [bootstrap, afterTwo, tip])
    }

    // MARK: - Deriver.derive(ops:upTo:)

    /// M4-RW-001 / M4-RW-002 — `.now` is the full fold; `.atOp` is the prefix
    /// THROUGH the target, so the target op's own effect is APPLIED.
    func test_deriveUpTo_atOpIsInclusiveOfTheTargetOp() async throws {
        let (h, marks) = try await makeThreeParagraphDoc()
        let ops = try await h.doc.opLog()

        XCTAssertEqual(Deriver.derive(ops: ops, upTo: .now).sequence.count, 3)
        XCTAssertEqual(
            Deriver.derive(ops: ops, upTo: .atOp(opId: marks[0], at: Date())).sequence.count, 1,
            "at the bootstrap op: only the bootstrap paragraph")
        let atSecond = Deriver.derive(ops: ops, upTo: .atOp(opId: marks[1], at: Date()))
        XCTAssertEqual(atSecond.sequence.count, 2,
                       "at the burst that ADDED the second paragraph, that paragraph is PRESENT — "
                       + "the boundary is inclusive")
        XCTAssertTrue(atSecond.sequence.compactMap { atSecond.paragraphs[$0] }
            .contains { $0.contains("Two") })
    }

    /// M4-RW-003 — a cursor whose op is NOT in the log silently returns the
    /// FULL derivation. There is no signal of any kind that the requested
    /// moment was not found.
    func test_deriveUpTo_unknownOpId_silentlyReturnsThePresent() async throws {
        let (h, _) = try await makeThreeParagraphDoc()
        let ops = try await h.doc.opLog()

        let missing = Deriver.derive(ops: ops, upTo: .atOp(opId: "01NOSUCHOPINTHISLOG", at: Date()))
        let now = Deriver.derive(ops: ops, upTo: .now)

        XCTAssertEqual(missing.sequence, now.sequence)
        XCTAssertEqual(missing.paragraphs, now.paragraphs,
                       "a moment that does not exist derives as the present, not as a failure")
    }

    /// M4-RW-004 — an empty log derives empty under either cursor.
    func test_deriveUpTo_emptyLog_isEmptyUnderEitherCursor() {
        XCTAssertTrue(Deriver.derive(ops: [], upTo: .now).sequence.isEmpty)
        XCTAssertTrue(Deriver.derive(ops: [], upTo: .atOp(opId: "x", at: Date())).sequence.isEmpty)
    }

    // MARK: - restoreToOp: the boundary and the op it writes

    /// M4-RW-005 / M4-RW-006 / M4-RW-009 — restoring "to" an op leaves that
    /// op's effect in place, and records the restore as a `.checkpointRestore`
    /// stamped `.rewind` whose `sourceCheckpoint` is the target op id.
    func test_restoreToOp_landsAfterTheTargetOp_andStampsItsProvenance() async throws {
        let (h, marks) = try await makeThreeParagraphDoc()
        let doc = h.doc

        let r = try await doc.restoreToOp(opId: marks[1])

        XCTAssertTrue(doc.materialize().contains("Two"),
                      "the target op ADDED 'Two.'; restoring TO it leaves 'Two.' present")
        XCTAssertFalse(doc.materialize().contains("Three"))
        XCTAssertEqual(r.priorSequenceCount, 3)
        XCTAssertEqual(r.newSequenceCount, 2)
        XCTAssertEqual(r.removedParagraphIds.count, 1)

        let op = try XCTUnwrap(r.restoreOp)
        XCTAssertEqual(op.kind, .checkpointRestore)
        XCTAssertEqual(op.provenance?.synthesisSource, .rewind)
        XCTAssertEqual(op.provenance?.sourceCheckpoint, marks[1])
    }

    /// M4-RW-007 — target == tip is a genuine no-op: nothing appended, counts
    /// equal, `restoreOp` nil.
    func test_restoreToOp_targetIsTheTip_isAGenuineNoOp() async throws {
        let (h, marks) = try await makeThreeParagraphDoc()
        let doc = h.doc
        let countBefore = try await doc.opLog().count

        let r = try await doc.restoreToOp(opId: marks[2])

        XCTAssertNil(r.restoreOp)
        XCTAssertEqual(r.priorSequenceCount, r.newSequenceCount)
        XCTAssertTrue(r.removedParagraphIds.isEmpty)
        let countAfter = try await doc.opLog().count
        XCTAssertEqual(countAfter, countBefore, "the log was not extended")
    }

    /// M4-RW-008 — a target op id that is NOT IN THE LOG produces a result
    /// BYTE-IDENTICAL to the legitimate no-op above. `RewindRestoreResult` is
    /// `Equatable`, and the two compare equal: the caller cannot distinguish
    /// "there was nothing to do" from "the moment you asked for does not
    /// exist". Nothing throws.
    /// M4-RW-008 (fixed under RULING-27, 2026-08-09) — a vanished target is now
    /// DISTINGUISHABLE: the result carries `targetResolution`, so a caller can
    /// tell "your moment is gone; this is the nearest" from an honest no-op.
    func test_restoreToOp_unknownTarget_isDistinguishableAndResolvesNearest() async throws {
        let (h, marks) = try await makeThreeParagraphDoc()
        let doc = h.doc
        let textBefore = doc.materialize()

        let legitimate = try await doc.restoreToOp(opId: marks[2])       // tip: nothing to do
        let vanished = try await doc.restoreToOp(opId: "99THISOPNEVEREXISTED")

        XCTAssertEqual(legitimate.targetResolution, .exact)
        guard case .nearest(let requested, let restoredTo) = vanished.targetResolution else {
            return XCTFail("a vanished target must say so — got \(vanished.targetResolution)")
        }
        XCTAssertEqual(requested, "99THISOPNEVEREXISTED")
        XCTAssertEqual(restoredTo, marks[2],
                       "nearest surviving = the greatest opId at or before the requested moment")
        XCTAssertNotEqual(legitimate, vanished,
                          "the channel exists — the two results no longer compare equal")
        XCTAssertEqual(doc.materialize(), textBefore,
                       "nearest here IS the tip, so the text did not move")
    }

    /// RULING-27's substantive half: a vanished target that sorts into the
    /// MIDDLE of history restores to the nearest surviving moment at-or-before
    /// it — the writer's intent ('go back to roughly then') honoured
    /// approximately, never silently replaced by the present.
    func test_restoreToOp_vanishedMidHistoryTarget_restoresToNearestBefore() async throws {
        let (h, marks) = try await makeThreeParagraphDoc()
        let doc = h.doc

        // A fabricated id sorting between marks[1] (the burst that added
        // "Two.") and marks[2]: take marks[1] and bump its last character.
        var midId = marks[1]
        midId += "0"

        let r = try await doc.restoreToOp(opId: midId)

        guard case .nearest(_, let restoredTo) = r.targetResolution else {
            return XCTFail("expected .nearest, got \(r.targetResolution)")
        }
        XCTAssertEqual(restoredTo, marks[1])
        XCTAssertTrue(doc.materialize().contains("Two"))
        XCTAssertFalse(doc.materialize().contains("Three"),
                       "restored to the moment before 'Three.' existed — the nearest one")
    }

    /// M4-RW-030 — a rewind whose TEXT is unchanged but whose range contains
    /// task ops still appends a marker `.checkpointRestore` (empty changes) so
    /// `TaskDeriver` can slice at the boundary, and the pane task disappears.
    func test_restoreToOp_textUnchangedButTaskOpsPast_appendsAMarkerAndRewindsTheTask() async throws {
        let h = try await makeHarness("One.")
        let doc = h.doc
        try await doc.flushBurstNow()
        let beforeTask = try await doc.opLog().last!.opId
        let task = doc.createPaneTask(body: "remember this", parentTaskId: nil)
        try await doc.flushBurstNow()
        let filter = TaskFilter(scope: .project, statuses: [.open])
        XCTAssertTrue(doc.tasks(filter: filter).contains { $0.id == task.id })
        let textBefore = doc.materialize()

        let r = try await doc.restoreToOp(opId: beforeTask)

        XCTAssertEqual(doc.materialize(), textBefore, "no manuscript text changed")
        let op = try XCTUnwrap(r.restoreOp, "a marker op IS appended")
        XCTAssertTrue(op.changes.isEmpty, "the marker carries no paragraph changes")
        XCTAssertTrue(r.rewoundTaskOps)
        XCTAssertFalse(doc.tasks(filter: filter).contains { $0.id == task.id },
                       "the pane task is rewound out of the derivation")
    }

    // MARK: - The words: RULING-24's tier 1 mechanism

    /// M4-RW-010 / M4-RW-011 — the log is append-only across a rewind, and the
    /// pre-rewind text is exactly recoverable by deriving at the old tip.
    func test_rewind_isAppendOnly_andThePreRewindWordsStayDerivable() async throws {
        let (h, marks) = try await makeThreeParagraphDoc()
        let doc = h.doc
        let opsBefore = try await doc.opLog()
        let preTip = marks[2]
        let preWords = doc.sequence.compactMap { doc.paragraph(id: $0) }
        XCTAssertEqual(preWords, ["One.", "Two.", "Three."])

        _ = try await doc.restoreToOp(opId: marks[0])
        XCTAssertEqual(doc.sequence.compactMap { doc.paragraph(id: $0) }, ["One."])

        let opsAfter = try await doc.opLog()
        XCTAssertTrue(opsBefore.allSatisfy { b in opsAfter.contains { $0.opId == b.opId } },
                      "every pre-rewind op survives")
        XCTAssertGreaterThan(opsAfter.count, opsBefore.count, "the log only grew")

        let atPreTip = Deriver.derive(ops: opsAfter, upTo: .atOp(opId: preTip, at: Date()))
        XCTAssertEqual(atPreTip.sequence.compactMap { atPreTip.paragraphs[$0] }, preWords,
                       "every rewound-away word is still derivable at the old tip")
    }

    /// M4-RW-012 — a forward rewind returns the LIVE document to the exact
    /// pre-rewind words.
    func test_rewind_forwardAgain_returnsTheExactWords() async throws {
        let (h, marks) = try await makeThreeParagraphDoc()
        let doc = h.doc
        let preWords = doc.sequence.compactMap { doc.paragraph(id: $0) }

        _ = try await doc.restoreToOp(opId: marks[0])
        _ = try await doc.restoreToOp(opId: marks[2])

        XCTAssertEqual(doc.sequence.compactMap { doc.paragraph(id: $0) }, preWords)
    }

    // MARK: - The orphan sweep

    /// M4-RW-013 / M4-RW-014 — an OPEN annotation on a removed paragraph is
    /// archived and reported; one on a surviving paragraph is untouched.
    func test_rewind_archivesOpenAnnotationsOnRemovedParagraphs_only() async throws {
        let h = try await makeHarness("First paragraph.")
        let doc = h.doc
        let target = try await doc.opLog().last!.opId
        doc.setFullText("First paragraph.\n\nSecond paragraph.\n")
        try await doc.flushBurstNow()
        let p2 = try await paragraphId(in: doc, containing: "Second")

        let doomed = try await doc.addAnnotation(kind: .comment, paragraphId: p2, body: "on p2")
        let safe = try await doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "on p1")

        let r = try await doc.restoreToOp(opId: target)

        XCTAssertEqual(annotation(doc, doomed)?.status, .archived)
        XCTAssertEqual(annotation(doc, safe)?.status, .open)
        XCTAssertEqual(r.archivedAnnotationOpIds.count, 1,
                       "the archive is reported back to the caller")
        XCTAssertEqual(r.removedParagraphIds, [p2])
    }

    /// M4-RW-015 — the `ann.kind != .craftNote` carve-out in
    /// `sweepOrphanedAnnotations` cannot change any outcome: a craft note has
    /// NO paragraph anchor to begin with, so the `removed.contains` term is
    /// already false. Two independent sites force it doc-scoped —
    /// `Document.addAnnotation` writes `changes: []` for `.craftNote`, and
    /// `AnnotationDeriver` forces `paragraphId = nil` for that kind regardless.
    ///
    /// This falsifies the survey's REW-D9, whose writer-visible consequence was
    /// "an open craft note whose paragraph chip points at text that is not in
    /// the document". There is no chip: the anchor is nil at creation.
    func test_craftNoteCarveOut_isUnreachableBecauseCraftNotesHaveNoAnchor() async throws {
        let h = try await makeHarness("First.")
        let doc = h.doc
        let target = try await doc.opLog().last!.opId
        doc.setFullText("First.\n\nSecond.\n"); try await doc.flushBurstNow()
        let p2 = try await paragraphId(in: doc, containing: "Second")

        let craft = try await doc.addAnnotation(kind: .craftNote, paragraphId: p2, body: "craft")
        let comment = try await doc.addAnnotation(kind: .comment, paragraphId: p2, body: "c")

        // The anchor is dropped at creation, for the craft note only.
        XCTAssertNil(annotation(doc, craft)?.paragraphId,
                     "a craft note is doc-scoped however it was created")
        XCTAssertEqual(annotation(doc, comment)?.paragraphId, p2)

        _ = try await doc.restoreToOp(opId: target)

        XCTAssertEqual(annotation(doc, craft)?.status, .open, "not archived")
        XCTAssertEqual(annotation(doc, comment)?.status, .archived)
        // The reason it was not archived is the nil anchor, not the kind clause.
        XCTAssertNil(annotation(doc, craft)?.paragraphId,
                     "so the kind clause never decides anything")
    }

    /// M4-RW-016 — a document that has never had an annotation gets no sweep,
    /// and no stale removed-set leaks into a later annotation.
    func test_rewind_onADocumentWithNoAnnotations_leavesNoStaleSweep() async throws {
        let h = try await makeHarness("First.")
        let doc = h.doc
        let target = try await doc.opLog().last!.opId
        doc.setFullText("First.\n\nSecond.\n"); try await doc.flushBurstNow()

        let r = try await doc.restoreToOp(opId: target)
        XCTAssertEqual(r.removedParagraphIds.count, 1)
        XCTAssertTrue(r.archivedAnnotationOpIds.isEmpty)

        // A later annotation on a later paragraph is unaffected.
        doc.setFullText("First.\n\nThird.\n"); try await doc.flushBurstNow()
        let p3 = try await paragraphId(in: doc, containing: "Third")
        let ann = try await doc.addAnnotation(kind: .comment, paragraphId: p3, body: "later")
        XCTAssertEqual(annotation(doc, ann)?.status, .open)
    }

    // MARK: - Stranded accepts

    /// M4-RW-017 — an accept past the target whose paragraph SURVIVES is
    /// reopened (status-only `.claudeAcceptRevert`) and reported.
    func test_rewind_reopensAnAcceptWhoseParagraphSurvives() async throws {
        let h = try await makeHarness("Original sentence here.")
        let doc = h.doc, pid = h.pid
        let annId = try await doc.addAnnotation(kind: .suggestedChange, paragraphId: pid,
                                                body: "b", suggestedText: "Improved sentence.")
        let beforeAccept = try await doc.opLog().last!.opId
        try await doc.acceptAnnotation(id: annId, userResponse: "yes")
        XCTAssertEqual(annotation(doc, annId)?.status, .accepted)

        let r = try await doc.restoreToOp(opId: beforeAccept)

        XCTAssertEqual(annotation(doc, annId)?.status, .open,
                       "offered again, against the text it was authored against")
        XCTAssertEqual(r.reopenedAnnotationOpIds, [annId])
        XCTAssertEqual(doc.paragraph(id: pid), "Original sentence here.")
    }

    /// M4-RW-018 — an accept past the target whose paragraph was REMOVED is
    /// archived instead, and reported in the archive list.
    func test_rewind_archivesAnAcceptWhoseParagraphWasRemoved() async throws {
        let h = try await makeHarness("First.")
        let doc = h.doc
        let early = try await doc.opLog().last!.opId
        doc.setFullText("First.\n\nSecond.\n"); try await doc.flushBurstNow()
        let p2 = try await paragraphId(in: doc, containing: "Second")
        let annId = try await doc.addAnnotation(kind: .suggestedChange, paragraphId: p2,
                                                body: "b", suggestedText: "Second, improved.")
        try await doc.acceptAnnotation(id: annId)

        let r = try await doc.restoreToOp(opId: early)

        XCTAssertEqual(annotation(doc, annId)?.status, .archived)
        XCTAssertTrue(r.reopenedAnnotationOpIds.isEmpty)
        XCTAssertFalse(r.archivedAnnotationOpIds.isEmpty)
    }

    // MARK: - The forward rewind is symmetric (RULING-25, fixed 2026-08-08)

    /// M4-RW-019 / M4-RW-020 — rewinding FORWARD past the moment a paragraph
    /// was created brings the paragraph back, the pane TASK back, AND reopens
    /// the comment the backward rewind's sweep archived — a `.rewind`-stamped
    /// `.annotationReopen`, the sweep's mirror. Before the 2026-08-08 fix the
    /// annotation stayed archived permanently and silently (the asymmetry this
    /// test used to pin as the M4-RW-019 violation). Production twin:
    /// `MaughamTests/Integration/RewindTravelReopenTests`.
    func test_forwardRewind_returnsTextTasks_andReopensWhatTheSweepArchived() async throws {
        let h = try await makeHarness("First.")
        let doc = h.doc
        try await doc.flushBurstNow()
        let early = try await doc.opLog().last!.opId

        doc.setFullText("First.\n\nSecond.\n"); try await doc.flushBurstNow()
        let p2 = try await paragraphId(in: doc, containing: "Second")
        let annId = try await doc.addAnnotation(kind: .comment, paragraphId: p2, body: "note")
        let task = doc.createPaneTask(body: "remember", parentTaskId: nil)
        try await doc.flushBurstNow()
        let later = try await doc.opLog().last!.opId
        let filter = TaskFilter(scope: .project, statuses: [.open])

        let back = try await doc.restoreToOp(opId: early)
        XCTAssertTrue(back.rewoundTaskOps)
        XCTAssertEqual(annotation(doc, annId)?.status, .archived)
        XCTAssertTrue(back.travelReopenedAnnotationIds.isEmpty,
                      "the backward leg reopens nothing — the paragraph is absent there")
        XCTAssertFalse(doc.tasks(filter: filter).contains { $0.id == task.id })

        let forward = try await doc.restoreToOp(opId: later)

        XCTAssertTrue(doc.sequence.contains(p2), "the paragraph came back")
        XCTAssertTrue(doc.tasks(filter: filter).contains { $0.id == task.id },
                      "the task came back — TaskDeriver's window moved")
        XCTAssertEqual(annotation(doc, annId)?.status, .open,
                       "and the comment came back with them — RULING-25's symmetric travel")
        XCTAssertEqual(forward.travelReopenedAnnotationIds, [annId])
        XCTAssertTrue(forward.removedParagraphIds.isEmpty,
                      "a forward rewind removes nothing, so no archive sweep runs")
        XCTAssertTrue(forward.reopenedAnnotationOpIds.isEmpty,
                      "the accept-revert channel stays empty — this is the travel channel")
        XCTAssertFalse(forward.rewoundTaskOps)
    }

    // MARK: - restoreToOpUndoable

    /// M4-RW-021 / M4-RW-028 — `removeAllActions()` runs UNCONDITIONALLY before
    /// the restore. When the restore turns out to be a genuine no-op the guard
    /// returns before registering anything, so the writer is left with an EMPTY
    /// undo stack and nothing to show for it.
    func test_undoableRewind_aNoOpCostsNothing() async throws {
        let (h, marks) = try await makeThreeParagraphDoc()
        let doc = h.doc
        let um = UndoManager()
        um.registerUndo(withTarget: self) { _ in }        // stand-in for typing history
        um.setActionName("Typing")
        XCTAssertTrue(um.canUndo)

        let r = try await doc.restoreToOpUndoable(opId: marks[2], undoManager: um)

        XCTAssertNil(r.restoreOp, "a genuine no-op")
        XCTAssertTrue(um.canUndo,
                      "the typing history SURVIVES — an action that changes nothing costs nothing "
                      + "(RULING-37, fixed 2026-08-09)")
        XCTAssertEqual(um.undoActionName, "Typing",
                       "the writer's own stack is exactly as they left it")
    }

    /// M4-RW-022 (fully fixed: RULING-37 + RULING-27, 2026-08-09) — a target
    /// that does not exist in the log costs nothing AND says so: the stack
    /// survives, and the result names the nearest surviving moment it resolved
    /// to instead of reporting a plain success.
    func test_undoableRewind_unknownTarget_costsNothing_andSaysSo() async throws {
        let (h, _) = try await makeThreeParagraphDoc()
        let doc = h.doc
        let textBefore = doc.materialize()
        let um = UndoManager()
        um.registerUndo(withTarget: self) { _ in }
        um.setActionName("Typing")

        let r = try await doc.restoreToOpUndoable(opId: "99NOSUCHOPATALL", undoManager: um)

        XCTAssertNil(r.restoreOp, "nearest here is the tip — nothing to change")
        XCTAssertEqual(doc.materialize(), textBefore)
        XCTAssertTrue(um.canUndo, "no change, no cost (RULING-37)")
        guard case .nearest = r.targetResolution else {
            return XCTFail("the vanished moment must be named, not silently absorbed")
        }
    }

    /// M4-RW-023 / M4-RW-024 — a real rewind leaves exactly ONE undo action,
    /// named "Restore from History"; after ⌘Z the stack is empty.
    func test_undoableRewind_leavesExactlyOneUndoAction() async throws {
        let (h, marks) = try await makeThreeParagraphDoc()
        let doc = h.doc
        let preWords = doc.sequence.compactMap { doc.paragraph(id: $0) }
        let um = UndoManager()
        um.registerUndo(withTarget: self) { _ in }
        um.setActionName("Typing")

        _ = try await doc.restoreToOpUndoable(opId: marks[0], undoManager: um)
        XCTAssertTrue(um.canUndo)
        XCTAssertEqual(um.undoActionName, "Restore from History")

        um.undo(); await doc.awaitPendingUndoWork()

        XCTAssertEqual(doc.sequence.compactMap { doc.paragraph(id: $0) }, preWords,
                       "one ⌘Z returns the whole rewind")
        XCTAssertFalse(um.canUndo, "and there is nothing behind it")
    }

    /// M4-RW-025 — the compensating restore is stamped `.undoRewind`, never
    /// `.rewind`, so it is invisible to `TaskDeriver`'s window matcher.
    func test_undoOfARewind_stampsItsCompensatingRestoreUndoRewind() async throws {
        let (h, marks) = try await makeThreeParagraphDoc()
        let doc = h.doc
        let um = UndoManager()

        _ = try await doc.restoreToOpUndoable(opId: marks[0], undoManager: um)
        let afterRewind = try await doc.opLog()
        XCTAssertEqual(afterRewind.last?.provenance?.synthesisSource, .rewind)

        um.undo(); await doc.awaitPendingUndoWork()

        let afterUndo = try await doc.opLog()
        let sources = afterUndo.compactMap { $0.provenance?.synthesisSource }
        XCTAssertTrue(sources.contains(.undoRewind),
                      "the compensating restore is stamped .undoRewind")
        XCTAssertEqual(sources.filter { $0 == .rewind }.count, 1,
                       "and it did NOT stamp a second .rewind")
    }

    /// M4-RW-026 — when the text has drifted since the restore (the cross-device
    /// case), the undo DECLINES: it leaves the drifted text alone and does not
    /// restore forward. The decline is invisible — nothing is thrown to the
    /// caller and nothing reaches a writer-facing surface.
    func test_undoOfARewind_declinesSilentlyWhenTextDriftedSince() async throws {
        let h = try await makeHarness("Original sentence here.")
        let doc = h.doc, pid = h.pid
        doc.setFullText("Original sentence here.\n\nSecond.\n"); try await doc.flushBurstNow()
        let bootstrap = try await doc.opLog().first { $0.kind == .bootstrap }!.opId
        let preTipWords = doc.sequence.compactMap { doc.paragraph(id: $0) }

        let um = UndoManager()
        _ = try await doc.restoreToOpUndoable(opId: bootstrap, undoManager: um)

        // A peer's merged edit lands after the restore.
        doc.setParagraph(id: pid, text: "Something a peer wrote.")
        try await doc.flushBurstNow()
        let drifted = doc.materialize()

        um.undo(); await doc.awaitPendingUndoWork()

        XCTAssertEqual(doc.materialize(), drifted, "the undo declined — nothing was clobbered")
        XCTAssertNotEqual(doc.sequence.compactMap { doc.paragraph(id: $0) }, preTipWords,
                          "and it did not restore forward either")
    }

    /// M4-RW-031 — redo re-runs `restoreToOp` from scratch, so it can never
    /// disagree with a fresh rewind.
    func test_redoOfARewind_reRunsTheRestoreFromScratch() async throws {
        let (h, marks) = try await makeThreeParagraphDoc()
        let doc = h.doc
        let um = UndoManager()

        _ = try await doc.restoreToOpUndoable(opId: marks[0], undoManager: um)
        let postRestore = doc.sequence.compactMap { doc.paragraph(id: $0) }

        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertTrue(um.canRedo)

        um.redo(); await doc.awaitPendingUndoWork()
        XCTAssertEqual(doc.sequence.compactMap { doc.paragraph(id: $0) }, postRestore)
    }

    // MARK: - What the module hands its caller

    /// M4-RW-029 — `RewindRestoreResult` carries everything an honest
    /// before-and-after report would need: the removed paragraphs, the
    /// annotations it archived, the ones it reopened, whether tasks were
    /// rewound, and the sequence counts either side.
    func test_theResultCarriesEveryCollateralEffectTheRewindCaused() async throws {
        let h = try await makeHarness("First.")
        let doc = h.doc
        let target = try await doc.opLog().last!.opId
        doc.setFullText("First.\n\nSecond.\n"); try await doc.flushBurstNow()
        let p2 = try await paragraphId(in: doc, containing: "Second")
        _ = try await doc.addAnnotation(kind: .comment, paragraphId: p2, body: "a")
        _ = try await doc.addAnnotation(kind: .query, paragraphId: p2, body: "b")
        _ = doc.createPaneTask(body: "t", parentTaskId: nil)
        try await doc.flushBurstNow()

        let r = try await doc.restoreToOp(opId: target)

        XCTAssertEqual(r.priorSequenceCount, 2)
        XCTAssertEqual(r.newSequenceCount, 1)
        XCTAssertEqual(r.removedParagraphIds, [p2])
        XCTAssertEqual(r.archivedAnnotationOpIds.count, 2,
                       "both open annotations on the removed paragraph, counted")
        XCTAssertTrue(r.reopenedAnnotationOpIds.isEmpty)
        XCTAssertTrue(r.rewoundTaskOps)
        XCTAssertNotNil(r.restoreOp)
    }
}
