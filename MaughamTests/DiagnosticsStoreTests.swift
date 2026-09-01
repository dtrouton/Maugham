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
        XCTAssertEqual(store.clauseStatusHistory(docId: docId), [])
        XCTAssertEqual(store.roundHistory(docId: docId), [],
                       "the round ring is derived state like everything else here — "
                       + "an unreadable file is a document with no rounds, never a throw")
        XCTAssertNil(store.latestRound(forPass: "pass-line", docId: docId))
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
        let firstRun = makeRun(lastOpId: "op0")
        store.replace(run: firstRun, diagnostics: [], docId: docId)
        let run = makeRun(lastOpId: "op1")
        let note = makeDiagnostic(docId: docId, runId: run.id)
        store.replace(run: run, diagnostics: [note], docId: docId)
        let versionBefore = store.version

        store.advanceMarker(to: "op2", docId: docId)

        XCTAssertEqual(store.lastOpId(docId: docId), "op2")
        XCTAssertEqual(store.roundHistory(docId: docId).map(\.runId), [firstRun.id],
                       "moving the marker copies the whole record — the round ring "
                       + "rides along with the notes")
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
        XCTAssertEqual(reread.roundHistory(docId: docId).map(\.runId), [firstRun.id],
                       "…and so does the ring, or a marker-only run would cost the "
                       + "next one its comparison")
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

    /// A sidecar written before the letter field existed decodes as nil
    /// rather than failing — same tolerated-missing discipline as every other
    /// optional field on `CompilerRun` (global constraint 2).
    func test_aSidecarWithoutLetterStillLoads() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docNoLetter"
        let url = DiagnosticsStore.sidecarURL(projectRoot: project, docId: docId, device: device)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Run written before letter existed (no letter field at all).
        try Data("""
            {"diagnostics":[],"run":{"at":"2026-08-04T09:00:00Z","deltaSummary":"1 new, 0 revised",
            "id":"01JABC","lastOpId":"op1","model":"sonnet"}}
            """.utf8).write(to: url)

        let store = DiagnosticsStore(projectRoot: project, device: device)
        store.load(docId: docId)

        XCTAssertEqual(store.lastRun(docId: docId)?.model, "sonnet")
        XCTAssertNil(store.lastRun(docId: docId)?.letter,
            "a run written before the field existed has no letter to report")
    }

    /// A run WITH a letter reloads with the letter equal — the other half of
    /// the compatibility contract (write, not just tolerated-missing read).
    func test_aSidecarWithALetter_reloadsWithTheLetterEqual() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docWithLetter"

        let letter = Letter(
            about: "The middle third pulls its punches.", oneThing: "let Marta want something",
            working: [Letter.Working(
                refs: [Diagnostic.Ref(paragraphId: "a1b2", excerpt: "excerpt")],
                what: "the opening", why: "it moves")],
            habits: [], questions: [], scenes: nil, scenePosition: nil)
        var run = makeRun()
        run.letter = letter
        DiagnosticsStore(projectRoot: project, device: device)
            .replace(run: run, diagnostics: [], docId: docId)

        let reopened = DiagnosticsStore(projectRoot: project, device: device)
        reopened.load(docId: docId)
        XCTAssertEqual(reopened.lastRun(docId: docId)?.letter, letter)
    }

    /// **The scene position is a DISK format** (editorial letter P1 Task 3).
    /// `Letter.scenePosition` carries `ScenePosition.rawValue`, so the four
    /// snake_case strings are what a sidecar holds — renaming a case reads
    /// back as an unrecognised string on every letter already written, and the
    /// pane would lose the position it needs to know whether the table's
    /// turn-less rows were strains or observations.
    func test_theScenePositionRoundTripsAsItsRawString() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docScenePosition"

        var run = makeRun()
        run.letter = Letter(
            about: "A woman waits out a fog.", oneThing: nil,
            working: [], habits: [], questions: [], scenes: nil,
            scenePosition: ScenePosition.strongDefault.rawValue)
        DiagnosticsStore(projectRoot: project, device: device)
            .replace(run: run, diagnostics: [], docId: docId)

        let url = DiagnosticsStore.sidecarURL(projectRoot: project, docId: docId, device: device)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"strong_default\""),
                      "the raw value is what reaches the file; got \(raw)")

        let reopened = DiagnosticsStore(projectRoot: project, device: device)
        reopened.load(docId: docId)
        XCTAssertEqual(reopened.lastRun(docId: docId)?.letter?.scenePosition, "strong_default")
    }

    /// …and a letter written before the position existed still loads, with no
    /// position rather than a failure — global constraint 2's tolerated-missing
    /// discipline, one field deeper than `test_aSidecarWithoutLetterStillLoads`
    /// reaches.
    func test_aLetterWithoutAScenePositionStillLoads() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docLetterNoPosition"
        let url = DiagnosticsStore.sidecarURL(projectRoot: project, docId: docId, device: device)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            {"diagnostics":[],"run":{"at":"2026-08-04T09:00:00Z","deltaSummary":"1 new, 0 revised",
            "id":"01JABC","lastOpId":"op1","model":"sonnet",
            "letter":{"about":"A woman waits out a fog.","working":[],"habits":[],
            "questions":[]}}}
            """.utf8).write(to: url)

        let store = DiagnosticsStore(projectRoot: project, device: device)
        store.load(docId: docId)

        XCTAssertEqual(store.lastRun(docId: docId)?.letter?.about, "A woman waits out a fog.")
        XCTAssertNil(store.lastRun(docId: docId)?.letter?.scenePosition)
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

    // MARK: - Clause-status history (the drift ring, Task 1)

    /// The ring is a separate append, never a mirror of the run record:
    /// `replace` supersedes `run`/`diagnostics` every time, and the ring is
    /// exactly the thing that must survive that supersession — see
    /// `DriftDetector`.
    func test_clauseStatusHistory_appendsOnEveryReplaceThatCarriesStatuses() {
        let store = DiagnosticsStore(
            projectRoot: URL(fileURLWithPath: "/tmp/unused"),
            device: DeviceSlug.make(from: "test-mac"))
        let docId = "docHistory"

        let statusesA = [DiagnosticIngest.ClauseStatus(
            clauseQuote: "Cold, and never wistful.", status: "strains", refs: [])]
        var run1 = makeRun()
        run1.clauseStatuses = statusesA
        store.replace(run: run1, diagnostics: [], docId: docId)

        let statusesB = [DiagnosticIngest.ClauseStatus(
            clauseQuote: "Cold, and never wistful.", status: "holds", refs: [])]
        var run2 = makeRun()
        run2.clauseStatuses = statusesB
        store.replace(run: run2, diagnostics: [], docId: docId)

        XCTAssertEqual(store.clauseStatusHistory(docId: docId), [statusesA, statusesB],
            "oldest first, newest last")
    }

    /// `nil` (nothing declared to check) and `[]` (checked, found nothing
    /// straining) are different answers — only `nil` leaves no mark on the
    /// ring.
    func test_clauseStatusHistory_aRunWithNilStatusesDoesNotAppend() {
        let store = DiagnosticsStore(
            projectRoot: URL(fileURLWithPath: "/tmp/unused"),
            device: DeviceSlug.make(from: "test-mac"))
        let docId = "docNoStatuses"

        let statuses = [DiagnosticIngest.ClauseStatus(
            clauseQuote: "Cold, and never wistful.", status: "strains", refs: [])]
        var run1 = makeRun()
        run1.clauseStatuses = statuses
        store.replace(run: run1, diagnostics: [], docId: docId)

        let run2 = makeRun() // clauseStatuses defaults to nil
        store.replace(run: run2, diagnostics: [], docId: docId)

        XCTAssertEqual(store.clauseStatusHistory(docId: docId), [statuses],
            "the second run checked nothing, so it leaves the ring untouched")
    }

    func test_clauseStatusHistory_capsAtDepth_oldestDropped() {
        let store = DiagnosticsStore(
            projectRoot: URL(fileURLWithPath: "/tmp/unused"),
            device: DeviceSlug.make(from: "test-mac"))
        let docId = "docCap"

        var expected: [[DiagnosticIngest.ClauseStatus]] = []
        for i in 0..<(DiagnosticsStore.clauseHistoryDepth + 2) {
            let statuses = [DiagnosticIngest.ClauseStatus(
                clauseQuote: "clause \(i)", status: "strains", refs: [])]
            var run = makeRun()
            run.clauseStatuses = statuses
            store.replace(run: run, diagnostics: [], docId: docId)
            expected.append(statuses)
        }

        XCTAssertEqual(
            store.clauseStatusHistory(docId: docId),
            Array(expected.suffix(DiagnosticsStore.clauseHistoryDepth)),
            "the oldest entries fall off the ring, never the newest")
    }

    func test_clauseStatusHistory_roundTripsThroughRelaunch() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docHistoryRoundTrip"

        let statuses = [DiagnosticIngest.ClauseStatus(
            clauseQuote: "Kelly never speaks first.", status: "strains",
            refs: [Diagnostic.Ref(paragraphId: "a1b2", excerpt: "Kelly spoke.")])]
        var run = makeRun()
        run.clauseStatuses = statuses
        DiagnosticsStore(projectRoot: project, device: device)
            .replace(run: run, diagnostics: [], docId: docId)

        let reopened = DiagnosticsStore(projectRoot: project, device: device)
        reopened.load(docId: docId)
        XCTAssertEqual(reopened.clauseStatusHistory(docId: docId), [statuses])
    }

    /// A v1 sidecar (no `clauseStatuses` on the run at all, from before Task
    /// 3) still loads, with an empty ring — never a crash, never a wipe of
    /// the run record.
    func test_aV1SidecarWithNoClauseStatuses_stillLoads_withEmptyRing() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docLegacyHistory"
        let url = DiagnosticsStore.sidecarURL(projectRoot: project, docId: docId, device: device)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            {"diagnostics":[],"run":{"at":"2026-08-04T09:00:00Z","deltaSummary":"1 new, 0 revised",
            "id":"01JABC","lastOpId":"op1","model":"sonnet"}}
            """.utf8).write(to: url)

        let store = DiagnosticsStore(projectRoot: project, device: device)
        store.load(docId: docId)

        XCTAssertEqual(store.clauseStatusHistory(docId: docId), [],
            "a sidecar written before the ring existed has nothing to report, not a crash")
    }

    /// A v2 sidecar (Task 3: `clauseStatuses` on the run, but written before
    /// the ring existed) also loads clean, with an empty ring rather than a
    /// backfill from the standing run — the ring is only ever written by
    /// `replace`, never reconstructed on load.
    func test_aV2SidecarWithClauseStatusesButNoRing_stillLoads_withEmptyRing() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docV2NoRing"
        let url = DiagnosticsStore.sidecarURL(projectRoot: project, docId: docId, device: device)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            {"diagnostics":[],"run":{"at":"2026-08-04T09:00:00Z","deltaSummary":"1 new, 0 revised",
            "id":"01JABC","lastOpId":"op1","model":"sonnet",\
            "clauseStatuses":[{"clauseQuote":"Cold.","status":"strains","refs":[]}]}}
            """.utf8).write(to: url)

        let store = DiagnosticsStore(projectRoot: project, device: device)
        store.load(docId: docId)

        XCTAssertEqual(store.lastRun(docId: docId)?.clauseStatuses?.first?.clauseQuote, "Cold.",
            "the run record still carries what it checked")
        XCTAssertEqual(store.clauseStatusHistory(docId: docId), [],
            "the ring starts empty rather than backfilling from the standing run")
    }

    /// `replace` supersedes the standing run and notes every time; the ring
    /// must not be swept along with them (doc-comment on the ring: history
    /// outlives runs by design — drift needs what replace forgets).
    func test_replace_doesNotClearThePreviouslyAppendedHistory() {
        let store = DiagnosticsStore(
            projectRoot: URL(fileURLWithPath: "/tmp/unused"),
            device: DeviceSlug.make(from: "test-mac"))
        let docId = "docHistoryPersists"

        let statuses = [DiagnosticIngest.ClauseStatus(
            clauseQuote: "Cold, and never wistful.", status: "strains", refs: [])]
        var run1 = makeRun()
        run1.clauseStatuses = statuses
        store.replace(run: run1, diagnostics: [], docId: docId)

        let plainRun = makeRun()
        let note = makeDiagnostic(docId: docId, runId: plainRun.id)
        store.replace(run: plainRun, diagnostics: [note], docId: docId)

        XCTAssertEqual(store.clauseStatusHistory(docId: docId), [statuses],
            "replace-on-run supersedes the standing notes, never the drift ring")
        XCTAssertEqual(store.lastRun(docId: docId)?.id, plainRun.id,
            "the run record itself still supersedes normally")
    }

    // MARK: - The cold-start offer's refusal memory (Stage 3)

    /// **Not `/tmp/unused`** — every other test in this file gets away with
    /// that shared, fixed path because it only exercises `replace`/`dismiss`,
    /// which never read a sidecar back on init. `refusedColdStart` is loaded
    /// EAGERLY at `init()` (`refusedColdStart`'s own doc), so a fixed path
    /// reused across separate invocations of this test binary is a real
    /// cross-run leak: a `docId` refused by a PRIOR run of this very test is
    /// still marked refused in the file the NEXT run's fresh store reads at
    /// construction — measured live (`XCTAssertFalse` on a brand-new store
    /// failed because a previous run's own write was still on disk).
    func test_refuseColdStart_isRememberedAndBumpsVersion() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "doc-refuse"

        XCTAssertFalse(store.hasRefusedColdStart(docId: docId))
        let versionBefore = store.version

        store.refuseColdStart(docId: docId)

        XCTAssertTrue(store.hasRefusedColdStart(docId: docId))
        XCTAssertGreaterThan(store.version, versionBefore,
            "the pane's `showsColdStartOffer` re-render must be able to key off this")
    }

    /// A second refusal of an already-refused document changes nothing —
    /// no version bump the pane would re-render for pointlessly.
    func test_refuseColdStart_aSecondRefusalIsANoOp() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "doc-refuse-twice"
        store.refuseColdStart(docId: docId)
        let versionAfterFirst = store.version

        store.refuseColdStart(docId: docId)

        XCTAssertEqual(store.version, versionAfterFirst)
    }

    /// **The refusal is a bit a document can carry before it has ever been
    /// run at all** — before `FileContent` for it exists, unlike every other
    /// record this store keeps. Refusing an unrun document must not
    /// fabricate a run or otherwise change what `lastRun`/`live` report.
    func test_refuseColdStart_worksForADocumentWithNoRunAtAll_andMintsNoRun() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "doc-never-run"

        store.refuseColdStart(docId: docId)

        XCTAssertTrue(store.hasRefusedColdStart(docId: docId))
        XCTAssertNil(store.lastRun(docId: docId))
        XCTAssertEqual(store.live(docId: docId, currentText: { _ in nil }), [])
    }

    /// Persisted immediately and survives a relaunch — a fresh store instance
    /// against the same project and device must still say "refused" without
    /// `load(docId:)` ever being called for it, since `refusedColdStart` is
    /// read once at `init` rather than lazily per document.
    func test_refuseColdStart_survivesRelaunch() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "doc-refuse-relaunch"

        let store1 = DiagnosticsStore(projectRoot: project, device: device)
        store1.refuseColdStart(docId: docId)

        let store2 = DiagnosticsStore(projectRoot: project, device: device)
        XCTAssertTrue(store2.hasRefusedColdStart(docId: docId))
    }

    /// Per-device, on the same discipline as every other sidecar here: a
    /// refusal recorded on one Mac must not silence the offer's own "never
    /// re-asked" promise on a document a DIFFERENT device has never seen
    /// refused.
    func test_refuseColdStart_isPerDevice() throws {
        let project = try makeProject()
        let docId = "doc-refuse-cross-device"

        let storeA = DiagnosticsStore(
            projectRoot: project, device: DeviceSlug.make(from: "mac-a"))
        storeA.refuseColdStart(docId: docId)

        let storeB = DiagnosticsStore(
            projectRoot: project, device: DeviceSlug.make(from: "mac-b"))
        XCTAssertFalse(storeB.hasRefusedColdStart(docId: docId))
    }

    /// A missing or corrupt refusal file reads as empty, the same
    /// derived-state contract every other sidecar in this store follows —
    /// losing it costs nothing worse than the offer asking once more.
    func test_refuseColdStart_corruptFileReadsAsEmpty() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let url = project
            .appendingPathComponent(".maugham/diagnostics")
            .appendingPathComponent("cold-start-refused.\(device.raw).json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        let store = DiagnosticsStore(projectRoot: project, device: device)

        XCTAssertFalse(store.hasRefusedColdStart(docId: "anything"))
    }
}
