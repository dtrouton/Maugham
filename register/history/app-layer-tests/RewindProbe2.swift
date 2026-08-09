import XCTest
import MaughamCore
@testable import Maugham

/// Second probe pass. Round 1 left three things open:
///  - the craft-note carve-out in `sweepOrphanedAnnotations` — is it ever live?
///  - the task half of the forward-rewind asymmetry (annotations stayed archived)
///  - what the writer's undo stack looks like across a rewind
@MainActor
final class RewindObservationProbe2: XCTestCase {

    private func show(_ label: String, _ value: Any) { print("PROBE2 | \(label) = \(value)") }

    private struct Harness { let doc: Document; let pid: String }

    private func makeHarness(_ initialMd: String) async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RewindProbe2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let relativePath = "manuscript/c1.md"
        try initialMd.write(to: tmp.appendingPathComponent(relativePath),
                            atomically: true, encoding: .utf8)
        let item = StructureItem(id: "doc-x", title: "Chapter 1", type: .document,
                                 path: relativePath)
        let manifest = ProjectManifest(type: .novel, title: "P2", author: "A",
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

    // MARK: - Is the craft-note carve-out ever live?

    func test_probe_craftNoteAnchor() async throws {
        let h = try await makeHarness("First.")
        let doc = h.doc
        let target = try await doc.opLog().last!.opId
        doc.setFullText("First.\n\nSecond.\n"); try await doc.flushBurstNow()
        let burst = try await doc.opLog().last { $0.kind == .typingBurst }
        let p2 = burst!.changes.first { $0.next.contains("Second") }!.paragraphId

        // Create every annotation kind against p2 and see which keep an anchor.
        let craft = try await doc.addAnnotation(kind: .craftNote, paragraphId: p2, body: "craft")
        let comment = try await doc.addAnnotation(kind: .comment, paragraphId: p2, body: "c")
        let query = try await doc.addAnnotation(kind: .query, paragraphId: p2, body: "q")
        show("craft/AT-CREATION/craftNote.paragraphId",
             String(describing: annotation(doc, craft)?.paragraphId))
        show("craft/AT-CREATION/comment.paragraphId",
             String(describing: annotation(doc, comment)?.paragraphId))
        show("craft/AT-CREATION/query.paragraphId",
             String(describing: annotation(doc, query)?.paragraphId))
        show("craft/AT-CREATION/p2-was", p2)

        // What does the creation op itself carry?
        let craftOp = try await doc.opLog().first {
            $0.provenance?.sourceAnnotationId == nil && $0.kind == .claudeCraftNote
        }
        show("craft/creation-op-kind-found", craftOp != nil)
        let allKinds = try await doc.opLog().map { "\($0.kind)" }
        show("craft/op-kinds", allKinds)

        let r = try await doc.restoreToOp(opId: target)
        show("craft/after-rewind/craftNote.status",
             String(describing: annotation(doc, craft)?.status))
        show("craft/after-rewind/comment.status",
             String(describing: annotation(doc, comment)?.status))
        show("craft/after-rewind/query.status",
             String(describing: annotation(doc, query)?.status))
        show("craft/after-rewind/archived-count", r.archivedAnnotationOpIds.count)
        show("craft/CARVE-OUT-WAS-LIVE",
             annotation(doc, craft)?.paragraphId != nil)
    }

    // MARK: - The forward-rewind asymmetry: tasks vs annotations

    func test_probe_forwardRewindTasks() async throws {
        let h = try await makeHarness("First.")
        let doc = h.doc
        try await doc.flushBurstNow()
        let early = try await doc.opLog().last!.opId

        // A pane task AND an annotation, both created after `early`.
        doc.setFullText("First.\n\nSecond.\n"); try await doc.flushBurstNow()
        let burst = try await doc.opLog().last { $0.kind == .typingBurst }
        let p2 = burst!.changes.first { $0.next.contains("Second") }!.paragraphId
        let annId = try await doc.addAnnotation(kind: .comment, paragraphId: p2, body: "note")
        let task = doc.createPaneTask(body: "remember this", parentTaskId: nil)
        try await doc.flushBurstNow()
        let later = try await doc.opLog().last!.opId

        let filter = TaskFilter(scope: .project, statuses: [.open])
        show("fwd/before/task-present", doc.tasks(filter: filter).contains { $0.id == task.id })
        show("fwd/before/ann-status", String(describing: annotation(doc, annId)?.status))

        // Rewind BACK past both.
        let back = try await doc.restoreToOp(opId: early)
        show("fwd/after-back/task-present", doc.tasks(filter: filter).contains { $0.id == task.id })
        show("fwd/after-back/ann-status", String(describing: annotation(doc, annId)?.status))
        show("fwd/after-back/rewoundTaskOps", back.rewoundTaskOps)

        // Rewind FORWARD past both again.
        let fwd = try await doc.restoreToOp(opId: later)
        show("fwd/after-forward/task-present",
             doc.tasks(filter: filter).contains { $0.id == task.id })
        show("fwd/after-forward/ann-status", String(describing: annotation(doc, annId)?.status))
        show("fwd/after-forward/rewoundTaskOps", fwd.rewoundTaskOps)
        show("fwd/after-forward/p2-back", doc.sequence.contains(p2))
        show("fwd/ASYMMETRY (task back, annotation not)",
             "task=\(doc.tasks(filter: filter).contains { $0.id == task.id }) "
             + "ann=\(String(describing: annotation(doc, annId)?.status))")
    }

    // MARK: - the words are never lost (RULING-24 tier 1)

    func test_probe_wordsAlwaysRecoverable() async throws {
        let h = try await makeHarness("One.")
        let doc = h.doc
        doc.setFullText("One.\n\nTwo.\n"); try await doc.flushBurstNow()
        doc.setFullText("One.\n\nTwo.\n\nThree.\n"); try await doc.flushBurstNow()
        let preTip = try await doc.opLog().last!.opId
        let preWords = doc.sequence.compactMap { doc.paragraph(id: $0) }
        show("words/pre-rewind", preWords)

        let bootstrap = try await doc.opLog().first { $0.kind == .bootstrap }!.opId
        _ = try await doc.restoreToOp(opId: bootstrap)
        show("words/after-rewind-to-bootstrap",
             doc.sequence.compactMap { doc.paragraph(id: $0) })

        // Every pre-rewind word is still derivable from the log at the old tip.
        let ops = try await doc.opLog()
        let atPreTip = Deriver.derive(ops: ops, upTo: .atOp(opId: preTip, at: Date()))
        show("words/derived-at-preTip",
             atPreTip.sequence.compactMap { atPreTip.paragraphs[$0] })
        show("words/ALL-RECOVERABLE",
             atPreTip.sequence.compactMap { atPreTip.paragraphs[$0] } == preWords)

        // And a forward rewind actually brings them back into the live doc.
        _ = try await doc.restoreToOp(opId: preTip)
        show("words/after-forward-rewind", doc.sequence.compactMap { doc.paragraph(id: $0) })
        show("words/ROUND-TRIP-EXACT",
             doc.sequence.compactMap { doc.paragraph(id: $0) } == preWords)

        // Nothing was ever removed from the log.
        show("words/log-only-grew", ops.count <= (try await doc.opLog().count))
    }

    // MARK: - what the result tells the caller vs what it costs

    func test_probe_resultCompleteness() async throws {
        let h = try await makeHarness("First.")
        let doc = h.doc
        let target = try await doc.opLog().last!.opId
        doc.setFullText("First.\n\nSecond.\n"); try await doc.flushBurstNow()
        let burst = try await doc.opLog().last { $0.kind == .typingBurst }
        let p2 = burst!.changes.first { $0.next.contains("Second") }!.paragraphId
        _ = try await doc.addAnnotation(kind: .comment, paragraphId: p2, body: "a")
        _ = try await doc.addAnnotation(kind: .query, paragraphId: p2, body: "b")
        let task = doc.createPaneTask(body: "t", parentTaskId: nil)
        try await doc.flushBurstNow()
        _ = task

        let r = try await doc.restoreToOp(opId: target)
        show("result/priorSequenceCount", r.priorSequenceCount)
        show("result/newSequenceCount", r.newSequenceCount)
        show("result/removedParagraphIds.count", r.removedParagraphIds.count)
        show("result/archivedAnnotationOpIds.count", r.archivedAnnotationOpIds.count)
        show("result/reopenedAnnotationOpIds.count", r.reopenedAnnotationOpIds.count)
        show("result/rewoundTaskOps", r.rewoundTaskOps)
        show("result/restoreOp-present", r.restoreOp != nil)
        show("result/CARRIES-THE-ARCHIVE-COUNT", r.archivedAnnotationOpIds.count > 0)
    }

    // MARK: - undo of a rewind whose target was a missing op

    func test_probe_undoOfNothing() async throws {
        let h = try await makeHarness("One.")
        let doc = h.doc
        doc.setFullText("One.\n\nTwo.\n"); try await doc.flushBurstNow()
        let um = UndoManager()
        um.registerUndo(withTarget: self) { _ in }
        um.setActionName("Typing")

        let r = try await doc.restoreToOpUndoable(opId: "01NOSUCHOPATALL", undoManager: um)
        show("undoOfNothing/restoreOp", String(describing: r.restoreOp?.opId))
        show("undoOfNothing/canUndo", um.canUndo)
        show("undoOfNothing/canRedo", um.canRedo)
        show("undoOfNothing/actionName", um.undoActionName.debugDescription)
        show("undoOfNothing/text", doc.materialize().debugDescription)

        // What did the writer's ⌘Z do before, and what does it do now?
        show("undoOfNothing/SUMMARY",
             "the rewind found no such moment, changed nothing, reported success, "
             + "and cost the writer their entire typing-undo stack")
    }

    // MARK: - a rewind on a document with no annotations at all

    func test_probe_noAnnotationGate() async throws {
        let h = try await makeHarness("First.")
        let doc = h.doc
        let target = try await doc.opLog().last!.opId
        doc.setFullText("First.\n\nSecond.\n"); try await doc.flushBurstNow()

        let r = try await doc.restoreToOp(opId: target)
        show("gate/removed-count", r.removedParagraphIds.count)
        show("gate/archived-count", r.archivedAnnotationOpIds.count)
        show("gate/sequence-after", doc.sequence.count)

        // Now add an annotation and rewind again — does a stale sweep fire?
        doc.setFullText("First.\n\nThird.\n"); try await doc.flushBurstNow()
        let b = try await doc.opLog().last { $0.kind == .typingBurst }
        let p3 = b!.changes.first { $0.next.contains("Third") }!.paragraphId
        let ann = try await doc.addAnnotation(kind: .comment, paragraphId: p3, body: "later note")
        show("gate/new-annotation-status", String(describing: annotation(doc, ann)?.status))
        show("gate/still-open-after-a-prior-rewind",
             annotation(doc, ann)?.status == .open)
    }
}
