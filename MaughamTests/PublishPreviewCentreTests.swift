import XCTest
import AppKit
import SwiftUI
import PDFKit
import Observation
import MaughamCore
@testable import Maugham

/// **Publish's centre is the book** (shell-finish stage 3b Task 5, spec §4's
/// Publish column, and Denver's recorded decision: the most recent compiled PDF,
/// the SAME preview for a piece subject, degrading when nothing has been
/// compiled).
///
/// Three things are under test and they need different instruments:
///
/// - **The resolver.** `PublishPreviewResolver` walks the catalog from the TAIL
///   (`PublicationStore.load()` is ascending `compiledAt`) and answers with the
///   first row it can actually put on screen. Both of its guards are about facts
///   on disk — a row can outlive its file (`ExportsListView`'s Delete removes the
///   file and never the JSONL), and an unknown format decodes to `.pdf` — so
///   these tests write real catalogs and real PDFs.
/// - **The rule.** `ProjectWindow.publishPreviewCentre` is a static over
///   `(persona, resolution)`, so it is assertable with no window at all. It
///   takes NO subject, which is Denver's decision made structural rather than
///   asserted case by case.
/// - **The shape.** The preview is a THIRD layer of `manuscriptEditor`'s
///   `ZStack`, above altitude and above the host — never a new `editorPane` arm,
///   for the reason stage 3a recorded: two ViewBuilder branches are two view
///   identities and `EditorHost.onDisappear` is `doc.close()` +
///   `unregister(path:)` + `loads.abandon()`. The mounted tests count the host's
///   lifetimes across a preview ↔ editor ↔ altitude round trip, and the source
///   census is the bridge from the probe's spelling to production's.
///
/// **`PublishingStores.sharedFor` is a leaking singleton** — every test here
/// resets it in `setUp`/`tearDown`, or a catalog written by one case is the
/// answer another case gets.
@MainActor
final class PublishPreviewCentreTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // This suite mounts `EditorHost`, which styles text through production
        // typography (the fontd cold-start window, CLAUDE.md).
        FontWarmup.ensure()
    }

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []
    private var defaultsSuites: [String] = []

    override func setUp() async throws {
        temp = TempDirectory()
        PublishingStores._resetForTesting()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        for suite in defaultsSuites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        defaultsSuites.removeAll()
        PublishingStores._resetForTesting()
        temp.cleanup()
        temp = nil
    }

    // MARK: - The resolver

    /// **Compared by `publicationID`, not by value.** A `Publication` that has
    /// been through the catalog is not `==` the one that went in: JSONL encodes
    /// `compiled_at` at whole-second resolution, so the decoded row differs from
    /// the appended one in the field that orders the whole file. The id is the
    /// catalog's own identity and is exactly what "this row and not that one"
    /// means here.
    private func assertReady(_ resolution: PublishPreviewResolution,
                             is expected: Publication,
                             _ message: String,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        guard let shown = resolution.publication else {
            XCTFail("expected the book, got \(resolution) — \(message)",
                    file: file, line: line)
            return
        }
        XCTAssertEqual(shown.publicationID, expected.publicationID,
                       "showing v\(shown.version), expected v\(expected.version) "
                       + "— \(message)", file: file, line: line)
    }

    /// **The latest is the LAST**, because the catalog is ascending `compiledAt`
    /// — the same fact `ListPublicationsTool` reaches for with `suffix(limit)`.
    /// Three rows, written oldest-first, and the newest is what the writer sees.
    func test_theNewestCompiledPDFIsWhatTheCentreShows() async throws {
        let project = try makeProject()
        let store = PublicationStore(projectURL: project)
        try await append(to: store, in: project, version: "0.1", minutesAgo: 30)
        try await append(to: store, in: project, version: "0.2", minutesAgo: 20)
        let newest = try await append(to: store, in: project, version: "0.3", minutesAgo: 10)

        let resolution = await PublishPreviewResolver.latestReadablePDF(
            store: store, projectURL: project)

        assertReady(resolution, is: newest,
                    "the catalog is ascending, so the writer's most recent "
                    + "compile is its tail — not its head")
    }

    /// **An EPUB is not the book this column can draw.** The newest row is an
    /// EPUB and the walk keeps going rather than stopping on it.
    func test_theWalkPassesAnEpubAndKeepsLookingForAPDF() async throws {
        let project = try makeProject()
        let store = PublicationStore(projectURL: project)
        let pdf = try await append(to: store, in: project, version: "0.1", minutesAgo: 20)
        _ = try await append(to: store, in: project, version: "0.2",
                             format: .epub, minutesAgo: 10)

        let resolution = await PublishPreviewResolver.latestReadablePDF(
            store: store, projectURL: project)

        assertReady(resolution, is: pdf,
                    "PDFKit cannot draw an EPUB; the newest row this column "
                    + "can show is the PDF underneath it")
    }

    /// **A row outlives its file**, which is not a corner case: `ExportsListView`'s
    /// Delete removes the file and never the JSONL, so the newest row in a
    /// working writer's catalog is routinely one whose PDF is gone. The walk
    /// steps past it to the next-newest readable one.
    func test_aRowWhoseFileWasDeletedIsWalkedPastToTheNextNewest() async throws {
        let project = try makeProject()
        let store = PublicationStore(projectURL: project)
        let older = try await append(to: store, in: project, version: "0.1", minutesAgo: 20)
        let newer = try await append(to: store, in: project, version: "0.2", minutesAgo: 10)
        try FileManager.default.removeItem(
            at: project.appendingPathComponent(newer.outputPath))

        let resolution = await PublishPreviewResolver.latestReadablePDF(
            store: store, projectURL: project)

        assertReady(resolution, is: older,
                    "the newest row has no file behind it — a centre column "
                    + "built on it would draw an empty PDFView")
    }

    /// **And a file that is not a PDF at all.** An unknown `format` decodes to
    /// `.pdf` (ADR 0015's forward-tolerance, `PublishConfig.Format`), so the
    /// format field alone is not enough: the file must open. Written as bytes
    /// that are not a PDF at a `.pdf` path, which is exactly what a newer
    /// build's third output format would leave behind.
    func test_aRowWhoseFileIsNotReallyAPDFIsWalkedPast() async throws {
        let project = try makeProject()
        let store = PublicationStore(projectURL: project)
        let real = try await append(to: store, in: project, version: "0.1", minutesAgo: 20)
        let fake = try await append(to: store, in: project, version: "0.2", minutesAgo: 10)
        try "this is not a PDF".write(
            to: project.appendingPathComponent(fake.outputPath),
            atomically: true, encoding: .utf8)

        let resolution = await PublishPreviewResolver.latestReadablePDF(
            store: store, projectURL: project)

        assertReady(resolution, is: real,
                    "`format == .pdf` is a decoded field and an unknown "
                    + "format decodes to it — so the file has to open, not "
                    + "merely be claimed")
    }

    /// Nothing compiled at all: the empty catalog. This is the degrade Denver
    /// asked for, and the centre falls back to altitude.
    func test_anEmptyCatalogIsNothingCompiled() async throws {
        let project = try makeProject()
        let store = PublicationStore(projectURL: project)

        let resolution = await PublishPreviewResolver.latestReadablePDF(
            store: store, projectURL: project)

        XCTAssertEqual(resolution, .nothingCompiled)
    }

    /// Every row's file gone: the same answer as an empty catalog, reached the
    /// long way. The contract is "or to nil when none remains".
    func test_everyRowsFileGoneIsAlsoNothingCompiled() async throws {
        let project = try makeProject()
        let store = PublicationStore(projectURL: project)
        for (index, version) in ["0.1", "0.2"].enumerated() {
            let pub = try await append(to: store, in: project, version: version,
                                       minutesAgo: 20 - index * 5)
            try FileManager.default.removeItem(
                at: project.appendingPathComponent(pub.outputPath))
        }

        let resolution = await PublishPreviewResolver.latestReadablePDF(
            store: store, projectURL: project)

        XCTAssertEqual(resolution, .nothingCompiled,
                       "the walk ran off the end — the centre degrades to "
                       + "altitude rather than drawing a card about a file that "
                       + "is not there")
    }

    /// **An absolute `output_path` resolves as itself.** `Publication.outputPath`
    /// is documented relative to the project root, and `PublicationTools` carries
    /// the absolute-prefix branch for the records that are not — so the resolver
    /// shares that idiom rather than assuming.
    func test_anAbsoluteOutputPathIsResolvedAsItself() async throws {
        let project = try makeProject()
        let outside = temp.url.appendingPathComponent("elsewhere.pdf")
        try Self.writePDF(at: outside)
        let store = PublicationStore(projectURL: project)
        let pub = Self.publication(version: "0.1", outputPath: outside.path,
                                   compiledAt: Date())
        try await store.append(pub)

        let resolution = await PublishPreviewResolver.latestReadablePDF(
            store: store, projectURL: project)

        assertReady(resolution, is: pub,
                    "an absolute path is resolved as itself")
    }

    /// **"Unreadable" is never presented as "empty"** (RULING-7's shape, and the
    /// reason this resolver answers with a reason rather than an optional).
    ///
    /// Today `PublicationStore.load()` is the lenient `JSONLAppendStore.load()`,
    /// which reads an unreadable-yet-present file as an empty list, so nothing in
    /// production reaches this arm — it is driven through the loader seam
    /// instead. A branch already on `origin/main` makes `load()` throw a named
    /// `PublicationStore.ReadError` for exactly this fact; when it merges, this
    /// test is what says the reconcile kept the two answers apart.
    func test_anUnreadableCatalogIsNotTheSameAnswerAsAnEmptyOne() async {
        struct Unreadable: Error {}

        let unreadable = await PublishPreviewResolver.latestReadablePDF(
            in: temp.url, loading: { throw Unreadable() })
        let empty = await PublishPreviewResolver.latestReadablePDF(
            in: temp.url, loading: { [] })

        XCTAssertEqual(unreadable, .unreadableCatalog(reason: Unreadable().localizedDescription),
                       "…carrying what the failure said, so a surface that "
                       + "grows copy for this has the sentence")
        XCTAssertEqual(empty, .nothingCompiled)
        XCTAssertNotEqual(
            unreadable, empty,
            "a catalog that exists and cannot be read is a DIFFERENT fact from "
            + "a project that has never been compiled — collapsing them is how "
            + "a writer is told their book was never made")
    }

    /// Both non-`ready` answers degrade the centre the same way — to altitude —
    /// and that is deliberate: the reason is kept in the value for the copy that
    /// will need it, not spent on a second centre-column surface.
    func test_bothDegradesLeaveTheCentreToAltitude() {
        for resolution: PublishPreviewResolution in [.nothingCompiled, Self.unreadable] {
            XCTAssertNil(
                ProjectWindow.publishPreviewCentre(persona: .publish,
                                                   preview: resolution),
                "\(resolution): with nothing to draw, the overlay stays down "
                + "and the writer gets the project at altitude")
        }
    }

    // MARK: - The rule

    /// **Publish's alone, and only with something compiled** — over the whole
    /// product of personas and resolutions, so a fifth persona has to answer it.
    func test_theOverlayIsPublishsAloneAndOnlyWithSomethingCompiled() throws {
        let ready = Self.publication(version: "1.0", outputPath: "Exports/b.pdf",
                                     compiledAt: Date())
        for persona in Persona.allCases {
            XCTAssertEqual(
                ProjectWindow.publishPreviewCentre(persona: persona,
                                                   preview: .ready(ready)) != nil,
                persona.previewsThePublishedBook,
                "\(persona): the overlay is gated on the ONE spelling of "
                + "\"this persona's centre is the compiled book\"")
            for degrade: PublishPreviewResolution in [.nothingCompiled, Self.unreadable] {
                XCTAssertNil(
                    ProjectWindow.publishPreviewCentre(persona: persona,
                                                       preview: degrade),
                    "\(persona) with \(degrade)")
            }
        }
    }

    /// The predicate itself: exactly one persona, and it is the one whose whole
    /// job is the book.
    func test_onlyPublishPreviewsThePublishedBook() {
        XCTAssertEqual(Persona.allCases.filter(\.previewsThePublishedBook), [.publish])
    }

    /// **`subjectShowsAltitude` is untouched**, which is what makes the
    /// uncompiled truth table identical to the one stage 3a left: the preview is
    /// a layer ABOVE it rather than a change to it.
    func test_theAltitudeRuleIsUnchangedByThisTask() {
        for (subject, shape) in ProjectAltitudeCentreTests.notADocument {
            XCTAssertTrue(
                ProjectWindow.subjectShowsAltitude(
                    persona: .publish, subject: subject,
                    structure: ProjectAltitudeCentreTests.structure),
                "Publish with \(shape): still altitude, exactly as before — the "
                + "preview does not reach this rule")
        }
        XCTAssertFalse(
            ProjectWindow.subjectShowsAltitude(
                persona: .publish, subject: .item("chapter-1"),
                structure: ProjectAltitudeCentreTests.structure),
            "…and a document is still not altitude; what covers it in Publish "
            + "is the preview layer, decided somewhere else entirely")
    }

    // MARK: - The status footer

    /// **The footer refuses over the preview**, for altitude's own argument: its
    /// four readings — the goal capsule, the live session words, the `¶id` under
    /// the cursor, the current element — are about a document in the centre, and
    /// over a compiled book there is no such document on screen.
    func test_theFooterIsSilentOverThePreviewAndSpeaksUnderneathIt() {
        XCTAssertFalse(
            ProjectWindow.showsStatusFooter(
                persona: .publish, subject: .item("doc1"), showsPaletteWall: false,
                publishPreview: .ready(Self.publication(
                    version: "1.0", outputPath: "Exports/b.pdf", compiledAt: Date())),
                structure: Self.oneDocument),
            "the preview covers the document the footer would be reporting on")
        XCTAssertTrue(
            ProjectWindow.showsStatusFooter(
                persona: .publish, subject: .item("doc1"), showsPaletteWall: false,
                publishPreview: .nothingCompiled, structure: Self.oneDocument),
            "control: with nothing compiled, Publish over a document is the "
            + "editor and the footer reports exactly as it did before this task")
    }

    /// The other personas cannot be silenced by a resolution they never read —
    /// otherwise the refusal above would be a fact about the value rather than
    /// about the overlay.
    func test_aReadyPublicationSilencesNobodyElsesFooter() {
        let ready = PublishPreviewResolution.ready(
            Self.publication(version: "1.0", outputPath: "Exports/b.pdf",
                             compiledAt: Date()))
        for persona in [Persona.author, .review] {
            XCTAssertTrue(
                ProjectWindow.showsStatusFooter(
                    persona: persona, subject: .item("doc1"), showsPaletteWall: false,
                    publishPreview: ready, structure: Self.oneDocument),
                "\(persona): a compiled book in another persona's centre is not "
                + "this persona's business")
        }
    }

    // MARK: - Where a research subject lands in Publish

    /// **Publish stops acting on a research subject** — spec §4's "—" row. The
    /// placement answers `.nothingMoves`, so the subject falls through to the
    /// manuscript arm: the preview if there is one, altitude if there is not.
    func test_publishNoLongerTakesTheCentreForAResearchSubject() {
        XCTAssertEqual(
            ProjectWindow.researchSubjectPlacement(
                persona: .publish, subject: .research("r1")),
            .nothingMoves,
            "Publish has no rendering for a research note (spec §4), and the "
            + "centre it does have is the book")
        XCTAssertNil(
            ProjectWindow.researchSubjectPlacement(
                persona: .publish, subject: .research("r1")).inspectedItemID,
            "…and neither column acts on it, which is what `.nothingMoves` "
            + "means for the right column too")
        XCTAssertEqual(
            ProjectWindow.researchSubjectPlacement(
                persona: .author, subject: .research("r1")),
            .takesTheCentre("r1"),
            "the control: Author still hands the centre over, so the assertion "
            + "above is about Publish rather than about a function that stopped "
            + "routing anybody")
    }

    /// And with nothing compiled it lands where the spec says it lands: the
    /// project at altitude, rather than a blank centre.
    func test_aResearchSubjectInUncompiledPublishReachesAltitude() {
        XCTAssertTrue(
            ProjectWindow.subjectShowsAltitude(
                persona: .publish, subject: .research("r1"),
                structure: Self.oneDocument),
            "spec §4: \"— (project altitude shown)\" — the centre never renders "
            + "nothing")
    }

    // MARK: - Mounted: the book takes the centre

    /// **The project's own subject in Publish draws the compiled book.**
    func test_theProjectSubjectInPublishShowsTheCompiledBook() async throws {
        let store = try await novel()
        let publication = try await compileOne(into: store)
        let mount = try await host(store: store, persona: .publish,
                                   subject: .project, preview: .ready(publication))

        await pumpUntil(deadline: 5) { !self.pdfViews(in: mount.window).isEmpty }

        XCTAssertFalse(pdfViews(in: mount.window).isEmpty,
                       "the centre column mounted no PDF at all. Views: "
                       + "\(viewNames(in: mount.window))")
        // **Altitude is still mounted — that is the layered shape working, not a
        // bug.** The project's subject answers `subjectShowsAltitude` too, so
        // both layers are in the stack; what says which one the writer sees is
        // z-order, measured the way the OS measures it.
        XCTAssertNotNil(altitudeTable(in: mount.window),
                        "premise: the project subject really does put altitude "
                        + "in the stack, so this is a test about which layer is "
                        + "in FRONT rather than about which one exists")
        let hit = try middleOfTheColumn(in: mount.window)
        let pdf = try XCTUnwrap(pdfViews(in: mount.window).first)
        XCTAssertTrue(hit === pdf || hit.isDescendant(of: pdf),
                      "the middle of the column hit-tests to \(type(of: hit)) — "
                      + "the corkboard is drawn OVER the compiled book, which is "
                      + "the truth table upside down")
    }

    /// **Denver's decision, mounted: a piece subject shows the SAME preview.**
    /// The gate takes no subject at all, so this is the structural property made
    /// visible rather than a second rule.
    func test_aDocumentSubjectInPublishShowsTheSameBookAndNotTheEditor() async throws {
        let store = try await novel()
        let publication = try await compileOne(into: store)
        let chapter = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.structure, where: { $0.type == .document }))
        let mount = try await host(store: store, persona: .publish,
                                   subject: .item(chapter.id),
                                   preview: .ready(publication))

        await pumpUntil(deadline: 5) { !self.pdfViews(in: mount.window).isEmpty }

        XCTAssertFalse(pdfViews(in: mount.window).isEmpty,
                       "a chapter subject in Publish must show the book, not "
                       + "the chapter — Denver's decision. Views: "
                       + "\(viewNames(in: mount.window))")
        let hit = try middleOfTheColumn(in: mount.window)
        let pdf = try XCTUnwrap(pdfViews(in: mount.window).first)
        XCTAssertTrue(hit === pdf || hit.isDescendant(of: pdf),
                      "the middle of the column hit-tests to \(type(of: hit)), "
                      + "so the preview is not covering what is underneath it")
    }

    /// **A research subject in Publish falls through the arm that used to take
    /// it** — mounted through the same arm order `editorPane` uses, because the
    /// placement change is only half the claim.
    func test_aResearchSubjectInPublishShowsTheBookAndNotTheNote() async throws {
        let store = try await novel()
        let publication = try await compileOne(into: store)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Ships")
        let mount = try await host(store: store, persona: .publish,
                                   subject: .research(note.id),
                                   preview: .ready(publication))

        await pumpUntil(deadline: 5) { !self.pdfViews(in: mount.window).isEmpty }

        XCTAssertFalse(pdfViews(in: mount.window).isEmpty,
                       "the research arm above the editor arm took the centre "
                       + "in Publish. Views: \(viewNames(in: mount.window))")
    }

    /// **With nothing compiled, Publish is exactly what stage 3a left**: a
    /// document subject opens in the editor.
    func test_uncompiledPublishStillOpensTheChapterInTheEditor() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.structure, where: { $0.type == .document }))
        let mount = try await host(store: store, persona: .publish,
                                   subject: .item(chapter.id),
                                   preview: .nothingCompiled)

        await pumpUntil(deadline: 5) { !self.textViews(in: mount.window).isEmpty }

        XCTAssertFalse(textViews(in: mount.window).isEmpty,
                       "the chapter must still open — the degrade is altitude "
                       + "for a non-document subject, not a dead persona")
        XCTAssertTrue(pdfViews(in: mount.window).isEmpty,
                      "…and nothing is drawn over it")
    }

    /// **And the project row in uncompiled Publish is still the corkboard.**
    func test_uncompiledPublishStillShowsAltitudeForTheProjectRow() async throws {
        let store = try await novel()
        let mount = try await host(store: store, persona: .publish,
                                   subject: .project, preview: .nothingCompiled)

        await pumpUntil(deadline: 5) { self.altitudeTable(in: mount.window) != nil }

        XCTAssertNotNil(altitudeTable(in: mount.window),
                        "stage 3a's degrade is what an uncompiled Publish "
                        + "still gets")
        XCTAssertTrue(pdfViews(in: mount.window).isEmpty)
    }

    // MARK: - Mounted: the host survives the new layer

    /// **`EditorHost` is torn down ZERO times across preview ↔ editor ↔
    /// altitude.** The whole reason the preview is a layer: a fourth `editorPane`
    /// arm would unmount the host on every hop, and its `.onDisappear` is
    /// `doc.close()` + `documentStore.unregister(path:)` + `loads.abandon()`.
    ///
    /// The trip is the one a writer makes while checking a proof: the book in
    /// Publish, back to the chapter in Author, up to the project at altitude,
    /// and into Publish again.
    func test_thePreviewEditorAltitudeRoundTripNeverTearsTheHostDown() async throws {
        let store = try await novel()
        let publication = try await compileOne(into: store)
        let chapter = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.structure, where: { $0.type == .document }))
        let mount = try await host(store: store, persona: .publish,
                                   subject: .item(chapter.id),
                                   preview: .ready(publication))

        await pumpUntil(deadline: 5) { !self.pdfViews(in: mount.window).isEmpty }
        XCTAssertEqual(mount.hostLife.appearances, 1, "premise: the host mounted")
        XCTAssertEqual(mount.hostLife.disappearances, 0, "premise: and is still up")

        mount.box.persona = .author
        await pumpUntil(deadline: 5) { self.pdfViews(in: mount.window).isEmpty }
        XCTAssertTrue(pdfViews(in: mount.window).isEmpty,
                      "the book stayed up after the writer left Publish")
        XCTAssertFalse(textViews(in: mount.window).isEmpty,
                       "…and the chapter is underneath, in the host that never "
                       + "went away")

        mount.box.subject = .project
        await pumpUntil(deadline: 5) { self.altitudeTable(in: mount.window) != nil }
        XCTAssertNotNil(altitudeTable(in: mount.window))

        mount.box.persona = .publish
        await pumpUntil(deadline: 5) { !self.pdfViews(in: mount.window).isEmpty }
        XCTAssertFalse(pdfViews(in: mount.window).isEmpty,
                       "and the book is back, over the corkboard this time")

        XCTAssertEqual(
            mount.hostLife.disappearances, 0,
            "the host was torn down on a hop between the book and the prose — "
            + "which is `doc.close()`, `unregister(path:)` and `loads.abandon()` "
            + "on a gesture a writer checking proofs makes all day")
        XCTAssertEqual(mount.hostLife.appearances, 1,
                       "…and never re-appeared either, so it is the same host "
                       + "with the same Document")
    }

    /// **The control that makes the zero above mean something**: the same hop
    /// through the shape this task rejected — the preview as an arm of its own
    /// beside the editor. The counter is the same counter; if it could not see a
    /// teardown, the assertion above would be green over any shape at all.
    ///
    /// The hop runs prose → book here rather than book → prose, because that is
    /// the direction in which the arm shape has a host to lose: with the preview
    /// as an arm, a window that opens in Publish never mounted one.
    func test_control_thePreviewAsItsOwnArmTearsTheHostDown() async throws {
        let store = try await novel()
        let publication = try await compileOne(into: store)
        let chapter = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.structure, where: { $0.type == .document }))
        let mount = try await host(store: store, persona: .author,
                                   subject: .item(chapter.id),
                                   preview: .ready(publication),
                                   shape: .ownArm)

        await pumpUntil(deadline: 5) { !self.textViews(in: mount.window).isEmpty }
        XCTAssertEqual(mount.hostLife.appearances, 1,
                       "premise: the arm shape mounts the host on the prose")

        mount.box.persona = .publish
        await pumpUntil(deadline: 5) { !self.pdfViews(in: mount.window).isEmpty }

        XCTAssertGreaterThanOrEqual(
            mount.hostLife.disappearances, 1,
            "the arm shape tears the host down on the way into Publish — which "
            + "is what the layered shape's zero is measured against, and why "
            + "this test exists rather than a comment saying an arm would be "
            + "worse")
    }

    // MARK: - Mounted: the compile that finishes while the writer watches

    /// **A compile that completes lands in the centre without a relaunch.**
    ///
    /// `CompileOrchestrator` posts `.maughamPublicationCompleted` AFTER the
    /// catalog append, `.project`-scoped, and the refresh receives it through the
    /// ADR 0021 helper with the `WindowAccessor` idiom. Driven end to end: an
    /// empty catalog, a real compiled PDF appended behind the window's back, then
    /// the post.
    func test_aCompletedCompileReachesTheCentreWithoutARelaunch() async throws {
        let project = try makeProject()
        let box = PublishCentreProbeBox(persona: .publish)
        let window = mountRefreshProbe(projectURL: project, box: box)

        await pumpUntil(deadline: 5) { box.modifierWindow != nil }
        XCTAssertEqual(box.preview, .nothingCompiled,
                       "premise: nothing has been compiled yet")
        XCTAssertTrue(MaughamEvent.isLive(box.modifierWindow),
                      "premise: the RECEIVER has a live window — ADR 0021's "
                      + "project scope drops the post otherwise, and this test "
                      + "would measure nothing")
        XCTAssertTrue(box.modifierWindow === window,
                      "premise: and it is the window this test is posting into")

        let stores = PublishingStores.sharedFor(
            projectID: ProjectIdentifier.id(for: project), projectURL: project)
        let published = try await append(to: stores.publicationStore, in: project,
                                         version: "1.0", minutesAgo: 0)
        MaughamEvent.post(.maughamPublicationCompleted, to: .project(for: project))

        await pumpUntil(deadline: 5) {
            box.preview.publication?.publicationID == published.publicationID
        }
        assertReady(box.preview, is: published,
                    "the compile finished and the centre column never heard "
                    + "about it — the writer has to relaunch to see their own "
                    + "book")
    }

    /// **Arriving in Publish re-asks**, which is also what covers the file that
    /// was deleted since — no watcher, and no stale card over a PDF that is not
    /// there any more.
    func test_arrivingInPublishReAsksAndNoticesTheFileIsGone() async throws {
        let project = try makeProject()
        let stores = PublishingStores.sharedFor(
            projectID: ProjectIdentifier.id(for: project), projectURL: project)
        let published = try await append(to: stores.publicationStore, in: project,
                                         version: "1.0", minutesAgo: 5)

        let box = PublishCentreProbeBox(persona: .author)
        _ = mountRefreshProbe(projectURL: project, box: box)
        await pumpUntil(deadline: 5) {
            box.preview.publication?.publicationID == published.publicationID
        }
        assertReady(box.preview, is: published,
                    "premise: the window opened onto the book that is there")

        try FileManager.default.removeItem(
            at: project.appendingPathComponent(published.outputPath))
        box.persona = .publish

        await pumpUntil(deadline: 5) { box.preview == .nothingCompiled }
        XCTAssertEqual(box.preview, .nothingCompiled,
                       "the writer deleted the export in the Finder and walked "
                       + "into Publish — the centre must notice on arrival, "
                       + "since nothing here watches the directory")
    }

    // MARK: - The shape, in production

    /// **The bridge from the probe's spelling to the window's.** The mounted
    /// tests above drive a probe that takes every routing decision from
    /// production's statics, but the SHAPE of the last arm is the probe's own and
    /// a probe cannot vouch for it. This reads the real `manuscriptEditor`.
    func test_theBookIsAThirdLayerOfTheSameZStackAndNotAFourthArm() throws {
        let source = try Self.source(of: "Views/ProjectWindow.swift")
        let arm = try XCTUnwrap(
            Self.declaration(named: "private func manuscriptEditor(", in: source),
            "the editor arm must still be a member of its own")

        XCTAssertTrue(arm.contains("ZStack"), "still one stack, not a choice")
        XCTAssertTrue(arm.contains("EditorHost("),
                      "…with the host mounted unconditionally underneath")
        XCTAssertTrue(arm.contains("ProjectAltitudePane("),
                      "…altitude over it")
        XCTAssertTrue(arm.contains("PublishPreviewCentre("),
                      "…and the book over both")
        XCTAssertTrue(arm.contains("Self.publishPreviewCentre("),
                      "the layer is gated on the named rule rather than on a "
                      + "second spelling written out here")

        let altitudeAt = try XCTUnwrap(arm.range(of: "ProjectAltitudePane("))
        let bookAt = try XCTUnwrap(arm.range(of: "PublishPreviewCentre("))
        XCTAssertTrue(altitudeAt.lowerBound < bookAt.lowerBound,
                      "the book must be the LAST layer of the stack — a "
                      + "corkboard drawn over a compiled book is the truth "
                      + "table read upside down")

        XCTAssertEqual(
            Self.occurrences(of: "PublishPreviewCentre(", in: source), 1,
            "one mount for the book, in the centre column's overlay. A second "
            + "is a surface nobody decided to add")
        XCTAssertEqual(
            Self.occurrences(of: "manuscriptEditor(", in: source), 2,
            "the declaration and exactly ONE call — unchanged by this task")
    }

    /// **`previewsThePublishedBook` is the ONE spelling, and the centre rule's
    /// files ask it rather than naming the persona.**
    ///
    /// `centresTheCanvas`'s own history is the warrant: a persona compared by
    /// name reads identically at three sites and drifts at the fourth, and that
    /// cost three separate visible defects before the question was named. The
    /// window's sole surviving name-gate is the Exports footer
    /// (`BinderPaneToggle`'s `persona != .plan`), which is about exporting
    /// rather than about what the centre column draws — and it lives in neither
    /// file scanned here, which is why this census can be absolute.
    func test_theCentreRulesFilesAskThePredicateRatherThanNamingThePersona() throws {
        let files = ["Views/ProjectWindow.swift", "Views/ResearchSubjectColumns.swift",
                     "Views/Publish/PublishPreviewCentre.swift",
                     "Publish/PublishPreviewResolver.swift"]
        for file in files {
            let source = try Self.source(of: file)
            XCTAssertTrue(
                Self.nameGates(in: source).isEmpty,
                "\(file) compares the persona by name: "
                + "\(Self.nameGates(in: source)). The one spelling is "
                + "`Persona.previewsThePublishedBook`")
        }
        // The control: the scanner sees the offender it is asserting the absence
        // of, or every line above is green over any file at all.
        XCTAssertFalse(
            Self.nameGates(in: "guard persona == .publish else { return nil }").isEmpty,
            "the scanner cannot see a planted name-gate, so its silence above "
            + "says nothing")

        for file in ["Views/ProjectWindow.swift", "Views/ResearchSubjectColumns.swift"] {
            let source = try Self.source(of: file)
            XCTAssertTrue(
                source.contains("previewsThePublishedBook"),
                "\(file) decides something about Publish's centre and must ASK "
                + "the predicate — a file that neither names the persona nor "
                + "asks the question has stopped deciding")
        }
    }

    private static func nameGates(in source: String) -> [String] {
        source
            .components(separatedBy: .newlines)
            .filter { $0.contains("== .publish") || $0.contains("!= .publish") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Hosting

    private struct Mount {
        let window: NSWindow
        let box: PublishCentreProbeBox
        let hostLife: EditorHostLifeCounter
    }

    private func host(store: ProjectStore,
                      persona: Persona = .publish,
                      subject: BinderSubject? = nil,
                      preview: PublishPreviewResolution = .nothingCompiled,
                      shape: PublishCentreProbeView.Shape = .layered)
    async throws -> Mount {
        let documentStore = try await DocumentStore.open(url: store.url)
        store.documentStore = documentStore
        documentStores.append(documentStore)

        let box = PublishCentreProbeBox(persona: persona)
        box.subject = subject
        box.preview = preview
        let life = EditorHostLifeCounter()
        // `EditorHost` reads `UserPreferences` out of the environment, and a
        // missing environment value traps inside SwiftUI's accessor rather than
        // reading nil — the whole test process goes down.
        let suite = "publish-preview-centre-\(UUID().uuidString)"
        defaultsSuites.append(suite)
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!)
        let root = PublishCentreProbeView(
            store: store, documentStore: documentStore, box: box,
            hostLife: life, shape: shape, canvasModel: CanvasModel())
            .environment(preferences)

        let frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump(0.1)
        return Mount(window: window, box: box, hostLife: life)
    }

    /// The refresh modifier alone, in a live window — the event path needs a
    /// visible `NSWindow` or ADR 0021's liveness guard drops the post.
    private func mountRefreshProbe(projectURL: URL,
                                   box: PublishCentreProbeBox) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let hosting = NSHostingView(rootView: AnyView(
            PublishRefreshProbeView(projectURL: projectURL, box: box)))
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump(0.1)
        return window
    }

    // MARK: - Reading the mounted window

    private func pdfViews(in window: NSWindow) -> [PDFView] {
        collect(PDFView.self, in: window)
    }

    private func altitudeTable(in window: NSWindow) -> NSTableView? {
        collect(NSTableView.self, in: window).first
    }

    private func textViews(in window: NSWindow) -> [MaughamTextView] {
        collect(MaughamTextView.self, in: window)
    }

    private func middleOfTheColumn(in window: NSWindow) throws -> NSView {
        let content = try XCTUnwrap(window.contentView)
        // The premise, read off the window this display actually granted:
        // `NSWindow` clamps to the screen, and CI's is narrower than this Mac's.
        try XCTSkipUnless(
            content.bounds.width >= 300 && content.bounds.height >= 300,
            "this display mounted a \(content.bounds.size) centre column")
        let middle = NSPoint(x: content.bounds.midX, y: content.bounds.midY)
        return try XCTUnwrap(content.hitTest(content.convert(middle, to: nil)),
                             "nothing at all at the middle of the column")
    }

    private func viewNames(in window: NSWindow) -> [String] {
        collect(NSView.self, in: window).map { String(describing: type(of: $0)) }
    }

    private func collect<T: NSView>(_ type: T.Type, in window: NSWindow) -> [T] {
        guard let root = window.contentView else { return [] }
        var found: [T] = []
        collect(type, in: root, into: &found)
        return found
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }

    // MARK: - Fixtures

    private func makeProject() throws -> URL {
        let url = temp.url.appendingPathComponent("Book-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Exports", isDirectory: true),
            withIntermediateDirectories: true)
        return url
    }

    private func novel() async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Preview-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        return store
    }

    /// One real compiled PDF in the project's own catalog — the fixture the
    /// mounted tests need, since `PDFPreview` opens the file for real.
    @discardableResult
    private func compileOne(into store: ProjectStore) async throws -> Publication {
        try FileManager.default.createDirectory(
            at: store.url.appendingPathComponent("Exports", isDirectory: true),
            withIntermediateDirectories: true)
        let publications = PublicationStore(projectURL: store.url)
        return try await append(to: publications, in: store.url,
                                version: "1.0", minutesAgo: 1)
    }

    @discardableResult
    private func append(to store: PublicationStore, in projectURL: URL,
                        version: String,
                        format: PublishConfig.Format = .pdf,
                        language: String? = nil,
                        minutesAgo: Int) async throws -> Publication {
        let name = "Exports/book-\(version)-\(UUID().uuidString.prefix(4))"
            + (format == .pdf ? ".pdf" : ".epub")
        let file = projectURL.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if format == .pdf {
            try Self.writePDF(at: file)
        } else {
            try Data("epub".utf8).write(to: file)
        }
        let pub = Self.publication(
            version: version, format: format, outputPath: name,
            compiledAt: Date().addingTimeInterval(-Double(minutesAgo) * 60),
            language: language)
        try await store.append(pub)
        return pub
    }

    static func publication(version: String,
                            format: PublishConfig.Format = .pdf,
                            outputPath: String,
                            compiledAt: Date,
                            language: String? = nil) -> Publication {
        Publication(
            publicationID: "pub-\(UUID().uuidString.prefix(8))",
            version: version, label: nil, format: format,
            outputPath: outputPath, snapshotID: "snap-\(version)",
            checkpointID: "ckpt-\(version)", republishedFrom: nil,
            compiledAt: compiledAt, maughamVersion: "test",
            tectonicVersion: "test", language: language)
    }

    /// A real, openable one-page PDF. `PDFDocument(url:) != nil` is one of the
    /// resolver's two guards, so the fixture cannot fake it.
    static func writePDF(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 200, height: 260)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
        context.endPDFPage()
        context.closePDF()
    }

    /// A stand-in for the arm the reconcile will make live.
    static let unreadable = PublishPreviewResolution
        .unreadableCatalog(reason: "the catalog could not be read")

    static let oneDocument: [StructureItem] = [
        StructureItem(id: "doc1", title: "Chapter One", type: .document,
                      path: "manuscript/chapter-1.md")
    ]

    // MARK: - Reading the source

    private static func source(of relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
        return try String(contentsOf: root.appendingPathComponent(relativePath),
                          encoding: .utf8)
    }

    private static func declaration(named header: String, in source: String) -> String? {
        guard let start = source.range(of: header) else { return nil }
        let rest = source[start.lowerBound...]
        guard let end = rest.range(of: "\n    }\n") else { return String(rest) }
        return String(rest[..<end.upperBound])
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}

