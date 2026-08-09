import XCTest
import MaughamCore
@testable import Maugham

/// A PROBE, not a test. It asserts almost nothing; it PRINTS observed behaviour
/// so the characterisation assertions in `RewindCharacterization.swift` can be
/// written from what the code ACTUALLY does.
///
///   xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
///     CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/RewindObservationProbe
@MainActor
final class RewindObservationProbe: XCTestCase {

    private func show(_ label: String, _ value: Any) { print("PROBE | \(label) = \(value)") }

    // MARK: - Harness (mirrors RewindUndoTests.makeHarness)

    private struct Harness { let doc: Document; let pid: String; let url: URL }

    private func makeHarness(_ initialMd: String) async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RewindProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let relativePath = "manuscript/c1.md"
        try initialMd.write(to: tmp.appendingPathComponent(relativePath),
                            atomically: true, encoding: .utf8)
        let item = StructureItem(id: "doc-x", title: "Chapter 1", type: .document,
                                 path: relativePath)
        let manifest = ProjectManifest(type: .novel, title: "Rewind Probe", author: "A",
                                       created: Date(), modified: Date(),
                                       structure: [item], research: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let ds = try await DocumentStore.open(url: tmp)
        let doc = try await Document.load(url: tmp.appendingPathComponent(relativePath),
                                          device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: relativePath)
        let pid = try await doc.opLog().first { $0.kind == .bootstrap }!.changes.first!.paragraphId
        return Harness(doc: doc, pid: pid, url: tmp)
    }

