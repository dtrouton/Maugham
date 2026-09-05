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
        // Two rounds, so the ring below has something in it to ride along: a
        // check contributes nothing to it (two loops P1 Task 5).
        let firstRound = makeRound(round: 1)
        store.replace(run: firstRound, diagnostics: [], docId: docId)
        store.replace(run: makeRound(round: 2), diagnostics: [], docId: docId)
        let run = makeRun(lastOpId: "op1")
        let note = makeDiagnostic(docId: docId, runId: run.id)
        store.replace(run: run, diagnostics: [note], docId: docId)
        let versionBefore = store.version

        store.advanceMarker(to: "op2", docId: docId)

        XCTAssertEqual(store.lastOpId(docId: docId), "op2")
        XCTAssertEqual(store.roundHistory(docId: docId).map(\.runId), [firstRound.id],
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
        XCTAssertEqual(reread.roundHistory(docId: docId).map(\.runId), [firstRound.id],
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

    /// **A sidecar written before `kind` existed still loads, and the legacy
    /// rule is what answers for it** (two loops P1 Task 1).
    ///
    /// The field is optional on `CompilerRun`'s standing convention, but the
    /// hand-written decoder does not consult a property's default — a field
    /// added to the type and forgotten there is a compile error at best and a
    /// throw on every pre-existing sidecar at worst, and an undecodable
    /// sidecar reads to the writer as a document that was never checked.
    func test_aSidecarWithoutKindStillLoads_andTheLegacyRuleAnswersForIt() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docNoKind"
        let url = DiagnosticsStore.sidecarURL(projectRoot: project, docId: docId, device: device)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A run written before the field existed, in a lane: no `kind` key at
        // all, and a `passId` — which is what the two verbs looked like before
        // either of them was declared.
        try Data("""
            {"diagnostics":[],"run":{"at":"2026-08-04T09:00:00Z","deltaSummary":"1 new, 0 revised",
            "id":"01JABC","lastOpId":"op1","model":"sonnet","passId":"line","round":2}}
            """.utf8).write(to: url)

        let store = DiagnosticsStore(projectRoot: project, device: device)
        store.load(docId: docId)

        let run = try XCTUnwrap(store.lastRun(docId: docId))
        XCTAssertNil(run.kind, "a run written before the field existed declares nothing")
        XCTAssertEqual(run.effectiveKind, .round,
                       "…and a run with a lane was a round, undeclared")
    }

    /// The other half of the legacy rule, and the control for the test above:
    /// a lane-less record from the same era was an ordinary \u{2318}R.
    func test_aLegacyRunWithNoLaneReadsAsACheck() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docNoKindNoLane"
        let url = DiagnosticsStore.sidecarURL(projectRoot: project, docId: docId, device: device)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            {"diagnostics":[],"run":{"at":"2026-08-04T09:00:00Z","deltaSummary":"1 new, 0 revised",
            "id":"01JABD","lastOpId":"op1","model":"sonnet"}}
            """.utf8).write(to: url)

        let store = DiagnosticsStore(projectRoot: project, device: device)
        store.load(docId: docId)

        let run = try XCTUnwrap(store.lastRun(docId: docId))
        XCTAssertNil(run.kind)
        XCTAssertEqual(run.effectiveKind, .check)
    }

    /// A run that DOES declare its kind round-trips it, and the legacy rule
    /// never second-guesses it — the write half of the compatibility
    /// contract, and what says the inference is a fallback rather than the
    /// answer. A `.check` in a lane is the sharp case: infer from `passId`
    /// and this reads `.round`.
    func test_aDeclaredKindSurvivesTheSidecar_andOutranksTheLegacyRule() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docWithKind"

        var run = makeRun()
        run.passId = "line"
        run.round = 3
        run.kind = .check
        let store = DiagnosticsStore(projectRoot: project, device: device)
        store.replace(run: run, diagnostics: [], docId: docId)

        let reopened = DiagnosticsStore(projectRoot: project, device: device)
        reopened.load(docId: docId)
        let reloaded = try XCTUnwrap(reopened.lastRun(docId: docId))
        XCTAssertEqual(reloaded.kind, .check, "the declaration survives the disk")
        XCTAssertEqual(reloaded.effectiveKind, .check,
                       "…and the lane does not overrule it")
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

    // MARK: - The writer's ask (editorial letter P2 Task 3)

    /// **Not `/tmp/unused`**, for `refuseColdStart`'s measured reason: `asks`
    /// is loaded eagerly at `init`, so a fixed path shared across invocations
    /// of this binary would hand a fresh store a previous run's own write.
    func test_setAsk_isReadBackAndBumpsVersion() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "doc-ask"

        XCTAssertNil(store.ask(docId: docId))
        let versionBefore = store.version

        store.setAsk("I'm worried the middle sags.", docId: docId)

        XCTAssertEqual(store.ask(docId: docId), "I'm worried the middle sags.")
        XCTAssertGreaterThan(store.version, versionBefore,
            "a SwiftUI field reading `ask(docId:)` through a method observes nothing "
            + "unless `version` moves")
    }

    /// The ask is per document, not per project: asking about one chapter
    /// must not brief the run against another.
    func test_setAsk_isPerDocument() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))

        store.setAsk("Does the ending land?", docId: "doc-one")

        XCTAssertEqual(store.ask(docId: "doc-one"), "Does the ending land?")
        XCTAssertNil(store.ask(docId: "doc-two"))
    }

    /// Trimmed, and a blank ask is a REMOVAL rather than an empty string —
    /// a writer who selects the field and deletes it has asked nothing, and
    /// an empty string kept on disk would brief every later run with a
    /// question mark of nothing.
    func test_setAsk_trimsAndAnEmptyAskClears() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "doc-ask-clear"

        store.setAsk("   Does the middle sag?  \n", docId: docId)
        XCTAssertEqual(store.ask(docId: docId), "Does the middle sag?")

        store.setAsk("   ", docId: docId)
        XCTAssertNil(store.ask(docId: docId), "whitespace alone is nothing asked")

        store.setAsk("Back again.", docId: docId)
        store.setAsk(nil, docId: docId)
        XCTAssertNil(store.ask(docId: docId), "…and so is nil")
    }

    /// **An ask over `askLimit` is refused, and the one that stood stands.**
    ///
    /// A worry is a sentence, not a page: the ask rides every run's briefing
    /// as its own section, and an essay pasted in here would out-argue the
    /// writer's own intent about what this round is for. The refusal has to
    /// leave the previous ask alone — a too-long edit that cleared it would
    /// silently stop briefing the round with a question the writer believes
    /// they are still asking.
    func test_setAsk_refusesAnAskOverTheLimit_andLeavesTheStandingOneAlone() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "doc-ask-cap"
        XCTAssertTrue(store.setAsk("Does the middle sag?", docId: docId))
        let versionBefore = store.version

        let tooLong = String(repeating: "a", count: DiagnosticsStore.askLimit + 1)
        XCTAssertFalse(store.setAsk(tooLong, docId: docId),
                       "an ask over \(DiagnosticsStore.askLimit) characters is refused")
        XCTAssertEqual(
            store.ask(docId: docId), "Does the middle sag?",
            "a refused edit must not clear the ask the writer believes they are asking")
        XCTAssertEqual(
            store.version, versionBefore,
            "nothing changed, so nothing needs re-reading \u{2014} a version bump over a "
            + "refused write is a re-render that says the field moved when it did not")
    }

    /// CONTROL for the refusal: exactly at the limit lands, so the guard is a
    /// ceiling rather than an off-by-one that refuses the longest legal ask.
    /// And the count is of the TRIMMED text, since that is what is stored and
    /// briefed — whitespace the writer cannot see must not refuse their
    /// sentence.
    func test_setAsk_takesAnAskExactlyAtTheLimit_measuredAfterTrimming() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "doc-ask-cap-control"

        let atLimit = String(repeating: "b", count: DiagnosticsStore.askLimit)
        XCTAssertTrue(store.setAsk(atLimit, docId: docId))
        XCTAssertEqual(store.ask(docId: docId), atLimit)

        let padded = "   " + String(repeating: "c", count: DiagnosticsStore.askLimit) + "  \n"
        XCTAssertTrue(store.setAsk(padded, docId: docId),
                      "trailing whitespace is not part of the ask and must not refuse it")
        XCTAssertEqual(
            store.ask(docId: docId),
            String(repeating: "c", count: DiagnosticsStore.askLimit))
    }

    /// **A pending draft is promoted by the run, and only what changed is
    /// written** (P2 Task 7, fix round 1). The gap it closes: ⌘R is a menu
    /// command that never touches the first responder, so a worry typed and not
    /// submitted would otherwise be dropped by the round it was typed for.
    func test_commitPendingAsk_promotesWhatWasTypedButNotSubmitted() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "doc-pending"

        store.notePendingAsk("I'm worried the middle sags.", docId: docId)
        XCTAssertNil(store.ask(docId: docId), "noting is not asking")

        XCTAssertTrue(store.commitPendingAsk(docId: docId))
        XCTAssertEqual(store.ask(docId: docId), "I'm worried the middle sags.")

        XCTAssertFalse(
            store.commitPendingAsk(docId: docId),
            "the pending draft is spent \u{2014} a second round must not rewrite the "
            + "asks file for a sentence that already stands")
    }

    /// A pending draft equal to what already stands writes nothing, so an
    /// ordinary round costs no file write and no re-render.
    func test_commitPendingAsk_writesNothingWhenNothingChanged() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "doc-pending-same"
        store.setAsk("Does the middle sag?", docId: docId)
        let versionBefore = store.version

        store.notePendingAsk("  Does the middle sag?  ", docId: docId)
        XCTAssertFalse(store.commitPendingAsk(docId: docId))
        XCTAssertEqual(store.version, versionBefore)
        XCTAssertEqual(store.ask(docId: docId), "Does the middle sag?")
    }

    /// **An emptied field is a withdrawal, not an absence.** A writer who
    /// selects their ask and deletes it without submitting must not have the
    /// round they then ask for briefed with the sentence they just removed.
    func test_commitPendingAsk_anEmptiedFieldWithdrawsTheAsk() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "doc-pending-empty"
        store.setAsk("Does the middle sag?", docId: docId)

        store.notePendingAsk("", docId: docId)
        XCTAssertTrue(store.commitPendingAsk(docId: docId))
        XCTAssertNil(store.ask(docId: docId))
    }

    /// The pending buffer is per document, like the ask itself: a draft typed
    /// about one chapter may never be promoted onto another.
    func test_commitPendingAsk_isPerDocument() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))

        store.notePendingAsk("Does chapter one sag?", docId: "doc-a")

        XCTAssertFalse(store.commitPendingAsk(docId: "doc-b"))
        XCTAssertNil(store.ask(docId: "doc-b"))
        XCTAssertTrue(store.commitPendingAsk(docId: "doc-a"), "control")
        XCTAssertEqual(store.ask(docId: "doc-a"), "Does chapter one sag?")
    }

    /// A submitted ask spends the pending buffer, so a later round cannot
    /// re-promote a draft the writer has already had committed for them.
    func test_setAsk_spendsThePendingDraft() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "doc-pending-spent"

        store.notePendingAsk("Half a thou", docId: docId)
        store.setAsk("Does the ending land?", docId: docId)

        XCTAssertFalse(store.commitPendingAsk(docId: docId))
        XCTAssertEqual(store.ask(docId: docId), "Does the ending land?")
    }

    /// **A pending draft over the limit is refused exactly as a submitted one
    /// is**, and the round goes out briefed with the ask that stands rather
    /// than with nothing.
    func test_commitPendingAsk_refusesOverTheLimitAndLeavesTheAskStanding() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "doc-pending-long"
        store.setAsk("Does the middle sag?", docId: docId)

        store.notePendingAsk(
            String(repeating: "a", count: DiagnosticsStore.askLimit + 1), docId: docId)

        XCTAssertFalse(store.commitPendingAsk(docId: docId))
        XCTAssertEqual(store.ask(docId: docId), "Does the middle sag?")
    }

    /// Persisted immediately and survives a relaunch — a fresh store over the
    /// same root reads it back without `load(docId:)` ever being called,
    /// since `asks` is read once at `init`.
    func test_setAsk_survivesRelaunch() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "doc-ask-relaunch"

        let store1 = DiagnosticsStore(projectRoot: project, device: device)
        store1.setAsk("Is Kelly's grief legible?", docId: docId)

        let store2 = DiagnosticsStore(projectRoot: project, device: device)
        XCTAssertEqual(store2.ask(docId: docId), "Is Kelly's grief legible?")
    }

    /// Per device, on the same discipline as every other sidecar here.
    func test_setAsk_isPerDevice() throws {
        let project = try makeProject()
        let docId = "doc-ask-cross-device"

        let storeA = DiagnosticsStore(
            projectRoot: project, device: DeviceSlug.make(from: "mac-a"))
        storeA.setAsk("Does the middle sag?", docId: docId)

        let storeB = DiagnosticsStore(
            projectRoot: project, device: DeviceSlug.make(from: "mac-b"))
        XCTAssertNil(storeB.ask(docId: docId))
    }

    /// **An ask can be set on a document the compiler has never read** —
    /// which is why it cannot live inside `FileContent`, whose whole shape is
    /// a run that happened. Setting one must fabricate no run.
    func test_setAsk_worksForADocumentWithNoRunAtAll_andMintsNoRun() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "doc-ask-never-run"

        store.setAsk("What is this even about?", docId: docId)

        XCTAssertEqual(store.ask(docId: docId), "What is this even about?")
        XCTAssertNil(store.lastRun(docId: docId))
        XCTAssertEqual(store.live(docId: docId, currentText: { _ in nil }), [])
    }

    /// Its own file, named for this device (tripwire 24's `.raw`-at-the-
    /// filename-point rule), and NOT the per-doc sidecar.
    func test_asksFilename_isPerDevice_andTakesDeviceSlug() {
        let project = URL(fileURLWithPath: "/tmp/project")
        let slug = DeviceSlug.make(from: "Denvers-Mac.local")

        XCTAssertEqual(
            DiagnosticsStore.asksURL(projectRoot: project, device: slug).path,
            project.appendingPathComponent(".maugham/diagnostics/asks.\(slug.raw).json").path)
    }

    /// A missing or corrupt asks file reads as empty — the derived-state
    /// contract every sidecar here follows. Losing it costs the writer the
    /// question they typed, and nothing else.
    func test_setAsk_corruptFileReadsAsEmpty() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let url = DiagnosticsStore.asksURL(projectRoot: project, device: device)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        let store = DiagnosticsStore(projectRoot: project, device: device)

        XCTAssertNil(store.ask(docId: "anything"))
    }

    // MARK: - The two standing slots (two loops P1 Task 5)

    /// A round fixture: `passId` is what `CompilerRun.effectiveKind` reads for
    /// a record written before `kind` existed, and `kind` is what a record
    /// written since says outright. Both are set, so nothing here depends on
    /// which of the two the store consults.
    private func makeRound(
        passId: String = "line", round: Int = 1, lastOpId: String = ULID.generate(),
        at: Date? = nil
    ) -> CompilerRun {
        let wholeSecond = at ?? Date(
            timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        return CompilerRun(
            id: ULID.generate(), at: wholeSecond, model: "test-model",
            lastOpId: lastOpId, deltaSummary: "the piece whole",
            intentSnapshot: "intent snapshot", passId: passId, round: round,
            kind: .round)
    }

    private func makeCheck(
        lastOpId: String = ULID.generate(), at: Date? = nil
    ) -> CompilerRun {
        let wholeSecond = at ?? Date(
            timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        return CompilerRun(
            id: ULID.generate(), at: wholeSecond, model: "test-model",
            lastOpId: lastOpId, deltaSummary: "3 new, 2 revised \u{00b6}",
            intentSnapshot: "intent snapshot", kind: .check)
    }

    /// **A sidecar written before this task loads, and its one run lands in
    /// the slot its own kind names.** No migration (tripwire 11): the legacy
    /// keys are read, and a passless run is a check.
    func test_aLegacySidecarWithNoLaneLoadsAsTheStandingCheck() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docLegacyCheck"
        let url = DiagnosticsStore.sidecarURL(projectRoot: project, docId: docId, device: device)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            {"clauseHistory":[],\
            "diagnostics":[{"anchor":{"anchorText":"steady","paragraphId":"efgh"},\
            "body":"A strain","docId":"docLegacyCheck","id":"01JNOTE","kind":"conformanceStrain",\
            "runId":"01JRUN"}],\
            "run":{"at":"2026-09-01T09:00:00Z","deltaSummary":"1 new, 0 revised",\
            "droppedDangling":0,"id":"01JRUN","lastOpId":"op1","model":"sonnet",\
            "passId":null,"round":null}}
            """.utf8).write(to: url)

        let store = DiagnosticsStore(projectRoot: project, device: device)
        store.load(docId: docId)

        XCTAssertEqual(store.lastCheck(docId: docId)?.id, "01JRUN",
                       "a run with no lane is a check, and the file's one run is it")
        XCTAssertNil(store.lastRound(docId: docId),
                     "nothing in that file was ever a round")
        XCTAssertEqual(store.lastOpId(docId: docId), "op1",
                       "the marker is the check's, and the check is where it landed")
        XCTAssertEqual(
            store.live(docId: docId, currentText: { _ in "steady" }).map(\.id), ["01JNOTE"],
            "and Author's rows came with it")
    }

    /// The other half: a legacy run filed in a lane was a round, so it loads
    /// as one — and Author's pane, the marker and the check slot are all empty
    /// for a document nobody has ever ⌘R'd.
    func test_aLegacySidecarWithALaneLoadsAsTheStandingRound() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docLegacyRound"
        let url = DiagnosticsStore.sidecarURL(projectRoot: project, docId: docId, device: device)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            {"clauseHistory":[],"diagnostics":[],\
            "run":{"at":"2026-09-01T09:00:00Z","deltaSummary":"the piece whole",\
            "droppedDangling":0,"id":"01JROUND","lastOpId":"op7","model":"sonnet",\
            "passId":"line","round":2}}
            """.utf8).write(to: url)

        let store = DiagnosticsStore(projectRoot: project, device: device)
        store.load(docId: docId)

        XCTAssertEqual(store.lastRound(docId: docId)?.id, "01JROUND")
        XCTAssertEqual(store.latestRound(forPass: "line", docId: docId), 2,
                       "the lane's count came with it")
        XCTAssertNil(store.lastCheck(docId: docId),
                     "no check has ever been made against this document")
        XCTAssertNil(store.lastOpId(docId: docId),
                     "and a round moves no marker \u{2014} reading one off a round is "
                     + "how Author's next check skipped the prose it had never read")
    }

    /// **A check replaces the check and leaves the round exactly where the
    /// cockpit is drawing it** — the whole point of the two slots.
    func test_aCheckOverAStandingRoundLeavesTheRoundUntouched() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "docBothVerbs"

        let round = makeRound(round: 4)
        let roundNote = makeDiagnostic(docId: docId, runId: round.id, body: "the round's")
        store.replace(run: round, diagnostics: [roundNote], docId: docId)

        let check = makeCheck(lastOpId: "op-check")
        let checkNote = makeDiagnostic(docId: docId, runId: check.id, body: "the check's")
        store.replace(run: check, diagnostics: [checkNote], docId: docId)

        XCTAssertEqual(store.lastRound(docId: docId), round,
                       "the whole record, byte for byte \u{2014} a check that landed on "
                       + "the round would have taken the cockpit's report with it")
        XCTAssertEqual(store.lastCheck(docId: docId), check)
        XCTAssertEqual(store.lastOpId(docId: docId), "op-check",
                       "the marker is the check's own")
        XCTAssertEqual(
            store.live(docId: docId, currentText: { _ in nil }).map(\.body), ["the check's"],
            "Author's rows are the check's notes; the round's strains are stored "
            + "and drawn nowhere in P1")
        XCTAssertEqual(store.roundHistory(docId: docId), [],
                       "and a check files no round \u{2014} the ring would otherwise say "
                       + "the last round was an Author keystroke")
    }

    /// And the reverse: a round leaves Author's notes and marker alone, while
    /// filing the round it superseded.
    func test_aRoundOverAStandingCheckLeavesTheCheckUntouched() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "docRoundOverCheck"

        let first = makeRound(round: 1)
        store.replace(run: first, diagnostics: [], docId: docId)
        let check = makeCheck(lastOpId: "op-check")
        let checkNote = makeDiagnostic(docId: docId, runId: check.id, body: "the check's")
        store.replace(run: check, diagnostics: [checkNote], docId: docId)

        let second = makeRound(round: 2)
        store.replace(run: second, diagnostics: [], docId: docId)

        XCTAssertEqual(store.lastCheck(docId: docId), check)
        XCTAssertEqual(store.lastOpId(docId: docId), "op-check",
                       "a round moves no marker, and must not take the check's")
        XCTAssertEqual(
            store.live(docId: docId, currentText: { _ in nil }).map(\.body), ["the check's"])
        XCTAssertEqual(store.roundHistory(docId: docId).map(\.runId), [first.id],
                       "the outgoing ROUND is filed \u{2014} and only it, though a check "
                       + "finished between the two")
    }

    /// The ring's rule from the reading end: any number of checks between two
    /// rounds changes neither the lane's count nor what the next round is
    /// measured since.
    func test_latestRoundIgnoresAnyNumberOfChecks() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "docChecksBetween"

        store.replace(run: makeRound(round: 3), diagnostics: [], docId: docId)
        for _ in 1...3 {
            store.replace(run: makeCheck(), diagnostics: [], docId: docId)
        }

        XCTAssertEqual(store.roundHistory(docId: docId), [],
                       "and none of the three superseded checks was filed as a "
                       + "round \u{2014} the ring is what the next round is measured "
                       + "since, and an Author keystroke in it moves that boundary")
        XCTAssertEqual(store.latestRound(forPass: "line", docId: docId), 3,
                       "three ⌘Rs are not three rounds; the lane is still on 3")
        XCTAssertEqual(store.standingRound(docId: docId)?.record.round, 3,
                       "and the round the next one is briefed against is still that one")
    }

    /// And the marker's rule from the reading end: any number of rounds leaves
    /// the check loop's position where the last check left it.
    func test_lastOpIdIgnoresAnyNumberOfRounds() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "docRoundsBetween"

        store.replace(run: makeCheck(lastOpId: "op-check"), diagnostics: [], docId: docId)
        for round in 1...3 {
            store.replace(run: makeRound(round: round, lastOpId: "op-round-\(round)"),
                          diagnostics: [], docId: docId)
        }

        XCTAssertEqual(store.lastOpId(docId: docId), "op-check",
                       "the next check reads the delta from where the last CHECK "
                       + "stopped, whatever Review has done since")
    }

    /// **A preview stands in one slot.** A check streaming onto Author's pane
    /// must not blank the round the cockpit is showing, and the round the next
    /// round is briefed against is still the one that finished.
    func test_aPreviewOfOneVerbDoesNotHideTheOthersStandingAnswer() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "docCrossPreview"

        let round = makeRound(round: 2)
        store.replace(run: round, diagnostics: [], docId: docId)
        let check = makeCheck()
        store.replace(run: check, diagnostics: [], docId: docId)

        store.preview(run: makeCheck(), diagnostics: [], docId: docId)
        XCTAssertEqual(store.lastRound(docId: docId), round,
                       "a check's preview left the cockpit's report blank")
        XCTAssertEqual(store.standingRound(docId: docId)?.record.runId, round.id)

        store.preview(run: makeRound(round: 3), diagnostics: [], docId: docId)
        XCTAssertEqual(store.latestRound(forPass: "line", docId: docId), 3,
                       "control: the round in flight is the one the lane is on")
        XCTAssertEqual(store.standingRound(docId: docId)?.record.runId, round.id,
                       "and the round BEFORE it is still the one that finished")
    }

    /// Both slots survive a relaunch with their own notes — and the file this
    /// build writes carries the two slot keys and neither legacy one.
    func test_roundTrip_survivesRelaunchWithBothSlots() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docTwoSlots"

        let store1 = DiagnosticsStore(projectRoot: project, device: device)
        let round = makeRound(round: 2)
        let roundNote = makeDiagnostic(docId: docId, runId: round.id, body: "the round's")
        store1.replace(run: round, diagnostics: [roundNote], docId: docId)
        let check = makeCheck(lastOpId: "op-check")
        let checkNote = makeDiagnostic(docId: docId, runId: check.id, body: "the check's")
        store1.replace(run: check, diagnostics: [checkNote], docId: docId)

        let store2 = DiagnosticsStore(projectRoot: project, device: device)
        store2.load(docId: docId)

        XCTAssertEqual(store2.lastCheck(docId: docId), check)
        XCTAssertEqual(store2.lastRound(docId: docId), round)
        XCTAssertEqual(store2.lastOpId(docId: docId), "op-check")
        XCTAssertEqual(
            store2.live(docId: docId, currentText: { _ in nil }).map(\.body), ["the check's"])
        XCTAssertEqual(store2.standingRound(docId: docId)?.notes.map(\.body), ["the round's"],
                       "the round's own notes are still what the next round is "
                       + "briefed against")

        let url = DiagnosticsStore.sidecarURL(projectRoot: project, docId: docId, device: device)
        let keys = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(keys.keys), ["check", "round", "clauseHistory", "rounds"],
                       "the legacy keys are READ and never written again; a file "
                       + "carrying both shapes is one the next build would have to "
                       + "choose between. Got: \(keys.keys.sorted())")
    }

    /// **`lastRun` is the newer of the two**, and nothing else — the one
    /// reader that mixes the verbs, for the intent mark and the unread badge.
    func test_lastRunIsTheNewerOfTheTwoStandingRuns() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "docNewer"
        let early = Date(timeIntervalSince1970: 1_780_000_000)
        let late = early.addingTimeInterval(600)

        store.replace(run: makeRound(round: 1, at: late), diagnostics: [], docId: docId)
        store.replace(run: makeCheck(at: early), diagnostics: [], docId: docId)

        XCTAssertEqual(store.lastRun(docId: docId)?.effectiveKind, .round,
                       "the round is newer, though the check landed last")

        store.replace(run: makeCheck(at: late.addingTimeInterval(60)),
                      diagnostics: [], docId: docId)
        XCTAssertEqual(store.lastRun(docId: docId)?.effectiveKind, .check,
                       "and now the check is")
    }

    /// **The badge is per verb underneath, and one run never clears the
    /// other's count** (fix round 1).
    ///
    /// `replace` clears the badge when its own run left nothing, and that was
    /// sound only while a replace superseded the other verb's notes too. With
    /// two slots it does not: a clean round would erase the badge counting a
    /// standing check's strains — which are still drawn on Author's pane —
    /// and a clean check would erase a round's queued notes. What the writer
    /// is shown is still ONE number per document, the sum.
    func test_theBadgeIsPerVerbSoNeitherRunClearsTheOthersCount() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "docBadgeSlots"

        let check = makeCheck()
        store.replace(
            run: check,
            diagnostics: [makeDiagnostic(docId: docId, runId: check.id),
                          makeDiagnostic(docId: docId, runId: check.id)],
            docId: docId)
        XCTAssertEqual(store.unreadCount(docId: docId), 2, "control: two unread strains")

        var cleanRound = makeRound(round: 1)
        cleanRound.mintedNotes = 0
        store.replace(run: cleanRound, diagnostics: [], docId: docId)
        XCTAssertEqual(store.unreadCount(docId: docId), 2,
                       "a round that raised nothing cleared the badge counting the "
                       + "standing check's strains \u{2014} which are still on "
                       + "Author's pane with nothing left to say they are unread")

        store.markRead(docId: docId)
        XCTAssertEqual(store.unreadCount(docId: docId), 0,
                       "the writer read the pane: both verbs' counts drop")

        // The converse: a round's queued notes survive a clean check.
        var round = makeRound(round: 2)
        round.mintedNotes = 3
        store.replace(run: round, diagnostics: [], docId: docId)
        XCTAssertEqual(store.unreadCount(docId: docId), 3)

        store.replace(run: makeCheck(), diagnostics: [], docId: docId)
        XCTAssertEqual(store.unreadCount(docId: docId), 3,
                       "a clean \u{2318}R erased three notes the round put in the "
                       + "writer's queue")

        // And the original behaviour still holds WITHIN a slot: a run clears
        // its own stale count, and the badge is the sum of the two.
        let second = makeCheck()
        store.replace(
            run: second,
            diagnostics: [makeDiagnostic(docId: docId, runId: second.id)], docId: docId)
        XCTAssertEqual(store.unreadCount(docId: docId), 4, "3 queued + 1 unread strain")
        store.replace(run: makeCheck(), diagnostics: [], docId: docId)
        XCTAssertEqual(store.unreadCount(docId: docId), 3,
                       "the check's own stale count went with it, and only it")
    }

    /// The drift ring is fed by BOTH verbs: a clause strains across the
    /// writer's runs, not across one loop's.
    func test_bothVerbsFeedTheDriftRing() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "docDriftBoth"
        let statuses = [DiagnosticIngest.ClauseStatus(
            clauseQuote: "Cold, and never wistful.", status: "strains", refs: [])]

        var round = makeRound(round: 1)
        round.clauseStatuses = statuses
        store.replace(run: round, diagnostics: [], docId: docId)
        var check = makeCheck()
        check.clauseStatuses = statuses
        store.replace(run: check, diagnostics: [], docId: docId)

        XCTAssertEqual(store.clauseStatusHistory(docId: docId), [statuses, statuses],
                       "one ring over both loops, or a clause straining through a "
                       + "round and a check reads as two unrelated single sightings")
    }
}
