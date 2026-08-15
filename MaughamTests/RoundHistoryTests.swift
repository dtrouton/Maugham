import XCTest
@testable import Maugham
import MaughamCore

/// The sidecar's memory of ROUNDS (M3-P3 Task 1): the four stamps a run
/// carries, the capped ring of prior-round fingerprints beside the clause
/// ring, and the pure comparison the pane and the briefing both read through.
///
/// Nothing here writes the stamps — the run does that in Task 2. What is
/// pinned is the storage and the arithmetic.
@MainActor
final class RoundHistoryTests: XCTestCase {

    // MARK: - Fixtures

    private func makeProject() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoundHistory-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Whole-second `at`: the sidecar's ISO8601 round trip truncates fractional
    /// seconds, so a `Date()` fixture would fail equality after a save/load for
    /// a reason that has nothing to do with rounds.
    private func makeRun(
        id: String = ULID.generate(), passId: String? = nil, round: Int? = nil,
        freshEyes: Bool? = nil, intentDriftVerdict: String? = nil
    ) -> CompilerRun {
        let wholeSecond = Date(
            timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        return CompilerRun(
            id: id, at: wholeSecond, model: "test-model", lastOpId: "op1",
            deltaSummary: "1 new, 0 revised \u{00b6}", intentSnapshot: "intent",
            passId: passId, round: round, freshEyes: freshEyes,
            intentDriftVerdict: intentDriftVerdict)
    }

    private func makeDiagnostic(
        kind: DiagnosticKind?, clauseQuote: String? = nil, paragraphId: String? = "a1b2",
        body: String = "A note", docId: String = "docR", runId: String = "run-1"
    ) -> Diagnostic {
        Diagnostic(
            id: ULID.generate(), docId: docId,
            anchor: paragraphId.map { Diagnostic.Anchor(paragraphId: $0, anchorText: "steady") },
            body: body, category: nil, runId: runId, kind: kind,
            refs: nil, clauseQuote: clauseQuote)
    }

    // MARK: - The four stamps

    func test_theRoundStampsRoundTripThroughTheSidecar() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docStamps"
        let run = makeRun(passId: "pass-line", round: 3, freshEyes: true,
                          intentDriftVerdict: "holds")

        DiagnosticsStore(projectRoot: project, device: device)
            .replace(run: run, diagnostics: [], docId: docId)

        let reopened = DiagnosticsStore(projectRoot: project, device: device)
        reopened.load(docId: docId)
        let reread = try XCTUnwrap(reopened.lastRun(docId: docId))
        XCTAssertEqual(reread.passId, "pass-line")
        XCTAssertEqual(reread.round, 3)
        XCTAssertEqual(reread.freshEyes, true)
        XCTAssertEqual(reread.intentDriftVerdict, "holds")
        XCTAssertEqual(reread, run, "the whole record, not only the new half")
    }

