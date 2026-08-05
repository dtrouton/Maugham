import XCTest
@testable import Maugham
import MaughamCore

@MainActor
final class DiagnosticsStoreTests: XCTestCase {
    private func makeProject() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsStore-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeRun(lastOpId: String = ULID.generate()) -> CompilerRun {
        // Whole-second `at`: ISO8601 round-tripping through the sidecar
        // truncates fractional seconds (same rounding the manifest's
        // `modified` field already lives with), so a sub-second `Date()`
        // fixture would fail equality after a save/load cycle for a reason
        // that has nothing to do with the store's correctness.
        let wholeSecond = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        return CompilerRun(
            id: ULID.generate(), at: wholeSecond, model: "test-model",
            lastOpId: lastOpId, deltaSummary: "3 new, 2 revised \u{00b6}",
            intentSnapshot: "intent snapshot")
    }

    private func makeDiagnostic(
        docId: String, runId: String, anchor: Diagnostic.Anchor? = nil,
        body: String = "A diagnostic note"
    ) -> Diagnostic {
        Diagnostic(
            id: ULID.generate(), docId: docId, anchor: anchor, body: body,
            category: "test", runId: runId)
    }

    func test_sidecarFilename_isPerDevice_andTakesDeviceSlug() {
        let project = URL(fileURLWithPath: "/tmp/project")
        let slug = DeviceSlug.make(from: "Denvers-Mac.local")
        let url = DiagnosticsStore.sidecarURL(
            projectRoot: project, docId: "doc123", device: slug)
        XCTAssertEqual(
            url.path,
            project.appendingPathComponent(".maugham/diagnostics/doc123.\(slug.raw).json").path)
    }

    func test_replace_dropsThePreviousRunsDiagnostics() {
        let store = DiagnosticsStore(
            projectRoot: URL(fileURLWithPath: "/tmp/unused"),
            device: DeviceSlug.make(from: "test-mac"))
        let docId = "docA"

        let run1 = makeRun()
        let diag1 = makeDiagnostic(docId: docId, runId: run1.id)
        store.replace(run: run1, diagnostics: [diag1], docId: docId)
        let versionAfterFirst = store.version

        let run2 = makeRun()
        let diag2 = makeDiagnostic(docId: docId, runId: run2.id)
        store.replace(run: run2, diagnostics: [diag2], docId: docId)

        let live = store.live(docId: docId, currentText: { _ in diag2.anchor?.anchorText })
        XCTAssertEqual(live.map(\.id), [diag2.id])
        XCTAssertFalse(live.contains { $0.id == diag1.id })
        XCTAssertGreaterThan(store.version, versionAfterFirst)
        XCTAssertEqual(store.lastRun(docId: docId)?.id, run2.id)
    }

    func test_live_filtersAnchoredNotesWhoseParagraphChanged() {
        let store = DiagnosticsStore(
            projectRoot: URL(fileURLWithPath: "/tmp/unused"),
            device: DeviceSlug.make(from: "test-mac"))
        let docId = "docB"
        let run = makeRun()
        let anchor = Diagnostic.Anchor(paragraphId: "abcd", anchorText: "old")
        let diag = makeDiagnostic(docId: docId, runId: run.id, anchor: anchor)
        store.replace(run: run, diagnostics: [diag], docId: docId)

        XCTAssertEqual(
            store.live(docId: docId, currentText: { _ in "new" }).map(\.id), [])
        XCTAssertEqual(
            store.live(docId: docId, currentText: { _ in "old" }).map(\.id), [diag.id])
        XCTAssertEqual(
            store.live(docId: docId, currentText: { _ in nil }).map(\.id), [])
    }

    func test_live_keepsDriftNotesRegardlessOfText() {
        let store = DiagnosticsStore(
            projectRoot: URL(fileURLWithPath: "/tmp/unused"),
            device: DeviceSlug.make(from: "test-mac"))
        let docId = "docC"
        let run = makeRun()
        let drift = makeDiagnostic(docId: docId, runId: run.id, anchor: nil, body: "drift note")
        store.replace(run: run, diagnostics: [drift], docId: docId)

        XCTAssertEqual(
            store.live(docId: docId, currentText: { _ in nil }).map(\.id), [drift.id])
        XCTAssertEqual(
            store.live(docId: docId, currentText: { _ in "anything" }).map(\.id), [drift.id])

        store.dismiss(drift.id, docId: docId)
        XCTAssertEqual(store.live(docId: docId, currentText: { _ in nil }), [])
    }

    func test_roundTrip_survivesRelaunch() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docD"

        let store1 = DiagnosticsStore(projectRoot: project, device: device)
        let run = makeRun()
        let anchor = Diagnostic.Anchor(paragraphId: "efgh", anchorText: "steady")
        let diag = makeDiagnostic(docId: docId, runId: run.id, anchor: anchor)
        store1.replace(run: run, diagnostics: [diag], docId: docId)

        let store2 = DiagnosticsStore(projectRoot: project, device: device)
        store2.load(docId: docId)

