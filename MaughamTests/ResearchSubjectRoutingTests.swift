import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The centre and the right column follow a research subject** (shell-finish
/// stage-2a Task 5, spec §4).
///
/// Task 4 gave every persona's tree a Research and a Palette section, so every
/// tree can now name a research item as the window's subject. This is the other
/// half: what the rest of the window does about it.
///
/// Two rules, and they differ by column:
///
/// - Where the centre is **not** the canvas, the research subject takes the
///   centre — the note, the card or the preview — and the right column inspects
///   it. That is spec §4's Author cell.
/// - Where the centre **is** the canvas (Plan's `.canvas` and `.tree`), the
///   canvas stays exactly where it is and the right column previews the item
///   instead. `CanvasTreeSegmentMountTests` measured what a second centre-column
///   branch costs — the writer's camera, layouts and thumbnails, on every
///   selection — so a research click in Plan must not swap the centre.
///
/// **The mounted half drives the REAL tree**, one per host: a row is selected
/// through `List(selection:)` and the assertion is about the surface that
/// actually reached the window. The route functions alone would pass over a
/// window that mounts nothing (the mode-UX lesson: 22 green undo tests on a ⌘Z
/// that could not reach the stack).
@MainActor
final class ResearchSubjectRoutingTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // This suite mounts EditorSurface and the palette editor, both of which
        // style text through production typography.
        FontWarmup.ensure()
    }

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []
    private var defaultsSuites: [String] = []

    override func setUp() async throws {
        temp = TempDirectory()
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
        temp.cleanup()
        temp = nil
    }

    // MARK: - Where the research subject lands

    /// Every segment whose centre is a document — Author's, Review's and
    /// Publish's whole left column today — hands the centre over.
    func test_aResearchSubjectTakesTheCentreWhereTheSegmentHasNoResearchOfItsOwn() {
        for segment in [BinderSegment.manuscript, .scenes, .find, .trash] {
            XCTAssertEqual(
                ProjectWindow.researchSubjectPlacement(
                    binderSegment: segment, subject: .research("r1")),
                .takesTheCentre("r1"),
                "\(segment) has no research surface of its own, so the window's "
                + "subject is what its centre column is about")
        }
    }

    /// The canvas keeps the centre. This is the contract
    /// `CanvasTreeSegmentMountTests` measured the cost of breaking.
    func test_theCanvasKeepsTheCentreAndTheItemIsPreviewedBesideIt() {
        for segment in BinderSegment.allCases where segment.centresTheCanvas {
            XCTAssertEqual(
                ProjectWindow.researchSubjectPlacement(
                    binderSegment: segment, subject: .research("r1")),
                .besideTheCanvas("r1"),
                "\(segment) draws the canvas in the centre — a research click "
                + "must not swap it out and take the writer's camera with it")
        }
    }

    /// The two transitional segments still carry the old panes and their own
    /// `selectedResearchId`, so the subject does not reach over them. Stage 2b
    /// deletes both panes and this arm with them.
    func test_theSegmentsThatKeepTheirOwnResearchSelectionAreLeftAlone() {
        for segment in [BinderSegment.research, .palette] {
            XCTAssertEqual(
                ProjectWindow.researchSubjectPlacement(
                    binderSegment: segment, subject: .research("r1")),
                .segmentStands,
                "\(segment)'s centre answers to the old pane's selection; a "
                + "second rule over the same column is two answers to one question")
        }
    }

    /// The control, and it is what stops the three above from being vacuous: a
    /// subject that is not research changes nothing, in any segment.
    func test_aSubjectThatIsNotResearchLeavesEverySegmentAlone() {
        for segment in BinderSegment.allCases {
            for subject: BinderSubject? in [nil, .project, .item("doc1")] {
                XCTAssertEqual(
                    ProjectWindow.researchSubjectPlacement(
                        binderSegment: segment, subject: subject),
                    .segmentStands,
                    "\(String(describing: subject)) in \(segment)")
            }
        }
    }

    /// **The right column previews exactly when the centre is not showing the
    /// item** — the one sentence both columns are derived from, asserted over
    /// every case rather than trusted at each call site.
    func test_thePreviewIsShownExactlyWhereTheCentreIsNotShowingTheItem() {
        let placements: [ProjectWindow.ResearchSubjectPlacement] =
            [.takesTheCentre("r1"), .besideTheCanvas("r1"), .segmentStands]
        for placement in placements {
            XCTAssertEqual(
                placement.previewsInTheRightColumn,
                placement.inspectedItemID != nil && placement.centreItemID == nil,
                "\(placement)")
        }
    }

    // MARK: - Which surface the centre shows

    /// **A palette card selected in the research tree edits through the visual
    /// editor.** `ResearchNoteEditor`'s stale open text clobbers the card model
    /// on the next re-render (a lost update), which is why the rule exists at
    /// all — and why it now lives in one function both arms call.
    func test_aPaletteCardRoutesToTheCardEditorAndNeverToTheNoteEditor() async throws {
        let store = try await novel(notes: [], cards: ["Harbour"])
        let card = try XCTUnwrap(store.paletteCardItems().first)

        let route = ProjectWindow.researchCentreRoute(
            id: card.id, in: store.manifest.research)

        XCTAssertEqual(route, .paletteCard(card.id))
    }

    func test_aTextNoteRoutesToTheNoteEditorWithItsPath() async throws {
        let store = try await novel(notes: ["Ships"], cards: [])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))
        let path = try XCTUnwrap(note.path)

        XCTAssertEqual(
            ProjectWindow.researchCentreRoute(id: note.id, in: store.manifest.research),
            .note(item: note, path: path))
    }

    /// A kind the writer cannot edit here — a PDF, an image, a link, a group —
    /// is previewed. `ResearchPreview` is the same view the `.research` segment
    /// has always shown for these.
    func test_anUneditableKindRoutesToThePreview() async throws {
        let store = try await novel(notes: [], cards: [])
        let pdf = try await importPDF(named: "Tide tables", into: store)

        XCTAssertEqual(
            ProjectWindow.researchCentreRoute(id: pdf.id, in: store.manifest.research),
            .preview(pdf))
    }

    /// The render-race arm. The sweep lands a dangling id on `.project` before
    /// the routing sees it (Task 2), but a subject and a manifest arriving in
    /// different passes leave a window in which the id names nothing.
    func test_anIdThatNamesNothingRoutesToTheEmptyState() async throws {
        let store = try await novel(notes: ["Ships"], cards: [])

        XCTAssertEqual(
            ProjectWindow.researchCentreRoute(id: "no-such-item",
                                              in: store.manifest.research),
            .missing)
        XCTAssertEqual(
            ProjectWindow.researchCentreRoute(id: nil, in: store.manifest.research),
            .missing,
            "and the `.research` segment's own arm passes nil when nothing is "
            + "selected in the old pane")
    }

    /// **The palette rule is a path prefix ending in a SEPARATOR.** A group
    /// called "Palette research" gives its notes paths that begin with the
    /// palette folder's characters and are in no way inside it — and routing one
    /// of those to the card editor shows "Card unavailable" over a note the
    /// writer can see in their tree. Drop the `+ "/"` from the rule and this is
    /// the test that goes red.
    func test_aNoteBesideThePaletteFolderIsStillANote() async throws {
        let store = try await novel(notes: [], cards: [])
        let group = try await store.addResearchItem(
            parentId: nil, title: "Palette research", kind: nil)
        let note = try await store.addResearchTextNote(
            parentId: group.id, title: "Ships")
        let path = try XCTUnwrap(note.path)
        XCTAssertTrue(path.hasPrefix(ProjectStore.paletteFolderPath),
                      "fixture precondition: the path begins with the palette "
                      + "folder's characters — got \(path)")
        XCTAssertFalse(path.hasPrefix(ProjectStore.paletteFolderPath + "/"),
                       "…and is not inside it")

        XCTAssertEqual(
            ProjectWindow.researchCentreRoute(id: note.id, in: store.manifest.research),
            .note(item: note, path: path))
    }

    // MARK: - The metrics zero themselves (contract 3)

    /// Asserted rather than re-implemented: the window already zeroes the
    /// inspector/footer metrics for any subject that is not a manuscript
    /// document, and a research subject has no `itemID` at all.
    func test_aResearchSubjectIsNotADocumentSoTheWindowsMetricsZero() async throws {
        let store = try await novel(notes: ["Ships"], cards: [])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))
        let document = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.structure, where: { $0.type == .document }))

        XCTAssertFalse(
            ProjectWindow.selectionIsDocument(.research(note.id),
                                              in: store.manifest.structure),
            "a research subject is not a document, so the metrics the "
            + "EditorCoordinator can no longer deliver are zeroed")
        XCTAssertTrue(
            ProjectWindow.selectionIsDocument(.item(document.id),
                                              in: store.manifest.structure),
            "control: a manuscript document still is one")
    }

    /// **And the manuscript status footer goes with them.** The footer's four
    /// readings are all about a manuscript document; over a research note the
    /// goal capsule is about something else and the `¶id`/element readouts are
    /// blank. The segment alone used to be a complete answer — `.manuscript`
    /// could hold nothing but a document — and this task is what made it
    /// incomplete.
    func test_theManuscriptStatusFooterIsSilentWhenAResearchItemTookTheCentre() {
        for segment in [BinderSegment.manuscript, .scenes] {
            XCTAssertTrue(
                ProjectWindow.showsStatusFooter(binderSegment: segment,
                                                subject: .item("doc1")),
                "control: \(segment) over a manuscript document still reports")
            XCTAssertFalse(
                ProjectWindow.showsStatusFooter(binderSegment: segment,
                                                subject: .research("r1")),
                "\(segment) with a research item in the centre has no document "
                + "for the footer to be about")
        }
        for segment in BinderSegment.allCases where !segment.showsManuscriptStatusFooter {
            XCTAssertFalse(
                ProjectWindow.showsStatusFooter(binderSegment: segment,
                                                subject: .item("doc1")),
                "\(segment): the segment still decides FIRST — this is a "
                + "narrowing of `showsManuscriptStatusFooter` and never a "
                + "second answer to it")
        }
    }

    // MARK: - Mounted: the note reaches the centre, through each tree

    func test_aNoteSelectedInTheNovelTreeReachesTheCentreAndTheInspector() async throws {
        let store = try await novel(notes: ["Ships"], cards: [])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))
        try seedNoteText(Self.noteText, at: note, in: store)

        let mount = try await host(store: store, tree: .binder, segment: .manuscript)
        let table = try XCTUnwrap(firstTableView(in: mount.window))
        await select(row: 1 + store.manifest.structure.count + 1, in: table,
                     until: { mount.probe.subject == .research(note.id) })

        try await assertTheNoteIsInTheCentre(of: mount, note: note)
    }

    func test_aNoteSelectedInTheCollectionTreeReachesTheCentreAndTheInspector() async throws {
        let store = try await collection(pieces: ["One"], notes: ["Ships"], cards: [])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))
        try seedNoteText(Self.noteText, at: note, in: store)

        let mount = try await host(store: store, tree: .collection, segment: .manuscript)
        let table = try XCTUnwrap(firstTableView(in: mount.window))
        await select(row: 1 + store.manifest.structure.count + 1, in: table,
                     until: { mount.probe.subject == .research(note.id) })

        try await assertTheNoteIsInTheCentre(of: mount, note: note)
    }

    func test_aNoteSelectedInTheScreenplayTreeReachesTheCentreAndTheInspector() async throws {
        let store = try await screenplay(notes: ["Ships"], cards: [])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))
        try seedNoteText(Self.noteText, at: note, in: store)

        let mount = try await host(store: store, tree: .navigator, segment: .scenes)
        let table = try XCTUnwrap(firstTableView(in: mount.window))
        // project, script, two sluglines, the Research header, then the note.
        await select(row: 5, in: table,
                     until: { mount.probe.subject == .research(note.id) })

        try await assertTheNoteIsInTheCentre(of: mount, note: note)
    }

    // MARK: - Mounted: the palette card takes the card editor

    /// The lost-update precedent, on the delivery path: a card row in the tree
    /// is a research subject like any other, and the centre must be the visual
    /// editor rather than a text editor holding the card's source.
    func test_aPaletteCardSelectedInTheTreeMountsTheCardEditorNotTheNoteEditor() async throws {
        let store = try await novel(notes: ["Ships"], cards: ["Harbour"])
        let card = try XCTUnwrap(store.paletteCardItems().first)

        let mount = try await host(store: store, tree: .binder, segment: .manuscript)
        let table = try XCTUnwrap(firstTableView(in: mount.window))
        // the project row, the chapters, Research (header + note), then the
        // Palette header and the card.
        await select(row: 1 + store.manifest.structure.count + 2 + 1, in: table,
                     until: { mount.probe.subject == .research(card.id) })

        XCTAssertEqual(mount.probe.subject, .research(card.id), "precondition")
        await pumpUntil(deadline: 5) { !self.segmentedControls(in: mount.window).isEmpty }
        XCTAssertFalse(
            segmentedControls(in: mount.window).isEmpty,
            "PaletteCardEditor's Kind picker is a segmented control and nothing "
            + "else in this window mounts one — the card must reach the visual "
            + "editor")
        XCTAssertTrue(
            textViews(in: mount.window).isEmpty,
            "…and never ResearchNoteEditor, whose stale open text clobbers the "
            + "card model on the next re-render (the lost update the rule exists "
            + "for)")
    }

    // MARK: - Mounted: the canvas keeps the centre in Plan

    /// **A research click in Plan previews the item and leaves the board
    /// alone.** Both halves are the assertion: the canvas is not rebuilt (its
    /// `load()` count does not move), and the right column shows the item.
    func test_aResearchClickInPlanPreviewsBesideACanvasThatIsNeverRebuilt() async throws {
        let store = try await novel(notes: [], cards: [])
        let pdf = try await importPDF(named: "Tide tables", into: store)

        let mount = try await host(store: store, tree: .binder, segment: .tree)
        await pumpUntil(deadline: 5) { mount.canvasLoads.count >= 1 }
        let loadsBefore = mount.canvasLoads.count
        XCTAssertGreaterThan(loadsBefore, 0,
                             "precondition: the canvas is the centre column")
        let boardBefore = try XCTUnwrap(canvasViews(in: mount.window).first,
                                        "precondition: the board is mounted")

        let table = try XCTUnwrap(firstTableView(in: mount.window))
        await select(row: 1 + store.manifest.structure.count + 1, in: table,
                     until: { mount.probe.subject == .research(pdf.id) })
        XCTAssertEqual(mount.probe.subject, .research(pdf.id), "precondition")

        await pumpUntil(deadline: 5) { !self.pdfViews(in: mount.window).isEmpty }
        XCTAssertFalse(
            pdfViews(in: mount.window).isEmpty,
            "the right column previews the item — otherwise a research click in "
            + "Plan changes nothing anywhere and the tree's Research section is "
            + "a list that does not do anything")
        XCTAssertEqual(
            mount.canvasLoads.count, loadsBefore,
            "…and the canvas was not rebuilt. A second centre-column branch "
            + "costs the camera, the layouts and the thumbnail cache on every "
            + "research click (CanvasTreeSegmentMountTests measured it)")
        XCTAssertTrue(
            canvasViews(in: mount.window).contains { $0 === boardBefore },
            "…and it is the SAME board, still in the centre. The load count "
            + "alone cannot see the other half of the failure: a placement that "
            + "gave the centre away would UNMOUNT the canvas, which runs no "
            + "load at all")
    }

    // MARK: - Shared mounted assertions

    private func assertTheNoteIsInTheCentre(
        of mount: Mount, note: ResearchItem,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        XCTAssertEqual(mount.probe.subject, .research(note.id),
                       "precondition: the tree wrote the subject", file: file, line: line)

        await pumpUntil(deadline: 5) {
            self.textViews(in: mount.window).contains { $0.string.contains(Self.noteText) }
        }
        let editors = textViews(in: mount.window)
        XCTAssertTrue(
            editors.contains { $0.string.contains(Self.noteText) },
            "the note the tree named must be the note in the centre column — "
            + "found \(editors.count) editor(s) holding "
            + "\(editors.map { String($0.string.prefix(40)) })",
            file: file, line: line)

        await pumpUntil(deadline: 5) {
            self.textFields(in: mount.window).contains { $0.stringValue == note.title }
        }
        XCTAssertTrue(
            textFields(in: mount.window).contains { $0.stringValue == note.title },
            "and the right column inspects it — InspectorResearchPanel's Title "
            + "field carries the item's own title",
            file: file, line: line)
    }

    // MARK: - Fixtures

    private static let noteText = "Ships at anchor, unhurried."

    private static let twoScenes = FountainTokenizer().parse(
        "INT. KITCHEN - DAY\n\nLarry sits.\n\nEXT. ROOF - NIGHT\n\nHe climbs.\n")

    private func novel(notes: [String], cards: [String]) async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url),
                                 notes: notes, cards: cards)
    }

    private func collection(pieces: [String], notes: [String],
                            cards: [String]) async throws -> ProjectStore {
        let url = try await ProjectFactory.createCollectionProject(
            named: "Collection-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        for title in pieces { _ = try await store.addLoosePiece(title: title, mode: .prose) }
        return try await furnish(store, notes: notes, cards: cards)
    }

    private func screenplay(notes: [String], cards: [String]) async throws -> ProjectStore {
        let url = try await ProjectFactory.createScreenplayProject(
            named: "Screenplay-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url),
                                 notes: notes, cards: cards)
    }

    private func furnish(_ store: ProjectStore, notes: [String],
                         cards: [String]) async throws -> ProjectStore {
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        documentStores.append(ds)
        for title in notes {
            _ = try await store.addResearchTextNote(parentId: nil, title: title)
        }
        for title in cards {
            _ = try await store.addPaletteCard(title: title, kind: .location)
        }
        await store.wordCountPopulationTask?.value
        return store
    }

    /// A research item the centre column can only PREVIEW. A PDF rather than a
    /// link: `LinkPreview` is a `WKWebView` and would reach the network.
    private func importPDF(named title: String,
                           into store: ProjectStore) async throws -> ResearchItem {
        let source = temp.url.appendingPathComponent("\(title).pdf")
        try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: source)
        let imported = try await store.importResearchFiles([source], toParentId: nil)
        let item = try XCTUnwrap(imported.first)
        XCTAssertEqual(item.kind, .pdf, "fixture precondition")
        return item
    }

    private func researchItem(named title: String, in store: ProjectStore) -> ResearchItem? {
        TreeWalk.first(in: store.manifest.research, where: { $0.title == title })
    }

    /// `ResearchNoteEditor` loads the note's text off disk, so the words the
    /// centre column shows are the words in the file.
    private func seedNoteText(_ text: String, at item: ResearchItem,
                              in store: ProjectStore) throws {
        let path = try XCTUnwrap(item.path)
        try Data(text.utf8).write(to: store.url.appendingPathComponent(path))
    }

    // MARK: - Hosting

    private typealias Tree = ResearchSubjectRoutingProbeTree

    private struct Mount {
        let window: NSWindow
        let probe: BinderSubjectProbe
        let canvasLoads: CanvasLoadCounter
    }

    private func host(store: ProjectStore, tree: Tree,
                      segment: BinderSegment) async throws -> Mount {
        let probe = BinderSubjectProbe()
        let counter = CanvasLoadCounter()
        let suite = "research-subject-routing-\(UUID().uuidString)"
        defaultsSuites.append(suite)
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!)
        let documentStore = try XCTUnwrap(store.documentStore)

        let root = ResearchRoutingProbeView(
            store: store,
            documentStore: documentStore,
            tree: tree,
            segment: segment,
            script: tree == .navigator ? Self.twoScenes : nil,
            documentID: TreeWalk.first(in: store.manifest.structure,
                                       where: { $0.type == .document })?.id,
            probe: probe,
            canvasModel: CanvasModel(),
            canvasLoads: counter)
            .environment(preferences)

        let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        await pumpUntil(deadline: 5) { self.firstTableView(in: window) != nil }
        // The palette section loads its cards from disk once per manifest
        // change, so its rows arrive a turn after the table does.
        pump(0.2)
        return Mount(window: window, probe: probe, canvasLoads: counter)
    }

    private func select(row: Int, in table: NSTableView,
                        until settled: (() -> Bool)? = nil) async {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if let settled {
            await pumpUntil(deadline: 5, settled)
        } else {
            await waitOut(0.4)
        }
    }

    // MARK: - Reading the mounted window

    private func firstTableView(in window: NSWindow) -> NSTableView? {
        collect(NSTableView.self, in: window).first
    }

    private func textViews(in window: NSWindow) -> [MaughamTextView] {
        collect(MaughamTextView.self, in: window)
    }

    private func textFields(in window: NSWindow) -> [NSTextField] {
        collect(NSTextField.self, in: window)
    }

    private func segmentedControls(in window: NSWindow) -> [NSSegmentedControl] {
        collect(NSSegmentedControl.self, in: window)
    }

    private func canvasViews(in window: NSWindow) -> [CanvasEventNSView] {
        collect(CanvasEventNSView.self, in: window)
    }

    private func pdfViews(in window: NSWindow) -> [NSView] {
        collect(NSView.self, in: window)
            .filter { String(describing: type(of: $0)).contains("PDFView") }
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
}

