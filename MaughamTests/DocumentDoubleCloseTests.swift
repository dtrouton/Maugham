import XCTest
import MaughamCore
@testable import Maugham

/// Double-close safety for `Document.close()`.
///
/// The zombie-window teardown (workaround 1) closes the Document from
/// `EditorHost.onDisappear`, while `loadDocumentIfNeeded` also closes the prior
/// document on a doc switch. These paths don't overlap in practice (onDisappear
/// fires on segment/window teardown; the switch-close fires while EditorHost
/// stays mounted), but the mitigation's safety argument rests on `close()` being
/// idempotent regardless — so pin it: a second `close()` no-ops (empty pending
/// buffer, trailing autosave no-op, `pending.clear` idempotent) and never records
/// a burst-flush failure.
@MainActor
final class DocumentDoubleCloseTests: XCTestCase {

    private func makeDoc(text: String) async throws -> Document {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoubleClose-\(UUID().uuidString)")
        let manuscriptDir = tmp.appendingPathComponent("manuscript")
        try FileManager.default.createDirectory(
            at: manuscriptDir, withIntermediateDirectories: true)
        let mdURL = manuscriptDir.appendingPathComponent("doc.md")
        try text.write(to: mdURL, atomically: true, encoding: .utf8)
        return try await Document.load(
            url: mdURL, device: "test", session: "s", presenter: nil)
    }

    /// Closing twice does not crash and records no burst-flush failure the second
    /// time — the pending buffer was already cleared by the first close, so the
    /// second `flushBurstNow` has nothing to append and cannot fail.
    func test_close_twice_isSafe() async throws {
        let doc = try await makeDoc(text: "First paragraph.\n\nSecond paragraph.")

        // Make a real edit so the first close has a burst to flush.
        doc.setFullText("First paragraph edited.\n\nSecond paragraph.")

        await doc.close()
        let failuresAfterFirst = doc.closeBurstFlushFailures

        // Second close must be a clean no-op — no crash, no new failure.
        await doc.close()
        XCTAssertEqual(doc.closeBurstFlushFailures, failuresAfterFirst,
            "a second close() must not attempt (or fail) another burst flush")
        XCTAssertEqual(doc.closeBurstFlushFailures, 0,
            "a clean double-close records no burst-flush failure")

        // The edit survives both closes: the op log still carries it.
        let ops = try await doc.opLog()
        let hasEdit = ops.contains { (op: Op) in
            op.changes.contains { (change: Op.ParagraphChange) in
                change.next.contains("edited")
            }
        }
        XCTAssertTrue(hasEdit, "the flushed edit must survive the double close")
    }

    /// `close()` husks the heavy in-memory state after the disk truth is written.
    /// This is the load-bearing memory win: a closed Document's `@State` box can
    /// stay retained by a dead SwiftUI scene graph (we can't nil another view's
    /// @State), so husking makes the stranded instance weightless.
    func test_close_husksHeavyInMemoryState() async throws {
        let doc = try await makeDoc(text: "First paragraph.\n\nSecond paragraph.")
        // Sanity: the heavy state is populated before close.
        XCTAssertFalse(doc.paragraphs.isEmpty)
        XCTAssertFalse(doc.sequence.isEmpty)
        XCTAssertFalse(doc.displayText.isEmpty)
        XCTAssertFalse(doc.opLogSnapshot.isEmpty)

        await doc.close()

        XCTAssertTrue(doc.isClosed, "close() sets isClosed")
        XCTAssertTrue(doc.paragraphs.isEmpty, "close() husks the paragraphs dict")
        XCTAssertTrue(doc.sequence.isEmpty, "close() husks the sequence array")
        XCTAssertTrue(doc.displayText.isEmpty, "close() husks displayText")
        XCTAssertTrue(doc.opLogSnapshot.isEmpty, "close() husks the op-log mirror")

        // Disk truth is untouched by husking — the async accessor reads it back.
        let ops = try await doc.opLog()
        XCTAssertFalse(ops.isEmpty,
            "husking is memory-only: the persisted op log is intact on disk")
    }

    /// A mutation on a closed (husked) doc no-ops rather than resurrecting the
    /// husk. `setFullText` is the documented misuse case (a still-referenced
    /// zombie's editor binding): it must not re-parse the text into empty prior
    /// state and re-populate paragraphs.
    func test_setFullText_onClosedDoc_noOpsWithoutResurrectingHusk() async throws {
        let doc = try await makeDoc(text: "Original paragraph.")
        await doc.close()
        XCTAssertTrue(doc.isClosed)

        doc.setFullText("Resurrected text that must be ignored.")

        XCTAssertTrue(doc.displayText.isEmpty,
            "setFullText on a closed doc must not resurrect displayText")
        XCTAssertTrue(doc.paragraphs.isEmpty,
            "setFullText on a closed doc must not repopulate paragraphs")
    }
}
