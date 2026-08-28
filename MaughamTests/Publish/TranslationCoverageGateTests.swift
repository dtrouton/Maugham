import XCTest
import MaughamCore
@testable import Maugham

/// Task 9: blocking translation coverage gate + Fountain element-drift warnings.
///
/// Five scenarios, each pinning one behavior of `TranslationCoverage.check` and
/// its `CompileOrchestrator` wiring:
///  1. A blocked EPUB compile (stale + missing paragraph, no allow_stale) fails
///     and the error lists the exact ¶ids.
///  2. The SAME gaps compile clean under allow_stale, with warnings itemizing
///     every fallback ¶id.
///  3. Zero-layer guard: compiling a language with no records anywhere fails with
///     the single "no translation layer" error.
///  4. A fully-covered fountain piece whose translation flips an action line into
///     an ALL-CAPS character cue emits an element-drift warning.
///  5. A fully-fresh translation compiles clean with no gate warnings.
///
/// EPUB compiles are pure Swift (no bundled tectonic), so the whole suite runs
/// without the tectonic binary.
@MainActor
final class TranslationCoverageGateTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CovGate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        PublishingStores._resetForTesting()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - fixtures

    private struct CompileFixture {
        let store: ProjectStore
        let docID: String
        let doc: Document
        let stores: PublishingStores
        let projectURL: URL
    }

    /// Build a novel project (publish starter installed), overwrite its starter
    /// doc with `content` BEFORE its first `Document.load` so Bootstrap mints the
    /// anchors from real paragraphs, then wire a base + `es` publish config.
    private func makeCompileFixture(content: String) async throws -> CompileFixture {
        let projectURL = try await ProjectFactory.createNovelProject(
            named: "Cov-\(UUID().uuidString.prefix(6))", in: tmp)
        let probe = try await ProjectStore.load(from: projectURL)
        let item = try XCTUnwrap(
            ProjectStore.collectDocuments(in: probe.manifest.structure).first)
        let path = try XCTUnwrap(item.path)
        let docURL = projectURL.appendingPathComponent(path)
        try content.write(to: docURL, atomically: true, encoding: .utf8)

        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let store = try await ProjectStore.load(from: projectURL)

        let pid = ProjectIdentifier.id(for: projectURL)
        PublishingStores._resetForTesting()
        let stores = PublishingStores.sharedFor(projectID: pid, projectURL: projectURL)
        var cfg = try await stores.configStore.load() ?? PublishConfig()
        cfg.metadata.title = "Base"
        cfg.metadata.author = "Auth"
        cfg.metadata.language = "en"
        cfg.languageOverrides = ["es": .init(metadata: ["title": "Título"])]
        try await stores.configStore.save(cfg)

        // Edition identity (spec 2026-07-23): an es compile renders an EXISTING
        // source version, so seed a source publication at 0.1 — without it the
        // language compile fails during version resolution BEFORE the coverage
        // gate these scenarios exercise.
        try await stores.publicationStore.append(seedSourcePublication())

        return CompileFixture(
            store: store, docID: item.id, doc: doc, stores: stores, projectURL: projectURL)
    }

    /// A source-language Publication (language == nil) at v0.1 — the source
    /// version an `es` edition renders. Format is irrelevant to the resolution
    /// (it only checks language == nil at the version).
    private func seedSourcePublication() -> Publication {
        Publication(
            publicationID: "pub-src", version: "0.1", label: nil, format: .epub,
            outputPath: "Exports/src.epub", snapshotID: "snap-src", checkpointID: "",
            republishedFrom: nil, compiledAt: Date(),
            maughamVersion: "9.9.9", tectonicVersion: "0.15.0", language: nil)
    }

    private func orchestrator(_ fx: CompileFixture, language: String, allowStale: Bool)
        -> CompileOrchestrator
    {
        CompileOrchestrator(
            projectURL: fx.projectURL,
            astSource: ProjectStoreASTSource(
                projectStore: fx.store, language: language),
            configStore: fx.stores.configStore,
            publicationStore: fx.stores.publicationStore,
            snapshotStore: fx.stores.snapshotStore,
            jobManager: fx.stores.jobManager,
            maughamVersion: "9.9.9",
            tectonicVersion: "0.15.0")
    }

    private func orchestrator(_ fx: TwoDocFixture, language: String, allowStale: Bool)
        -> CompileOrchestrator
    {
        CompileOrchestrator(
            projectURL: fx.projectURL,
            astSource: ProjectStoreASTSource(
                projectStore: fx.store, language: language),
            configStore: fx.stores.configStore,
            publicationStore: fx.stores.publicationStore,
            snapshotStore: fx.stores.snapshotStore,
            jobManager: fx.stores.jobManager,
            maughamVersion: "9.9.9",
            tectonicVersion: "0.15.0")
    }

    /// P2: a multi-language compile binds each body itself (`BodyPlan` asks the
    /// source for its own siblings), so the orchestrator is handed an UNBOUND
    /// source rather than one pre-bound to a single tongue.
    private func multiOrchestrator(_ fx: CompileFixture) -> CompileOrchestrator {
        CompileOrchestrator(
            projectURL: fx.projectURL,
            astSource: ProjectStoreASTSource(projectStore: fx.store),
            configStore: fx.stores.configStore,
            publicationStore: fx.stores.publicationStore,
            snapshotStore: fx.stores.snapshotStore,
            jobManager: fx.stores.jobManager,
            maughamVersion: "9.9.9",
            tectonicVersion: "0.15.0")
    }

    private func writeTranslation(
        _ fx: CompileFixture, paragraphID: String, text: String?,
        sourceHash: String, verbatim: Bool = false, language: String = "es"
    ) async throws {
        let rec = TranslationRecord(
            paragraphId: paragraphID, language: language, text: text,
            sourceHash: sourceHash, verbatim: verbatim)
        try await TranslationStore.append(
            rec, forDocId: fx.docID, deviceSlug: DeviceSlug.make(from: "test-mac"),
            in: fx.projectURL)
    }

    private func sourceHash(_ fx: CompileFixture, _ paragraphID: String) -> String {
        TranslationHash.hash(fx.doc.paragraphs[paragraphID] ?? "")
    }

    private func errors(_ outcome: CompileOrchestrator.Outcome) -> [TectonicLogParser.Diagnostic] {
        if case .failed(let errs, _) = outcome { return errs }
        return []
    }

    private func warnings(_ outcome: CompileOrchestrator.Outcome) -> [TectonicLogParser.Diagnostic] {
        if case .completed(_, let warns) = outcome { return warns }
        return []
    }

    // MARK: - Scenario 1: blocked compile lists exact ¶ids

    func test_blockedCompile_failsAndListsExactParagraphIds() async throws {
        let fx = try await makeCompileFixture(content: """
        First paragraph.

        Second paragraph.

        Third paragraph.
        """)
        XCTAssertEqual(fx.doc.sequence.count, 3, "fixture must have three paragraphs")
        let ids = fx.doc.sequence

        // p0 fresh, p1 stale (wrong hash), p2 missing (no record).
        try await writeTranslation(fx, paragraphID: ids[0], text: "Uno.",
                                   sourceHash: sourceHash(fx, ids[0]))
        try await writeTranslation(fx, paragraphID: ids[1], text: "Dos.",
                                   sourceHash: "00000000deadbeef")

        let outcome = try await orchestrator(fx, language: "es", allowStale: false)
            .compile(format: .epub, label: nil, language: "es", allowStale: false)

        guard case .failed = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        let message = errors(outcome).map(\.message).joined(separator: "\n")
        XCTAssertTrue(message.contains("¶\(ids[1])"),
            "blocked error must list the stale ¶id, got: \(message)")
        XCTAssertTrue(message.contains("¶\(ids[2])"),
            "blocked error must list the missing ¶id, got: \(message)")
        XCTAssertTrue(message.contains("1 stale"), message)
        XCTAssertTrue(message.contains("1 missing"), message)
    }

    // MARK: - Scenario 2: allow_stale passes with itemized fallback warnings

    func test_allowStale_compilesCleanWithItemizedWarnings() async throws {
        let fx = try await makeCompileFixture(content: """
        First paragraph.

        Second paragraph.

        Third paragraph.
        """)
        let ids = fx.doc.sequence
        try await writeTranslation(fx, paragraphID: ids[0], text: "Uno.",
                                   sourceHash: sourceHash(fx, ids[0]))
        try await writeTranslation(fx, paragraphID: ids[1], text: "Dos.",
                                   sourceHash: "00000000deadbeef")  // stale

        let outcome = try await orchestrator(fx, language: "es", allowStale: true)
            .compile(format: .epub, label: nil, language: "es", allowStale: true)

        guard case .completed = outcome else {
            return XCTFail("expected .completed under allow_stale, got \(outcome)")
        }
        let message = warnings(outcome).map(\.message).joined(separator: "\n")
        XCTAssertTrue(message.contains("¶\(ids[1])"),
            "allow_stale warnings must itemize the stale fallback ¶id, got: \(message)")
        XCTAssertTrue(message.contains("¶\(ids[2])"),
            "allow_stale warnings must itemize the missing fallback ¶id, got: \(message)")
        XCTAssertTrue(message.lowercased().contains("fallback"), message)
    }

    // MARK: - Scenario 3: zero-layer guard

    func test_zeroLayerGuard_failsWithSingleError() async throws {
        let fx = try await makeCompileFixture(content: """
        First paragraph.

        Second paragraph.
        """)
        // No translation records written for "es".

        let report = try TranslationCoverage.check(projectStore: fx.store, language: "es")
        // Every paragraph is "missing" with no records, so `gaps` are populated
        // too — but `zeroLayerError` is the distinct, higher-precedence outcome
        // the orchestrator surfaces (a single error, not per-piece missing lists).
        XCTAssertEqual(
            report.zeroLayerError,
            "no translation layer for 'es' — run write_translation first")

        let outcome = try await orchestrator(fx, language: "es", allowStale: true)
            .compile(format: .epub, label: nil, language: "es", allowStale: true)
        guard case .failed = outcome else {
            return XCTFail("zero-layer must fail even under allow_stale, got \(outcome)")
        }
        let message = errors(outcome).map(\.message).joined(separator: "\n")
        XCTAssertTrue(message.contains("no translation layer for 'es'"), message)
    }

    // MARK: - Scenario 4: fountain element drift

    private func freshlyCovered(
        body: String, translations: [String]
    ) async throws -> TranslationCoverage.Report {
        let (store, docID, doc) = try await makeFountainFixture(body: body)
        XCTAssertEqual(doc.sequence.count, translations.count,
            "fixture paragraph count must match the translations supplied")
        let slug = DeviceSlug.make(from: "test-mac")
        for (id, text) in zip(doc.sequence, translations) {
            let rec = TranslationRecord(
                paragraphId: id, language: "es", text: text,
                sourceHash: TranslationHash.hash(doc.paragraphs[id] ?? ""),
                verbatim: false)
            try await TranslationStore.append(
                rec, forDocId: docID, deviceSlug: slug, in: store.url)
        }
        let report = try TranslationCoverage.check(projectStore: store, language: "es")
        XCTAssertFalse(report.isBlocked, "piece must be fully covered for drift to run")
        return report
    }

    /// The case this test used to WARN about — an action block whose
    /// translation opens ALL-CAPS and re-parses as a cue — is now carried
    /// across by `TranslatedFountainStructure` (the source element wins), so
    /// the emitter renders action and there is nothing to warn about. A
    /// warning that fired over corrected output would send the translator
    /// chasing a drift the book does not have.
    func test_fountainDrift_allCapsActionToCharacter_isPreservedAndSilent() async throws {
        let body = """
        INT. WAR ROOM - DAY

        The captain nods slowly.
        Ready the men now.
        """
        let report = try await freshlyCovered(
            body: body,
            translations: ["INT. WAR ROOM - DAY", "EL CAPITÁN\nPreparen a los hombres."])
        XCTAssertEqual(report.fountainDriftWarnings, [],
            "structure the emitter preserves must not be reported as drift")
    }

    /// The Serbian shape: every slugline Cyrillic. Fully preserved — zero
    /// warnings, because zero of the output is affected.
    func test_fountainDrift_cyrillicSluglines_areSilent() async throws {
        let body = """
        EXT. TERRACE - DAY

        GRACE
        Morning.

        INT. BAR - NIGHT
        """
        let report = try await freshlyCovered(
            body: body,
            translations: ["ЕКСТ. ТЕРАСА - ДАН", "ГРЕЈС\nДобро јутро.", "ИНТ. БАР - НОЋ"])
        XCTAssertEqual(report.fountainDriftWarnings, [])
    }

    /// Residual drift — a translation whose line count differs from its
    /// source paragraph cannot be aligned, so the re-parse stands and the
    /// warning must say so: the piece, the first line, both elements, and how
    /// many MORE lines drift (the first sighting was one warning over a body
    /// where ~45 sluglines had drifted, and it read as a single bad line).
    func test_fountainDrift_unalignable_warnsOnceWithACount() async throws {
        let body = """
        EXT. TERRACE - DAY

        GRACE
        Morning.

        INT. BAR - NIGHT
        """
        // Both sluglines translated as TWO lines: unalignable, so both drift
        // (heading → cue, and a second line the source never had).
        let report = try await freshlyCovered(
            body: body,
            translations: ["ЕКСТ. ТЕРАСА - ДАН\nдруга", "ГРЕЈС\nДобро јутро.", "ИНТ. БАР - НОЋ\nдруга"])
        XCTAssertEqual(report.fountainDriftWarnings.count, 1,
            "one warning per piece, got \(report.fountainDriftWarnings)")
        let warning = try XCTUnwrap(report.fountainDriftWarnings.first)
        XCTAssertTrue(warning.contains("Scene"), "warning must name the piece: \(warning)")
        XCTAssertTrue(warning.contains("source scene heading"), warning)
        XCTAssertTrue(warning.contains("translated character"), warning)
        XCTAssertTrue(warning.contains("more line"),
            "warning must say how much of the piece drifts beyond the first line: \(warning)")
    }

    // MARK: - Scenario 5: fully-fresh compile passes clean

    func test_fullyFresh_compilesCleanWithNoGateWarnings() async throws {
        let fx = try await makeCompileFixture(content: """
        First paragraph.

        Second paragraph.
        """)
        for id in fx.doc.sequence {
            try await writeTranslation(fx, paragraphID: id, text: "traducción",
                                       sourceHash: sourceHash(fx, id))
        }

        let outcome = try await orchestrator(fx, language: "es", allowStale: false)
            .compile(format: .epub, label: nil, language: "es", allowStale: false)
        guard case .completed = outcome else {
            return XCTFail("fully-fresh compile must complete, got \(outcome)")
        }
        let message = warnings(outcome).map(\.message).joined(separator: "\n").lowercased()
        XCTAssertFalse(message.contains("stale"), "no stale warning expected: \(message)")
        XCTAssertFalse(message.contains("missing"), "no missing warning expected: \(message)")
        XCTAssertFalse(message.contains("drift"), "no drift warning expected: \(message)")
    }

    // MARK: - Scenario 6: empty-paragraph filter (F2 — direct coverage)

    /// A real untranslated paragraph must gate as "missing"; a whitespace-only
    /// paragraph inserted alongside it must never count toward stale, missing,
    /// or the zero-layer trigger, no matter how it got there (the filter in
    /// `TranslationCoverage.check` is a general non-empty-text guard, not
    /// special-cased to Task 7's wholly-empty-doc fixtures).
    func test_emptyParagraphFilter_realParagraphGatesWhitespaceParagraphDoesNot() async throws {
        let fx = try await makeCompileFixture(content: """
        First real paragraph.

        Second real paragraph.
        """)
        XCTAssertEqual(fx.doc.sequence.count, 2, "fixture must have two paragraphs")
        let ids = fx.doc.sequence

        // ids[0] fully translated so `anyRecords` is true and the zero-layer
        // guard doesn't mask the missing-paragraph assertion below. ids[1] is
        // left untranslated on purpose — it must surface as "missing".
        try await writeTranslation(fx, paragraphID: ids[0], text: "Primer párrafo real.",
                                   sourceHash: sourceHash(fx, ids[0]))

        // Insert a whitespace-only paragraph with no translation record at all.
        let blankID = fx.doc.insertParagraph(after: ids[1], text: "   ")
        try await fx.doc.flushBurstNow()

        let freshStore = try await ProjectStore.load(from: fx.projectURL)
        let report = try TranslationCoverage.check(projectStore: freshStore, language: "es")

        XCTAssertNil(report.zeroLayerError,
            "ids[0] carries a real translation record, so zero-layer must not fire")
        XCTAssertTrue(report.isBlocked, "the untranslated real paragraph must block")
        let gap = try XCTUnwrap(report.gaps.first)
        XCTAssertEqual(gap.missing, [ids[1]],
            "only the real untranslated paragraph may appear in missing — " +
            "the whitespace-only paragraph must never appear, got \(gap.missing)")
        XCTAssertFalse(gap.stale.contains(blankID), "whitespace-only paragraph must never be stale")
        XCTAssertFalse(gap.missing.contains(blankID), "whitespace-only paragraph must never be missing")
    }

    // MARK: - Scenario 7: F1 — excluded untranslated stub doesn't gate

    /// A two-piece book: piece A fully translated, piece B an untranslated stub.
    /// Un-excluded, B blocks the edition (and with A carrying records the
    /// zero-layer guard is quiet, so B surfaces as a plain missing gap). Marking
    /// B `include: false` must make the gate pass clean — B produces no gaps and
    /// does NOT feed the zero-layer denominator (this is the ES-edition unlock:
    /// the stub drafts stop blocking the compile).
    func test_excludedUntranslatedStub_passesGate() async throws {
        let fx = try await makeTwoDocFixture(
            a: "Alpha paragraph.", b: "Bravo stub paragraph.")
        // Fully translate every paragraph of A; leave B entirely untranslated.
        for id in fx.docA.doc.sequence {
            let rec = TranslationRecord(
                paragraphId: id, language: "es", text: "Alfa.",
                sourceHash: TranslationHash.hash(fx.docA.doc.paragraphs[id] ?? ""),
                verbatim: false)
            try await TranslationStore.append(
                rec, forDocId: fx.docA.id, deviceSlug: DeviceSlug.make(from: "test-mac"),
                in: fx.projectURL)
        }

        // Without exclusion, B blocks.
        let blocked = try TranslationCoverage.check(projectStore: fx.store, language: "es")
        XCTAssertNil(blocked.zeroLayerError, "A carries records, so zero-layer is quiet")
        XCTAssertTrue(blocked.isBlocked, "the untranslated stub B must block un-excluded")

        // With B excluded, the gate is clean.
        let clean = try TranslationCoverage.check(
            projectStore: fx.store, language: "es", excludedSectionIDs: [fx.docB.id])
        XCTAssertNil(clean.zeroLayerError)
        XCTAssertFalse(clean.isBlocked,
            "an excluded untranslated stub must not produce gaps")
        XCTAssertTrue(clean.gaps.isEmpty, "no gaps expected once B is excluded")

        // End-to-end: config excludes B, the strict (no allow_stale) es compile
        // completes — the whole point of F1 for translated subset editions.
        var cfg = try await fx.stores.configStore.load() ?? PublishConfig()
        cfg.sections[fx.docB.id] = .init(include: false)
        try await fx.stores.configStore.save(cfg)

        let outcome = try await orchestrator(fx, language: "es", allowStale: false)
            .compile(format: .epub, label: nil, language: "es", allowStale: false)
        guard case .completed = outcome else {
            return XCTFail("excluded-stub es compile must complete strictly, got \(outcome)")
        }
    }

    /// The all-excluded-except-translated case in isolation: a single
    /// untranslated doc, excluded, must not fire the zero-layer guard (its
    /// paragraphs are outside the edition, so they can't demand a layer).
    func test_excludedOnlyDoc_doesNotFireZeroLayer() async throws {
        let fx = try await makeCompileFixture(content: "Sole untranslated paragraph.")
        // No records for "es" anywhere.
        let unexcluded = try TranslationCoverage.check(projectStore: fx.store, language: "es")
        XCTAssertNotNil(unexcluded.zeroLayerError,
            "un-excluded untranslated doc must fire zero-layer")

        let excluded = try TranslationCoverage.check(
            projectStore: fx.store, language: "es", excludedSectionIDs: [fx.docID])
        XCTAssertNil(excluded.zeroLayerError,
            "an excluded doc must not feed the zero-layer denominator")
        XCTAssertFalse(excluded.isBlocked)
    }

    // MARK: - F2: dry_run returns the gate verdict, mutating nothing

    /// A stale/missing edition dry_run (no allow_stale) returns the same
    /// `.failed` block a real compile would, and mints no Publication / doesn't
    /// bump the version.
    func test_dryRun_blockedGate_failsWithoutMinting() async throws {
        let fx = try await makeCompileFixture(content: """
        First paragraph.

        Second paragraph.
        """)
        let ids = fx.doc.sequence
        // p0 fresh, p1 missing.
        try await writeTranslation(fx, paragraphID: ids[0], text: "Uno.",
                                   sourceHash: sourceHash(fx, ids[0]))

        let before = try await fx.stores.configStore.load()!
        let outcome = try await orchestrator(fx, language: "es", allowStale: false)
            .compile(format: .epub, label: nil, language: "es",
                     allowStale: false, dryRun: true)
        guard case .failed = outcome else {
            return XCTFail("blocked dry_run must fail, got \(outcome)")
        }
        XCTAssertTrue(errors(outcome).map(\.message).joined().contains("¶\(ids[1])"))

        // Only the seeded source publication remains — the blocked dry_run
        // minted no NEW (es) Publication (spec 2026-07-23 seeding).
        let pubs = try await fx.stores.publicationStore.load()
        XCTAssertEqual(pubs.count, 1,
                       "only the seeded source publication may remain: \(pubs)")
        XCTAssertNil(pubs.first?.language,
                     "the sole remaining publication is the seeded source (language == nil)")
        let after = try await fx.stores.configStore.load()!
        XCTAssertEqual(after.nextVersion, before.nextVersion,
                       "dry_run must not bump next_version")
    }

    /// A fully-fresh edition dry_run returns `.dryRunPassed` (the verdict a real
    /// compile would have produced) without minting a Publication or bumping the
    /// version.
    func test_dryRun_freshGate_passesWithoutMinting() async throws {
        let fx = try await makeCompileFixture(content: """
        First paragraph.

        Second paragraph.
        """)
        for id in fx.doc.sequence {
            try await writeTranslation(fx, paragraphID: id, text: "traducción",
                                       sourceHash: sourceHash(fx, id))
        }

        let before = try await fx.stores.configStore.load()!
        let outcome = try await orchestrator(fx, language: "es", allowStale: false)
            .compile(format: .epub, label: nil, language: "es",
                     allowStale: false, dryRun: true)
        guard case .dryRunPassed = outcome else {
            return XCTFail("fresh dry_run must pass, got \(outcome)")
        }

        // Only the seeded source publication remains — the passing dry_run
        // minted no NEW (es) Publication (spec 2026-07-23 seeding).
        let pubs = try await fx.stores.publicationStore.load()
        XCTAssertEqual(pubs.count, 1,
                       "only the seeded source publication may remain: \(pubs)")
        XCTAssertNil(pubs.first?.language,
                     "the sole remaining publication is the seeded source (language == nil)")
        let after = try await fx.stores.configStore.load()!
        XCTAssertEqual(after.nextVersion, before.nextVersion,
                       "dry_run must not bump next_version")
    }

    // MARK: - P2: one gate per tongue
    //
    // A multi-language compile runs the gate once per translated body and
    // fails ONCE, carrying every blocked tongue's errors. Each diagnostic
    // message is prefixed with the tag it belongs to — for single-language
    // compiles too, because one contract is cheaper to read than two.

    /// Two translated bodies, both blocked for different reasons: the refusal
    /// carries BOTH tongues' errors, each under its own tag. Reporting only the
    /// first would send the writer round the loop once per language.
    func test_p2_everyBlockedTongueIsReported_eachUnderItsOwnTag() async throws {
        let fx = try await makeCompileFixture(content: """
        First paragraph.

        Second paragraph.
        """)
        let ids = fx.doc.sequence
        // es: one fresh, one stale → blocked, itemized by ¶id.
        try await writeTranslation(fx, paragraphID: ids[0], text: "Uno.",
                                   sourceHash: sourceHash(fx, ids[0]))
        try await writeTranslation(fx, paragraphID: ids[1], text: "Dos.",
                                   sourceHash: "00000000deadbeef")
        // fr: no records at all → the zero-layer refusal.

        let outcome = try await multiOrchestrator(fx)
            .compile(format: .epub, label: nil, languages: ["es", "fr"])
        guard case .failed = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        let messages = errors(outcome).map(\.message)
        XCTAssertTrue(
            messages.contains { $0.hasPrefix("[es] ") && $0.contains("¶\(ids[1])") },
            "the stale es paragraph must be reported under [es]: \(messages)")
        XCTAssertTrue(
            messages.contains {
                $0 == "[fr] no translation layer for 'fr' — run write_translation first"
            },
            "the fr zero-layer refusal must be reported under [fr]: \(messages)")
    }

    /// A failure is whole: when one tongue blocks, the tongue that PASSED
    /// contributes nothing — not its fallback warnings, not its tag. Nothing
    /// was compiled, so there is nothing for a warning to be about.
    func test_p2_aPassingTonguesWarningsAppearNowhereWhenAnotherIsBlocked() async throws {
        let fx = try await makeCompileFixture(content: """
        First paragraph.

        Second paragraph.
        """)
        let ids = fx.doc.sequence
        try await writeTranslation(fx, paragraphID: ids[0], text: "Uno.",
                                   sourceHash: sourceHash(fx, ids[0]))
        try await writeTranslation(fx, paragraphID: ids[1], text: "Dos.",
                                   sourceHash: "00000000deadbeef")

        // allow_stale lets es through with fallback warnings; fr's zero layer
        // refuses regardless.
        let outcome = try await multiOrchestrator(fx).compile(
            format: .epub, label: nil, languages: ["es", "fr"], allowStale: true)
        guard case .failed = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        let joined = errors(outcome).map(\.message).joined(separator: "\n")
        XCTAssertFalse(joined.contains("[es]"),
                       "the passing tongue says nothing on a failure: \(joined)")
        XCTAssertFalse(joined.lowercased().contains("fallback"), joined)

        // The control: es ALONE under allow_stale completes and does carry
        // those warnings — so their absence above means something.
        let alone = try await multiOrchestrator(fx).compile(
            format: .epub, label: nil, languages: ["es"], allowStale: true)
        guard case .completed = alone else {
            return XCTFail("es alone must complete under allow_stale, got \(alone)")
        }
        let warned = warnings(alone).map(\.message).joined(separator: "\n")
        XCTAssertTrue(warned.contains("[es] "), warned)
        XCTAssertTrue(warned.lowercased().contains("fallback"), warned)
    }

    /// The tag prefix is ONE contract, not a multi-language special case: a
    /// single-tongue compile's diagnostics carry it too, and are otherwise
    /// exactly what `applyGate` produced — message prefixed, context lines
    /// untouched.
    func test_p2_theSingleTongueRefusalIsApplyGatesOwnSentenceUnderItsTag() async throws {
        let fx = try await makeCompileFixture(content: """
        First paragraph.

        Second paragraph.
        """)
        let ids = fx.doc.sequence
        try await writeTranslation(fx, paragraphID: ids[0], text: "Uno.",
                                   sourceHash: sourceHash(fx, ids[0]))
        try await writeTranslation(fx, paragraphID: ids[1], text: "Dos.",
                                   sourceHash: "00000000deadbeef")

        let outcome = try await orchestrator(fx, language: "es", allowStale: false)
            .compile(format: .epub, label: nil, language: "es", allowStale: false)
        guard case .failed = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        let report = try TranslationCoverage.check(projectStore: fx.store, language: "es")
        guard case .blocked(let expected, _) = TranslationCoverage.applyGate(
            report: report, language: "es", allowStale: false) else {
            return XCTFail("the fixture must block")
        }
        XCTAssertEqual(errors(outcome).map(\.message),
                       expected.map { "[es] " + $0.message })
        XCTAssertEqual(errors(outcome).map(\.contextLines),
                       expected.map(\.contextLines),
                       "the prefix goes on the message and nothing else")
    }

    // MARK: - two-doc fixture (F1)

    private struct TwoDocFixture {
        let store: ProjectStore
        let docA: (id: String, doc: Document)
        let docB: (id: String, doc: Document)
        let stores: PublishingStores
        let projectURL: URL
    }

    /// Hand-built two-piece novel project (A then B), each loaded through
    /// `Document.load` so Bootstrap mints real anchors, wired with a base + `es`
    /// publish config. Mirrors `makeCompileFixture` but with two pieces so an
    /// exclusion can be observed relative to a translated sibling.
    private func makeTwoDocFixture(a: String, b: String) async throws -> TwoDocFixture {
        let projectDir = tmp.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: projectDir.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let pathA = "manuscript/a.md"
        let pathB = "manuscript/b.md"
        let idA = "doc-a"
        let idB = "doc-b"
        try a.write(to: projectDir.appendingPathComponent(pathA), atomically: true, encoding: .utf8)
        try b.write(to: projectDir.appendingPathComponent(pathB), atomically: true, encoding: .utf8)

        let itemA = StructureItem(id: idA, title: "A", type: .document, path: pathA)
        let itemB = StructureItem(id: idB, title: "B", type: .document, path: pathB)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(), structure: [itemA, itemB], research: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: projectDir.appendingPathComponent(ProjectManifest.fileName))

        let store = try await ProjectStore.load(from: projectDir)
        let docA = try await Document.load(
            url: projectDir.appendingPathComponent(pathA),
            device: "test", session: "s", presenter: nil)
        let docB = try await Document.load(
            url: projectDir.appendingPathComponent(pathB),
            device: "test", session: "s", presenter: nil)

        let pid = ProjectIdentifier.id(for: projectDir)
        PublishingStores._resetForTesting()
        let stores = PublishingStores.sharedFor(projectID: pid, projectURL: projectDir)
        var cfg = try await stores.configStore.load() ?? PublishConfig()
        cfg.metadata.title = "Base"
        cfg.metadata.author = "Auth"
        cfg.metadata.language = "en"
        cfg.languageOverrides = ["es": .init(metadata: ["title": "Título"])]
        try await stores.configStore.save(cfg)

        // Edition identity (spec 2026-07-23): seed a source publication so the
        // es compile resolves to it rather than failing loudly (see
        // `makeCompileFixture`).
        try await stores.publicationStore.append(seedSourcePublication())

        return TwoDocFixture(
            store: store, docA: (idA, docA), docB: (idB, docB),
            stores: stores, projectURL: projectDir)
    }

    // MARK: - fountain fixture (check-level, no compile)

    private func makeFountainFixture(body: String) async throws
        -> (store: ProjectStore, docID: String, doc: Document)
    {
        let projectDir = tmp.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: projectDir.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let path = "manuscript/scene.fountain"
        let docID = "doc-scene-fountain"
        let docURL = projectDir.appendingPathComponent(path)
        try body.write(to: docURL, atomically: true, encoding: .utf8)

        let item = StructureItem(id: docID, title: "Scene", type: .document, path: path)
        let manifest = ProjectManifest(
            type: .screenplay, title: "T", author: "A",
            created: Date(), modified: Date(), structure: [item], research: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: projectDir.appendingPathComponent(ProjectManifest.fileName))

        let store = try await ProjectStore.load(from: projectDir)
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        return (store, docID, doc)
    }
}
