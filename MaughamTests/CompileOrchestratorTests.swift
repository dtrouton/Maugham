import XCTest
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
        // Skip if no tectonic.
        let testBundlePath = Bundle(for: CompileOrchestratorTests.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        guard let _ = try? TectonicLocator.locateInBundle(
            at: URL(fileURLWithPath: appPath)) else {
            throw XCTSkip("tectonic missing")
        }

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
            XCTAssertTrue(log.contains("version_collision"))
        case .completed, .dryRunPassed:
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
        XCTAssertEqual(filtered.orderedPieces().map(\.pieceID), ["p1", "p3"])

        let ast = ProjectASTBuilder.build(from: filtered)
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
        XCTAssertEqual(filtered.orderedPieces().map(\.pieceID), ["p1", "p2"])
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
        compiledAt: Date = Date()
    ) async throws {
        try await store.append(Publication(
            publicationID: "pub-src-\(version)-\(format.rawValue)",
            version: version, label: nil, format: format,
            outputPath: "Exports/src-\(version).\(format.rawValue)",
            snapshotID: "snap-src", checkpointID: "",
            republishedFrom: nil, compiledAt: compiledAt,
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0",
            language: nil))
    }

    private func makeOrch(
        _ configStore: PublishConfigStore, _ pubStore: PublicationStore
    ) -> CompileOrchestrator {
        CompileOrchestrator(
            projectURL: tmp, astSource: OneSrc(),
            configStore: configStore,
            publicationStore: pubStore,
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(),
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
}
