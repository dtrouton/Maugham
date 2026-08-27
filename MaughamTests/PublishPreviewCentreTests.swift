import XCTest
import AppKit
import SwiftUI
import PDFKit
import Observation
import MaughamCore
@testable import Maugham

/// **Publish's centre is the book — at PROJECT level** (shell-finish stage 3b
/// Task 5, spec §4's Publish column, re-cut by Denver's rulings of 2026-08-12).
///
/// The rulings this suite pins, because they walk back what the merged
/// behaviour asserted:
///
/// 1. **A chapter/piece subject in Publish always opens the editor** — *"I might
///    tweak something for layout."* The preview is a project-level surface: the
///    project row, a group, or nothing selected. The old truth-table tests
///    (a document subject shows the same preview) are wrong by ruling and are
///    replaced here rather than kept.
/// 2. **An uncompiled Publish at project level says so** — altitude plus a
///    standing notice, because a bare unexplained corkboard read as "basically
///    Author".
/// 3. **The unreadable catalog gets a NAMING banner** — RULING-7's shape made
///    visible: two different notices, never one.
/// 4. **The header carries a publication picker** — readable PDFs, newest
///    first; a new compile snaps back to the newest; the choice is
///    window-transient.
///
/// Three things are under test and they need different instruments:
///
/// - **The resolver.** `PublishPreviewResolver` walks the catalog from the TAIL
///   (`PublicationStore.load()` is ascending `compiledAt`) and answers with
///   every row it can actually put on screen. Both of its guards are about facts
///   on disk — a row can outlive its file (`ExportsListView`'s Delete removes the
///   file and never the JSONL), and an unknown format decodes to `.pdf` — so
///   these tests write real catalogs and real PDFs.
/// - **The rule.** `ProjectWindow.publishCentre` is a static over
///   `(persona, subject, structure, resolution)`, so it is assertable with no
///   window at all.
/// - **The shape.** The layer is a THIRD member of `manuscriptEditor`'s
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

        let resolution = await PublishPreviewResolver.readablePDFs(
            store: store, projectURL: project)

        assertReady(resolution, is: newest,
                    "the catalog is ascending, so the writer's most recent "
                    + "compile is its tail — not its head")
    }

    /// **And the picker's rows are the whole of it, newest first** (Denver's
    /// 2026-08-12 ruling 4). The listing is the generalisation of the walk
    /// rather than a second one, which is what says a menu entry cannot exist
    /// for a book this column could not draw.
    func test_thePickerListsEveryReadablePDFNewestFirst() async throws {
        let project = try makeProject()
        let store = PublicationStore(projectURL: project)
        let oldest = try await append(to: store, in: project, version: "0.1", minutesAgo: 30)
        let middle = try await append(to: store, in: project, version: "0.2", minutesAgo: 20)
        let newest = try await append(to: store, in: project, version: "0.3", minutesAgo: 10)

        let resolution = await PublishPreviewResolver.readablePDFs(
            store: store, projectURL: project)

        XCTAssertEqual(resolution.publications.map(\.publicationID),
                       [newest.publicationID, middle.publicationID, oldest.publicationID],
                       "the header picker reads this order and shows it as it "
                       + "stands — newest first, so the writer's last compile is "
                       + "the first row")
        XCTAssertEqual(resolution.publication?.publicationID, newest.publicationID,
                       "…and 'the book' is still the head of that list, so every "
                       + "caller that only wants the newest is unchanged")
    }

    /// **An EPUB is not the book this column can draw** — and it is missing from
    /// the picker for the same reason it is not the book: PDFKit cannot draw it,
    /// and the Exports footer is where it lives.
    func test_theWalkPassesAnEpubAndKeepsLookingForAPDF() async throws {
        let project = try makeProject()
        let store = PublicationStore(projectURL: project)
        let pdf = try await append(to: store, in: project, version: "0.1", minutesAgo: 20)
        let epub = try await append(to: store, in: project, version: "0.2",
                                    format: .epub, minutesAgo: 10)

        let resolution = await PublishPreviewResolver.readablePDFs(
            store: store, projectURL: project)

        assertReady(resolution, is: pdf,
                    "PDFKit cannot draw an EPUB; the newest row this column "
                    + "can show is the PDF underneath it")
        XCTAssertFalse(resolution.publications.contains { $0.publicationID == epub.publicationID },
                       "and it is not offered in the picker either — selecting "
                       + "it would render an empty page")
    }

    /// **A row outlives its file**, which is not a corner case: `ExportsListView`'s
    /// Delete removes the file and never the JSONL, so the newest row in a
    /// working writer's catalog is routinely one whose PDF is gone. The walk
    /// steps past it to the next-newest readable one, and the picker does too.
    func test_aRowWhoseFileWasDeletedIsWalkedPastToTheNextNewest() async throws {
        let project = try makeProject()
        let store = PublicationStore(projectURL: project)
        let older = try await append(to: store, in: project, version: "0.1", minutesAgo: 20)
        let newer = try await append(to: store, in: project, version: "0.2", minutesAgo: 10)
        try FileManager.default.removeItem(
            at: project.appendingPathComponent(newer.outputPath))

        let resolution = await PublishPreviewResolver.readablePDFs(
            store: store, projectURL: project)

        assertReady(resolution, is: older,
                    "the newest row has no file behind it — a centre column "
                    + "built on it would draw an empty PDFView")
        XCTAssertEqual(resolution.publications.map(\.publicationID), [older.publicationID],
                       "the deleted row is not a picker entry either: every "
                       + "guard the walk applies applies per ROW, which is the "
                       + "whole reason the listing generalises the walk instead "
                       + "of standing beside it")
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

        let resolution = await PublishPreviewResolver.readablePDFs(
            store: store, projectURL: project)

        assertReady(resolution, is: real,
                    "`format == .pdf` is a decoded field and an unknown "
                    + "format decodes to it — so the file has to open, not "
                    + "merely be claimed")
        XCTAssertEqual(resolution.publications.map(\.publicationID), [real.publicationID],
                       "…and the picker does not offer it")
    }

    /// Nothing compiled at all: the empty catalog. This is the degrade Denver
    /// asked for, and it now carries a notice of its own.
    func test_anEmptyCatalogIsNothingCompiled() async throws {
        let project = try makeProject()
        let store = PublicationStore(projectURL: project)

        let resolution = await PublishPreviewResolver.readablePDFs(
            store: store, projectURL: project)

        XCTAssertEqual(resolution, .nothingCompiled)
        XCTAssertTrue(resolution.publications.isEmpty,
                      "and no picker rows, which is what makes the header's "
                      + "`count > 1` question safe to ask")
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

        let resolution = await PublishPreviewResolver.readablePDFs(
            store: store, projectURL: project)

        XCTAssertEqual(resolution, .nothingCompiled,
                       "the walk ran off the end — the centre degrades to "
                       + "altitude plus the never-compiled notice rather than "
                       + "drawing a card about a file that is not there")
    }

    /// **`.ready` is never empty**, which is the invariant `publishCentre`'s
    /// otherwise-unreachable ternary leans on. Asserted over every shape of
    /// catalog this suite can build rather than left to the reading.
    func test_theResolverNeverAnswersReadyWithNoBooks() async throws {
        let project = try makeProject()
        let store = PublicationStore(projectURL: project)
        for resolution in [
            await PublishPreviewResolver.readablePDFs(store: store, projectURL: project),
            await PublishPreviewResolver.readablePDFs(in: project, loading: { [] }),
            await PublishPreviewResolver.readablePDFs(
                in: project, loading: { [Self.publication(version: "9.9",
                                                          outputPath: "Exports/ghost.pdf",
                                                          compiledAt: Date())] })
        ] {
            if case .ready(let rows) = resolution {
                XCTAssertFalse(rows.isEmpty,
                               "`.ready` with no rows would put an empty picker "
                               + "and a blank page in front of the writer")
            }
        }
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

        let resolution = await PublishPreviewResolver.readablePDFs(
            store: store, projectURL: project)

        assertReady(resolution, is: pub,
                    "an absolute path is resolved as itself")
    }

    /// **"Unreadable" is never presented as "empty"** (RULING-7's shape, and the
    /// reason this resolver answers with a reason rather than an optional).
    ///
    /// This case drives the loader SEAM, which is what keeps the two answers
    /// assertable side by side in one function. Its companion below,
    /// `test_aRealUnreadableCatalogRefusesThroughTheProductionEntryPoint`, drives
    /// a real squatted device file through the store-taking overload production
    /// actually calls — the reconcile of 2026-08-12 made
    /// `PublicationStore.load()` throw a named
    /// `PublicationStore.ReadError.unreadableFile` (RULING-54), so this arm is
    /// no longer seam-only and the pair is what says the reconcile kept
    /// *unreadable* and *never compiled* apart end to end.
    func test_anUnreadableCatalogIsNotTheSameAnswerAsAnEmptyOne() async {
        struct Unreadable: Error {}

        let unreadable = await PublishPreviewResolver.readablePDFs(
            in: temp.url, loading: { throw Unreadable() })
        let empty = await PublishPreviewResolver.readablePDFs(
            in: temp.url, loading: { [] })

        XCTAssertEqual(unreadable, .unreadableCatalog(reason: Unreadable().localizedDescription),
                       "…carrying what the failure said, so the banner has the "
                       + "sentence")
        XCTAssertEqual(empty, .nothingCompiled)
        XCTAssertNotEqual(
            unreadable, empty,
            "a catalog that exists and cannot be read is a DIFFERENT fact from "
            + "a project that has never been compiled — collapsing them is how "
            + "a writer is told their book was never made")
    }

    /// **The same fact, through the door production uses** — and the sharp part
    /// is the row that IS readable.
    ///
    /// The catalog here holds a good PDF row in this device's own file *and* a
    /// second device file that cannot be read (a directory squatting on its
    /// path — the permissions-break / dataless-stub shape, borrowed from
    /// `PublicationStoreTests`). `PublicationStore.load()` throws
    /// `ReadError.unreadableFile` naming that file (RULING-54), so the resolver
    /// must answer `.unreadableCatalog` **rather than drawing the row it could
    /// see**: the unreadable file may hold a newer edition, and presenting a
    /// stale PDF as "your latest compile" is a lie about the writer's book.
    ///
    /// This is the case the seam-driven test above cannot make — the seam proves
    /// the resolver's arms are distinct, this proves the production loader
    /// actually reaches the unreadable one.
    func test_aRealUnreadableCatalogRefusesThroughTheProductionEntryPoint() async throws {
        let project = try makeProject()
        let store = PublicationStore(projectURL: project)
        try await append(to: store, in: project, version: "0.1", minutesAgo: 10)

        // Sanity: with the catalog readable, this project HAS a book to show —
        // so the refusal below is caused by the unreadable file and nothing else.
        let before = await PublishPreviewResolver.readablePDFs(
            store: store, projectURL: project)
        XCTAssertNotNil(before.publication,
                        "precondition: a readable catalog with a real PDF shows the book")

        let squatted = PublicationStore.fileURL(
            deviceSlug: DeviceSlug.make(from: "otherdevice"), in: project)
        try FileManager.default.createDirectory(
            at: squatted, withIntermediateDirectories: true)

        let resolution = await PublishPreviewResolver.readablePDFs(
            store: store, projectURL: project)

        guard case .unreadableCatalog(let reason) = resolution else {
            XCTFail("an unreadable device file must refuse the preview, got \(resolution) "
                    + "— drawing the row we happened to be able to read presents a "
                    + "possibly-stale PDF as the writer's latest compile")
            return
        }
        XCTAssertNotEqual(resolution, .nothingCompiled,
                          "RULING-7: unreadable is never presented as empty")
        XCTAssertTrue(reason.contains(squatted.lastPathComponent),
                      "the banner's sentence names the file that could not be "
                      + "read, so the writer knows what to fix — got: \(reason)")
    }

    /// **Which book the header draws is the writer's pick, and the fallback is
    /// the load-bearing half** (`PublishPreviewResolver.shown`). The pick can
    /// leave the list underneath them — they delete the export in the Finder, a
    /// compile lands and the catalog is re-walked — and a header that resolved
    /// its own selection would then draw nothing in the column whose job is the
    /// book.
    func test_thePickedBookFallsBackToTheNewestWhenItsRowIsGone() {
        let newest = Self.publication(version: "1.1", outputPath: "Exports/b2.pdf",
                                      compiledAt: Date())
        let older = Self.publication(version: "1.0", outputPath: "Exports/b1.pdf",
                                     compiledAt: Date().addingTimeInterval(-600))
        let rows = [newest, older]

        XCTAssertEqual(PublishPreviewResolver.shown(nil, in: rows)?.publicationID,
                       newest.publicationID,
                       "no pick is the newest — which is also what a relaunch "
                       + "and a new compile both mean")
        XCTAssertEqual(
            PublishPreviewResolver.shown(older.publicationID, in: rows)?.publicationID,
            older.publicationID,
            "the writer's pick is what they get")
        XCTAssertEqual(
            PublishPreviewResolver.shown("pub-vanished", in: rows)?.publicationID,
            newest.publicationID,
            "a pick whose row has left the list draws the newest rather than "
            + "an empty column")
        XCTAssertNil(PublishPreviewResolver.shown(older.publicationID, in: []),
                     "…and with nothing readable at all there is nothing to draw, "
                     + "which is the notice's case rather than the page's")
    }

    // MARK: - The rule: the new truth table

    /// **The whole table, in one loop** (Denver, 2026-08-12).
    ///
    /// | subject | compiled | uncompiled | unreadable |
    /// |---|---|---|---|
    /// | project / group / none / research | the book | notice: never compiled | notice: naming |
    /// | a document | the EDITOR — nothing over it | the editor | the editor |
    ///
    /// Ruling 1 is the row that changed: a chapter used to show the book.
    func test_theTruthTableTheRulingsLeave() {
        let compiled = PublishPreviewResolution.ready(newestFirst: [Self.aBook])

        for (subject, shape) in ProjectAltitudeCentreTests.notADocument {
            XCTAssertEqual(
                ProjectWindow.publishCentre(
                    persona: .publish, subject: subject,
                    structure: ProjectAltitudeCentreTests.structure,
                    preview: compiled),
                .books([Self.aBook]),
                "\(shape): project level in Publish is the book")
            XCTAssertEqual(
                ProjectWindow.publishCentre(
                    persona: .publish, subject: subject,
                    structure: ProjectAltitudeCentreTests.structure,
                    preview: .nothingCompiled),
                .notice(.neverCompiled),
                "\(shape) with nothing compiled: altitude, and a notice saying "
                + "so — the bare corkboard is what read as 'basically Author'")
            XCTAssertEqual(
                ProjectWindow.publishCentre(
                    persona: .publish, subject: subject,
                    structure: ProjectAltitudeCentreTests.structure,
                    preview: Self.unreadable),
                .notice(.unreadableCatalog(reason: Self.unreadableReason)),
                "\(shape) with an unreadable catalog: altitude, and a DIFFERENT "
                + "notice carrying the sentence that names the file")
        }

        for preview: PublishPreviewResolution in [compiled, .nothingCompiled, Self.unreadable] {
            XCTAssertNil(
                ProjectWindow.publishCentre(
                    persona: .publish, subject: .item("chapter-1"),
                    structure: ProjectAltitudeCentreTests.structure,
                    preview: preview),
                "a chapter in Publish is the EDITOR whatever the catalog says "
                + "(\(preview)) — Denver, 2026-08-12: \"I might tweak something "
                + "for layout\". Nothing is layered over it, not even a notice")
        }
    }

    /// **A research subject is project level too**, which is spec §4's "—" row
    /// read forward: `.nothingMoves` means neither column acts on it, so it
    /// falls through to whatever Publish shows when the tree names no document.
    func test_aResearchSubjectInPublishIsProjectLevel() {
        XCTAssertEqual(
            ProjectWindow.publishCentre(
                persona: .publish, subject: .research("r1"),
                structure: Self.oneDocument,
                preview: .ready(newestFirst: [Self.aBook])),
            .books([Self.aBook]),
            "a research note in Publish resolves to no manuscript document, so "
            + "it is project level and the book is what covers it")
        XCTAssertEqual(
            ProjectWindow.publishCentre(
                persona: .publish, subject: .research("r1"),
                structure: Self.oneDocument, preview: .nothingCompiled),
            .notice(.neverCompiled))
    }

    /// **Publish's alone** — over the whole product of personas and resolutions,
    /// so a fifth persona has to answer it.
    func test_theLayerIsPublishsAloneWhateverTheCatalogSays() {
        for persona in Persona.allCases {
            for preview: PublishPreviewResolution in [
                .ready(newestFirst: [Self.aBook]), .nothingCompiled, Self.unreadable
            ] {
                let covered = ProjectWindow.publishCentre(
                    persona: persona, subject: .project,
                    structure: Self.oneDocument, preview: preview) != nil
                XCTAssertEqual(
                    covered, persona.previewsThePublishedBook,
                    "\(persona) with \(preview): the layer is gated on the ONE "
                    + "spelling of \"this persona's centre is the compiled "
                    + "book\", and that gate decides the notices too")
            }
        }
    }

    /// The predicate itself: exactly one persona, and it is the one whose whole
    /// job is the book.
    func test_onlyPublishPreviewsThePublishedBook() {
        XCTAssertEqual(Persona.allCases.filter(\.previewsThePublishedBook), [.publish])
    }

    /// **The two degrades leave the centre to altitude — with DIFFERENT notices
    /// over it** (Denver's ruling 3, RULING-7's shape given a surface).
    ///
    /// This is the re-cut of `test_bothDegradesLeaveTheCentreToAltitude`, which
    /// asserted only that neither drew a book. That was true and insufficient:
    /// it was equally green while the writer saw the same unexplained corkboard
    /// for both facts.
    func test_bothDegradesLeaveTheCentreToAltitudeUnderTwoDifferentNotices() {
        let never = ProjectWindow.publishCentre(
            persona: .publish, subject: .project, structure: Self.oneDocument,
            preview: .nothingCompiled)
        let unreadable = ProjectWindow.publishCentre(
            persona: .publish, subject: .project, structure: Self.oneDocument,
            preview: Self.unreadable)

        for (resolution, centre) in [(PublishPreviewResolution.nothingCompiled, never),
                                     (Self.unreadable, unreadable)] {
            guard case .notice = centre else {
                XCTFail("\(resolution): a notice is what stands over altitude now")
                return
            }
            XCTAssertTrue(
                ProjectWindow.subjectShowsAltitude(
                    persona: .publish, subject: .project,
                    structure: Self.oneDocument),
                "\(resolution): …and altitude is still what it stands OVER — "
                + "the corkboard is real content, not an empty state")
        }
        XCTAssertNotEqual(never, unreadable,
                          "one notice for both facts is the collapse RULING-7 "
                          + "forbids, and the whole point of the distinction "
                          + "living in the resolution")
        XCTAssertEqual(never, .notice(.neverCompiled))
        XCTAssertEqual(unreadable, .notice(.unreadableCatalog(reason: Self.unreadableReason)))
    }

    /// **The copy differs in every part a writer reads** — headline, detail and
    /// glyph — because "distinct" is what the ruling asks for and equal strings
    /// would satisfy the case-inequality above.
    func test_theTwoNoticesLookAndReadDifferently() {
        let never = PublishCentreNotice.neverCompiled
        let unreadable = PublishCentreNotice.unreadableCatalog(reason: Self.unreadableReason)

        XCTAssertNotEqual(never.headline, unreadable.headline)
        XCTAssertNotEqual(never.detail, unreadable.detail)
        XCTAssertNotEqual(never.symbol, unreadable.symbol)
        XCTAssertTrue(unreadable.detail.contains(Self.unreadableReason),
                      "the naming banner carries the error's OWN sentence, which "
                      + "is what names the file — the resolver kept it precisely "
                      + "so this surface would not have to invent one")
        XCTAssertFalse(never.headline.isEmpty)
        XCTAssertFalse(never.detail.isEmpty)
    }

    /// **`subjectShowsAltitude` is untouched by any of this** — the layer is
    /// composed FROM it rather than a change to it.
    func test_theAltitudeRuleIsUnchangedAndIsWhatTheLayerComposes() {
        for (subject, shape) in ProjectAltitudeCentreTests.notADocument {
            XCTAssertTrue(
                ProjectWindow.subjectShowsAltitude(
                    persona: .publish, subject: subject,
                    structure: ProjectAltitudeCentreTests.structure),
                "Publish with \(shape): still altitude, exactly as before")
        }
        XCTAssertFalse(
            ProjectWindow.subjectShowsAltitude(
                persona: .publish, subject: .item("chapter-1"),
                structure: ProjectAltitudeCentreTests.structure),
            "…and a document is not altitude — which, since the ruling, is also "
            + "why nothing covers it in Publish")
    }

    // MARK: - The status footer

    /// **A document in Publish reports exactly as it does in Author** — the
    /// footer's four readings are about the document in the centre, and since
    /// the ruling that document is on screen.
    func test_theFooterSpeaksOverAChapterInPublishAsItDoesInAuthor() {
        for persona in [Persona.author, .review, .publish] {
            XCTAssertTrue(
                ProjectWindow.showsStatusFooter(
                    persona: persona, subject: .item("doc1"),
                    showsPaletteWall: false, structure: Self.oneDocument),
                "\(persona): the chapter is in the centre column, so the goal "
                + "capsule, the session words, the `¶id` and the element all "
                + "have something to be about")
        }
    }

    /// **And refuses at project level, where the book or a notice stands** — by
    /// the altitude clause, which is the only clause left that can answer it.
    func test_theFooterIsSilentAtProjectLevelInPublish() {
        for (subject, shape) in ProjectAltitudeCentreTests.notADocument {
            XCTAssertFalse(
                ProjectWindow.showsStatusFooter(
                    persona: .publish, subject: subject, showsPaletteWall: false,
                    structure: ProjectAltitudeCentreTests.structure),
                "Publish with \(shape): a word count under a compiled book — or "
                + "under a 'nothing published yet' banner — is a claim about a "
                + "document that is not on screen")
        }
    }

    /// **Why the footer needs no publish clause of its own any more.**
    ///
    /// The clause `showsStatusFooter` carried from stage 3b until this revision
    /// was removed rather than kept, and this is the assertion that removal
    /// rests on: wherever `publishCentre` answers anything at all,
    /// `subjectShowsAltitude` is already true, so the altitude clause has
    /// already refused. Asserted over the whole product — every persona, every
    /// subject shape, every resolution — because a parameter that cannot change
    /// an answer is exactly what the find-overlay question was settled with a
    /// test instead of an argument.
    func test_theBookOnlyEverCoversAltitudeSoTheFooterNeedsNoClauseOfItsOwn() {
        var covered = 0
        let subjects: [BinderSubject?] = [
            nil, .project, .item("chapter-1"), .item("part-one"),
            .item("no-such-id"), .research("r1")
        ]
        for persona in Persona.allCases {
            for subject in subjects {
                for preview: PublishPreviewResolution in [
                    .ready(newestFirst: [Self.aBook]), .nothingCompiled, Self.unreadable
                ] {
                    guard ProjectWindow.publishCentre(
                        persona: persona, subject: subject,
                        structure: ProjectAltitudeCentreTests.structure,
                        preview: preview) != nil else { continue }
                    covered += 1
                    XCTAssertTrue(
                        ProjectWindow.subjectShowsAltitude(
                            persona: persona, subject: subject,
                            structure: ProjectAltitudeCentreTests.structure),
                        "\(persona)/\(String(describing: subject))/\(preview): "
                        + "Publish's layer covered something altitude does NOT "
                        + "cover — the footer lost the clause that used to "
                        + "catch that case")
                    XCTAssertFalse(
                        ProjectWindow.showsStatusFooter(
                            persona: persona, subject: subject,
                            showsPaletteWall: false,
                            structure: ProjectAltitudeCentreTests.structure),
                        "…and the footer must be silent under it")
                }
            }
        }
        XCTAssertGreaterThan(covered, 0,
                             "the loop never reached a covered case, so the "
                             + "implication above is vacuously true and says "
                             + "nothing")
    }

    // MARK: - Where a research subject lands in Publish

    /// **Publish stops acting on a research subject** — spec §4's "—" row. The
    /// placement answers `.nothingMoves`, so the subject falls through to the
    /// manuscript arm: the book if there is one, altitude and a notice if not.
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

    // MARK: - Mounted: the book takes the centre

    /// **The project's own subject in Publish draws the compiled book.**
    func test_theProjectSubjectInPublishShowsTheCompiledBook() async throws {
        let store = try await novel()
        let publication = try await compileOne(into: store)
        let mount = try await host(store: store, persona: .publish,
                                   subject: .project,
                                   preview: .ready(newestFirst: [publication]))

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

    /// **Denver's ruling 1, mounted and in the direction that changed: a chapter
    /// subject in Publish opens the EDITOR, with a compiled book in hand.**
    ///
    /// This is the inverse of the test that shipped in stage 3b
    /// (`…ShowsTheSameBookAndNotTheEditor`), which is the point — the merged
    /// behaviour is the defect now.
    func test_aDocumentSubjectInPublishOpensTheEditorEvenWithABookCompiled() async throws {
        let store = try await novel()
        let publication = try await compileOne(into: store)
        let chapter = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.structure, where: { $0.type == .document }))
        let mount = try await host(store: store, persona: .publish,
                                   subject: .item(chapter.id),
                                   preview: .ready(newestFirst: [publication]))

        await pumpUntil(deadline: 5) { !self.textViews(in: mount.window).isEmpty }

        XCTAssertFalse(textViews(in: mount.window).isEmpty,
                       "a chapter subject in Publish must open the chapter — "
                       + "Denver, 2026-08-12: \"I might tweak something for "
                       + "layout\". Views: \(viewNames(in: mount.window))")
        XCTAssertTrue(pdfViews(in: mount.window).isEmpty,
                      "…and the book must not be drawn over it")
        XCTAssertNil(altitudeTable(in: mount.window),
                     "…nor the corkboard")
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
                                   preview: .ready(newestFirst: [publication]))

        await pumpUntil(deadline: 5) { !self.pdfViews(in: mount.window).isEmpty }

        XCTAssertFalse(pdfViews(in: mount.window).isEmpty,
                       "the research arm above the editor arm took the centre "
                       + "in Publish. Views: \(viewNames(in: mount.window))")
    }

    /// **The picker swaps the rendered PDF**, driven through the binding the
    /// header writes — the delivery path, not the label function.
    func test_pickingAnOlderPublicationSwapsTheRenderedPDF() async throws {
        let store = try await novel()
        let older = try await append(to: PublicationStore(projectURL: store.url),
                                     in: store.url, version: "1.0", minutesAgo: 60)
        let newer = try await append(to: PublicationStore(projectURL: store.url),
                                     in: store.url, version: "1.1", minutesAgo: 5)
        let mount = try await host(store: store, persona: .publish, subject: .project,
                                   preview: .ready(newestFirst: [newer, older]))

        await pumpUntil(deadline: 5) { !self.pdfViews(in: mount.window).isEmpty }
        let pdf = try XCTUnwrap(pdfViews(in: mount.window).first)
        XCTAssertEqual(pdf.document?.documentURL?.lastPathComponent,
                       URL(fileURLWithPath: newer.outputPath).lastPathComponent,
                       "premise: the column opens on the newest book")

        mount.box.selectedPublicationID = older.publicationID
        await pumpUntil(deadline: 5) {
            self.pdfViews(in: mount.window).first?.document?.documentURL?
                .lastPathComponent
                == URL(fileURLWithPath: older.outputPath).lastPathComponent
        }

        XCTAssertEqual(pdfViews(in: mount.window).first?.document?.documentURL?
            .lastPathComponent,
                       URL(fileURLWithPath: older.outputPath).lastPathComponent,
                       "picking the previous version must put that file on "
                       + "screen — the header's whole purpose")
    }

    /// **One publication reads as ONE sentence** — the header this column had
    /// before the picker existed, restored for the case that still has no
    /// control in it: four fragments swept past one arrow key at a time say less
    /// than the sentence they make together.
    func test_aSingleBookHeaderReadsAsOneCombinedSentence() async throws {
        let store = try await novel()
        let publication = try await compileOne(into: store)
        let mount = try await host(store: store, persona: .publish, subject: .project,
                                   preview: .ready(newestFirst: [publication]))
        await pumpUntil(deadline: 5) { !self.pdfViews(in: mount.window).isEmpty }

        // **Read off label AND value.** A combined `AXStaticText` carries its
        // sentence as its VALUE — a predicate over the label alone finds
        // nothing here and would be equally silent over a header that never
        // combined at all.
        let sentence = "\(store.manifest.title), v\(publication.version)"
        let elements = try axElements(in: mount.window,
                                      until: { Self.text(of: $0).contains(sentence) })
        XCTAssertTrue(
            elements.contains { Self.text(of: $0).contains(sentence) },
            "the single-publication header must combine into one element — the "
            + "book's name and which printing it is belong in the same "
            + "sentence. Elements: "
            + "\(elements.map { "\($0.role)|\($0.label)|\($0.value)" })")
    }

    /// **…and the header with a CHOICE in it must not combine**, which is the
    /// reason the view branches at all: `.combine` flattens its children into
    /// one static element, and the child it would flatten here is the picker —
    /// the only way to reach another publication without a mouse.
    func test_theHeaderWithAChoiceKeepsThePickerReachable() async throws {
        let store = try await novel()
        let older = try await append(to: PublicationStore(projectURL: store.url),
                                     in: store.url, version: "1.0", minutesAgo: 60)
        let newer = try await append(to: PublicationStore(projectURL: store.url),
                                     in: store.url, version: "1.1", minutesAgo: 5)
        let mount = try await host(store: store, persona: .publish, subject: .project,
                                   preview: .ready(newestFirst: [newer, older]))
        await pumpUntil(deadline: 5) { !self.pdfViews(in: mount.window).isEmpty }

        let isPicker: ((role: String, label: String, value: String)) -> Bool = {
            Self.text(of: $0).contains("Publication")
                || $0.role == "AXPopUpButton" || $0.role == "AXMenuButton"
        }
        let elements = try axElements(in: mount.window, until: isPicker)
        // The premise FIRST: without it the absence asserted below is equally
        // true of a tree SwiftUI has not built yet, and this test would pass
        // over a header that combined everything away.
        XCTAssertTrue(
            elements.contains(where: isPicker),
            "the picker must be an element of its own, or a VoiceOver user "
            + "cannot reach the other printings at all. Elements: "
            + "\(elements.filter { !$0.label.isEmpty }.map { "\($0.role):\($0.label)" })")
        XCTAssertFalse(
            elements.contains {
                Self.text(of: $0).contains("\(store.manifest.title), v")
            },
            "…and the combined sentence is the SINGLE-publication header's: "
            + "here it would have flattened that picker into a static string. "
            + "Elements: \(elements.map { "\($0.role)|\($0.label)|\($0.value)" })")
    }

    /// **With nothing compiled, a chapter in Publish opens in the editor** —
    /// unchanged by the ruling, and the control that says the test above is
    /// about the compiled case rather than about a persona that stopped working.
    func test_uncompiledPublishStillOpensTheChapterInTheEditor() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.structure, where: { $0.type == .document }))
        let mount = try await host(store: store, persona: .publish,
                                   subject: .item(chapter.id),
                                   preview: .nothingCompiled)

        await pumpUntil(deadline: 5) { !self.textViews(in: mount.window).isEmpty }

        XCTAssertFalse(textViews(in: mount.window).isEmpty,
                       "the chapter must still open")
        XCTAssertTrue(pdfViews(in: mount.window).isEmpty,
                      "…and nothing is drawn over it")
    }

    /// **The project row in uncompiled Publish is the corkboard, and the notice
    /// stands over it without taking the writer's clicks** (Denver's ruling 2).
    ///
    /// The hit test is the load-bearing half: the banner fills the column so it
    /// can sit at its head, and without `allowsHitTesting(false)` that frame
    /// swallows every click meant for the cards and rows underneath — the exact
    /// surface the notice exists to explain.
    func test_uncompiledPublishShowsAltitudeUnderANoticeThatTakesNoClicks() async throws {
        let store = try await novel()
        let mount = try await host(store: store, persona: .publish,
                                   subject: .project, preview: .nothingCompiled)

        await pumpUntil(deadline: 5) { self.altitudeTable(in: mount.window) != nil }

        XCTAssertNotNil(altitudeTable(in: mount.window),
                        "stage 3a's altitude is what an uncompiled Publish "
                        + "still shows")
        XCTAssertTrue(pdfViews(in: mount.window).isEmpty)

        let hit = try middleOfTheColumn(in: mount.window)
        let table = try XCTUnwrap(altitudeTable(in: mount.window))
        XCTAssertTrue(hit === table || hit.isDescendant(of: table)
                      || table.isDescendant(of: hit),
                      "the middle of the column hit-tests to \(type(of: hit)) — "
                      + "the banner is eating the clicks meant for the corkboard "
                      + "it is explaining")

        // Last, because reading the copy needs an accessibility tree and skips
        // without one: every assertion above must have run first.
        let shown = try labels(in: mount.window)
        XCTAssertTrue(
            shown.contains { $0.contains(PublishCentreNotice.neverCompiled.headline) },
            "the standing notice must actually be on screen — a bare corkboard "
            + "in Publish is what read as \"basically Author\". Labels: \(shown)")
    }

    /// **And the unreadable catalog gets its own banner over the same
    /// corkboard** (ruling 3) — different words, and the file's name in them.
    func test_anUnreadableCatalogShowsANamingBannerOverAltitude() async throws {
        let store = try await novel()
        let mount = try await host(store: store, persona: .publish,
                                   subject: .project, preview: Self.unreadable)

        await pumpUntil(deadline: 5) { self.altitudeTable(in: mount.window) != nil }

        XCTAssertNotNil(altitudeTable(in: mount.window),
                        "the altitude fallback stays — Denver kept it and added "
                        + "the banner beside it")
        let shown = try labels(in: mount.window)
        XCTAssertTrue(
            shown.contains { $0.contains(Self.unreadableReason) },
            "the banner carries the error's own sentence, which names the file. "
            + "Labels: \(shown)")
        XCTAssertFalse(
            shown.contains { $0.contains(PublishCentreNotice.neverCompiled.headline) },
            "…and it must NOT be the never-compiled notice: telling a writer "
            + "their book was never made when it is sitting there unreadable is "
            + "RULING-7's forbidden collapse, now with a surface to happen on")
    }

    // MARK: - Mounted: the host survives the new layer

    /// **`EditorHost` is torn down ZERO times across preview ↔ editor ↔
    /// altitude.** The whole reason the preview is a layer: a fourth `editorPane`
    /// arm would unmount the host on every hop, and its `.onDisappear` is
    /// `doc.close()` + `documentStore.unregister(path:)` + `loads.abandon()`.
    ///
    /// The trip is the one a writer makes while checking a proof — and since
    /// ruling 1 it is a trip they make *within Publish* as well: the book at the
    /// project row, the chapter to fix the layout, and back up.
    func test_thePreviewEditorAltitudeRoundTripNeverTearsTheHostDown() async throws {
        let store = try await novel()
        let publication = try await compileOne(into: store)
        let chapter = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.structure, where: { $0.type == .document }))
        let mount = try await host(store: store, persona: .publish,
                                   subject: .project,
                                   preview: .ready(newestFirst: [publication]))

        await pumpUntil(deadline: 5) {
            !self.pdfViews(in: mount.window).isEmpty && mount.hostLife.appearances == 1
        }
        XCTAssertEqual(mount.hostLife.appearances, 1, "premise: the host mounted")
        XCTAssertEqual(mount.hostLife.disappearances, 0, "premise: and is still up")

        // The gesture the ruling creates: fix the layout without leaving Publish.
        //
        // **Wait for the chapter's own surface, not for the book's absence.**
        // The two are separate passes with an async load between them: the
        // subject change removes the preview layer in the render it causes,
        // while the text view arrives only after `EditorHost.onChange(of:
        // selectedItemId)` has awaited `loadDocumentIfNeeded()` and the
        // resulting state change has been rendered. Measured on a 1 ms poll,
        // the book is gone ~80 ms before the surface exists — with the counter
        // reading 1/0 throughout, so an empty column in that window is a
        // half-finished hop and NOT a teardown. Waiting on the departure and
        // asserting the arrival made the gap a coin flip decided by how the
        // worker's runloop happened to be serviced; it came up tails twice in
        // the parallel gate and never once in isolation.
        mount.box.subject = .item(chapter.id)
        await pumpUntil(deadline: 5) {
            self.pdfViews(in: mount.window).isEmpty
                && !self.textViews(in: mount.window).isEmpty
        }
        XCTAssertTrue(pdfViews(in: mount.window).isEmpty,
                      "the book gives way to the prose")
        XCTAssertFalse(textViews(in: mount.window).isEmpty,
                       "the chapter opened in the host that was already there")
        // Pinned at the hop as well as at the end: the counter is what carries
        // the never-torn claim, so if a hop ever DOES cost a teardown it must
        // fail here, naming the hop, rather than surfacing as an empty column
        // that reads like a slow render.
        XCTAssertEqual(mount.hostLife.disappearances, 0,
                       "…the same host, not a fresh one on the chapter")
        XCTAssertEqual(mount.hostLife.appearances, 1,
                       "…and it never re-appeared on the way in")

        mount.box.persona = .author
        await pumpUntil(deadline: 5) { !self.textViews(in: mount.window).isEmpty }

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
    /// through the shape this task rejected — the covering surface as an arm of
    /// its own beside the editor. The counter is the same counter; if it could
    /// not see a teardown, the assertion above would be green over any shape at
    /// all.
    ///
    /// The hop is chapter → project, which is the one every persona makes and
    /// the one ruling 1 puts back inside Publish: with an arm shape it costs
    /// `doc.close()`, `unregister(path:)` and `loads.abandon()` every time.
    func test_control_thePreviewAsItsOwnArmTearsTheHostDown() async throws {
        let store = try await novel()
        let publication = try await compileOne(into: store)
        let chapter = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.structure, where: { $0.type == .document }))
        let mount = try await host(store: store, persona: .publish,
                                   subject: .item(chapter.id),
                                   preview: .ready(newestFirst: [publication]),
                                   shape: .ownArm)

        await pumpUntil(deadline: 5) { mount.hostLife.appearances == 1 }
        XCTAssertEqual(mount.hostLife.appearances, 1,
                       "premise: the arm shape mounts the host on the chapter")

        mount.box.subject = .project
        // Waits on the quantity it asserts, for the reason the layered test
        // records: `.onDisappear` is not guaranteed to have run by the render
        // that puts the book on screen, and a control that can time out early
        // is a control that can stop proving the counter works.
        await pumpUntil(deadline: 5) {
            !self.pdfViews(in: mount.window).isEmpty
                && mount.hostLife.disappearances >= 1
        }

        XCTAssertGreaterThanOrEqual(
            mount.hostLife.disappearances, 1,
            "the arm shape tears the host down on the way from the chapter to "
            + "the book — which is what the layered shape's zero is measured "
            + "against, and why this test exists rather than a comment saying "
            + "an arm would be worse")
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

    /// **A new compile snaps the preview back to the newest** (Denver's ruling
    /// 4), taking whatever the writer had picked with it — because the thing
    /// they just made is what they want to look at.
    func test_aNewCompileTakesTheWritersPickBackToTheNewest() async throws {
        let project = try makeProject()
        let stores = PublishingStores.sharedFor(
            projectID: ProjectIdentifier.id(for: project), projectURL: project)
        let first = try await append(to: stores.publicationStore, in: project,
                                     version: "1.0", minutesAgo: 30)
        _ = try await append(to: stores.publicationStore, in: project,
                             version: "1.1", minutesAgo: 20)

        let box = PublishCentreProbeBox(persona: .publish)
        _ = mountRefreshProbe(projectURL: project, box: box)
        // The window must be RESOLVED before the post, or ADR 0021's liveness
        // guard drops it and this test measures nothing — the sibling event
        // test's premise, and the reason it is asserted rather than assumed.
        await pumpUntil(deadline: 5) {
            box.modifierWindow != nil && box.preview.publications.count == 2
        }
        XCTAssertTrue(MaughamEvent.isLive(box.modifierWindow),
                      "premise: the receiver has a live window")

        box.selectedPublicationID = first.publicationID
        XCTAssertEqual(
            PublishPreviewResolver.shown(box.selectedPublicationID,
                                         in: box.preview.publications)?.publicationID,
            first.publicationID,
            "premise: the writer is looking at the older proof")

        let third = try await append(to: stores.publicationStore, in: project,
                                     version: "1.2", minutesAgo: 0)
        MaughamEvent.post(.maughamPublicationCompleted, to: .project(for: project))

        await pumpUntil(deadline: 5) {
            box.preview.publication?.publicationID == third.publicationID
        }
        XCTAssertNil(box.selectedPublicationID,
                     "a compile that finishes must put the writer on the book "
                     + "they just made — a manual pick that survives it leaves "
                     + "them staring at an old proof wondering what happened")
        XCTAssertEqual(
            PublishPreviewResolver.shown(box.selectedPublicationID,
                                         in: box.preview.publications)?.publicationID,
            third.publicationID)
    }

    /// **…and a refresh that brings no new book leaves the pick alone.** The
    /// reset is keyed on the newest publication changing rather than on the
    /// refresh happening, so walking out of Publish and back does not move the
    /// page under the writer.
    func test_arrivingInPublishAgainKeepsTheWritersPick() async throws {
        let project = try makeProject()
        let stores = PublishingStores.sharedFor(
            projectID: ProjectIdentifier.id(for: project), projectURL: project)
        let older = try await append(to: stores.publicationStore, in: project,
                                     version: "1.0", minutesAgo: 30)
        _ = try await append(to: stores.publicationStore, in: project,
                             version: "1.1", minutesAgo: 20)

        let box = PublishCentreProbeBox(persona: .author)
        _ = mountRefreshProbe(projectURL: project, box: box)
        await pumpUntil(deadline: 5) { box.preview.publications.count == 2 }
        box.selectedPublicationID = older.publicationID

        box.persona = .publish
        pump(1.0)   // the arrival refresh reads the catalog off disk

        XCTAssertEqual(box.selectedPublicationID, older.publicationID,
                       "arriving in Publish re-asks the catalog, and the answer "
                       + "was the same book — nothing happened that the writer "
                       + "should be moved by")
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

    // MARK: - The gate's selection is the other transient pick (P4 Task 5)

    /// **A persona change lets the design gate go**, where it deliberately keeps
    /// the writer's publication pick.
    ///
    /// The two are both window-transient state about Publish's centre and this
    /// modifier owns both, so the difference has to be asserted rather than
    /// argued: a publication pick is a place in a READING, which Denver's ruling
    /// keeps across a walk out of Publish and back; a selected proposal is a
    /// place in a DECISION the writer entered by pressing Show, and leaving
    /// Publish is them leaving it.
    func test_aPersonaChangeLetsTheGateGoAndKeepsTheBooksPick() async throws {
        let project = try makeProject()
        let stores = PublishingStores.sharedFor(
            projectID: ProjectIdentifier.id(for: project), projectURL: project)
        let older = try await append(to: stores.publicationStore, in: project,
                                     version: "1.0", minutesAgo: 30)
        _ = try await append(to: stores.publicationStore, in: project,
                             version: "1.1", minutesAgo: 20)

        let box = PublishCentreProbeBox(persona: .publish)
        _ = mountRefreshProbe(projectURL: project, box: box)
        await pumpUntil(deadline: 5) { box.preview.publications.count == 2 }
        box.selectedPublicationID = older.publicationID
        box.selectedProposal = Self.aProposal

        box.persona = .author
        await pumpUntil(deadline: 5) { box.selectedProposal == nil }

        XCTAssertNil(box.selectedProposal,
                     "walking out of Publish leaves the gate behind")
        XCTAssertEqual(box.selectedPublicationID, older.publicationID,
                       "…and does NOT take the book the writer was reading")
    }

    /// …and arriving BACK in Publish does not resurrect it. The clear is written
    /// before the modifier's arrival guard for exactly this: the guard's own
    /// `return` runs on a change away from Publish, and a clear behind it would
    /// only ever fire on the way in.
    func test_theGateIsGoneOnTheWayBackIntoPublishToo() async throws {
        let project = try makeProject()
        let box = PublishCentreProbeBox(persona: .publish)
        _ = mountRefreshProbe(projectURL: project, box: box)
        box.selectedProposal = Self.aProposal

        box.persona = .author
        await pumpUntil(deadline: 5) { box.selectedProposal == nil }
        box.persona = .publish
        pump(0.5)

        XCTAssertNil(box.selectedProposal)
    }

    /// A staged proposal, for the tests that are about the SELECTION rather than
    /// about what the gate draws (`DesignGateTests` owns the latter).
    static let aProposal = DesignProposalStore.Proposal(
        id: "prop-preview", designerName: "Tschichold", round: 1, language: nil,
        created: Date(timeIntervalSince1970: 1_770_000_000), status: .pending,
        specMarkdown: "# a design", filePaths: ["template.tex"],
        sampleResult: nil, revertNote: nil)

    /// …and the report behind one, for the tests that need a proposal the store
    /// really holds rather than a value.
    static let aReport = DesignerReport(
        specMarkdown: "# a design",
        files: [DesignerReport.ProposedFile(path: "template.tex",
                                            content: "\\documentclass{book}")])

    // MARK: - …and the gate's proposal goes stale where the writer sits

    /// **A round superseded under the writer stops offering verdicts.**
    ///
    /// The gate holds its proposal as a VALUE, and the store keeps ONE pending
    /// slot: a fresh round — the writer's own next Run, or one an MCP caller
    /// asked for — marks whatever preceded it `superseded` on disk. Nothing
    /// re-derived the selection, so the writer went on looking at Approve and
    /// Request Changes over a proposal the store had already retired, and
    /// pressing either acted on a dead round.
    ///
    /// `DesignGate.verbs`/`settledNote` are already pure functions of the
    /// status, so the whole of the fix is that the status ARRIVES.
    func test_aSupersededRoundStopsOfferingVerdictsWhereTheWriterSits() async throws {
        let project = try makeProject()
        let store = DesignProposalStore(projectURL: project)
        let first = try store.stage(report: Self.aReport, round: 1,
                                    designerName: "Tschichold", language: nil)

        let box = PublishCentreProbeBox(persona: .publish)
        _ = mountRefreshProbe(projectURL: project, box: box)
        await pumpUntil(deadline: 5) { box.modifierWindow != nil }
        XCTAssertTrue(MaughamEvent.isLive(box.modifierWindow),
                      "premise: the receiver has a live window — ADR 0021's "
                      + "project scope drops the post otherwise, and this test "
                      + "would measure nothing")
        box.selectedProposal = first
        XCTAssertEqual(box.selectedProposal?.status, .pending,
                       "premise: the writer opened a round still to decide")

        _ = try store.stage(report: Self.aReport, round: 2,
                            designerName: "Tschichold", language: nil)
        MaughamEvent.postDesignProposalsChanged(projectURL: project)
        await pumpUntil(deadline: 5) { box.selectedProposal?.status == .superseded }

        XCTAssertEqual(box.selectedProposal?.id, first.id,
                       "which round the writer is looking at is their own "
                       + "choice — the re-read must not move them to the new one")
        XCTAssertEqual(box.selectedProposal?.status, .superseded,
                       "the gate is still offering Approve over a round the "
                       + "store retired")
        XCTAssertEqual(DesignGate.verbs(status: .superseded,
                                        hasOpenProposalRound: true), [],
                       "…which is what makes the status enough: the footer's "
                       + "verbs are a pure function of it")
    }

    /// **A proposal that is gone clears the selection rather than leaving a
    /// ghost.** Everything under `.maugham/design/` is derived and the store's
    /// own doc says deleting it is safe, so this is a state a writer reaches on
    /// purpose. Four verbs over a record that no longer exists is the worse
    /// answer: every one of them refuses, one press at a time.
    func test_aDeletedProposalClearsTheSelectionRatherThanDrawingAGhost() async throws {
        let project = try makeProject()
        let store = DesignProposalStore(projectURL: project)
        let staged = try store.stage(report: Self.aReport, round: 1,
                                     designerName: "Tschichold", language: nil)

        let box = PublishCentreProbeBox(persona: .publish)
        _ = mountRefreshProbe(projectURL: project, box: box)
        await pumpUntil(deadline: 5) { box.modifierWindow != nil }
        XCTAssertTrue(MaughamEvent.isLive(box.modifierWindow),
                      "premise: the receiver has a live window")
        box.selectedProposal = staged

        try FileManager.default.removeItem(at: store.proposalDir(id: staged.id))
        MaughamEvent.postDesignProposalsChanged(projectURL: project)
        await pumpUntil(deadline: 5) { box.selectedProposal == nil }

        XCTAssertNil(box.selectedProposal,
                     "the gate is describing a proposal that is not on disk")
    }

    /// **The control: an announcement with no gate open disturbs nothing.**
    /// Without it the two tests above could pass over a modifier that cleared
    /// the selection — or the book's own pick — on every post.
    func test_anAnnouncementWithNoGateOpenDisturbsNothing() async throws {
        let project = try makeProject()
        let stores = PublishingStores.sharedFor(
            projectID: ProjectIdentifier.id(for: project), projectURL: project)
        let published = try await append(to: stores.publicationStore, in: project,
                                         version: "1.0", minutesAgo: 0)

        let box = PublishCentreProbeBox(persona: .publish)
        _ = mountRefreshProbe(projectURL: project, box: box)
        await pumpUntil(deadline: 5) {
            box.preview.publication?.publicationID == published.publicationID
        }
        box.selectedPublicationID = published.publicationID

        MaughamEvent.postDesignProposalsChanged(projectURL: project)
        await waitOut(0.3)

        XCTAssertNil(box.selectedProposal)
        XCTAssertEqual(box.selectedPublicationID, published.publicationID,
                       "a design announcement is not news about the book")
        XCTAssertEqual(box.preview.publication?.publicationID,
                       published.publicationID)
    }

    /// **A verb's answer about another round is dropped.**
    ///
    /// A verb answers from a `Task` that outlives the press — a promotion is
    /// file I/O over the writer's whole template set — and they are free to
    /// press Back, or Show a different round on the desk, while it runs. Writing
    /// the answer in unconditionally would reopen a gate the writer closed, or
    /// replace the round they had just opened, a frame after they acted.
    func test_aVerbsAnswerAboutAnotherRoundIsDropped() {
        var promoted = Self.aProposal
        promoted.status = .approved

        XCTAssertEqual(
            ProjectWindow.publishSelection(after: promoted,
                                           showing: Self.aProposal)?.status,
            .approved,
            "the round on screen takes its own verb's answer, or the gate goes "
            + "on offering Approve over a design already live")

        let another = DesignProposalStore.Proposal(
            id: "prop-somewhere-else", designerName: "Tschichold", round: 2,
            language: nil, created: Date(timeIntervalSince1970: 1_770_000_100),
            status: .pending, specMarkdown: "# another design",
            filePaths: ["template.tex"], sampleResult: nil, revertNote: nil)
        XCTAssertEqual(
            ProjectWindow.publishSelection(after: promoted, showing: another)?.id,
            another.id,
            "the writer moved on; a verb about the round they left must not "
            + "pull it back into the centre column")
        XCTAssertNil(
            ProjectWindow.publishSelection(after: promoted, showing: nil),
            "…and one about a gate they CLOSED must not reopen it")
    }

    /// The bridge: the window's write-back goes through that rule rather than
    /// straight into its own state. Without this the pure test above pins a rule
    /// nothing obeys.
    func test_theWindowsWriteBackGoesThroughTheSelectionRule() throws {
        let code = SourceScan.codeLines(
            of: try Self.source(of: "Views/ProjectWindow.swift"))
        XCTAssertTrue(
            code.contains { $0.contains("publishSelection(") },
            "`onProposalChanged` must adopt through `publishSelection`, or a "
            + "verb answering after the writer moved on writes the old proposal "
            + "back into the centre column")
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
        XCTAssertTrue(arm.contains("ReviewBoardPane("),
                      "…Review's passes board over that (M3 P1 Task 6)")
        XCTAssertTrue(arm.contains("Self.reviewCentreShowsBoard("),
                      "…gated on its own named rule, for this layer's reason")
        XCTAssertTrue(arm.contains("PublishPreviewCentre("),
                      "…and the book over all of them")
        XCTAssertTrue(arm.contains("PublishCentreNoticeBanner("),
                      "…with the notice standing in the same place when there "
                      + "is no book")
        XCTAssertTrue(arm.contains("Self.publishCentre("),
                      "both are gated on the ONE named rule rather than on a "
                      + "second spelling written out here — and a second gate "
                      + "is how a 'nothing published yet' banner ends up over a "
                      + "compiled book")

        let altitudeAt = try XCTUnwrap(arm.range(of: "ProjectAltitudePane("))
        let boardAt = try XCTUnwrap(arm.range(of: "ReviewBoardPane("))
        let bookAt = try XCTUnwrap(arm.range(of: "PublishPreviewCentre("))
        XCTAssertTrue(altitudeAt.lowerBound < bookAt.lowerBound,
                      "the book must be the LAST layer of the stack — a "
                      + "corkboard drawn over a compiled book is the truth "
                      + "table read upside down")
        XCTAssertTrue(boardAt.lowerBound < bookAt.lowerBound,
                      "…LAST means after Review's board too. The two are never "
                      + "both offered today (each predicate is true of one "
                      + "persona), so nothing behavioural would catch a layer "
                      + "that slipped in front of the book — this ordering is "
                      + "the only thing holding the book's place")

        XCTAssertEqual(
            Self.occurrences(of: "PublishPreviewCentre(", in: source), 1,
            "one mount for the book, in the centre column's overlay. A second "
            + "is a surface nobody decided to add")
        XCTAssertEqual(
            Self.occurrences(of: "PublishCentreNoticeBanner(", in: source), 1,
            "and one for the notice, for the same reason")
        XCTAssertEqual(
            Self.occurrences(of: "manuscriptEditor(", in: source), 2,
            "the declaration and exactly ONE call — unchanged by this task")
    }

    /// **The centre's rule asks the subject question that already exists.**
    ///
    /// Ruling 1 made the layer subject-dependent, and the risk that arrives with
    /// it is a second document-resolution rule beside `subjectShowsAltitude` —
    /// two answers free to disagree about what a document is, with a PDF over
    /// the chapter a writer is fixing as the visible cost. The rule composes it
    /// instead, and this is the census that says so.
    func test_theRuleComposesTheWindowsOwnDocumentQuestion() throws {
        let source = try Self.source(of: "Views/ProjectWindow.swift")
        let rule = try XCTUnwrap(
            Self.declaration(named: "static func publishCentre(", in: source))

        XCTAssertTrue(rule.contains("subjectShowsAltitude("),
                      "the project-level question is asked of the function that "
                      + "already answers it")
        XCTAssertFalse(rule.contains("selectionIsDocument("),
                       "…and not re-derived from the primitive underneath it, "
                       + "which is how the two would come to disagree")
        XCTAssertFalse(rule.contains("TreeWalk."),
                       "…nor by walking the structure a third time")

        // The behavioural half of the same claim, so this census is a bridge to
        // a property rather than the property itself.
        for (subject, shape) in ProjectAltitudeCentreTests.notADocument {
            XCTAssertEqual(
                ProjectWindow.publishCentre(
                    persona: .publish, subject: subject,
                    structure: ProjectAltitudeCentreTests.structure,
                    preview: .ready(newestFirst: [Self.aBook])) != nil,
                ProjectWindow.subjectShowsAltitude(
                    persona: .publish, subject: subject,
                    structure: ProjectAltitudeCentreTests.structure),
                "\(shape): the two must answer together in Publish")
        }
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

        let window = TestWindow.mount(AnyView(root),
                                      size: CGSize(width: 900, height: 700),
                                      as: SilentTestWindow.self)
        windows.append(window)
        pump(0.1)
        return Mount(window: window, box: box, hostLife: life)
    }

    /// The refresh modifier alone, in a live window — the event path needs a
    /// visible `NSWindow` or ADR 0021's liveness guard drops the post.
    private func mountRefreshProbe(projectURL: URL,
                                   box: PublishCentreProbeBox) -> NSWindow {
        let window = TestWindow.mount(AnyView(
            PublishRefreshProbeView(projectURL: projectURL, box: box)),
            size: CGSize(width: 400, height: 300),
            as: SilentTestWindow.self)
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

    /// **Every accessibility label and value in the mounted tree** — how a
    /// SwiftUI `Text` is read from AppKit, and the only way to assert a piece of
    /// COPY is on SCREEN rather than merely constructible.
    ///
    /// The walk is over the accessibility tree rather than the view tree,
    /// because SwiftUI publishes elements that are not views — `TreeFindOverlay
    /// Tests`' idiom verbatim, KVC and all, including its skip: SwiftUI builds
    /// no accessibility tree at all unless an assistive client is attached to
    /// the process.
    private func labels(in window: NSWindow) throws -> [String] {
        try axElements(in: window).flatMap { [$0.label, $0.value] }
            .filter { !$0.isEmpty }
    }

    /// The same walk, keeping each element whole — role beside label — because
    /// "the picker is still an element of its own" is a claim about an element
    /// and not about a string.
    ///
    /// `until:` is the retry the established idiom carries (`TreeFindOverlay
    /// Tests.closeButton`): SwiftUI builds its accessibility tree lazily, so the
    /// first read of a freshly mounted subtree is routinely a row of empty
    /// labels. The last read is returned either way, so a failure prints what
    /// was actually there.
    private func axElements(
        in window: NSWindow,
        until satisfied: ((role: String, label: String, value: String)) -> Bool = { _ in true }
    ) throws -> [(role: String, label: String, value: String)] {
        var elements = try axElements(in: window)
        for _ in 0..<20 where !elements.contains(where: satisfied) {
            pump(0.1)
            elements = try axElements(in: window)
        }
        return elements
    }

    private func axElements(in window: NSWindow) throws
    -> [(role: String, label: String, value: String)] {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process, so "
                + "SwiftUI builds no accessibility tree to read the header from")
        }
        guard let root = window.contentView else { return [] }
        return axElements(under: root).map { element in
            (role: axAttribute(element, "accessibilityRole") as? String ?? "",
             label: axAttribute(element, "accessibilityLabel") as? String ?? "",
             value: axAttribute(element, "accessibilityValue") as? String ?? "")
        }
    }

    /// What an element SAYS — its label if it has one, else its value. A
    /// combined `Text` row is an `AXStaticText` whose sentence is the value, and
    /// a control's is its label, so any assertion about copy on screen has to
    /// read both or it is asserting about the wrong field.
    private static func text(
        of element: (role: String, label: String, value: String)
    ) -> String {
        element.label.isEmpty ? element.value : element.label
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

    /// The sentence a real `PublicationStore.ReadError` carries — shortened, but
    /// the same shape: it NAMES the file, which is what the banner shows.
    static let unreadableReason =
        "The publications catalog “publications.otherdevice.jsonl” exists but can't be read."
    static let unreadable = PublishPreviewResolution
        .unreadableCatalog(reason: unreadableReason)

    /// A book to put in a resolution when the test is about the rule rather than
    /// about disk.
    static let aBook = publication(version: "1.0", outputPath: "Exports/b.pdf",
                                   compiledAt: Date(timeIntervalSince1970: 1_770_000_000))

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
/// move the persona, the subject, the resolved publications and the header's
/// pick the way the window does.
@Observable
@MainActor
final class PublishCentreProbeBox {
    var subject: BinderSubject?
    var persona: Persona
    var preview: PublishPreviewResolution = .nothingCompiled
    /// The header picker's window-transient choice — `nil` is "the newest".
    var selectedPublicationID: String?
    /// The design proposal the desk's Show put in the centre (P4 Task 5) —
    /// window-transient like the pick above, but cleared by a persona change
    /// where the pick deliberately is not.
    var selectedProposal: DesignProposalStore.Proposal?
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

    private var selection: Binding<String?> {
        Binding(get: { box.selectedPublicationID },
                set: { box.selectedPublicationID = $0 })
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
                                  itemID: id, previewVisible: false,
                                  readOnly: !box.persona.editsResearchInTheCentre)
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
                publishLayer
            }
        case .ownArm:
            if case .books(let publications) = publishCentre {
                book(publications)
            } else if showsAltitude {
                altitude
            } else {
                editor
            }
        }
    }

    @ViewBuilder
    private var publishLayer: some View {
        switch publishCentre {
        // The gate arm (publish-department P4 Task 5) — production's fourth
        // layer, so this probe stays what it claims to be: `manuscriptEditor`'s
        // own shape with the same decisions taken from the same statics.
        case .designProposal(let proposal):
            DesignGateView(proposal: proposal, projectURL: store.url,
                           onClose: { box.selectedProposal = nil })
        case .books(let publications): book(publications)
        case .notice(let notice): PublishCentreNoticeBanner(notice: notice)
        case .none: EmptyView()
        }
    }

    private func book(_ publications: [Publication]) -> some View {
        PublishPreviewCentre(publications: publications, projectURL: store.url,
                             title: store.manifest.title,
                             selectedPublicationID: selection)
    }

    private var showsAltitude: Bool {
        ProjectWindow.subjectShowsAltitude(persona: box.persona,
                                           subject: box.subject,
                                           structure: store.manifest.structure)
    }

    private var publishCentre: PublishCentre? {
        ProjectWindow.publishCentre(persona: box.persona, subject: box.subject,
                                    structure: store.manifest.structure,
                                    preview: box.preview,
                                    proposal: box.selectedProposal)
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
                                        set: { box.preview = $0 }),
                selectedPublicationID: Binding(
                    get: { box.selectedPublicationID },
                    set: { box.selectedPublicationID = $0 }),
                selectedProposal: Binding(
                    get: { box.selectedProposal },
                    set: { box.selectedProposal = $0 })))
            .onChange(of: window) { _, next in box.modifierWindow = next }
    }
}
