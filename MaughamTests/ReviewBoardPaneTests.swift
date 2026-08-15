import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import MaughamCore
@testable import Maugham

/// **What the Review board DRAWS** (M3 P1 Task 7).
/// `ReviewBoardRoutingTests` (Task 6) is about the pane's place in the centre
/// column's stack; this file is about its contents: the chip per (piece × pass),
/// the states those chips show, the group headers, the chip-less reference row,
/// the empty project, and the two scrolling axes that are the pane's and never
/// the window's.
///
/// **Nothing here needs a project on disk**, which is itself the point. The pane
/// takes a title, a structure array and a pass list — no `ProjectStore`, no
/// `DocumentStore`, no `Document` — so the whole surface is drivable from
/// literal `StructureItem`s. That is tripwire 4 satisfied by construction rather
/// than by inspection, and `test_theSourceReadsNoStoreAtAll` is the census that
/// keeps it that way.
///
/// **How a chip is observed.** SwiftUI on this SDK backs a `Button` with no
/// `NSButton` (measured and recorded in `ProjectAltitudePaneTests` and
/// `InspectorIntentAffordanceTests`) — but each button does mount its own
/// focus-ring container as a real `NSView`, one per `ForEach` element, at the
/// frame the layout gave it. Counting those containers is the reliable
/// structural reading of "how many chips are on this board", and it holds
/// precisely because this task's rows carry no OTHER buttons: titles are plain
/// `Text` until Task 8. The accessibility tree carries the state each chip is
/// showing, and the test that reads it skips by name when no assistive client
/// can attach.
@MainActor
final class ReviewBoardPaneTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
    }

    // MARK: - Fixtures

    private static let passes = ReviewPass.presets  // four: structural, line, copyedit, proof

    private func doc(_ id: String, _ title: String, states: [String: PassState]? = nil,
                     kind: PieceKind? = nil) -> StructureItem {
        StructureItem(id: id, title: title, type: .document, path: "\(id).md",
                      pieceKind: kind, passStates: states)
    }

    private func group(_ id: String, _ title: String, _ children: [StructureItem]) -> StructureItem {
        StructureItem(id: id, title: title, type: .group, children: children)
    }

    // MARK: - The chip's own truth table (no window)

    /// **The chip's colour is the projection's, cell by cell.** Each state is
    /// asserted against the status the rest of the app would paint for a piece
    /// standing exactly there: `.done` and `.skipped` are complete (an
    /// all-skipped piece is `final`, the spec's recorded edge), `.inProgress`
    /// and an `.unknown` written by a newer build are open, and untouched is
    /// draft.
    ///
    /// Concrete expectations, not a re-derivation: this is what fails if the
    /// chip ever grows a switch of its own that disagrees with
    /// `ReviewStatus.derived`.
    func test_everyChipStateMapsToTheStatusTheRestOfTheAppWouldPaint() {
        XCTAssertEqual(ReviewBoardChip.status(for: nil), .draft,
                       "untouched is draft — nothing has been ruled on")
        XCTAssertEqual(ReviewBoardChip.status(for: .inProgress), .revising)
        XCTAssertEqual(ReviewBoardChip.status(for: .done), .final)
        XCTAssertEqual(ReviewBoardChip.status(for: .skipped), .final,
                       "a skip is an adjudication, not an omission")
        XCTAssertEqual(ReviewBoardChip.status(for: .unknown("hyphenated")), .revising,
                       "a state this build cannot read is touched-but-open — "
                       + "never promoted to complete")
    }

    /// …and those statuses reach the pixel through `StatusSwatch`, the one
    /// place a `ReviewStatus` becomes a `Color`, so the board and the tree's
    /// dots cannot drift.
    func test_theChipsColoursComeFromTheOneSwatch() {
        XCTAssertEqual(StatusSwatch.color(for: ReviewBoardChip.status(for: .done)),
                       StatusSwatch.color(for: .final))
        XCTAssertNotEqual(StatusSwatch.color(for: ReviewBoardChip.status(for: .done)),
                          StatusSwatch.color(for: ReviewBoardChip.status(for: nil)),
                          "premise: done and untouched are not the same colour, "
                          + "or the assertion above is about nothing")
    }

    /// Every state gets a glyph of its own — a board where two states look
    /// alike is a board that cannot be read.
    func test_everyStateHasItsOwnGlyph() {
        let states: [PassState?] = [nil, .inProgress, .done, .skipped, .unknown("x")]
        let symbols = states.map { ReviewBoardChip.symbol(for: $0) }

        XCTAssertEqual(Set(symbols).count, states.count,
                       "two states share a glyph: \(symbols)")
        XCTAssertFalse(symbols.contains(""), "and none of them is blank")
    }

    /// **The chip says the state in the SAME words the writer set it with** —
    /// `PassLadder`'s titles, read rather than restated, so the inspector and
    /// the board cannot call the same state two different things.
    func test_theChipSpeaksTheLaddersOwnWords() {
        XCTAssertEqual(ReviewBoardChip.stateTitle(for: nil), PassLadder.untouchedTitle)
        XCTAssertEqual(ReviewBoardChip.stateTitle(for: .inProgress), PassLadder.inProgressTitle)
        XCTAssertEqual(ReviewBoardChip.stateTitle(for: .done), PassLadder.doneTitle)
        XCTAssertEqual(ReviewBoardChip.stateTitle(for: .skipped), PassLadder.skipTitle)
        XCTAssertEqual(ReviewBoardChip.stateTitle(for: .unknown("triage")), "triage",
                       "a future build's state shows the value it actually holds")
    }

    /// A chip is a glyph in a grid, so its label has to carry the whole cell:
    /// which piece, which pass, what state.
    func test_theChipsLabelNamesThePieceThePassAndTheState() {
        let label = ReviewBoardChip.label(
            piece: "Chapter One",
            pass: ReviewPass(id: "line", name: "Line"),
            state: .done)

        for fragment in ["Chapter One", "Line", PassLadder.doneTitle] {
            XCTAssertTrue(label.contains(fragment),
                          "\u{201C}\(label)\u{201D} does not name \(fragment)")
        }
    }

    // MARK: - Mounted: one chip per (piece × pass)

    /// **The grid is a grid.** Three pieces, four passes, twelve chips — and
    /// the count is exact, so a row that quietly drew a fifth control (or
    /// skipped a pass whose state is absent) fails here.
    func test_everyPieceGetsOneChipPerPass() async throws {
        let structure = [
            doc("ch1", "Chapter One", states: ["structural": .done]),
            doc("ch2", "Chapter Two"),
            doc("ch3", "Chapter Three", states: ["line": .inProgress, "proof": .skipped]),
        ]
        let window = mount(structure: structure)

        let chips = try await chipsSettling(in: window, expecting: 3 * Self.passes.count)
        XCTAssertEqual(chips.count, 12,
                       "three pieces × four passes. A chip is drawn for an "
                       + "UNTOUCHED pass too — an absent key is a state the "
                       + "reviewer can act on, not a missing cell")
    }

    /// **Group headers are rows, not chips.** Adding two groups around the same
    /// pieces changes nothing about the chip count — the headers carry no
    /// controls of their own (Task 8's navigation is not this task's).
    func test_groupHeadersAddRowsAndNoChips() async throws {
        let flat = mount(structure: [doc("ch1", "One"), doc("ch2", "Two")])
        let flatChips = try await chipsSettling(in: flat, expecting: 2 * Self.passes.count)

        let nested = mount(structure: [
            group("p1", "Part One", [doc("ch1", "One")]),
            group("p2", "Part Two", [group("p2a", "Act I", [doc("ch2", "Two")])]),
        ])
        let nestedChips = try await chipsSettling(in: nested, expecting: 2 * Self.passes.count)

        XCTAssertEqual(nestedChips.count, flatChips.count,
                       "the same two pieces under three group headers must "
                       + "still be eight chips")
    }

    /// **A reference piece is chip-less** — its passes belong to the project it
    /// points at, and a control here would be a decision made in the wrong
    /// window. Asserted as a difference: the same board with the reference
    /// swapped for a loose piece gains a full row of chips.
    func test_aReferenceRowDrawsNoChipsAndALoosePieceInItsPlaceDoes() async throws {
        let withReference = mount(structure: [
            doc("ch1", "Chapter One"),
            doc("ref", "Another Novel", kind: .reference),
        ])
        let referenceChips = try await chipsSettling(
            in: withReference, expecting: Self.passes.count)
        XCTAssertEqual(referenceChips.count, Self.passes.count,
                       "only the loose piece's row carries chips")

        let withLoose = mount(structure: [
            doc("ch1", "Chapter One"),
            doc("ref", "Another Novel", kind: .loose),
        ])
        let looseChips = try await chipsSettling(
            in: withLoose, expecting: 2 * Self.passes.count)
        XCTAssertEqual(looseChips.count, 2 * Self.passes.count,
                       "control: the same row as a LOOSE piece does carry them, "
                       + "so the absence above is about `pieceKind` and not "
                       + "about a row that failed to mount at all")
    }

    /// **The empty project draws no chips and no grid** — the
    /// `ContentUnavailableView` arm. (That it carries tripwire 15's full frame
    /// chain is enforced for every pane under `Maugham/` by
    /// `TripwireGrepTests.test_contentUnavailableViewAlwaysChainsFullFrame`;
    /// what is asserted here is that the arm is REACHED.)
    func test_anEmptyProjectShowsNoBoardAtAll() async throws {
        let window = mount(structure: [])
        pump(0.3)

        XCTAssertTrue(chips(in: window).isEmpty, "no chips on an empty project")
        XCTAssertTrue(scrollViews(in: window).isEmpty,
                      "…and no scrolling grid either — the pane is showing the "
                      + "unavailable view, which is not a scroller")
    }

    // MARK: - Mounted: the states the chips are showing

    /// The chips publish the state they are drawing, piece and pass named, so a
    /// reviewer on VoiceOver can read the board — and so this test can check
    /// that the RIGHT cell got the right state rather than only counting them.
    ///
    /// Skips by name when no assistive client can attach: a tree that was never
    /// built is not evidence about this view (`InspectorIntentAffordanceTests`'
    /// rule).
    func test_eachChipPublishesItsOwnCellsState() async throws {
        let structure = [
            doc("ch1", "Chapter One", states: ["structural": .done, "line": .inProgress]),
            doc("ch2", "Chapter Two", states: ["proof": .skipped]),
        ]
        let window = mount(structure: structure)
        _ = try await chipsSettling(in: window, expecting: 2 * Self.passes.count)

        let labels = try axButtonLabels(in: window)
        XCTAssertFalse(labels.isEmpty,
                       "the hosted board published no buttons at all, so this "
                       + "test could not fail for the reason it exists")

        for expected in [
            "Chapter One — Structural: \(PassLadder.doneTitle)",
            "Chapter One — Line: \(PassLadder.inProgressTitle)",
            "Chapter One — Copyedit: \(PassLadder.untouchedTitle)",
            "Chapter Two — Proof: \(PassLadder.skipTitle)",
            "Chapter Two — Structural: \(PassLadder.untouchedTitle)",
        ] {
            XCTAssertTrue(labels.contains(expected),
                          "no chip published \u{201C}\(expected)\u{201D}. "
                          + "Published: \(labels.sorted())")
        }
    }

    // MARK: - Mounted: the two scrolling axes are the pane's

    /// **A wide pass set scrolls INSIDE the pane, and the pane still fits its
    /// column.** Twelve passes against a 520pt column: the grid's content is
    /// wider than the window, and the hosted view is not — which is the
    /// responsive rule (wide content scrolls in its own container; the window
    /// never scrolls horizontally).
    func test_aWidePassSetScrollsInsideThePaneAndNeverWidensTheWindow() async throws {
        let many = (1...12).map { ReviewPass(id: "p\($0)", name: "Pass \($0)") }
        let width: CGFloat = 520
        let window = mount(structure: [doc("ch1", "Chapter One")],
                           passes: many, width: width)
        _ = try await chipsSettling(in: window, expecting: many.count)

        let host = try XCTUnwrap(window.contentView)
        try XCTSkipUnless(host.bounds.width >= 400,
                          "this display mounted a \(host.bounds.size) column, "
                          + "too narrow to ask the question")

        XCTAssertGreaterThan(
            ReviewBoardPane.intrinsicWidth(passCount: many.count), host.bounds.width,
            "premise: twelve pass columns really are wider than this column")

        let widest = scrollViews(in: window)
            .compactMap { $0.documentView?.frame.width }
            .max() ?? 0
        XCTAssertGreaterThan(widest, host.bounds.width,
                             "the grid must be wider than the column and scroll "
                             + "inside it — scrollers: \(scrollViews(in: window).count)")

        for view in [host] + host.subviews {
            XCTAssertLessThanOrEqual(
                view.frame.width, host.bounds.width + 0.5,
                "the pane itself grew past the column it was given "
                + "(\(view.frame.width) > \(host.bounds.width)), which is the "
                + "window scrolling horizontally")
        }
    }

    /// A narrow pass set does not leave a gutter: the slack goes to the piece
    /// column instead, so the rows fill the pane they are given.
    func test_aNarrowPassSetHandsItsSlackToThePieceColumn() {
        let wideColumn: CGFloat = 900
        XCTAssertLessThan(ReviewBoardPane.intrinsicWidth(passCount: 4), wideColumn,
                          "premise: four passes want less than a 900pt column")
        XCTAssertEqual(
            ReviewBoardPane.intrinsicWidth(passCount: 12),
            ReviewBoardPane.minimumTitleColumnWidth + 12 * ReviewBoardPane.passColumnWidth,
            "the intrinsic width is the piece column's floor plus every pass "
            + "column — the number the pane compares its own width against")
    }

    // MARK: - Censuses

    /// **The pane reads no store** (tripwire 4, by construction). The board's
    /// body runs once per row on a project that can hold hundreds; a
    /// `ProjectStore` in scope is an invitation to a word count, a document
    /// lookup or a disk read on that path. The pane's inputs are values, and
    /// this is what says so — the mounted tests above cannot, because they
    /// would pass just as well with an unused store property.
    func test_theSourceReadsNoStoreAtAll() throws {
        let code = try Self.codeLines(of: "Views/Review/ReviewBoardPane.swift")

        for forbidden in ["ProjectStore", "DocumentStore", "Document(", "FileManager",
                          "cachedWordCount", "contentsOf"] {
            XCTAssertFalse(code.contains { $0.contains(forbidden) },
                           "`\(forbidden)` appears on the pane's path — the "
                           + "board takes values so nothing per-row can reach "
                           + "the disk (tripwire 4)")
        }
    }

    /// **The chips are `Button`s, never `.onTapGesture`** (tripwire 9's shape,
    /// and `CorkboardGrid`'s), and the board accepts no drops — a reviewer
    /// dragging a chapter onto a pass column means nothing, and a silent
    /// drop target that does nothing is worse than none.
    func test_theBoardUsesButtonsAndAcceptsNoDrops() throws {
        let code = try Self.codeLines(of: "Views/Review/ReviewBoardPane.swift")

        XCTAssertTrue(code.contains { $0.contains("buttonStyle(.plain)") },
                      "the chip must be a plain `Button`")
        for forbidden in ["onTapGesture", "dropDestination", "onDrop", "onInsert"] {
            XCTAssertFalse(code.contains { $0.contains(forbidden) },
                           "the board must not use `\(forbidden)`")
        }
    }

    /// **The container is a `ScrollView`, not a `List`** — and this is not
    /// stylistic. `ReviewBoardRoutingTests.boardScroller` identifies the board
    /// structurally as a scroll view holding NO `NSTableView`, which is what
    /// Task 6's whole routing suite reads; a `List` mounts one and every
    /// routing assertion silently starts finding a different view. If a later
    /// task genuinely wants a `List` here, that reading must be re-derived in
    /// the same commit.
    func test_theBoardIsAScrollViewAndNotAList() throws {
        let code = try Self.codeLines(of: "Views/Review/ReviewBoardPane.swift")

        XCTAssertTrue(code.contains { $0.contains("ScrollView(") })
        XCTAssertTrue(code.contains { $0.contains("LazyVStack") },
                      "rows are lazy — a long manuscript must not build every "
                      + "row view to show the first screenful")
        XCTAssertFalse(code.contains { $0.contains("List(") || $0.contains("List {") },
                       "a `List` mounts an `NSTableView` and breaks "
                       + "`ReviewBoardRoutingTests.boardScroller`")
    }

    /// The one production mount hands the pane values off `manifest` — the
    /// other half of the tripwire-4 census, since the pane's own file cannot
    /// see what is passed to it.
    func test_theProductionMountPassesManifestValues() throws {
        let code = try Self.codeLines(of: "Views/ProjectWindow.swift")

        for expected in ["title: store.manifest.title",
                         "structure: store.manifest.structure",
                         "passes: store.manifest.effectiveReviewPasses"] {
            XCTAssertTrue(code.contains { $0.contains(expected) },
                          "the mount must pass `\(expected)`")
        }
    }

    // MARK: - Hosting

    private func mount(structure: [StructureItem],
                       passes: [ReviewPass] = ReviewBoardPaneTests.passes,
                       width: CGFloat = 700) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: width, height: 600)
        let hosting = NSHostingView(rootView: AnyView(
            ReviewBoardPane(title: "The Project", structure: structure, passes: passes)
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

    // MARK: - Reading the mounted board

    /// See the class doc: a SwiftUI `Button` mounts a focus-ring container and
    /// no `NSButton`, and the chips are this task's only buttons.
    private func chips(in window: NSWindow) -> [NSView] {
        collect(NSView.self, in: window)
            .filter { String(describing: type(of: $0)).contains("FocusRingView") }
    }

    private func chipsSettling(in window: NSWindow, expecting count: Int,
                               file: StaticString = #filePath,
                               line: UInt = #line) async throws -> [NSView] {
        var found: [NSView] = []
        _ = await pumpUntil(deadline: 5) {
            found = self.chips(in: window)
            return found.count >= count
        }
        // The waits above are for the count to be REACHED; a board that draws
        // too many settles at the wrong number and the caller's exact
        // assertion is what catches it. Give a stray extra a window to appear
        // in before reading.
        pump(0.2)
        found = chips(in: window)
        XCTAssertFalse(found.isEmpty,
                       "the board mounted no chips at all", file: file, line: line)
        return found
    }

    private func scrollViews(in window: NSWindow) -> [NSScrollView] {
        collect(NSScrollView.self, in: window)
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

    // MARK: - Census helpers

    private static var appSourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
    }

    private static func codeLines(of relativePath: String) throws -> [String] {
        let url = appSourceDir.appendingPathComponent(relativePath)
        return SourceScan.codeLines(of: try String(contentsOf: url, encoding: .utf8))
    }
}
