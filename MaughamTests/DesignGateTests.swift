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
/// **And since Task 6, the verdict itself.** Approve / Request Changes / Revert /
/// Finalize sit in the gate's footer, and three things about them are pinned
/// here: which verbs a proposal offers (a pure function of its status), that
/// every refusal arrives in its OWN words on the delivery path (Global Constraint
/// 2/4), and that a verb's result is written back into the window — because the
/// gate holds its proposal as a VALUE, and a verb that answered with the value it
/// was handed would leave Approve on screen over a design already live.
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

    // MARK: - The verbs: what a proposal offers (Task 6, no window)

    /// **A proposal waiting on the writer offers Approve** — and Request Changes
    /// only while the session that made it can still be asked to revise it, which
    /// is the desk's own rule (`DepartmentDesignRow.offersRequestChanges`): outside
    /// that window the honest verb is a fresh Run, which lives on the desk.
    func test_aPendingProposalOffersApproveAndIterationWhileTheRoundIsOpen() {
        XCTAssertEqual(
            DesignGate.verbs(status: .pending, hasOpenProposalRound: false),
            [.approve],
            "a closed round leaves Approve as the only thing to do here")
        XCTAssertEqual(
            DesignGate.verbs(status: .pending, hasOpenProposalRound: true),
            [.approve, .requestChanges])
    }

    /// **An approved proposal offers the two ways out of a standing promotion**,
    /// and no longer offers Approve. `ProposalPromotion`'s type doc is the reason
    /// there are exactly two: the backup holding the writer's originals is a
    /// single slot, and Revert (put them back) and Finalize (let them go, by
    /// name) are how it is freed.
    func test_anApprovedProposalOffersRevertAndFinalizeAndNotApprove() {
        let verbs = DesignGate.verbs(status: .approved, hasOpenProposalRound: true)

        XCTAssertEqual(verbs, [.revert, .finalize])
        XCTAssertFalse(verbs.contains(.approve),
                       "a design already live is not one to approve again")
        XCTAssertFalse(verbs.contains(.requestChanges),
                       "…nor one the writer is still iterating on")
    }

    /// **A proposal past deciding offers nothing and says why.** A footer with
    /// neither a verb nor a reason is the blank RULING-7's shape forbids: it
    /// reads as a surface that failed to load rather than as a decision already
    /// taken.
    func test_aSettledProposalOffersNothingAndSaysWhyInstead() throws {
        for status: DesignProposalStore.Status in
            [.rejected, .superseded, .unknown("archived")] {
            XCTAssertEqual(
                DesignGate.verbs(status: status, hasOpenProposalRound: true), [],
                "\(status) is not a verdict the writer can still give")
            let note = try XCTUnwrap(
                DesignGate.settledNote(Self.proposal(status: status)),
                "\(status) draws no verbs, so it owes the writer a sentence")
            XCTAssertFalse(note.isEmpty)
        }

        for status: DesignProposalStore.Status in [.pending, .approved] {
            XCTAssertNil(DesignGate.settledNote(Self.proposal(status: status)),
                         "\(status) has verbs; a settled note beside them would "
                         + "tell the writer the decision is already made")
        }
    }

    /// **A reverted round says the revert's own words**, not a sentence invented
    /// here. `ProposalPromotion.revert` writes the note where the cause is known
    /// — the writer's own words when they gave any, its standing sentence when
    /// they did not — and the gate is where that note is read.
    func test_aRevertedRoundShowsTheNoteTheRevertWrote() throws {
        var reverted = Self.proposal(status: .rejected)
        reverted.revertNote = ProposalPromotion.defaultRevertNote

        XCTAssertEqual(DesignGate.settledNote(reverted),
                       ProposalPromotion.defaultRevertNote)

        var wordless = Self.proposal(status: .rejected)
        wordless.revertNote = "   "
        XCTAssertEqual(DesignGate.settledNote(wordless), DesignGate.turnedDownNote,
                       "a rejected proposal with nothing on record still says "
                       + "something — an empty box where a reason goes is the "
                       + "failure this whole surface is written against")
    }

    /// **A status from a newer build is carried raw**, `DepartmentDesignRow
    /// .statusWord`'s discipline: printing "unknown" over it would tell the
    /// writer their proposal is broken when it is merely from the future.
    func test_aStatusFromANewerBuildIsNamedRatherThanCalledBroken() throws {
        let note = try XCTUnwrap(
            DesignGate.settledNote(Self.proposal(status: .unknown("archived"))))
        XCTAssertTrue(note.contains("archived"), note)
    }

    // MARK: - The verbs: every refusal renders its own sentence (Constraint 2/4)

    /// **The four refusals, each in its own words, each earned against a real
    /// project.** This is the brief's sharpest clause and the reason the verbs
    /// go through `DesignGatePromotion` rather than swallowing a throw: a writer
    /// who presses Approve and is told nothing cannot tell a refusal from a bug.
    ///
    /// Driven end-to-end rather than by constructing the errors, because what is
    /// under test is that the sentence REACHES the surface — a `catch` that
    /// logged and returned would pass an errors-are-well-worded test.
    func test_everyRefusalReachesTheGateInItsOwnWords() async throws {
        let project = try Self.publishProject(in: temp.url)
        let store = DesignProposalStore(projectURL: project)
        let first = try store.stage(report: Self.report(), round: 1,
                                    designerName: "Tschichold", language: nil)
        let second = try store.stage(report: Self.report(), round: 2,
                                     designerName: "Tschichold", language: nil)

        // 1. A compile is running. Names the job, because a writer with two
        //    editions compiling needs to know which one to wait for.
        let busy = CompileJobManager()
        let jobID = await busy.register(phase: .compiling)
        let compiling = try Self.refusal(
            await DesignGatePromotion.approve(first, projectURL: project,
                                              jobManager: busy))
        XCTAssertTrue(compiling.contains(jobID),
                      "the busy-compile refusal must name the job: \(compiling)")

        // 2. Finalize with nothing promoted — named before the slot is taken, so
        //    the sentence is about this proposal rather than another's backup.
        let nothingToFinalize = try Self.refusal(
            DesignGatePromotion.finalize(first, projectURL: project))
        XCTAssertTrue(nothingToFinalize.contains(first.id), nothingToFinalize)

        // Promote the first round for real; the two remaining refusals are both
        // about the backup slot it now holds.
        guard case .done = await DesignGatePromotion.approve(
            first, projectURL: project, jobManager: CompileJobManager())
        else { return XCTFail("the first approval should have gone through") }

        // 3. The same proposal again: its own backup already stands.
        let doubleApprove = try Self.refusal(
            await DesignGatePromotion.approve(first, projectURL: project,
                                              jobManager: CompileJobManager()))
        XCTAssertTrue(doubleApprove.contains(first.id), doubleApprove)

        // 4. A DIFFERENT proposal, refused by the project's one backup slot —
        //    naming the proposal holding it and both ways out.
        let slotTaken = try Self.refusal(
            await DesignGatePromotion.approve(second, projectURL: project,
                                              jobManager: CompileJobManager()))
        XCTAssertTrue(slotTaken.contains(first.id),
                      "the slot refusal names the proposal holding it: \(slotTaken)")
        for wayOut in ["Revert", "finalize"] {
            XCTAssertTrue(slotTaken.localizedCaseInsensitiveContains(wayOut),
                          "the slot refusal offers \(wayOut) as a way out: "
                          + slotTaken)
        }

        let sentences = [compiling, nothingToFinalize, doubleApprove, slotTaken]
        XCTAssertEqual(Set(sentences).count, sentences.count,
                       "four different refusals, four different sentences — a "
                       + "shared one teaches the writer nothing about which "
                       + "wall they hit: \(sentences)")
        for sentence in sentences { XCTAssertFalse(sentence.isEmpty) }
    }

    /// **A refusal that is not the promotion's own still gets a sentence.** A
    /// promotion is file I/O against the writer's own folder, and a permissions
    /// error or a project that moved must not be the one press that produces
    /// silence.
    func test_aFailureThePromotionDoesNotNameStillSaysSomething() async throws {
        let gone = temp.url.appendingPathComponent("no-such-project")
        let sentence = try Self.refusal(
            await DesignGatePromotion.approve(Self.proposal(), projectURL: gone,
                                              jobManager: CompileJobManager()))
        XCTAssertFalse(sentence.isEmpty)

        struct Wordless: Error { }
        XCTAssertFalse(DesignGate.refusalSentence(Wordless()).isEmpty)
    }

    // MARK: - The verbs: the status the writer sees is the one on disk

    /// **Approve hands back the APPROVED proposal, not the one it was given.**
    ///
    /// Task 5's ledgered concern, closed. The gate holds its proposal as a value
    /// — deliberately, so nothing reads `.maugham/design/` on a body path — and
    /// `ProposalPromotion.approve` marks it approved as its LAST step, on disk,
    /// where the caller's copy cannot see it. A verb that answered with the value
    /// it was handed would leave the gate offering Approve over a proposal it had
    /// just approved.
    func test_approveHandsBackTheApprovedProposalRatherThanTheStaleSnapshot() async throws {
        let project = try Self.publishProject(in: temp.url)
        let staged = try DesignProposalStore(projectURL: project)
            .stage(report: Self.report(), round: 1,
                   designerName: "Tschichold", language: nil)
        XCTAssertEqual(staged.status, .pending)

        let settled = try Self.settled(
            await DesignGatePromotion.approve(staged, projectURL: project,
                                              jobManager: CompileJobManager()))

        XCTAssertEqual(settled.status, .approved,
                       "the value handed back is what the store now holds")
        XCTAssertEqual(DesignGate.verbs(status: settled.status,
                                        hasOpenProposalRound: false),
                       [.revert, .finalize],
                       "…which is what makes the footer reconfigure on the very "
                       + "next body pass")
    }

    /// **Revert hands back the rejected proposal WITH its note**, which is the
    /// only thing the gate then has to say about that round.
    func test_revertHandsBackTheRejectedProposalAndItsNote() async throws {
        let project = try Self.publishProject(in: temp.url)
        let staged = try DesignProposalStore(projectURL: project)
            .stage(report: Self.report(), round: 1,
                   designerName: "Tschichold", language: nil)
        _ = await DesignGatePromotion.approve(staged, projectURL: project,
                                              jobManager: CompileJobManager())

        let settled = try Self.settled(
            await DesignGatePromotion.revert(staged, projectURL: project,
                                             jobManager: CompileJobManager()))

        XCTAssertEqual(settled.status, .rejected)
        XCTAssertEqual(DesignGate.settledNote(settled),
                       ProposalPromotion.defaultRevertNote)
        XCTAssertEqual(DesignGate.verbs(status: settled.status,
                                        hasOpenProposalRound: true), [],
                       "a reverted round is read-only from here on")
    }

    /// **Finalize keeps the proposal approved and takes the way back away.**
    /// It is the one verb whose result is invisible in the proposal's status —
    /// what it changes is what can be undone — which is exactly why it answers
    /// with a sentence of its own.
    func test_finalizeKeepsTheStatusAndDiscardsTheBackup() async throws {
        let project = try Self.publishProject(in: temp.url)
        let store = DesignProposalStore(projectURL: project)
        let staged = try store.stage(report: Self.report(), round: 1,
                                     designerName: "Tschichold", language: nil)
        _ = await DesignGatePromotion.approve(staged, projectURL: project,
                                              jobManager: CompileJobManager())
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.backupDir(id: staged.id).path))

        let outcome = DesignGatePromotion.finalize(staged, projectURL: project)

        XCTAssertEqual(try Self.settled(outcome).status, .approved)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.backupDir(id: staged.id).path),
            "the displaced templates are gone — that is the whole verb")
        guard case .done(_, let sentence) = outcome else {
            return XCTFail("finalize should have answered .done")
        }
        XCTAssertEqual(sentence, DesignGate.finalizedConfirmation,
                       "the one verb with no visible status change is the one "
                       + "that most needs to say it happened")
    }

    /// **A verb that worked announces itself, and one that refused does not.**
    ///
    /// The department desk one column over lists `.maugham/design/proposals/` in
    /// a `.task` whose key watches the designer's RUN state — and a promotion is
    /// not a run, so without this post the desk goes on saying "waiting for your
    /// review" over a proposal the writer just approved (Task 5's concern 1, the
    /// half the value hand-back cannot reach).
    func test_aVerbThatWorkedTellsTheRestOfTheWindow() async throws {
        let project = try Self.publishProject(in: temp.url)
        let staged = try DesignProposalStore(projectURL: project)
            .stage(report: Self.report(), round: 1,
                   designerName: "Tschichold", language: nil)

        var announcements = 0
        let token = NotificationCenter.default.addObserver(  // adr-0021-ok: a test observing the post, not a production receiver
            forName: .maughamDesignProposalsChanged, object: nil, queue: .main) { note in
                guard note.userInfo?[MaughamEvent.scopeIdKey] as? String
                    == ProjectIdentifier.id(for: project) else { return }
                announcements += 1
            }
        defer { NotificationCenter.default.removeObserver(token) }

        _ = await DesignGatePromotion.approve(staged, projectURL: project,
                                              jobManager: CompileJobManager())
        XCTAssertEqual(announcements, 1,
                       "an approval must reach the desk's Design row")

        // …and a refusal is not news: nothing on disk moved.
        _ = await DesignGatePromotion.approve(staged, projectURL: project,
                                              jobManager: CompileJobManager())
        XCTAssertEqual(announcements, 1,
                       "a refused verb changed nothing, so it announces nothing")
    }

    // MARK: - The verbs, mounted

    /// **The gate draws what the proposal offers, and nothing else.** Read off
    /// the accessibility tree because the contract is about what a writer can
    /// reach — and each verb carries a label of its own, since "Revert" told
    /// apart only by the surface it sits on is not something a linear tree
    /// carries.
    func test_thePendingGateDrawsApproveAndRequestChangesAndNoWayBackFromNowhere()
        async throws {
        let window = mountGate(Self.proposal(status: .pending),
                               hasOpenProposalRound: true)
        _ = try await settling(in: window)

        let labels = try axButtonLabels(in: window)
        for offered: DesignGate.Verb in [.approve, .requestChanges] {
            XCTAssertTrue(labels.contains(offered.accessibilityLabel),
                          "\(offered) is not on the gate. Published: \(labels.sorted())")
        }
        for absent: DesignGate.Verb in [.revert, .finalize] {
            XCTAssertFalse(labels.contains(absent.accessibilityLabel),
                           "\(absent) has nothing to act on over a proposal that "
                           + "was never promoted. Published: \(labels.sorted())")
        }
    }

    /// …and an approved one draws the two ways out instead.
    func test_theApprovedGateDrawsRevertAndFinalize() async throws {
        let window = mountGate(Self.proposal(status: .approved),
                               hasOpenProposalRound: true)
        _ = try await settling(in: window)

        let labels = try axButtonLabels(in: window)
        for offered: DesignGate.Verb in [.revert, .finalize] {
            XCTAssertTrue(labels.contains(offered.accessibilityLabel),
                          "\(offered) is not on the gate. Published: \(labels.sorted())")
        }
        XCTAssertFalse(labels.contains(DesignGate.Verb.approve.accessibilityLabel),
                       "Published: \(labels.sorted())")
    }

    /// **A settled proposal draws no verbs and says why on screen.**
    func test_aTurnedDownRoundDrawsItsNoteAndNoVerdicts() async throws {
        var reverted = Self.proposal(status: .rejected)
        reverted.revertNote = "Reverted — the ligatures broke in the Spanish edition."
        let window = mountGate(reverted, hasOpenProposalRound: true)
        _ = try await settling(in: window)

        let labels = try axButtonLabels(in: window)
        for verb in DesignGate.Verb.allCases {
            XCTAssertFalse(labels.contains(verb.accessibilityLabel),
                           "\(verb) over a round already turned down. "
                           + "Published: \(labels.sorted())")
        }
        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains { $0.contains("ligatures broke") },
                      "the revert's own note is not on the gate. "
                      + "Published: \(texts.sorted())")
    }

    /// **A refused verb puts its own sentence on the gate**, on the delivery
    /// path: pressed through the accessibility tree, with the refusal travelling
    /// from the seam exactly as production's does.
    func test_aRefusedVerbDrawsItsSentenceRatherThanDoingNothingVisible()
        async throws {
        let sentence = "a compile is running (job-7) — wait for it, or cancel it."
        var actions = DesignGateActions()
        actions.approve = { _ in .refused(sentence) }
        let window = mountGate(Self.proposal(status: .pending), actions: actions)
        _ = try await settling(in: window)

        try press(.approve, in: window)
        _ = await pumpUntil(deadline: 3) {
            ((try? self.axTexts(in: window)) ?? []).contains { $0.contains(sentence) }
        }

        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains { $0.contains(sentence) },
                      "the refusal is not on screen. Published: \(texts.sorted())")
    }

    /// **A verb's result reaches the window, so the gate cannot lie about where
    /// the proposal stands.**
    ///
    /// The delivery-path half of Task 5's ledgered concern: the gate's proposal
    /// is `ProjectWindow.publishSelectedProposal`, and unless the verb writes the
    /// refreshed value back into it the surface keeps drawing the snapshot it
    /// opened with — Approve still offered, "waiting for your review" still in
    /// the header, over templates that are already live.
    func test_aVerbsResultIsWrittenBackSoTheGateCannotLieAboutTheStatus()
        async throws {
        var approved = Self.proposal(status: .pending)
        approved.status = .approved
        var actions = DesignGateActions()
        actions.approve = { _ in
            .done(approved, sentence: DesignGate.approvedConfirmation)
        }
        var handedUp: [DesignProposalStore.Status] = []
        let window = mountGate(Self.proposal(status: .pending), actions: actions,
                               onProposalChanged: { handedUp.append($0.status) })
        _ = try await settling(in: window)

        try press(.approve, in: window)
        _ = await pumpUntil(deadline: 3) { !handedUp.isEmpty }

        XCTAssertEqual(handedUp, [.approved],
                       "the window's own copy of the proposal must move, or the "
                       + "gate goes on offering Approve over a live design")
    }

    /// **Request Changes takes the writer's words and reports what happened
    /// either way** — the one verb here that does not touch the publish tree, and
    /// the one whose refusal comes back as a sentence rather than an outcome.
    func test_requestChangesSendsTheWritersWordsAndSaysWhenItCannot() async throws {
        var sent: [String] = []
        var actions = DesignGateActions()
        actions.requestChanges = { words in
            sent.append(words)
            return words.isEmpty ? DepartmentDesignRow.noWordsRefusal : nil
        }
        let window = mountGate(Self.proposal(status: .pending), actions: actions,
                               hasOpenProposalRound: true)
        _ = try await settling(in: window)

        try press(.requestChanges, in: window)
        _ = await pumpUntil(deadline: 3) { !sent.isEmpty }

        XCTAssertEqual(sent, [""], "the field's words, whatever they are")
        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains {
            $0.contains(DepartmentDesignRow.noWordsRefusal)
        }, "the refusal is not on screen. Published: \(texts.sorted())")
    }

    // MARK: - Finalize asks first

    /// **Finalize is the one verb that asks, and its question names the cost.**
    ///
    /// The other three are all recoverable from the surface itself: Approve is
    /// undone by the Revert it puts on screen the same frame, Request Changes
    /// moves no byte of the publish tree, and Revert IS the way back. Finalize
    /// discards the writer's own displaced templates — and it is also the verb
    /// whose success changes nothing visible about the proposal, so a mis-click
    /// there is an irreversible loss that looks like a no-op.
    func test_finalizeIsTheOneVerbThatAsksFirstAndItsQuestionNamesTheCost() throws {
        for immediate: DesignGate.Verb in [.approve, .requestChanges, .revert] {
            XCTAssertNil(
                DesignGate.confirmation(for: immediate, perform: { }, cancel: { }),
                "\(immediate) is recoverable — a dialog in front of it is "
                + "ceremony the writer learns to click through")
        }

        let confirmation = try XCTUnwrap(
            DesignGate.confirmation(for: .finalize, perform: { }, cancel: { }))
        XCTAssertEqual(confirmation.verb, .finalize)
        XCTAssertEqual(confirmation.message, DesignGate.finalizeCost,
                       "the question must say what is lost, not merely ask "
                       + "whether the writer is sure")
        XCTAssertTrue(confirmation.message.localizedCaseInsensitiveContains("discarded"),
                      confirmation.message)
        XCTAssertEqual(confirmation.confirmTitle, DesignGate.Verb.finalize.title,
                       "the button that finalizes is labelled with the verb the "
                       + "writer pressed")
        XCTAssertEqual(confirmation.cancelTitle, DesignGate.cancelTitle)
        XCTAssertFalse(confirmation.title.isEmpty)
    }

    /// **One spelling of the cost.** The hover and the dialog are the same
    /// promise made twice; a writer who read one and met a different sentence in
    /// the other would have to work out whether they describe the same act.
    func test_theHoverAndTheDialogSayTheCostInTheSameWords() {
        XCTAssertTrue(DesignGate.Verb.finalize.help.contains(DesignGate.finalizeCost),
                      "the tooltip must carry the one spelling: "
                      + DesignGate.Verb.finalize.help)
    }

    /// **Pressing Finalize reaches no promotion until the writer says yes** — on
    /// the delivery path, pressed through the accessibility tree the way a click
    /// presses it.
    func test_pressingFinalizeReachesNoPromotionUntilTheWriterSaysYes() async throws {
        let calls = Box(0)
        let pending = Box<[DesignGateConfirmation?]>([])
        var actions = DesignGateActions()
        actions.finalize = { proposal in
            calls.value += 1
            return .done(proposal, sentence: DesignGate.finalizedConfirmation)
        }
        let window = mountGate(Self.proposal(status: .approved), actions: actions,
                               onConfirmationChanged: { pending.value.append($0) })
        _ = try await settling(in: window)

        let confirmation = try await pressAwaitingConfirmation(
            .finalize, in: window, pending: pending)

        XCTAssertEqual(calls.value, 0,
                       "the press ran the promotion before the writer had "
                       + "answered — the confirmation would be decoration")
        XCTAssertEqual(confirmation.verb, .finalize)
    }

    /// **Cancelling leaves the promotion exactly as it stood** — against a real
    /// project, because what a cancelled Finalize must not touch is the backup
    /// holding the writer's own templates, and a spy closure cannot tell me
    /// whether that folder is still there.
    func test_cancellingTheConfirmationLeavesTheBackupStanding() async throws {
        let project = try Self.publishProject(in: temp.url)
        let store = DesignProposalStore(projectURL: project)
        let staged = try store.stage(report: Self.report(), round: 1,
                                     designerName: "Tschichold", language: nil)
        let approved = try Self.settled(
            await DesignGatePromotion.approve(staged, projectURL: project,
                                              jobManager: CompileJobManager()))
        let backup = store.proposalDir(id: approved.id)
            .appendingPathComponent("backup", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path),
                      "premise: the promotion stands and its backup holds the "
                      + "writer's originals")

        let pending = Box<[DesignGateConfirmation?]>([])
        var actions = DesignGateActions()
        actions.finalize = { proposal in
            DesignGatePromotion.finalize(proposal, projectURL: project)
        }
        let window = mountGate(approved, projectURL: project, actions: actions,
                               onConfirmationChanged: { pending.value.append($0) })
        _ = try await settling(in: window)

        let confirmation = try await pressAwaitingConfirmation(
            .finalize, in: window, pending: pending)
        confirmation.cancel()
        _ = await pumpUntil(deadline: 1) { (pending.value.last ?? nil) == nil }

        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path),
                      "a cancelled Finalize discarded the backup — the writer "
                      + "said no and lost their templates anyway")
        XCTAssertNil(pending.value.last ?? nil,
                     "…and nothing is left waiting on an answer already given")
    }

    /// **Saying yes runs the verb, writes the result back, and announces it.**
    /// The whole of what the press used to do, now one gesture further along —
    /// including the post the desk in the other column listens for, since a
    /// confirmation that swallowed it would leave the Design row describing a
    /// proposal whose backup is gone.
    func test_confirmingFinalizeRunsTheVerbAndTellsTheRestOfTheWindow() async throws {
        let project = try Self.publishProject(in: temp.url)
        let store = DesignProposalStore(projectURL: project)
        let staged = try store.stage(report: Self.report(), round: 1,
                                     designerName: "Tschichold", language: nil)
        let approved = try Self.settled(
            await DesignGatePromotion.approve(staged, projectURL: project,
                                              jobManager: CompileJobManager()))
        let backup = store.proposalDir(id: approved.id)
            .appendingPathComponent("backup", isDirectory: true)

        var announcements = 0
        let token = NotificationCenter.default.addObserver(  // adr-0021-ok: a test observing the post, not a production receiver
            forName: .maughamDesignProposalsChanged, object: nil, queue: .main) { note in
                guard note.userInfo?[MaughamEvent.scopeIdKey] as? String
                    == ProjectIdentifier.id(for: project) else { return }
                announcements += 1
            }
        defer { NotificationCenter.default.removeObserver(token) }

        let pending = Box<[DesignGateConfirmation?]>([])
        let handedUp = Box<[DesignProposalStore.Status]>([])
        var actions = DesignGateActions()
        actions.finalize = { proposal in
            DesignGatePromotion.finalize(proposal, projectURL: project)
        }
        let window = mountGate(approved, projectURL: project, actions: actions,
                               onProposalChanged: { handedUp.value.append($0.status) },
                               onConfirmationChanged: { pending.value.append($0) })
        _ = try await settling(in: window)

        let confirmation = try await pressAwaitingConfirmation(
            .finalize, in: window, pending: pending)
        confirmation.perform()
        _ = await pumpUntil(deadline: 5) { !handedUp.value.isEmpty }

        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path),
                       "the writer said yes and the backup is still there — the "
                       + "confirmation ate the verb")
        XCTAssertEqual(handedUp.value, [.approved],
                       "finalizing changes what can be undone, not what shipped "
                       + "— but the refreshed proposal still reaches the window")
        XCTAssertEqual(announcements, 1,
                       "the desk in the other column never heard the verdict")

        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains { $0.contains(DesignGate.finalizedConfirmation) },
                      "the one verb with no visible status change said nothing "
                      + "at all. Published: \(texts.sorted())")
    }

    // MARK: - Census (Task 6)

    /// **`requestChanges` has one spelling, and both surfaces reach it.**
    ///
    /// The desk composed the call and its three refusals inline until this task;
    /// the gate is the second surface to want them, and a copy would be two
    /// answers to "why did that not go" — free to drift the moment
    /// `DesignerOrchestrator.requestChanges` grows a fifth guard, which is
    /// exactly what `unknownRefusal` exists against.
    func test_requestChangesHasOneSpellingAndBothSurfacesReachIt() throws {
        let orchestratorCallers = try ["Views/Publish/DepartmentDesignRow.swift",
                                       "Views/Publish/DepartmentPaneHost.swift",
                                       "Views/Publish/DesignGateView.swift",
                                       "Views/Publish/DesignGateVerbs.swift",
                                       "Views/ProjectWindow.swift"]
            .filter { path in
                SourceScan.codeLines(of: try Self.source(of: path))
                    .contains { $0.contains("designer.requestChanges(") }
            }
        XCTAssertEqual(orchestratorCallers,
                       ["Views/Publish/DepartmentDesignRow.swift"],
                       "the orchestrator's verb is called from `sendChanges` and "
                       + "nowhere else in this department")

        for surface in ["Views/Publish/DepartmentPaneHost.swift",
                        "Views/ProjectWindow.swift"] {
            XCTAssertTrue(
                SourceScan.codeLines(of: try Self.source(of: surface))
                    .contains { $0.contains("DepartmentDesignRow.sendChanges") },
                "\(surface) must reach the one spelling rather than compose its own")
        }
    }

    /// **Nothing about the gate's verbs reaches `NSUndoManager`** — the
    /// stored-reversal ruling, which `ProposalPromotion`'s type doc settles and
    /// this surface is the one most likely to forget.
    ///
    /// *Undoable* here is `revert`: a verb the writer asks for by name. A ⌘Z in a
    /// text pane must never, at any depth of an undo stack it happens to share,
    /// un-ship a book's templates — those two acts have nothing in common but a
    /// keystroke, and the keystroke belongs to the prose.
    func test_nothingAboutTheGatesVerbsReachesTheUndoManager() throws {
        let banned = ["NSUndoManager", "undoManager", "registerUndo",
                      "UndoBracket", "beginUndoGrouping"]
        for path in ["Publish/ProposalPromotion.swift",
                     "Stores/DesignProposalStore.swift",
                     "Views/Publish/DesignGateVerbs.swift",
                     "Views/Publish/DesignGateView.swift"] {
            let code = SourceScan.codeLines(of: try Self.source(of: path))
            for token in banned {
                XCTAssertFalse(
                    code.contains { $0.contains(token) },
                    "\(path) names \(token) in code. Approving a design is a "
                    + "stored reversal (Revert), never an undo registration.")
            }
        }
    }

    /// **The window hands the gate its verbs**, and hands the result back into
    /// the one piece of state the gate arm is a function of. The bridge from the
    /// seam's spelling to production's — without it every mounted test above
    /// passes over a surface nothing wires up.
    func test_theWindowWiresTheVerbsAndTakesTheirResultBack() throws {
        let code = SourceScan.codeLines(of: try Self.source(of: "Views/ProjectWindow.swift"))

        XCTAssertTrue(code.contains { $0.contains("actions:") && $0.contains("designGateActions") }
                      || code.contains { $0.contains("designGateActions(") },
                      "the gate must be given a wired `DesignGateActions`")
        XCTAssertTrue(
            code.contains { $0.contains("onProposalChanged:") },
            "…and the window must take the refreshed proposal back, or the gate "
            + "draws the snapshot it opened with for the rest of the session")
        XCTAssertTrue(
            code.contains { $0.contains("DesignGatePromotion.") },
            "the verbs run through the one performer, which is what re-reads the "
            + "proposal and announces the change")
    }

    /// **The desk re-derives when the gate acts.** The other half of the
    /// write-back: `ProjectWindow`'s state feeds the gate, and the desk in the
    /// right column has its own listing keyed on the designer's run state — which
    /// a promotion never touches.
    func test_theDeskListensForTheGatesVerdict() throws {
        let code = SourceScan.codeLines(
            of: try Self.source(of: "Views/Publish/DepartmentPaneHost.swift"))
        XCTAssertTrue(
            code.contains { $0.contains("maughamDesignProposalsChanged") },
            "the desk must hear a promotion, or its Design row keeps describing "
            + "a status the proposal no longer has")
    }

    // MARK: - Fixtures

    /// A project with a live publish tree to promote onto —
    /// `ProposalPromotionTests`' fixture, built by hand for its reason: what
    /// `approve` needs is that the tree EXISTS and holds the file it is about to
    /// overwrite, and a hand-built one says exactly which bytes are under test.
    private static func publishProject(in root: URL) throws -> URL {
        let projectURL = root.appendingPathComponent("P-\(UUID().uuidString)")
        let publish = projectURL.appendingPathComponent(".maugham/publish",
                                                        isDirectory: true)
        try FileManager.default.createDirectory(at: publish,
                                                withIntermediateDirectories: true)
        try "LIVE ORIGINAL".write(
            to: publish.appendingPathComponent("template.tex"),
            atomically: true, encoding: .utf8)
        return projectURL
    }

    private static func refusal(_ outcome: DesignGateOutcome,
                                file: StaticString = #filePath,
                                line: UInt = #line) throws -> String {
        guard case .refused(let sentence) = outcome else {
            XCTFail("expected a refusal, got \(outcome)", file: file, line: line)
            throw XCTSkip("not a refusal")
        }
        return sentence
    }

    private static func settled(_ outcome: DesignGateOutcome,
                                file: StaticString = #filePath,
                                line: UInt = #line) throws -> DesignProposalStore.Proposal {
        guard case .done(let proposal, _) = outcome else {
            XCTFail("expected the verb to have run, got \(outcome)",
                    file: file, line: line)
            throw XCTSkip("not a completed verb")
        }
        return proposal
    }

    /// Press a verb through the accessibility tree — `DepartmentPaneTests`'
    /// idiom: it is the action a click ultimately performs and, unlike a
    /// synthetic `mouseDown`, it does not need this process to be the active app
    /// (CLAUDE.md's synthetic-click premise).
    private func press(_ verb: DesignGate.Verb, in window: NSWindow) throws {
        let published = try axButtonLabels(in: window).sorted()
        let buttons = try axButtons(labelled: verb.accessibilityLabel, in: window)
        XCTAssertEqual(buttons.count, 1,
                       "one \(verb) on the gate. Buttons: \(published)")
        guard let button = buttons.first else { return }
        _ = (button as? NSObject)?.perform(
            NSSelectorFromString("accessibilityPerformPress"))
    }

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

    private func mountGate(
        _ proposal: DesignProposalStore.Proposal,
        projectURL: URL? = nil,
        actions: DesignGateActions = DesignGateActions(),
        hasOpenProposalRound: Bool = false,
        onClose: @escaping () -> Void = { },
        onProposalChanged: @escaping (DesignProposalStore.Proposal) -> Void = { _ in },
        onConfirmationChanged: @escaping (DesignGateConfirmation?) -> Void = { _ in }
    ) -> NSWindow {
        mount(AnyView(DesignGateView(proposal: proposal,
                                     projectURL: projectURL ?? temp.url,
                                     actions: actions,
                                     hasOpenProposalRound: hasOpenProposalRound,
                                     onClose: onClose,
                                     onProposalChanged: onProposalChanged,
                                     onConfirmationChanged: onConfirmationChanged)),
              width: 900)
    }

    /// Press a verb and wait for the confirmation it owes the writer — the
    /// dialog itself belongs to the window server, so what a headless mount can
    /// hold is the value behind it.
    private func pressAwaitingConfirmation(
        _ verb: DesignGate.Verb, in window: NSWindow, pending: Box<[DesignGateConfirmation?]>,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> DesignGateConfirmation {
        try press(verb, in: window)
        _ = await pumpUntil(deadline: 3) { !pending.value.isEmpty }
        return try XCTUnwrap(pending.value.last ?? nil,
                             "\(verb) never asked the writer anything",
                             file: file, line: line)
    }

    /// A mutable cell an escaping closure can write into from the main actor.
    /// `DepartmentRunTests.Box`'s twin.
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
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
