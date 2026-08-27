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
        body: String = "A note", docId: String = "docR", runId: String = "run-1",
        category: String? = nil
    ) -> Diagnostic {
        Diagnostic(
            id: ULID.generate(), docId: docId,
            anchor: paragraphId.map { Diagnostic.Anchor(paragraphId: $0, anchorText: "steady") },
            body: body, category: category, runId: runId, kind: kind,
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

    /// **The cross-lane count is additive-optional like every stamp before it**
    /// (#42 F-H). A sidecar written by a build that had never heard of
    /// `openInOtherLanes` decodes with nil — which the since-line reads as
    /// nothing to say — and one carrying it round-trips the value.
    ///
    /// From a raw fixture rather than a re-encode, on the P3 tolerance test's
    /// reasoning: the hand-written decoder does not fall back to a property's
    /// default, so a missing `decodeIfPresent` line would throw here and the
    /// writer would be told their document was never checked.
    func test_aSidecarWithoutTheCrossLaneCountDecodesAsNil_andOneWithItRoundTrips() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let url = DiagnosticsStore.sidecarURL(
            projectRoot: project, docId: "docNoLanes", device: device)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
            {"clauseHistory":[],"diagnostics":[],\
            "run":{"at":"2026-08-15T09:00:00Z","deltaSummary":"1 new, 0 revised",\
            "droppedDangling":0,"id":"01JRUN","lastOpId":"op1","mintedNotes":2,\
            "model":"sonnet","passId":"pass-line","round":2}}
            """.utf8).write(to: url)

        let store = DiagnosticsStore(projectRoot: project, device: device)
        store.load(docId: "docNoLanes")
        let old = try XCTUnwrap(store.lastRun(docId: "docNoLanes"),
                                "the record must still load")
        XCTAssertEqual(old.mintedNotes, 2, "control: its neighbour still decodes")
        XCTAssertNil(old.openInOtherLanes)

        var run = makeRun(passId: "pass-line", round: 3)
        run.openInOtherLanes = 2
        DiagnosticsStore(projectRoot: project, device: device)
            .replace(run: run, diagnostics: [], docId: "docLanes")
        let reopened = DiagnosticsStore(projectRoot: project, device: device)
        reopened.load(docId: "docLanes")
        let reread = try XCTUnwrap(reopened.lastRun(docId: "docLanes"))
        XCTAssertEqual(reread.openInOtherLanes, 2)
        XCTAssertEqual(reread, run, "the whole record, not only the new field")
    }

    /// **The field is legacy on the way in and empty on the way out** (M4 P1
    /// Task 5). The decode above is what keeps a sidecar written before this
    /// milestone readable; this is the other direction, read as raw JSON rather
    /// than through the type — a `RoundRecord` that still SNAPSHOTTED
    /// fingerprints would satisfy every projection assertion in this file and
    /// leave the app carrying a second, staler account of what a round found.
    func test_aNewSidecarWritesTheRingWithNoFingerprints() throws {
        let project = try makeProject()
        let device = DeviceSlug.make(from: "test-mac")
        let docId = "docEmptyPrints"
        let store = DiagnosticsStore(projectRoot: project, device: device)

        let run1 = makeRun(id: "run-1", passId: "pass-line", round: 1)
        store.replace(
            run: run1,
            diagnostics: [makeDiagnostic(kind: .conformanceStrain,
                                         clauseQuote: "Cold.", runId: run1.id)],
            docId: docId)
        store.replace(run: makeRun(id: "run-2", passId: "pass-line", round: 2),
                      diagnostics: [], docId: docId)

        let url = DiagnosticsStore.sidecarURL(projectRoot: project, docId: docId, device: device)
        // adr-0018-ok: the sidecar is derived state and its own source of truth
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"fingerprints\":[]"),
                      "a filed round must carry the key and no findings; got \(raw)")
        XCTAssertFalse(raw.contains("\"clauseQuote\""),
                       "a finding's identity reached the ring; got \(raw)")
    }

    // MARK: - The fingerprint

    /// The three kinds, each fingerprinting as the identity the plan names:
    /// strains and continuity carry their clause quote plus the anchored
    /// paragraph; a reader report carries `(kind, category, paragraphId)` with
    /// no quote.
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

    /// **The reader's two kinds are two findings, even on one paragraph**
    /// (M4 P1 review, Important 3). "The dream broke here" and "I stopped
    /// believing her" are different things to have noticed; without the
    /// category in the identity they collapse into one, a round raising both
    /// counts one, and the mint's dedupe silently discards the second.
    func test_theReadersTwoKindsAreTwoFindingsOnOneParagraph() {
        let dream = makeDiagnostic(kind: .readerReport, clauseQuote: nil,
                                   paragraphId: "a1b2", category: "dream_break")
        let belief = makeDiagnostic(kind: .readerReport, clauseQuote: nil,
                                    paragraphId: "a1b2", category: "belief")

        XCTAssertNotEqual(RoundFingerprint.make(of: dream),
                          RoundFingerprint.make(of: belief),
                          "two reader kinds on one paragraph collapsed into one finding")
        XCTAssertNotEqual(RoundFingerprint.make(of: dream)?.stringValue,
                          RoundFingerprint.make(of: belief)?.stringValue,
                          "…and the string the mint stamps must separate them too, "
                          + "because that is what the dedupe compares")
        XCTAssertEqual(RoundFingerprint.make(of: dream)?.category, "dream_break")
    }

    /// The category belongs to the READER alone: a strain and a continuity
    /// question are told apart by the clause they cite, and a stray category
    /// on either would be a second discriminator nothing sets.
    func test_onlyAReaderReportCarriesACategoryInItsIdentity() {
        let strain = makeDiagnostic(kind: .conformanceStrain, clauseQuote: "Cold.",
                                    category: "belief")
        XCTAssertNil(RoundFingerprint.make(of: strain)?.category)
        let question = makeDiagnostic(kind: .continuity, clauseQuote: "the fog",
                                      category: "belief")
        XCTAssertNil(RoundFingerprint.make(of: question)?.category)
    }

    // MARK: - The fingerprint STRING: a persisted, synced wire format

    /// **`stringValue` is a contract, not a convenience** (M4 P1 review,
    /// Important 4). It is stamped on `Op.Provenance.compilerFingerprint`,
    /// which is append-only, syncs between devices and is compared by the
    /// mint's dedupe — so a change to the order, the separator or the field set
    /// silently redefines "the same finding" for every note already in a
    /// writer's op log, on every machine. Three assertions, in
    /// `CompilerProvenanceTests`' round-trip discipline: the exact string, the
    /// nil-vs-empty rule, and the field order.
    func test_theFingerprintStringIsExactlyThisFormat() throws {
        let fingerprint = RoundFingerprint(
            kind: "readerReport", clauseQuote: "the fog", paragraphId: "a1b2",
            category: "belief")
        XCTAssertEqual(
            fingerprint.stringValue,
            "readerReport\u{1f}the fog\u{1f}a1b2\u{1f}belief",
            "the fingerprint format moved \u{2014} every note already stamped in "
            + "a writer's op log now reads as a different finding")
    }

    /// `nil` and `""` are deliberately the same string: neither is a
    /// discriminator, and `make` has already refused a fingerprint for anything
    /// carrying no discriminator at all.
    func test_theFingerprintStringTreatsNilAndEmptyAlike() {
        XCTAssertEqual(
            RoundFingerprint(kind: "continuity", clauseQuote: nil,
                             paragraphId: "a1b2").stringValue,
            RoundFingerprint(kind: "continuity", clauseQuote: "",
                             paragraphId: "a1b2", category: "").stringValue)
        XCTAssertEqual(
            RoundFingerprint(kind: "continuity", clauseQuote: nil,
                             paragraphId: "a1b2").stringValue,
            "continuity\u{1f}\u{1f}a1b2\u{1f}",
            "every field is present even when empty, so a nil cannot shift the "
            + "positions of the fields after it")
    }

    /// **The order is load-bearing and the separator is what makes it safe.**
    /// Two fingerprints whose fields are the same values in different positions
    /// must not produce the same string — which is exactly what a separator
    /// that could occur inside a field, or a format that omitted empties, would
    /// allow.
    func test_theFingerprintStringCannotRespellOneFieldAsAnother() {
        let quoted = RoundFingerprint(
            kind: "continuity", clauseQuote: "a1b2", paragraphId: nil)
        let anchored = RoundFingerprint(
            kind: "continuity", clauseQuote: nil, paragraphId: "a1b2")
        XCTAssertNotEqual(quoted.stringValue, anchored.stringValue,
                          "the same token in two fields produced one identity")
        XCTAssertEqual(quoted.stringValue.split(separator: "\u{1f}",
                                                omittingEmptySubsequences: false).count, 4,
                       "four fields, always \u{2014} a fifth or a fourth dropped is a "
                       + "format change")
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

    /// **A note with nothing to be identified BY takes no part either.** An
    /// anchorless note is supported by design and a refless reader report or a
    /// cites-less continuity question produces one, so `(kind, nil, nil)` is a
    /// reachable shape — and it is a bucket rather than an identity: every such
    /// note in a round would collapse into one finding, so three that persisted
    /// would read as one persisting and two resolved.
    func test_aNoteWithNeitherAnchorNorClauseHasNoFingerprint() {
        XCTAssertNil(RoundFingerprint.make(
            of: makeDiagnostic(kind: .readerReport, clauseQuote: nil, paragraphId: nil)))
        XCTAssertNil(RoundFingerprint.make(
            of: makeDiagnostic(kind: .continuity, clauseQuote: nil, paragraphId: nil)))
        XCTAssertNotNil(RoundFingerprint.make(
            of: makeDiagnostic(kind: .readerReport, clauseQuote: nil, paragraphId: "c3d4")),
            "one discriminator is enough — this is not a demand for both")
        XCTAssertNotNil(RoundFingerprint.make(
            of: makeDiagnostic(kind: .continuity, clauseQuote: "the fog", paragraphId: nil)),
            "…from either side")
    }

    func test_aDifferentClauseIsADifferentFinding() {
        let first = makeDiagnostic(kind: .conformanceStrain, clauseQuote: "Cold.")
        let second = makeDiagnostic(kind: .conformanceStrain, clauseQuote: "Never wistful.")
        XCTAssertNotEqual(RoundFingerprint.make(of: first), RoundFingerprint.make(of: second))
    }

    // MARK: - Since last round: the count comes off the QUEUE (M4 P1 Task 5)
    //
    // The fingerprint comparison between two rounds' sidecar reports is gone
    // with the reports themselves: two of the three kinds a round raises are
    // annotations now, and a strain the writer answered is not "resolved"
    // merely because the next run stopped saying it. What the line counts is
    // what the writer can see in the queue and act on, which is the only
    // account of a round that a writer can check against their own screen.

    /// A compiler-authored note in the queue, as `SinceLastRound` reads one.
    /// Every field the arithmetic turns on is a parameter; nothing else here is
    /// load-bearing.
    private func makeAnnotation(
        lane: String? = "pass-line",
        round: Int? = 1,
        status: AnnotationStatus = .open,
        resolvedAt: Date? = nil,
        runId: String? = "run-1"
    ) -> Annotation {
        Annotation(
            id: ULID.generate(), kind: .query, paragraphId: "a1b2",
            body: "Whose coat is on the chair?", suggestedText: nil, priorText: nil,
            createdAt: Date(timeIntervalSince1970: 100), createdBySession: nil,
            status: status, userResponse: nil, resolvedAt: resolvedAt,
            isStale: false, reviewPassId: lane,
            compilerRunId: runId, compilerRound: round,
            compilerFingerprint: "continuity\u{1f}the fog\u{1f}a1b2\u{1f}")
    }

    /// When round 1 of this lane finished. Everything the writer settled after
    /// it is this round's news; everything before it was already reported.
    private let previousRoundAt = Date(timeIntervalSince1970: 1_000)

    private func compute(_ annotations: [Annotation],
                         lane: String? = "pass-line",
                         currentRound: Int = 2) -> SinceLastRound.Outcome {
        SinceLastRound.compute(annotations: annotations, lane: lane,
                               currentRound: currentRound,
                               previousRoundAt: previousRoundAt)
    }

    /// The three states, in one queue: a note this round minted, one from an
    /// earlier round the writer is still holding, and one they settled since
    /// the last round finished.
    func test_theThreeStatesAreCountedOffTheQueue() {
        let outcome = compute([
            makeAnnotation(round: 2),
            makeAnnotation(round: 1),
            makeAnnotation(round: 1, status: .stetted,
                           resolvedAt: previousRoundAt.addingTimeInterval(60)),
        ])
        XCTAssertEqual(outcome, SinceLastRound.Outcome(resolved: 1, persisting: 1, new: 1))
    }

    /// **A settled note is settled however the writer settled it.** Stet,
    /// reject, accept and archive are four verdicts and one fact: the note is
    /// no longer in front of them.
    func test_everyWayOutOfOpenCountsAsResolved() {
        for status in [AnnotationStatus.stetted, .rejected, .accepted, .archived] {
            XCTAssertEqual(
                compute([makeAnnotation(
                    round: 1, status: status,
                    resolvedAt: previousRoundAt.addingTimeInterval(60))]),
                SinceLastRound.Outcome(resolved: 1, persisting: 0, new: 0),
                "\(status) is a note the writer dealt with")
        }
    }

    /// **A declined note is still open, and still persisting.** The triage mark
    /// sorts the queue; it does not settle anything, and a line that counted it
    /// resolved would tell the writer they had finished with something still
    /// sitting in front of them.
    func test_aTriagedNoteIsStillPersisting() {
        XCTAssertEqual(compute([makeAnnotation(round: 1, status: .open)]),
                       SinceLastRound.Outcome(resolved: 0, persisting: 1, new: 0))
    }

    /// **The lane is the comparison** (decision 1). A Proof round's notes take
    /// no part in a Line round's count, and the passless lane is a lane of its
    /// own rather than a wildcard that swallows every other.
    func test_itCountsOnlyItsOwnLane() {
        let mixed = [
            makeAnnotation(lane: "pass-line", round: 2),
            makeAnnotation(lane: "pass-proof", round: 2),
            makeAnnotation(lane: nil, round: 2),
            makeAnnotation(lane: "pass-proof", round: 1),
            makeAnnotation(lane: "pass-proof", round: 1, status: .stetted,
                           resolvedAt: previousRoundAt.addingTimeInterval(60)),
        ]
        XCTAssertEqual(compute(mixed, lane: "pass-line"),
                       SinceLastRound.Outcome(resolved: 0, persisting: 0, new: 1),
                       "another pass's notes bled into this lane's count")
        XCTAssertEqual(compute(mixed, lane: nil),
                       SinceLastRound.Outcome(resolved: 0, persisting: 0, new: 1),
                       "the passless lane must count its own note and nobody else's")
        XCTAssertEqual(compute(mixed, lane: "pass-proof"),
                       SinceLastRound.Outcome(resolved: 1, persisting: 1, new: 1),
                       "control: the same queue, read from the other lane")
    }

    /// **Resolved means resolved SINCE the last round** — not resolved ever.
    /// The queue holds every note this pass ever raised, so a count without the
    /// boundary would re-report the same settled note in every round for as
    /// long as the writer stayed in the pass, and the line would climb forever
    /// while nothing was happening.
    func test_onlyWhatWasSettledSinceThePreviousRoundIsResolved() {
        let long = makeAnnotation(round: 1, status: .stetted,
                                  resolvedAt: previousRoundAt.addingTimeInterval(-60))
        let fresh = makeAnnotation(round: 1, status: .stetted,
                                   resolvedAt: previousRoundAt.addingTimeInterval(60))
        XCTAssertEqual(compute([long]),
                       SinceLastRound.Outcome(resolved: 0, persisting: 0, new: 0),
                       "a note settled before the last round even ran was already "
                       + "counted, in the round it was settled in")
        XCTAssertEqual(compute([long, fresh]),
                       SinceLastRound.Outcome(resolved: 1, persisting: 0, new: 0),
                       "control: the one settled since does count")
    }

    /// The boundary itself is exclusive: a note settled at the very instant the
    /// previous round was filed belongs to that round's account.
    func test_theResolvedBoundaryIsExclusive() {
        XCTAssertEqual(
            compute([makeAnnotation(round: 1, status: .stetted, resolvedAt: previousRoundAt)]),
            SinceLastRound.Outcome(resolved: 0, persisting: 0, new: 0))
    }

    /// **The writer's own notes, and Claude Desktop's, are not this round's
    /// account of itself.** Only a note a compiler run authored can be new,
    /// persisting or resolved in the sense this line means.
    func test_aNoteTheCompilerDidNotWriteTakesNoPart() {
        let human = makeAnnotation(round: nil, runId: nil)
        XCTAssertEqual(compute([human]),
                       SinceLastRound.Outcome(resolved: 0, persisting: 0, new: 0))
        XCTAssertEqual(
            compute([makeAnnotation(round: nil, status: .stetted,
                                    resolvedAt: previousRoundAt.addingTimeInterval(60),
                                    runId: nil)]),
            SinceLastRound.Outcome(resolved: 0, persisting: 0, new: 0),
            "…including when they settle it in the window this line reports on")
    }

    /// An empty queue is a legitimate answer, not a missing one: a round that
    /// found nothing over a pass whose earlier notes are all dealt with reads
    /// three zeroes, and that is the good outcome said plainly.
    func test_anEmptyQueueCountsThreeZeroes() {
        XCTAssertEqual(compute([]), SinceLastRound.Outcome(resolved: 0, persisting: 0, new: 0))
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
        XCTAssertEqual(history.first?.fingerprints, [],
                       "the ring stopped carrying fingerprints in M4 P1 \u{2014} what "
                       + "changed between two rounds is counted off the queue, and a "
                       + "second account of it here would be one that can disagree")

        // …and it survives the relaunch, or "since last round" forgets the
        // round it is measured against every time the writer reopens.
        let reopened = DiagnosticsStore(projectRoot: project, device: device)
        reopened.load(docId: docId)
        XCTAssertEqual(reopened.roundHistory(docId: docId), history)
    }

    /// **A cold document's FIRST run streams, and it has no prior round.**
    ///
    /// The trap this pins: `preview` sets the last finished content aside, and
    /// for a document with no run there is none — but assigning `nil` to a
    /// dictionary subscript removes the key, so "set aside, and there was
    /// nothing" reads exactly like "never set aside". A `replace` that decided
    /// by nil-ness would fall through to the standing content, which at that
    /// moment is this very run's own half-report: round 1 filed against
    /// itself, on the ordinary first ⌘R against a new document.
    func test_aColdDocumentsFirstStreamingRunFilesNothing() {
        let store = DiagnosticsStore(
            projectRoot: URL(fileURLWithPath: "/tmp/unused"),
            device: DeviceSlug.make(from: "test-mac"))
        let docId = "docColdStream"

        let run1 = makeRun(id: "run-1", passId: "P", round: 1)
        let note1 = makeDiagnostic(kind: .conformanceStrain, clauseQuote: "Cold.",
                                   runId: run1.id)
        store.preview(run: run1, diagnostics: [], docId: docId)
        store.preview(run: run1, diagnostics: [note1], docId: docId)
        store.replace(run: run1, diagnostics: [note1], docId: docId)

        XCTAssertEqual(store.roundHistory(docId: docId), [],
                       "a first run has no prior round — least of all itself")

        // …and the run after it, also streamed, files run 1 exactly once.
        let run2 = makeRun(id: "run-2", passId: "P", round: 2)
        store.preview(run: run2, diagnostics: [], docId: docId)
        store.preview(run: run2, diagnostics: [], docId: docId)
        store.replace(run: run2, diagnostics: [], docId: docId)

        XCTAssertEqual(store.roundHistory(docId: docId).map(\.runId), ["run-1"])
        XCTAssertEqual(store.latestRound(forPass: "P", docId: docId), 2)
    }

    /// A preview the writer cancelled leaves the finished run standing, and the
    /// next run that finishes files THAT — not the abandoned half-report, and
    /// not nothing.
    func test_anAbandonedPreviewLeavesTheFinishedRunToBeFiled() throws {
        // A real project root, because `discardPreview` puts the standing
        // answer back by re-reading the sidecar the finished run wrote.
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "docAbandoned"

        store.replace(run: makeRun(id: "run-1", passId: "P", round: 1),
                      diagnostics: [], docId: docId)
        store.preview(run: makeRun(id: "run-2", passId: "P", round: 2),
                      diagnostics: [], docId: docId)
        store.discardPreview(docId: docId)
        store.replace(run: makeRun(id: "run-3", passId: "P", round: 2),
                      diagnostics: [], docId: docId)

        XCTAssertEqual(store.roundHistory(docId: docId).map(\.runId), ["run-1"],
                       "the cancelled run was never a round, and the one it "
                       + "interrupted still had to be filed")
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

    /// **`latestRound` answers the round IN FLIGHT; `standingRound` answers
    /// the round BEFORE it** (R1, #42) — pinned by asking both while a
    /// preview stands in for a run that has not finished.
    ///
    /// `replace` a round 1, then `preview` a round 2 with no matching
    /// `replace`: `latestRound` reads `byDoc` directly and sees round 2 (the
    /// preview), because it answers "which round is this lane on, the one in
    /// flight included" — what the round mint and the Review cockpit strip
    /// both need. `standingRound` reads through the shadow
    /// (`finishedContent`) and still sees round 1, because it answers "what
    /// did the round BEFORE this one say" — a preview's own half-report is
    /// not that answer, or a round would be briefed against itself.
    ///
    /// Had `latestRound` gone through the shadow instead (the alternative R1
    /// rejected), it would have read `standingRound`'s value here too —
    /// round 1 — one behind the run actually streaming.
    ///
    /// `discardPreview` drops the preview untouched, and both readers agree
    /// again: round 1, the last run that actually finished.
    ///
    /// A real project root, per `test_anAbandonedPreviewLeavesTheFinishedRunToBeFiled`'s
    /// note above: `discardPreview` puts the standing answer back by
    /// re-reading the sidecar the finished run wrote, so the read-back needs
    /// somewhere real to read from.
    func test_latestRound_answersTheRoundInFlightWhileAPreviewStands() throws {
        let store = DiagnosticsStore(
            projectRoot: try makeProject(), device: DeviceSlug.make(from: "test-mac"))
        let docId = "docMidPreview"

        store.replace(run: makeRun(passId: "line", round: 1), diagnostics: [], docId: docId)
        store.preview(run: makeRun(passId: "line", round: 2), diagnostics: [], docId: docId)

        XCTAssertEqual(store.latestRound(forPass: "line", docId: docId), 2,
                       "the round in flight, included")
        XCTAssertEqual(store.standingRound(docId: docId)?.record.round, 1,
                       "the round before it — the shadow, not the preview")

        store.discardPreview(docId: docId)

        XCTAssertEqual(store.latestRound(forPass: "line", docId: docId), 1,
                       "the preview is gone; both readers agree again")
        XCTAssertEqual(store.standingRound(docId: docId)?.record.round, 1)
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
