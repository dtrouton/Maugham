import XCTest
import MaughamCore
import PDFKit
@testable import Maugham

@MainActor
final class RepublisherTests: XCTestCase {

    var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepubTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try await PublishStarter.install(into: tmp, force: false)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testRepublish_usesSnapshotTemplate_notCurrent() async throws {
        // Reads the real premise: tectonic bundled AND its TeX bundle obtainable.
        try await TectonicProbe.requireReady()

        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hello.")]
            }
        }
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Repub", author: "T")))

        // 1. Initial compile creates v0.1 + snapshot.
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: PublicationStore(projectURL: tmp),
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")
        let initial = try await orch.compile(format: .pdf, label: nil)
        guard case .completed(let initialPub, _) = initial else {
            XCTFail("initial failed: \(initial)")
            return
        }

        // 2. Mutate the live template to be invalid LaTeX. If Republisher
        //    used live state, this would break the compile.
        let templateURL = tmp.appendingPathComponent(".maugham/publish/template.tex")
        try "\\undefined_command_xyz".write(
            to: templateURL, atomically: true, encoding: .utf8)

        // 3. Republish from the original snapshot — succeeds because it uses
        //    the snapshotted template.
        let r = Republisher(
            projectURL: tmp,
            astSource: Src(),
            publicationStore: PublicationStore(projectURL: tmp),
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")
        let outcome = try await r.republish(
            snapshotID: initialPub.snapshotID,
            format: .pdf, label: nil)
        switch outcome {
        case .completed(let pub, _):
            XCTAssertEqual(pub.republishedFrom, "0.1")
        case .failed(let errors, let log):
            XCTFail("republish failed: errors=\(errors.map(\.message)) log=\(log.prefix(300))")
        case .dryRunPassed:
            XCTFail("republish never produces dry_run_passed")
        case .cancelled:
            XCTFail("nothing cancelled this republish")
        }
    }

    /// Finding 1: `Republisher` used to build its compilers and the new
    /// `Publication` with a default `language: nil`, so a republished
    /// Spanish edition's catalog record reported untagged and its filename
    /// lacked the `-es` suffix — even though the snapshotted config (and
    /// thus the compiled content) was already Spanish. Republisher must
    /// carry the prior publication's `language` forward.
    func testRepublish_carriesEditionLanguageAndFilenameSuffix() async throws {
        // Reads the real premise: tectonic bundled AND its TeX bundle obtainable.
        try await TectonicProbe.requireReady()

        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hola.")]
            }
        }
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "RepubLang", author: "T")))

        // Edition identity (spec 2026-07-23): a language edition renders an
        // EXISTING source version, so seed a source publication at 0.1 first —
        // the es compile targets it rather than minting its own version.
        let pubStore = PublicationStore(projectURL: tmp)
        try await pubStore.append(Publication(
            publicationID: "pub-src", version: "0.1", label: nil, format: .pdf,
            outputPath: "Exports/src.pdf", snapshotID: "snap-src", checkpointID: "",
            republishedFrom: nil, compiledAt: Date(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0", language: nil))

        // 1. Initial Spanish-edition compile renders v0.1 + a snapshot whose
        //    Publication.language is "es".
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: pubStore,
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")
        let initial = try await orch.compile(format: .pdf, label: nil, language: "es")
        guard case .completed(let initialPub, _) = initial else {
            XCTFail("initial failed: \(initial)")
            return
        }
        XCTAssertEqual(initialPub.language, "es")

        // 2. Republish from that snapshot — the new record must carry the
        //    edition language forward, and the output filename must stay
        //    language-suffixed.
        let r = Republisher(
            projectURL: tmp,
            astSource: Src(),
            publicationStore: PublicationStore(projectURL: tmp),
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")
        let outcome = try await r.republish(
            snapshotID: initialPub.snapshotID,
            format: .pdf, label: nil)
        switch outcome {
        case .completed(let pub, _):
            XCTAssertEqual(pub.language, "es")
            XCTAssertTrue(pub.outputPath.hasSuffix("-es.pdf"),
                          "expected language-suffixed republish filename, got \(pub.outputPath)")
        case .failed(let errors, let log):
            XCTFail("republish failed: errors=\(errors.map(\.message)) log=\(log.prefix(300))")
        case .dryRunPassed:
            XCTFail("republish never produces dry_run_passed")
        case .cancelled:
            XCTFail("nothing cancelled this republish")
        }
    }

    // MARK: - F1: republish re-runs the translation coverage gate

    private struct GatedRepubFixture {
        let projectURL: URL
        let item: StructureItem
        let doc: Document
        let store: ProjectStore
        let configStore: PublishConfigStore
        let publicationStore: PublicationStore
        let snapshotStore: PublicationSnapshotStore
        let jobManager: CompileJobManager
    }

    /// A real novel project with two paragraphs, wired with the plain
    /// (non-shared) stores `Republisher`/`CompileOrchestrator` take directly,
    /// matching this file's existing construction style. `translateAll`
    /// controls whether the second paragraph gets an `es` translation record
    /// at all — `false` leaves it permanently missing, for round-3's
    /// persistent-gap-under-allow_stale scenario.
    private func makeGatedRepubFixture(translateAll: Bool = true) async throws -> GatedRepubFixture {
        let projectURL = try await ProjectFactory.createNovelProject(
            named: "RepubGate-\(UUID().uuidString.prefix(6))", in: tmp)
        let probe = try await ProjectStore.load(from: projectURL)
        let item = try XCTUnwrap(
            ProjectStore.collectDocuments(in: probe.manifest.structure).first)
        let path = try XCTUnwrap(item.path)
        let docURL = projectURL.appendingPathComponent(path)
        try """
        First paragraph.

        Second paragraph.
        """.write(to: docURL, atomically: true, encoding: .utf8)

        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let store = try await ProjectStore.load(from: projectURL)
        XCTAssertEqual(doc.sequence.count, 2, "fixture must have two paragraphs")

        let configStore = PublishConfigStore(projectURL: projectURL)
        var cfg = try await configStore.load() ?? PublishConfig()
        cfg.metadata.title = "RepubGate"
        cfg.metadata.author = "T"
        cfg.metadata.language = "en"
        cfg.languageOverrides = ["es": .init(metadata: ["title": "Título"])]
        try await configStore.save(cfg)

        let idsToTranslate = translateAll ? doc.sequence : [doc.sequence[0]]
        for id in idsToTranslate {
            let rec = TranslationRecord(
                paragraphId: id, language: "es", text: "Traducción \(id).",
                sourceHash: TranslationHash.hash(doc.paragraphs[id] ?? ""),
                verbatim: false)
            try await TranslationStore.append(
                rec, forDocId: item.id, deviceSlug: DeviceSlug.make(from: "test-mac"),
                in: projectURL)
        }

        // Edition identity (spec 2026-07-23): every consumer of this fixture
        // compiles a language ("es") edition, which now renders an EXISTING
        // source version rather than minting its own. Seed a source publication
        // at 0.1 so the es compile resolves to it.
        let publicationStore = PublicationStore(projectURL: projectURL)
        try await publicationStore.append(Publication(
            publicationID: "pub-src", version: "0.1", label: nil, format: .epub,
            outputPath: "Exports/src.epub", snapshotID: "snap-src", checkpointID: "",
            republishedFrom: nil, compiledAt: Date(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0", language: nil))

        return GatedRepubFixture(
            projectURL: projectURL, item: item, doc: doc, store: store,
            configStore: configStore,
            publicationStore: publicationStore,
            snapshotStore: PublicationSnapshotStore(projectURL: projectURL),
            jobManager: CompileJobManager())
    }

    /// Finding F1: `Republisher` built its compilers from the live
    /// `ProjectStore`-backed `astSource` — the snapshot freezes config/
    /// templates only, never manuscript/translation content — so a
    /// republished translated edition could ship a paragraph the ORIGINAL
    /// gated compile would have refused, if the source changed underneath it
    /// in between. `republish` must re-run `TranslationCoverage.check` and
    /// refuse exactly like `compile` does (no `allow_stale` — republish is a
    /// reproduction command, not a place to accept a new fallback).
    func testRepublish_blockedWhenSourceEditStalesTranslationAfterGatedCompile() async throws {
        let fx = try await makeGatedRepubFixture()
        let ids = fx.doc.sequence

        // 1. Gated compile with FULL "es" coverage succeeds.
        let orch = CompileOrchestrator(
            projectURL: fx.projectURL,
            astSource: ProjectStoreASTSource(
                projectStore: fx.store, language: "es"),
            configStore: fx.configStore,
            publicationStore: fx.publicationStore,
            snapshotStore: fx.snapshotStore,
            jobManager: fx.jobManager,
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")
        let initial = try await orch.compile(
            format: .epub, label: nil, language: "es", allowStale: false)
        guard case .completed(let initialPub, _) = initial else {
            XCTFail("initial gated compile failed: \(initial)")
            return
        }
        XCTAssertEqual(initialPub.language, "es")

        // 2. Edit the source AFTER the gated compile — stales ids[1]'s
        //    translation relative to the now-changed paragraph text.
        fx.doc.setParagraph(id: ids[1], text: "Second paragraph, revised.")
        try await fx.doc.flushBurstNow()

        // 3. Republish from that snapshot: must re-run the gate and refuse,
        //    naming the now-stale ¶id — a snapshot-frozen config does not
        //    make the manuscript content safe to reproduce untouched.
        let freshStore = try await ProjectStore.load(from: fx.projectURL)
        let r = Republisher(
            projectURL: fx.projectURL,
            astSource: ProjectStoreASTSource(
                projectStore: freshStore, language: "es"),
            publicationStore: fx.publicationStore,
            snapshotStore: fx.snapshotStore,
            jobManager: fx.jobManager,
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")
        let outcome = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)

        guard case .failed(let errors, _) = outcome else {
            XCTFail("expected republish to fail on the now-stale translation, got \(outcome)")
            return
        }
        let message = errors.map(\.message).joined(separator: "\n")
        XCTAssertTrue(message.contains("¶\(ids[1])"),
            "republish gate must name the stale ¶id, got: \(message)")
        XCTAssertTrue(message.contains("1 stale"), message)
    }

    /// Companion to the blocked case above: with NO source edits since the
    /// gated compile, republish must still succeed and carry the edition
    /// `language` forward (the existing pin from
    /// `testRepublish_carriesEditionLanguageAndFilenameSuffix`), proving F1's
    /// gate doesn't false-positive on a clean reproduction.
    func testRepublish_succeedsAndCarriesLanguage_whenNoEditsSinceGatedCompile() async throws {
        let fx = try await makeGatedRepubFixture()

        let orch = CompileOrchestrator(
            projectURL: fx.projectURL,
            astSource: ProjectStoreASTSource(
                projectStore: fx.store, language: "es"),
            configStore: fx.configStore,
            publicationStore: fx.publicationStore,
            snapshotStore: fx.snapshotStore,
            jobManager: fx.jobManager,
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")
        let initial = try await orch.compile(
            format: .epub, label: nil, language: "es", allowStale: false)
        guard case .completed(let initialPub, _) = initial else {
            XCTFail("initial gated compile failed: \(initial)")
            return
        }

        // No edits in between — republish from the same, still-fresh source.
        let r = Republisher(
            projectURL: fx.projectURL,
            astSource: ProjectStoreASTSource(
                projectStore: fx.store, language: "es"),
            publicationStore: fx.publicationStore,
            snapshotStore: fx.snapshotStore,
            jobManager: fx.jobManager,
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")
        let outcome = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)

        switch outcome {
        case .completed(let pub, _):
            XCTAssertEqual(pub.language, "es")
            XCTAssertTrue(pub.outputPath.hasSuffix("-es.epub"),
                "expected language-suffixed republish filename, got \(pub.outputPath)")
        case .failed(let errors, let log):
            XCTFail("republish failed: errors=\(errors.map(\.message)) log=\(log.prefix(300))")
        case .dryRunPassed:
            XCTFail("republish never produces dry_run_passed")
        case .cancelled:
            XCTFail("nothing cancelled this republish")
        }
    }

    // MARK: - F1 round 3: republish honors the original compile's allow_stale mode

    /// Round 3: republish has no `allow_stale` parameter of its own — it
    /// replays whichever gate mode the ORIGINAL compile used. An edition
    /// compiled with `allow_stale: true` must republish successfully even
    /// with the SAME persistent gap still present (no source edit at all —
    /// this isn't "new staleness slipping through", it's the mode the writer
    /// already opted into), demoting the gap to an itemized warning again.
    func testRepublish_allowStaleEdition_succeedsWithItemizedWarningForPersistentGap() async throws {
        let fx = try await makeGatedRepubFixture(translateAll: false)
        let ids = fx.doc.sequence

        // 1. Initial compile under allow_stale: ids[1] has no translation
        //    record at all, so it falls back to source text — demoted to a
        //    warning, not a block.
        let orch = CompileOrchestrator(
            projectURL: fx.projectURL,
            astSource: ProjectStoreASTSource(
                projectStore: fx.store, language: "es"),
            configStore: fx.configStore,
            publicationStore: fx.publicationStore,
            snapshotStore: fx.snapshotStore,
            jobManager: fx.jobManager,
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")
        let initial = try await orch.compile(
            format: .epub, label: nil, language: "es", allowStale: true)
        guard case .completed(let initialPub, let initialWarnings) = initial else {
            XCTFail("initial allow_stale compile failed: \(initial)")
            return
        }
        XCTAssertEqual(initialPub.allowStale, true,
            "an allow_stale compile must record allowStale on its Publication")
        XCTAssertTrue(initialWarnings.map(\.message).joined().contains("¶\(ids[1])"),
            "initial compile must itemize the missing paragraph as a warning")

        // 2. No source edits — the SAME gap persists. Republish must still
        //    succeed, demoting the persistent gap to a warning again rather
        //    than blocking (which is what round 1's strict-gate fix would
        //    otherwise do unconditionally).
        let r = Republisher(
            projectURL: fx.projectURL,
            astSource: ProjectStoreASTSource(
                projectStore: fx.store, language: "es"),
            publicationStore: fx.publicationStore,
            snapshotStore: fx.snapshotStore,
            jobManager: fx.jobManager,
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")
        let outcome = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)

        guard case .completed(let pub, let warnings) = outcome else {
            XCTFail("expected allow_stale republish to succeed, got \(outcome)")
            return
        }
        XCTAssertEqual(pub.allowStale, true,
            "the republished edition must carry allowStale forward")
        let message = warnings.map(\.message).joined(separator: "\n")
        XCTAssertTrue(message.contains("¶\(ids[1])"),
            "republish gate must itemize the persistent gap as a warning, got: \(message)")
        XCTAssertTrue(message.lowercased().contains("fallback"), message)
    }

    // MARK: - F1: republish reproduces the snapshot's included subset

    /// The `include` flags live in `PublishConfig`, which is already snapshotted,
    /// so a subset compiled once reproduces the SAME subset on republish for
    /// free. Pin both halves: (1) the snapshot round-trips the exclusion, and
    /// (2) republish wraps the live source with the snapshot's excluded set and
    /// completes. The initial EPUB compile's durable `build/body.xhtml` proves
    /// the excluded piece was actually dropped from the emitted body.
    func testRepublish_reproducesSnapshotSubset() async throws {
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "Alpha", mode: .prose, displayText: "First."),
                 .init(pieceID: "p2", title: "Bravo", mode: .prose, displayText: "Middle."),
                 .init(pieceID: "p3", title: "Charlie", mode: .prose, displayText: "Third.")]
            }
        }
        let configStore = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig(metadata: .init(title: "RepubSubset", author: "T"))
        cfg.sections["p2"] = .init(include: false)
        try await configStore.save(cfg)

        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)

        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let initial = try await orch.compile(format: .epub, label: nil)
        guard case .completed(let initialPub, _) = initial else {
            return XCTFail("initial subset compile failed: \(initial)")
        }

        // The emitted body dropped the excluded piece.
        let body = try String(
            contentsOf: tmp.appendingPathComponent(".maugham/publish/build/body.xhtml"),
            encoding: .utf8)
        XCTAssertFalse(body.contains("data-piece-id=\"p2\""),
                       "excluded piece must be absent from the initial compile body")

        // The snapshot froze the include flag — republish reads it back.
        let snap = try snapStore.load(id: initialPub.snapshotID)
        XCTAssertEqual(snap.config.excludedSectionIDs, ["p2"],
                       "snapshot must round-trip the include=false flag")

        let r = Republisher(
            projectURL: tmp, astSource: Src(),
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let outcome = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)
        guard case .completed(let pub, _) = outcome else {
            return XCTFail("subset republish failed: \(outcome)")
        }
        XCTAssertEqual(pub.republishedFrom, "0.1")
    }

    // MARK: - F1 round 5: republish surfaces fountain drift warnings too

    private struct FountainRepubFixture {
        let projectURL: URL
        let item: StructureItem
        let doc: Document
        let store: ProjectStore
        let configStore: PublishConfigStore
        let publicationStore: PublicationStore
        let snapshotStore: PublicationSnapshotStore
        let jobManager: CompileJobManager
    }

    /// A real screenplay project with one fully-`es`-translated fountain
    /// piece whose translation deliberately flips an action line into an
    /// ALL-CAPS character cue — the SAME drift
    /// `TranslationCoverageGateTests
    /// .test_fountainDrift_allCapsActionToCharacter_warns` exercises at the
    /// `TranslationCoverage.check` level, wired end-to-end here through a
    /// real compile + republish.
    private func makeFountainRepubFixture() async throws -> FountainRepubFixture {
        let projectURL = try await ProjectFactory.createScreenplayProject(
            named: "RepubDrift-\(UUID().uuidString.prefix(6))", in: tmp)
        let probe = try await ProjectStore.load(from: projectURL)
        let item = try XCTUnwrap(
            ProjectStore.collectDocuments(in: probe.manifest.structure).first)
        let path = try XCTUnwrap(item.path)
        let docURL = projectURL.appendingPathComponent(path)
        try """
        INT. WAR ROOM - DAY

        The captain nods slowly.
        Ready the men now.
        """.write(to: docURL, atomically: true, encoding: .utf8)

        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let store = try await ProjectStore.load(from: projectURL)
        XCTAssertEqual(doc.sequence.count, 2,
            "fixture must be scene heading + one action block paragraph")
        let ids = doc.sequence

        let configStore = PublishConfigStore(projectURL: projectURL)
        var cfg = try await configStore.load() ?? PublishConfig()
        cfg.metadata.title = "RepubDrift"
        cfg.metadata.author = "T"
        cfg.metadata.language = "en"
        cfg.languageOverrides = ["es": .init(metadata: ["title": "Título"])]
        try await configStore.save(cfg)

        let slug = DeviceSlug.make(from: "test-mac")
        func fresh(_ id: String, _ text: String) async throws {
            let rec = TranslationRecord(
                paragraphId: id, language: "es", text: text,
                sourceHash: TranslationHash.hash(doc.paragraphs[id] ?? ""),
                verbatim: false)
            try await TranslationStore.append(
                rec, forDocId: item.id, deviceSlug: slug, in: projectURL)
        }
        // Scene heading: identity translation (fully covered, no gap).
        // Action block: translated as THREE lines against the source's two,
        // so `TranslatedFountainStructure` cannot align it and the ALL-CAPS
        // first line re-parses as a cue — residual drift, the kind the
        // warning still reports (a two-line translation would be preserved
        // as action and warn about nothing, `TranslationCoverageGateTests`).
        try await fresh(ids[0], doc.paragraphs[ids[0]] ?? "")
        try await fresh(ids[1], "EL CAPITÁN\nPreparen\na los hombres.")

        // Edition identity (spec 2026-07-23): seed a source publication so the
        // consumer's language ("es") compile renders it rather than minting a
        // new version.
        let publicationStore = PublicationStore(projectURL: projectURL)
        try await publicationStore.append(Publication(
            publicationID: "pub-src", version: "0.1", label: nil, format: .epub,
            outputPath: "Exports/src.epub", snapshotID: "snap-src", checkpointID: "",
            republishedFrom: nil, compiledAt: Date(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0", language: nil))

        return FountainRepubFixture(
            projectURL: projectURL, item: item, doc: doc, store: store,
            configStore: configStore,
            publicationStore: publicationStore,
            snapshotStore: PublicationSnapshotStore(projectURL: projectURL),
            jobManager: CompileJobManager())
    }

    /// Round 5: `Republisher.republish` used to reimplement the gate block
    /// inline and never read `report.fountainDriftWarnings` at all, so a
    /// republished screenplay edition silently dropped this warning even
    /// though the same-language `compile` surfaced it. Both now route
    /// through the ONE shared `TranslationCoverage.applyGate`, so this
    /// asserts republish surfaces the SAME drift warning `compile` does.
    func testRepublish_surfacesFountainDriftWarning() async throws {
        let fx = try await makeFountainRepubFixture()

        let orch = CompileOrchestrator(
            projectURL: fx.projectURL,
            astSource: ProjectStoreASTSource(
                projectStore: fx.store, language: "es"),
            configStore: fx.configStore,
            publicationStore: fx.publicationStore,
            snapshotStore: fx.snapshotStore,
            jobManager: fx.jobManager,
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")
        let initial = try await orch.compile(
            format: .epub, label: nil, language: "es", allowStale: false)
        guard case .completed(let initialPub, let initialWarnings) = initial else {
            XCTFail("initial es compile failed: \(initial)")
            return
        }
        XCTAssertTrue(
            initialWarnings.map(\.message).joined().lowercased().contains("drift"),
            "initial compile must surface the fountain drift warning")

        // No source edits — republish the SAME snapshot.
        let r = Republisher(
            projectURL: fx.projectURL,
            astSource: ProjectStoreASTSource(
                projectStore: fx.store, language: "es"),
            publicationStore: fx.publicationStore,
            snapshotStore: fx.snapshotStore,
            jobManager: fx.jobManager,
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")
        let outcome = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)

        guard case .completed(_, let warnings) = outcome else {
            XCTFail("expected republish to succeed, got \(outcome)")
            return
        }
        let message = warnings.map(\.message).joined(separator: "\n").lowercased()
        XCTAssertTrue(message.contains("drift"),
            "republish must surface the fountain drift warning too, got: \(message)")
        XCTAssertTrue(message.contains("action"), message)
        XCTAssertTrue(message.contains("character"), message)
    }

    // MARK: - P1 (issue #25): republish must never wear the original's filename

    /// P1 (issue #25): republish clobbered the ORIGINAL edition's artifact —
    /// the staged filename came from snap.config's pinned nextVersion. The
    /// original's bytes must survive a republish, verbatim.
    /// RULING-52 + RULING-7 (fix for M7-PB-005/006 on the republish path):
    /// with the catalog file made read-only after the original compile, the
    /// republish's append throws AFTER the artifact has been moved into
    /// Exports/ — the failure must name the moved file and terminalise the job.
    func test_aRepublishFailureAfterTheMoveNamesTheMovedFile() async throws {
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hello.")]
            }
        }
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Led", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        guard case .completed(let initialPub, _) = try await orch.compile(format: .epub, label: nil)
        else { return XCTFail("fixture compile failed") }

        let catalogURL = PublicationStore.fileURL(
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current), in: tmp)
        try FileManager.default.setAttributes(
            [.immutable: true], ofItemAtPath: catalogURL.path)
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false], ofItemAtPath: catalogURL.path)
        }

        let jobs = CompileJobManager()
        let r = Republisher(
            projectURL: tmp, astSource: Src(),
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: jobs,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let outcome = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)
        guard case .failed(let errors, _) = outcome else {
            return XCTFail("the thrown append must surface as .failed, got \(outcome)")
        }
        let context = (errors.first?.contextLines ?? []).joined(separator: "\n")
        XCTAssertTrue(context.contains("Exports/"),
                      "the report names the moved artifact — found: \(context)")
        let inFlight = await jobs.allInProgress()
        XCTAssertTrue(inFlight.isEmpty, "the job is terminal, not stranded")
    }

    /// RULING-8 (fix for M7-PB-011): the Exports pane refreshes on
    /// `.maughamPublicationCompleted`, and a republish lands a publication the
    /// same as a compile does — so it posts the same project-scoped event.
    /// One question ("does this edition exist?"), one answer on both paths.
    func test_republishPostsTheCompletionEventTheExportsPaneRefreshesOn() async throws {
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hello.")]
            }
        }
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Evt", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        guard case .completed(let initialPub, _) = try await orch.compile(format: .epub, label: nil)
        else { return XCTFail("fixture compile failed") }

        var receivedIDs: [String] = []
        let observer = NotificationCenter.default.addObserver( // adr-0021-ok: headless test observes the post; the scoped receive helpers are View modifiers

            forName: .maughamPublicationCompleted, object: nil, queue: nil
        ) { note in
            if let id = note.object as? String { receivedIDs.append(id) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let r = Republisher(
            projectURL: tmp, astSource: Src(),
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        guard case .completed(let repub, _) = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)
        else { return XCTFail("republish failed") }

        XCTAssertEqual(receivedIDs, [repub.publicationID],
                       "the republish posts the completion event with its own "
                       + "publication id, exactly as the compile path does")
    }

    func test_republishLeavesTheOriginalArtifactBytesUntouched() async throws {
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hello.")]
            }
        }
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Durable", author: "T")))

        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)

        // 1. Initial compile creates the original .epub publication.
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let initial = try await orch.compile(format: .epub, label: nil)
        guard case .completed(let initialPub, _) = initial else {
            XCTFail("initial compile failed: \(initial)")
            return
        }
        let originalURL = tmp.appendingPathComponent(initialPub.outputPath)
        let originalBytes = try Data(contentsOf: originalURL)
        XCTAssertFalse(originalBytes.isEmpty, "fixture sanity: original artifact must be non-empty")

        // 2. Mutate the manuscript (the drift the finding is about) — a
        //    republish still renders from the frozen snapshot, but before
        //    the fix the STAGED FILENAME echoed the original's, so moving
        //    it into Exports/ clobbered the original bytes regardless.
        struct MutatedSrc: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hello, mutated world.")]
            }
        }

        // 3. republish(snapshotID:, format: .epub, label: nil) — nil label
        //    is the collision case (no label to disambiguate the filename).
        let r = Republisher(
            projectURL: tmp, astSource: MutatedSrc(),
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let outcome = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)
        guard case .completed(let republishedPub, _) = outcome else {
            XCTFail("republish failed: \(outcome)")
            return
        }

        // 4. The original outputPath must still exist AND its Data must
        //    equal the recorded bytes — bytes, not just existence.
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path),
            "the original artifact must still exist after a republish")
        let bytesAfter = try Data(contentsOf: originalURL)
        XCTAssertEqual(bytesAfter, originalBytes,
            "a republish must never overwrite the original edition's bytes")

        // 5. The new Publication's outputPath must differ from the original's.
        XCTAssertNotEqual(republishedPub.outputPath, initialPub.outputPath,
            "the republished edition must land at a distinct path from the original")
    }

    // MARK: - P2 (issue #25): republish holds the mint gate too
    //
    // The `-r<suffix>` means a republish can't collide with a sibling
    // edition, so what the reservation guards is the same republish arriving
    // twice, or one racing a compile that resolved to its triple. That
    // version is unpredictable from outside, which is why these two assert on
    // the gate's own state rather than on a refusal: what they falsify is a
    // LEAKED reservation, which would wedge the triple for the life of the
    // app. (The refusal wording and the reserve-before-compile ordering are
    // pinned on the compile path, in `CompileOrchestratorTests`.)

    private struct RepubSrc: ProjectASTBuilder.Source {
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hello.")]
        }
    }

    /// A republish that succeeds hands its reservation back.
    func testP2_republishReleasesItsReservationOnSuccess() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Gate", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)
        let gate = PublishMintGate()

        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: RepubSrc(),
            configStore: configStore,
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(), mintGate: gate,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let initial = try await orch.compile(format: .epub, label: nil)
        guard case .completed(let initialPub, _) = initial else {
            return XCTFail("initial compile failed: \(initial)")
        }

        let r = Republisher(
            projectURL: tmp, astSource: RepubSrc(),
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(), mintGate: gate,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let outcome = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)
        guard case .completed = outcome else {
            return XCTFail("republish failed: \(outcome)")
        }

        let held = await gate._inFlightForTesting
        XCTAssertTrue(held.isEmpty,
                      "a finished republish must hold no reservation, got: \(held)")
    }

    /// A republish whose reserved section throws hands its reservation back
    /// too — a plain file where `Exports/` belongs makes the stage→Exports
    /// move's `createDirectory` throw, well past the reservation point. Since
    /// the RULING-52 fix the throw surfaces as a `.failed` outcome; the
    /// release this test guards is unchanged.
    func testP2_republishReleasesItsReservationWhenItThrows() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "GateThrow", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)
        let gate = PublishMintGate()

        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: RepubSrc(),
            configStore: configStore,
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(), mintGate: gate,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let initial = try await orch.compile(format: .epub, label: nil)
        guard case .completed(let initialPub, _) = initial else {
            return XCTFail("initial compile failed: \(initial)")
        }

        let exports = tmp.appendingPathComponent("Exports")
        try FileManager.default.removeItem(at: exports)
        try "not a directory".write(to: exports, atomically: true, encoding: .utf8)

        let r = Republisher(
            projectURL: tmp, astSource: RepubSrc(),
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(), mintGate: gate,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let blocked = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)
        guard case .failed = blocked else {
            return XCTFail("expected .failed with a file where Exports/ belongs, got \(blocked)")
        }

        let held = await gate._inFlightForTesting
        XCTAssertTrue(held.isEmpty,
                      "a thrown republish must not leak its reservation, got: \(held)")
    }

    /// Repeated republishes each get their own file — no shared clobber path.
    func test_twoRepublishesProduceTwoNewDistinctFiles() async throws {
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hello.")]
            }
        }
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Repeat", author: "T")))

        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)

        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let initial = try await orch.compile(format: .epub, label: nil)
        guard case .completed(let initialPub, _) = initial else {
            XCTFail("initial compile failed: \(initial)")
            return
        }

        let r = Republisher(
            projectURL: tmp, astSource: Src(),
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")

        let first = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)
        guard case .completed(let firstPub, _) = first else {
            XCTFail("first republish failed: \(first)")
            return
        }
        let second = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)
        guard case .completed(let secondPub, _) = second else {
            XCTFail("second republish failed: \(second)")
            return
        }

        let allOutputPaths = [initialPub.outputPath, firstPub.outputPath, secondPub.outputPath]
        XCTAssertEqual(Set(allOutputPaths).count, 3,
            "each compile/republish must produce a distinct catalog outputPath, got \(allOutputPaths)")
        for path in allOutputPaths {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: tmp.appendingPathComponent(path).path),
                "expected a file on disk at \(path)")
        }
    }

    /// The republished filename carries the republish version (the '{version}'
    /// token expands from the EFFECTIVE config), so it says which catalog row
    /// it is — and so it can never equal the original's name.
    func test_republishedFilenameCarriesTheRepublishVersion() async throws {
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hello.")]
            }
        }
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Stamp", author: "T")))

        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)

        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let initial = try await orch.compile(format: .epub, label: nil)
        guard case .completed(let initialPub, _) = initial else {
            XCTFail("initial compile failed: \(initial)")
            return
        }

        let r = Republisher(
            projectURL: tmp, astSource: Src(),
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let outcome = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)
        guard case .completed(let pub, _) = outcome else {
            XCTFail("republish failed: \(outcome)")
            return
        }

        XCTAssertTrue(pub.version.contains("-r"),
            "expected the republish version to carry the '-r' infix, got \(pub.version)")
        let filename = URL(fileURLWithPath: pub.outputPath).lastPathComponent
        XCTAssertTrue(filename.contains(pub.version),
            "expected the republished filename '\(filename)' to contain its own version '\(pub.version)'")
    }

    // MARK: - I1 (whole-branch review): the republish version is unique by
    // construction, and a name already taken on disk is a loud failure
    //
    // The `-r<suffix>` is four hex characters — a 65,536-value pool that every
    // republish of one edition draws from, since the mint always composes off
    // the ORIGINAL row's version. Two draws colliding renders the identical
    // filename, and the punishment used to be a silent `removeItem` of the
    // earlier republish's artifact: the exact loss this branch closes, arriving
    // by the one route the `-r` did not cover.

    private func fakePub(version: String, snapshotID: String = "snap-x") -> Publication {
        Publication(
            publicationID: "pub-\(version)", version: version, label: nil,
            format: .epub, outputPath: "Exports/\(version).epub",
            snapshotID: snapshotID, checkpointID: "", republishedFrom: nil,
            compiledAt: Date(), maughamVersion: "0.0.0-test",
            tectonicVersion: "n/a", language: nil)
    }

    /// The mint re-draws while the composed version is taken, so it can never
    /// hand back a version the catalog already holds. A scripted suffix source
    /// makes the collision certain rather than a one-in-65,536 hope.
    func test_theRepublishVersionMintSkipsVersionsTheCatalogAlreadyHolds() {
        var draws = ["aaaa", "aaaa", "bbbb", "cccc"]
        let minted = Republisher.uniqueRepublishVersion(
            base: "0.1",
            existing: [fakePub(version: "0.1"),
                       fakePub(version: "0.1-raaaa"),
                       fakePub(version: "0.1-rbbbb")],
            mintSuffix: { draws.removeFirst() })
        XCTAssertEqual(minted, "0.1-rcccc",
            "the mint must re-draw past every taken version, not hand one back")
    }

    /// The free case is a single draw — no re-mint when nothing collides.
    func test_theRepublishVersionMintKeepsItsFirstFreeDraw() {
        var draws = ["aaaa", "bbbb"]
        let minted = Republisher.uniqueRepublishVersion(
            base: "0.1", existing: [fakePub(version: "0.1")],
            mintSuffix: { draws.removeFirst() })
        XCTAssertEqual(minted, "0.1-raaaa")
        XCTAssertEqual(draws, ["bbbb"], "a free version must cost exactly one draw")
    }

    /// A snapshot with no prior catalog row still mints against the catalog:
    /// the `republish-<suffix>` shape is drawn from the same small pool.
    func test_theRepublishVersionMintSkipsTakenVersionsWithoutAPriorRow() {
        var draws = ["aaaa", "bbbb"]
        let minted = Republisher.uniqueRepublishVersion(
            base: nil, existing: [fakePub(version: "republish-aaaa")],
            mintSuffix: { draws.removeFirst() })
        XCTAssertEqual(minted, "republish-bbbb")
    }

    /// And the second half: if something IS already at the destination path,
    /// the republish fails loudly and leaves those bytes alone. The old code
    /// deleted them. A pinned suffix makes the destination predictable, so the
    /// test can occupy it.
    func test_republishFailsLoudlyRatherThanDeletingWhatIsAlreadyAtItsDestination() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Occupied", author: "T")))

        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)

        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: RepubSrc(),
            configStore: configStore,
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let initial = try await orch.compile(format: .epub, label: nil)
        guard case .completed(let initialPub, _) = initial else {
            return XCTFail("initial compile failed: \(initial)")
        }

        // Pin the suffix so the republish's filename is knowable, then park a
        // squatter file at exactly that path.
        var r = Republisher(
            projectURL: tmp, astSource: RepubSrc(),
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        r.mintSuffix = { "abcd" }

        let snap = try snapStore.load(id: initialPub.snapshotID)
        var pinned = snap.config
        pinned.nextVersion = "\(initialPub.version)-rabcd"
        let expectedName = OutputFilenameBuilder.make(
            config: pinned, format: .epub, label: nil, language: nil)
        let dest = tmp.appendingPathComponent("Exports").appendingPathComponent(expectedName)
        let squatterBytes = Data("not the republish's to delete".utf8)
        try squatterBytes.write(to: dest)

        let outcome = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)

        guard case .failed(let errors, let log) = outcome else {
            return XCTFail("expected a loud failure when the destination is occupied, got \(outcome)")
        }
        let message = errors.map(\.message).joined(separator: "\n")
        XCTAssertTrue(message.contains(expectedName),
            "the diagnostic must name the occupied path, got: \(message)")
        XCTAssertTrue(log.contains("output_path_occupied"), log)

        XCTAssertEqual(try Data(contentsOf: dest), squatterBytes,
            "a republish must never delete what is already at its destination")
        let pubs = try await pubStore.load()
        XCTAssertEqual(pubs.count, 1,
            "the refused republish must leave no catalog row behind: \(pubs.map(\.version))")
    }

    // MARK: - M4 (spec §3): the republish version is stamped INSIDE the artifact

    /// Spec §3 asks that the `-r` version be asserted at the emission layer,
    /// not just in the filename: a reader holding the file must be able to tell
    /// which catalog row it is. The EPUB path is the honest cheap seam — its
    /// OPF carries `maugham:version` from `config.nextVersion`, and an epub
    /// compiles here without tectonic. (The PDF's `\MaughamVersion` is written
    /// from the same `config.nextVersion`, one `\renewcommand` away, but
    /// reading it back means a real tectonic run.)
    func test_theRepublishedEPUBCarriesItsOwnVersionInsideTheArtifact() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Inside", author: "T")))

        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)

        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: RepubSrc(),
            configStore: configStore,
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let initial = try await orch.compile(format: .epub, label: nil)
        guard case .completed(let initialPub, _) = initial else {
            return XCTFail("initial compile failed: \(initial)")
        }

        let r = Republisher(
            projectURL: tmp, astSource: RepubSrc(),
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let outcome = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)
        guard case .completed(let pub, _) = outcome else {
            return XCTFail("republish failed: \(outcome)")
        }
        XCTAssertTrue(pub.version.contains("-r"), pub.version)

        let opf = try opfXML(inEPUBAt: tmp.appendingPathComponent(pub.outputPath))
        XCTAssertTrue(opf.contains("<meta property=\"maugham:version\">\(pub.version)</meta>"),
            "the artifact must carry its OWN republish version, not the original's — OPF said: " +
            (opf.split(separator: "\n").first { $0.contains("maugham:version") }.map(String.init) ?? "no version meta"))
        XCTAssertFalse(
            opf.contains("<meta property=\"maugham:version\">\(initialPub.version)</meta>"),
            "the republished artifact must not stamp the ORIGINAL edition's version")
    }

    private func opfXML(inEPUBAt url: URL) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-p", url.path, "OEBPS/content.opf"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - P3 (issue #25): republish re-validates the snapshot's config

    /// Sweep finding P3 was refuted by source (`PublishConfigValidator.swift:54-56`
    /// has required `{version}` since `28b6fed9`); what was missing was this pin.
    /// This is the dynamic replay half — `Republisher.republish` re-validates
    /// `snap.config` (the same guard finding 1.5 added for traversal) rather than
    /// trusting a snapshot that could arrive doctored via iCloud sync or a hand
    /// edit. Doctor a saved snapshot's template down to `{title}.{ext}` — no
    /// `{version}` — and republish must refuse with
    /// `RepublishError.invalidSnapshotConfig`. The static half (the validator
    /// call itself) is pinned in `PublishConfigValidatorTests`.
    func test_republishRefusesASnapshotWhoseTemplateLacksVersion() async throws {
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hello.")]
            }
        }
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Doctored", author: "T")))

        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)

        // 1. A normal compile succeeds and leaves a valid snapshot behind.
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let initial = try await orch.compile(format: .epub, label: nil)
        guard case .completed(let initialPub, _) = initial else {
            XCTFail("initial compile failed: \(initial)")
            return
        }

        // 2. Doctor the saved snapshot's config: drop {version} from the
        //    filename template, as if it arrived already invalid.
        let snap = try snapStore.load(id: initialPub.snapshotID)
        var doctoredConfig = snap.config
        doctoredConfig.outputs.filenameTemplate = "{title}.{ext}"
        let doctored = PublicationSnapshot(
            snapshotID: snap.snapshotID, createdAt: snap.createdAt,
            publishFiles: snap.publishFiles, config: doctoredConfig,
            maughamVersion: snap.maughamVersion, tectonicVersion: snap.tectonicVersion)
        try snapStore.save(doctored)

        // 3. Republish must re-validate and refuse — not trust the snapshot.
        let r = Republisher(
            projectURL: tmp, astSource: Src(),
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        do {
            _ = try await r.republish(
                snapshotID: initialPub.snapshotID, format: .epub, label: nil)
            XCTFail("expected republish to refuse a snapshot whose template lacks {version}")
        } catch RepublishError.invalidSnapshotConfig(let msg) {
            XCTAssertTrue(msg.contains("filename_template"), msg)
        }
    }

    // MARK: - Task 5: republish carries the imprint

    /// A republish of an imprint publication must mint an imprint publication:
    /// the same `imprint` on the new catalog row, and the imprint's own
    /// template compiled again — not the book's.
    ///
    /// Seeded by hand rather than through the orchestrator: `CompileOrchestrator`
    /// grows its `imprint:` parameter in Task 6, so this test writes the
    /// prior `Publication(imprint:)` and captures the snapshot itself. The
    /// snapshot's config is built the way production will build it — through
    /// `PublishConfig.resolved(imprint:pieceIDs:)`, the one setter of
    /// `config.imprint` — so nothing here hand-assembles a shape the compile
    /// path would not produce.
    ///
    /// The template half is proved by making the BOOK's `template.tex`
    /// uncompilable before the snapshot is captured. The snapshot freezes both
    /// files, `Republisher` stages both, and the republish can only succeed by
    /// compiling `special.tex` — the imprint's. A republish that reached for
    /// the book's template would fail on `\undefined_command_xyz`.
    func testRepublish_carriesTheImprintAndCompilesItsTemplate() async throws {
        // Reads the real premise: tectonic bundled AND its TeX bundle obtainable.
        try await TectonicProbe.requireReady()

        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hello.")]
            }
        }

        let publish = tmp.appendingPathComponent(".maugham/publish", isDirectory: true)
        // The imprint's own template: a copy of the starter, valid.
        let starter = try String(
            contentsOf: publish.appendingPathComponent("template.tex"), encoding: .utf8)
        try starter.write(to: publish.appendingPathComponent("special.tex"),
                          atomically: true, encoding: .utf8)
        // The book's template, now uncompilable.
        try "\\undefined_command_xyz".write(
            to: publish.appendingPathComponent("template.tex"),
            atomically: true, encoding: .utf8)

        let book = PublishConfig(
            metadata: .init(title: "Imprints", author: "T"),
            imprints: ["aldine": .init(template: "special.tex")])
        let imprintConfig = try book.resolved(imprint: "aldine", pieceIDs: ["p1"])
        XCTAssertEqual(imprintConfig.template, "special.tex")
        XCTAssertEqual(imprintConfig.imprint, "aldine")

        // The prior publication + its snapshot, as a Task 6 compile will leave them.
        let snapStore = PublicationSnapshotStore(projectURL: tmp)
        let snap = try snapStore.capture(
            config: imprintConfig, maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")
        try snapStore.save(snap)
        XCTAssertTrue(snap.publishFiles.contains { $0.relativePath == "special.tex" },
                      "the snapshot must hold the imprint template; it held: "
                      + snap.publishFiles.map(\.relativePath).sorted().joined(separator: ", "))

        let pubStore = PublicationStore(projectURL: tmp)
        try await pubStore.append(Publication(
            publicationID: "pub-aldine", version: "0.1", label: nil, format: .pdf,
            outputPath: "Exports/imprints-v0.1-aldine.pdf", snapshotID: snap.snapshotID,
            checkpointID: "", republishedFrom: nil, compiledAt: Date(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0",
            language: nil, allowStale: false, imprint: "aldine"))

        let r = Republisher(
            projectURL: tmp, astSource: Src(),
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")
        let outcome = try await r.republish(
            snapshotID: snap.snapshotID, format: .pdf, label: nil)

        switch outcome {
        case .completed(let pub, _):
            XCTAssertEqual(pub.imprint, "aldine",
                           "the republished row must carry the prior's imprint")
            XCTAssertEqual(pub.republishedFrom, "0.1")
            // The imprint reached the filename too (Task 4's builder reads
            // `config.imprint`, which the snapshot's resolved config carries).
            XCTAssertTrue(pub.outputPath.contains("aldine"),
                          "the republished output should name its imprint: \(pub.outputPath)")
            // And the artifact is real: it could only have been produced by
            // special.tex, because template.tex in this snapshot does not compile.
            let out = tmp.appendingPathComponent(pub.outputPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.path),
                          "no artifact at \(pub.outputPath)")
            let pdf = PDFDocument(url: out)
            XCTAssertGreaterThan(pdf?.pageCount ?? 0, 0,
                                 "the republished artifact is not a PDF with pages")
        case .failed(let errors, let log):
            XCTFail("republish failed: errors=\(errors.map(\.message)) log=\(log.prefix(600))")
        case .dryRunPassed:
            XCTFail("republish never produces dry_run_passed")
        case .cancelled:
            XCTFail("nothing cancelled this republish")
        }
    }

    // MARK: - C1: an imprint's rendered set is an allowlist, at republish too

    /// A project that grows between the compile and the republish.
    private struct GrowingSrc: ProjectASTBuilder.Source {
        let pieces: [String]
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            pieces.map {
                .init(pieceID: $0, title: $0.uppercased(), mode: .prose,
                      displayText: "Text of \($0).")
            }
        }
    }

    // `pieceIDs(inEPUBAt:)` lived here as a private helper until P2 Task 4
    // moved it to `MaughamTests/Publish/EPUBInspection.swift`, where the
    // bilingual suite can ask the same question of a two-language EPUB. It is
    // an `XCTestCase` extension there, so the call sites below are unchanged.

    /// C1 (whole-branch review). An imprint's `sections` is an ALLOWLIST, and
    /// resolution MATERIALIZES it — the frozen config names only the pieces
    /// that existed when it compiled. A piece added afterwards is in neither
    /// the allowlist nor the materialized `include:false` set, so reproducing
    /// the frozen exclusions as a denylist against the live tree lets it into
    /// an edition that never named it. The republish of an imprint derives its
    /// exclusions the other way round: everything live the allowlist does not
    /// name.
    func test_republishOfAnImprintDoesNotGainAPieceAddedSinceTheCompile() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig(metadata: .init(title: "Grown", author: "T"))
        cfg.imprints = ["aldine": .init(sections: ["p1": .init()])]
        try await configStore.save(cfg)

        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)
        let atCompile = GrowingSrc(pieces: ["p1", "p2"])
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: atCompile,
            configStore: configStore,
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let initial = try await orch.compile(
            format: .epub, label: nil, imprint: "aldine")
        guard case .completed(let initialPub, _) = initial else {
            return XCTFail("the imprint's first compile failed: \(initial)")
        }
        XCTAssertEqual(try pieceIDs(inEPUBAt: tmp.appendingPathComponent(initialPub.outputPath)),
                       ["p1"], "fixture: the compile itself renders only the allowlist")

        // The writer adds a chapter. It is not in the imprint's allowlist.
        let afterwards = GrowingSrc(pieces: ["p1", "p2", "p3"])
        let r = Republisher(
            projectURL: tmp, astSource: afterwards,
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let outcome = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)
        guard case .completed(let pub, _) = outcome else {
            return XCTFail("the imprint republish failed: \(outcome)")
        }
        XCTAssertEqual(pub.imprint, "aldine")
        XCTAssertEqual(
            try pieceIDs(inEPUBAt: tmp.appendingPathComponent(pub.outputPath)), ["p1"],
            "the republished imprint must render exactly what its allowlist names "
            + "— a piece added since the compile was never in this edition")
    }

    /// The CONTROL, and the reason this is not simply "republish renders the
    /// frozen set": the BOOK's `sections` map is a denylist — absent means
    /// included — so a chapter written since the compile joins a republished
    /// book, exactly as it joins a fresh compile. Only the excluded one stays
    /// out.
    func test_republishOfTheBookDoesGainAPieceAddedSinceTheCompile() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig(metadata: .init(title: "Grown", author: "T"))
        cfg.sections["p2"] = .init(include: false)
        try await configStore.save(cfg)

        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: GrowingSrc(pieces: ["p1", "p2"]),
            configStore: configStore,
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let initial = try await orch.compile(format: .epub, label: nil)
        guard case .completed(let initialPub, _) = initial else {
            return XCTFail("the book's first compile failed: \(initial)")
        }

        let r = Republisher(
            projectURL: tmp, astSource: GrowingSrc(pieces: ["p1", "p2", "p3"]),
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let outcome = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)
        guard case .completed(let pub, _) = outcome else {
            return XCTFail("the book republish failed: \(outcome)")
        }
        XCTAssertNil(pub.imprint)
        XCTAssertEqual(
            try pieceIDs(inEPUBAt: tmp.appendingPathComponent(pub.outputPath)), ["p1", "p3"],
            "the book's map is a denylist: the excluded piece stays out and the "
            + "new one comes in")
    }

    /// The third case the derivation has to keep right: an imprint that names
    /// NO `sections` of its own inherits the book's map, which is a denylist —
    /// so it behaves like the book, and a new piece joins it. This is why the
    /// derivation asks the frozen config's own imprint layer rather than
    /// merely whether an imprint is set.
    func test_republishOfAnImprintWithNoAllowlistInheritsTheBooksDenylist() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig(metadata: .init(title: "Grown", author: "T"))
        cfg.sections["p2"] = .init(include: false)
        cfg.imprints = ["plain": .init(metadata: ["title": .string("Grown, Plain")])]
        try await configStore.save(cfg)

        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: GrowingSrc(pieces: ["p1", "p2"]),
            configStore: configStore,
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let initial = try await orch.compile(
            format: .epub, label: nil, imprint: "plain")
        guard case .completed(let initialPub, _) = initial else {
            return XCTFail("the inheriting imprint's compile failed: \(initial)")
        }

        let r = Republisher(
            projectURL: tmp, astSource: GrowingSrc(pieces: ["p1", "p2", "p3"]),
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let outcome = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)
        guard case .completed(let pub, _) = outcome else {
            return XCTFail("the inheriting imprint's republish failed: \(outcome)")
        }
        XCTAssertEqual(pub.imprint, "plain")
        XCTAssertEqual(
            try pieceIDs(inEPUBAt: tmp.appendingPathComponent(pub.outputPath)), ["p1", "p3"],
            "an imprint with no allowlist of its own inherits the book's denylist, "
            + "so the new piece joins it too")
    }

    /// I2 (whole-branch review). A republish mints a triple too, and its
    /// in-flight refusal is the third of the three that used to name only
    /// `(version, language, format)` — ambiguous the moment an imprint holds a
    /// version of its own. A scripted suffix makes the minted version, and so
    /// the gate key, known in advance.
    func test_aRepublishRefusedByTheGateNamesTheImprint() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig(metadata: .init(title: "Held", author: "T"))
        cfg.imprints = ["aldine": .init(metadata: ["title": .string("Held, Aldine")])]
        try await configStore.save(cfg)

        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: GrowingSrc(pieces: ["p1"]),
            configStore: configStore,
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        guard case .completed(let initialPub, _) = try await orch.compile(
            format: .epub, label: nil, imprint: "aldine") else {
            return XCTFail("the imprint's compile must succeed to be republished")
        }

        let gate = PublishMintGate()
        var r = Republisher(
            projectURL: tmp, astSource: GrowingSrc(pieces: ["p1"]),
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(), mintGate: gate,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        r.mintSuffix = { "abcd" }
        let held = await gate.reserve(.init(
            version: "\(initialPub.version)-rabcd", language: nil, format: .epub,
            imprint: "aldine"))
        XCTAssertTrue(held, "fixture: the triple this republish will mint is in flight")

        let outcome = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)
        guard case .failed(let errors, let excerpt) = outcome else {
            return XCTFail("expected an in-flight refusal, got \(outcome)")
        }
        XCTAssertTrue(excerpt.hasPrefix("mint_in_flight:"), excerpt)
        XCTAssertTrue(
            errors.contains { $0.message.contains("under imprint 'aldine'") },
            "the refusal must name the imprint: \(errors.map(\.message))")
        XCTAssertTrue(
            errors.flatMap(\.contextLines).contains { $0.contains("under imprint 'aldine'") },
            "and so must the triple's context line: \(errors.flatMap(\.contextLines))")
    }

    /// Its control: the same refusal for a BOOK republish says "on the book"
    /// rather than naming an imprint that is not there.
    func test_aRepublishOfTheBookRefusedByTheGateNamesTheBook() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Held", author: "T")))

        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: GrowingSrc(pieces: ["p1"]),
            configStore: configStore,
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        guard case .completed(let initialPub, _) = try await orch.compile(
            format: .epub, label: nil) else {
            return XCTFail("the book's compile must succeed to be republished")
        }

        let gate = PublishMintGate()
        var r = Republisher(
            projectURL: tmp, astSource: GrowingSrc(pieces: ["p1"]),
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(), mintGate: gate,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        r.mintSuffix = { "abcd" }
        _ = await gate.reserve(.init(
            version: "\(initialPub.version)-rabcd", language: nil, format: .epub,
            imprint: nil))

        let outcome = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)
        guard case .failed(let errors, _) = outcome else {
            return XCTFail("expected an in-flight refusal, got \(outcome)")
        }
        XCTAssertTrue(
            errors.contains { $0.message.contains("on the book") },
            "the refusal must name the book: \(errors.map(\.message))")
    }

    // MARK: - P2 Task 6: a republish reproduces every body the record names
    //
    // The record is two halves and the republish reads both: the snapshot's
    // own `languages` (written by every compile since P2) says what was
    // rendered, and the prior catalog row's `language` is the identity that
    // names it. An older snapshot has neither key — only the row — and must
    // still reproduce exactly what it reproduced before this branch.

    /// A source that answers with different text per language, so a
    /// republished bilingual document can be read back body by body.
    private struct RebindableRepubSrc: LanguageRebindableSource {
        let tag: String?
        static func text(for tag: String?) -> String {
            tag.map { "Prevedeniparagrafu\($0)." } ?? "Thesourceparagraph."
        }
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            [.init(pieceID: "p1", title: "C", mode: .prose,
                   displayText: Self.text(for: tag))]
        }
        func rebound(toLanguage tag: String?) -> ProjectASTBuilder.Source {
            RebindableRepubSrc(tag: tag)
        }
    }

    private func bilingualConfigStore() async throws -> PublishConfigStore {
        let configStore = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig(metadata: .init(title: "RepubMulti", author: "T"))
        cfg.metadata.language = "en"
        cfg.languageOverrides = ["sr": .init(metadata: ["title": "Prevedeni Naslov"])]
        try await configStore.save(cfg)
        return configStore
    }

    private func repubOrchestrator(
        _ configStore: PublishConfigStore, _ pubStore: PublicationStore,
        _ snapStore: PublicationSnapshotStore
    ) -> CompileOrchestrator {
        CompileOrchestrator(
            projectURL: tmp, astSource: RebindableRepubSrc(tag: nil),
            configStore: configStore,
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
    }

    private func repubRepublisher(
        _ pubStore: PublicationStore, _ snapStore: PublicationSnapshotStore
    ) -> Republisher {
        Republisher(
            projectURL: tmp, astSource: RebindableRepubSrc(tag: nil),
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
    }

    /// A bilingual publication republishes as a bilingual publication: both
    /// bodies in the archive, each reading its own text, and a catalog row
    /// carrying the joined identity rather than one tongue or none.
    func test_republishOfABilingualRecord_reproducesEveryBody() async throws {
        let configStore = try await bilingualConfigStore()
        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)

        guard case .completed(let first, _) = try await repubOrchestrator(
            configStore, pubStore, snapStore)
            .compile(format: .epub, label: nil, languages: ["en", "sr"]) else {
            return XCTFail("fixture: the bilingual compile must complete")
        }
        XCTAssertEqual(first.language, "en+sr", "fixture")

        guard case .completed(let again, _) = try await repubRepublisher(
            pubStore, snapStore)
            .republish(snapshotID: first.snapshotID, format: .epub, label: nil) else {
            return XCTFail("the bilingual republish must complete")
        }
        XCTAssertEqual(again.language, "en+sr",
                       "the republished row carries the joined identity")
        XCTAssertTrue(again.outputPath.contains("en+sr"),
                      "and so does its filename: \(again.outputPath)")

        let epub = tmp.appendingPathComponent(again.outputPath)
        let entries = try epubEntryNames(inEPUBAt: epub)
        XCTAssertTrue(entries.contains("OEBPS/section-en-001.xhtml"), "\(entries)")
        XCTAssertTrue(entries.contains("OEBPS/section-sr-001.xhtml"), "\(entries)")
        XCTAssertEqual(try pieceIDOccurrences(inEPUBAt: epub).count, 2,
                       "one occurrence of the one piece per body")

        let en = try epubEntryText("OEBPS/section-en-001.xhtml", inEPUBAt: epub)
        let sr = try epubEntryText("OEBPS/section-sr-001.xhtml", inEPUBAt: epub)
        XCTAssertTrue(en.contains(RebindableRepubSrc.text(for: nil)),
                      "the source body reads the source text: \(en)")
        XCTAssertTrue(sr.contains(RebindableRepubSrc.text(for: "sr")),
                      "and the sr body its own — not the source text under the "
                      + "translation's name: \(sr)")
        XCTAssertFalse(sr.contains(RebindableRepubSrc.text(for: nil)), sr)
    }

    /// A snapshot minted BEFORE this branch has no `languages` key at all, and
    /// a republish of it must reproduce exactly what it reproduced before —
    /// one body, the prior row's language, the un-tagged section filenames.
    ///
    /// Disable experiment: drop the `prior?.language` fallback (leave only
    /// `snap.languages`) and this fails with `again.language == nil` and an
    /// output filename that has lost its `-sr`.
    func test_republishOfAPreBranchSnapshot_reproducesItsOneBodyFromTheRow() async throws {
        let configStore = try await bilingualConfigStore()
        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)
        // A translated edition renders an EXISTING source version.
        try await pubStore.append(Publication(
            publicationID: "pub-src", version: "0.1", label: nil, format: .pdf,
            outputPath: "Exports/src.pdf", snapshotID: "snap-src", checkpointID: "",
            republishedFrom: nil, compiledAt: Date(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a", language: nil))

        guard case .completed(let first, _) = try await repubOrchestrator(
            configStore, pubStore, snapStore)
            .compile(format: .epub, label: nil, language: "sr") else {
            return XCTFail("fixture: the sr compile must complete")
        }
        XCTAssertEqual(first.language, "sr", "fixture")

        // Age the snapshot: strip the key no pre-P2 snapshot carries.
        let fresh = try snapStore.load(id: first.snapshotID)
        XCTAssertEqual(fresh.languages, ["sr"], "fixture: a fresh compile records its tags")
        try snapStore.save(PublicationSnapshot(
            snapshotID: fresh.snapshotID, createdAt: fresh.createdAt,
            publishFiles: fresh.publishFiles, config: fresh.config,
            maughamVersion: fresh.maughamVersion,
            tectonicVersion: fresh.tectonicVersion,
            languages: nil))
        XCTAssertNil(try snapStore.load(id: first.snapshotID).languages, "fixture")

        guard case .completed(let again, _) = try await repubRepublisher(
            pubStore, snapStore)
            .republish(snapshotID: first.snapshotID, format: .epub, label: nil) else {
            return XCTFail("an old snapshot must still republish")
        }
        XCTAssertEqual(again.language, "sr",
                       "the row is the only record left of what it rendered")
        XCTAssertTrue(again.outputPath.contains("-sr."),
                      "and the filename keeps its suffix: \(again.outputPath)")

        let epub = tmp.appendingPathComponent(again.outputPath)
        let entries = try epubEntryNames(inEPUBAt: epub)
        XCTAssertTrue(entries.contains("OEBPS/section-001.xhtml"),
                      "one body keeps the un-tagged filenames: \(entries)")
        XCTAssertFalse(entries.contains { $0.contains("section-sr-") },
                       "a single body must not be rearranged: \(entries)")
        let body = try epubEntryText("OEBPS/section-001.xhtml", inEPUBAt: epub)
        XCTAssertTrue(body.contains(RebindableRepubSrc.text(for: "sr")),
                      "and it reads the sr text: \(body)")
    }

    /// The other half of that fallback: a pre-branch snapshot whose prior row
    /// carries a JOINED identity must reproduce BOTH bodies. `LanguageSet`
    /// refuses a `+` in a tag — it is an identity, never a tongue — so the
    /// republish splits it back into components itself.
    ///
    /// Disable experiment: hand `prior?.language` to `LanguageSet` unsplit and
    /// this fails on the throw (`invalid language tag 'en+sr'`).
    func test_republishOfAPreBranchSnapshot_splitsAJoinedIdentityBackIntoBodies() async throws {
        let configStore = try await bilingualConfigStore()
        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)

        guard case .completed(let first, _) = try await repubOrchestrator(
            configStore, pubStore, snapStore)
            .compile(format: .epub, label: nil, languages: ["en", "sr"]) else {
            return XCTFail("fixture: the bilingual compile must complete")
        }

        let fresh = try snapStore.load(id: first.snapshotID)
        try snapStore.save(PublicationSnapshot(
            snapshotID: fresh.snapshotID, createdAt: fresh.createdAt,
            publishFiles: fresh.publishFiles, config: fresh.config,
            maughamVersion: fresh.maughamVersion,
            tectonicVersion: fresh.tectonicVersion,
            languages: nil))

        guard case .completed(let again, _) = try await repubRepublisher(
            pubStore, snapStore)
            .republish(snapshotID: first.snapshotID, format: .epub, label: nil) else {
            return XCTFail("a joined identity with no snapshot key must still republish")
        }
        XCTAssertEqual(again.language, "en+sr")
        let entries = try epubEntryNames(
            inEPUBAt: tmp.appendingPathComponent(again.outputPath))
        XCTAssertTrue(entries.contains("OEBPS/section-en-001.xhtml"), "\(entries)")
        XCTAssertTrue(entries.contains("OEBPS/section-sr-001.xhtml"), "\(entries)")
    }

    /// The control for both fallbacks: an ordinary SOURCE republish is
    /// untouched — one body, no identity, no language suffix. Without it the
    /// two tests above could pass on a republish that had started tagging
    /// every edition.
    func test_republishOfASourceRecord_staysUntagged() async throws {
        let configStore = try await bilingualConfigStore()
        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)

        guard case .completed(let first, _) = try await repubOrchestrator(
            configStore, pubStore, snapStore).compile(format: .epub, label: nil) else {
            return XCTFail("fixture: the source compile must complete")
        }
        XCTAssertNil(first.language, "fixture")

        guard case .completed(let again, _) = try await repubRepublisher(
            pubStore, snapStore)
            .republish(snapshotID: first.snapshotID, format: .epub, label: nil) else {
            return XCTFail("the source republish must complete")
        }
        XCTAssertNil(again.language, "a source republish mints no identity")
        XCTAssertFalse(again.outputPath.contains("-en."),
                       "and no language suffix: \(again.outputPath)")
        let entries = try epubEntryNames(
            inEPUBAt: tmp.appendingPathComponent(again.outputPath))
        XCTAssertTrue(entries.contains("OEBPS/section-001.xhtml"), "\(entries)")
        let body = try epubEntryText("OEBPS/section-001.xhtml", inEPUBAt: epub(again))
        XCTAssertTrue(body.contains(RebindableRepubSrc.text(for: nil)),
                      "the source body reads the source text: \(body)")
    }

    /// A snapshot with no frozen `config.json` cannot say which of its language
    /// tags is the book's own — `snap.config` is the first body's
    /// language-FOLDED one and answers wrongly for every translated edition —
    /// so a republish refuses rather than guessing. Loudly, naming the file, in
    /// the same throwing shape the snapshot load and the config validation use.
    ///
    /// Disable experiment: restore the silent
    /// `?? snap.config.metadata.language` fallback and this fails on no throw.
    func test_republishRefusesASnapshotMissingItsFrozenConfig() async throws {
        let configStore = try await bilingualConfigStore()
        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)

        guard case .completed(let first, _) = try await repubOrchestrator(
            configStore, pubStore, snapStore)
            .compile(format: .epub, label: nil, languages: ["en", "sr"]) else {
            return XCTFail("fixture: the bilingual compile must complete")
        }

        let fresh = try snapStore.load(id: first.snapshotID)
        XCTAssertTrue(fresh.publishFiles.contains { $0.relativePath == "config.json" },
                      "fixture: a captured snapshot carries the unfolded config")
        try snapStore.save(PublicationSnapshot(
            snapshotID: fresh.snapshotID, createdAt: fresh.createdAt,
            publishFiles: fresh.publishFiles.filter { $0.relativePath != "config.json" },
            config: fresh.config,
            maughamVersion: fresh.maughamVersion,
            tectonicVersion: fresh.tectonicVersion,
            languages: fresh.languages))

        do {
            _ = try await repubRepublisher(pubStore, snapStore)
                .republish(snapshotID: first.snapshotID, format: .epub, label: nil)
            XCTFail("a snapshot with no config.json must refuse, not guess")
        } catch let error as RepublishError {
            let sentence = error.errorDescription ?? ""
            XCTAssertTrue(sentence.contains("config.json"),
                          "the refusal must name the file: \(sentence)")
        }
    }

    /// Its control: the same snapshot, untouched, republishes. Without it the
    /// refusal above could pass on a republish that had started refusing
    /// everything.
    func test_republishOfASnapshotWithItsFrozenConfig_stillRepublishes() async throws {
        let configStore = try await bilingualConfigStore()
        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)

        guard case .completed(let first, _) = try await repubOrchestrator(
            configStore, pubStore, snapStore)
            .compile(format: .epub, label: nil, languages: ["en", "sr"]) else {
            return XCTFail("fixture: the bilingual compile must complete")
        }
        guard case .completed(let again, _) = try await repubRepublisher(
            pubStore, snapStore)
            .republish(snapshotID: first.snapshotID, format: .epub, label: nil) else {
            return XCTFail("an intact snapshot must republish")
        }
        XCTAssertEqual(again.language, "en+sr")
    }

    private func epub(_ pub: Publication) -> URL {
        tmp.appendingPathComponent(pub.outputPath)
    }

    // MARK: - C1: every body folds from the UNFOLDED config

    /// A bilingual config whose SECOND body is the source one, plus a
    /// per-piece style file that has a language-suffixed variant on disk —
    /// the two things a language fold rewrites (metadata, `style_file`).
    private func styledBilingualConfigStore() async throws -> PublishConfigStore {
        let configStore = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig(metadata: .init(title: "RepubMulti", author: "T"))
        cfg.metadata.language = "en"
        cfg.languageOverrides = ["sr": .init(metadata: ["title": "Prevedeni Naslov"])]
        cfg.sections = ["p1": .init(styleFile: "tribute.tex")]
        try await configStore.save(cfg)

        let pieces = tmp.appendingPathComponent(".maugham/publish/pieces",
                                                isDirectory: true)
        try FileManager.default.createDirectory(
            at: pieces, withIntermediateDirectories: true)
        try "% base\n".write(to: pieces.appendingPathComponent("tribute.tex"),
                             atomically: true, encoding: .utf8)
        try "% serbian\n".write(to: pieces.appendingPathComponent("tribute.sr.tex"),
                                atomically: true, encoding: .utf8)
        return configStore
    }

    /// The plan a republish of `snapshotID` folds — driven through the
    /// production seam (`Republisher.foldingBase`) over the REAL staged
    /// snapshot, from the real extracted `config.json` and the real stage
    /// publish dir. `version` is threaded so a caller can ask for byte
    /// identity against the original compile.
    private func republishPlan(
        snapshotID: String, snapStore: PublicationSnapshotStore, version: String
    ) async throws -> BodyPlan {
        let snap = try snapStore.load(id: snapshotID)
        let stage = tmp.appendingPathComponent("Stage-\(UUID().uuidString)")
        let stagePublish = stage.appendingPathComponent(".maugham/publish",
                                                        isDirectory: true)
        try PublicationSnapshotStore.extract(snap, into: stagePublish)
        guard let staged = try await PublishConfigStore(projectURL: stage).load()
        else { throw XCTSkip("fixture: the snapshot must carry its config.json") }
        let set = try LanguageSet(
            language: nil, languages: snap.languages,
            sourceTag: staged.metadata.language)
        let base = try Republisher.foldingBase(
            stagedConfig: staged, snapshotConfig: snap.config,
            set: set, liveSource: RebindableRepubSrc(tag: nil),
            version: version)
        return try BodyPlan.make(
            set: set, resolved: base, source: RebindableRepubSrc(tag: nil),
            publishDir: stagePublish, wrap: { $0 })
    }

    /// The plan the COMPILE DOOR built for that compile: the live config,
    /// unfolded, with the compiled version threaded through `nextVersion`
    /// (`CompileOrchestrator.compile`'s `versioned`).
    private func doorPlan(
        configStore: PublishConfigStore, languages: [String], version: String
    ) async throws -> BodyPlan {
        guard var versioned = try await configStore.load() else {
            throw XCTSkip("fixture: the project must have a config")
        }
        versioned.nextVersion = version
        let set = try LanguageSet(
            language: nil, languages: languages,
            sourceTag: versioned.metadata.language)
        return try BodyPlan.make(
            set: set, resolved: versioned, source: RebindableRepubSrc(tag: nil),
            publishDir: tmp.appendingPathComponent(".maugham/publish",
                                                   isDirectory: true),
            wrap: { $0 })
    }

    /// C1 (whole-branch review). Every body of a republish is folded from the
    /// UNFOLDED config, exactly as the compile door folds it — so
    /// `build/metadata.<tag>.tex` is byte-identical between the two, for every
    /// body, at the same version.
    ///
    /// The order matters and is the whole finding: with `["sr","en"]` the
    /// snapshot's `config` is the SERBIAN body's fold, and the English body
    /// (`tag == nil`, whose own fold is a no-op) inherits it wholesale.
    ///
    /// Disable experiment: pass `resolved: snap.config`-with-a-new-version
    /// (the shipped `effective`) instead of `base` — the `en` body's metadata
    /// block comes out titled "Prevedeni Naslov" with
    /// `\MaughamLanguage{sr}`, and its style file resolves to
    /// `tribute.sr.tex`.
    func test_aRepublishFoldsEveryBodyFromTheUnfoldedConfig() async throws {
        let configStore = try await styledBilingualConfigStore()
        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)

        guard case .completed(let first, _) = try await repubOrchestrator(
            configStore, pubStore, snapStore)
            .compile(format: .epub, label: nil, languages: ["sr", "en"]) else {
            return XCTFail("fixture: the bilingual compile must complete")
        }
        XCTAssertEqual(first.language, "sr+en", "fixture: the translated body leads")

        let original = try await doorPlan(
            configStore: configStore, languages: ["sr", "en"],
            version: first.version)
        let replay = try await republishPlan(
            snapshotID: first.snapshotID, snapStore: snapStore,
            version: first.version)

        XCTAssertEqual(replay.bodies.count, 2, "one body per recorded language")
        for (i, body) in replay.bodies.enumerated() {
            XCTAssertEqual(
                PDFCompiler.metadataBlock(config: body.config, label: nil),
                PDFCompiler.metadataBlock(config: original.bodies[i].config,
                                          label: nil),
                "body \(i) (\(body.displayTag)): build/metadata.\(body.displayTag).tex "
                + "must be byte-identical to the original compile's")
            XCTAssertEqual(
                body.config.sections["p1"]?.styleFile,
                original.bodies[i].config.sections["p1"]?.styleFile,
                "body \(i) (\(body.displayTag)): and so must its style file")
        }

        // The absolute values, so the two computations agreeing is not the
        // whole of the assertion.
        let sr = PDFCompiler.metadataBlock(config: replay.bodies[0].config, label: nil)
        let en = PDFCompiler.metadataBlock(config: replay.bodies[1].config, label: nil)
        XCTAssertTrue(sr.contains("{Prevedeni Naslov}"), sr)
        XCTAssertTrue(sr.contains("\\renewcommand{\\MaughamLanguage}{sr}"), sr)
        XCTAssertTrue(en.contains("{RepubMulti}"),
                      "the English half keeps the book's own title: \(en)")
        XCTAssertTrue(en.contains("\\renewcommand{\\MaughamLanguage}{en}"),
                      "and its own language: \(en)")
        XCTAssertEqual(replay.bodies[0].config.sections["p1"]?.styleFile,
                       "tribute.sr.tex")
        XCTAssertEqual(replay.bodies[1].config.sections["p1"]?.styleFile,
                       "tribute.tex",
                       "the English half inputs the base style file, not the "
                       + "Serbian variant")

        // And the production path still republishes the record whole.
        guard case .completed(let again, _) = try await repubRepublisher(
            pubStore, snapStore)
            .republish(snapshotID: first.snapshotID, format: .epub, label: nil)
        else { return XCTFail("the bilingual republish must complete") }
        XCTAssertEqual(again.language, "sr+en")
    }

    /// Control: the order that always worked must go on working. With
    /// `["en","sr"]` the snapshot's config IS the unfolded one (the source
    /// body's fold is the identity), so this passed before the fix and must
    /// pass after it — the fix cannot be a re-ordering that merely moves the
    /// defect to the other arrangement.
    func test_aRepublishFoldsEveryBodyFromTheUnfoldedConfig_sourceBodyFirst() async throws {
        let configStore = try await styledBilingualConfigStore()
        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)

        guard case .completed(let first, _) = try await repubOrchestrator(
            configStore, pubStore, snapStore)
            .compile(format: .epub, label: nil, languages: ["en", "sr"]) else {
            return XCTFail("fixture: the bilingual compile must complete")
        }
        XCTAssertEqual(first.language, "en+sr", "fixture")

        let original = try await doorPlan(
            configStore: configStore, languages: ["en", "sr"],
            version: first.version)
        let replay = try await republishPlan(
            snapshotID: first.snapshotID, snapStore: snapStore,
            version: first.version)

        for (i, body) in replay.bodies.enumerated() {
            XCTAssertEqual(
                PDFCompiler.metadataBlock(config: body.config, label: nil),
                PDFCompiler.metadataBlock(config: original.bodies[i].config,
                                          label: nil),
                "body \(i) (\(body.displayTag))")
            XCTAssertEqual(
                body.config.sections["p1"]?.styleFile,
                original.bodies[i].config.sections["p1"]?.styleFile,
                "body \(i) (\(body.displayTag)) style file")
        }
        let en = PDFCompiler.metadataBlock(config: replay.bodies[0].config, label: nil)
        let sr = PDFCompiler.metadataBlock(config: replay.bodies[1].config, label: nil)
        XCTAssertTrue(en.contains("{RepubMulti}"), en)
        XCTAssertTrue(sr.contains("{Prevedeni Naslov}"), sr)
    }

    /// The minted republish version reaches every body — `\MaughamVersion` in
    /// each `build/metadata.<tag>.tex`, and the filename, agree with the
    /// catalog row (P1, issue #25). The one thing that is DELIBERATELY not
    /// byte-identical to the original compile.
    func test_theFoldingBaseCarriesTheMintedRepublishVersion() async throws {
        let configStore = try await styledBilingualConfigStore()
        guard let staged = try await configStore.load() else {
            return XCTFail("fixture")
        }
        let base = try Republisher.foldingBase(
            stagedConfig: staged, snapshotConfig: staged,
            set: try LanguageSet(language: nil, languages: nil, sourceTag: "en"),
            liveSource: RebindableRepubSrc(tag: nil), version: "0.1-rab12")
        XCTAssertEqual(base.nextVersion, "0.1-rab12")
        XCTAssertTrue(
            PDFCompiler.metadataBlock(config: base, label: nil)
                .contains("\\renewcommand{\\MaughamVersion}{0.1-rab12}"))
    }

    /// The staged config cannot always describe the snapshot's imprint — a
    /// hand-assembled snapshot (and `testRepublish_carriesTheImprintAndCompiles
    /// Template`'s own fixture) captures a resolved config whose `config.json`
    /// on disk never defined that imprint.
    ///
    /// ONE body: the frozen config IS a correct base — its fold is the
    /// identity for the source body and idempotent for a single translated
    /// one — so `foldingBase` falls back to it rather than refusing a shape
    /// that republished perfectly well before this fix.
    func test_theFoldingBaseFallsBackToTheFrozenConfigForOneBody() throws {
        var frozen = PublishConfig(metadata: .init(title: "Imprints", author: "T"))
        frozen.imprint = "aldine"
        frozen.template = "special.tex"
        let staged = PublishConfig(metadata: .init(title: "Imprints", author: "T"))
        XCTAssertTrue(staged.imprints.isEmpty, "fixture: the staged config knows no imprints")

        let base = try Republisher.foldingBase(
            stagedConfig: staged, snapshotConfig: frozen,
            set: try LanguageSet(language: nil, languages: nil, sourceTag: "en"),
            liveSource: RebindableRepubSrc(tag: nil), version: "0.1-rzz99")
        XCTAssertEqual(base.template, "special.tex",
                       "the fallback keeps the imprint's own template")
        XCTAssertEqual(base.imprint, "aldine")
        XCTAssertEqual(base.nextVersion, "0.1-rzz99",
                       "and still carries the minted version")
    }

    /// TWO bodies: there is no correct base to fall back TO — the frozen
    /// config is the first body's fold, which is precisely the wrong answer
    /// for the second. Refuse in the same words an unreadable `config.json`
    /// is refused in, naming the file.
    func test_theFoldingBaseRefusesAMultiBodyRecordItCannotUnfold() throws {
        var frozen = PublishConfig(metadata: .init(title: "Imprints", author: "T"))
        frozen.imprint = "aldine"
        let staged = PublishConfig(metadata: .init(title: "Imprints", author: "T"))

        XCTAssertThrowsError(try Republisher.foldingBase(
            stagedConfig: staged, snapshotConfig: frozen,
            set: try LanguageSet(language: nil, languages: ["sr", "en"],
                                 sourceTag: "en"),
            liveSource: RebindableRepubSrc(tag: nil), version: "0.1-rzz99")
        ) { error in
            guard case RepublishError.unreadableSnapshotConfig(let msg) = error else {
                return XCTFail("expected unreadableSnapshotConfig, got \(error)")
            }
            XCTAssertTrue(msg.contains("config.json"),
                          "the refusal must name the file: \(msg)")
            XCTAssertTrue(msg.contains("2-language"),
                          "and say what it could not unfold: \(msg)")
        }
    }
}