        XCTAssertEqual(store2.lastRun(docId: docId), run)
        XCTAssertEqual(
            store2.live(docId: docId, currentText: { _ in "steady" }), [diag])
    }

    /// What a run lost survives the relaunch, because "Nothing to flag." is a
    /// claim the pane makes off the sidecar long after the run.
    func test_roundTrip_carriesWhatTheRunDiscarded() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docDropped"

        var run = makeRun()
        run.droppedDangling = 3
        DiagnosticsStore(projectRoot: project, device: device)
            .replace(run: run, diagnostics: [], docId: docId)

        let reopened = DiagnosticsStore(projectRoot: project, device: device)
        reopened.load(docId: docId)
        XCTAssertEqual(reopened.lastRun(docId: docId)?.droppedDangling, 3)
    }

    /// A sidecar written before the field existed decodes as zero rather than
    /// failing the whole file — an undecodable sidecar reads as empty, which
    /// would tell the writer their document had never been checked.
    func test_aSidecarWithoutTheDiscardCountStillLoads() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docLegacy"
        let url = DiagnosticsStore.sidecarURL(projectRoot: project, docId: docId, device: device)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            {"diagnostics":[],"run":{"at":"2026-08-04T09:00:00Z","deltaSummary":"1 new, 0 revised",
            "id":"01JABC","lastOpId":"op1","model":"sonnet"}}
            """.utf8).write(to: url)

        let store = DiagnosticsStore(projectRoot: project, device: device)
        store.load(docId: docId)

        XCTAssertEqual(store.lastRun(docId: docId)?.model, "sonnet",
            "the record must still load")
        XCTAssertEqual(store.lastRun(docId: docId)?.droppedDangling, 0)
    }

    func test_corruptSidecar_readsAsEmpty_neverThrows() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docE"
        let url = DiagnosticsStore.sidecarURL(projectRoot: project, docId: docId, device: device)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0x00, 0x13, 0x37]).write(to: url)

        let store = DiagnosticsStore(projectRoot: project, device: device)
        store.load(docId: docId)

        XCTAssertEqual(store.live(docId: docId, currentText: { _ in "anything" }), [])
        XCTAssertNil(store.lastRun(docId: docId))
    }

    func test_dismiss_removesOneNote_andBumpsVersion() {
        let store = DiagnosticsStore(
            projectRoot: URL(fileURLWithPath: "/tmp/unused"),
            device: DeviceSlug.make(from: "test-mac"))
        let docId = "docF"
        let run = makeRun()
        let diagA = makeDiagnostic(docId: docId, runId: run.id, body: "keep me")
        let diagB = makeDiagnostic(docId: docId, runId: run.id, body: "drop me")
        store.replace(run: run, diagnostics: [diagA, diagB], docId: docId)
        let versionBeforeDismiss = store.version

        store.dismiss(diagB.id, docId: docId)

        let live = store.live(docId: docId, currentText: { _ in nil })
        XCTAssertEqual(live.map(\.id), [diagA.id])
        XCTAssertGreaterThan(store.version, versionBeforeDismiss)
    }

    /// The empty-delta run (M2 Task 7): ops landed that changed no prose, so
    /// there is nothing to ask about and nothing to replace — but the marker
    /// must pass them or every later run re-walks them. `replace` cannot do
    /// this: it would drop the standing notes for a run that produced none.
    func test_advanceMarker_movesTheMarkerAndKeepsTheNotes() throws {
        let project = try makeProject()
        let store = DiagnosticsStore(
            projectRoot: project, device: DeviceSlug.make(from: "test-mac"))
        let docId = "docG"
        let run = makeRun(lastOpId: "op1")
        let note = makeDiagnostic(docId: docId, runId: run.id)
        store.replace(run: run, diagnostics: [note], docId: docId)
        let versionBefore = store.version

        store.advanceMarker(to: "op2", docId: docId)

        XCTAssertEqual(store.lastOpId(docId: docId), "op2")
        XCTAssertEqual(store.live(docId: docId, currentText: { _ in nil }).map(\.id),
                       [note.id],
                       "a run that produced nothing does not clear the last one's notes")
        XCTAssertGreaterThan(store.version, versionBefore)

        // …and it survives the sidecar, or the next launch re-reads ops this
        // machine has already checked.
        let reread = DiagnosticsStore(
            projectRoot: project, device: DeviceSlug.make(from: "test-mac"))
        reread.load(docId: docId)
        XCTAssertEqual(reread.lastOpId(docId: docId), "op2")
    }

    /// A document nobody has ever run against has no marker to move: the marker
    /// is a property of a run that happened. Asserted rather than left to the
    /// `guard`, because the alternative — synthesising a run record — would put
    /// a "last run" line in the pane for a run that never occurred.
    func test_advanceMarker_onADocWithNoRunIsANoOp() {
        let store = DiagnosticsStore(
            projectRoot: URL(fileURLWithPath: "/tmp/unused"),
            device: DeviceSlug.make(from: "test-mac"))

        store.advanceMarker(to: "op2", docId: "never-run")

        XCTAssertNil(store.lastOpId(docId: "never-run"))
        XCTAssertNil(store.lastRun(docId: "never-run"))
    }
}
