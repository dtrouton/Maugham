import XCTest
import MaughamCore
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
        let testBundlePath = Bundle(for: RepublisherTests.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        guard let _ = try? TectonicLocator.locateInBundle(
            at: URL(fileURLWithPath: appPath)) else {
            throw XCTSkip("tectonic missing")
        }

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
        }
    }

    /// Finding 1: `Republisher` used to build its compilers and the new
    /// `Publication` with a default `language: nil`, so a republished
    /// Spanish edition's catalog record reported untagged and its filename
    /// lacked the `-es` suffix — even though the snapshotted config (and
    /// thus the compiled content) was already Spanish. Republisher must
    /// carry the prior publication's `language` forward.
    func testRepublish_carriesEditionLanguageAndFilenameSuffix() async throws {
        let testBundlePath = Bundle(for: RepublisherTests.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        guard let _ = try? TectonicLocator.locateInBundle(
            at: URL(fileURLWithPath: appPath)) else {
            throw XCTSkip("tectonic missing")
        }

        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hola.")]
            }
        }
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "RepubLang", author: "T")))

        // 1. Initial Spanish-edition compile creates v0.1 + a snapshot whose
        //    Publication.language is "es".
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: PublicationStore(projectURL: tmp),
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

        return GatedRepubFixture(
            projectURL: projectURL, item: item, doc: doc, store: store,
            configStore: configStore,
            publicationStore: PublicationStore(projectURL: projectURL),
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
                projectStore: fx.store, language: "es", allowStale: false),
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
                projectStore: freshStore, language: "es", allowStale: false),
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
                projectStore: fx.store, language: "es", allowStale: false),
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
                projectStore: fx.store, language: "es", allowStale: false),
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
                projectStore: fx.store, language: "es", allowStale: true),
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
                projectStore: fx.store, language: "es", allowStale: true),
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
        // Action block: ALL-CAPS character cue + dialogue — the drift.
        try await fresh(ids[0], doc.paragraphs[ids[0]] ?? "")
        try await fresh(ids[1], "EL CAPITÁN\nPreparen a los hombres.")

        return FountainRepubFixture(
            projectURL: projectURL, item: item, doc: doc, store: store,
            configStore: configStore,
            publicationStore: PublicationStore(projectURL: projectURL),
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
                projectStore: fx.store, language: "es", allowStale: false),
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
                projectStore: fx.store, language: "es", allowStale: false),
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
}