// MARK: - Probes

/// The window state the centre column reads, held outside the view so a test can
/// move the persona, the subject and the resolved publication the way the window
/// does.
@Observable
@MainActor
final class PublishCentreProbeBox {
    var subject: BinderSubject?
    var persona: Persona
    var preview: PublishPreviewResolution = .nothingCompiled
    /// The window the REFRESH MODIFIER actually got, which is not the same fact
    /// as the window the test made: `WindowAccessor` resolves it a runloop turn
    /// later, and ADR 0021's project scope drops a post whose receiver has no
    /// live window. Without this the event tests would silently measure nothing.
    var modifierWindow: NSWindow?

    init(persona: Persona) { self.persona = persona }
}

/// **The centre column, wired the way `editorPane` wires it** — the research
/// placement, the canvas route, the Collection reference arm, then the editor
/// arm, with every decision taken from production's own statics.
///
/// What it spells for itself is the SHAPE of the last arm, which is the thing
/// under test and cannot be reached from outside `ProjectWindow`. Hence two
/// cases: `.layered` is what production does, and `.ownArm` is the shape this
/// task rejected, driven by the control test so the lifetime counter is proven
/// able to see a teardown.
@MainActor
struct PublishCentreProbeView: View {
    enum Shape { case layered, ownArm }

