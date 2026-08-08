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

    /// Every fixture carries a `kind`, because a diagnostic without one is by
    /// definition a v1 record and `load` drops those as superseded — a
    /// kind-less fixture would vanish on reload for a reason that has nothing
    /// to do with the store's correctness.
    private func makeDiagnostic(
        docId: String, runId: String, anchor: Diagnostic.Anchor? = nil,
        body: String = "A diagnostic note"
    ) -> Diagnostic {
        Diagnostic(
            id: ULID.generate(), docId: docId, anchor: anchor, body: body,
            category: nil, runId: runId, kind: .continuity)
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

    /// **The conformance summary rides on the run record and survives a
    /// relaunch.** Most of what a run checked produces no note at all — a
    /// clause that holds and a clause the delta is silent about are both real
    /// answers — so the list the pane leads with lives here, superseded with
    /// the run that made it rather than beside notes it does not have.
    ///
    /// Task 4 owns this field's own contract; the run that writes it is Task
    /// 3's, so its round trip is pinned here rather than left to a later
    /// commit that could ship after a release.
    func test_roundTrip_carriesTheClausesTheRunChecked() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docClauses"

        var run = makeRun()
        run.clauseStatuses = [
            DiagnosticIngest.ClauseStatus(
                clauseQuote: "Cold, and never wistful.", status: "strains",
                refs: [Diagnostic.Ref(paragraphId: "a1b2", excerpt: "The fog came.")]),
            DiagnosticIngest.ClauseStatus(
                clauseQuote: "Kelly never speaks first.", status: "silent", refs: [])
        ]
        DiagnosticsStore(projectRoot: project, device: device)
            .replace(run: run, diagnostics: [], docId: docId)

        let reopened = DiagnosticsStore(projectRoot: project, device: device)
        reopened.load(docId: docId)
        XCTAssertEqual(reopened.lastRun(docId: docId)?.clauseStatuses, run.clauseStatuses,
                       "quote, status and refs all survive — the refs are what the "
                       + "pane renders as excerpt chips, and a chip with no excerpt "
                       + "is the paragraph id the writer must never see")
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
        XCTAssertNil(store.lastRun(docId: docId)?.clauseStatuses,
            "a run written before the sections existed checked no clauses, and "
            + "an empty list would claim it checked and found nothing")
    }

    /// A sidecar a v1 run wrote decodes clean — the writer's existing file is
    /// never a crash and never a wipe — and its notes are dropped as
    /// superseded: they were written against a contract this build no longer
    /// speaks, and replace-on-run puts them one run from gone regardless. The
    /// run record survives, so the pane can still say when the doc was last
    /// checked.
    func test_aV1SidecarLoadsAndItsNotesAreDroppedAsSuperseded() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docV1"
        let url = DiagnosticsStore.sidecarURL(projectRoot: project, docId: docId, device: device)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Exactly what v1 wrote: no kind, no refs, no clauseQuote.
        try Data("""
            {"diagnostics":[{"anchor":{"anchorText":"steady","paragraphId":"efgh"},\
            "body":"A v1 note","category":"rhythm","docId":"docV1","id":"01JV1",\
            "runId":"01JRUN"}],\
            "run":{"at":"2026-08-04T09:00:00Z","deltaSummary":"1 new, 0 revised",\
            "droppedDangling":0,"id":"01JRUN","lastOpId":"op1","model":"sonnet"}}
            """.utf8).write(to: url)

        let store = DiagnosticsStore(projectRoot: project, device: device)
        store.load(docId: docId)

        XCTAssertEqual(
            store.lastRun(docId: docId)?.model, "sonnet",
            "a v1 file must decode rather than read as a document never checked")
        XCTAssertEqual(
            store.live(docId: docId, currentText: { _ in "steady" }), [],
            "a v1 note is superseded, not migrated")
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

    /// **Refs are display-only, not liveness.** A note's anchor is its first
    /// resolving ref; the other refs are the excerpt chips the pane shows the
    /// writer. When a non-anchor ref's paragraph changes, the note stays live
    /// because the anchor has not moved.
    func test_aChangedRefDoesNotDismissTheNote() {
        let store = DiagnosticsStore(
            projectRoot: URL(fileURLWithPath: "/tmp/unused"),
            device: DeviceSlug.make(from: "test-mac"))
        let docId = "docRefs"
        let run = makeRun()
        // A note anchored to the first ref, with a second display-only ref
        let anchor = Diagnostic.Anchor(paragraphId: "a1b2", anchorText: "The fog came.")
        let refs = [
            Diagnostic.Ref(paragraphId: "a1b2", excerpt: "The fog came."),
            Diagnostic.Ref(paragraphId: "c3d4", excerpt: "Cold, and never…")
        ]
        var diag = makeDiagnostic(docId: docId, runId: run.id, anchor: anchor)
        diag.refs = refs
        store.replace(run: run, diagnostics: [diag], docId: docId)

        // The anchor stays the same, the display ref changes — note stays live
        let live = store.live(docId: docId, currentText: { id in
            id == "a1b2" ? "The fog came." : "New text for the second ref"
        })
        XCTAssertEqual(live.map(\.id), [diag.id],
                       "refs are display, never liveness — anchor alone pins the note")
    }

    /// The truncated-reader count survives the relaunch, so the pane can say
    /// how many reader reports a run discarded over the schema's cap of three.
    func test_roundTrip_carriesTruncatedReaderCount() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docTruncated"

        var run = makeRun()
        run.truncatedReader = 2
        DiagnosticsStore(projectRoot: project, device: device)
            .replace(run: run, diagnostics: [], docId: docId)

        let reopened = DiagnosticsStore(projectRoot: project, device: device)
        reopened.load(docId: docId)
        XCTAssertEqual(reopened.lastRun(docId: docId)?.truncatedReader, 2)
    }

    /// A sidecar written before the truncatedReader field existed decodes as
    /// nil rather than failing — the reader count is optional and honoring its
    /// absence is the contract.
    func test_aSidecarWithoutTruncatedReaderStillLoads() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docNoTruncated"
        let url = DiagnosticsStore.sidecarURL(projectRoot: project, docId: docId, device: device)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Run written before truncatedReader existed (no truncatedReader field)
        try Data("""
            {"diagnostics":[],"run":{"at":"2026-08-04T09:00:00Z","deltaSummary":"1 new, 0 revised",
            "id":"01JABC","lastOpId":"op1","model":"sonnet"}}
            """.utf8).write(to: url)

        let store = DiagnosticsStore(projectRoot: project, device: device)
        store.load(docId: docId)

        XCTAssertEqual(store.lastRun(docId: docId)?.model, "sonnet")
        XCTAssertNil(store.lastRun(docId: docId)?.truncatedReader,
            "a run written before the field existed has no reader truncation to report")
    }
}
