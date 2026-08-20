import XCTest
import MaughamCore
@testable import Maugham

/// **The designer's production wiring**: the closures
/// `DesignerOrchestrator.Environment.production` hands the run, driven against
/// a real project on disk.
///
/// `DesignerOrchestratorTests` proves the round's control flow with every
/// closure a spy; this file proves the closures themselves — that a briefing
/// carries the writer's own doctrine and what the book actually contains, that
/// the designer is READ and never minted, that a report lands as a staged
/// proposal with its sample result recorded on it, and that a window closing
/// takes the project's stores with it.
@MainActor
final class DesignerEnvironmentTests: XCTestCase {

    // MARK: - Harness

    private struct Harness {
        let projectURL: URL
        let projectStore: ProjectStore
        let documentStore: DocumentStore
        let environment: DesignerOrchestrator.Environment
    }

    /// A one-chapter project whose prose exercises several element kinds, with
    /// a live publish tree — the two premises `briefRound` refuses without.
    private func makeHarness(
        publishTree: Bool = true, manuscript: Bool = true
    ) async throws -> Harness {
        let root = try makeRoot()
        let path = "manuscript/c1.md"
        if manuscript {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("manuscript"),
                withIntermediateDirectories: true)
            try """
            # The Fog

            The fog came in *softly*.

            > Nobody spoke.
            """.write(to: root.appendingPathComponent(path),
                      atomically: true, encoding: .utf8)
        }

        let manifest = ProjectManifest(
            type: .novel, title: "Design", author: "A",
            created: Date(), modified: Date(),
            structure: manuscript
                ? [StructureItem(id: "doc-1", title: "Chapter 1",
                                 type: .document, path: path)]
                : [],
            research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: root.appendingPathComponent("project.maugham.json"))

        if publishTree { try await installPublishTree(in: root) }

        let projectStore = try await ProjectStore.load(from: root)
        let documentStore = try await DocumentStore.open(url: root)
        projectStore.documentStore = documentStore

        if manuscript {
            // A real `Document.load` — the `¶id`-minting path — so the AST the
            // census walks is the one a compile would see (ADR 0018's open-doc
            // branch), not a raw file read.
            let doc = try await Document.load(
                url: root.appendingPathComponent(path),
                device: "test", session: "s", presenter: nil)
            documentStore.register(document: doc, for: path)
        }

        return Harness(
            projectURL: root,
            projectStore: projectStore,
            documentStore: documentStore,
            environment: environment(store: projectStore, projectURL: root))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesignerEnv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The three files `PublishStarter.isInitialized` and the briefing's
    /// template section care about. Hand-written rather than copied out of the
    /// bundle so the fixture says exactly what it is testing.
    private func installPublishTree(in root: URL) async throws {
        let publish = root.appendingPathComponent(".maugham/publish", isDirectory: true)
        try FileManager.default.createDirectory(at: publish, withIntermediateDirectories: true)
        try "\\documentclass{book}\n"
            .write(to: publish.appendingPathComponent("template.tex"),
                   atomically: true, encoding: .utf8)
        try "body { font-family: serif; }\n"
            .write(to: publish.appendingPathComponent("styles.css"),
                   atomically: true, encoding: .utf8)
        // Through the store, so the fixture's config.json is the real shape
        // rather than a hand-rolled guess at the key names.
        try await PublishConfigStore(projectURL: root).save(PublishConfig())
    }

    private func environment(
        store: ProjectStore, projectURL: URL
    ) -> DesignerOrchestrator.Environment {
        DesignerOrchestrator.Environment.production(
            store: store,
            projectURL: projectURL,
            preferences: UserPreferences(
                defaults: UserDefaults(suiteName: "DesignerEnvTests-\(UUID().uuidString)")!),
            onRunEnded: { _ in })
    }