    let store: ProjectStore
    let documentStore: DocumentStore
    let box: PublishCentreProbeBox
    let hostLife: EditorHostLifeCounter
    let shape: Shape
    let canvasModel: CanvasModel

    @State private var layout: OutlineLayout = .table
    @State private var control = EditorControl()

    private var subject: Binding<BinderSubject?> {
        Binding(get: { box.subject }, set: { box.subject = $0 })
    }

    private var referencePiece: StructureItem? {
        guard let id = box.subject?.itemID,
              let piece = store.manifest.structure.first(where: { $0.id == id }),
              piece.pieceKind == .reference
        else { return nil }
        return piece
    }

    var body: some View {
        centre.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var centre: some View {
        let route = ProjectWindow.editorRoute(
            persona: box.persona, projectType: store.manifest.type,
            selectedPieceIsReference: referencePiece != nil)
        if let id = ProjectWindow.researchSubjectPlacement(
            persona: box.persona, subject: box.subject).centreItemID {
            ResearchSubjectCentre(store: store, documentStore: documentStore,
                                  itemID: id, previewVisible: false)
        } else if route == .canvas {
            CanvasView(model: canvasModel, projectRoot: store.url,
                       paletteSwatchHexes: { [] })
        } else if route == .collectionReference, let piece = referencePiece {
            ReferencePlaceholderCard(piece: piece, onOpen: {})
        } else {
            manuscriptCentre
        }
    }

    @ViewBuilder
    private var manuscriptCentre: some View {
        switch shape {
        case .layered:
            ZStack {
                editor
                if showsAltitude { altitude }
                if let publication = book { PublishPreviewCentre(
                    publication: publication, projectURL: store.url,
                    title: store.manifest.title) }
            }
        case .ownArm:
            if let publication = book {
                PublishPreviewCentre(publication: publication,
                                     projectURL: store.url,
                                     title: store.manifest.title)
            } else if showsAltitude {
                altitude
            } else {
                editor
            }
        }
    }

    private var showsAltitude: Bool {
        ProjectWindow.subjectShowsAltitude(persona: box.persona,
                                           subject: box.subject,
                                           structure: store.manifest.structure)
    }

    private var book: Publication? {
        ProjectWindow.publishPreviewCentre(persona: box.persona,
                                           preview: box.preview)
    }

    private var editor: some View {
        EditorHost(store: store, documentStore: documentStore,
                   selectedItemId: box.subject?.itemID, control: control)
            .onAppear { hostLife.appeared() }
            .onDisappear { hostLife.disappeared() }
    }

    private var altitude: some View {
        ProjectAltitudePane(store: store, layout: $layout,
                            selectedSubject: subject, title: store.manifest.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The refresh modifier in a live window — production's own, with the same
/// `WindowAccessor` idiom `ProjectWindow` uses.
@MainActor
private struct PublishRefreshProbeView: View {
    let projectURL: URL
    let box: PublishCentreProbeBox

    @State private var window: NSWindow?

    var body: some View {
        Color.clear
            .background(WindowAccessor(window: $window))
            .modifier(PublishPreviewModifier(
                projectURL: projectURL, window: window, persona: box.persona,
                publishPreview: Binding(get: { box.preview },
                                        set: { box.preview = $0 })))
            .onChange(of: window) { _, next in box.modifierWindow = next }
    }
}
