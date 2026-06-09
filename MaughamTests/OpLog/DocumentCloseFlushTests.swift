// MaughamTests/OpLog/DocumentCloseFlushTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// Regression for the Tier-0 silent-manuscript-loss bug (sweep 7): when the
/// op-log append inside `flushBurstNow` fails on `close()`, the final burst of
/// edits must NOT be silently dropped. `close()` ran `try? await flushBurstNow()`,
/// swallowing the error — the edits you most want to survive (the last burst
/// before quit/FS-surgery) were lost with no signal and no durable re-persist.
///
/// The fix: on append failure the in-memory `PendingBuffer` is still intact
/// (`pending.clear()` runs only after a successful append), so `close()`
/// durably flushes it to `.maugham/pending/<docId>.<slug>.pending.jsonl` for
/// crash recovery, and records the failure non-silently.
@MainActor
final class DocumentCloseFlushTests: XCTestCase {

    private func makeProject(initialMd: String = "") throws -> (URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DOCCLOSE-\(UUID().uuidString)")
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

    private struct InjectedDiskError: Error {}

    /// The core regression: a failing burst-append on `close()` must persist
    /// the pending changes durably (to the `.pending.jsonl` recovery file)
    /// rather than silently dropping them.
    func test_close_failingBurstAppend_persistsPendingForRecovery() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.\n")
        let doc = try await Document.load(
            url: project.appendingPathComponent(path),
            device: "m", session: "s", presenter: nil)

        // Type the burst we most want to survive.
        doc.setFullText("Hello world — the last burst before close.")

        // Arm the disk-error: the next op-log append throws.
        doc.opStore.appendFailureForTesting = InjectedDiskError()

        // close() runs the burst flush. The append fails — but the edits must
        // survive durably on disk for crash recovery, not vanish.
        await doc.close()

        // The failure must be SURFACED, not swallowed: close() handled it
        // (logged + explicit pending re-flush), recorded by the counter. The
        // unfixed `try? await flushBurstNow()` swallowed it silently → 0.
        XCTAssertEqual(
            doc.closeBurstFlushFailures, 1,
            "close() must surface the burst-flush failure non-silently, not "
            + "swallow it with `try?`.")

        let slug = DeviceSlug.make(from: "m")
        let pendingURL = project
            .appendingPathComponent(".maugham/pending")
            .appendingPathComponent("\(doc.docId).\(slug).pending.jsonl")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: pendingURL.path),
            "close() must durably flush the still-intact pending buffer to "
            + ".pending.jsonl when the burst append fails — otherwise the final "
            + "burst of edits is silently lost.")

        // And the recovered bytes must be the burst we typed.
        let recovered = PendingBuffer(projectURL: project, docId: doc.docId, device: "m")
        try await recovered.loadFromDisk()
        let texts = recovered.snapshot().map(\.next)
        XCTAssertTrue(
            texts.contains(where: { $0.contains("the last burst before close") }),
            "Recovery file must carry the lost burst's text; got \(texts)")
    }

    /// Reopening the project after the failed-close recovers the burst into the
    /// op log via the normal crash-recovery path — proving end-to-end durability.
    func test_close_failingBurstAppend_isRecoveredOnReload() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.\n")
        let url = project.appendingPathComponent(path)

        do {
            let doc = try await Document.load(
                url: url, device: "m", session: "s", presenter: nil)
            doc.setFullText("Surviving edit.")
            doc.opStore.appendFailureForTesting = InjectedDiskError()
            await doc.close()
        }

        // Session 2: a clean reload (append now works) must fold the recovered
        // pending into a real burst op.
        let reopened = try await Document.load(
            url: url, device: "m", session: "s", presenter: nil)
        XCTAssertTrue(
            reopened.displayText.contains("Surviving edit."),
            "The burst dropped by the failing close must come back on reload via "
            + "pending-buffer crash recovery; got \(reopened.displayText)")
    }
}