// MARK: - Probes

/// How many times the mounted canvas has run its `.onAppear` load — the
/// production path `CanvasTreeSegmentMountTests` counts, so a rebuilt canvas is
/// visible as the number moving rather than through an instrument invented for
/// this test.
@MainActor
final class CanvasLoadCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

/// **The three columns, wired the way `ProjectWindow` wires them.**
///
/// The tree is production's own (all three hosts), the subject binding is the
/// window's, and both other columns are chosen by the SAME
/// `ProjectWindow.researchSubjectPlacement` value the window's `editorPane` and
/// `inspectorPane` read. Nothing here re-spells the rule — a probe that decided
/// for itself which column gets the item would be testing the probe.
@MainActor
private struct ResearchRoutingProbeView: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    let tree: ResearchSubjectRoutingProbeTree
    let segment: BinderSegment
    let script: FountainScript?
    let documentID: String?
    let probe: BinderSubjectProbe
    let canvasModel: CanvasModel
    let canvasLoads: CanvasLoadCounter

    @State private var renaming: String?

    private var subject: Binding<BinderSubject?> {
        Binding(get: { probe.subject }, set: { probe.subject = $0 })
    }

    private var placement: ProjectWindow.ResearchSubjectPlacement {
        ProjectWindow.researchSubjectPlacement(binderSegment: segment,
                                               subject: probe.subject)
    }

    var body: some View {
        HStack(spacing: 0) {
            treeColumn.frame(width: 300)
            centre.frame(maxWidth: .infinity, maxHeight: .infinity)
            right.frame(width: 320)
        }
    }

    @ViewBuilder
    private var treeColumn: some View {
        switch tree {
        case .binder:
            BinderView(store: store, selectedSubject: subject)
        case .collection:
            CollectionPiecesPane(store: store, selectedSubject: subject,
                                 renamingItemId: $renaming)
        case .navigator:
            SceneNavigatorPane(store: store, script: script,
                               projectTitle: store.manifest.title,
                               selectedSubject: subject,
                               documentID: documentID,
                               onSelect: { _ in })
        }
    }

    @ViewBuilder
    private var centre: some View {
        if let id = placement.centreItemID {
            ResearchSubjectCentre(store: store, documentStore: documentStore,
                                  itemID: id, previewVisible: false)
        } else if segment.centresTheCanvas {
            CanvasView(model: canvasModel, projectRoot: store.url,
                       paletteSwatchHexes: { canvasLoads.record(); return [] })
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var right: some View {
        if let id = placement.inspectedItemID {
            ResearchSubjectInspector(store: store, itemID: id,
                                     showsPreview: placement.previewsInTheRightColumn)
        } else {
            Color.clear
        }
    }
}

/// The probe's tree choice, at file scope because a nested type cannot be named
/// from the test's own `private enum Tree` across the file boundary.
enum ResearchSubjectRoutingProbeTree { case binder, collection, navigator }
