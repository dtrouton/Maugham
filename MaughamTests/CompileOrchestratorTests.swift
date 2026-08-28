import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class CompileOrchestratorTests: XCTestCase {

    var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try await PublishStarter.install(into: tmp, force: false)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testCompile_pdf_writesPublicationAndSnapshot_andBumpsVersion() async throws {
        // Reads the real premise: tectonic bundled AND its TeX bundle obtainable.
        try await TectonicProbe.requireReady()

        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hi.")]
            }
        }
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(
            metadata: .init(title: "Orch", author: "T")))

        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: PublicationStore(projectURL: tmp),
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test",
            tectonicVersion: "0.15.0")

        let result = try await orch.compile(format: .pdf, label: nil)
        switch result {
        case .completed(let pub, _):
            XCTAssertEqual(pub.version, "0.1")
            XCTAssertEqual(pub.format, .pdf)
        default:
            XCTFail("expected completed, got \(result)")
        }

        // Verify next compile bumps to 0.2.
        let r2 = try await orch.compile(format: .pdf, label: nil)
        if case .completed(let pub, _) = r2 {
            XCTAssertEqual(pub.version, "0.2")
        } else {
            XCTFail("expected completed")
        }

        // Verify publications.jsonl exists with 2 entries.
        let pubs = try await PublicationStore(projectURL: tmp).load()
        XCTAssertEqual(pubs.count, 2)
    }

    // MARK: - D3c: pre-compile version-collision guard

    func testCompile_refusesWhenNextVersionCollidesWithExistingPublication() async throws {
        // Seed a publication at version 0.1 directly, then manually set
        // config.next_version back to "0.1" (simulates a writer rolling
        // the counter back via set_publish_config). The next compile must
        // refuse with a structured version_collision diagnostic.
        let configStore = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig(metadata: .init(title: "Collide", author: "T"))
        cfg.nextVersion = "0.1"
        try await configStore.save(cfg)

        let pubStore = PublicationStore(projectURL: tmp)
        try await pubStore.append(Publication(
            publicationID: "pub-pre-existing",
            version: "0.1", label: nil, format: .pdf,
            outputPath: "Exports/pre.pdf",
            snapshotID: "snap-x", checkpointID: "",
            republishedFrom: nil,
            compiledAt: Date(),
            maughamVersion: "0.0.0-test",
            tectonicVersion: "0.15.0"))

        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "x")]
            }
        }
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: pubStore,
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test",
            tectonicVersion: "0.15.0")

        let result = try await orch.compile(format: .pdf, label: nil)
        switch result {
        case .failed(let errs, let log):
            XCTAssertFalse(errs.isEmpty, "expected structured error in errors[]")
            XCTAssertTrue(errs.contains { $0.message.contains("0.1") && $0.message.lowercased().contains("already exists") })
            // I2: with per-imprint counters the book's 0.1 and an imprint's
            // 0.1 coexist, so the refusal has to say WHOSE 0.1 this is.
            XCTAssertTrue(errs.contains { $0.message.contains("on the book") },
                          "the refusal must name the book: \(errs.map(\.message))")
            XCTAssertTrue(log.contains("version_collision"))
        case .completed, .dryRunPassed, .cancelled:
            XCTFail("expected .failed due to version collision; got \(result)")
        }

        // Verify no new Publication was minted.
        let pubs = try await pubStore.load()
        XCTAssertEqual(pubs.count, 1,
                       "collision guard must not append a colliding Publication")
        XCTAssertEqual(pubs.first?.publicationID, "pub-pre-existing")
    }

    // MARK: - F1: per-section include flag drops excluded pieces from output

    /// Three pieces, the middle one excluded. The EPUB compile path writes
    /// `build/body.xhtml` without tectonic, so the emitted body is directly
    /// inspectable: the excluded piece must be absent, the other two present.
    /// (The PDF/LaTeX format is covered by the ToC compile probe.)
    func testCompile_epub_excludedSectionOmittedFromBody() async throws {
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "Alpha", mode: .prose, displayText: "First piece."),
                 .init(pieceID: "p2", title: "Bravo", mode: .prose, displayText: "Middle piece."),
                 .init(pieceID: "p3", title: "Charlie", mode: .prose, displayText: "Third piece.")]
            }
        }
        let configStore = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig(metadata: .init(title: "Subset", author: "T"))
        cfg.sections["p2"] = .init(include: false)
        try await configStore.save(cfg)

        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: PublicationStore(projectURL: tmp),
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test",
            tectonicVersion: "n/a")

        let result = try await orch.compile(format: .epub, label: nil)
        guard case .completed = result else {
            return XCTFail("expected completed, got \(result)")
        }

        let body = try String(
            contentsOf: tmp.appendingPathComponent(".maugham/publish/build/body.xhtml"),
            encoding: .utf8)
        XCTAssertTrue(body.contains("data-piece-id=\"p1\""), "included Alpha missing")
        XCTAssertTrue(body.contains("data-piece-id=\"p3\""), "included Charlie missing")
        XCTAssertFalse(body.contains("data-piece-id=\"p2\""), "excluded Bravo present")
        XCTAssertFalse(body.contains("Middle piece."), "excluded body text present")
    }

    /// The wrapper the orchestrator uses is the emit contract for BOTH formats —
    /// building the AST from it and emitting each body confirms the excluded
    /// piece is gone from LaTeX and XHTML alike, cheaply and without tectonic.
    func testIncludeFilteredASTSource_dropsExcluded_bothFormats() throws {
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "Keep One", mode: .prose, displayText: "Keep."),
                 .init(pieceID: "p2", title: "Drop Two", mode: .prose, displayText: "Drop."),
                 .init(pieceID: "p3", title: "Keep Three", mode: .prose, displayText: "Keep.")]
            }
        }
        let filtered = IncludeFilteredASTSource(base: Src(), excludedSectionIDs: ["p2"])
        XCTAssertEqual(try filtered.orderedPieces().map(\.pieceID), ["p1", "p3"])

        let ast = try ProjectASTBuilder.build(from: filtered)
        let latex = LaTeXBodyEmitter.emit(ast)
        let xhtml = XHTMLBodyEmitter.emit(ast)
        for body in [latex, xhtml] {
            XCTAssertTrue(body.contains("Keep One"))
            XCTAssertTrue(body.contains("Keep Three"))
            XCTAssertFalse(body.contains("Drop Two"))
        }
    }

    func testIncludeFilteredASTSource_emptyExcludedSet_isPassThrough() throws {
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "A", mode: .prose, displayText: "x"),
                 .init(pieceID: "p2", title: "B", mode: .prose, displayText: "y")]
            }
        }
        let filtered = IncludeFilteredASTSource(base: Src(), excludedSectionIDs: [])
        XCTAssertEqual(try filtered.orderedPieces().map(\.pieceID), ["p1", "p2"])
    }

    // MARK: - F2: dry_run runs the gates but mutates nothing

    struct OneSrc: ProjectASTBuilder.Source {
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hi.")]
        }
    }

    /// dry_run returns `.dryRunPassed` and leaves publications list, config
    /// `nextVersion`, and the Exports output directory untouched. (No tectonic
    /// needed — dry_run short-circuits before any compile.)
    func testDryRun_pdf_noPublicationNoVersionBumpNoOutput() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(
            metadata: .init(title: "Dry", author: "T")))

        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: OneSrc(),
            configStore: configStore,
            publicationStore: PublicationStore(projectURL: tmp),
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test",
            tectonicVersion: "0.15.0")

        let result = try await orch.compile(format: .pdf, label: nil, dryRun: true)
        guard case .dryRunPassed(let warnings) = result else {
            return XCTFail("expected .dryRunPassed, got \(result)")
        }
        XCTAssertTrue(warnings.isEmpty, "source-language dry_run has no gate warnings")

        // No Publication minted.
        let pubs = try await PublicationStore(projectURL: tmp).load()
        XCTAssertTrue(pubs.isEmpty, "dry_run must not mint a Publication")
        // Version not bumped.
        let cfg = try await configStore.load()
        XCTAssertEqual(cfg?.nextVersion, "0.1", "dry_run must not bump next_version")
        // No Exports output directory created.
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tmp.appendingPathComponent("Exports").path),
            "dry_run must not write any output")
    }

    /// dry_run surfaces the version-collision it would hit (the guard runs
    /// before the dry_run short-circuit) but still mutates nothing.
    func testDryRun_reportsVersionCollisionWithoutMinting() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig(metadata: .init(title: "Collide", author: "T"))
        cfg.nextVersion = "0.1"
        try await configStore.save(cfg)

        let pubStore = PublicationStore(projectURL: tmp)
        try await pubStore.append(Publication(
            publicationID: "pub-pre-existing",
            version: "0.1", label: nil, format: .pdf,
            outputPath: "Exports/pre.pdf",
            snapshotID: "snap-x", checkpointID: "",
            republishedFrom: nil,
            compiledAt: Date(),
            maughamVersion: "0.0.0-test",
            tectonicVersion: "0.15.0"))

        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: OneSrc(),
            configStore: configStore,
            publicationStore: pubStore,
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test",
            tectonicVersion: "0.15.0")

        let result = try await orch.compile(format: .pdf, label: nil, dryRun: true)
        guard case .failed(let errs, let log) = result else {
            return XCTFail("expected .failed from collision guard, got \(result)")
        }
        XCTAssertTrue(errs.contains { $0.message.lowercased().contains("already exists") })
        XCTAssertTrue(log.contains("version_collision"))

        // Still exactly the seeded Publication.
        let pubs = try await pubStore.load()
        XCTAssertEqual(pubs.count, 1)
        XCTAssertEqual(pubs.first?.publicationID, "pub-pre-existing")
    }

    // MARK: - F5: EMISSION.md auto-refresh

    /// User-owned starter files a compile's EMISSION.md refresh must never
    /// touch, keyed by their `.maugham/publish/` filename (mirrors
    /// `PublishStarter.files` minus EMISSION.md, which IS meant to change).
    /// `config.json` is deliberately excluded here — a REAL (non-dry-run)
    /// compile legitimately bumps `next_version` in it, orthogonal to F5;
    /// `testCompile_dryRun_stillRefreshesEmissionDoc` below covers
    /// `config.json` staying byte-identical under dry_run, where nothing
    /// else mutates it.
    private let userOwnedStarterFiles = [
        "template.tex", "preamble.tex", "frontmatter.tex", "prose.tex",
        "screenplay.tex", "backmatter.tex", "styles.css",
    ]

    /// A compile against a publish dir seeded with a stale EMISSION.md
    /// leaves it byte-equal to `renderProjectCopy` for the CURRENT contract
    /// (not the stale one), stamped with the app version the orchestrator
    /// was constructed with — and every user-owned starter file is
    /// byte-identical before and after. No tectonic needed: the EPUB path
    /// writes `build/body.xhtml` directly.
    func testCompile_refreshesStaleEmissionDoc_leavesUserFilesUntouched() async throws {
        let publishDir = tmp.appendingPathComponent(".maugham/publish", isDirectory: true)
        let emissionURL = publishDir.appendingPathComponent("EMISSION.md")
        let stale = "# STALE EMISSION.md from a v0.23-era init\n\nOutdated contract text.\n"
        try stale.write(to: emissionURL, atomically: true, encoding: .utf8)

        var before: [String: Data] = [:]
        for name in userOwnedStarterFiles {
            before[name] = try Data(contentsOf: publishDir.appendingPathComponent(name))
        }

        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "F5", mode: .prose, displayText: "Body text.")]
            }
        }
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "F5", author: "T")))

        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: PublicationStore(projectURL: tmp),
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(),
            maughamVersion: "9.9.9-f5test",
            tectonicVersion: "n/a")

        let result = try await orch.compile(format: .epub, label: nil)
        guard case .completed = result else {
            return XCTFail("expected completed, got \(result)")
        }

        let refreshed = try String(contentsOf: emissionURL, encoding: .utf8)
        XCTAssertEqual(refreshed, EmissionContract.renderProjectCopy(appVersion: "9.9.9-f5test"),
                       "EMISSION.md must be refreshed to exactly the current contract")
        XCTAssertTrue(refreshed.contains("9.9.9-f5test"),
                      "refreshed EMISSION.md must carry the app-version stamp")
        XCTAssertFalse(refreshed.contains("STALE EMISSION.md"),
                       "stale content must be fully replaced, not appended to")

        for name in userOwnedStarterFiles {
            let after = try Data(contentsOf: publishDir.appendingPathComponent(name))
            XCTAssertEqual(after, before[name], "\(name) must be byte-identical before/after compile")
        }
    }

    /// dry_run still refreshes the doc (Task 6's chosen behavior: dry_run
    /// runs the pipeline's front half, and there's no reason to let the
    /// project's contract doc drift just because nothing was emitted). Also
    /// covers `config.json` staying byte-identical (dry_run mutates nothing
    /// else, so this pins the "config.json untouched" half of the F5
    /// contract that the real-compile test above can't, since a real
    /// compile legitimately bumps `next_version`).
    func testCompile_dryRun_stillRefreshesEmissionDoc() async throws {
        let publishDir = tmp.appendingPathComponent(".maugham/publish", isDirectory: true)
        let emissionURL = publishDir.appendingPathComponent("EMISSION.md")
        try "stale".write(to: emissionURL, atomically: true, encoding: .utf8)

        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "F5dry", author: "T")))
        let configBefore = try Data(contentsOf: publishDir.appendingPathComponent("config.json"))

        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: OneSrc(),
            configStore: configStore,
            publicationStore: PublicationStore(projectURL: tmp),
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(),
            maughamVersion: "9.9.9-f5dry",
            tectonicVersion: "n/a")

        let result = try await orch.compile(format: .pdf, label: nil, dryRun: true)
        guard case .dryRunPassed = result else {
            return XCTFail("expected .dryRunPassed, got \(result)")
        }

        let refreshed = try String(contentsOf: emissionURL, encoding: .utf8)
        XCTAssertEqual(refreshed, EmissionContract.renderProjectCopy(appVersion: "9.9.9-f5dry"))

        let configAfter = try Data(contentsOf: publishDir.appendingPathComponent("config.json"))
        XCTAssertEqual(configAfter, configBefore,
                       "dry_run must not touch config.json even though EMISSION.md refreshes")
    }

    // MARK: - Edition identity: (version, language, format) (spec 2026-07-23)
    //
    // A Publication is keyed on the triple. A language edition renders an
    // EXISTING source version rather than minting its own; source-only compiles
    // bump next_version. These are the orchestrator-level pins for the behavior
    // change from v0.25.0 (where a language compile minted from next_version and
    // bumped it). All use the plain `OneSrc` source, so the translation coverage
    // gate — which only runs against a `ProjectStoreASTSource` — is skipped and
    // the version-resolution logic is exercised in isolation.

    /// Seed a source-language Publication (language == nil) directly, so a
    /// language edition has an existing source version to render.
    private func seedSourcePublication(
        _ store: PublicationStore,
        version: String = "0.1",
        format: PublishConfig.Format = .pdf,
        compiledAt: Date = Date(),
        imprint: String? = nil
    ) async throws {
        try await store.append(Publication(
            publicationID: "pub-src-\(imprint ?? "book")-\(version)-\(format.rawValue)",
            version: version, label: nil, format: format,
            outputPath: "Exports/src-\(version).\(format.rawValue)",
            snapshotID: "snap-src", checkpointID: "",
            republishedFrom: nil, compiledAt: compiledAt,
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0",
            language: nil, imprint: imprint))
    }

    private func makeOrch(
        _ configStore: PublishConfigStore, _ pubStore: PublicationStore,
        _ mintGate: PublishMintGate = PublishMintGate(),
        jobManager: CompileJobManager = CompileJobManager()
    ) -> CompileOrchestrator {
        CompileOrchestrator(
            projectURL: tmp, astSource: OneSrc(),
            configStore: configStore,
            publicationStore: pubStore,
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: jobManager,
            mintGate: mintGate,
            maughamVersion: "0.0.0-test",
            tectonicVersion: "n/a")
    }

    /// (a) A source pdf@0.1 exists → `compile(language:"es")` (no version) mints
    /// version "0.1" + language "es" and leaves next_version unbumped.
    func testEdition_languageWithoutVersion_mintsAtLatestSourceVersion_noBump() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Ed", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)
        try await seedSourcePublication(pubStore, version: "0.1", format: .pdf)

        let result = try await makeOrch(configStore, pubStore)
            .compile(format: .epub, label: nil, language: "es")
        guard case .completed(let pub, _) = result else {
            return XCTFail("expected completed, got \(result)")
        }
        XCTAssertEqual(pub.version, "0.1", "es edition renders the source version, not a new one")
        XCTAssertEqual(pub.language, "es")

        let cfg = try await configStore.load()
        XCTAssertEqual(cfg?.nextVersion, "0.1",
                       "a language compile must not bump next_version")
    }

    /// (a, republish-exclusion — T1 review) A republished SOURCE record
    /// (`language == nil`, `republishedFrom` set, mangled `-r…` version) more
    /// recent than the genuine source publication must NOT be the resolution
    /// target: the edition mints at the ORIGINAL "0.1", not "0.1-rabcd".
    func testEdition_languageWithoutVersion_ignoresRepublishedSourceRecords() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Ed", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)
        try await seedSourcePublication(
            pubStore, version: "0.1", format: .pdf,
            compiledAt: Date(timeIntervalSinceNow: -1000))
        // More-recent republished source record with a mangled version.
        try await pubStore.append(Publication(
            publicationID: "pub-repub", version: "0.1-rabcd", label: nil,
            format: .pdf, outputPath: "Exports/repub.pdf",
            snapshotID: "snap-src", checkpointID: "",
            republishedFrom: "0.1", compiledAt: Date(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0",
            language: nil))

        let result = try await makeOrch(configStore, pubStore)
            .compile(format: .epub, label: nil, language: "es")
        guard case .completed(let pub, _) = result else {
            return XCTFail("expected completed, got \(result)")
        }
        XCTAssertEqual(pub.version, "0.1",
                       "edition must mint at the original source version, not the republished '-r…' one")
        XCTAssertEqual(pub.language, "es")
    }

    /// (c, republish-exclusion — T1 review) Pinning a republished record's
    /// mangled version is refused: the pinned-`version` branch validates
    /// against ORIGINAL source records only (`republishedFrom == nil`) — the
    /// same rule as latest-source resolution, closing the other door to a
    /// mangled-version edition.
    func testEdition_pinnedRepublishedVersion_refused() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Ed", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)
        try await seedSourcePublication(pubStore, version: "0.1", format: .pdf)
        try await pubStore.append(Publication(
            publicationID: "pub-repub", version: "0.1-rabcd", label: nil,
            format: .pdf, outputPath: "Exports/repub.pdf",
            snapshotID: "snap-src", checkpointID: "",
            republishedFrom: "0.1", compiledAt: Date(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0",
            language: nil))

        let result = try await makeOrch(configStore, pubStore)
            .compile(format: .epub, label: nil, language: "es", version: "0.1-rabcd")
        guard case .failed(let errs, let log) = result else {
            return XCTFail("expected .failed, got \(result)")
        }
        XCTAssertTrue(errs.contains { $0.message.contains("no source v0.1-rabcd") },
                      "got: \(errs.map(\.message))")
        XCTAssertTrue(log.contains("no_source_version"))
        // T1 re-review: the record DOES exist (as a republished one), so the
        // refusal must explain the republish-exclusion and name the original,
        // pinnable version rather than claim nothing exists at that version.
        let context = errs.flatMap(\.contextLines).joined(separator: "\n")
        XCTAssertTrue(context.contains("republished record"),
                      "context must explain the record is republished, got: \(context)")
        XCTAssertTrue(context.contains("pin the original v0.1"),
                      "context must name the original pinnable version, got: \(context)")
        let pubs = try await pubStore.load()
        XCTAssertEqual(pubs.count, 2, "refusal must mint nothing")
    }

    /// (a, latest-selection) With two source versions, a version-less language
    /// compile targets the most recent source publication by `compiledAt`.
    func testEdition_languageWithoutVersion_picksLatestSourceByCompiledAt() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Ed", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)
        try await seedSourcePublication(
            pubStore, version: "0.1", format: .pdf,
            compiledAt: Date(timeIntervalSinceNow: -1000))
        try await seedSourcePublication(
            pubStore, version: "0.2", format: .pdf, compiledAt: Date())

        let result = try await makeOrch(configStore, pubStore)
            .compile(format: .epub, label: nil, language: "es")
        guard case .completed(let pub, _) = result else {
            return XCTFail("expected completed, got \(result)")
        }
        XCTAssertEqual(pub.version, "0.2", "must pick the latest source version")
    }

    /// (b) No source publication → a language compile fails loudly and mints
    /// nothing; the message tells the writer to compile the source edition first.
    func testEdition_languageWithoutSourcePublication_failsLoudly() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Ed", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)

        let result = try await makeOrch(configStore, pubStore)
            .compile(format: .epub, label: nil, language: "es")
        guard case .failed(let errs, let log) = result else {
            return XCTFail("expected .failed, got \(result)")
        }
        XCTAssertTrue(errs.contains { $0.message.contains("compile the source edition first") },
                      "message must name the remedy, got: \(errs.map(\.message))")
        XCTAssertTrue(log.contains("no_source_publication"))
        let pubs = try await pubStore.load()
        XCTAssertTrue(pubs.isEmpty, "no Publication may be minted on the loud failure")
    }

    /// (c) A pinned `version` + `language` mints the family member; repeating the
    /// exact (version, language, format) triple collides with a refusal naming
    /// version AND language (AND format).
    func testEdition_pinnedVersion_mintsThenExactTripleCollides() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Ed", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)
        try await seedSourcePublication(pubStore, version: "0.1", format: .pdf)
        let orch = makeOrch(configStore, pubStore)

        let first = try await orch.compile(
            format: .epub, label: nil, language: "es", version: "0.1")
        guard case .completed(let pub, _) = first else {
            return XCTFail("expected completed, got \(first)")
        }
        XCTAssertEqual(pub.version, "0.1")
        XCTAssertEqual(pub.language, "es")

        // Repeat the exact triple → collision.
        let dupe = try await orch.compile(
            format: .epub, label: nil, language: "es", version: "0.1")
        guard case .failed(let errs, let log) = dupe else {
            return XCTFail("expected collision .failed, got \(dupe)")
        }
        let message = errs.map(\.message).joined()
        XCTAssertTrue(message.contains("0.1"), "collision must name the version: \(message)")
        XCTAssertTrue(message.contains("es"), "collision must name the language: \(message)")
        XCTAssertTrue(message.contains("epub"), "collision must name the format: \(message)")
        XCTAssertTrue(log.contains("version_collision"))

        let pubs = try await pubStore.load()
        XCTAssertEqual(pubs.count, 2, "seed + one es edition; the dupe minted nothing")
    }

    /// (d) A source compile at a manually-set next_version colliding with an
    /// EXISTING source version+format still refuses — the exact-triple guard is
    /// not weakened for a same-(version, language, format) source match.
    func testEdition_sourceCompile_exactTripleCollision_refuses() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig(metadata: .init(title: "Ed", author: "T"))
        cfg.nextVersion = "0.1"
        try await configStore.save(cfg)
        let pubStore = PublicationStore(projectURL: tmp)
        try await seedSourcePublication(pubStore, version: "0.1", format: .epub)

        let result = try await makeOrch(configStore, pubStore)
            .compile(format: .epub, label: nil)
        guard case .failed(let errs, let log) = result else {
            return XCTFail("expected .failed, got \(result)")
        }
        XCTAssertTrue(errs.contains {
            $0.message.contains("0.1") && $0.message.lowercased().contains("already exists") })
        XCTAssertTrue(log.contains("version_collision"))
        let pubs = try await pubStore.load()
        XCTAssertEqual(pubs.count, 1, "collision guard must not mint")
    }

    /// (d, weaker-for-format) The triple guard is strictly weaker than the old
    /// version-only guard: a DIFFERENT format at the same source version is
    /// permitted, deliberately completing a family at a manually-set version.
    func testEdition_sourceCompile_differentFormatSameVersion_permitted() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig(metadata: .init(title: "Ed", author: "T"))
        cfg.nextVersion = "0.1"
        try await configStore.save(cfg)
        let pubStore = PublicationStore(projectURL: tmp)
        try await seedSourcePublication(pubStore, version: "0.1", format: .pdf)

        // Source epub at 0.1 — different format from the seeded pdf → no collision.
        let result = try await makeOrch(configStore, pubStore)
            .compile(format: .epub, label: nil)
        guard case .completed(let pub, _) = result else {
            return XCTFail("expected completed (weaker guard), got \(result)")
        }
        XCTAssertEqual(pub.version, "0.1")
        XCTAssertNil(pub.language)
        // A source compile still bumps next_version.
        let after = try await configStore.load()
        XCTAssertEqual(after?.nextVersion, "0.2")
    }

    /// (e) `version:` without `language:` is refused — source versions come from
    /// next_version, never a pinned version.
    func testEdition_versionWithoutLanguage_refused() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Ed", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)

        let result = try await makeOrch(configStore, pubStore)
            .compile(format: .epub, label: nil, version: "0.1")
        guard case .failed(let errs, let log) = result else {
            return XCTFail("expected .failed, got \(result)")
        }
        XCTAssertTrue(errs.contains { $0.message.contains("requires a language") },
                      "got: \(errs.map(\.message))")
        XCTAssertTrue(log.contains("version_without_language"))
        let pubs = try await pubStore.load()
        XCTAssertTrue(pubs.isEmpty)
    }

    /// (f) dry_run runs the identical resolution + guard. A valid pinned edition
    /// passes the dry run and mutates nothing.
    func testEdition_dryRun_pinnedVersion_validates_zeroMutation() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Ed", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)
        try await seedSourcePublication(pubStore, version: "0.1", format: .pdf)

        let result = try await makeOrch(configStore, pubStore)
            .compile(format: .epub, label: nil, language: "es",
                     dryRun: true, version: "0.1")
        guard case .dryRunPassed = result else {
            return XCTFail("expected .dryRunPassed, got \(result)")
        }
        let pubs = try await pubStore.load()
        XCTAssertEqual(pubs.count, 1, "dry_run must not mint (only the seed remains)")
        let cfg = try await configStore.load()
        XCTAssertEqual(cfg?.nextVersion, "0.1", "dry_run must not bump next_version")
    }

    /// (f) The same dry_run resolution refuses an invalid pin (no source at that
    /// version) and still mutates nothing.
    func testEdition_dryRun_missingSourceVersion_refuses_zeroMutation() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Ed", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)

        let result = try await makeOrch(configStore, pubStore)
            .compile(format: .epub, label: nil, language: "es",
                     dryRun: true, version: "0.2")
        guard case .failed(let errs, let log) = result else {
            return XCTFail("expected .failed from resolution, got \(result)")
        }
        XCTAssertTrue(errs.contains { $0.message.contains("no source v0.2") },
                      "got: \(errs.map(\.message))")
        XCTAssertTrue(log.contains("no_source_version"))
        let pubs = try await pubStore.load()
        XCTAssertTrue(pubs.isEmpty, "dry_run refusal must mint nothing")
    }

    /// (g) End-to-end edition pair: a source compile bumps next_version; a
    /// language edition of that source version leaves next_version untouched.
    /// EPUB path is tectonic-free.
    func testEdition_sourceBumps_languageEditionDoesNot_endToEnd() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Ed", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)
        let orch = makeOrch(configStore, pubStore)

        // Source edition: mints 0.1, bumps next_version to 0.2.
        let source = try await orch.compile(format: .epub, label: nil)
        guard case .completed(let sourcePub, _) = source else {
            return XCTFail("source compile failed: \(source)")
        }
        XCTAssertEqual(sourcePub.version, "0.1")
        XCTAssertNil(sourcePub.language)
        let afterSource = try await configStore.load()
        XCTAssertEqual(afterSource?.nextVersion, "0.2", "source compile bumps next_version")

        // Language edition of that source: renders 0.1, next_version stays 0.2.
        let edition = try await orch.compile(format: .epub, label: nil, language: "es")
        guard case .completed(let editionPub, _) = edition else {
            return XCTFail("edition compile failed: \(edition)")
        }
        XCTAssertEqual(editionPub.version, "0.1", "es edition renders the source version")
        XCTAssertEqual(editionPub.language, "es")
        let afterEdition = try await configStore.load()
        XCTAssertEqual(afterEdition?.nextVersion, "0.2",
                       "a language edition must not advance next_version")

        let pubs = try await pubStore.load()
        XCTAssertEqual(pubs.count, 2, "one source + one language edition")
    }

    // MARK: - C1: the RESOLVED edition version reaches the compiled OUTPUT
    //
    // The edition-effective config threads `effectiveVersion` into
    // `effective.nextVersion` so the filename `{version}` token, the PDF
    // `\MaughamVersion`, and the EPUB metadata render the version the edition
    // TARGETS — not the (possibly-bumped) `config.nextVersion`. Before the fix,
    // an edition compiled after the source bump shipped under the wrong version.

    /// (C1-1) Source at 0.1, next_version manually advanced to 0.5, then a
    /// version-less es edition. The es edition renders the SOURCE version 0.1,
    /// so its output filename must carry "v0.1" — NOT "v0.5" (the pre-fix bug,
    /// where the filename rendered config.nextVersion).
    func testC1_editionOutputFilename_usesResolvedSourceVersion_notNextVersion() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig(metadata: .init(title: "Ed", author: "T"))
        cfg.nextVersion = "0.5"
        try await configStore.save(cfg)
        let pubStore = PublicationStore(projectURL: tmp)
        try await seedSourcePublication(pubStore, version: "0.1", format: .pdf)

        let result = try await makeOrch(configStore, pubStore)
            .compile(format: .epub, label: nil, language: "es")
        guard case .completed(let pub, _) = result else {
            return XCTFail("expected completed, got \(result)")
        }
        XCTAssertEqual(pub.version, "0.1")
        XCTAssertTrue(pub.outputPath.contains("v0.1"),
                      "edition filename must render the resolved source version: \(pub.outputPath)")
        XCTAssertFalse(pub.outputPath.contains("v0.5"),
                       "edition filename must not render the bumped next_version: \(pub.outputPath)")
    }

    /// (C1-2) Two pinned es editions at DIFFERENT source versions must produce
    /// DISTINCT output filenames. Both pass the (version, language, format)
    /// collision guard (versions differ), so before the C1 fix both rendered
    /// config.nextVersion into the SAME filename — silently clobbering each
    /// other's output while the two records pointed at one path.
    func testC1_twoPinnedEditionsAtDifferentVersions_distinctOutputPaths() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Ed", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)
        try await seedSourcePublication(pubStore, version: "1.0", format: .epub)
        try await seedSourcePublication(pubStore, version: "1.1", format: .epub)
        let orch = makeOrch(configStore, pubStore)

        let a = try await orch.compile(
            format: .epub, label: nil, language: "es", version: "1.0")
        let b = try await orch.compile(
            format: .epub, label: nil, language: "es", version: "1.1")
        guard case .completed(let pubA, _) = a, case .completed(let pubB, _) = b else {
            return XCTFail("both pinned editions must complete; got \(a) / \(b)")
        }
        XCTAssertEqual(pubA.version, "1.0")
        XCTAssertEqual(pubB.version, "1.1")
        XCTAssertNotEqual(pubA.outputPath, pubB.outputPath,
                          "distinct pinned versions must not share an output path (clobber): \(pubA.outputPath)")
        XCTAssertTrue(pubA.outputPath.contains("v1.0"), pubA.outputPath)
        XCTAssertTrue(pubB.outputPath.contains("v1.1"), pubB.outputPath)
    }

    // MARK: - P2 (issue #25): the mint gate
    //
    // The catalog triple-guard reads the catalog, and only after the compile
    // does the winner's row land in it — so two calls inside that window both
    // pass the guard and both mint. `PublishMintGate` closes it. EPUB
    // throughout: no tectonic, sub-second, so two calls really do overlap.

    /// Two same-process compiles of one triple, started together: exactly one
    /// Publication, and one refusal naming the in-flight edition.
    func testP2_concurrentIdenticalCompiles_mintExactlyOnePublication() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Race", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)
        let orch = makeOrch(configStore, pubStore)

        async let first = orch.compile(format: .epub, label: nil)
        async let second = orch.compile(format: .epub, label: nil)
        let outcomes = try await [first, second]

        let completed = outcomes.compactMap { outcome -> Publication? in
            if case .completed(let pub, _) = outcome { return pub }
            return nil
        }
        let refusals = outcomes.compactMap { outcome -> [TectonicLogParser.Diagnostic]? in
            if case .failed(let errs, _) = outcome { return errs }
            return nil
        }
        XCTAssertEqual(completed.count, 1, "exactly one of the two compiles may mint: \(outcomes)")
        XCTAssertEqual(refusals.count, 1, "the loser must be refused, not silently succeed: \(outcomes)")
        XCTAssertTrue(
            refusals.flatMap { $0 }.contains { $0.message.contains("already compiling") },
            "the refusal must name the in-flight compile, got: \(refusals)")

        let pubs = try await pubStore.load()
        XCTAssertEqual(pubs.count, 1, "the race must leave exactly one Publication at v0.1")
        // The source path's other half of the same race: one grab of
        // next_version, so the counter advanced exactly once.
        let cfg = try await configStore.load()
        XCTAssertEqual(cfg?.nextVersion, "0.2",
                       "only the winning compile may bump next_version")
    }

    /// The deterministic half of the race: with the triple already reserved on
    /// the gate the orchestrator shares, a compile is refused before it
    /// touches anything — no snapshot, no output, no Publication, no bump.
    /// (The concurrent test above proves the reservation really happens on the
    /// compile path; this one proves what the refusal costs.)
    func testP2_aTripleAlreadyInFlightIsRefusedWithoutMinting() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Held", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)
        let gate = PublishMintGate()
        let reserved = await gate.reserve(
            PublishMintGate.Key(version: "0.1", language: nil, format: .epub))
        XCTAssertTrue(reserved)

        let result = try await makeOrch(configStore, pubStore, gate)
            .compile(format: .epub, label: nil)
        guard case .failed(let errs, let log) = result else {
            return XCTFail("expected .failed while the triple is in flight, got \(result)")
        }
        XCTAssertTrue(errs.contains { $0.message.contains("already compiling") },
                      "got: \(errs.map(\.message))")
        XCTAssertTrue(errs.contains { $0.message.contains("0.1") && $0.message.contains("epub") },
                      "the refusal must name the triple: \(errs.map(\.message))")
        // I2: and where that triple lives, since an imprint may hold its own.
        XCTAssertTrue(errs.contains { $0.message.contains("on the book") },
                      "the refusal must name the book: \(errs.map(\.message))")
        XCTAssertTrue(log.contains("mint_in_flight"), log)

        let minted = try await pubStore.load()
        XCTAssertTrue(minted.isEmpty, "a refusal must mint nothing")
        let cfg = try await configStore.load()
        XCTAssertEqual(cfg?.nextVersion, "0.1", "a refusal must not bump next_version")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tmp.appendingPathComponent("Exports").path),
            "a refusal must not write output")
    }

    /// The other thing a refusal must not touch: the publish tree itself.
    /// The F5 EMISSION.md refresh used to run on the way TO the gate, so a
    /// compile that was about to be refused still rewrote the file — and its
    /// atomic-write temp could land inside the winner's snapshot enumeration
    /// (CI run 31584930789: the winner died reading the loser's vanishing
    /// `EMISSION.md.sb-*`). A refused compile leaves EMISSION.md alone.
    func testP2_aRefusedCompileDoesNotRewriteEmissionMd() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Held", author: "T")))
        let gate = PublishMintGate()
        let reserved = await gate.reserve(
            PublishMintGate.Key(version: "0.1", language: nil, format: .epub))
        XCTAssertTrue(reserved)

        let emission = tmp.appendingPathComponent(".maugham/publish/EMISSION.md")
        try "sentinel — refused compiles may not rewrite this".write(
            to: emission, atomically: true, encoding: .utf8)

        let result = try await makeOrch(configStore, PublicationStore(projectURL: tmp), gate)
            .compile(format: .epub, label: nil)
        guard case .failed = result else {
            return XCTFail("expected .failed while the triple is in flight, got \(result)")
        }
        XCTAssertEqual(try String(contentsOf: emission),
                       "sentinel — refused compiles may not rewrite this",
                       "a refusal must not touch the publish tree")
    }

    /// A compile whose reserved section throws must hand its reservation
    /// back — otherwise one transient disk error wedges that edition for the
    /// life of the app. A plain file where `Exports/` belongs makes the EPUB
    /// writer's `createDirectory` throw, well past the reservation point.
    /// Since the RULING-52 fix the throw surfaces as a `.failed` outcome (the
    /// honest report) rather than propagating raw — the reservation release
    /// this test guards is unchanged: removing the file and retrying must
    /// compile, not refuse.
    func testP2_reservationIsReleasedWhenTheCompileThrows() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Throw", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)
        let gate = PublishMintGate()
        let orch = makeOrch(configStore, pubStore, gate)

        let exports = tmp.appendingPathComponent("Exports")
        try "not a directory".write(to: exports, atomically: true, encoding: .utf8)
        let blocked = try await orch.compile(format: .epub, label: nil)
        guard case .failed = blocked else {
            return XCTFail("expected .failed with a file where Exports/ belongs, got \(blocked)")
        }
        try FileManager.default.removeItem(at: exports)

        let retry = try await orch.compile(format: .epub, label: nil)
        guard case .completed(let pub, _) = retry else {
            return XCTFail("the retry must not be refused by a leaked reservation: \(retry)")
        }
        XCTAssertEqual(pub.version, "0.1", "the failed attempt minted nothing, so 0.1 is still free")
        // And the gate itself is clean.
        let free = await gate.reserve(
            PublishMintGate.Key(version: "0.1", language: nil, format: .epub))
        XCTAssertTrue(free, "the gate must hold no reservation once the compile has returned")
    }

    /// M1 (whole-branch review): a dry run answers "would this compile?" and
    /// mutates nothing, so it must neither be refused by an in-flight compile
    /// nor take the gate away from one. With the triple deliberately held, the
    /// dry run must still ANSWER — and must leave the reservation exactly as
    /// it found it, held by its real owner (a dry run that never reserved must
    /// never release).
    func testDryRun_answersWhileTheTripleIsInFlight_andTouchesNoReservation() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "DryHeld", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)
        let gate = PublishMintGate()
        let key = PublishMintGate.Key(version: "0.1", language: nil, format: .epub)
        let reserved = await gate.reserve(key)
        XCTAssertTrue(reserved, "fixture sanity: the triple must start held")

        let result = try await makeOrch(configStore, pubStore, gate)
            .compile(format: .epub, label: nil, dryRun: true)
        guard case .dryRunPassed = result else {
            return XCTFail("a dry run must answer rather than be refused by an in-flight compile, got \(result)")
        }

        // The real owner's reservation survives: the dry run neither took it
        // nor handed back a reservation it never held.
        let stillHeld = await gate._inFlightForTesting
        XCTAssertEqual(stillHeld, [key],
                       "the in-flight compile's reservation must survive the dry run, got: \(stillHeld)")

        // And the dry run mutated nothing, as ever.
        let pubs = try await pubStore.load()
        XCTAssertTrue(pubs.isEmpty, "a dry run must mint nothing")
        let cfg = try await configStore.load()
        XCTAssertEqual(cfg?.nextVersion, "0.1", "a dry run must not bump next_version")
    }
    /// RULING-22 (fix for M7-PB-009): a cancel that lands while the compile
    /// is rendering stops it BEFORE anything durable is committed — no
    /// snapshot, no export, no catalog row, no version bump, and the outcome
    /// says cancelled rather than completed.
    func test_aCancelledCompileDoesNotPublish() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Cxl", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)
        let jobs = CompileJobManager()

        /// Holds the emit until the test has cancelled the job — a slow
        /// manuscript, not a mock: `orderedPieces` really is called on the
        /// compile path.
        final class Gate: @unchecked Sendable {
            let semaphore = DispatchSemaphore(value: 0)
        }
        let gate = Gate()
        struct SlowSrc: ProjectASTBuilder.Source {
            let gate: Gate
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                gate.semaphore.wait()
                return [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hi.")]
            }
        }
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: SlowSrc(gate: gate),
            configStore: configStore,
            publicationStore: pubStore,
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: jobs,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")

        let compileTask = Task.detached {
            try await orch.compile(format: .epub, label: nil)
        }
        // Wait for the job to exist, cancel it, then let the emit proceed.
        let deadline = Date().addingTimeInterval(10)
        var jobID: String?
        while jobID == nil && Date() < deadline {
            jobID = await jobs.allInProgress().first?.jobID
            if jobID == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        let id = try XCTUnwrap(jobID, "the job never registered")
        _ = await jobs.cancel(jobID: id)
        gate.semaphore.signal()

        let outcome = try await compileTask.value
        guard case .cancelled = outcome else {
            return XCTFail("a cancelled compile must not publish — got \(outcome)")
        }
        let catalog = try await pubStore.load()
        XCTAssertTrue(catalog.isEmpty, "no catalog row")
        let exports = (try? FileManager.default.contentsOfDirectory(
            atPath: tmp.appendingPathComponent("Exports").path)) ?? []
        XCTAssertEqual(exports, [],
                       "no export file — the cancelled compile takes back the "
                       + "artifact it had already staged there (the directory "
                       + "shell may remain)")
        let cfg = try await configStore.load()
        XCTAssertEqual(cfg?.nextVersion, "0.1", "no version bump")
        let job = await jobs.get(jobID: id)
        if case .cancelled = job?.status {} else {
            XCTFail("the record still says cancelled — got \(String(describing: job?.status))")
        }
    }

    /// RULING-8 (fix for M7-PB-008): the compile path refuses an occupied
    /// destination exactly as the republish path does — with a filename
    /// template omitting {version}, the second source compile used to DELETE
    /// the first record's bytes and point that record's catalog row at the
    /// wrong edition. Whatever is at the destination, it is not this job's to
    /// destroy.
    /// Task 6 note: this used to force the collision with a `{version}`-less
    /// `filename_template`, which a compile now refuses outright — the
    /// pre-flight validates the config, and a template missing `{version}`
    /// could never have been written through `set_publish_config` either. The
    /// destination is occupied the way it can still legitimately happen: a
    /// file sitting where the next compile would write (a hand-placed export,
    /// a record whose catalog row was lost).
    func test_anOccupiedDestinationRefusesRatherThanReplacingAnEarlierRecordsBytes() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        var config = PublishConfig(metadata: .init(title: "Occ", author: "T"))
        config.outputs.filenameTemplate = "{title}-v{version}.{ext}"
        try await configStore.save(config)
        let pubStore = PublicationStore(projectURL: tmp)
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hi.")]
            }
        }
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: pubStore,
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")

        guard case .completed = try await orch.compile(format: .epub, label: nil)
        else { return XCTFail("first compile failed") }

        // The destination the NEXT compile (v0.2) would take is already held.
        let occupied = tmp.appendingPathComponent("Exports/Occ-v0.2.epub")
        let occupiedBytes = Data("an earlier record's bytes".utf8)
        try occupiedBytes.write(to: occupied)

        let outcome = try await orch.compile(format: .epub, label: nil)
        guard case .failed(let errors, _) = outcome else {
            return XCTFail("expected the occupied-destination refusal, got \(outcome)")
        }
        XCTAssertTrue(errors.first?.message.contains("refusing to overwrite") == true,
                      "found: \(String(describing: errors.first?.message))")
        XCTAssertEqual(try Data(contentsOf: occupied), occupiedBytes,
                       "the occupant's bytes are untouched")
        let catalog = try await pubStore.load()
        XCTAssertEqual(catalog.count, 1, "and no second row was minted over them")
    }

    /// RULING-52 + RULING-7 (fix for M7-PB-005/006/007): a failure AFTER the
    /// first durable mutation says what it did as well as what failed, and the
    /// job record is terminal — never stranded in_progress. Injected at the
    /// sharpest site: a valid but READ-ONLY catalog file, so the strict load
    /// (RULING-54) reads it fine and the APPEND throws after the export and
    /// the snapshot have landed. (A directory squatting on the path — the old
    /// injection — now refuses pre-flight instead; pinned below.)
    func test_aFailureAfterMutationNamesWhatLandedAndTerminalisesTheJob() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Led", author: "T")))
        let jobs = CompileJobManager()
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hi.")]
            }
        }
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: PublicationStore(projectURL: tmp),
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: jobs,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        // Injection: a valid but READ-ONLY catalog file — the strict load
        // (RULING-54) reads it fine, and the append throws AFTER the export
        // and snapshot have landed. (A directory squatting on this path now
        // refuses pre-flight instead — pinned below.)
        let catalogURL = PublicationStore.fileURL(
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current), in: tmp)
        try FileManager.default.createDirectory(
            at: catalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: catalogURL)  // an empty catalog loads as []
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: catalogURL.path)

        let outcome = try await orch.compile(format: .epub, label: nil)
        guard case .failed(let errors, _) = outcome else {
            return XCTFail("the thrown error must surface as .failed, got \(outcome)")
        }
        let context = (errors.first?.contextLines ?? []).joined(separator: "\n")
        XCTAssertTrue(context.contains("Exports/"),
                      "the report names the export that landed — found: \(context)")
        XCTAssertTrue(context.lowercased().contains("snapshot"),
                      "and the snapshot — found: \(context)")
        XCTAssertTrue(context.contains("next_version")
                        || context.lowercased().contains("not advanced")
                        || context.lowercased().contains("did not happen"),
                      "and says the remaining steps did not happen — found: \(context)")
        let inFlight = await jobs.allInProgress()
        XCTAssertTrue(inFlight.isEmpty, "the job is terminal, not stranded")
    }

    /// RULING-54 (M9-OL-009): an UNREADABLE-yet-present catalog file refuses
    /// the compile at the pre-flight load — BEFORE any mutation — because a
    /// silently shorter catalog is what the occupied-destination refusal and
    /// the version mint read. Nothing lands: no export, no snapshot, and the
    /// job is terminal with the error naming the file.
    func test_anUnreadableCatalogRefusesBeforeAnythingLands() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Led", author: "T")))
        let jobs = CompileJobManager()
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hi.")]
            }
        }
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: PublicationStore(projectURL: tmp),
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: jobs,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        // A directory squatting on the catalog path: unreadable-yet-present.
        let catalogURL = PublicationStore.fileURL(
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current), in: tmp)
        try FileManager.default.createDirectory(
            at: catalogURL, withIntermediateDirectories: true)

        let outcome = try await orch.compile(format: .epub, label: nil)

        guard case .failed(let errors, _) = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        let text = errors.map(\.message).joined(separator: "\n")
        XCTAssertTrue(text.contains(catalogURL.lastPathComponent) || text.contains("publications catalog"),
                      "the refusal names the catalog — found: \(text)")
        let exports = (try? FileManager.default.contentsOfDirectory(
            atPath: tmp.appendingPathComponent("Exports").path)) ?? []
        XCTAssertTrue(exports.isEmpty, "nothing landed — the refusal came before any mutation")
        let inFlight = await jobs.allInProgress()
        XCTAssertTrue(inFlight.isEmpty, "the job is terminal")
    }

    // MARK: - Imprints (P1 Task 6): resolution at the door, identity below it
    //
    // An imprint is a named publishing configuration inside one project. The
    // orchestrator resolves it ONCE — `PublishConfig.resolved(imprint:pieceIDs:)`
    // — and everything downstream reads a plain `PublishConfig` that never
    // learns an imprint existed. What the orchestrator keeps for itself is
    // IDENTITY: an imprint's publications are its own, so the pin, the
    // latest-source resolution, the collision guard and the mint key are all
    // scoped by imprint, and the counter a source compile advances is the
    // imprint's own rather than the book's.

    /// A project with one imprint, `special`, counting its own versions from
    /// 1.0 while the book counts from 0.1. Nothing here names an allowlist, so
    /// the whole (one-piece) book is in every edition.
    private func imprintConfig(
        template: String? = nil,
        imprintNextVersion: String? = "1.0",
        sections: [String: PublishConfig.Section]? = nil,
        bookNextVersion: String = "0.1"
    ) -> PublishConfig {
        PublishConfig(
            metadata: .init(title: "Orch", author: "T"),
            nextVersion: bookNextVersion,
            imprints: ["special": .init(
                template: template,
                sections: sections,
                metadata: ["title": .string("Orch, Special Edition")],
                nextVersion: imprintNextVersion)])
    }

    /// Acceptance 2. A source compile under `special` mints
    /// `(special, "1.0", nil, pdf)`, advances the IMPRINT's counter to 1.1,
    /// leaves the book's alone, and freezes the resolved config — imprint and
    /// its own template — into the snapshot a republish reproduces from.
    func testImprint_sourceCompile_mintsUnderTheImprintAndBumpsOnlyItsCounter() async throws {
        try await TectonicProbe.requireReady()

        // The imprint compiles through its OWN template (Task 5 reads
        // `config.template`): a copy of the starter's, under a distinct
        // basename — which is what the validator's basename rule is for, and
        // what keeps the two out of one another's `build/` intermediates.
        // (Kept beside the starter rather than in a subdirectory: the
        // template `\input`s `preamble.tex` by bare name, which tectonic
        // resolves against the template's own directory.)
        let publish = tmp.appendingPathComponent(".maugham/publish", isDirectory: true)
        let starter = try Data(contentsOf: publish.appendingPathComponent("template.tex"))
        try starter.write(to: publish.appendingPathComponent("special.tex"))

        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(imprintConfig(template: "special.tex"))
        let pubStore = PublicationStore(projectURL: tmp)

        let result = try await makeOrch(configStore, pubStore)
            .compile(format: .pdf, label: nil, imprint: "special")
        guard case .completed(let pub, _) = result else {
            return XCTFail("expected completed, got \(result)")
        }
        XCTAssertEqual(pub.imprint, "special",
                       "the catalog row records the imprint it compiled under")
        XCTAssertEqual(pub.version, "1.0",
                       "an imprint mints at ITS OWN next_version, not the book's")
        XCTAssertNil(pub.language)
        XCTAssertEqual(pub.format, .pdf)

        let after = try await configStore.load()
        XCTAssertEqual(after?.imprints["special"]?.nextVersion, "1.1",
                       "the bump lands on the imprint's own counter")
        XCTAssertEqual(after?.nextVersion, "0.1",
                       "and never on the book's")

        // The snapshot froze the RESOLVED config, which is what lets a
        // republish reproduce the imprint (Task 5 reads `prior?.imprint`).
        let snap = try PublicationSnapshotStore(projectURL: tmp).load(id: pub.snapshotID)
        XCTAssertEqual(snap.config.imprint, "special")
        XCTAssertEqual(snap.config.template, "special.tex")
    }

    /// The converse half of acceptance 2: a BOOK compile of the same project
    /// advances the book's counter and leaves the imprint's where it was.
    func testImprint_bookCompile_leavesTheImprintsCounterAlone() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(imprintConfig())
        let jobs = CompileJobManager()

        let result = try await makeOrch(
            configStore, PublicationStore(projectURL: tmp), jobManager: jobs)
            .compile(format: .epub, label: nil)
        guard case .completed(let pub, _) = result else {
            return XCTFail("expected completed, got \(result)")
        }
        XCTAssertNil(pub.imprint, "a book compile records no imprint")
        XCTAssertEqual(pub.version, "0.1")

        let after = try await configStore.load()
        XCTAssertEqual(after?.nextVersion, "0.2")
        XCTAssertEqual(after?.imprints["special"]?.nextVersion, "1.0",
                       "the imprint's counter is not the book's to advance")

        // The control for the refusal below: a compile that RAN registered a
        // job, so an empty job manager there means something, not nothing.
        let seen = await jobs.all()
        XCTAssertEqual(seen.count, 1, "a compile that starts registers a job")
    }

    /// A name this project never defined is a caller's typo, not a compile —
    /// so nothing is registered as having started.
    func testImprint_unknownName_refusesBeforeTheJobManagerSeesAJob() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(imprintConfig())
        let jobs = CompileJobManager()

        let result = try await makeOrch(
            configStore, PublicationStore(projectURL: tmp), jobManager: jobs)
            .compile(format: .epub, label: nil, imprint: "speshal")
        guard case .failed(let errors, let excerpt) = result else {
            return XCTFail("expected failed, got \(result)")
        }
        XCTAssertEqual(excerpt, "unknown_imprint: speshal")
        let message = errors.map(\.message).joined(separator: "\n")
        XCTAssertTrue(message.contains("unknown imprint 'speshal'"),
                      "the refusal carries the error's own sentence, got \(message)")
        XCTAssertTrue(message.contains("special"),
                      "and names what this project does define, got \(message)")

        let seen = await jobs.all()
        XCTAssertTrue(seen.isEmpty,
                      "a typo starts no compile, so it leaves no job behind: \(seen)")
    }

    /// The pin is scoped: a version that exists only under another imprint is
    /// not this compile's to render, and the refusal says where it does live.
    func testImprint_pinnedVersionUnderAnotherImprint_isRefusedByName() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(imprintConfig())
        let pubStore = PublicationStore(projectURL: tmp)
        try await seedSourcePublication(
            pubStore, version: "1.0", format: .pdf, imprint: "special")

        let refused = try await makeOrch(configStore, pubStore)
            .compile(format: .epub, label: nil, language: "es", version: "1.0")
        guard case .failed(let errors, let excerpt) = refused else {
            return XCTFail("expected failed, got \(refused)")
        }
        XCTAssertEqual(excerpt, "no_source_version: 1.0/es")
        let context = errors.flatMap(\.contextLines).joined(separator: "\n")
        XCTAssertTrue(
            context.contains("version '1.0' exists under imprint 'special', not the book"),
            "the refusal must name where v1.0 actually lives, got \(context)")

        // The control: the same pin, asked for by the imprint that owns it.
        let accepted = try await makeOrch(configStore, pubStore)
            .compile(format: .epub, label: nil, language: "es", version: "1.0",
                     imprint: "special")
        guard case .completed(let pub, _) = accepted else {
            return XCTFail("expected completed, got \(accepted)")
        }
        XCTAssertEqual(pub.version, "1.0")
        XCTAssertEqual(pub.language, "es")
        XCTAssertEqual(pub.imprint, "special")
    }

    /// And the same refusal in the other direction — the book's version is not
    /// an imprint's to render either.
    func testImprint_pinnedVersionOnTheBook_isRefusedForAnImprintByName() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(imprintConfig())
        let pubStore = PublicationStore(projectURL: tmp)
        try await seedSourcePublication(pubStore, version: "1.0", format: .pdf)

        let refused = try await makeOrch(configStore, pubStore)
            .compile(format: .epub, label: nil, language: "es", version: "1.0",
                     imprint: "special")
        guard case .failed(let errors, _) = refused else {
            return XCTFail("expected failed, got \(refused)")
        }
        let context = errors.flatMap(\.contextLines).joined(separator: "\n")
        XCTAssertTrue(
            context.contains("version '1.0' exists on the book, not under imprint 'special'"),
            "the refusal must name the book as where v1.0 lives, got \(context)")
    }

    /// Latest-source resolution is scoped too: an edition under an imprint
    /// renders that imprint's most recent source, not the book's — even when
    /// the book's is newer.
    func testImprint_latestSourceResolutionIsPerImprint() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(imprintConfig())
        let pubStore = PublicationStore(projectURL: tmp)
        try await seedSourcePublication(
            pubStore, version: "1.0", format: .pdf,
            compiledAt: Date(timeIntervalSinceNow: -1000), imprint: "special")
        try await seedSourcePublication(pubStore, version: "0.9", format: .pdf)

        let result = try await makeOrch(configStore, pubStore)
            .compile(format: .epub, label: nil, language: "es", imprint: "special")
        guard case .completed(let pub, _) = result else {
            return XCTFail("expected completed, got \(result)")
        }
        XCTAssertEqual(pub.version, "1.0",
                       "the imprint's own source, not the book's more recent 0.9")
        XCTAssertEqual(pub.imprint, "special")
    }

    /// The refusing half of the same predicate: the book's source publications
    /// do not make an imprint compilable.
    func testImprint_editionWithNoSourceUnderThatImprint_refuses() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(imprintConfig())
        let pubStore = PublicationStore(projectURL: tmp)
        try await seedSourcePublication(pubStore, version: "0.1", format: .pdf)

        let refused = try await makeOrch(configStore, pubStore)
            .compile(format: .epub, label: nil, language: "es", imprint: "special")
        guard case .failed(_, let excerpt) = refused else {
            return XCTFail("expected failed, got \(refused)")
        }
        XCTAssertEqual(excerpt, "no_source_publication: es")

        // The control: the book, whose source that publication IS.
        let accepted = try await makeOrch(configStore, pubStore)
            .compile(format: .epub, label: nil, language: "es")
        guard case .completed(let pub, _) = accepted else {
            return XCTFail("expected completed, got \(accepted)")
        }
        XCTAssertEqual(pub.version, "0.1")
        XCTAssertNil(pub.imprint)
    }

    /// The collision guard is per imprint: the book and an imprint may both
    /// hold v0.1 of the same format, because they are different publications.
    func testImprint_collisionGuardIsPerImprint() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(imprintConfig(imprintNextVersion: "0.1"))
        let pubStore = PublicationStore(projectURL: tmp)
        let orch = makeOrch(configStore, pubStore)

        guard case .completed(let book, _) =
                try await orch.compile(format: .epub, label: nil) else {
            return XCTFail("the book's 0.1 must compile")
        }
        XCTAssertEqual(book.version, "0.1")

        guard case .completed(let special, _) =
                try await orch.compile(format: .epub, label: nil, imprint: "special") else {
            return XCTFail("the imprint's own 0.1 is a different publication")
        }
        XCTAssertEqual(special.version, "0.1")
        XCTAssertEqual(special.imprint, "special")

        // The control: WITHIN one imprint the guard still fires. Put the
        // counter back and ask for the same triple again.
        var reset = try await configStore.load()!
        reset.imprints["special"]?.nextVersion = "0.1"
        try await configStore.save(reset)
        let refused = try await orch.compile(format: .epub, label: nil, imprint: "special")
        guard case .failed(let errors, let excerpt) = refused else {
            return XCTFail("expected a collision refusal, got \(refused)")
        }
        XCTAssertEqual(excerpt, "version_collision: 0.1/source/epub")
        // I2 (whole-branch review): the excerpt's triple is ambiguous now that
        // the book holds a v0.1/source/epub too — the sentence the writer
        // reads must say which of the two it is refusing.
        XCTAssertTrue(
            errors.contains { $0.message.contains("under imprint 'special'") },
            "the refusal must name the imprint: \(errors.map(\.message))")
        XCTAssertTrue(
            errors.flatMap(\.contextLines).contains { $0.contains("under imprint 'special'") },
            "and so must the triple's context line: "
            + "\(errors.flatMap(\.contextLines))")
    }

    /// The mint gate's key carries the imprint, so a book compile in flight
    /// does not hold an imprint's identical triple.
    func testImprint_mintGateKeyIsPerImprint() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(imprintConfig())
        let pubStore = PublicationStore(projectURL: tmp)
        let gate = PublishMintGate()

        // The BOOK's 1.0/epub is in flight…
        let held = await gate.reserve(
            .init(version: "1.0", language: nil, format: .epub, imprint: nil))
        XCTAssertTrue(held)

        // …which says nothing about the IMPRINT's own 1.0/epub.
        guard case .completed(let pub, _) = try await makeOrch(configStore, pubStore, gate)
            .compile(format: .epub, label: nil, imprint: "special") else {
            return XCTFail("a book's reservation must not block an imprint")
        }
        XCTAssertEqual(pub.version, "1.0")

        // The control: with the IMPRINT's own key held, the same compile is
        // refused. Its counter is 1.1 after the compile above.
        let heldImprint = await gate.reserve(
            .init(version: "1.1", language: nil, format: .epub, imprint: "special"))
        XCTAssertTrue(heldImprint)
        let refused = try await makeOrch(configStore, pubStore, gate)
            .compile(format: .epub, label: nil, imprint: "special")
        guard case .failed(let errors, let excerpt) = refused else {
            return XCTFail("expected an in-flight refusal, got \(refused)")
        }
        XCTAssertEqual(excerpt, "mint_in_flight: 1.1/source/epub")
        // I2: spec §6 — the mint-gate refusal names the imprint.
        XCTAssertTrue(
            errors.contains { $0.message.contains("under imprint 'special'") },
            "the refusal must name the imprint: \(errors.map(\.message))")
        XCTAssertTrue(
            errors.flatMap(\.contextLines).contains { $0.contains("under imprint 'special'") },
            "and so must the triple's context line: "
            + "\(errors.flatMap(\.contextLines))")
    }

    /// `dry_run` under an imprint answers the question and mutates nothing —
    /// no publication, and neither counter moves.
    func testImprint_dryRun_reportsWithoutMintingOrBumping() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(imprintConfig())
        let pubStore = PublicationStore(projectURL: tmp)

        let result = try await makeOrch(configStore, pubStore)
            .compile(format: .epub, label: nil, dryRun: true, imprint: "special")
        guard case .dryRunPassed = result else {
            return XCTFail("expected dryRunPassed, got \(result)")
        }
        let pubs = try await pubStore.load()
        XCTAssertTrue(pubs.isEmpty, "a dry run mints nothing, got \(pubs)")
        let after = try await configStore.load()
        XCTAssertEqual(after?.imprints["special"]?.nextVersion, "1.0",
                       "the imprint's counter must not move on a dry run")
        XCTAssertEqual(after?.nextVersion, "0.1")
    }

    /// The pre-flight reads the piece list only when it can change an answer.
    /// With no imprints there is no allowlist to materialize and no allowlist
    /// id to validate, so an ordinary compile derives its manuscript exactly
    /// once — the emitters' own read — instead of twice.
    ///
    /// `test_aCancelledCompileDoesNotPublish` leans on this as well: its
    /// source blocks on a one-shot semaphore, so a second read would hang the
    /// suite rather than fail it.
    func testImprint_thePieceListIsReadOnlyWhenAnImprintCouldNeedIt() async throws {
        final class Counter: @unchecked Sendable { var reads = 0 }
        struct CountingSrc: ProjectASTBuilder.Source {
            let counter: Counter
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                counter.reads += 1
                return [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hi.")]
            }
        }
        func compileCountingReads(_ cfg: PublishConfig) async throws -> Int {
            let dir = tmp.appendingPathComponent("count-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try await PublishStarter.install(into: dir, force: false)
            let configStore = PublishConfigStore(projectURL: dir)
            try await configStore.save(cfg)
            let counter = Counter()
            let orch = CompileOrchestrator(
                projectURL: dir, astSource: CountingSrc(counter: counter),
                configStore: configStore,
                publicationStore: PublicationStore(projectURL: dir),
                snapshotStore: PublicationSnapshotStore(projectURL: dir),
                jobManager: CompileJobManager(),
                maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
            guard case .completed = try await orch.compile(format: .epub, label: nil)
            else {
                XCTFail("the compile must succeed for the count to mean anything")
                return -1
            }
            return counter.reads
        }

        let plain = try await compileCountingReads(
            PublishConfig(metadata: .init(title: "Orch", author: "T")))
        XCTAssertEqual(plain, 1, "a project with no imprints pays for one read")

        // The control: with an imprint in the config the pre-flight does need
        // the list, and reads it.
        let withImprint = try await compileCountingReads(imprintConfig())
        XCTAssertEqual(withImprint, 2,
                       "an imprint's allowlist is materialized against the real "
                        + "piece ids, so the pre-flight reads them")
    }

    // MARK: - Compile-time config validation (Task 6)

    /// The config-write door deliberately does not check that the DEFAULT
    /// `template.tex` exists — a project whose starter install failed silently
    /// must still be able to patch any config key. The compile is where that
    /// gets met, as a Maugham refusal rather than a tectonic error.
    func testCompile_missingDefaultTemplate_refusesAPDFAtPreFlight() async throws {
        let template = tmp.appendingPathComponent(".maugham/publish/template.tex")
        try FileManager.default.removeItem(at: template)

        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Orch", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)

        let refused = try await makeOrch(configStore, pubStore)
            .compile(format: .pdf, label: nil)
        guard case .failed(let errors, let excerpt) = refused else {
            return XCTFail("expected failed, got \(refused)")
        }
        XCTAssertTrue(excerpt.hasPrefix("invalid_config:"),
                      "expected a config refusal, got \(excerpt)")
        XCTAssertTrue(errors.map(\.message).joined().contains("template.tex"),
                      "the refusal must name the missing template, got \(errors)")
        let pubs = try await pubStore.load()
        XCTAssertTrue(pubs.isEmpty, "nothing was minted")

        // The control: an EPUB of the same project is emitted without LaTeX,
        // so a missing template.tex is not its problem.
        guard case .completed = try await makeOrch(configStore, pubStore)
            .compile(format: .epub, label: nil) else {
            return XCTFail("an EPUB must not need template.tex")
        }
    }

    /// The compile validates the RESOLVED config, and its `pieceIDs` are this
    /// project's own — which is what makes an imprint allowlist naming a piece
    /// that does not exist a refusal rather than a silently empty book.
    func testImprint_allowlistNamingNoPiece_refusesAtCompile() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(imprintConfig(
            sections: ["nope": PublishConfig.Section()]))
        let pubStore = PublicationStore(projectURL: tmp)

        let refused = try await makeOrch(configStore, pubStore)
            .compile(format: .epub, label: nil, imprint: "special")
        guard case .failed(let errors, let excerpt) = refused else {
            return XCTFail("expected failed, got \(refused)")
        }
        XCTAssertTrue(excerpt.contains("imprints.special.sections.nope"),
                      "expected the offending field in the excerpt, got \(excerpt)")
        XCTAssertTrue(errors.map(\.message).joined().contains("nope"),
                      "the refusal must name the id, got \(errors)")

        // The control: the same allowlist naming the piece this project has.
        try await configStore.save(imprintConfig(
            sections: ["p1": PublishConfig.Section()]))
        guard case .completed(let pub, _) = try await makeOrch(configStore, pubStore)
            .compile(format: .epub, label: nil, imprint: "special") else {
            return XCTFail("an allowlist naming a real piece must compile")
        }
        XCTAssertEqual(pub.imprint, "special")
    }


    // MARK: - P2: many languages — one document, one identity
    //
    // `languages:` renders one complete body per tag into ONE publication. The
    // orchestrator's whole job here is the joining: the record, the collision
    // guard, the mint key and the version branches read `set.identity`
    // ("en+sr"), while the compilers' `language:` — which resolves
    // `template.<tag>.tex` and `styles.<tag>.css` — reads `set.singleTag`,
    // nil for a bilingual compile because no one template belongs to two
    // tongues.

    /// A source that answers with different text per language, so a two-body
    /// compile can be read back body by body. The production conformer is
    /// `ProjectStoreASTSource`; `OneSrc` above deliberately is NOT one, which
    /// is what the not-rebindable refusal below is asked over.
    struct RebindableSrc: LanguageRebindableSource {
        let tag: String?
        static func text(for tag: String?) -> String {
            tag.map { "Prevedeniparagrafu\($0)." } ?? "Thesourceparagraph."
        }
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            [.init(pieceID: "p1", title: "C", mode: .prose,
                   displayText: Self.text(for: tag))]
        }
        func rebound(toLanguage tag: String?) -> ProjectASTBuilder.Source {
            RebindableSrc(tag: tag)
        }
    }

    private func makeOrch(
        _ configStore: PublishConfigStore, _ pubStore: PublicationStore,
        source: ProjectASTBuilder.Source,
        in projectURL: URL? = nil,
        jobManager: CompileJobManager = CompileJobManager()
    ) -> CompileOrchestrator {
        let root = projectURL ?? tmp!
        return CompileOrchestrator(
            projectURL: root, astSource: source,
            configStore: configStore,
            publicationStore: pubStore,
            snapshotStore: PublicationSnapshotStore(projectURL: root),
            jobManager: jobManager,
            maughamVersion: "0.0.0-test",
            tectonicVersion: "n/a")
    }

    /// A second project root beside `tmp`, starter installed — for the pin that
    /// compiles the same edition two ways and compares what they minted.
    private func makeSiblingProject(_ name: String) async throws -> URL {
        let dir = tmp.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await PublishStarter.install(into: dir, force: false)
        return dir
    }

    /// Acceptance 2's compile half. A bilingual compile under `special` is ONE
    /// publication — `(special, "0.1", "en+sr", epub)` — the imprint's counter
    /// is the only one that moves, and the archive holds both bodies in the
    /// order they were asked for.
    func test_languages_bilingualImprintCompile_isOnePublicationHoldingBothBodies() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(imprintConfig(imprintNextVersion: nil))
        let pubStore = PublicationStore(projectURL: tmp)

        let result = try await makeOrch(configStore, pubStore, source: RebindableSrc(tag: nil))
            .compile(format: .epub, label: nil, languages: ["en", "sr"],
                     imprint: "special")
        guard case .completed(let pub, _) = result else {
            return XCTFail("expected completed, got \(result)")
        }
        XCTAssertEqual(pub.imprint, "special")
        XCTAssertEqual(pub.version, "0.1",
                       "a set containing the source body mints at next_version")
        XCTAssertEqual(pub.language, "en+sr",
                       "the record carries the joined identity, not one tongue")
        XCTAssertEqual(pub.format, .epub)

        let after = try await configStore.load()
        XCTAssertEqual(after?.imprints["special"]?.nextVersion, "0.2",
                       "the bump lands on the imprint's own counter")
        XCTAssertEqual(after?.nextVersion, "0.1", "and never on the book's")

        // One document, both bodies, in the order asked for.
        let epub = tmp.appendingPathComponent(pub.outputPath)
        let entries = try epubEntryNames(inEPUBAt: epub)
        XCTAssertTrue(entries.contains("OEBPS/section-en-001.xhtml"), "\(entries)")
        XCTAssertTrue(entries.contains("OEBPS/section-sr-001.xhtml"), "\(entries)")
        let en = try epubEntryText("OEBPS/section-en-001.xhtml", inEPUBAt: epub)
        let sr = try epubEntryText("OEBPS/section-sr-001.xhtml", inEPUBAt: epub)
        XCTAssertTrue(en.contains(RebindableSrc.text(for: nil)),
                      "the source body reads the source text: \(en)")
        XCTAssertTrue(sr.contains(RebindableSrc.text(for: "sr")),
                      "the sr body reads its own: \(sr)")
        let opf = try epubEntryText("OEBPS/content.opf", inEPUBAt: epub)
        let enAt = try XCTUnwrap(opf.range(of: "section-en-001.xhtml"))
        let srAt = try XCTUnwrap(opf.range(of: "section-sr-001.xhtml"))
        XCTAssertTrue(enAt.lowerBound < srAt.lowerBound,
                      "the spine keeps the order the languages were asked in:\n\(opf)")
    }

    /// The order asked for IS the identity: `["sr","en"]` is a different
    /// document from `["en","sr"]`, and its record says so.
    func test_languages_theOrderAskedForIsTheIdentity() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Ed", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)

        let result = try await makeOrch(configStore, pubStore, source: RebindableSrc(tag: nil))
            .compile(format: .epub, label: nil, languages: ["sr", "en"])
        guard case .completed(let pub, _) = result else {
            return XCTFail("expected completed, got \(result)")
        }
        XCTAssertEqual(pub.language, "sr+en")
    }

    /// A one-tag list is the legacy `language:` argument — same record, same
    /// filename, byte for byte. Pinned by compiling both, in two projects that
    /// differ in nothing else.
    func test_languages_aSingleTranslatedTagIsTheLegacyLanguageArgument() async throws {
        var minted: [Publication] = []
        for (name, asList) in [("legacy", false), ("aslist", true)] {
            let dir = try await makeSiblingProject(name)
            let configStore = PublishConfigStore(projectURL: dir)
            try await configStore.save(PublishConfig(metadata: .init(title: "Ed", author: "T")))
            let pubStore = PublicationStore(projectURL: dir)
            try await seedSourcePublication(pubStore, version: "0.1", format: .pdf)
            let orch = makeOrch(configStore, pubStore,
                                source: RebindableSrc(tag: nil), in: dir)
            let outcome = asList
                ? try await orch.compile(format: .epub, label: nil, languages: ["sr"])
                : try await orch.compile(format: .epub, label: nil, language: "sr")
            guard case .completed(let pub, _) = outcome else {
                return XCTFail("\(name) must complete, got \(outcome)")
            }
            minted.append(pub)
        }
        XCTAssertEqual(minted[0].language, minted[1].language)
        XCTAssertEqual(minted[0].version, minted[1].version)
        XCTAssertEqual(minted[0].outputPath, minted[1].outputPath,
                       "a one-tag list must not rename the file")
        XCTAssertEqual(minted[1].language, "sr")
    }

    /// A pinned `version` renders an EXISTING source version, so a set that
    /// contains the source body itself is refused exactly as `language: nil`
    /// with a version is — the source body has no version to pin to.
    func test_languages_aPinnedVersionWithASourceBodyIsRefused() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Ed", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)
        try await seedSourcePublication(pubStore, version: "0.1", format: .pdf)

        let refused = try await makeOrch(configStore, pubStore,
                                         source: RebindableSrc(tag: nil))
            .compile(format: .epub, label: nil, languages: ["en", "sr"], version: "0.1")
        guard case .failed(_, let excerpt) = refused else {
            return XCTFail("expected failed, got \(refused)")
        }
        XCTAssertEqual(excerpt, "version_without_language: 0.1")

        // The control: the same version, over a set with no source body.
        let accepted = try await makeOrch(configStore, pubStore,
                                          source: RebindableSrc(tag: nil))
            .compile(format: .epub, label: nil, languages: ["sr"], version: "0.1")
        guard case .completed(let pub, _) = accepted else {
            return XCTFail("a translated-only set may pin a version, got \(accepted)")
        }
        XCTAssertEqual(pub.version, "0.1")
        XCTAssertEqual(pub.language, "sr")
    }

    /// dry_run answers the question for every body and mints none of them.
    func test_languages_dryRunReportsWithoutMinting() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Ed", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)

        let outcome = try await makeOrch(configStore, pubStore,
                                         source: RebindableSrc(tag: nil))
            .compile(format: .epub, label: nil, languages: ["en", "sr"], dryRun: true)
        guard case .dryRunPassed = outcome else {
            return XCTFail("expected dryRunPassed, got \(outcome)")
        }
        let pubs = try await pubStore.load()
        XCTAssertTrue(pubs.isEmpty, "a dry run mints nothing: \(pubs)")
        let after = try await configStore.load()
        XCTAssertEqual(after?.nextVersion, "0.1", "and bumps nothing")
    }

    /// The snapshot records every body's tag, in order, with the source body
    /// spelled the way the config spells it.
    func test_languages_theSnapshotRecordsEveryBodysTag() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Ed", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)

        guard case .completed(let both, _) = try await makeOrch(
            configStore, pubStore, source: RebindableSrc(tag: nil))
            .compile(format: .epub, label: nil, languages: ["en", "sr"]) else {
            return XCTFail("the bilingual compile must complete")
        }
        XCTAssertEqual(try snapStore.load(id: both.snapshotID).languages, ["en", "sr"])

        // A single-body source compile records its one tag — the config's own
        // spelling of the source language, present from now on in every
        // snapshot (older ones decode nil, pinned in PublicationSnapshotTests).
        guard case .completed(let plain, _) = try await makeOrch(
            configStore, pubStore, source: RebindableSrc(tag: nil))
            .compile(format: .epub, label: nil) else {
            return XCTFail("the source compile must complete")
        }
        XCTAssertEqual(try snapStore.load(id: plain.snapshotID).languages, ["en"])
    }

    /// The compilers' `language:` is the set's SINGLE tag, never its identity:
    /// it is what resolves `template.<tag>.tex` and `styles.<tag>.css`, and a
    /// bilingual document belongs to no one tongue's template. So a two-body
    /// compile takes the base files — with a suffixed one sitting right there —
    /// while one translated body still resolves its own.
    ///
    /// The FILENAME is a separate argument (`identity:`) and a separate
    /// question, pinned by
    /// `test_languages_aBilingualFileCarriesItsIdentityInItsName` — this test is
    /// only about what the two suffix-resolving lookups see.
    func test_languages_theCompilersSeeNoSingleTongueForABilingualDocument() async throws {
        let publish = tmp.appendingPathComponent(".maugham/publish", isDirectory: true)
        try "/* sronly */".write(
            to: publish.appendingPathComponent("styles.sr.css"),
            atomically: true, encoding: .utf8)
        // The planted offender for the other wrong answer: a file named after
        // the joined identity, which nothing may ever resolve — the identity
        // names the EDITION (and, since the filename ruling, the output file),
        // never a template or a stylesheet.
        try "/* jointidentity */".write(
            to: publish.appendingPathComponent("styles.en+sr.css"),
            atomically: true, encoding: .utf8)
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Ed", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)

        guard case .completed(let both, _) = try await makeOrch(
            configStore, pubStore, source: RebindableSrc(tag: nil))
            .compile(format: .epub, label: nil, languages: ["en", "sr"]) else {
            return XCTFail("the bilingual compile must complete")
        }
        let css = try epubEntryText(
            "OEBPS/styles.css", inEPUBAt: tmp.appendingPathComponent(both.outputPath))
        XCTAssertFalse(css.contains("sronly"),
                       "a bilingual book takes the BASE stylesheet: \(css)")
        XCTAssertFalse(css.contains("jointidentity"),
                       "and does not resolve a suffix from its identity: \(css)")

        // The control: ONE translated body does resolve its own stylesheet, so
        // the base one above is a decision rather than a missing file.
        try await seedSourcePublication(pubStore, version: "0.1", format: .pdf)
        guard case .completed(let sr, _) = try await makeOrch(
            configStore, pubStore, source: RebindableSrc(tag: nil))
            .compile(format: .epub, label: nil, languages: ["sr"]) else {
            return XCTFail("the sr compile must complete")
        }
        let srCSS = try epubEntryText(
            "OEBPS/styles.css", inEPUBAt: tmp.appendingPathComponent(sr.outputPath))
        XCTAssertTrue(srCSS.contains("sronly"), srCSS)
    }

    /// A bilingual document carries its IDENTITY in its name, so it lands
    /// beside the source edition at the same version instead of on top of it.
    /// The name and the template suffix are two different questions: `identity:`
    /// answers the first, `language:` the second.
    func test_languages_aBilingualFileCarriesItsIdentityInItsName() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Ed", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)

        guard case .completed(let src, _) = try await makeOrch(
            configStore, pubStore, source: RebindableSrc(tag: nil))
            .compile(format: .epub, label: nil) else {
            return XCTFail("the source compile must complete")
        }
        // Back to the version the source edition took, so both want one name.
        guard var reset = try await configStore.load() else {
            return XCTFail("the config must still be there")
        }
        reset.nextVersion = "0.1"
        try await configStore.save(reset)

        let bilingual = try await makeOrch(
            configStore, pubStore, source: RebindableSrc(tag: nil))
            .compile(format: .epub, label: nil, languages: ["en", "sr"])
        guard case .completed(let both, _) = bilingual else {
            return XCTFail(
                "the bilingual compile must complete — without an identity in "
                + "the name it collides with the source edition's file: \(bilingual)")
        }
        XCTAssertEqual(src.version, both.version, "both editions at one version")
        XCTAssertNotEqual(src.outputPath, both.outputPath,
                          "and therefore at two filenames")
        XCTAssertTrue(both.outputPath.hasSuffix("-en+sr.epub"), both.outputPath)
        for path in [src.outputPath, both.outputPath] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: tmp.appendingPathComponent(path).path),
                "both files must be on disk: \(path)")
        }

        // The control: one translated body keeps the name it has always had.
        try await seedSourcePublication(pubStore, version: "0.9", format: .pdf)
        guard case .completed(let sr, _) = try await makeOrch(
            configStore, pubStore, source: RebindableSrc(tag: nil))
            .compile(format: .epub, label: nil, languages: ["sr"], version: "0.9") else {
            return XCTFail("the sr compile must complete")
        }
        XCTAssertTrue(sr.outputPath.hasSuffix("-sr.epub"), sr.outputPath)
    }

    /// A bilingual publication IS a source publication: its identity contains
    /// the source tag, so a later edition pins its version and a version-less
    /// edition resolves to it. Reading `language == nil` alone would tell a
    /// writer who has compiled nothing but "en+sr" that they have no source
    /// edition at all.
    func test_languages_aBilingualRecordIsASourcePublication() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Ed", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)

        guard case .completed(let both, _) = try await makeOrch(
            configStore, pubStore, source: RebindableSrc(tag: nil))
            .compile(format: .epub, label: nil, languages: ["en", "sr"]) else {
            return XCTFail("the bilingual compile must complete")
        }
        XCTAssertEqual(both.version, "0.1")

        // Pinned by version...
        guard case .completed(let pinned, _) = try await makeOrch(
            configStore, pubStore, source: RebindableSrc(tag: nil))
            .compile(format: .epub, label: nil, languages: ["es"], version: "0.1") else {
            return XCTFail("the es edition must pin the bilingual source version")
        }
        XCTAssertEqual(pinned.version, "0.1")

        // ...and without a version, where it is the latest source publication.
        guard case .completed(let latest, _) = try await makeOrch(
            configStore, pubStore, source: RebindableSrc(tag: nil))
            .compile(format: .epub, label: nil, languages: ["fr"]) else {
            return XCTFail("the fr edition must resolve the bilingual source")
        }
        XCTAssertEqual(latest.version, "0.1")

        // The control: an identity with no source component is no source
        // publication, and pinning it is refused by name.
        try await pubStore.append(Publication(
            publicationID: "pub-srfr", version: "3.0", label: nil, format: .epub,
            outputPath: "Exports/srfr.epub", snapshotID: "snap-x", checkpointID: "",
            republishedFrom: nil, compiledAt: Date(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a", language: "sr+fr"))
        let refused = try await makeOrch(configStore, pubStore,
                                         source: RebindableSrc(tag: nil))
            .compile(format: .epub, label: nil, languages: ["es"], version: "3.0")
        guard case .failed(_, let excerpt) = refused else {
            return XCTFail("two translations are not a source edition: \(refused)")
        }
        XCTAssertEqual(excerpt, "no_source_version: 3.0/es")
    }

    /// A `language`/`languages` combination that cannot resolve is a caller's
    /// typo: nothing was read, nothing started, and `compile_status` must not
    /// grow a job for it (the unknown-imprint precedent).
    func test_languages_anImpossibleCombinationRefusesBeforeTheJobRegisters() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Ed", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)
        // The control below renders an existing source version, so seed one.
        try await seedSourcePublication(pubStore, version: "0.1", format: .pdf)
        let jobs = CompileJobManager()

        let refused = try await makeOrch(configStore, pubStore,
                                         source: RebindableSrc(tag: nil), jobManager: jobs)
            .compile(format: .epub, label: nil, language: "sr", languages: ["fr"])
        guard case .failed(let errors, let excerpt) = refused else {
            return XCTFail("expected failed, got \(refused)")
        }
        XCTAssertTrue(excerpt.hasPrefix("invalid_languages: "), excerpt)
        XCTAssertTrue(errors.map(\.message).joined().contains("disagree"),
                      "the refusal carries LanguageSet's own sentence: \(errors)")
        let seen = await jobs.all()
        XCTAssertTrue(seen.isEmpty,
                      "a typo starts no compile, so it leaves no job behind: \(seen)")

        // The control: the same call with the two spellings agreeing runs, and
        // registers a job — so an empty job manager above means something.
        let ok = try await makeOrch(configStore, pubStore,
                                    source: RebindableSrc(tag: nil), jobManager: jobs)
            .compile(format: .epub, label: nil, language: "sr", languages: ["sr"],
                     dryRun: true)
        guard case .dryRunPassed = ok else {
            return XCTFail("the agreeing call must run, got \(ok)")
        }
        let started = await jobs.all()
        XCTAssertEqual(started.count, 1, "a compile that starts registers a job")
    }

    /// Two bodies over a source that cannot bind to a language is refused with
    /// `BodyPlan`'s own sentence. Unlike the door refusals above this one is
    /// discovered while PLANNING the compile — it is a property of the project's
    /// manuscript source rather than of the request — so it registers-then-fails
    /// like every other refusal that got as far as reading the project.
    func test_languages_aSourceThatCannotBindToALanguageIsRefused() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Ed", author: "T")))
        let pubStore = PublicationStore(projectURL: tmp)

        let refused = try await makeOrch(configStore, pubStore, source: OneSrc())
            .compile(format: .epub, label: nil, languages: ["en", "sr"])
        guard case .failed(let errors, let excerpt) = refused else {
            return XCTFail("expected failed, got \(refused)")
        }
        XCTAssertTrue(excerpt.hasPrefix("not_rebindable: "), excerpt)
        XCTAssertTrue(errors.map(\.message).joined().contains("cannot bind to a language"),
                      "the refusal carries BodyPlan's own sentence: \(errors)")

        // The control: ONE body is never rebound, so the same source compiles.
        guard case .completed = try await makeOrch(configStore, pubStore, source: OneSrc())
            .compile(format: .epub, label: nil) else {
            return XCTFail("a single-body compile must not need a rebindable source")
        }
    }

}
