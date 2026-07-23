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

        return CompileFixture(
            store: store, docID: item.id, doc: doc, stores: stores, projectURL: projectURL)
    }

    private func orchestrator(_ fx: CompileFixture, language: String, allowStale: Bool)
        -> CompileOrchestrator
    {
        CompileOrchestrator(
            projectURL: fx.projectURL,
            astSource: ProjectStoreASTSource(
                projectStore: fx.store, language: language, allowStale: allowStale),
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
                projectStore: fx.store, language: language, allowStale: allowStale),
            configStore: fx.stores.configStore,
            publicationStore: fx.stores.publicationStore,
            snapshotStore: fx.stores.snapshotStore,
            jobManager: fx.stores.jobManager,
            maughamVersion: "9.9.9",
            tectonicVersion: "0.15.0")
    }

    private func writeTranslation(
        _ fx: CompileFixture, paragraphID: String, text: String?,
        sourceHash: String, verbatim: Bool = false
    ) async throws {
        let rec = TranslationRecord(
            paragraphId: paragraphID, language: "es", text: text,
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

        let report = TranslationCoverage.check(projectStore: fx.store, language: "es")
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

    // MARK: - Scenario 4: fountain ALL-CAPS action→character drift

    func test_fountainDrift_allCapsActionToCharacter_warns() async throws {
        // Hand-built fountain project: scene heading + a two-line action block.
        let body = """
        INT. WAR ROOM - DAY

        The captain nods slowly.
        Ready the men now.
        """
        let (store, docID, doc) = try await makeFountainFixture(body: body)
        XCTAssertEqual(doc.sequence.count, 2,
            "fixture must be scene heading + one action block paragraph")
        let ids = doc.sequence

        // Fully cover the piece. Scene heading: identity. Action block: a
        // translation that reads as an ALL-CAPS character cue + dialogue.
        let slug = DeviceSlug.make(from: "test-mac")
        func fresh(_ id: String, _ text: String) async throws {
            let rec = TranslationRecord(
                paragraphId: id, language: "es", text: text,
                sourceHash: TranslationHash.hash(doc.paragraphs[id] ?? ""),
                verbatim: false)
            try await TranslationStore.append(
                rec, forDocId: docID, deviceSlug: slug, in: store.url)
        }
        try await fresh(ids[0], doc.paragraphs[ids[0]] ?? "")
        try await fresh(ids[1], "EL CAPITÁN\nPreparen a los hombres.")

        let report = TranslationCoverage.check(projectStore: store, language: "es")
        XCTAssertFalse(report.isBlocked, "piece must be fully covered for drift to run")
        XCTAssertEqual(report.fountainDriftWarnings.count, 1,
            "expected exactly one drift warning, got \(report.fountainDriftWarnings)")
        let warning = try XCTUnwrap(report.fountainDriftWarnings.first)
        XCTAssertTrue(warning.contains("Scene"), "warning must name the piece: \(warning)")
        XCTAssertTrue(warning.contains("action"), "warning must name the source element: \(warning)")
        XCTAssertTrue(warning.contains("character"), "warning must name the drifted element: \(warning)")
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
        let report = TranslationCoverage.check(projectStore: freshStore, language: "es")

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
        let blocked = TranslationCoverage.check(projectStore: fx.store, language: "es")
        XCTAssertNil(blocked.zeroLayerError, "A carries records, so zero-layer is quiet")
        XCTAssertTrue(blocked.isBlocked, "the untranslated stub B must block un-excluded")

        // With B excluded, the gate is clean.
        let clean = TranslationCoverage.check(
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
        let unexcluded = TranslationCoverage.check(projectStore: fx.store, language: "es")
        XCTAssertNotNil(unexcluded.zeroLayerError,
            "un-excluded untranslated doc must fire zero-layer")

        let excluded = TranslationCoverage.check(
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

        let pubs = try await fx.stores.publicationStore.load()
        XCTAssertTrue(pubs.isEmpty, "blocked dry_run must mint no Publication")
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

        let pubs = try await fx.stores.publicationStore.load()
        XCTAssertTrue(pubs.isEmpty, "passing dry_run must mint no Publication")
        let after = try await fx.stores.configStore.load()!
        XCTAssertEqual(after.nextVersion, before.nextVersion,
                       "dry_run must not bump next_version")
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
