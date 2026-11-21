import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **Every right-column pane fits the narrowest column a writer can have** (#122).
///
/// Denver's smoke, macOS 27: the Tasks toolbar's … menu sat half off the
/// column's trailing edge and its Doc/Project picker was cut at the leading
/// edge. The toolbar wanted about 300pt on one row; the pane is drawn at the
/// column's width less the resize handle, 272pt by default and 232pt at the
/// floor. An over-wide pane inflates its own layout width, and `RightColumn`'s
/// frame then clipped it — centred, so on both edges.
///
/// **The instrument is `AnnotationsQueueToolbarWidthTests`'**: a proposal, not
/// a frame walk. `NSHostingController.sizeThatFits(in:)` offers the content a
/// width and returns the width it takes; overflow is `measured > proposed`.
/// Windowless: nothing here is mounted or pressed (tripwire 33).
@MainActor
final class RightColumnPaneWidthTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // The panes style text through production typography.
        FontWarmup.ensure()
    }

    // MARK: - The widths a pane is drawn at

    /// A pane gets the column's width less the resize handle's gutter.
    private static func paneWidth(column: Double) -> CGFloat {
        CGFloat(column) - RightColumn.resizeHandleWidth
    }

    /// The narrowest a pane is ever drawn: the floor a writer can drag to.
    private static var floor: CGFloat {
        paneWidth(column: UIState.detailColumnWidthRange.lowerBound)
    }

    /// The floor and the default, the width Denver's screenshot was taken in.
    private static var paneWidths: [CGFloat] {
        [floor, paneWidth(column: UIState.defaultDetailColumnWidth)]
    }

    private static var ceiling: CGFloat {
        paneWidth(column: UIState.detailColumnWidthRange.upperBound)
    }

    /// Sub-pixel slack for SwiftUI's rounding to the backing scale.
    private static let slack: CGFloat = 0.5

    // MARK: - The instrument

    private static func size(of view: some View, proposing width: CGFloat) -> CGSize {
        let controller = NSHostingController(rootView: AnyView(view))
        _ = controller.view
        return controller.sizeThatFits(in: CGSize(width: width, height: 4000))
    }

    private static func fits(_ view: some View, in width: CGFloat) -> (Bool, CGFloat) {
        let measured = size(of: view, proposing: width).width
        return (measured <= width + slack, measured)
    }

    /// What a variant asks for before any column squeezes it — the ideal under
    /// an unspecified proposal (a row holding a `Spacer` fills any proposal, so
    /// `sizeThatFits` cannot answer this).
    private static func idealWidth(of view: some View) -> CGFloat {
        NSHostingView(rootView: AnyView(view)).intrinsicContentSize.width
    }

    // MARK: - The planted control

    /// The check says no to an over-wide view and yes to a flexible one, so a
    /// green census below is a measurement and not a check that cannot fail.
    func test_theCheckFailsAnOverWideViewAndPassesAFlexibleOne() {
        let overWide = HStack(spacing: 0) {
            Text("Doc · Project").fixedSize()
            Color.clear.frame(width: Self.floor + 40, height: 20)
        }
        let (overFits, overMeasured) = Self.fits(overWide, in: Self.floor)
        XCTAssertFalse(overFits,
            "a fixed \(Self.floor + 40)pt row measured \(overMeasured)pt at the "
            + "\(Self.floor)pt floor — the instrument cannot see overflow")

        let flexible = HStack { Text("Doc"); Spacer(); Text("…") }
        XCTAssertTrue(Self.fits(flexible, in: Self.floor).0,
                      "the control: a flexible row fits")

        // **Why no pane wears `.frame(minWidth: 0, …)` as a "safety net".** It
        // answers the proposed width whatever its content wants, so this
        // instrument reads it as fitting — and it centres the overflow inside
        // itself, cropping both edges again. The one net is `RightColumn`'s
        // leading-aligned clip; the rule is that every pane fits.
        let (maskedFits, _) = Self.fits(
            overWide.frame(minWidth: 0, maxWidth: .infinity), in: Self.floor)
        XCTAssertTrue(maskedFits,
            "measured fact this census relies on: a minWidth-0 frame hides "
            + "its content's overflow from sizeThatFits")
    }

    // MARK: - The Tasks toolbar (retired)
    //
    // Its fit claims went with the Tasks pane (shell plan 2 Task 7); To
    // resolve's filter bar is measured by
    // `test_theFilterBarFitsTheColumnFloor` (`ResolvePaneTests`).

    // MARK: - To resolve's filter bar

    /// **Every chip and both trailing controls**, with long pass names: the
    /// chips scroll sideways, so the bar takes the width it is offered at the
    /// floor and at the default, and its trailing controls stay on the column.
    func test_theFilterBarFitsTheColumnFloor() {
        let passes = (1...4).map {
            ReviewPass(id: "p\($0)", name: "A long structural pass number \($0)")
        }
        let bar = ResolveFilterBar(
            chips: passes.map { .pass($0.id) } + [.mine, .checks, .questions, .others],
            selection: [.mine], passes: passes,
            showsSelectionMode: true, selectionModeOn: false, showsNewTodo: true,
            onToggle: { _ in }, onToggleSelectionMode: {}, onNewTodo: {})
        let chipLabels = HStack(spacing: 4) {
            ForEach(bar.chips, id: \.self) { chip in
                Text(ResolveFilterBar.label(chip, passes: passes)).font(.caption).fixedSize()
                    .padding(.horizontal, 8)
            }
        }
        XCTAssertGreaterThan(Self.idealWidth(of: chipLabels), Self.ceiling,
                             "premise: the chips alone want more than the widest column")
        for width in Self.paneWidths {
            let (fits, measured) = Self.fits(bar, in: width)
            XCTAssertTrue(fits,
                "To resolve's filter bar wants \(measured)pt in a \(width)pt pane — "
                + "an over-wide row is cropped by the column (#122)")
        }
    }

    /// **With the triage control** (Task 7b): the chips still scroll, and the
    /// triage menu sits beside them as one icon, so the bar fits the column
    /// from its floor to its ceiling whatever choice is made.
    func test_theFilterBarWithTheTriageControlFitsTheNarrowColumn() {
        let passes = (1...4).map {
            ReviewPass(id: "p\($0)", name: "A long structural pass number \($0)")
        }
        for choice in ResolveTriageChoice.allCases {
            let bar = ResolveFilterBar(
                chips: passes.map { .pass($0.id) } + [.mine, .checks, .questions, .others],
                selection: [.mine], passes: passes,
                showsSelectionMode: true, selectionModeOn: false, showsNewTodo: true,
                checksUnread: true, triage: choice,
                onToggle: { _ in }, onToggleSelectionMode: {}, onNewTodo: {})
            for width in Self.paneWidths + [Self.ceiling] {
                let (fits, measured) = Self.fits(bar, in: width)
                XCTAssertTrue(fits, "with triage \(choice) the bar wants \(measured)pt in a \(width)pt pane")
            }
        }
    }

    /// **The active choice's word is drawn, not dropped** (Task 7b fix): the
    /// bar with a choice on asks for more width than the bare flag — the
    /// word is there — and still fits every width (it wraps beneath the
    /// chips rather than clipping or reverting to the bare icon).
    func test_theActiveTriageWordIsDrawnAndStillFits() {
        func bar(_ choice: ResolveTriageChoice) -> ResolveFilterBar {
            ResolveFilterBar(chips: [.mine, .others], selection: [], passes: [],
                             showsSelectionMode: true, selectionModeOn: false, showsNewTodo: true,
                             triage: choice, onToggle: { _ in }, onToggleSelectionMode: {}, onNewTodo: {})
        }
        let bare = Self.idealWidth(of: bar(.all))
        for choice in ResolveTriageChoice.allCases where choice != .all {
            XCTAssertGreaterThan(Self.idealWidth(of: bar(choice)), bare + 10,
                                 "\(choice)'s word must be drawn beside the flag")
            for width in Self.paneWidths + [Self.ceiling] {
                let (fits, measured) = Self.fits(bar(choice), in: width)
                XCTAssertTrue(fits, "\(choice) wants \(measured)pt in \(width)pt")
            }
        }
    }

    /// **The wrapped arm, measured** (Task 7b deferred minor): with more
    /// chips than any column holds and each choice, the arm that puts the
    /// triage control beneath the chips fits every width on its own.
    func test_theTriageControlsWrappedArmFitsWithMoreChipsThanFit() {
        let passes = (1...4).map {
            ReviewPass(id: "p\($0)", name: "A long structural pass number \($0)")
        }
        for choice in ResolveTriageChoice.allCases {
            let bar = ResolveFilterBar(
                chips: passes.map { .pass($0.id) } + [.mine, .checks, .questions, .others],
                selection: [.mine], passes: passes,
                showsSelectionMode: true, selectionModeOn: false, showsNewTodo: true,
                triage: choice, onToggle: { _ in }, onToggleSelectionMode: {}, onNewTodo: {})
            for width in Self.paneWidths + [Self.ceiling] {
                let (fits, measured) = Self.fits(bar.wrapped, in: width)
                XCTAssertTrue(fits, "wrapped arm, \(choice): \(measured)pt in \(width)pt")
            }
        }
    }

    /// **The bare All flag keeps the chips' row** (review minor): however
    /// wide the chip set, the bar under All is one row tall — the flag is
    /// not pushed beneath the chips merely because they scroll.
    func test_theBareAllFlagStaysOnTheChipsRowHoweverWideTheChips() {
        let passes = (1...4).map {
            ReviewPass(id: "p\($0)", name: "A long structural pass number \($0)")
        }
        func bar(_ chips: [ResolveSource]) -> ResolveFilterBar {
            ResolveFilterBar(chips: chips, selection: [], passes: passes,
                             showsSelectionMode: true, selectionModeOn: false, showsNewTodo: true,
                             triage: .all, onToggle: { _ in }, onToggleSelectionMode: {}, onNewTodo: {})
        }
        let wide = bar(passes.map { .pass($0.id) } + [.mine, .checks, .questions, .others])
        let narrow = bar([.mine])
        for width in Self.paneWidths + [Self.ceiling] {
            let oneRow = Self.size(of: narrow, proposing: width).height
            let measured = Self.size(of: wide, proposing: width)
            XCTAssertLessThanOrEqual(measured.width, width + Self.slack)
            XCTAssertEqual(measured.height, oneRow, accuracy: 1,
                           "under All at \(width)pt the wide bar is one row, like the narrow one")
            XCTAssertGreaterThan(Self.size(of: wide.wrapped, proposing: width).height, oneRow + 5,
                                 "control: the wrapped arm is taller, so the height check can fail")
        }
    }

    // MARK: - The census: every arm the right column can show

    /// **Every arm of `RightColumnContent`, walked off `RightColumnFixture.arms`**
    /// (whose coverage of the enum is asserted), rendered by the real
    /// `RightColumn` over real stores — so the control and each arm's header
    /// are measured together, and a new arm joins by failing the coverage.
    ///
    /// Before #122 the pane picker's census failed on two panes: Tasks (the
    /// one-row toolbar, 392pt) and the Inspector (a `minWidth: 240`), both at
    /// 232pt.
    ///
    /// Each arm is measured in its first-render state over a fresh novel with
    /// one open document, a Part, a research note with a 200-character title
    /// and the three Book statements. What it cannot see: content an arm loads
    /// in a `.task` after its first frame, and a Collection's reference piece
    /// (`ReferencePieceInspector`).
    func test_noRightColumnPaneIsWiderThanTheColumn() async throws {
        let fixture = try await makeFixture()
        XCTAssertEqual(
            RightColumnFixture.kinds(of: fixture.arms, in: fixture.store),
            RightColumnFixture.armKinds.subtracting(RightColumnFixture.armKindsOnlyACollectionHas),
            "premise: the census walks every arm a novel's window can show")
        var offenders: [String] = []
        for arm in fixture.arms {
            for width in Self.paneWidths + [Self.ceiling] {
                let (fits, measured) = Self.fits(fixture.pane(arm, paneWidth: width), in: width)
                if !fits { offenders.append("\(arm.name) → \(measured)pt in \(width)pt") }
            }
        }
        XCTAssertEqual(offenders, [],
            "these right-column arms are wider than the pane they are drawn "
            + "in, and the column crops them (#122):\n"
            + offenders.joined(separator: "\n"))
    }

    /// **The control alone, with a 200-character pulled-up title, at 240, 280
    /// and 480** (plan 3 Review Focus 5): it takes the width it is offered —
    /// the title truncates in the middle — on every position.
    func test_theControlWithALongPulledUpTitleFitsTheColumn() async throws {
        let fixture = try await makeFixture()
        let pulled = try XCTUnwrap(fixture.arms.first { $0.name == "a research note pulled up" })
        XCTAssertEqual(RightColumnControl.pulledUpTitle(subject: pulled.subject, store: fixture.store)?.count,
                       200, "premise: the pulled-up title is 200 characters")
        for column in [240.0, 280.0, 480.0] {
            let width = Self.paneWidth(column: column)
            for position in RightColumnPosition.allCases {
                let control = RightColumnControlFixture.control(
                    store: fixture.store, position: .constant(position), subject: pulled.subject,
                    width: width, canvasModel: CanvasModel())
                let (fits, measured) = Self.fits(control, in: width)
                XCTAssertTrue(fits, "the control on \(position) wants \(measured)pt in a \(width)pt pane")
            }
        }
        // The planted control: the same title in a row that cannot truncate.
        let unbroken = HStack(spacing: 4) {
            Image(systemName: "pin")
            Text(RightColumnControl.pulledUpTitle(subject: pulled.subject, store: fixture.store) ?? "")
                .fixedSize()
        }
        XCTAssertFalse(Self.fits(unbroken, in: Self.ceiling).0,
                       "control: a title that does not truncate overflows even the widest column")
    }

    // MARK: - An edition's loaded rows and heads (shell p4 Task 6)

    /// **Every row an edition's To resolve draws once it has loaded** — a
    /// change with all three verbs, a glossary
    /// proposal, a design proposal with Show, Approve and Discard, a compile
    /// problem with a long title — and both heads (a translator's letter with
    /// Run Whole Book, the Source's design head with Run and Request
    /// Changes) fit the column's floor, the default and the ceiling. Measured by proposal, not by a first frame: these draw only
    /// after the edition's read (`PulledUpFitsTheColumnTests` cannot see
    /// them in a fresh book).
    func test_anEditionsRowsAndHeadsFitTheColumn() async throws {
        let fixture = try await makeFixture()
        let docId = try XCTUnwrap(TreeWalk.collect(in: fixture.store.manifest.structure,
                                                   where: { $0.path != nil }).first?.id)
        var round = TranslationRound(number: 12, language: "es", docId: docId, startedAt: Date())
        round.endedAt = Date()
        round.summary = String(repeating: "I kept the fog where it rolls in, and softened nothing. ", count: 4)
        let departure = TranslationRound.DepartureRecord(
            id: "d1", paragraphId: "aa11", verdict: "drifted", kind: "register",
            note: "The translation is gentler than the source in the closing clause.",
            gloss: "It now says she whispered the oath instead of spitting it.", outcome: nil)
        round.departures = [departure]
        let glossary = TranslationRound.GlossaryProposalRecord(
            term: "the long grey fog over the harbour", rendering: "la larga niebla gris sobre el puerto",
            reason: "It recurs in every chapter and has been rendered three ways.", adopted: false)
        round.glossaryProposals = [glossary]
        let change = ResolveItem.translationChange(docId: docId, language: "es", round: 12, departure)
        let problem = TectonicLogParser.Diagnostic(
            level: .error, file: nil, line: nil,
            message: "A table is wider than the text block and runs into the margin.",
            contextLines: [], pieceID: docId, paragraphID: "aa11")
        let proposal = DesignProposalStore.Proposal(
            id: "prop-1", designerName: "Tschichold Who Has A Very Long Name", round: 7, language: nil,
            created: Date(), status: .pending, specMarkdown: "", filePaths: [], sampleResult: nil,
            revertNote: nil)
        var read = ResolveEditionItems.Read(language: "es", rounds: [docId: round],
                                            proposals: [proposal], problems: [problem], hasRounds: true)
        read.departureRows[change.id] = TranslationRoundReport.departureRows(
            round, sources: ["aa11": String(repeating: "A source paragraph that runs on. ", count: 6)],
            translatorName: "Lucía").first
        for row in PublishProblems.rows([problem], titles: [docId: String(repeating: "Chapter ", count: 12)]) {
            read.problemRows[ResolveItem.compileProblem(problem).id] = row
        }
        var verbs = ResolveEditionVerbs()
        verbs.authorVerbs = { _, _ in .unrestricted }
        let items = ResolveEditionItems.items(language: "es", isSource: false, docIds: [docId], read: read)
        XCTAssertEqual(items.count, 4, "premise: a change, a glossary proposal, a design proposal, a problem")
        var offenders: [String] = []
        for width in Self.paneWidths + [Self.ceiling] {
            for item in items {
                let (fits, measured) = Self.fits(
                    ResolveEditionRow(item: item, read: read, verbs: verbs), in: width)
                if !fits { offenders.append("\(item.id) → \(measured)pt in \(width)pt") }
            }
            for isSource in [false, true] {
                let head = EditionHeadView(language: isSource ? "en" : "es", isSource: isSource,
                                           docIds: [docId], store: fixture.store,
                                           documentStore: fixture.documentStore, editionRead: read,
                                           onShowRound: { _ in }, onShowProposal: { _ in })
                let (fits, measured) = Self.fits(head, in: width)
                if !fits { offenders.append("\(isSource ? "Source" : "es") head → \(measured)pt in \(width)pt") }
            }
        }
        XCTAssertEqual(offenders, [], "an edition's loaded faces are wider than the column:\n"
                       + offenders.joined(separator: "\n"))
    }

    private struct Fixture {
        let store: ProjectStore
        let documentStore: DocumentStore
        let arms: [RightColumnFixture.Arm]
        /// The app injects these at its root; the annotation and statement
        /// panes read them.
        let preferences: UserPreferences

        @MainActor
        func pane(_ arm: RightColumnFixture.Arm, paneWidth: CGFloat) -> some View {
            let control = EditorControl()
            control.translationLanguage = arm.translationLanguage
            return RightColumnFixture.pane(
                store: store, documentStore: documentStore,
                probe: RightColumnFixture.Probe(position: arm.position, subject: arm.subject),
                editorControl: control,
                width: Double(paneWidth + RightColumn.resizeHandleWidth))
                .environment(preferences)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let url = try await ProjectFactory.createNovelProject(
            named: "Width-\(UUID().uuidString.prefix(6))", in: TestTemp.root)
        let store = try await ProjectStore.load(from: url)
        let documentStore = try await DocumentStore.open(url: url)
        store.documentStore = documentStore
        let item = try XCTUnwrap(
            TreeWalk.collect(in: store.manifest.structure, where: { $0.path != nil }).first,
            "premise: the novel template has a document to open")
        let path = try XCTUnwrap(item.path)
        try "- [ ] A task with a long enough body to wrap in a narrow column.\n\nA paragraph."
            .write(to: url.appendingPathComponent(path), atomically: true, encoding: .utf8)
        let document = try await Document.load(url: url.appendingPathComponent(path),
                                               device: "macA", session: "s1", presenter: nil)
        documentStore.register(document: document, for: path)
        let part = try await store.addStructureItem(parentId: nil, title: "Part One", kind: .group)
        _ = try await store.addStructureItem(
            parentId: part.id, title: "A chapter in the Part with a long enough title to wrap",
            kind: .document(store.manifest.type.primaryFormat))
        let title = String(String(repeating: "A very long research note title ", count: 7).prefix(200))
        let note = try await store.addResearchTextNote(parentId: nil, title: title)
        for kind in [Statement.Kind.lessons, .firstReader, .visualLanguage, .intent] {
            _ = try await store.createStatement(kind: kind, scope: .project)
        }
        let suite = "RightColumnPaneWidth-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return Fixture(store: store, documentStore: documentStore,
                       arms: RightColumnFixture.arms(docId: item.id, partId: part.id, noteId: note.id),
                       preferences: UserPreferences(defaults: UserDefaults(suiteName: suite)!))
    }

    // MARK: - No list paints a fill of its own

    /// **A right-column pane's `List` hides its content background.** A
    /// `.sidebar` list paints the sidebar material and an `.inset` one its own
    /// fill; no other pane has either (#122's grey column). A grep census,
    /// narrow on purpose: the right-column panes that hold a `List`, each
    /// `.listStyle(` matched by a `.scrollContentBackground(.hidden)`.
    func test_everyRightColumnListHidesItsContentBackground() throws {
        for file in Self.rightColumnListFiles {
            let lines = try Self.codeLines(of: file)
            let styles = lines.filter { $0.contains(".listStyle(") }.count
            let hidden = lines.filter { $0.contains(".scrollContentBackground(.hidden)") }.count
            XCTAssertGreaterThan(styles, 0, "premise: \(file) styles a List")
            XCTAssertEqual(hidden, styles,
                "\(file) has \(styles) styled List(s) and \(hidden) hidden "
                + "content background(s): a list without one paints a fill the "
                + "other right-column panes do not have (#122)")
        }
    }

    /// The right-column panes that hold a `List`.
    private static let rightColumnListFiles = [
        "Maugham/Views/InboxPane.swift",
    ]

    private static func codeLines(of relativePath: String) throws -> [String] {
        let url = SourceTree.repoRoot.appendingPathComponent(relativePath)
        return SourceScan.codeLines(of: try String(contentsOf: url, encoding: .utf8))
    }
}