    private func annotation(_ doc: Document, _ id: String) -> Annotation? {
        doc.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }
    }

    // MARK: - Deriver.derive(ops:upTo:)

    func test_probe_deriverUpTo() async throws {
        let h = try await makeHarness("One.")
        let doc = h.doc
        doc.setFullText("One.\n\nTwo.\n"); try await doc.flushBurstNow()
        doc.setFullText("One.\n\nTwo.\n\nThree.\n"); try await doc.flushBurstNow()
        let ops = try await doc.opLog()
        show("deriver/op-kinds", ops.map { "\($0.kind)" })

        let full = Deriver.derive(ops: ops, upTo: .now)
        show("deriver/now/sequence-count", full.sequence.count)

        let bootstrapId = ops.first { $0.kind == .bootstrap }!.opId
        let atBootstrap = Deriver.derive(ops: ops, upTo: .atOp(opId: bootstrapId, at: Date()))
        show("deriver/atOp(bootstrap)/count", atBootstrap.sequence.count)

        let firstBurst = ops.first { $0.kind == .typingBurst }!.opId
        let atFirst = Deriver.derive(ops: ops, upTo: .atOp(opId: firstBurst, at: Date()))
        show("deriver/atOp(first-burst)/count", atFirst.sequence.count)
        show("deriver/atOp(first-burst)/INCLUSIVE-of-that-op",
             atFirst.sequence.count > atBootstrap.sequence.count)

        // The headline: a cursor whose op is not in the log.
        let missing = Deriver.derive(ops: ops, upTo: .atOp(opId: "01MISSINGOPID", at: Date()))
        show("deriver/atOp(MISSING)/count", missing.sequence.count)
        show("deriver/atOp(MISSING)/equals-full", missing.sequence == full.sequence)

        let last = ops.last!.opId
        let atLast = Deriver.derive(ops: ops, upTo: .atOp(opId: last, at: Date()))
        show("deriver/atOp(tip)/equals-full", atLast.sequence == full.sequence)

        // Empty log.
        show("deriver/empty/now", Deriver.derive(ops: [], upTo: .now).sequence)
        show("deriver/empty/atOp", Deriver.derive(ops: [], upTo: .atOp(opId: "x", at: Date())).sequence)
    }

    // MARK: - restoreToOp: the inclusive boundary and the no-op shapes

    func test_probe_restoreBoundaryAndNoOps() async throws {
        let h = try await makeHarness("One.")
        let doc = h.doc
        doc.setFullText("One.\n\nTwo.\n"); try await doc.flushBurstNow()
        let burstA = try await doc.opLog().last!.opId
        doc.setFullText("One.\n\nTwo.\n\nThree.\n"); try await doc.flushBurstNow()

        show("restore/text-before", doc.materialize().debugDescription)
        let r = try await doc.restoreToOp(opId: burstA)
        show("restore/text-after-targeting-burstA", doc.materialize().debugDescription)
        show("restore/burstA-effect-still-present", doc.materialize().contains("Two"))
        show("restore/prior->new", "\(r.priorSequenceCount) -> \(r.newSequenceCount)")
        show("restore/removedParagraphIds.count", r.removedParagraphIds.count)
        show("restore/restoreOp-kind", String(describing: r.restoreOp?.kind))
        show("restore/restoreOp-synthesisSource",
             String(describing: r.restoreOp?.provenance?.synthesisSource))
        show("restore/restoreOp-sourceCheckpoint",
             String(describing: r.restoreOp?.provenance?.sourceCheckpoint))
        show("restore/rewoundTaskOps", r.rewoundTaskOps)

        // No-op A: target IS the tip.
        let h2 = try await makeHarness("One.")
        let d2 = h2.doc
        d2.setFullText("One.\n\nTwo.\n"); try await d2.flushBurstNow()
        let tip = try await d2.opLog().last!.opId
        let countBefore = try await d2.opLog().count
        let n1 = try await d2.restoreToOp(opId: tip)
        show("noop-tip/restoreOp", String(describing: n1.restoreOp?.opId))
        show("noop-tip/prior->new", "\(n1.priorSequenceCount) -> \(n1.newSequenceCount)")
        show("noop-tip/log-grew", (try await d2.opLog().count) - countBefore)

        // No-op B: target op id is NOT IN THE LOG AT ALL.
        let n2 = try await d2.restoreToOp(opId: "01THISOPNEVEREXISTED")
        show("noop-missing/restoreOp", String(describing: n2.restoreOp?.opId))
        show("noop-missing/prior->new", "\(n2.priorSequenceCount) -> \(n2.newSequenceCount)")
        show("noop-missing/removed", n2.removedParagraphIds)
        show("noop-missing/archived", n2.archivedAnnotationOpIds)
        show("noop-missing/rewoundTaskOps", n2.rewoundTaskOps)
        show("noop-missing/log-grew", (try await d2.opLog().count) - countBefore)
        show("noop-missing/text-unchanged", d2.materialize().debugDescription)
        show("noop-missing/RESULT-IDENTICAL-TO-noop-tip", n1 == n2)
        show("noop-missing/did-it-throw", "no — it returned a success value")
    }

    // MARK: - the append-only guarantee (RULING-24 tier 1)

    func test_probe_appendOnly() async throws {
        let h = try await makeHarness("One.")
        let doc = h.doc
        doc.setFullText("One.\n\nTwo.\n"); try await doc.flushBurstNow()
        let target = try await doc.opLog().first { $0.kind == .bootstrap }!.opId
        let before = try await doc.opLog()
        let beforeText = doc.materialize()
        let preTip = before.last!.opId

        _ = try await doc.restoreToOp(opId: target)
        let after = try await doc.opLog()
        show("appendOnly/before-count", before.count)
        show("appendOnly/after-count", after.count)
        show("appendOnly/every-prior-op-survives",
             before.allSatisfy { b in after.contains { $0.opId == b.opId } })
        show("appendOnly/text-now", doc.materialize().debugDescription)

        // The pre-rewind tip is still a scrub target: derive back to it.
        let backAtTip = Deriver.derive(ops: after, upTo: .atOp(opId: preTip, at: Date()))
        show("appendOnly/derive-at-preTip-recovers-the-words",
             backAtTip.sequence.compactMap { backAtTip.paragraphs[$0] }.joined(separator: " | "))
        show("appendOnly/that-equals-pre-rewind-text",
             backAtTip.sequence.compactMap { backAtTip.paragraphs[$0] }.joined(separator: "\n\n")
                == beforeText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - the orphan sweep

    func test_probe_orphanSweep() async throws {
        let h = try await makeHarness("First paragraph.")
        let doc = h.doc
        let target = try await doc.opLog().last!.opId
        doc.setFullText("First paragraph.\n\nSecond paragraph.\n"); try await doc.flushBurstNow()
        let burst = try await doc.opLog().last { $0.kind == .typingBurst }
        let p2 = burst!.changes.first { $0.next.contains("Second") }!.paragraphId

        let comment = try await doc.addAnnotation(kind: .comment, paragraphId: p2, body: "note")
        let craft = try await doc.addAnnotation(kind: .craftNote, paragraphId: p2, body: "craft")
        let onSurvivor = try await doc.addAnnotation(kind: .comment, paragraphId: h.pid,
                                                     body: "on p1")
        show("sweep/before", [comment: annotation(doc, comment)?.status,
                              craft: annotation(doc, craft)?.status,
                              onSurvivor: annotation(doc, onSurvivor)?.status]
                .map { "\($0.value.map { "\($0)" } ?? "nil")" })

        let r = try await doc.restoreToOp(opId: target)
        show("sweep/removed-count", r.removedParagraphIds.count)
        show("sweep/comment-after", String(describing: annotation(doc, comment)?.status))
        show("sweep/craftNote-after", String(describing: annotation(doc, craft)?.status))
        show("sweep/craftNote-still-claims-paragraph",
             String(describing: annotation(doc, craft)?.paragraphId))
        show("sweep/craftNote-paragraph-still-in-sequence",
             doc.sequence.contains(p2))
        show("sweep/onSurvivor-after", String(describing: annotation(doc, onSurvivor)?.status))
        show("sweep/archivedAnnotationOpIds.count", r.archivedAnnotationOpIds.count)
        show("sweep/reopenedAnnotationOpIds.count", r.reopenedAnnotationOpIds.count)
    }

    // MARK: - forward rewind: what comes back and what does not

    func test_probe_forwardRewind() async throws {
        let h = try await makeHarness("First paragraph.")
        let doc = h.doc
        let early = try await doc.opLog().last!.opId
        doc.setFullText("First paragraph.\n\nSecond paragraph.\n"); try await doc.flushBurstNow()
        let burst = try await doc.opLog().last { $0.kind == .typingBurst }
        let p2 = burst!.changes.first { $0.next.contains("Second") }!.paragraphId
        let annId = try await doc.addAnnotation(kind: .comment, paragraphId: p2, body: "note")
        let later = try await doc.opLog().last!.opId   // after the annotation exists

        // Rewind BACK past p2's creation — the sweep archives the comment.
        _ = try await doc.restoreToOp(opId: early)
        show("forward/after-back-rewind/status", String(describing: annotation(doc, annId)?.status))
        show("forward/after-back-rewind/p2-present", doc.sequence.contains(p2))

        // Now rewind FORWARD to a moment where p2 exists again.
        let r = try await doc.restoreToOp(opId: later)
        show("forward/after-forward-rewind/p2-present", doc.sequence.contains(p2))
        show("forward/after-forward-rewind/text", doc.materialize().debugDescription)
        show("forward/after-forward-rewind/status",
             String(describing: annotation(doc, annId)?.status))
        show("forward/removedIds-on-forward", r.removedParagraphIds)
        show("forward/reopened-on-forward", r.reopenedAnnotationOpIds)
        show("forward/COMMENT-CAME-BACK", annotation(doc, annId)?.status == .open)
    }

    // MARK: - stranded accepts

    func test_probe_strandedAccepts() async throws {
        // (a) paragraph SURVIVES → claudeAcceptRevert, reported as reopened
        let h = try await makeHarness("Original sentence here.")
        let doc = h.doc, pid = h.pid
        let annId = try await doc.addAnnotation(kind: .suggestedChange, paragraphId: pid,
                                                body: "b", suggestedText: "Improved sentence.")
        let beforeAccept = try await doc.opLog().last!.opId
        try await doc.acceptAnnotation(id: annId, userResponse: "yes")
        show("stranded/survivor/status-before", String(describing: annotation(doc, annId)?.status))
        let r = try await doc.restoreToOp(opId: beforeAccept)
        show("stranded/survivor/status-after", String(describing: annotation(doc, annId)?.status))
        show("stranded/survivor/reopenedIds", r.reopenedAnnotationOpIds)
        show("stranded/survivor/archivedIds", r.archivedAnnotationOpIds)
        show("stranded/survivor/text", doc.paragraph(id: pid)?.debugDescription ?? "nil")

        // (b) paragraph REMOVED → claudeArchive, reported as archived
        let h2 = try await makeHarness("First.")
        let d2 = h2.doc
        let early = try await d2.opLog().last!.opId
        d2.setFullText("First.\n\nSecond.\n"); try await d2.flushBurstNow()
        let b = try await d2.opLog().last { $0.kind == .typingBurst }
        let p2 = b!.changes.first { $0.next.contains("Second") }!.paragraphId
        let a2 = try await d2.addAnnotation(kind: .suggestedChange, paragraphId: p2,
                                            body: "b", suggestedText: "Second, improved.")
        try await d2.acceptAnnotation(id: a2)
        show("stranded/removed/status-before", String(describing: annotation(d2, a2)?.status))
        let r2 = try await d2.restoreToOp(opId: early)
        show("stranded/removed/status-after", String(describing: annotation(d2, a2)?.status))
        show("stranded/removed/reopenedIds", r2.reopenedAnnotationOpIds)
        show("stranded/removed/archivedIds.count", r2.archivedAnnotationOpIds.count)
    }

    // MARK: - restoreToOpUndoable: the undo-stack cost

    func test_probe_undoStackCost() async throws {
        // A genuine no-op rewind (target == tip) still clears the typing stack.
        let h = try await makeHarness("One.")
        let doc = h.doc
        doc.setFullText("One.\n\nTwo.\n"); try await doc.flushBurstNow()
        let tip = try await doc.opLog().last!.opId

        let um = UndoManager()
        // Stand in for the writer's per-keystroke undo history.
        um.registerUndo(withTarget: self) { _ in }
        um.setActionName("Typing")
        show("undoCost/canUndo-before", um.canUndo)
        show("undoCost/actionName-before", um.undoActionName)

        let r = try await doc.restoreToOpUndoable(opId: tip, undoManager: um)
        show("undoCost/restore-was-a-noop", r.restoreOp == nil)
        show("undoCost/canUndo-after", um.canUndo)
        show("undoCost/actionName-after", um.undoActionName.debugDescription)

        // And for a rewind that DOES change something: the stack becomes one action.
        let h2 = try await makeHarness("One.")
        let d2 = h2.doc
        d2.setFullText("One.\n\nTwo.\n"); try await d2.flushBurstNow()
        let target = try await d2.opLog().first { $0.kind == .bootstrap }!.opId
        let um2 = UndoManager()
        um2.registerUndo(withTarget: self) { _ in }
        um2.setActionName("Typing")
        _ = try await d2.restoreToOpUndoable(opId: target, undoManager: um2)
        show("undoCost/real-rewind/canUndo", um2.canUndo)
        show("undoCost/real-rewind/actionName", um2.undoActionName.debugDescription)
        um2.undo(); await d2.awaitPendingUndoWork()
        show("undoCost/real-rewind/after-one-undo/canUndo", um2.canUndo)
        show("undoCost/real-rewind/after-one-undo/text", d2.materialize().debugDescription)

        // A MISSING target through the undoable wrapper.
        let h3 = try await makeHarness("One.")
        let d3 = h3.doc
        d3.setFullText("One.\n\nTwo.\n"); try await d3.flushBurstNow()
        let um3 = UndoManager()
        um3.registerUndo(withTarget: self) { _ in }
        um3.setActionName("Typing")
        let r3 = try await d3.restoreToOpUndoable(opId: "01NOSUCHOP", undoManager: um3)
        show("undoCost/missing-target/restoreOp", String(describing: r3.restoreOp?.opId))
        show("undoCost/missing-target/canUndo-after", um3.canUndo)
        show("undoCost/missing-target/typing-history-gone", !um3.canUndo)
    }

    // MARK: - the undo's decline paths

    func test_probe_undoDecline() async throws {
        let h = try await makeHarness("Original sentence here.")
        let doc = h.doc, pid = h.pid
        doc.setFullText("Original sentence here.\n\nSecond.\n"); try await doc.flushBurstNow()
        let target = try await doc.opLog().first { $0.kind == .bootstrap }!.opId
        let preTipText = doc.materialize()

        let um = UndoManager()
        _ = try await doc.restoreToOpUndoable(opId: target, undoManager: um)
        show("decline/post-restore-text", doc.materialize().debugDescription)

        // Simulate a cross-device merge landing after the restore: mutate text.
        doc.setParagraph(id: pid, text: "Something a peer wrote.")
        try await doc.flushBurstNow()
        let driftedText = doc.materialize()

        um.undo(); await doc.awaitPendingUndoWork()
        show("decline/text-after-undo", doc.materialize().debugDescription)
        show("decline/undo-declined", doc.materialize() == driftedText)
        show("decline/did-NOT-restore-preTip", doc.materialize() != preTipText)
        show("decline/anything-thrown-to-caller", "no — the closure returns void and logs")
    }

    // MARK: - synthesisSource stamping

    func test_probe_synthesisSourceStamps() async throws {
        let h = try await makeHarness("One.")
        let doc = h.doc
        doc.setFullText("One.\n\nTwo.\n"); try await doc.flushBurstNow()
        let target = try await doc.opLog().first { $0.kind == .bootstrap }!.opId

        let um = UndoManager()
        _ = try await doc.restoreToOpUndoable(opId: target, undoManager: um)
        var kinds = try await doc.opLog().map { "\($0.kind):\(String(describing: $0.provenance?.synthesisSource))" }
        show("stamps/after-rewind", kinds)

        um.undo(); await doc.awaitPendingUndoWork()
        kinds = try await doc.opLog().map { "\($0.kind):\(String(describing: $0.provenance?.synthesisSource))" }
        show("stamps/after-undo", kinds)
    }
}
