import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import PDFKit
import MaughamCore
@testable import Maugham

/// **The gate: what a writer looks at before they say yes** (publish-department
/// P4 Task 5, spec §5's centre).
///
/// A design round's product is a *proposal* — a written spec, a set of template
/// files, and sample pages compiled against them. Until this task it existed
/// only on disk and as a line on the desk. The gate is where it faces the
/// writer, and it takes the Publish centre while it is selected: the same column
/// the compiled book shows in, above the same altitude view, by the same rule
/// (`ProjectWindow.publishCentre` composes `subjectShowsAltitude`, so a chapter
/// in Publish still opens the editor — Denver's 2026-08-12 ruling).
///
/// **Three things are under test, and they need different instruments.**
///
/// - **The routing.** `publishCentre` is a static over
///   `(persona, subject, structure, resolution, proposal)`, so the whole truth
///   table is assertable with no window at all — including the two arms that
///   matter most: a selected proposal outranks the book, and deselecting gives
///   the book (or its notice) back untouched.
/// - **The record.** The gate names the sample's `demonstrates` lines and the
///   round's language, and P3 dropped both on the floor: `SampleCompiler`
///   computed the lines and `sampleResult(_:)` threw them away, while the round's
///   language reached `stage` on a `StageContext` and was never written down.
///   Neither is a fact the gate can re-derive — the AST has moved on — so both
///   are pinned here as store round-trips, tolerant of the older `proposal.json`
///   that carries neither.
/// - **The surface.** Mounted, and read off the accessibility tree, because the
///   contract is about what a writer can SEE: the spec, the staged files, the
///   pages (PDFKit's, the book's own renderer) or the cause when there are none.
///
/// **Nothing here is a verb.** Approve / Request Changes / Revert / Finalize are
/// Task 6's; the one control on this surface is the way back to the book.
@MainActor
final class DesignGateTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // The parallel-worker fontd cold-start window (CLAUDE.md): this suite
        // mounts real prose through production typography.
        FontWarmup.ensure()
    }

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - The routing (no window)

    /// **A selected proposal outranks the book.** The writer pressed Show; a
    /// compiled PDF drawn over the thing they asked to look at is the truth table
    /// upside down — the same argument that puts the book above altitude.
    func test_aSelectedProposalTakesTheCentreAheadOfTheBook() {
        let proposal = Self.proposal()

        for preview: PublishPreviewResolution in [
            .ready(newestFirst: [PublishPreviewCentreTests.aBook]),
            .nothingCompiled,
            PublishPreviewCentreTests.unreadable
        ] {
            XCTAssertEqual(
                ProjectWindow.publishCentre(
                    persona: .publish, subject: nil,
                    structure: ProjectAltitudeCentreTests.structure,
                    preview: preview, proposal: proposal),
                .designProposal(proposal),
                "with a proposal selected the gate has the column whatever the "
                + "catalog says (\(preview)) — the writer asked for the proposal")
        }
    }

    /// …and **deselecting gives the book back**, untouched. The gate is a
    /// surface the writer enters and leaves; leaving it must not cost them the
    /// arm they were on, and must not invent a fourth answer.
    func test_deselectingRestoresTheBookOrItsNotice() {
        let table: [(PublishPreviewResolution, PublishCentre)] = [
            (.ready(newestFirst: [PublishPreviewCentreTests.aBook]),
             .books([PublishPreviewCentreTests.aBook])),
            (.nothingCompiled, .notice(.neverCompiled)),
            (PublishPreviewCentreTests.unreadable,
             .notice(.unreadableCatalog(
                reason: PublishPreviewCentreTests.unreadableReason)))
        ]
        for (preview, expected) in table {
            XCTAssertEqual(
                ProjectWindow.publishCentre(
                    persona: .publish, subject: nil,
                    structure: ProjectAltitudeCentreTests.structure,
                    preview: preview, proposal: nil),
                expected,
                "with nothing selected the column is exactly what it was before "
                + "the gate existed")
        }
    }

    /// **The gate composes the window's document question rather than forking
    /// it.** Denver, 2026-08-12: *"a chapter/piece subject in Publish ALWAYS
    /// opens the editor — I might tweak something for layout."* A gate that
    /// answered its own subject rule would be a second answer free to disagree,
    /// and the disagreement would be a proposal drawn over the chapter a writer
    /// is fixing.
    func test_aChapterSubjectOpensTheEditorEvenWithAProposalSelected() {
        XCTAssertNil(
            ProjectWindow.publishCentre(
                persona: .publish, subject: .item("chapter-1"),
                structure: ProjectAltitudeCentreTests.structure,
                preview: .ready(newestFirst: [PublishPreviewCentreTests.aBook]),
                proposal: Self.proposal()),
            "a chapter in Publish is the editor, proposal or no proposal")
    }

    /// **The gate is Publish's, like the book it stands in front of.** A
    /// proposal selected before a persona switch must not follow the writer into
    /// Author's centre column.
    func test_onlyPublishHasAGate() {
        for persona in Persona.allCases where !persona.previewsThePublishedBook {
            XCTAssertNil(
                ProjectWindow.publishCentre(
                    persona: persona, subject: nil,
                    structure: ProjectAltitudeCentreTests.structure,
                    preview: .nothingCompiled, proposal: Self.proposal()),
                "\(persona) has no gate — the department's centre is Publish's")
        }
    }

    // MARK: - The sample panel (no window)

    /// **A failed sample shows its cause and is never a blank** (RULING-7's
    /// shape, and the brief's sharpest clause). A design round whose pages would
    /// not typeset is a round the writer still has to see — and turn down for a
    /// reason.
    func test_aFailedSampleCarriesItsCause() {
        let cause = "! Undefined control sequence. \\chapteropener"
        XCTAssertEqual(
            DesignGate.panel(for: .failed(error: cause),
                             projectURL: URL(fileURLWithPath: "/tmp/p"),
                             pagesExist: true),
            .failed(cause: cause))
    }

    /// …and **an empty cause is still not a blank**. `SampleCompiler
    /// .failureSentence` never answers "" today, but a `proposal.json` is a file
    /// on disk and this is the one place a writer would be shown an empty box
    /// where a reason goes.
    func test_aFailureWithNothingToSayStillSaysSomething() {
        for empty in ["", "   ", "\n"] {
            XCTAssertEqual(
                DesignGate.panel(for: .failed(error: empty),
                                 projectURL: URL(fileURLWithPath: "/tmp/p"),
                                 pagesExist: true),
                .failed(cause: DesignGate.noCauseGiven),
                "a failure with no words gets the standing sentence, never a "
                + "blank panel")
        }
        XCTAssertFalse(DesignGate.noCauseGiven.isEmpty)
    }

    /// **A proposal that was never sampled says so**, which is a different fact
    /// from a sample that failed. `DesignerEnvironment.sample` answers `nil` when
    /// the outcome could not be RECORDED — the proposal is staged and readable
    /// and simply has no pages beside it — and reading that as a failure would
    /// tell the writer their design is broken when nothing about it is.
    func test_aProposalThatWasNeverSampledIsNotAFailure() {
        XCTAssertEqual(
            DesignGate.panel(for: nil, projectURL: URL(fileURLWithPath: "/tmp/p"),
                             pagesExist: true),
            .notSampled)
    }

    /// The pages resolve the way the book's do — absolute as itself, relative
    /// against the project — so the gate and the preview cannot come to disagree
    /// about where a PDF is.
    func test_thePagesPathResolvesAsThePublicationsDo() {
        let project = URL(fileURLWithPath: "/tmp/project")
        XCTAssertEqual(
            DesignGate.panel(for: .pages(path: "/tmp/elsewhere/sample.pdf",
                                         demonstrates: []),
                             projectURL: project, pagesExist: true),
            .pages(URL(fileURLWithPath: "/tmp/elsewhere/sample.pdf")))
        XCTAssertEqual(
            DesignGate.panel(for: .pages(path: ".maugham/design/s.pdf",
                                         demonstrates: []),
                             projectURL: project, pagesExist: true),
            .pages(project.appendingPathComponent(".maugham/design/s.pdf")))
    }

    /// **Pages that are no longer on disk say where they were.** Everything
    /// under `.maugham/design/` is derived and the store's own doc says deleting
    /// it is safe — so a writer who has done that, or restored a project folder
    /// without it, opens a proposal whose recorded pages are gone. A `PDFView`
    /// over a missing file draws a grey void, which is the blank this surface is
    /// not allowed to have.
    func test_pagesThatAreGoneSayWhereTheyWereRatherThanDrawingAVoid() {
        let panel = DesignGate.panel(
            for: .pages(path: "/tmp/gone/sample.pdf", demonstrates: []),
            projectURL: URL(fileURLWithPath: "/tmp/project"), pagesExist: false)

        XCTAssertEqual(panel, .missing(path: "/tmp/gone/sample.pdf"))
    }

    // MARK: - What the gate says

    /// **The base-templates caveat, and only for an edition round** (Global
    /// Constraint 3). A design round briefed on a language sets that edition's
    /// TEXT, but Maugham keeps one template set per book — so the pages the
    /// writer is judging are the base design doing the edition's work, and a
    /// gate that did not say so would be offering an approval of something else.
    func test_anEditionRoundSaysItsSampleUsedTheBaseTemplates() throws {
        XCTAssertNil(DesignGate.caveat(language: nil),
                     "a round for the book itself has no caveat to make — the "
                     + "templates it proposes ARE the ones it was sampled with")

        let caveat = try XCTUnwrap(DesignGate.caveat(language: "es"))
        XCTAssertTrue(
            caveat.contains(
                TranslationReviewIndicator.displayLabel(forLanguageTag: "es")),
            "the caveat names the edition it is about: \(caveat)")
        XCTAssertFalse(caveat.isEmpty)
    }

    /// A proposal that staged no template files says so. `DesignerReport` can
    /// parse a report with an empty `files` array, and a heading over nothing is
    /// how a writer decides a surface failed to load.
    func test_aProposalWithNoStagedFilesSaysSoUnderItsOwnHeading() {
        XCTAssertFalse(DesignGate.templatesHeading.isEmpty)
        XCTAssertFalse(DesignGate.noTemplatesStaged.isEmpty)
    }

    // MARK: - The record: what P3 dropped on the floor

    /// **The sample's `demonstrates` lines survive onto the proposal.**
    ///
    /// `SamplePageSelection` computes them, `SampleCompiler.Outcome` carries
    /// them — and `sampleResult(_:)` used to discard them on the way to disk, so
    /// the one surface that exists to show the writer *why these pages* had
    /// nothing to show. They cannot be re-derived at the gate: the selection is
    /// a function of the AST as it stood at the round, and the writer has been
    /// writing since.
    func test_theDemonstratesLinesRideTheOutcomeOntoTheProposal() {
        let lines = ["chapter opener — ‘The Fog’", "verse — ‘Interlude’"]

        XCTAssertEqual(
            SampleCompiler.sampleResult(
                .pages(path: "/tmp/s.pdf", demonstrates: lines)),
            .pages(path: "/tmp/s.pdf", demonstrates: lines),
            "what the compile knew is what the proposal records")
    }

    func test_theDemonstratesLinesRoundTripThroughTheStore() throws {
        let store = DesignProposalStore(projectURL: temp.url)
        let staged = try store.stage(report: Self.report(), round: 1,
                                     designerName: "Tschichold", language: nil)
        let lines = ["chapter opener — ‘The Fog’"]

        try store.recordSampleResult(
            id: staged.id, .pages(path: "scratch/sample.pdf", demonstrates: lines))

        XCTAssertEqual(try store.load(id: staged.id).sampleResult,
                       .pages(path: "scratch/sample.pdf", demonstrates: lines))
    }

    /// **A `proposal.json` written before this task still reads.** The store's
    /// own discipline (`Status`' doc): this file is REWRITTEN in place by
    /// `updateStatus`/`recordSampleResult`, so a shape it cannot decode is not a
    /// missing line on a gate — it is a proposal that vanishes from `list()`
    /// entirely, taking the writer's standing design round with it.
    func test_aSampleResultWrittenBeforeThisTaskStillReadsAsPages() throws {
        let store = DesignProposalStore(projectURL: temp.url)
        let staged = try store.stage(report: Self.report(), round: 1,
                                     designerName: "Tschichold", language: nil)
        try Self.rewrite(proposalAt: store.proposalDir(id: staged.id)) { json in
            var json = json
            json["sampleResult"] = ["pages": ["path": "scratch/sample.pdf"]]
            return json
        }

        let loaded = try store.load(id: staged.id)

        XCTAssertEqual(loaded.sampleResult,
                       .pages(path: "scratch/sample.pdf", demonstrates: []),
                       "the older arm decodes, with no lines to show")
        XCTAssertEqual(try store.list().count, 1,
                       "and it is still in the listing — a decode failure here "
                       + "loses the whole proposal, not one line of it")
    }

    /// **A round's language is recorded on the proposal it stages.**
    ///
    /// `StageContext` carried it to `stage` and `stage` wrote everything else
    /// about the round down and dropped this. The gate needs it for Constraint
    /// 3's caveat, and it cannot be inferred: a proposal's staged files look
    /// identical either way, because an edition round proposes the book's own
    /// template set.
    func test_aRoundsLanguageIsRecordedOnTheProposalItStages() throws {
        let store = DesignProposalStore(projectURL: temp.url)

        let base = try store.stage(report: Self.report(), round: 1,
                                   designerName: "Tschichold", language: nil)
        let edition = try store.stage(report: Self.report(), round: 2,
                                      designerName: "Tschichold", language: "es")

        XCTAssertNil(try store.load(id: base.id).language,
                     "a round for the book itself carries no language")
        XCTAssertEqual(try store.load(id: edition.id).language, "es")
    }

    /// …and a proposal staged before this task reads back with no language,
    /// which is the honest answer for a round nobody recorded one for.
    func test_aProposalWrittenBeforeThisTaskHasNoLanguage() throws {
        let store = DesignProposalStore(projectURL: temp.url)
        let staged = try store.stage(report: Self.report(), round: 1,
                                     designerName: "Tschichold", language: "es")
        try Self.rewrite(proposalAt: store.proposalDir(id: staged.id)) { json in
            var json = json
            json.removeValue(forKey: "language")
            return json
        }

        XCTAssertNil(try store.load(id: staged.id).language)
    }

    // MARK: - The desk's Show (Task 4's concern 3, closed)

    /// **The Design row offers a way to look at what a round produced.** Task 4
    /// drew the pending badge as text and said so: nothing on that row was
    /// clickable through to a gate, because there was no gate. There is one now.
    ///
    /// The button is about the NEWEST round — the one `latestLine` describes —
    /// so the row's sentence and its control are about the same thing.
    func test_theDesignRowOffersAWayToSeeTheNewestProposal() {
        let row = DepartmentDesignRow.resolve(
            designerName: "Tschichold", proposals: [Self.proposal()],
            runState: .idle, session: .free, hasOpenProposalRound: false)
        XCTAssertTrue(row.offersShow)

        let empty = DepartmentDesignRow.resolve(
            designerName: "Tschichold", proposals: [],
            runState: .idle, session: .free, hasOpenProposalRound: false)
        XCTAssertFalse(empty.offersShow,
                       "a project with no round has nothing to show, and a "
                       + "control that can only refuse teaches nothing")
    }

    /// **Show works while a round is running.** It is a READ — the standing
    /// proposal is on disk and looking at it costs the warm session nothing — so
    /// it is deliberately not folded into `refusal`, which disables the two
    /// verbs that would contend for the session.
    func test_showIsNotRefusedByARoundInFlight() {
        let row = DepartmentDesignRow.resolve(
            designerName: "Tschichold", proposals: [Self.proposal()],
            runState: .running(round: 2, language: nil),
            session: .busy(round: 2), hasOpenProposalRound: true)

        XCTAssertTrue(row.offersShow, "reading a staged proposal contends with "
                      + "nothing — only Run and Request Changes do")
        XCTAssertFalse(row.canRun, "…and the verbs that DO contend still refuse")
    }

    /// **Pressing Show hands the newest proposal up**, whole. Pressed through
    /// the accessibility tree, `DepartmentPaneTests`' idiom: it is the action a
    /// click ultimately performs and, unlike a synthetic `mouseDown`, it does
    /// not need this process to be the active app (CLAUDE.md's synthetic-click
    /// premise).
    func test_pressingShowHandsUpTheProposal() async throws {
        var shown = 0
        let window = mountDesk(proposals: [Self.proposal()],
                               showProposal: { shown += 1 })
        _ = try await settling(in: window)

        let published = try axButtonLabels(in: window).sorted()
        let buttons = try axButtons(
            labelled: DepartmentDesignRow.showAccessibilityLabel, in: window)
        XCTAssertEqual(buttons.count, 1,
                       "one Show, on the Design row. Buttons: \(published)")
        _ = (buttons[0] as? NSObject)?.perform(
            NSSelectorFromString("accessibilityPerformPress"))
        _ = await pumpUntil(deadline: 3) { shown > 0 }

        XCTAssertEqual(shown, 1)
    }

    /// …and a desk with no round draws no Show at all.
    func test_aDeskWithNoRoundDrawsNoShow() async throws {
        let window = mountDesk(proposals: [], showProposal: { })
        _ = try await settling(in: window)

        let labels = try axButtonLabels(in: window)
        XCTAssertFalse(labels.contains(DepartmentDesignRow.showAccessibilityLabel),
                       "buttons published: \(labels.sorted())")
    }

    // MARK: - Mounted: the gate itself

    /// **The spec is on screen**, rendered rather than dumped: the designer
    /// writes markdown and the app has exactly one read-only markdown renderer
    /// (`GuideMarkdownView`, which the Help window uses), so the gate reuses it
    /// rather than growing a second.
    func test_theSpecIsOnScreen() async throws {
        let window = mountGate(Self.proposal(
            specMarkdown: "## The measure\n\nA 26-line page, set in Sabon."))
        _ = try await settling(in: window)

        let texts = try axTexts(in: window)
        XCTAssertFalse(texts.isEmpty,
                       "the gate published no text at all, so this test could "
                       + "not fail for the reason it exists")
        for expected in ["The measure", "A 26-line page, set in Sabon."] {
            XCTAssertTrue(texts.contains { $0.contains(expected) },
                          "nothing on the gate reads “\(expected)”. "
                          + "Published: \(texts.sorted())")
        }
    }

    /// **The gate names the templates the sample used** (Global Constraint 3,
    /// its first half). Approving a proposal replaces the live template set with
    /// exactly these files; a writer who cannot see which files those are is
    /// approving a description rather than a change.
    func test_theGateNamesEveryStagedFile() async throws {
        let paths = ["template.tex", "preamble.tex", "styles/verse.tex"]
        let window = mountGate(Self.proposal(filePaths: paths))
        _ = try await settling(in: window)

        let texts = try axTexts(in: window)
        // Case-insensitively: the headings are drawn `.textCase(.uppercase)`,
        // which is styling. Pinning the case here would turn a typographic
        // change into a red test about nothing.
        XCTAssertTrue(texts.contains {
            $0.localizedCaseInsensitiveContains(DesignGate.templatesHeading)
        }, "no heading over the file list. Published: \(texts.sorted())")
        for path in paths {
            XCTAssertTrue(texts.contains { $0.contains(path) },
                          "the staged file “\(path)” is not named on the gate. "
                          + "Published: \(texts.sorted())")
        }
    }

    /// **The sample's `demonstrates` lines are on screen** — what these pages
    /// were chosen to prove. Without them the writer is judging a handful of
    /// pages with no account of why those pages.
    func test_theDemonstratesLinesAreOnScreen() async throws {
        let lines = ["chapter opener — ‘The Fog’", "verse — ‘Interlude’"]
        let pdf = temp.url.appendingPathComponent("sample.pdf")
        try PublishPreviewCentreTests.writePDF(at: pdf)
        let window = mountGate(Self.proposal(
            sampleResult: .pages(path: pdf.path, demonstrates: lines)))
        _ = try await settling(in: window)

        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains {
            $0.localizedCaseInsensitiveContains(DesignGate.demonstratesHeading)
        }, "no heading over the lines. Published: \(texts.sorted())")
        for line in lines {
            XCTAssertTrue(texts.contains { $0.contains(line) },
                          "“\(line)” is not on the gate. Published: \(texts.sorted())")
        }
    }

    /// **An edition round's caveat is on screen**, not merely constructible.
    func test_theCaveatIsDrawnForAnEditionRound() async throws {
        let window = mountGate(Self.proposal(language: "es"))
        _ = try await settling(in: window)

        let caveat = try XCTUnwrap(DesignGate.caveat(language: "es"))
        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains { $0.contains(caveat) },
                      "the edition caveat is not on the gate. "
                      + "Published: \(texts.sorted())")
    }

    /// …and a round for the book itself does not carry it. The control for the
    /// test above: a caveat drawn unconditionally would pass that one and be
    /// wrong about every ordinary round.
    func test_control_aBookRoundDrawsNoCaveat() async throws {
        let window = mountGate(Self.proposal(language: nil))
        _ = try await settling(in: window)

        let caveat = try XCTUnwrap(DesignGate.caveat(language: "es"))
        let texts = try axTexts(in: window)
        XCTAssertFalse(texts.contains { $0.contains(caveat) },
                       "Published: \(texts.sorted())")
    }

    /// **The pages are PDFKit's** — the same view the compiled book is drawn in
    /// (`PDFPreview`, which `PublishPreviewCentre` and the research preview both
    /// use), so a proposal's sample and the book it would become cannot come to
    /// scroll differently.
    func test_theSamplePagesAreDrawnByTheBooksOwnRenderer() async throws {
        let pdf = temp.url.appendingPathComponent("sample.pdf")
        try PublishPreviewCentreTests.writePDF(at: pdf)
        let window = mountGate(Self.proposal(
            sampleResult: .pages(path: pdf.path, demonstrates: [])))
        _ = try await settling(in: window)

        _ = await pumpUntil(deadline: 3) { !self.collect(PDFView.self, in: window).isEmpty }
        XCTAssertEqual(collect(PDFView.self, in: window).count, 1,
                       "one PDF view, and it is the app's one PDF view")
    }

    /// **A failed sample draws its cause instead of an empty page** (RULING-7's
    /// shape on the delivery path). The proposal is still readable, still
    /// turn-downable — and the writer is told what stopped it.
    func test_aFailedSampleDrawsItsCauseAndNoPdfView() async throws {
        let cause = "! Undefined control sequence. \\chapteropener"
        let window = mountGate(Self.proposal(sampleResult: .failed(error: cause)))
        _ = try await settling(in: window)

        XCTAssertTrue(collect(PDFView.self, in: window).isEmpty,
                      "there are no pages, so there is no page view")
        let texts = try axTexts(in: window)
        for expected in [DesignGate.failedHeadline, cause] {
            XCTAssertTrue(texts.contains { $0.contains(expected) },
                          "“\(expected)” is not on the gate. "
                          + "Published: \(texts.sorted())")
        }
    }

    /// **The way back to the book is a control**, so it is reachable with the
    /// keyboard and announced by VoiceOver — and pressing it deselects, which is
    /// what `test_deselectingRestoresTheBookOrItsNotice` proves the column does
    /// with.
    func test_theWayBackToTheBookIsAButtonThatDeselects() async throws {
        var closed = 0
        let window = mountGate(Self.proposal(), onClose: { closed += 1 })
        _ = try await settling(in: window)

        let published = try axButtonLabels(in: window).sorted()
        let buttons = try axButtons(labelled: DesignGate.closeAccessibilityLabel,
                                    in: window)
        XCTAssertEqual(buttons.count, 1, "buttons published: \(published)")
        _ = (buttons[0] as? NSObject)?.perform(
            NSSelectorFromString("accessibilityPerformPress"))
        _ = await pumpUntil(deadline: 3) { closed > 0 }

        XCTAssertEqual(closed, 1)
    }

    // MARK: - Census

    /// **The gate is one more layer of the same `ZStack`**, never a new arm of
    /// `editorPane` — stage 3a's rule, which the book already follows: two
    /// ViewBuilder branches are two view identities, and `EditorHost.onDisappear`
    /// is `doc.close()` + `unregister(path:)` + `loads.abandon()`. A gate on its
    /// own arm would tear the host down on every Show and every Back.
    func test_theGateIsAFourthLayerOfTheSameStackAndNotANewArm() throws {
        let source = try Self.source(of: "Views/ProjectWindow.swift")
        let code = SourceScan.codeLines(of: source)

        XCTAssertTrue(code.contains { $0.contains("DesignGateView(") },
                      "production must mount the gate somewhere")
        let switchLine = try XCTUnwrap(
            code.firstIndex { $0.contains("Self.publishCentre(") },
            "the centre's one switch must still be there")
        let gateLine = try XCTUnwrap(code.firstIndex { $0.contains("DesignGateView(") })
        XCTAssertTrue(gateLine > switchLine && gateLine - switchLine < 40,
                      "the gate is an arm of the publishCentre switch inside "
                      + "manuscriptEditor's ZStack, beside the book's")
    }

    /// **The desk still reads no store** (tripwire 4). The Show affordance is a
    /// closure the host fills, exactly as every other verb on the desk is, so
    /// growing it must not put `DesignProposalStore` on a `body` path — which is
    /// why the pane's own closure takes no argument and the host supplies the
    /// proposal.
    func test_theShowAffordanceLeavesThePanesCensusTrue() throws {
        let code = SourceScan.codeLines(
            of: try Self.source(of: "Views/Publish/DepartmentPane.swift"))

        XCTAssertTrue(code.contains { $0.contains("showProposal") },
                      "the pane must draw the affordance")
        XCTAssertFalse(code.contains { $0.contains("DesignProposalStore") },
                       "the pane may not name the store it would have to read "
                       + "to know which proposal Show is about (tripwire 4)")
    }

    // MARK: - Fixtures

    private static func proposal(
        round: Int = 2,
        language: String? = nil,
        specMarkdown: String = "## The measure\n\nA 26-line page.",
        filePaths: [String] = ["template.tex"],
        status: DesignProposalStore.Status = .pending,
        sampleResult: DesignProposalStore.SampleResult? = nil
    ) -> DesignProposalStore.Proposal {
        DesignProposalStore.Proposal(
            id: "prop-abc123", designerName: "Tschichold", round: round,
            language: language, created: Date(timeIntervalSince1970: 1_770_000_000),
            status: status, specMarkdown: specMarkdown, filePaths: filePaths,
            sampleResult: sampleResult, revertNote: nil)
    }

    private static func report() -> DesignerReport {
        DesignerReport(
            specMarkdown: "## The measure\n\nA 26-line page.",
            files: [DesignerReport.ProposedFile(
                path: "template.tex", content: "\\documentclass{article}")])
    }

    /// Rewrite a staged `proposal.json` as raw JSON — the only way to build the
    /// file an OLDER build would have written, since this build's encoder cannot
    /// produce it any more.
    private static func rewrite(
        proposalAt dir: URL,
        _ transform: ([String: Any]) -> [String: Any]
    ) throws {
        let url = dir.appendingPathComponent("proposal.json")
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        try JSONSerialization
            .data(withJSONObject: transform(json), options: [.sortedKeys])
            .write(to: url, options: .atomic)
    }

    // MARK: - Hosting

    private func mountGate(_ proposal: DesignProposalStore.Proposal,
                           onClose: @escaping () -> Void = { }) -> NSWindow {
        mount(AnyView(DesignGateView(proposal: proposal, projectURL: temp.url,
                                     onClose: onClose)),
              width: 900)
    }

    private func mountDesk(proposals: [DesignProposalStore.Proposal],
                           showProposal: @escaping () -> Void) -> NSWindow {
        let row = DepartmentDesignRow.resolve(
            designerName: "Tschichold", proposals: proposals,
            runState: .idle, session: .free, hasOpenProposalRound: false)
        return mount(AnyView(DepartmentPane(title: "The Project", languages: [],
                                            design: row,
                                            showProposal: showProposal)),
                     width: 340)
    }

    private func mount(_ view: AnyView, width: CGFloat) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: width, height: 640)
        let hosting = NSHostingView(rootView: AnyView(
            view.frame(maxWidth: .infinity, maxHeight: .infinity)))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump(0.1)
        return window
    }

    /// Wait for the mounted surface to publish anything at all, then settle. A
    /// gate draws a scroller for its rail; a desk draws one for its sections.
    @discardableResult
    private func settling(in window: NSWindow,
                          file: StaticString = #filePath,
                          line: UInt = #line) async throws -> [NSScrollView] {
        var found: [NSScrollView] = []
        _ = await pumpUntil(deadline: 5) {
            found = self.collect(NSScrollView.self, in: window)
            return !found.isEmpty
        }
        pump(0.2)
        found = collect(NSScrollView.self, in: window)
        XCTAssertFalse(found.isEmpty, "nothing mounted at all",
                       file: file, line: line)
        return found
    }

    // MARK: - Reading the mounted window

    private func axButtons(labelled label: String,
                           in window: NSWindow) throws -> [AnyObject] {
        _ = try axButtonLabels(in: window)   // the skip check, in one place
        let root = try XCTUnwrap(window.contentView)
        return axElements(under: root)
            .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            .filter { (axAttribute($0, "accessibilityLabel") as? String) == label }
    }

    private func axButtonLabels(in window: NSWindow) throws -> [String] {
        try requireAssistiveClient()
        let root = try XCTUnwrap(window.contentView)
        return axElements(under: root)
            .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            .compactMap { axAttribute($0, "accessibilityLabel") as? String }
    }

    private func axTexts(in window: NSWindow) throws -> [String] {
        try requireAssistiveClient()
        let root = try XCTUnwrap(window.contentView)
        return axElements(under: root).flatMap { element -> [String] in
            [axAttribute(element, "accessibilityValue") as? String,
             axAttribute(element, "accessibilityLabel") as? String]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
        }
    }

    /// SwiftUI builds no accessibility tree at all unless an assistive client is
    /// attached to the process, so a tree that was never built is not evidence
    /// about this view — skip by name rather than fail (CLAUDE.md's rule for a
    /// mounted test reading a premise off the machine).
    private func requireAssistiveClient() throws {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process "
                + "(AXUIElementCopyAttributeValue -> \(error.rawValue)), so "
                + "SwiftUI never builds the tree this test reads")
        }
    }

    private func axAttribute(_ element: AnyObject, _ attribute: String) -> Any? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(attribute)) else { return nil }
        return object.value(forKey: attribute)
    }

    private func axElements(under root: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 40 else { return [] }
        let children = axAttribute(root, "accessibilityChildren") as? [AnyObject] ?? []
        return [root] + children.flatMap { axElements(under: $0, depth: depth + 1) }
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

    private func pump(_ seconds: TimeInterval = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func pumpUntil(deadline: TimeInterval,
                           _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return true }
            pump(0.05)
        }
        return condition()
    }

    // MARK: - Reading the source

    private static func source(of relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
        return try String(contentsOf: root.appendingPathComponent(relativePath),
                          encoding: .utf8)
    }
}
