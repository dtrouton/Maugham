import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class PreviewCompilerTests: XCTestCase {

    var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewCompilerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try await PublishStarter.install(into: tmp, force: false)
    }

    override func tearDown() async throws {
        PublishingStores._resetForTesting()
        try? FileManager.default.removeItem(at: tmp)
    }

    func testPreview_doesNotBumpVersion() async throws {
        // Reads the real premise: tectonic bundled AND its TeX bundle obtainable.
        try await TectonicProbe.requireReady()

        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(
            metadata: .init(title: "Pre", author: "X")))
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C1", mode: .prose, displayText: "A."),
                 .init(pieceID: "p2", title: "C2", mode: .prose, displayText: "B.")]
            }
        }
        let preview = PreviewCompiler(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")
        let result = try await preview.preview(
            format: .pdf, sectionIDs: ["p1"], maxPages: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputPath))
        // No publications written.
        let pubs = try await PublicationStore(projectURL: tmp).load()
        XCTAssertTrue(pubs.isEmpty)
        // Version still 0.1.
        let cfg = try await configStore.load()
        XCTAssertEqual(cfg?.nextVersion, "0.1")
    }

    /// RULING-7 (fix for M7-PB-010): a preview with no publish config is a
    /// FAILURE and must say so — the Result carries the cause in `errors`, so
    /// the tool renders the failed shape instead of completed-with-empty-path.
    func testPreview_withNoConfigReturnsTheCauseAsAnError() async throws {
        let bare = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewNoConfig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bare) }
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] { [] }
        }
        let jobs = CompileJobManager()
        let preview = PreviewCompiler(
            projectURL: bare, astSource: Src(),
            configStore: PublishConfigStore(projectURL: bare),
            jobManager: jobs,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let result = try await preview.preview(format: .epub, sectionIDs: nil, maxPages: nil)
        XCTAssertFalse(result.errors.isEmpty,
                       "the failure must reach the caller as an error, not as "
                       + "success with an empty path")
        XCTAssertTrue(result.errors.first?.message.contains("config") == true,
                      "and it names the real cause — found: "
                      + String(describing: result.errors.first?.message))
        let job = await jobs.allInProgress()
        XCTAssertTrue(job.isEmpty, "the job is terminal either way")
    }

    // MARK: - F5: EMISSION.md auto-refresh (previews are where iteration lives)

    /// A stale EMISSION.md seeded before a preview is refreshed to the
    /// current contract, stamped with the app version the preview was
    /// constructed with — mirroring `CompileOrchestrator`'s refresh.
    func testPreview_refreshesStaleEmissionDoc() async throws {
        let emissionURL = tmp.appendingPathComponent(".maugham/publish/EMISSION.md")
        try "# STALE from an old init\n".write(to: emissionURL, atomically: true, encoding: .utf8)

        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "PreF5", author: "T")))
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C1", mode: .prose, displayText: "A.")]
            }
        }
        let preview = PreviewCompiler(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            jobManager: CompileJobManager(),
            maughamVersion: "9.9.9-previewtest", tectonicVersion: "n/a")
        _ = try await preview.preview(format: .epub, sectionIDs: nil, maxPages: nil)

        let refreshed = try String(contentsOf: emissionURL, encoding: .utf8)
        XCTAssertEqual(refreshed, EmissionContract.renderProjectCopy(appVersion: "9.9.9-previewtest"))
        XCTAssertFalse(refreshed.contains("STALE from an old init"))
    }

    // MARK: - F1: default subset vs. explicit override

    struct ThreePieceSrc: ProjectASTBuilder.Source {
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            [.init(pieceID: "p1", title: "Alpha", mode: .prose, displayText: "First."),
             .init(pieceID: "p2", title: "Bravo", mode: .prose, displayText: "Middle."),
             .init(pieceID: "p3", title: "Charlie", mode: .prose, displayText: "Third.")]
        }
    }

    private func excludeMiddleConfigStore() async throws -> PublishConfigStore {
        let configStore = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig(metadata: .init(title: "Pre", author: "X"))
        cfg.sections["p2"] = .init(include: false)
        try await configStore.save(cfg)
        return configStore
    }

    /// No `section_ids` ⇒ "all *included* sections": the excluded piece is
    /// dropped from the preview body (EPUB path, no tectonic).
    func testPreview_noSectionIDs_subsetsToIncluded() async throws {
        let configStore = try await excludeMiddleConfigStore()
        let preview = PreviewCompiler(
            projectURL: tmp, astSource: ThreePieceSrc(),
            configStore: configStore, jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        _ = try await preview.preview(format: .epub, sectionIDs: nil, maxPages: nil)

        let body = try String(
            contentsOf: tmp.appendingPathComponent(".maugham/publish/build/body.xhtml"),
            encoding: .utf8)
        XCTAssertTrue(body.contains("data-piece-id=\"p1\""))
        XCTAssertTrue(body.contains("data-piece-id=\"p3\""))
        XCTAssertFalse(body.contains("data-piece-id=\"p2\""),
                       "default preview subset must drop the excluded piece")
    }

    /// Explicit `section_ids` is an exploratory override: it may name an
    /// excluded piece, and preview renders it anyway.
    func testPreview_explicitSectionIDs_overridesExclusion() async throws {
        let configStore = try await excludeMiddleConfigStore()
        let preview = PreviewCompiler(
            projectURL: tmp, astSource: ThreePieceSrc(),
            configStore: configStore, jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        _ = try await preview.preview(format: .epub, sectionIDs: ["p2"], maxPages: nil)

        let body = try String(
            contentsOf: tmp.appendingPathComponent(".maugham/publish/build/body.xhtml"),
            encoding: .utf8)
        XCTAssertTrue(body.contains("data-piece-id=\"p2\""),
                      "explicit section_ids override must render the named excluded piece")
        XCTAssertFalse(body.contains("data-piece-id=\"p1\""),
                       "explicit section_ids is an allowlist — unnamed pieces drop out")
    }

    // MARK: - F2: preview a translated edition (parity with compile)

    private struct LangFixture {
        let store: ProjectStore
        let docID: String
        let doc: Document
        let stores: PublishingStores
        let projectURL: URL
    }

    /// Novel project (publish starter installed), starter doc overwritten with
    /// `content` before its first `Document.load` so Bootstrap mints anchors from
    /// real paragraphs; base + `es` publish config wired. Mirrors the coverage-
    /// gate fixture so preview exercises the SAME ProjectStore substitution path.
    private func makeLangFixture(content: String) async throws -> LangFixture {
        let projectURL = try await ProjectFactory.createNovelProject(
            named: "PrevLang-\(UUID().uuidString.prefix(6))", in: tmp)
        let probe = try await ProjectStore.load(from: projectURL)
        let item = try XCTUnwrap(
            ProjectStore.collectDocuments(in: probe.manifest.structure).first)
        let path = try XCTUnwrap(item.path)
        try content.write(
            to: projectURL.appendingPathComponent(path), atomically: true, encoding: .utf8)

        let doc = try await Document.load(
            url: projectURL.appendingPathComponent(path),
            device: "test", session: "s", presenter: nil)
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

        return LangFixture(
            store: store, docID: item.id, doc: doc, stores: stores, projectURL: projectURL)
    }

    private func translate(
        _ fx: LangFixture, paragraphID: String, text: String, sourceHash: String
    ) async throws {
        try await TranslationStore.append(
            TranslationRecord(paragraphId: paragraphID, language: "es",
                              text: text, sourceHash: sourceHash, verbatim: false),
            forDocId: fx.docID, deviceSlug: DeviceSlug.make(from: "test-mac"),
            in: fx.projectURL)
    }

    private func makeLangPreview(_ fx: LangFixture, allowStale: Bool) -> PreviewCompiler {
        PreviewCompiler(
            projectURL: fx.projectURL,
            astSource: ProjectStoreASTSource(
                projectStore: fx.store, language: "es"),
            configStore: fx.stores.configStore, jobManager: fx.stores.jobManager,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a",
            language: "es", allowStale: allowStale)
    }

    /// A fully-translated edition previews with the Spanish text substituted
    /// into the body and the ES `dc:language` folded into the OPF — the exact
    /// edition-parity signal that was impossible before F2.
    func testPreview_language_substitutesTranslatedTextAndDcLanguage() async throws {
        let fx = try await makeLangFixture(content: """
        First paragraph.

        Second paragraph.
        """)
        let ids = fx.doc.sequence
        try await translate(fx, paragraphID: ids[0], text: "Primero.",
                            sourceHash: TranslationHash.hash(fx.doc.paragraphs[ids[0]] ?? ""))
        try await translate(fx, paragraphID: ids[1], text: "Segundo.",
                            sourceHash: TranslationHash.hash(fx.doc.paragraphs[ids[1]] ?? ""))

        let result = try await makeLangPreview(fx, allowStale: false)
            .preview(format: .epub, sectionIDs: nil, maxPages: nil)
        XCTAssertTrue(result.errors.isEmpty, "fully-fresh es preview must not gate: \(result.errors)")

        let body = try String(
            contentsOf: fx.projectURL.appendingPathComponent(".maugham/publish/build/body.xhtml"),
            encoding: .utf8)
        XCTAssertTrue(body.contains("Primero."), "translated text must be substituted")
        XCTAssertFalse(body.contains("First paragraph."), "source text must be replaced")

        // The produced preview .epub's OPF carries the folded es dc:language.
        let epubURL = URL(fileURLWithPath: result.outputPath)
        let opf = unzipEntry(epubURL, entry: "OEBPS/content.opf")
        XCTAssertTrue(opf.contains("<dc:language>es</dc:language>"),
                      "effectiveMetadata must fold dc:language into the preview OPF:\n\(opf)")
    }

    private func unzipEntry(_ archive: URL, entry: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-p", archive.path, entry]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Gate parity: a stale/missing edition blocks the preview without
    /// `allow_stale`, itemizing the exact ¶ids — the same report shape compile
    /// returns.
    func testPreview_language_gateBlocksWithoutAllowStale() async throws {
        let fx = try await makeLangFixture(content: """
        First paragraph.

        Second paragraph.
        """)
        let ids = fx.doc.sequence
        // p0 fresh; p1 left missing (no record).
        try await translate(fx, paragraphID: ids[0], text: "Primero.",
                            sourceHash: TranslationHash.hash(fx.doc.paragraphs[ids[0]] ?? ""))

        let result = try await makeLangPreview(fx, allowStale: false)
            .preview(format: .epub, sectionIDs: nil, maxPages: nil)
        XCTAssertFalse(result.errors.isEmpty, "missing translation must block the preview")
        let message = result.errors.map(\.message).joined(separator: "\n")
        XCTAssertTrue(message.contains("¶\(ids[1])"),
                      "gate error must list the missing ¶id, got: \(message)")
        XCTAssertTrue(message.contains("missing"), message)
    }

    /// The SAME gaps preview clean under `allow_stale`, with the source-text
    /// fallback warnings surfaced.
    func testPreview_language_allowStalePassesWithWarnings() async throws {
        let fx = try await makeLangFixture(content: """
        First paragraph.

        Second paragraph.
        """)
        let ids = fx.doc.sequence
        try await translate(fx, paragraphID: ids[0], text: "Primero.",
                            sourceHash: TranslationHash.hash(fx.doc.paragraphs[ids[0]] ?? ""))

        let result = try await makeLangPreview(fx, allowStale: true)
            .preview(format: .epub, sectionIDs: nil, maxPages: nil)
        XCTAssertTrue(result.errors.isEmpty, "allow_stale must not block: \(result.errors)")
        let message = result.warnings.map(\.message).joined(separator: "\n").lowercased()
        XCTAssertTrue(message.contains("fallback"),
                      "allow_stale preview must itemize source-text fallbacks: \(message)")
    }

    /// Explicit `section_ids` scopes the gate to exactly the previewed pieces.
    /// A two-piece book where A is fully translated and B is an untranslated
    /// stub: a whole-edition es preview blocks (on B), but previewing ONLY A
    /// passes — an exploratory preview of one section isn't blocked by other
    /// untranslated pieces. Previewing ONLY the untranslated B still blocks,
    /// proving explicit ids don't bypass the gate for what they DO render.
    func testPreview_language_explicitSectionScopesGateToRenderedPieces() async throws {
        let fx = try await makeTwoDocLangFixture(
            a: "Alpha paragraph.", b: "Bravo stub paragraph.")
        // Fully translate A; leave B untranslated.
        for id in fx.docA.doc.sequence {
            try await TranslationStore.append(
                TranslationRecord(paragraphId: id, language: "es", text: "Alfa.",
                                  sourceHash: TranslationHash.hash(fx.docA.doc.paragraphs[id] ?? ""),
                                  verbatim: false),
                forDocId: fx.docA.id, deviceSlug: DeviceSlug.make(from: "test-mac"),
                in: fx.projectURL)
        }

        func preview(_ sectionIDs: [String]?) async throws -> PreviewCompiler.Result {
            try await PreviewCompiler(
                projectURL: fx.projectURL,
                astSource: ProjectStoreASTSource(
                    projectStore: fx.store, language: "es"),
                configStore: fx.stores.configStore, jobManager: fx.stores.jobManager,
                maughamVersion: "0.0.0-test", tectonicVersion: "n/a",
                language: "es", allowStale: false
            ).preview(format: .epub, sectionIDs: sectionIDs, maxPages: nil)
        }

        // Whole edition blocks on B.
        let whole = try await preview(nil)
        XCTAssertFalse(whole.errors.isEmpty, "untranslated B must block the whole-edition preview")

        // Preview only A: the untranslated sibling B must not block.
        let onlyA = try await preview([fx.docA.id])
        XCTAssertTrue(onlyA.errors.isEmpty,
                      "previewing only the translated A must not be blocked by B: \(onlyA.errors)")

        // Preview only B: still gates on B's own missing translation.
        let onlyB = try await preview([fx.docB.id])
        XCTAssertFalse(onlyB.errors.isEmpty,
                       "previewing the untranslated B must still gate")
    }

    private struct TwoDocLangFixture {
        let store: ProjectStore
        let docA: (id: String, doc: Document)
        let docB: (id: String, doc: Document)
        let stores: PublishingStores
        let projectURL: URL
    }

    /// Hand-built two-piece novel project (A then B), each loaded through
    /// `Document.load` so Bootstrap mints anchors, wired with a base + `es`
    /// publish config. Mirrors the coverage-gate suite's two-doc fixture.
    private func makeTwoDocLangFixture(a: String, b: String) async throws -> TwoDocLangFixture {
        let projectDir = tmp
            .appendingPathComponent("PrevTwoDoc-\(UUID().uuidString)")
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

        return TwoDocLangFixture(
            store: store, docA: (idA, docA), docB: (idB, docB),
            stores: stores, projectURL: projectDir)
    }
    /// The deliberate other half of the occupied-destination refusal: previews
    /// reuse their filenames by design, so a second preview must keep
    /// OVERWRITING its own prior output rather than refusing.
    func testPreview_overwritesItsOwnPriorOutput() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Twice", author: "X")))
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "A.")]
            }
        }
        let preview = PreviewCompiler(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let one = try await preview.preview(format: .epub, sectionIDs: nil, maxPages: nil)
        XCTAssertTrue(one.errors.isEmpty, "fixture: first preview must succeed")
        let two = try await preview.preview(format: .epub, sectionIDs: nil, maxPages: nil)
        XCTAssertTrue(two.errors.isEmpty,
                      "a second preview overwrites its own output, never refuses "
                      + "— found: \(two.errors.map { $0.message })")
        XCTAssertEqual(two.outputPath, one.outputPath)
    }

    /// **A preview that throws must not leave its job running forever.** The
    /// gate blocks fail the job on their way out; every other exit past
    /// `register` used to be a bare `throw`, and an `.inProgress` job is read by
    /// `ProposalPromotion` as a live compile — so one failed preview would
    /// refuse every approve and revert for the life of the process, naming a
    /// compile that will never end.
    ///
    /// The failure is the disk's own (the rollback idiom this repo already uses
    /// for the same job): with `.maugham/publish` unwritable, the EMISSION
    /// refresh at the head of the preview cannot land. No tectonic, no LaTeX —
    /// the throw is what is under test, not what raised it.
    ///
    /// Disable experiment: drop the `do`/`catch` around `preview`'s body and
    /// this fails on a job still `.inProgress`.
    func testPreview_aThrowPastRegistrationFailsTheJob() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Doomed", author: "X")))
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "A.")]
            }
        }
        let manager = CompileJobManager()
        let preview = PreviewCompiler(
            projectURL: tmp, astSource: Src(),
            configStore: configStore, jobManager: manager,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")

        let fm = FileManager.default
        let publish = tmp.appendingPathComponent(".maugham/publish", isDirectory: true)
        let original = try XCTUnwrap(
            fm.attributesOfItem(atPath: publish.path)[.posixPermissions] as? NSNumber)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: publish.path)
        defer { try? fm.setAttributes([.posixPermissions: original], ofItemAtPath: publish.path) }

        do {
            _ = try await preview.preview(format: .epub, sectionIDs: nil, maxPages: nil)
            XCTFail("expected the unwritable publish directory to refuse the EMISSION refresh")
        } catch {
            // Whatever the disk raised — the point is what the job says after it.
        }

        let running = await manager.allInProgress()
        XCTAssertTrue(running.isEmpty,
                      "a thrown preview leaves no job running — ProposalPromotion "
                      + "reads exactly this and would refuse every promotion")
        let jobs = await manager.all()
        XCTAssertEqual(jobs.count, 1, "fixture: the preview registered exactly one job")
        let status = try XCTUnwrap(jobs.first).status
        guard case .failed = status else {
            return XCTFail("expected .failed, got \(status)")
        }
    }


    // MARK: - Task 7: previews under an imprint

    /// A three-piece project whose imprint `special` allowlists exactly one of
    /// them. `sections` is the half of resolution a preview must honour: the
    /// materialization turns the allowlist into `include: false` entries for
    /// everything it does not name, which is what `excludedSectionIDs` and
    /// `IncludeFilteredASTSource` already read.
    private func imprintConfigStore(
        nextVersion: String? = nil
    ) async throws -> PublishConfigStore {
        let configStore = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig(metadata: .init(title: "Pre", author: "X"))
        cfg.imprints = [
            "special": .init(sections: ["p1": .init()], nextVersion: nextVersion),
            "other": .init()
        ]
        try await configStore.save(cfg)
        return configStore
    }

    private func imprintPreview(
        _ configStore: PublishConfigStore, jobs: CompileJobManager = CompileJobManager()
    ) -> PreviewCompiler {
        PreviewCompiler(
            projectURL: tmp, astSource: ThreePieceSrc(),
            configStore: configStore, jobManager: jobs,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
    }

    /// An imprint's `sections` allowlist reaches the preview body: only the
    /// piece it names renders, and the two it does not are dropped — the same
    /// materialize-then-filter path a compile takes.
    func testPreview_underAnImprint_rendersOnlyItsAllowlist() async throws {
        let configStore = try await imprintConfigStore()
        _ = try await imprintPreview(configStore).preview(
            format: .epub, sectionIDs: nil, maxPages: nil, imprint: "special")

        let body = try String(
            contentsOf: tmp.appendingPathComponent(".maugham/publish/build/body.xhtml"),
            encoding: .utf8)
        XCTAssertTrue(body.contains("data-piece-id=\"p1\""),
                      "the allowlisted piece must render")
        XCTAssertFalse(body.contains("data-piece-id=\"p2\""),
                       "a piece the imprint does not name must be excluded")
        XCTAssertFalse(body.contains("data-piece-id=\"p3\""),
                       "a piece the imprint does not name must be excluded")
    }

    /// The CONTROL for the allowlist: the same config previewed as the book
    /// renders all three. Without it the assertion above could pass on a
    /// preview that renders nothing at all.
    func testPreview_withoutAnImprint_rendersEveryPiece() async throws {
        let configStore = try await imprintConfigStore()
        _ = try await imprintPreview(configStore).preview(
            format: .epub, sectionIDs: nil, maxPages: nil)

        let body = try String(
            contentsOf: tmp.appendingPathComponent(".maugham/publish/build/body.xhtml"),
            encoding: .utf8)
        XCTAssertTrue(body.contains("data-piece-id=\"p1\""))
        XCTAssertTrue(body.contains("data-piece-id=\"p2\""))
        XCTAssertTrue(body.contains("data-piece-id=\"p3\""))
    }

    /// The preview directory is last-write-wins, so an imprint preview that
    /// wore the book's filename would silently replace it. It does not: the
    /// preview's own `filename_template` names no `{imprint}`, so
    /// `OutputFilenameBuilder`'s collision guard inserts `-special` before the
    /// extension — reached because `resolved(imprint:pieceIDs:)` set
    /// `config.imprint` and the builder reads it off the config.
    func testPreview_underAnImprint_namesItsFileWithTheImprint() async throws {
        let configStore = try await imprintConfigStore()
        let book = try await imprintPreview(configStore).preview(
            format: .epub, sectionIDs: nil, maxPages: nil)
        let special = try await imprintPreview(configStore).preview(
            format: .epub, sectionIDs: nil, maxPages: nil, imprint: "special")

        XCTAssertEqual(URL(fileURLWithPath: book.outputPath).lastPathComponent,
                       "preview-0.1-epub.epub")
        XCTAssertEqual(URL(fileURLWithPath: special.outputPath).lastPathComponent,
                       "preview-0.1-epub-special.epub",
                       "an imprint preview must not land on the book's preview")
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.outputPath),
                      "and the book's preview must still be there afterwards")
    }

    /// An imprint's own `next_version` reaches the preview's filename too —
    /// proof the whole resolved config is in play, not just `config.imprint`.
    func testPreview_underAnImprint_takesItsOwnVersion() async throws {
        let configStore = try await imprintConfigStore(nextVersion: "3.7")
        let result = try await imprintPreview(configStore).preview(
            format: .epub, sectionIDs: nil, maxPages: nil, imprint: "special")
        XCTAssertEqual(URL(fileURLWithPath: result.outputPath).lastPathComponent,
                       "preview-3.7-epub-special.epub")
    }

    /// A name this project does not define is a caller's typo: the preview
    /// refuses in the resolver's own sentence, listing what it does know, and
    /// carries the same `unknown_imprint:` excerpt a compile's refusal does.
    func testPreview_unknownImprint_refusesWithTheKnownList() async throws {
        let configStore = try await imprintConfigStore()
        let jobs = CompileJobManager()
        let result = try await imprintPreview(configStore, jobs: jobs).preview(
            format: .epub, sectionIDs: nil, maxPages: nil, imprint: "nope")

        XCTAssertEqual(result.outputPath, "")
        let message = result.errors.map(\.message).joined()
        XCTAssertTrue(message.contains("unknown imprint 'nope'"), "got: \(message)")
        XCTAssertTrue(message.contains("other, special"),
                      "the refusal must list what this project does define, sorted "
                      + "— got: \(message)")
        XCTAssertEqual(result.logExcerpt, "unknown_imprint: nope")
        let running = await jobs.allInProgress()
        XCTAssertTrue(running.isEmpty, "the refusal is terminal for the job")
    }

    /// The refusal's CONTROL: nothing was rendered. A refusal that still wrote
    /// a body would be a compile the caller was told did not happen.
    func testPreview_unknownImprint_rendersNothing() async throws {
        let configStore = try await imprintConfigStore()
        _ = try await imprintPreview(configStore).preview(
            format: .epub, sectionIDs: nil, maxPages: nil, imprint: "nope")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tmp.appendingPathComponent(".maugham/publish/build/body.xhtml").path),
            "an unknown name is refused before a word of the manuscript is read")
    }

    /// Disable experiment (recorded, not automated): deleting the
    /// `loaded.imprints.isEmpty ? [] : …` guard in `run` and passing `[]`
    /// unconditionally leaves the allowlist unmaterialized, and
    /// `testPreview_underAnImprint_rendersOnlyItsAllowlist` goes red on
    /// `data-piece-id="p2"` still being in the body.
    func testPreview_underAnImprint_materializesAgainstTheProjectsPieces() async throws {
        let configStore = try await imprintConfigStore()
        let loaded = try await configStore.load()
        let cfg = try XCTUnwrap(loaded)
        let resolved = try cfg.resolved(
            imprint: "special", pieceIDs: ThreePieceSrc().orderedPieces().map(\.pieceID))
        XCTAssertEqual(resolved.excludedSectionIDs, ["p2", "p3"],
                       "the pieceIDs the preview reads are what turn an allowlist "
                       + "into an exclusion set")
    }

    // MARK: - I1: the preview door validates what it resolved

    /// A project whose imprint `escape` names a template outside the publish
    /// tree. `PublishConfigStore.save` writes what it is given — this is the
    /// hand-edited (or synced) `config.json` the preview door has to meet,
    /// which is exactly why `set_publish_config`'s write-time validation is
    /// not enough.
    private func escapingImprintConfigStore(
        template: String = "../../secret.tex"
    ) async throws -> PublishConfigStore {
        let configStore = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig(metadata: .init(title: "Pre", author: "X"))
        cfg.imprints = ["escape": .init(template: template)]
        try await configStore.save(cfg)
        return configStore
    }

    /// I1 (whole-branch review). `run` resolved the imprint and validated
    /// nothing, so a template that escapes the publish tree reached
    /// `PDFCompiler` — on the path that runs with `replacesExistingOutput:
    /// true`. It is refused now, in the same shape as the unknown-name
    /// refusal, before a file is written.
    func testPreview_underAnImprint_withAnEscapingTemplate_isRefused() async throws {
        let configStore = try await escapingImprintConfigStore()
        let jobs = CompileJobManager()
        let result = try await imprintPreview(configStore, jobs: jobs).preview(
            format: .pdf, sectionIDs: nil, maxPages: nil, imprint: "escape")

        XCTAssertEqual(result.outputPath, "")
        let message = result.errors.map(\.message).joined(separator: "\n")
        XCTAssertTrue(message.contains("template"),
                      "the refusal must name the offending field, got: \(message)")
        XCTAssertTrue(message.contains("..") || message.contains("traversal"),
                      "and say what is wrong with it, got: \(message)")
        // Both fields: the resolved config's top-level `template` (which the
        // imprint replaced) and the imprint layer itself, which resolution
        // leaves in place. One offending path, named wherever it appears.
        XCTAssertEqual(result.logExcerpt,
                       "invalid_config: template, imprints.escape.template")
        let running = await jobs.allInProgress()
        XCTAssertTrue(running.isEmpty, "the refusal is terminal for the job")
    }

    /// The refusal's CONTROL on the disk: nothing was previewed. An EPUB
    /// deliberately, because an EPUB does not typeset through the template at
    /// all — before this door existed the escaping config previewed
    /// SUCCESSFULLY here, writing into `build/preview` under a config no
    /// writer could have saved. The refusal has to come from the validation,
    /// not from a downstream compiler tripping over the bad path.
    func testPreview_underAnImprint_withAnEscapingTemplate_writesNothing() async throws {
        let configStore = try await escapingImprintConfigStore()
        _ = try await imprintPreview(configStore).preview(
            format: .epub, sectionIDs: nil, maxPages: nil, imprint: "escape")

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tmp.appendingPathComponent(PreviewCompiler.previewSubpath).path),
            "an invalid config is refused before anything is rendered")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tmp.appendingPathComponent(".maugham/publish/build/body.xhtml").path),
            "and before a word of the manuscript is emitted")
    }

    /// The CONTROL for the rule itself: a well-formed imprint still previews.
    /// Without it the refusal above could pass on a door that refuses
    /// everything.
    func testPreview_underAWellFormedImprint_stillPreviews() async throws {
        let publish = tmp.appendingPathComponent(".maugham/publish", isDirectory: true)
        let starter = try String(
            contentsOf: publish.appendingPathComponent("template.tex"), encoding: .utf8)
        try starter.write(to: publish.appendingPathComponent("special.tex"),
                          atomically: true, encoding: .utf8)
        let configStore = try await escapingImprintConfigStore(template: "special.tex")

        let result = try await imprintPreview(configStore).preview(
            format: .epub, sectionIDs: nil, maxPages: nil, imprint: "escape")
        XCTAssertTrue(result.errors.isEmpty,
                      "a valid imprint must not be caught by the new door: "
                      + "\(result.errors.map(\.message))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputPath),
                      "no preview at \(result.outputPath)")
    }

    // MARK: - P2 Task 6: a preview renders every body the request names
    //
    // The preview door is the compile door's twin, and `languages:` reaches it
    // the same way: one complete body per tag, the imprint's allowlist over
    // every one of them, the joined identity in the file's NAME (previews are
    // last-write-wins, so two editions sharing one filename would mean the
    // writer's last look silently replaced the other's), and a combination
    // that cannot resolve refused before anything is written.

    /// Three pieces answering with different text per language, so a two-body
    /// preview can be read back body by body. `ThreePieceSrc` above
    /// deliberately is NOT rebindable — this is its language-aware twin, and
    /// the two together are what make "a single body still previews from a
    /// source that has never heard of languages" a fact rather than an
    /// assumption.
    struct ThreePieceRebindableSrc: LanguageRebindableSource {
        let tag: String?
        static func text(for pieceID: String, _ tag: String?) -> String {
            tag.map { "Prevedeni\(pieceID)u\($0)." } ?? "Source\(pieceID)paragraph."
        }
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            ["p1", "p2", "p3"].map {
                .init(pieceID: $0, title: $0.uppercased(), mode: .prose,
                      displayText: Self.text(for: $0, tag))
            }
        }
        func rebound(toLanguage tag: String?) -> ProjectASTBuilder.Source {
            ThreePieceRebindableSrc(tag: tag)
        }
    }

    private func multiLanguagePreview(
        _ configStore: PublishConfigStore,
        languages: [String]?,
        jobs: CompileJobManager = CompileJobManager()
    ) -> PreviewCompiler {
        PreviewCompiler(
            projectURL: tmp, astSource: ThreePieceRebindableSrc(tag: nil),
            configStore: configStore, jobManager: jobs,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a",
            languages: languages)
    }

    private func plainConfigStore() async throws -> PublishConfigStore {
        let configStore = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig(metadata: .init(title: "Pre", author: "X"))
        cfg.metadata.language = "en"
        cfg.languageOverrides = ["sr": .init(metadata: ["title": "Prevedeni"])]
        try await configStore.save(cfg)
        return configStore
    }

    /// The imprint's `sections` allowlist holds for EVERY body, and each body
    /// reads its own text. One `p1` per body and nothing else: an allowlist
    /// applied to the first body only would put three pieces in the second.
    func test_languages_underAnImprint_previewsOnlyItsAllowlistInEveryBody() async throws {
        let configStore = try await imprintConfigStore()
        let result = try await multiLanguagePreview(configStore, languages: ["en", "sr"])
            .preview(format: .epub, sectionIDs: nil, maxPages: nil, imprint: "special")
        XCTAssertTrue(result.errors.isEmpty,
                      "the bilingual imprint preview must not fail: "
                      + "\(result.errors.map(\.message))")

        let epub = URL(fileURLWithPath: result.outputPath)
        XCTAssertEqual(try pieceIDOccurrences(inEPUBAt: epub).sorted(), ["p1", "p1"],
                       "the allowlist holds for both bodies — one p1 each, nothing else")

        let entries = try epubEntryNames(inEPUBAt: epub)
        XCTAssertTrue(entries.contains("OEBPS/section-en-001.xhtml"), "\(entries)")
        XCTAssertTrue(entries.contains("OEBPS/section-sr-001.xhtml"), "\(entries)")
        let en = try epubEntryText("OEBPS/section-en-001.xhtml", inEPUBAt: epub)
        let sr = try epubEntryText("OEBPS/section-sr-001.xhtml", inEPUBAt: epub)
        XCTAssertTrue(en.contains(ThreePieceRebindableSrc.text(for: "p1", nil)),
                      "the source body reads the source text: \(en)")
        XCTAssertTrue(sr.contains(ThreePieceRebindableSrc.text(for: "p1", "sr")),
                      "and the sr body reads its own: \(sr)")
    }

    /// The preview directory is last-write-wins by design, so a bilingual
    /// preview must not land on the source preview's filename. The template
    /// names no `{language}`, so the collision guard inserts the joined
    /// identity before the extension — `preview-0.1-pdf-en+sr.pdf`.
    func test_languages_theBilingualPreviewFileCarriesTheJoinedIdentity() async throws {
        // Reads the real premise: tectonic bundled AND its TeX bundle obtainable.
        try await TectonicProbe.requireReady()
        let configStore = try await plainConfigStore()

        let source = try await multiLanguagePreview(configStore, languages: nil)
            .preview(format: .pdf, sectionIDs: nil, maxPages: nil)
        XCTAssertEqual(URL(fileURLWithPath: source.outputPath).lastPathComponent,
                       "preview-0.1-pdf.pdf",
                       "fixture: the source preview keeps its unsuffixed name")

        let both = try await multiLanguagePreview(configStore, languages: ["en", "sr"])
            .preview(format: .pdf, sectionIDs: nil, maxPages: nil)
        XCTAssertTrue(both.errors.isEmpty, "\(both.errors.map(\.message))")
        XCTAssertEqual(URL(fileURLWithPath: both.outputPath).lastPathComponent,
                       "preview-0.1-pdf-en+sr.pdf")
        XCTAssertNotEqual(both.outputPath, source.outputPath,
                          "a bilingual preview must not overwrite the source preview")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.outputPath),
                      "and the source preview is still there")
    }

    /// The compilers' `language:` is the set's SINGLE tag, never its identity:
    /// a bilingual document belongs to no one tongue's stylesheet, so it takes
    /// the base one with a suffixed file sitting right there.
    func test_languages_theBilingualPreviewTakesTheBaseStylesheet() async throws {
        let publish = tmp.appendingPathComponent(".maugham/publish", isDirectory: true)
        try "/* sronly */".write(to: publish.appendingPathComponent("styles.sr.css"),
                                 atomically: true, encoding: .utf8)
        let configStore = try await plainConfigStore()

        let both = try await multiLanguagePreview(configStore, languages: ["en", "sr"])
            .preview(format: .epub, sectionIDs: nil, maxPages: nil)
        XCTAssertTrue(both.errors.isEmpty, "\(both.errors.map(\.message))")
        let css = try epubEntryText(
            "OEBPS/styles.css", inEPUBAt: URL(fileURLWithPath: both.outputPath))
        XCTAssertFalse(css.contains("sronly"),
                       "a bilingual preview takes the BASE stylesheet: \(css)")

        // The control: ONE translated body does resolve its own, so the base
        // above is a decision rather than a missing file.
        let sr = try await multiLanguagePreview(configStore, languages: ["sr"])
            .preview(format: .epub, sectionIDs: nil, maxPages: nil)
        XCTAssertTrue(sr.errors.isEmpty, "\(sr.errors.map(\.message))")
        let srCSS = try epubEntryText(
            "OEBPS/styles.css", inEPUBAt: URL(fileURLWithPath: sr.outputPath))
        XCTAssertTrue(srCSS.contains("sronly"),
                      "one translated body resolves styles.sr.css: \(srCSS)")
    }

    /// A combination that cannot resolve is a caller's typo, refused with the
    /// same `.failed`-shaped Result the unknown-imprint refusal returns — and
    /// refused BEFORE anything is written, because nothing about it needed the
    /// manuscript.
    ///
    /// Disable experiment: delete the `LanguageSet` construction and its
    /// `catch` from `run`, and this fails on `result.errors` being empty with
    /// a preview file on disk.
    func test_languages_anInvalidSetRefusesBeforeAnythingIsWritten() async throws {
        let configStore = try await plainConfigStore()
        let jobs = CompileJobManager()
        // "en" IS this book's own language, so "source" and "en" name the same
        // body — a duplicate, which `LanguageSet` refuses.
        let result = try await multiLanguagePreview(
            configStore, languages: ["source", "en"], jobs: jobs)
            .preview(format: .epub, sectionIDs: nil, maxPages: nil)

        XCTAssertFalse(result.errors.isEmpty, "a duplicate body must refuse the preview")
        XCTAssertTrue(result.logExcerpt.hasPrefix("invalid_languages: "),
                      "got: \(result.logExcerpt)")
        XCTAssertTrue(result.outputPath.isEmpty, "got: \(result.outputPath)")

        let previewDir = tmp.appendingPathComponent(
            PreviewCompiler.previewSubpath, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewDir.path),
                       "nothing was previewed — not even the output directory")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tmp.appendingPathComponent(".maugham/publish/build/body.xhtml").path),
            "and not a word of the manuscript was emitted")

        let running = await jobs.allInProgress()
        XCTAssertTrue(running.isEmpty, "the job is terminal")
    }

    /// The CONTROL for the refusal above: a well-formed set still previews.
    /// Without it the refusal could pass on a door that refuses every
    /// `languages:` request.
    func test_languages_aWellFormedSetStillPreviews() async throws {
        let configStore = try await plainConfigStore()
        let result = try await multiLanguagePreview(configStore, languages: ["en", "sr"])
            .preview(format: .epub, sectionIDs: nil, maxPages: nil)
        XCTAssertTrue(result.errors.isEmpty,
                      "a valid set must not be caught by the new door: "
                      + "\(result.errors.map(\.message))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputPath),
                      "no preview at \(result.outputPath)")
    }

    /// The gate runs once per TRANSLATED body, and reports EVERY blocked tongue
    /// rather than the first: a writer who has to preview once per language to
    /// learn the second one's gaps is being sent round the loop for nothing.
    ///
    /// Three bodies — the source (never gated), a covered `sr`, and an `es` with
    /// no records at all. The refusal must name `es` and must NOT name `sr`,
    /// which is what makes it a per-tongue verdict rather than a blanket one.
    func test_languages_theGateJudgesEachTongueAndNamesTheOneThatFailed() async throws {
        let fx = try await makeLangFixture(content: """
        First paragraph.

        Second paragraph.
        """)
        for id in fx.doc.sequence {
            try await TranslationStore.append(
                TranslationRecord(
                    paragraphId: id, language: "sr", text: "Prevedeni.",
                    sourceHash: TranslationHash.hash(fx.doc.paragraphs[id] ?? ""),
                    verbatim: false),
                forDocId: fx.docID, deviceSlug: DeviceSlug.make(from: "test-mac"),
                in: fx.projectURL)
        }

        let result = try await PreviewCompiler(
            projectURL: fx.projectURL,
            astSource: ProjectStoreASTSource(projectStore: fx.store),
            configStore: fx.stores.configStore, jobManager: fx.stores.jobManager,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a",
            languages: ["en", "sr", "es"]
        ).preview(format: .epub, sectionIDs: nil, maxPages: nil)

        XCTAssertFalse(result.errors.isEmpty, "an untranslated tongue must block")
        let message = result.errors.map(\.message).joined(separator: "\n")
        XCTAssertTrue(message.contains("[es]"),
                      "the blocked tongue must be named: \(message)")
        XCTAssertFalse(message.contains("[sr]"),
                       "and a tongue that PASSED must not be: \(message)")
        XCTAssertTrue(result.outputPath.isEmpty, "got: \(result.outputPath)")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fx.projectURL
                    .appendingPathComponent(PreviewCompiler.previewSubpath).path),
            "a blocked preview writes no output")
    }

    /// Its control: cover `es` too and the same three-body preview lands.
    /// Without it the refusal above could pass on a preview that had started
    /// refusing every multi-tongue request.
    func test_languages_everyTongueCovered_previewsAllThreeBodies() async throws {
        let fx = try await makeLangFixture(content: """
        First paragraph.

        Second paragraph.
        """)
        for tag in ["sr", "es"] {
            for id in fx.doc.sequence {
                try await TranslationStore.append(
                    TranslationRecord(
                        paragraphId: id, language: tag, text: "Prevedenina\(tag).",
                        sourceHash: TranslationHash.hash(fx.doc.paragraphs[id] ?? ""),
                        verbatim: false),
                    forDocId: fx.docID, deviceSlug: DeviceSlug.make(from: "test-mac"),
                    in: fx.projectURL)
            }
        }

        let result = try await PreviewCompiler(
            projectURL: fx.projectURL,
            astSource: ProjectStoreASTSource(projectStore: fx.store),
            configStore: fx.stores.configStore, jobManager: fx.stores.jobManager,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a",
            languages: ["en", "sr", "es"]
        ).preview(format: .epub, sectionIDs: nil, maxPages: nil)

        XCTAssertTrue(result.errors.isEmpty,
                      "a fully covered set must preview: \(result.errors.map(\.message))")
        let entries = try epubEntryNames(inEPUBAt: URL(fileURLWithPath: result.outputPath))
        for tag in ["en", "sr", "es"] {
            XCTAssertTrue(entries.contains("OEBPS/section-\(tag)-001.xhtml"),
                          "body '\(tag)' is missing from \(entries)")
        }
    }
}
