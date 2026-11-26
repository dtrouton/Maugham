import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **Nothing in the right column is laid out wider than the column** — mounted,
/// at the narrowest column the narrowest window gives, after each arm has
/// loaded what it loads.
///
/// The owner's hand check (2026-11-21): a palette card pulled up beside the
/// Palette wall ran off the window's trailing edge — the control's segment,
/// Open in Centre and Close, the Title field, the Kind picker, Paste, Restore.
/// Measured: the editor's segmented Kind picker cannot compress and asked
/// about 336pt (plus the editor's padding, 368pt) of a 232pt pane; the six
/// sense buttons' row asked about 325pt. Either widened the whole pane — the
/// control and the research panel with it — and `RightColumn`'s leading clip
/// cut the overflow at the window's edge.
///
/// `RightColumnPaneWidthTests` cannot see this: it measures each arm's FIRST
/// frame by proposal, and the palette editor draws "Loading…" until its
/// `.task` has read the card. This suite mounts the real `RightColumn` and
/// reads every AppKit-backed view's frame once the arm has settled — a text
/// field, a picker, a scroll view or the control's own host lying past the
/// column's edge is the overflow the writer sees. (Pure SwiftUI text draws no
/// `NSView`; the containers it widens do.)
@MainActor
final class PulledUpFitsTheColumnTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        await waitOut(0.05)
        windows.removeAll()
        try await super.tearDown()
    }

    // MARK: - The width

    /// **The column at the narrowest window the app allows**: the window's own
    /// floor, a writer whose wish is the column's floor. The window floor
    /// affords at least that (the arithmetic is `DetailColumnWidthTests`'), so
    /// this is the narrowest column a writer can ever be shown.
    private static var narrowest: Double {
        ProjectWindow.effectiveDetailColumnWidth(
            persisted: UIState.detailColumnWidthRange.lowerBound,
            containerWidth: Double(ProjectWindow.windowFloor))
    }

    private static let slack: CGFloat = 0.5

    // MARK: - The instrument

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    /// Every SHOWN AppKit-backed view whose frame runs past `width` in the
    /// hosting view's coordinates, named. A hidden view draws nothing — the
    /// editor's selection toolbar waits hidden wherever it was last placed.
    private static func overflow(in host: NSView, width: CGFloat) -> [String] {
        descendants(of: host).compactMap { view in
            guard !view.isHiddenOrHasHiddenAncestor else { return nil }
            let frame = view.convert(view.bounds, to: host)
            guard frame.maxX > width + slack, frame.width > 0 else { return nil }
            return "\(type(of: view)) maxX \(frame.maxX)"
        }
    }

    /// **Both scales a writer's display can have.** This Mac's own, and 1x
    /// (`OneXTestWindow`): a layout a hair wider than the column rounds to
    /// half a point past it on a Retina display, inside `slack`, and to a
    /// whole point on a 1x one — CI's display, which is how the cast
    /// edition's Adopt and the control's floating-point row were found.
    private enum Scale: CaseIterable { case native, oneX }

    private func mount(_ column: some View, width: Double, scale: Scale = .native) -> NSWindow {
        let size = CGSize(width: width, height: 900)
        let window: NSWindow = switch scale {
        case .native: TestWindow.mount(column, size: size)
        case .oneX: TestWindow.mount(column, size: size, as: OneXTestWindow.self)
        }
        windows.append(window)
        return window
    }

    /// Mount `column` at each scale, wait for `ready` (the arm's loaded
    /// state), let any trailing `.task` settle, and return what overflows,
    /// a 1x overflow named "1x:".
    private func overflowOnceSettled(_ column: some View, width: Double,
                                     ready: @escaping (NSView) -> Bool = { _ in true }) async throws
        -> (overflow: [String], ready: Bool) {
        var overflow: [String] = []
        var allReady = true
        for scale in Scale.allCases {
            let window = mount(column, width: width, scale: scale)
            let host = try XCTUnwrap(window.contentView)
            let wasReady = await pumpUntil(deadline: 5) { ready(host) }
            await waitOut(0.4)
            host.layoutSubtreeIfNeeded()
            overflow += Self.overflow(in: host, width: CGFloat(width)).map { scale == .oneX ? "1x: \($0)" : $0 }
            allReady = allReady && wasReady
            window.contentView = NSView(frame: .zero)
        }
        return (overflow, allReady)
    }

    private static func showsText(_ text: String, in host: NSView) -> Bool {
        descendants(of: host).contains { ($0 as? NSTextField)?.stringValue == text }
    }

    // MARK: - The planted control

    /// The instrument sees an over-wide control inside the real column's
    /// frame and clip, so a green run below is a measurement.
    func test_theInstrumentSeesAnOverWideControlInTheColumn() async throws {
        let width = Self.narrowest
        let overWide = HStack(spacing: 0) {
            TextField("", text: .constant("wide")).frame(width: width + 80)
        }
        .frame(width: width, alignment: .leading)
        .clipped()
        let (overflow, _) = try await overflowOnceSettled(overWide, width: width)
        XCTAssertFalse(overflow.filter { !$0.hasPrefix("1x: ") }.isEmpty,
                       "a \(width + 80)pt text field in a \(width)pt column was not seen")
        XCTAssertFalse(overflow.filter { $0.hasPrefix("1x: ") }.isEmpty, "nor at 1x")
    }

    /// The 1x mount is a 1x layout, and it sees a field 0.6pt too wide — a
    /// point at 1x — that a Retina mount rounds to half a point, inside the
    /// slack: the overhang CI's display showed and this Mac's did not.
    func test_theOneXMountSeesASubPointOverhang() async throws {
        let width = Self.narrowest
        let window = mount(Color.clear, width: width, scale: .oneX)
        XCTAssertEqual(window.backingScaleFactor, 1, "premise: the 1x window lays out at 1x")
        let hair = HStack(spacing: 0) {
            TextField("", text: .constant("hair")).frame(width: width + 0.6)
        }
        .frame(width: width, alignment: .leading)
        .clipped()
        let (overflow, _) = try await overflowOnceSettled(hair, width: width)
        XCTAssertTrue(overflow.contains { $0.hasPrefix("1x: ") }, "the 1x mount missed a 0.6pt overhang")
        if NSScreen.main?.backingScaleFactor == 2 {
            XCTAssertFalse(overflow.contains { !$0.hasPrefix("1x: ") },
                           "on Retina the half point is inside the slack — why the 1x mount exists")
        }
    }

    // MARK: - The palette card, the owner's case

    /// **A palette card pulled up beside the Palette wall, at the narrowest
    /// column**, with more swatches than one line holds and a note of each
    /// sense: every control lies inside the column, and the Kind picker is a
    /// menu (the segments do not fit).
    func test_aPaletteCardPulledUpFitsTheNarrowestColumn() async throws {
        let f = try await makeFixture()
        let width = Self.narrowest
        XCTAssertEqual(width, UIState.detailColumnWidthRange.lowerBound,
                       "premise: the narrowest window shows the narrowest column")
        let probe = RightColumnFixture.Probe(
            position: .pulledUp,
            subject: WindowSubject(open: .palette, faces: .palette, beside: .research(f.cardId)))
        let (overflow, ready) = try await overflowOnceSettled(
            RightColumnFixture.column(store: f.store, documentStore: f.documentStore,
                                      probe: probe, width: width)
                .environment(f.preferences),
            width: width,
            ready: { Self.showsText("Beach", in: $0) })
        XCTAssertTrue(ready, "premise: the editor read the card (its Title field says Beach)")
        XCTAssertEqual(overflow, [],
            "the palette card pulled up runs past the \(width)pt column — the "
            + "column clips it at the window's edge:\n" + overflow.joined(separator: "\n"))
    }

    /// The editor's two Kind pickers: segments in a wide column, a menu in a
    /// narrow one — measured, so the switch is not a guess about the words.
    func test_theKindPickerIsSegmentsWhenWideAndAMenuWhenNarrow() async throws {
        let f = try await makeFixture()
        func hasSegments(width: Double) async throws -> Bool {
            let editor = PaletteCardEditor(store: f.store, cardId: f.cardId)
                .frame(width: width, height: 900)
            let window = mount(editor, width: width)
            let host = try XCTUnwrap(window.contentView)
            _ = await pumpUntil(deadline: 5) { Self.showsText("Beach", in: host) }
            await waitOut(0.2)
            XCTAssertTrue(Self.descendants(of: host).contains { $0 is NSColorWell },
                          "premise: the editor is drawn (its swatch well)")
            return Self.descendants(of: host).contains { $0 is NSSegmentedControl }
        }
        let narrow = try await hasSegments(width: Self.narrowest - Double(RightColumn.resizeHandleWidth))
        let wide = try await hasSegments(width: 700)
        XCTAssertFalse(narrow, "at the column's floor the Kind picker is a menu")
        XCTAssertTrue(wide, "with room the Kind picker is its segments")
    }

    // MARK: - Every pulled-up kind and both faces

    /// **Every arm a novel's window can show** (`RightColumnFixture.arms`,
    /// whose coverage of the content enum `RightColumnPaneWidthTests`
    /// asserts), plus a palette card pulled up — each mounted at the
    /// narrowest column and left to load. (The read-only card is the centre's
    /// own card's face, which `face(of:)` pins; Lock's second pass went with
    /// Lock: no piece owns a palette card, so read-through never reaches it.)
    func test_everyArmFitsTheNarrowestColumnOnceLoaded() async throws {
        let f = try await makeFixture()
        let width = Self.narrowest
        var arms = RightColumnFixture.arms(docId: f.docId, partId: f.partId, noteId: f.noteId)
        let palette = WindowSubject(open: .palette, faces: .palette, beside: .research(f.cardId))
        arms.append(.init(name: "a palette card pulled up", position: .pulledUp, subject: palette))
        var offenders: [String] = []
        for arm in arms {
            let control = EditorControl()
            control.translationLanguage = arm.translationLanguage
            let probe = RightColumnFixture.Probe(position: arm.position, subject: arm.subject)
            let (overflow, _) = try await overflowOnceSettled(
                RightColumnFixture.column(store: f.store, documentStore: f.documentStore,
                                          probe: probe, editorControl: control, width: width)
                    .environment(f.preferences),
                width: width)
            if !overflow.isEmpty {
                offenders.append("\(arm.name): " + overflow.prefix(3).joined(separator: "; "))
            }
            for window in windows { window.contentView = NSView(frame: .zero) }
            windows.removeAll()
        }
        XCTAssertEqual(offenders, [],
            "these arms run past the \(width)pt column once loaded:\n"
            + offenders.joined(separator: "\n"))
    }

    // MARK: - To resolve's head, folded and open (2026-11-26)

    /// **To resolve fits the narrowest column with its head folded and
    /// open** — every To resolve arm, and a piece's head with a compiler
    /// behind it (the round cockpit, the check's header, both Ask fields),
    /// at both scales.
    func test_toResolvesHeadFitsTheNarrowestColumnFoldedAndOpen() async throws {
        let f = try await makeFixture()
        let width = Self.narrowest
        let arms = RightColumnFixture.arms(docId: f.docId, partId: f.partId, noteId: f.noteId)
            .filter { $0.position == .resolve }
        let root = f.store.url
        var offenders: [String] = []
        for open in [false, true] {
            f.documentStore.setResolveHeadOpen(open)
            let state = open ? "open" : "folded"
            for arm in arms {
                let control = EditorControl()
                control.translationLanguage = arm.translationLanguage
                let probe = RightColumnFixture.Probe(position: arm.position, subject: arm.subject)
                let (overflow, _) = try await overflowOnceSettled(
                    RightColumnFixture.column(store: f.store, documentStore: f.documentStore,
                                              probe: probe, editorControl: control, width: width)
                        .environment(f.preferences),
                    width: width)
                if !overflow.isEmpty {
                    offenders.append("\(arm.name), \(state): " + overflow.prefix(3).joined(separator: "; "))
                }
                for window in windows { window.contentView = NSView(frame: .zero) }
                windows.removeAll()
            }
            let head = ResolveHeadView(
                scope: .piece(docId: f.docId, includesBookLevel: false), snapshot: .empty,
                openDocId: f.docId, store: f.store, documentStore: f.documentStore,
                orchestrator: CompilerOrchestrator(),
                diagnostics: DiagnosticsStore(projectRoot: root, device: DeviceSlug.make(from: "fit-mac")),
                world: nil, reader: .nobody, compilerModel: .standard,
                onCompilerModelChange: { _ in }, onChooseReader: { _ in }, onOpenProjectSettings: {},
                onSetActivePass: { _, _ in }, onSetPassState: { _, _, _ in })
                .frame(width: width, alignment: .top)
                .environment(f.preferences)
            let (overflow, _) = try await overflowOnceSettled(head, width: width)
            if !overflow.isEmpty {
                offenders.append("a piece's head with a compiler, \(state): "
                                 + overflow.prefix(3).joined(separator: "; "))
            }
            for window in windows { window.contentView = NSView(frame: .zero) }
            windows.removeAll()
        }
        XCTAssertEqual(offenders, [],
            "To resolve runs past the \(width)pt column:\n" + offenders.joined(separator: "\n"))
    }

    // MARK: - The filter bar, one row (fix round 1, B2)

    /// **To resolve's filter bar is one row at the narrowest column**, with
    /// every chip, the triage control in each state and the overflow menu,
    /// at both scales: its height is the bare chips row's.
    func test_theFilterBarIsOneRowAtTheNarrowestColumnWithTriage() async throws {
        let width = Self.narrowest
        let chips: [ResolveSource] = [.pass("structural"), .pass("line"), .mine, .checks, .others, .questions]
        func bar(triage: ResolveTriageChoice?, actions: Bool) -> some View {
            ResolveFilterBar(
                chips: chips, selection: [], passes: ReviewPass.presets,
                showsSelectionMode: actions, selectionModeOn: false, showsNewTodo: actions,
                triage: triage, onToggle: { _ in }, onToggleSelectionMode: {}, onNewTodo: {})
                .frame(width: width)
        }
        for scale in Scale.allCases {
            let bare = mount(bar(triage: nil, actions: false), width: width, scale: scale)
            await waitOut(0.2)
            let oneRow = try XCTUnwrap(bare.contentView).fittingSize.height
            for choice in ResolveTriageChoice.allCases {
                let window = mount(bar(triage: choice, actions: true), width: width, scale: scale)
                await waitOut(0.2)
                let height = try XCTUnwrap(window.contentView).fittingSize.height
                XCTAssertEqual(height, oneRow, accuracy: 0.5,
                               "\(scale) with triage \(choice): the bar is \(height)pt, one row is \(oneRow)pt")
                window.contentView = NSView(frame: .zero)
            }
            bare.contentView = NSView(frame: .zero)
        }
    }

    // MARK: - New To-Do's sheet (fix round 1, B5)

    /// **New To-Do's buttons show their whole titles** — a novel's and a
    /// Collection's noun, both scopes offered, at both scales: no button is
    /// laid out narrower than its title asks.
    func test_newToDosButtonsShowTheirWholeTitles() async throws {
        var offenders: [String] = []
        for noun in [PieceNoun.chapter, PieceNoun.piece] {
            for scale in Scale.allCases {
                let sheet = NewTaskSheet(taskBody: .constant("Fix the fog"), scope: .constant(.document),
                                         canPickDocumentScope: true, canPickProjectScope: true,
                                         noun: noun, onCommit: {}, onCancel: {})
                let window = mount(sheet, width: 380, scale: scale)
                await waitOut(0.3)
                try requireAssistiveClient()
                // Each button's own width, alone and unconstrained, in the
                // sheet's styles: what its whole title asks.
                let wants: [String: CGFloat] = [
                    "Cancel": NSHostingView(rootView: Button("Cancel", role: .cancel) {}.fixedSize()).fittingSize.width,
                    "Add": NSHostingView(rootView: Button("Add") {}.buttonStyle(.borderedProminent)
                        .fixedSize()).fittingSize.width,
                ]
                for (title, want) in wants {
                    let found = try axButtons(labelled: title, in: window)
                    XCTAssertEqual(found.count, 1, "premise: one \(title) (\(scale), \(noun.singular))")
                    guard let rect = found.first.flatMap({ (axAttribute($0, "accessibilityFrame") as? NSValue)?.rectValue })
                    else { continue }
                    if rect.width + 1 < want {
                        offenders.append("\(noun.singular), \(scale): \(title) is \(rect.width)pt of \(want)pt")
                    }
                }
                window.contentView = NSView(frame: .zero)
            }
        }
        XCTAssertEqual(offenders, [], offenders.joined(separator: "\n"))
    }

    // MARK: - An edition's Brief, in every state (shell p4 Task 7)

    /// **An edition's Brief fits the narrowest column in every state**: a
    /// translated edition with its whole cast named long and a proposed brief
    /// pending, an edition nobody is cast for, and the Source with a long
    /// designer's name and proposals for two languages it has no edition of —
    /// each once loaded.
    func test_anEditionsBriefFitsTheNarrowestColumnInEveryState() async throws {
        let f = try await makeFixture()
        let width = Self.narrowest
        let long = "Guadalupe Nettel de la Cruz y Ocampo Bioy Casares"
        let translator = try await f.store.translatorRole(for: "es")
        try await f.store.renameProductionRole(id: translator.id, to: long)
        for mint in [f.store.readerRole(for:), f.store.collatorRole(for:)] {
            let role = try await mint("es")
            try await f.store.renameProductionRole(id: role.id, to: long)
        }
        try await f.store.renameProductionRole(id: f.store.designerRole().id, to: long)
        for language in ["es", "it", "pt-br"] {
            _ = try StatementProposalStore(projectURL: f.store.url).stage(.init(
                kind: .editionBrief(language),
                markdown: "A long proposed brief for the edition, with enough prose to wrap.",
                rationale: "The narrator's register wants a careful hand in this language.",
                proposedAt: Date(), author: "Claude"))
        }
        let source = BriefEditionView.sourceLanguage(store: f.store)
        XCTAssertEqual(EditionCastVerbs.proposalsWithoutAnEdition(
            StatementProposalStore(projectURL: f.store.url).pendingAll(),
            editions: TreeEditionRows.languages(store: f.store)), ["it", "pt-br"],
            "premise: the Source lists two proposals with no edition")
        var offenders: [String] = []
        for (name, language) in [("a cast edition", "es"), ("an uncast edition", "xx"),
                                 ("the Source", source)] {
            let subject = WindowSubject(open: .edition(language: language),
                                        faces: .edition(language: language))
            let probe = RightColumnFixture.Probe(position: .brief, subject: subject)
            let (overflow, _) = try await overflowOnceSettled(
                RightColumnFixture.column(store: f.store, documentStore: f.documentStore,
                                          probe: probe, width: width)
                    .environment(f.preferences),
                width: width)
            if !overflow.isEmpty {
                offenders.append("\(name): " + overflow.prefix(3).joined(separator: "; "))
            }
            for window in windows { window.contentView = NSView(frame: .zero) }
            windows.removeAll()
        }
        XCTAssertEqual(offenders, [],
            "an edition's Brief runs past the \(width)pt column:\n" + offenders.joined(separator: "\n"))
    }

    // MARK: - The fixture

    private struct Fixture {
        let store: ProjectStore
        let documentStore: DocumentStore
        let preferences: UserPreferences
        let docId: String
        let partId: String
        let noteId: String
        let cardId: String
    }

    private func makeFixture() async throws -> Fixture {
        let url = try await ProjectFactory.createNovelProject(
            named: "Fit-\(UUID().uuidString.prefix(6))", in: TestTemp.root)
        let store = try await ProjectStore.load(from: url)
        let documentStore = try await DocumentStore.open(url: url)
        store.documentStore = documentStore
        let item = try XCTUnwrap(
            TreeWalk.collect(in: store.manifest.structure, where: { $0.path != nil }).first,
            "premise: the novel template has a document")
        let path = try XCTUnwrap(item.path)
        try "- [ ] A task with a long enough body to wrap in a narrow column.\n\nA paragraph."
            .write(to: url.appendingPathComponent(path), atomically: true, encoding: .utf8)
        let document = try await Document.load(url: url.appendingPathComponent(path),
                                               device: "macA", session: "s1", presenter: nil)
        documentStore.register(document: document, for: path)
        let part = try await store.addStructureItem(parentId: nil, title: "Part One", kind: .group)
        let note = try await store.addResearchTextNote(
            parentId: nil, title: "A research note with a long enough title to truncate")
        for kind in [Statement.Kind.lessons, .firstReader, .visualLanguage, .intent] {
            _ = try await store.createStatement(kind: kind, scope: .project)
        }
        let card = try await store.addPaletteCard(title: "Beach", kind: .location)
        try await store.updatePaletteCard(PaletteCard(
            researchItemId: card.id, title: "Beach", kind: .location,
            swatches: ["#1E90FF", "#F4A460", "#FFFFFF", "#2E8B57", "#87CEEB",
                       "#DEB887", "#000080", "#FFD700", "#708090", "#FF7F50"],
            notes: PaletteCard.Sense.allCases.map {
                PaletteCard.SensoryNote(sense: $0, text: "Salt and wind on the \($0.rawValue) side")
            } + [PaletteCard.SensoryNote(sense: nil, text: "An untagged note")],
            imagePaths: [], body: "The tide out, the pier black against it."))
        let suite = "PulledUpFit-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return Fixture(store: store, documentStore: documentStore,
                       preferences: UserPreferences(defaults: UserDefaults(suiteName: suite)!),
                       docId: item.id, partId: part.id, noteId: note.id, cardId: card.id)
    }
}