    private func stageContext(
        round: Int = 1, designerName: String = "Ada Vance", language: String? = nil
    ) -> DesignerOrchestrator.StageContext {
        DesignerOrchestrator.StageContext(
            runId: "run-1", round: round, designerName: designerName, language: language)
    }

    private func report(
        spec: String = "## The proposal\n\nWider margins.",
        files: [DesignerReport.ProposedFile] = [
            .init(path: "template.tex", content: "\\documentclass{memoir}\n"),
        ]
    ) -> DesignerReport {
        DesignerReport(specMarkdown: spec, files: files)
    }

    private func source(at relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - The briefing

    /// The whole gather: who the designer is, the writer's declared look, what
    /// the book contains, what the samples will show, and the live templates.
    func test_theBriefingCarriesTheDoctrineTheCensusAndTheLiveTemplates() async throws {
        let harness = try await makeHarness()
        let statement = try await harness.projectStore.createStatement(
            kind: .visualLanguage, scope: .project)
        try await harness.projectStore.appendToStatement(
            "Warm paper, a deep gutter.", to: statement, session: "s")

        let gathered = await harness.environment.briefRound(nil, nil)
        let inputs = try XCTUnwrap(gathered)

        XCTAssertEqual(inputs.designerName, ProductionRole.presetDesigner.effectiveName)
        XCTAssertNotNil(inputs.roleBrief)
        XCTAssertTrue(inputs.visualLanguageText?.contains("deep gutter") == true,
                      "the writer's declared look is the brief")
        // The census walks the same AST the sample will render.
        XCTAssertTrue(inputs.census.kinds.contains(.blockquote))
        XCTAssertTrue(inputs.census.kinds.contains(.emphasis))
        XCTAssertEqual(inputs.selection.pieceIds, ["doc-1"])
        XCTAssertFalse(inputs.selection.demonstrates.isEmpty)

        let templatePaths = inputs.templateFiles.map(\.path).sorted()
        XCTAssertEqual(templatePaths, ["styles.css", "template.tex"],
                       "config.json is compile configuration, not a design file")
        XCTAssertTrue(
            inputs.templateFiles.first { $0.path == "template.tex" }?
                .content.contains("documentclass") == true)
        XCTAssertNil(inputs.language)
        XCTAssertNil(inputs.editionBriefText)

        await harness.documentStore.close()
    }

    /// A design round has to be a round about SOMETHING. Both refusals are
    /// `nil` — the orchestrator's "not a run" — rather than a failed run the
    /// desk would draw a red line under.
    func test_theRoundRefusesAProjectWithNoLiveTemplatesToRevise() async throws {
        let harness = try await makeHarness(publishTree: false)
        let inputs = await harness.environment.briefRound(nil, nil)
        XCTAssertNil(inputs)
        await harness.documentStore.close()
    }

    func test_theRoundRefusesAProjectWithNoBookInItYet() async throws {
        let harness = try await makeHarness(manuscript: false)
        let inputs = await harness.environment.briefRound(nil, nil)
        XCTAssertNil(inputs)
        await harness.documentStore.close()
    }

    /// **The identity is READ, never minted** (`ProjectStore.designerRole()`'s
    /// own rule): a gather that stamped a designer row into the manifest would
    /// shift `modified` and reshuffle the project wall because somebody asked
    /// who the designer was. Pinned bytes-unchanged rather than by asserting
    /// the absence of one field, so a mint through any other path fails too.
    func test_gatheringTheBriefingMintsNoDesigner() async throws {
        let harness = try await makeHarness()
        let manifestURL = harness.projectURL.appendingPathComponent("project.maugham.json")
        let before = try Data(contentsOf: manifestURL)

        let gathered = await harness.environment.briefRound(nil, nil)
        let inputs = try XCTUnwrap(gathered)

        XCTAssertEqual(try Data(contentsOf: manifestURL), before,
                       "reading the designer wrote to the manifest")
        XCTAssertTrue(harness.projectStore.manifest.productionRoles.isEmpty)
        XCTAssertEqual(inputs.designerName, ProductionRole.presetDesigner.effectiveName,
                       "the preset lives in the merge, not on disk")

        await harness.documentStore.close()
    }

    /// An edition round is briefed on that edition's doctrine, and says which
    /// edition it is for.
    func test_anEditionRoundCarriesThatEditionsBrief() async throws {
        let harness = try await makeHarness()
        let brief = try await harness.projectStore.createStatement(
            kind: .editionBrief("es"), scope: .project)
        try await harness.projectStore.appendToStatement(
            "Comillas latinas «así».", to: brief, session: "s")

        let gathered = await harness.environment.briefRound(nil, "es")
        let inputs = try XCTUnwrap(gathered)

        XCTAssertEqual(inputs.language, "es")
        XCTAssertTrue(inputs.editionBriefText?.contains("Comillas") == true)

        await harness.documentStore.close()
    }

    func test_theWritersOwnWordsForTheRoundRideTheBriefing() async throws {
        let harness = try await makeHarness()
        let gathered = await harness.environment.briefRound("Square album, warmer paper.", nil)
        let inputs = try XCTUnwrap(gathered)
        XCTAssertEqual(inputs.direction, "Square album, warmer paper.")
        await harness.documentStore.close()
    }

    // MARK: - Staging

    /// The round's one write: the report becomes a pending proposal on disk,
    /// and its sample compile's outcome is recorded ON that proposal.
    ///
    /// The fixture has no publish tree, so the sample fails at
    /// `SampleCompiler.assembleScratch` — no tectonic involved, and that is the
    /// point: **spec §6's property is that a failed sample rides the proposal
    /// and the round still ends well**, so the writer stands at a gate showing
    /// the spec and the compile error rather than nothing at all.
    func test_stagingWritesTheProposalAndRecordsAFailedSampleOnIt() async throws {
        let harness = try await makeHarness(publishTree: false)

        let outcome = await harness.environment.stage(report(), stageContext())

        let proposalId = try XCTUnwrap(outcome.proposalId)
        XCTAssertNil(outcome.rejection, "a sample that would not compile is not a refusal")
        XCTAssertEqual(outcome.filesStaged, 1)
        guard case .failed(let sentence)? = outcome.sample else {
            return XCTFail("the sample's outcome rides the round: \(String(describing: outcome.sample))")
        }
        XCTAssertFalse(sentence.isEmpty)

        let stored = try DesignProposalStore(projectURL: harness.projectURL).load(id: proposalId)
        XCTAssertEqual(stored.status, .pending)
        XCTAssertEqual(stored.designerName, "Ada Vance")
        XCTAssertEqual(stored.round, 1)
        XCTAssertEqual(stored.filePaths, ["template.tex"])
        XCTAssertEqual(stored.sampleResult, outcome.sample,
                       "the outcome the round reports is the one written down")

        await harness.documentStore.close()
    }

    /// The staged files are real files under the proposal, not just a list of
    /// paths — Task 8's promotion copies them from there.
    func test_theStagedFilesAreOnDiskUnderTheProposal() async throws {
        let harness = try await makeHarness(publishTree: false)
        let outcome = await harness.environment.stage(
            report(files: [.init(path: "partials/dropcaps.tex", content: "\\lettrine")]),
            stageContext())
        let proposalId = try XCTUnwrap(outcome.proposalId)
        let staged = DesignProposalStore(projectURL: harness.projectURL)
            .proposalDir(id: proposalId)
            .appendingPathComponent("files/partials/dropcaps.tex")
        XCTAssertEqual(try String(contentsOf: staged, encoding: .utf8), "\\lettrine")
        await harness.documentStore.close()
    }

    // MARK: - The window going away

    /// **Every capture is weak.** SwiftUI never dismantles a closed window's
    /// view graph, so an environment holding the project's stores strongly
    /// keeps the whole project in memory with nothing on screen. The stores are
    /// built inside a function that returns only the environment, so when it
    /// returns the closures are the only thing that could still be holding
    /// them.
    ///
    /// The refusals below are the control: a closure that answered normally
    /// after the window went away would prove only that nothing crashed.
    func test_theClosuresLetTheProjectWindowGo() async throws {
        let box = WeakStoreBox()
        let environment = try await makeEnvironmentAndForgetItsStores(box)

        XCTAssertNil(box.store,
                     "a closure is holding the ProjectStore strongly — a closed "
                     + "window would keep the whole project alive")

        // A round refuses rather than running against a window that is gone…
        let inputs = await environment.briefRound(nil, nil)
        XCTAssertNil(inputs)
        // …and a report that arrives afterwards is refused with a sentence, not
        // silently dropped and not staged into a project nobody is looking at.
        let outcome = await environment.stage(report(), stageContext())
        XCTAssertNil(outcome.proposalId)
        XCTAssertNotNil(outcome.rejection)
    }

    private final class WeakStoreBox {
        weak var store: ProjectStore?
    }

    private func makeEnvironmentAndForgetItsStores(
        _ box: WeakStoreBox
    ) async throws -> DesignerOrchestrator.Environment {
        let harness = try await makeHarness()
        box.store = harness.projectStore
        await harness.documentStore.close()
        return harness.environment
    }

    // MARK: - The teardown census

    /// The designer's half of the wiring census. The paired-count half — every
    /// window-ending path, all three orchestrators — lives in
    /// `TranslatorEnvironmentTests`; what is here is the claim this file owns:
    /// the round is REPORTED with the two things it produced, so a staged round
    /// whose sample failed does not read like one whose pages compiled.
    func test_theFinishedRoundIsReportedWithItsProposalAndItsSample() throws {
        func record(_ outcome: DesignerOrchestrator.RunSummary.Outcome) -> String {
            ProjectWindow.designRunRecord(
                DesignerOrchestrator.RunSummary(
                    runId: "run-1", round: 1, language: nil, at: Date(), outcome: outcome))
        }

        let compiled = record(.staged(.init(
            proposalId: "prop-1", filesStaged: 2,
            sample: .pages(path: "/tmp/sample.pdf"))))
        XCTAssertTrue(compiled.contains("prop-1"))
        XCTAssertTrue(compiled.contains("/tmp/sample.pdf"))

        let pageless = record(.staged(.init(
            proposalId: "prop-1", filesStaged: 2,
            sample: .failed(error: "! Undefined control sequence"))))
        XCTAssertTrue(pageless.contains("prop-1"))
        XCTAssertTrue(pageless.contains("Undefined control sequence"),
                      "a round whose pages did not compile still ended well — "
                      + "the record has to say so, or the two are indistinguishable")
        XCTAssertNotEqual(compiled, pageless)

        XCTAssertTrue(record(.staged(.init(rejection: "the disk refused")))
            .contains("the disk refused"))
        XCTAssertEqual(record(.cancelled), "cancelled")
    }

    /// The designer is owned, wired and released by the window — the tokens
    /// nothing else in the app would miss, since the loop is headless until P4
    /// gives it a run verb.
    func test_theWindowOwnsWiresAndReleasesTheDesigner() throws {
        let window = try source(at: "Maugham/Views/ProjectWindow.swift")
        for token in ["DesignerOrchestrator()", "designer.detach()",
                      "designer.configure(", "designer: designer",
                      "designer.updateModel("] {
            XCTAssertTrue(window.contains(token),
                          "ProjectWindow is missing \(token) — without it the "
                          + "designer is unwired, unmounted, or outlives the "
                          + "window that started it")
        }
        XCTAssertFalse(window.contains("designer.notARealVerb("),
                       "the scan reads the file rather than always answering true")
    }
}
