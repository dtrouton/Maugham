import XCTest
import MaughamCore
@testable import Maugham

/// ADR 0019: the on-disk manuscript file is the clean display form — standard
/// Markdown/Fountain with NO `<!-- ¶id -->` paragraph anchors and NO
/// `<!--t-XXXXXX-->` inline-task anchors. The anchors are the op-log join key
/// and live ONLY in the op log + the in-memory NSTextStorage/`paragraphs`.
///
/// These tests pin the autosave WRITE site (the only place that strips on the
/// way to disk). `materialize()` is unchanged and still emits anchors — that is
/// the in-memory/op-log form, and it is what restores the anchors on reload.
@MainActor
final class CleanMdWriteTests: XCTestCase {

    // MARK: - Fixture (mirrors DocumentTests / DocumentTasksTests)

    private func makeProject(initialMd: String = "Hello.") throws -> (URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLEANMD-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docPath = "manuscript/c1.md"
        try initialMd.data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docPath))
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: "doc-test", title: "C1", type: .document,
                path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, docPath)
    }

    private func diskBytes(_ project: URL, _ path: String) throws -> String {
        try String(contentsOf: project.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - Test 1 — clean file round-trips through a reload

    /// A doc with several paragraphs (one an inline task) autosaves a CLEAN
    /// `.md` (no `¶`/`t-` anchors), yet reloading restores identical content +
    /// ordering — because the op log, not the `.md`, carries the anchored truth.
    func test_autosave_writesCleanFile_roundTrips() async throws {
        let (project, path) = try makeProject(
            initialMd: "First paragraph.\n\n- [ ] do it\n\nThird paragraph.")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)

        // Reading tasks mints the inline `<!--t-…-->` anchor into the task
        // paragraph (in-memory + op log). materialize() now carries BOTH anchor
        // kinds; the editor-facing displayText strips them.
        _ = doc.tasks(filter: .init(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))

        // Snapshot the in-memory truth BEFORE the write/reload.
        let beforeIds = ParagraphParser.parse(doc.materialize()).compactMap(\.id)
        let beforeDisplay = doc.displayText
        XCTAssertEqual(beforeIds.count, 3, "three paragraphs expected")

        // close() flushes the burst (→ op log) and the autosave (→ .md write).
        await doc.close()

        // The ON-DISK file is clean: neither anchor kind survives to disk.
        let disk = try diskBytes(project, path)
        XCTAssertFalse(disk.contains("<!-- ¶"),
            "ADR 0019: the on-disk .md must not carry paragraph anchors; got:\n\(disk)")
        XCTAssertFalse(disk.contains("<!--t-"),
            "ADR 0019: the on-disk .md must not carry inline-task anchors; got:\n\(disk)")
        // The clean file is still the readable manuscript content.
        XCTAssertTrue(disk.contains("First paragraph."))
        XCTAssertTrue(disk.contains("- [ ] do it"))
        XCTAssertTrue(disk.contains("Third paragraph."))

        // Reload: content + paragraph ORDER must match, and the op log must
        // restore the anchors in-memory (materialize() carries them again).
        let reopened = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        let afterIds = ParagraphParser.parse(reopened.materialize()).compactMap(\.id)
        XCTAssertEqual(afterIds, beforeIds,
            "paragraph ids + order must survive the clean-file round-trip via the op log")
        XCTAssertEqual(reopened.displayText, beforeDisplay,
            "content + order must round-trip unchanged through the clean file")
        let reopenedMaterialized = reopened.materialize()
        XCTAssertTrue(reopenedMaterialized.contains("<!-- ¶"),
            "op log must restore paragraph anchors into the in-memory form on reload")
        XCTAssertTrue(reopenedMaterialized.contains("<!--t-"),
            "op log must restore the inline-task anchor into the in-memory form on reload")
    }

    // MARK: - Test 2 — an inline task derives again through the clean file

    /// An inline checkbox task survives the clean-file round-trip: its `t-`
    /// anchor is stripped from disk, yet the task still derives after a reload.
    /// (This pins task *derivation* through the clean file; Test 1 is the one
    /// that proves the op log specifically *persists* the anchor — here the
    /// checkbox text alone could re-mint it, which is also a valid outcome.)
    func test_inlineTask_roundTrips_throughCleanFile() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)

        // Turn the first paragraph into an inline checkbox, then derive (mints
        // the `<!--t-…-->` anchor into the op log + in-memory paragraph).
        guard let pid = try await {
            let log = try await doc.opLog()
            return log.first { $0.kind == .bootstrap }?.changes.first?.paragraphId
        }() else {
            return XCTFail("no bootstrap paragraph")
        }
        doc.setParagraph(id: pid, text: "- [ ] do it")
        let tasks = doc.tasks(filter: .init(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.kind, .inlineMarkdown)
        XCTAssertEqual(tasks.first?.body, "do it")

        await doc.close()

        // The on-disk file lacks the inline-task anchor (clean display form).
        let disk = try diskBytes(project, path)
        XCTAssertFalse(disk.contains("<!--t-"),
            "the inline-task anchor must not survive to disk; got:\n\(disk)")
        XCTAssertTrue(disk.contains("- [ ] do it"),
            "the checkbox text itself is clean Markdown and stays on disk")

        // Reload: the op log kept the anchor, so the inline task still derives.
        let reopened = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        let reopenedTasks = reopened.tasks(filter: .init(
            scope: .document(docId: reopened.docId),
            statuses: Set(TaskStatus.allCases)))
        XCTAssertEqual(reopenedTasks.count, 1,
            "the inline task must re-derive after the clean-file round-trip")
        XCTAssertEqual(reopenedTasks.first?.kind, .inlineMarkdown)
        XCTAssertEqual(reopenedTasks.first?.body, "do it")
    }

    // MARK: - Test 3 — an external clean edit is discarded (invariant A)

    /// Overwriting the clean `.md` externally with different content does NOT
    /// mutate the op log; the external-change handler re-materializes the op-log
    /// truth over the external bytes immediately (no separate autosave), and a
    /// forensic copy of the discarded bytes lands under `.maugham/conflicts/`.
    /// Proves invariant A holds with clean bytes (ADR 0019).
    func test_externalCleanEdit_isDiscarded_opLogUnchanged() async throws {
        let (project, path) = try makeProject(initialMd: "Canonical sentence.\n")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)
        // Write the clean .md to disk while keeping the doc LIVE. (This used to
        // call `close()`, but close() now husks the instance — abandoned by
        // contract — so it can no longer be used as a flush shortcut for a doc
        // that keeps handling external changes below. `performAutosave` writes
        // the same clean derived form and seeds `lastDiskEcho`.)
        try await doc.performAutosave()

        let opCountBefore = doc.opLogMirrorCount
        let materializeBefore = doc.materialize()

        // An outside editor overwrites the file with different CLEAN content
        // (no anchors — exactly what ADR 0019 leaves on disk).
        let external = "Completely different external text.\n"
        try external.data(using: .utf8)!.write(
            to: project.appendingPathComponent(path))

        // A single external-change call discards the edit: backs up the bytes,
        // then re-materializes the op-log truth over them (its own autosave
        // flush) — no separate performAutosave needed.
        try await doc.handleExternalDiskChange(diskMd: external)

        // The op log is the source of truth: it is UNCHANGED, and the in-memory
        // derived state still reflects the op log, not the external bytes.
        XCTAssertEqual(doc.opLogMirrorCount, opCountBefore,
            "an external .md edit must not append a content op to the source-of-truth log")
        XCTAssertEqual(doc.materialize(), materializeBefore,
            "the derived state must still be the op-log truth, not the external bytes")
        XCTAssertFalse(doc.displayText.contains("Completely different external text"),
            "external bytes must never become the in-memory truth")

        // The on-disk file is ALREADY re-materialized to the op-log truth — the
        // discard handler wrote it, no extra autosave required.
        let disk = try diskBytes(project, path)
        XCTAssertTrue(disk.contains("Canonical sentence."),
            "the discard handler must re-materialize the op-log truth back over the external edit")
        XCTAssertFalse(disk.contains("Completely different external text"),
            "the external edit must be blown away by the op-log re-materialize")
        XCTAssertFalse(disk.contains("<!-- ¶"),
            "the re-written file stays clean (no paragraph anchors)")

        // A forensic backup of the discarded external bytes lands under
        // .maugham/conflicts/ so nothing the writer typed is silently lost.
        let conflictsDir = project.appendingPathComponent(".maugham/conflicts")
        let backups = try FileManager.default.contentsOfDirectory(
            at: conflictsDir, includingPropertiesForKeys: nil)
        XCTAssertFalse(backups.isEmpty,
            "a forensic backup of the discarded external bytes must be written")
        let backupContents = try backups.map {
            try String(contentsOf: $0, encoding: .utf8)
        }
        XCTAssertTrue(backupContents.contains(external),
            "the backup must contain the exact discarded external bytes")
    }
}
