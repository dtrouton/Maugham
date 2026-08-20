import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import MaughamCore
@testable import Maugham

/// **What Publish's desk draws** (publish-department P4 Task 1) — the seat it
/// takes in the right column is `PersonaPaneRegistryTests`'; this file is about
/// the pane itself: its two sections, and the empty state it shows instead of
/// them.
///
/// **Nothing here needs a project on disk**, which is the point rather than a
/// convenience. `DepartmentPane` takes a title, a language list and a count —
/// no `ProjectStore`, no `DocumentStore` — so the whole surface is drivable
/// from literals, exactly as `ReviewBoardPane` is one persona over. That is
/// tripwire 4 satisfied by construction, and `test_theSourceReadsNoStoreAtAll`
/// is the census that keeps it so: the derivations the values come from (a walk
/// of every document's translation store, a read of the staged proposals) are
/// the mount's, and a `body` that could reach either would run it once per row.
///
/// **How the desk is observed while it has no controls.** Task 1 wires no
/// verbs, so there are no buttons to count the way the sibling suite counts
/// chips. The structural reading available instead is the sections' own
/// scroller: the desk puts them in a `ScrollView`, and the empty arm is a
/// `ContentUnavailableView`, which is not a scroller. Tasks 3 and 4 give the
/// rows buttons, at which point counting THOSE is the sharper reading and this
/// helper should be re-derived rather than leant on further.
@MainActor
final class DepartmentPaneTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // The parallel-worker fontd cold-start window (CLAUDE.md): this suite
        // mounts real text through production typography.
        FontWarmup.ensure()
    }

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
    }

    // MARK: - The empty state's truth table (no window)

    /// **Both halves must be missing before the desk says it is empty.** A book
    /// with editions and no design round is a working department, and so is one
    /// with a design round and a single language — telling either that there is
    /// nothing on the desk would be the surface contradicting what it holds.
    func test_theDeskIsOnlyEmptyWithNoLanguagesAndNoProposals() {
        XCTAssertNotNil(DepartmentDesk.emptiness(languageCount: 0, proposalCount: 0),
                        "neither half: the empty state is the honest answer")
        XCTAssertNil(DepartmentDesk.emptiness(languageCount: 1, proposalCount: 0),
                     "an edition is work for the department, design round or not")
        XCTAssertNil(DepartmentDesk.emptiness(languageCount: 0, proposalCount: 1),
                     "a staged design round is work for the department, "
                     + "editions or not")
        XCTAssertNil(DepartmentDesk.emptiness(languageCount: 3, proposalCount: 2))
    }

    /// The empty state says what is not here and what would fill it — never a
    /// bare heading, which reads as a pane that failed to load.
    func test_theEmptyStateNamesBothHalvesOfTheDepartment() throws {
        let emptiness = try XCTUnwrap(
            DepartmentDesk.emptiness(languageCount: 0, proposalCount: 0))

        XCTAssertFalse(emptiness.title.isEmpty)
        let description = emptiness.description.lowercased()
        XCTAssertTrue(description.contains("design"),
                      "the empty state must name the design half: \(emptiness.description)")
        XCTAssertTrue(description.contains("language"),
                      "…and the language half: \(emptiness.description)")
    }

    /// The Design section's line counts what is staged, and says nothing in a
    /// plural where there is one thing.
    func test_theDesignSummaryCountsWhatIsStaged() {
        XCTAssertEqual(DepartmentDesk.designSummary(proposalCount: 0),
                       "No design round yet.")
        XCTAssertEqual(DepartmentDesk.designSummary(proposalCount: 1),
                       "1 design round proposed.")
        XCTAssertEqual(DepartmentDesk.designSummary(proposalCount: 4),
                       "4 design rounds proposed.")
    }

    // MARK: - A row's own words (Task 2, no window)

    /// **A language with no name to print says so rather than printing nothing.**
    /// `translatorName` answers nil for an unlisted, unminted language — the
    /// honest answer for the MCP field, which omits it — and a desk row with a
    /// blank where a person's name goes reads as a bug rather than as a person
    /// the writer has not named yet.
    func test_aRowWithNoTranslatorSaysSoRatherThanPrintingABlank() {
        XCTAssertEqual(DepartmentDesk.translatorLine("Cortázar"), "Cortázar")
        XCTAssertEqual(DepartmentDesk.translatorLine(nil),
                       DepartmentDesk.noTranslatorYet)
        XCTAssertFalse(DepartmentDesk.noTranslatorYet.isEmpty)
    }

    /// The coverage line is the three figures `translation_status` reports, in
    /// its own vocabulary — and a language nobody has translated a paragraph of
    /// says *that* rather than "0 fresh · 0 stale · 0 missing", which is what a
    /// query-first language's zeroes would otherwise read as.
    func test_theCoverageLineCarriesTheThreeFigures() {
        XCTAssertEqual(DepartmentDesk.coverageLine(fresh: 12, stale: 3, missing: 1),
                       "12 fresh · 3 stale · 1 missing")
        XCTAssertEqual(DepartmentDesk.coverageLine(fresh: 0, stale: 0, missing: 0),
                       DepartmentDesk.notStarted)
        XCTAssertEqual(DepartmentDesk.coverageLine(fresh: 0, stale: 0, missing: 4),
                       "0 fresh · 0 stale · 4 missing")
    }

    /// Open queries are what the writer OWES somebody, so the row says it only
    /// when there is a debt — and counts in a singular where there is one.
    func test_theQueryLineAppearsOnlyWhereThereIsSomethingToAnswer() {
        XCTAssertNil(DepartmentDesk.queryLine(openQueries: 0),
                     "nothing owed, nothing said")
        XCTAssertEqual(DepartmentDesk.queryLine(openQueries: 1), "1 open query")
        XCTAssertEqual(DepartmentDesk.queryLine(openQueries: 5), "5 open queries")
    }

    // MARK: - The rows are translation_status's own numbers (Task 2)

    /// **The desk and the tool cannot disagree, because there is one
    /// derivation.** The pane's rows are `EditionStatus`, and so are
    /// `translation_status`'s — the union of file languages and open-query
    /// languages, the same freshness derivation, the same open-query filter
    /// (`.query` AND language-tagged `.craftNote`, the P2 widening). This drives
    /// both over one fixture and asserts the desk's per-language totals are the
    /// tool's rows summed.
    ///
    /// The disable experiment: give the pane a union of its own — file languages
    /// alone, say — and the `fr` row (query-first, no file) disappears here while
    /// the tool goes on reporting it.
    func test_theDesksRowsAreTranslationStatusOwnNumbers() async throws {
        let h = try await makeProject()
        let ids1 = h.doc1.sequence
        // es across both documents, one paragraph of doc-1 left untranslated.
        try await seed(h, doc: h.doc1, paragraphId: ids1[0], language: "es", text: "uno")
        try await seed(h, doc: h.doc2, paragraphId: h.doc2.sequence[0],
                       language: "es", text: "dos")
        // fr exists ONLY as an open question — the query-first workflow.
        try await addQuery(h, doc: h.doc1, paragraphId: ids1[0],
                           body: "tu or vous?", language: "fr")
        // …and es has one anchored query plus one whole-document craft note.
        try await addQuery(h, doc: h.doc1, paragraphId: ids1[1],
                           body: "idiom or literal?", language: "es")
        _ = try await h.doc1.addAnnotation(
            kind: .craftNote, paragraphId: nil,
            body: "Translation query (es) — tú or usted throughout?",
            toolArgs: #"{"language":"es","role_id":"role-es"}"#)

        let desk = try await EditionStatus.languageRows(
            in: h.projectStore, projectURL: h.projectURL)
        let tool = try await self.toolRows(h)

        XCTAssertEqual(desk.map(\.language), ["es", "fr"],
                       "one row per language the book has an edition in, sorted")
        for row in desk {
            let mine = tool.filter { $0.language == row.language }
            XCTAssertFalse(mine.isEmpty)
            XCTAssertEqual(row.fresh, mine.reduce(0) { $0 + $1.fresh },
                           "\(row.language) fresh")
            XCTAssertEqual(row.stale, mine.reduce(0) { $0 + $1.stale },
                           "\(row.language) stale")
            XCTAssertEqual(row.missing, mine.reduce(0) { $0 + $1.missing },
                           "\(row.language) missing")
            XCTAssertEqual(row.openQueries, mine.reduce(0) { $0 + $1.open_queries },
                           "\(row.language) open queries")
            XCTAssertEqual(row.translator, mine.first?.translator,
                           "\(row.language) translator")
        }
        // Spelled out, so a derivation that agreed with a BROKEN tool would
        // still fail here.
        let es = try XCTUnwrap(desk.first { $0.language == "es" })
        XCTAssertEqual(es.fresh, 2, "one paragraph in each document")
        XCTAssertEqual(es.missing, 1, "doc-1's second paragraph")
        XCTAssertEqual(es.openQueries, 2, "the anchored one and the whole-document one")
        let fr = try XCTUnwrap(desk.first { $0.language == "fr" })
        XCTAssertEqual(fr.openQueries, 1)
        XCTAssertEqual(fr.fresh + fr.stale + fr.missing, 0,
                       "no file yet — coverage is absent, not 'all missing'")

        await h.documentStore.close()
    }

    /// **Looking at the desk must not mint a translator** (the read rule in
    /// `ProjectStore+ProductionRoles.swift`, which names "a desk row"
    /// explicitly). The preset name is printed; the manifest is not touched, on
    /// disk or in memory.
    ///
    /// Disable experiment: route the name through
    /// `ProjectStore.translatorRole(for:)` — find-or-create — and the byte
    /// comparison fails.
    func test_anUnmintedLanguageShowsThePresetAndLeavesTheManifestAlone() async throws {
        let h = try await makeProject()
        try await seed(h, doc: h.doc1, paragraphId: h.doc1.sequence[0],
                       language: "es", text: "uno")

        let manifestURL = h.projectURL.appendingPathComponent("project.maugham.json")
        let before = try Data(contentsOf: manifestURL)

        let rows = try await EditionStatus.languageRows(
            in: h.projectStore, projectURL: h.projectURL)

        XCTAssertEqual(rows.first { $0.language == "es" }?.translator, "Cortázar")
        XCTAssertEqual(try Data(contentsOf: manifestURL), before,
                       "a desk row must not mint a production role")
        XCTAssertTrue(h.projectStore.manifest.productionRoles.isEmpty,
                      "…and the in-memory manifest is untouched too")

        await h.documentStore.close()
    }

    /// A stored rename wins over the preset — `effectiveName`, resolved in the
    /// one place that resolves it.
    func test_aStoredRenameIsWhatTheRowPrints() async throws {
        let h = try await makeProject()
        try await seed(h, doc: h.doc1, paragraphId: h.doc1.sequence[0],
                       language: "es", text: "uno")
        let minted = try await h.projectStore.translatorRole(for: "es")
        try await h.projectStore.renameProductionRole(id: minted.id, to: "Alejandra")

        let rows = try await EditionStatus.languageRows(
            in: h.projectStore, projectURL: h.projectURL)
        XCTAssertEqual(rows.first { $0.language == "es" }?.translator, "Alejandra")

        await h.documentStore.close()
    }

    /// An unlisted, unminted language has nobody to name, and the row says so
    /// in words rather than leaving the line blank.
    func test_anUnlistedLanguageHasNobodyToName() async throws {
        let h = try await makeProject()
        try await seed(h, doc: h.doc1, paragraphId: h.doc1.sequence[0],
                       language: "xx", text: "uno")

        let rows = try await EditionStatus.languageRows(
            in: h.projectStore, projectURL: h.projectURL)
        let xx = try XCTUnwrap(rows.first { $0.language == "xx" })
        XCTAssertNil(xx.translator, "no preset, nothing stored — nothing honest")
        XCTAssertEqual(DepartmentDesk.translatorLine(xx.translator),
                       DepartmentDesk.noTranslatorYet)

        await h.documentStore.close()
    }

    // MARK: - The brief's door (Task 2)

    /// **The door mints the file the writer is about to write in, and mints it
    /// once.** `createStatement` is find-or-create, so a second click finds what
    /// the first made — same id, one manifest row, one file. A door that minted
    /// per click would leave `edition-brief-es-2.md` beside the writer's own
    /// (`vacantStatementPath` steers around an occupied path), and the second
    /// visit would open the empty one.
    func test_theBriefsDoorCreatesOnceAndFindsItThereafter() async throws {
        let h = try await makeProject()

        let opened = await DepartmentPaneHost.openBrief(language: "es", in: h.projectStore)
        let reopened = await DepartmentPaneHost.openBrief(language: "es", in: h.projectStore)
        let first = try XCTUnwrap(opened)
        let second = try XCTUnwrap(reopened)

        XCTAssertEqual(first.language, "es")
        XCTAssertEqual(second.statementID, first.statementID,
                       "the second click found what the first made")
        let briefs = h.projectStore.manifest.statements.filter {
            $0.kind == .editionBrief("es") && $0.scope == .project
        }
        XCTAssertEqual(briefs.count, 1, "one brief per edition, ever")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: h.projectURL.appendingPathComponent(briefs[0].path).path),
            "the door leaves a file to write in")

        await h.documentStore.close()
    }

    /// Two languages are two briefs — the statement is keyed by its language,
    /// so the door must not hand `fr` the `es` brief.
    func test_eachEditionGetsItsOwnBrief() async throws {
        let h = try await makeProject()

        let openedES = await DepartmentPaneHost.openBrief(language: "es", in: h.projectStore)
        let openedFR = await DepartmentPaneHost.openBrief(language: "fr", in: h.projectStore)
        let es = try XCTUnwrap(openedES)
        let fr = try XCTUnwrap(openedFR)

        XCTAssertNotEqual(es.statementID, fr.statementID)
        XCTAssertEqual(h.projectStore.manifest.statements.count, 2)

        await h.documentStore.close()
    }

    // MARK: - Mounted: which arm the pane is on

    /// The empty project shows the unavailable view and no desk at all.
    ///
    /// (That the arm chains tripwire 15's full frame is enforced for every pane
    /// under `Maugham/` by
    /// `TripwireGrepTests.test_contentUnavailableViewAlwaysChainsFullFrame`;
    /// what is asserted here is that the arm is REACHED.)
    func test_aProjectWithNeitherShowsNoDesk() async throws {
        let window = mount(languages: [], proposals: 0)
        pump(0.3)

        XCTAssertTrue(scrollViews(in: window).isEmpty,
                      "the pane is showing the unavailable view, which is not a "
                      + "scroller — a desk here would mean two empty headings")
    }

    /// The control for the test above, and the mounted half of the truth table:
    /// one language is enough to put the sections on screen.
    func test_oneLanguageGivesTheDeskItsSections() async throws {
        let window = mount(languages: ["es"], proposals: 0)
        let scrollers = try await scrollersSettling(in: window)

        XCTAssertEqual(scrollers.count, 1,
                       "the sections scroll in one scroller of the pane's own — "
                       + "a right-column pane may not grow the split view "
                       + "(DetailPaneColumnHeightCensusTests)")
    }

    /// And a design round with no editions at all does too, which is the arm a
    /// reading of "the desk is for translations" would get wrong.
    func test_aStagedDesignRoundAloneGivesTheDeskItsSections() async throws {
        let window = mount(languages: [], proposals: 1)
        let scrollers = try await scrollersSettling(in: window)

        XCTAssertEqual(scrollers.count, 1)
    }

    /// **A language row is named the way the rest of the app names one** —
    /// `TranslationReviewIndicator.displayLabel`, so the tag the writer reads in
    /// the translation indicator and the one they read on the desk are the same
    /// string. Read off the accessibility tree, and skipped by name where no
    /// assistive client can attach: a tree that was never built is not evidence
    /// about this view.
    func test_aLanguageRowIsNamedAsTheRestOfTheAppNamesIt() async throws {
        let window = mount(languages: ["es"], proposals: 0)
        _ = try await scrollersSettling(in: window)

        let texts = try axTexts(in: window)
        XCTAssertFalse(texts.isEmpty,
                       "the hosted desk published no text at all, so this test "
                       + "could not fail for the reason it exists")
        let expected = TranslationReviewIndicator.displayLabel(forLanguageTag: "es")
        XCTAssertTrue(texts.contains { $0.contains(expected) },
                      "no row reads \u{201C}\(expected)\u{201D}. Published: \(texts.sorted())")
    }

    /// **The row carries the four facts the spec asks a language row for** —
    /// who translates it, how much of it is fresh/stale/missing, what is still
    /// unanswered — and the door to its brief. Read off the mounted tree so the
    /// assertion is about what a writer can see, not about a string constant.
    func test_aLanguageRowCarriesItsTranslatorItsCoverageAndItsQueries() async throws {
        let row = EditionStatus.LanguageRow(
            language: "es", translator: "Cortázar",
            fresh: 12, stale: 3, missing: 1, openQueries: 2)
        let window = mount(rows: [row], proposals: 0)
        _ = try await scrollersSettling(in: window)

        let texts = try axTexts(in: window)
        for expected in ["Cortázar",
                         DepartmentDesk.coverageLine(fresh: 12, stale: 3, missing: 1),
                         DepartmentDesk.queryLine(openQueries: 2) ?? "",
                         DepartmentDesk.editionBriefTitle] {
            XCTAssertTrue(texts.contains { $0.contains(expected) },
                          "nothing on the row reads \u{201C}\(expected)\u{201D}. "
                          + "Published: \(texts.sorted())")
        }
    }

    /// The door is a control, not a caption — a writer reaches it with the
    /// keyboard and VoiceOver announces it, which a `Text` would not. Read off
    /// the accessibility tree, as the sibling board reads its chips.
    func test_theEditionBriefDoorIsAButtonOnEveryRow() async throws {
        let window = mount(languages: ["es", "fr"], proposals: 0)
        _ = try await scrollersSettling(in: window)

        let labels = try axButtonLabels(in: window)
        XCTAssertEqual(labels.filter { $0 == DepartmentDesk.editionBriefTitle }.count, 2,
                       "one door per edition. Buttons published: \(labels.sorted())")
    }

    /// **Clicking a door carries the ROW's own tag**, so two editions cannot
    /// open one brief. Driven through a real click on the button the row
    /// actually got — the reading `ReviewBoardPaneTests` is calibrated against.
    func test_theDoorReportsTheLanguageItBelongsTo() async throws {
        var opened: [String] = []
        let window = mount(languages: ["es", "fr"], proposals: 0,
                           openEditionBrief: { opened.append($0) })
        _ = try await scrollersSettling(in: window)

        let doors = try await doorsSettling(in: window, expecting: 2)
        // Row order is the language order, and the rows stack — so the second
        // door down is `fr`'s. Read off the frames each one GOT rather than off
        // subview order.
        await click(doors[1], in: window, until: { !opened.isEmpty })

        XCTAssertEqual(opened, ["fr"],
                       "the second row's door opened \(opened) — a door that "
                       + "captured the wrong row's tag would open the first")
    }

    // MARK: - Census

    /// **The desk reads no store** (tripwire 4). Its values are assembled by the
    /// mount precisely because assembling them is expensive — the language union
    /// walks every document's translation store and the proposal count reads
    /// `.maugham/design/proposals/` — and a `body` that could reach either would
    /// pay for it once per row. Tasks 2–4 add the rows' contents and their
    /// verbs: the verbs arrive as closures, the contents as values, and neither
    /// makes this census stale.
    func test_theSourceReadsNoStoreAtAll() throws {
        let code = try Self.codeLines(of: "Views/Publish/DepartmentPane.swift")

        for forbidden in ["ProjectStore", "DocumentStore", "TranslationStore",
                          "DesignProposalStore", "FileManager", "contentsOf"] {
            XCTAssertFalse(code.contains { $0.contains(forbidden) },
                           "`\(forbidden)` appears on the pane's path — the desk "
                           + "takes values so nothing per-row can reach the disk "
                           + "(tripwire 4)")
        }
    }

    // MARK: - Hosting

    /// Bare tags, for the tests that are about the sections rather than a row's
    /// contents: every figure zero, nobody named.
    private func mount(languages: [String], proposals: Int,
                       width: CGFloat = 340,
                       openEditionBrief: @escaping (String) -> Void = { _ in }) -> NSWindow {
        mount(rows: languages.map {
            EditionStatus.LanguageRow(language: $0, translator: nil,
                                      fresh: 0, stale: 0, missing: 0, openQueries: 0)
        }, proposals: proposals, width: width, openEditionBrief: openEditionBrief)
    }

    private func mount(rows: [EditionStatus.LanguageRow], proposals: Int,
                       width: CGFloat = 340,
                       openEditionBrief: @escaping (String) -> Void = { _ in }) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: width, height: 600)
        let hosting = NSHostingView(rootView: AnyView(
            DepartmentPane(title: "The Project",
                           languages: rows,
                           designProposalCount: proposals,
                           openEditionBrief: openEditionBrief)
                .frame(maxWidth: .infinity, maxHeight: .infinity)))
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

    private func scrollViews(in window: NSWindow) -> [NSScrollView] {
        collect(NSScrollView.self, in: window)
    }

    private func scrollersSettling(in window: NSWindow,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) async throws -> [NSScrollView] {
        var found: [NSScrollView] = []
        _ = await pumpUntil(deadline: 5) {
            found = self.scrollViews(in: window)
            return !found.isEmpty
        }
        pump(0.2)
        found = scrollViews(in: window)
        XCTAssertFalse(found.isEmpty,
                       "the desk mounted no sections at all", file: file, line: line)
        return found
    }

    /// The pane's buttons, in the order a writer reads them — down the rows.
    /// A SwiftUI `Button` mounts a private focus-ring view, which is what
    /// `ReviewBoardPaneTests.chips` reads too; sorted by the frame each one GOT
    /// rather than by subview order, so "the second row's door" names the
    /// control on screen whatever the layout did with this width.
    private func doors(in window: NSWindow) -> [NSView] {
        guard let content = window.contentView else { return [] }
        return collect(NSView.self, in: window)
            .filter { String(describing: type(of: $0)).contains("FocusRingView") }
            .map { (view: $0, frame: $0.convert($0.bounds, to: content)) }
            .sorted { $0.frame.midY < $1.frame.midY }
            .map(\.view)
    }

    private func doorsSettling(in window: NSWindow, expecting count: Int,
                               file: StaticString = #filePath,
                               line: UInt = #line) async throws -> [NSView] {
        var found: [NSView] = []
        _ = await pumpUntil(deadline: 5) {
            found = self.doors(in: window)
            return found.count >= count
        }
        pump(0.2)
        found = doors(in: window)
        XCTAssertEqual(found.count, count,
                       "the desk mounted \(found.count) doors, not \(count)",
                       file: file, line: line)
        return found
    }

    /// A real click at the centre of a view — down and up through the window,
    /// so the `Button` gets its chance exactly as it does under a mouse.
    private func click(_ view: NSView, in window: NSWindow,
                       until settled: (() -> Bool)? = nil) async {
        let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let point = view.convert(centre, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(event)
            }
            pump(0.03)
        }
        if let settled { _ = await pumpUntil(deadline: 3, settled) }
    }

    private func axButtonLabels(in window: NSWindow) throws -> [String] {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process "
                + "(AXUIElementCopyAttributeValue -> \(error.rawValue)), so "
                + "SwiftUI never builds the tree this test reads")
        }
        let root = try XCTUnwrap(window.contentView)
        return axElements(under: root)
            .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            .compactMap { axAttribute($0, "accessibilityLabel") as? String }
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

    /// Every string the mounted desk publishes — a static text's value, plus any
    /// label an element carries. `ReviewBoardPaneTests.axButtonLabels`' shape,
    /// widened to text because this pane has no buttons yet.
    private func axTexts(in window: NSWindow) throws -> [String] {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process "
                + "(AXUIElementCopyAttributeValue -> \(error.rawValue)), so "
                + "SwiftUI never builds the tree this test reads")
        }
        let root = try XCTUnwrap(window.contentView)
        return axElements(under: root).flatMap { element -> [String] in
            [axAttribute(element, "accessibilityValue") as? String,
             axAttribute(element, "accessibilityLabel") as? String]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
        }
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

    // MARK: - A project on disk (the derivation's fixture)

    /// Two manuscript documents, open and registered — `TranslationStatusTool
    /// Tests`' harness, because the point of these tests is that the desk and
    /// that tool answer alike and a fixture of my own would be a second world
    /// for them to agree in.
    private struct Fixture {
        let projectURL: URL
        let projectId: String
        let projectStore: ProjectStore
        let documentStore: DocumentStore
        let registry: ProjectRegistry
        let doc1: Document
        let doc2: Document
    }

    private func makeProject() async throws -> Fixture {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DPT-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)

        let path1 = "manuscript/c1.md"
        let path2 = "manuscript/c2.md"
        try "Doc one first.\n\nDoc one second."
            .write(to: tmp.appendingPathComponent(path1), atomically: true, encoding: .utf8)
        try "Doc two only."
            .write(to: tmp.appendingPathComponent(path2), atomically: true, encoding: .utf8)

        let manifest = ProjectManifest(
            type: .novel, title: "The Project", author: "A",
            created: Date(), modified: Date(),
            structure: [
                StructureItem(id: "doc-1", title: "Chapter 1", type: .document, path: path1),
                StructureItem(id: "doc-2", title: "Chapter 2", type: .document, path: path2),
            ],
            research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let projectStore = try await ProjectStore.load(from: tmp)
        let documentStore = try await DocumentStore.open(url: tmp)
        projectStore.documentStore = documentStore

        let doc1 = try await Document.load(
            url: tmp.appendingPathComponent(path1),
            device: "test", session: "s", presenter: nil)
        documentStore.register(document: doc1, for: path1)
        let doc2 = try await Document.load(
            url: tmp.appendingPathComponent(path2),
            device: "test", session: "s", presenter: nil)
        documentStore.register(document: doc2, for: path2)

        let registry = ProjectRegistry()
        registry.register(url: tmp, store: projectStore)

        return Fixture(projectURL: tmp, projectId: ProjectIdentifier.id(for: tmp),
                       projectStore: projectStore, documentStore: documentStore,
                       registry: registry, doc1: doc1, doc2: doc2)
    }

    private func seed(_ fixture: Fixture, doc: Document, paragraphId: String,
                      language: String, text: String) async throws {
        let source = doc.paragraphs[paragraphId] ?? ""
        try await TranslationStore.append(
            TranslationRecord(paragraphId: paragraphId, language: language, text: text,
                              sourceHash: TranslationHash.hash(source), verbatim: false),
            forDocId: doc.docId,
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current),
            in: fixture.projectURL)
    }

    private func addQuery(_ fixture: Fixture, doc: Document, paragraphId: String,
                          body: String, language: String) async throws {
        let params: [String: Any] = [
            "project_id": fixture.projectId,
            "document_id": doc.docId,
            "paragraph_id": paragraphId,
            "body": body,
            "language": language,
        ]
        _ = try await AddQueryTool.handle(
            paramsJSON: try JSONSerialization.data(withJSONObject: params),
            registry: fixture.registry)
    }

    /// `translation_status`' own answer over the same fixture — the other half
    /// of the agreement.
    private func toolRows(_ fixture: Fixture) async throws -> [TranslationStatusTool.Row] {
        let params = try JSONSerialization.data(
            withJSONObject: ["project_id": fixture.projectId])
        let out = try await TranslationStatusTool.handle(
            paramsJSON: params, registry: fixture.registry)
        return try JSONDecoder().decode(
            TranslationStatusTool.Result.self, from: out).rows
    }

    private static var appSourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
    }

    private static func codeLines(of relativePath: String) throws -> [String] {
        let url = appSourceDir.appendingPathComponent(relativePath)
        return SourceScan.codeLines(of: try String(contentsOf: url, encoding: .utf8))
    }
}