    /// **The tolerance rule, from a raw fixture rather than a re-encode.** The
    /// hand-written decoder does not fall back to a property's default, so a
    /// missing `decodeIfPresent` line would throw here — and an undecodable
    /// sidecar reads as empty, which tells the writer their document was never
    /// checked.
    func test_aPreP3SidecarStillDecodes_andEveryStampIsNil() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docPreP3"
        let url = DiagnosticsStore.sidecarURL(projectRoot: project, docId: docId, device: device)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            {"clauseHistory":[],"diagnostics":[],\
            "run":{"at":"2026-08-15T09:00:00Z","deltaSummary":"1 new, 0 revised",\
            "droppedDangling":0,"id":"01JRUN","lastOpId":"op1","model":"sonnet"}}
            """.utf8).write(to: url)

        let store = DiagnosticsStore(projectRoot: project, device: device)
        store.load(docId: docId)

        let run = try XCTUnwrap(store.lastRun(docId: docId), "the record must still load")
        XCTAssertEqual(run.model, "sonnet")
        XCTAssertNil(run.passId)
        XCTAssertNil(run.round)
        XCTAssertNil(run.freshEyes)
        XCTAssertNil(run.intentDriftVerdict)
        XCTAssertEqual(store.roundHistory(docId: docId), [],
                       "a file written before the ring existed has no rounds, and "
                       + "nothing may be backfilled from the standing run")
        XCTAssertNil(store.latestRound(forPass: "pass-line", docId: docId))
    }

    /// The other half of the same contract: a sidecar carrying EVERY P3 field
    /// decodes them all. Written by hand rather than encoded, so the wire names
    /// are pinned rather than merely round-tripped against themselves.
    func test_aSidecarCarryingEveryP3FieldDecodes() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docFullP3"
        let url = DiagnosticsStore.sidecarURL(projectRoot: project, docId: docId, device: device)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            {"clauseHistory":[],"diagnostics":[],\
            "rounds":[{"at":"2026-08-15T08:00:00Z",\
            "fingerprints":[{"clauseQuote":"Cold, and never wistful.",\
            "kind":"conformanceStrain","paragraphId":"a1b2"}],\
            "freshEyes":false,"passId":"pass-line","round":1,"runId":"01JOLD"}],\
            "run":{"at":"2026-08-15T09:00:00Z","deltaSummary":"1 new, 0 revised",\
            "droppedDangling":0,"freshEyes":true,"id":"01JNEW",\
            "intentDriftVerdict":"drifted","lastOpId":"op2","model":"sonnet",\
            "passId":"pass-line","round":2}}
            """.utf8).write(to: url)

        let store = DiagnosticsStore(projectRoot: project, device: device)
        store.load(docId: docId)

        let run = try XCTUnwrap(store.lastRun(docId: docId))
        XCTAssertEqual(run.passId, "pass-line")
        XCTAssertEqual(run.round, 2)
        XCTAssertEqual(run.freshEyes, true)
        XCTAssertEqual(run.intentDriftVerdict, "drifted")

        let history = store.roundHistory(docId: docId)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.runId, "01JOLD")
        XCTAssertEqual(history.first?.round, 1)
        XCTAssertEqual(
            history.first?.fingerprints,
            [RoundFingerprint(kind: "conformanceStrain",
                              clauseQuote: "Cold, and never wistful.",
                              paragraphId: "a1b2")])
        XCTAssertEqual(store.latestRound(forPass: "pass-line", docId: docId), 2,
                       "the standing run is the newest round in its lane")
    }

    // MARK: - The fingerprint

    /// The three kinds, each fingerprinting as the identity the plan names:
    /// strains and continuity carry their clause quote plus the anchored
    /// paragraph; a reader report carries `(kind, paragraphId)` with no quote.
    func test_theThreeKindsFingerprintByAnchorAndQuote() throws {
        let strain = makeDiagnostic(kind: .conformanceStrain,
                                    clauseQuote: "Cold, and never wistful.",
                                    paragraphId: "a1b2")
        let question = makeDiagnostic(kind: .continuity, clauseQuote: "the fog",
                                      paragraphId: "a1b2")
        let report = makeDiagnostic(kind: .readerReport, clauseQuote: nil,
                                    paragraphId: "c3d4")

        XCTAssertEqual(
            RoundFingerprint.make(of: strain),
            RoundFingerprint(kind: "conformanceStrain",
                             clauseQuote: "Cold, and never wistful.", paragraphId: "a1b2"))
        XCTAssertEqual(
            RoundFingerprint.make(of: question),
            RoundFingerprint(kind: "continuity", clauseQuote: "the fog",
                             paragraphId: "a1b2"))
        XCTAssertEqual(
            RoundFingerprint.make(of: report),
            RoundFingerprint(kind: "readerReport", clauseQuote: nil, paragraphId: "c3d4"))
    }

    /// A v1 note has no section, so it has no round-over-round identity —
    /// `load` drops those as superseded anyway, and inventing an identity for
    /// one would match it against notes written under a contract it never spoke.
    func test_aV1NoteHasNoFingerprint() {
        XCTAssertNil(RoundFingerprint.make(of: makeDiagnostic(kind: nil)))
    }

    /// **Identity is the anchor and the quote, never the prose.** The model
    /// rewords the same finding every run; a fingerprint that read `body` would
    /// report every persisting note as one resolved plus one new.
    func test_twoNotesDifferingOnlyInProseAreTheSameFinding() {
        let first = makeDiagnostic(kind: .conformanceStrain, clauseQuote: "Cold.",
                                   body: "The last line reaches for a sigh.")
        let second = makeDiagnostic(kind: .conformanceStrain, clauseQuote: "Cold.",
                                    body: "The closing sentence turns wistful.")
        XCTAssertEqual(RoundFingerprint.make(of: first), RoundFingerprint.make(of: second))
    }

    func test_adifferentClauseIsADifferentFinding() {
        let first = makeDiagnostic(kind: .conformanceStrain, clauseQuote: "Cold.")
        let second = makeDiagnostic(kind: .conformanceStrain, clauseQuote: "Never wistful.")
        XCTAssertNotEqual(RoundFingerprint.make(of: first), RoundFingerprint.make(of: second))
    }

    // MARK: - The comparison

    private func fingerprint(_ quote: String) -> RoundFingerprint {
        RoundFingerprint(kind: "conformanceStrain", clauseQuote: quote, paragraphId: "a1b2")
    }

    private func note(_ quote: String, body: String = "A note") -> Diagnostic {
        makeDiagnostic(kind: .conformanceStrain, clauseQuote: quote, body: body)
    }

    private func record(_ fingerprints: [RoundFingerprint],
                        passId: String? = "pass-line", round: Int? = 1) -> RoundRecord {
        RoundRecord(runId: "01JOLD", at: Date(timeIntervalSince1970: 0), passId: passId,
                    round: round, freshEyes: nil, fingerprints: fingerprints)
    }

    func test_compare_partitionsResolvedPersistingAndNew() {
        let previous = record([fingerprint("A"), fingerprint("B"), fingerprint("C")])
        let outcome = RoundComparison.compare(
            previous: previous, current: [note("B"), note("C"), note("D")])
        XCTAssertEqual(outcome,
                       RoundComparison.Outcome(resolved: 1, persisting: 2, new: 1))
    }

    func test_compare_anEmptyPreviousRoundMakesEverythingNew() {
        let outcome = RoundComparison.compare(
            previous: record([]), current: [note("A"), note("B")])
        XCTAssertEqual(outcome, RoundComparison.Outcome(resolved: 0, persisting: 0, new: 2))
    }

    func test_compare_anEmptyCurrentRunResolvesEverything() {
        let outcome = RoundComparison.compare(
            previous: record([fingerprint("A"), fingerprint("B")]), current: [])
        XCTAssertEqual(outcome, RoundComparison.Outcome(resolved: 2, persisting: 0, new: 0))
    }

    /// One finding raised twice in a run is one finding. The model can name the
    /// same clause from two paragraphs' worth of prose, and counting the echoes
    /// would report more new notes than the pane draws.
    func test_compare_countsADuplicateFindingOnce() {
        let outcome = RoundComparison.compare(
            previous: record([fingerprint("A")]),
            current: [note("A"), note("A", body: "again"), note("B"), note("B")])
        XCTAssertEqual(outcome, RoundComparison.Outcome(resolved: 0, persisting: 1, new: 1))
    }

    /// A v1 note in the current run is not a finding this contract can compare,
    /// so it is neither new nor persisting — the same silence `make` returns.
    func test_compare_ignoresANoteWithNoFingerprint() {
        let outcome = RoundComparison.compare(
            previous: record([]), current: [makeDiagnostic(kind: nil)])
        XCTAssertEqual(outcome, RoundComparison.Outcome(resolved: 0, persisting: 0, new: 0))
    }

    // MARK: - The ring

    /// `replace` snapshots the run it is about to overwrite — the ring is a
    /// record of rounds that FINISHED, so the first replace against a cold
    /// document contributes nothing and the second contributes the first.
    func test_replaceSnapshotsTheOutgoingRunIntoTheRing() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docRing"
        let store = DiagnosticsStore(projectRoot: project, device: device)

        let run1 = makeRun(id: "run-1", passId: "pass-line", round: 1)
        let strain = makeDiagnostic(kind: .conformanceStrain, clauseQuote: "Cold.",
                                    runId: run1.id)
        store.replace(run: run1, diagnostics: [strain], docId: docId)
        XCTAssertEqual(store.roundHistory(docId: docId), [],
                       "a first run has no prior round to remember")

        let run2 = makeRun(id: "run-2", passId: "pass-line", round: 2)
        store.replace(run: run2, diagnostics: [], docId: docId)

        let history = store.roundHistory(docId: docId)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.runId, "run-1")
        XCTAssertEqual(history.first?.passId, "pass-line")
        XCTAssertEqual(history.first?.round, 1)
        XCTAssertEqual(history.first?.fingerprints,
                       [try XCTUnwrap(RoundFingerprint.make(of: strain))])

        // …and it survives the relaunch, or "since last round" forgets the
        // round it is measured against every time the writer reopens.
        let reopened = DiagnosticsStore(projectRoot: project, device: device)
        reopened.load(docId: docId)
        XCTAssertEqual(reopened.roundHistory(docId: docId), history)
    }

    func test_theRingCapsAtRoundHistoryDepth() {
        let store = DiagnosticsStore(
            projectRoot: URL(fileURLWithPath: "/tmp/unused"),
            device: DeviceSlug.make(from: "test-mac"))
        let docId = "docCap"

        for index in 1...(DiagnosticsStore.roundHistoryDepth + 1) {
            store.replace(run: makeRun(id: "run-\(index)", passId: "p", round: index),
                          diagnostics: [], docId: docId)
        }

        let history = store.roundHistory(docId: docId)
        XCTAssertEqual(history.count, DiagnosticsStore.roundHistoryDepth)
        XCTAssertEqual(history.map(\.runId),
                       ["run-1", "run-2", "run-3", "run-4", "run-5"],
                       "oldest→newest, and the sixth replace is the standing run "
                       + "rather than a ring entry")

        store.replace(run: makeRun(id: "run-7", passId: "p", round: 7),
                      diagnostics: [], docId: docId)
        XCTAssertEqual(store.roundHistory(docId: docId).map(\.runId),
                       ["run-2", "run-3", "run-4", "run-5", "run-6"],
                       "the oldest is what falls off")
    }

    // MARK: - The round-numbering read

    func test_latestRound_readsTheStandingRunFirst() {
        let store = DiagnosticsStore(
            projectRoot: URL(fileURLWithPath: "/tmp/unused"),
            device: DeviceSlug.make(from: "test-mac"))
        let docId = "docLatest"
        store.replace(run: makeRun(passId: "P", round: 1), diagnostics: [], docId: docId)
        store.replace(run: makeRun(passId: "P", round: 2), diagnostics: [], docId: docId)

        XCTAssertEqual(store.latestRound(forPass: "P", docId: docId), 2)
    }

    /// The lane changed: the standing run is another pass's, so the answer for
    /// this lane comes off the ring — and the count it left there survives.
    func test_latestRound_fallsBackToTheRingWhenTheLaneChanged() {
        let store = DiagnosticsStore(
            projectRoot: URL(fileURLWithPath: "/tmp/unused"),
            device: DeviceSlug.make(from: "test-mac"))
        let docId = "docLanes"
        store.replace(run: makeRun(passId: "P", round: 1), diagnostics: [], docId: docId)
        store.replace(run: makeRun(passId: "Q", round: 1), diagnostics: [], docId: docId)

        XCTAssertEqual(store.latestRound(forPass: "Q", docId: docId), 1,
                       "the standing run's own lane")
        XCTAssertEqual(store.latestRound(forPass: "P", docId: docId), 1,
                       "the lane the writer left, remembered by the ring")
        XCTAssertNil(store.latestRound(forPass: "R", docId: docId),
                     "a lane nothing has ever run in")
    }

    func test_latestRound_isNilWhenNothingHasEverRun() {
        let store = DiagnosticsStore(
            projectRoot: URL(fileURLWithPath: "/tmp/unused"),
            device: DeviceSlug.make(from: "test-mac"))
        XCTAssertNil(store.latestRound(forPass: "P", docId: "never-run"))
        XCTAssertNil(store.latestRound(forPass: nil, docId: "never-run"))
    }

    /// **The passless lane resolves against passless records only** (decision
    /// 1): a ⌘R with no active pass is an ordinary M2 run that mints no round,
    /// and it must never inherit a numbered pass's count.
    func test_latestRound_thePasslessLaneNeverBorrowsAPassesCount() {
        let store = DiagnosticsStore(
            projectRoot: URL(fileURLWithPath: "/tmp/unused"),
            device: DeviceSlug.make(from: "test-mac"))
        let docId = "docPassless"
        store.replace(run: makeRun(passId: "P", round: 4), diagnostics: [], docId: docId)
        store.replace(run: makeRun(passId: nil, round: nil), diagnostics: [], docId: docId)

        XCTAssertNil(store.latestRound(forPass: nil, docId: docId),
                     "a passless run carries no round for a later one to follow")
        XCTAssertEqual(store.latestRound(forPass: "P", docId: docId), 4,
                       "and the pass's own count is untouched by it")
    }
}
