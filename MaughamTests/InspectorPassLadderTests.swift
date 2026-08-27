import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// The Inspector's pass ladder (M3 P1 Task 4) — the control that replaced the
/// free-string draft/revising/final picker in both inspector arms.
///
/// **The menu item is performed, not the closure called.** SwiftUI's `.menu`
/// `Picker` bridges to a real `NSPopUpButton` here (measured: macOS 26.5,
/// Xcode 26 — the mounted inspector publishes one `SwiftUIPopupButton` per
/// ladder row), and each menu item carries SwiftUI's own `menuAction:` target.
/// Performing that item is the same act a click is, and it is the only route
/// that proves the binding reaches the store: `selectItem(withTitle:)` plus
/// `sendAction` was measured writing NOTHING (the popup's own target and action
/// are both nil), which is exactly the shape of a green suite over a dead
/// control.
@MainActor
final class InspectorPassLadderTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    override func setUp() async throws { temp = try TempDirectory() }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        temp = nil
    }

    // MARK: - Hosting + reading the mounted window

    private func mount(_ view: AnyView) -> NSWindow {
        let window = TestWindow.mount(view, size: CGSize(width: 420, height: 700))
        windows.append(window)
        pump()
        return window
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let match = view as? T { out.append(match) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }

    /// The ladder's popups, in mounted order.
    ///
    /// **Filtered by their own menu contents, never by index.** The inspector
    /// mounts other popups (the publishing section's page-range menu arrives
    /// asynchronously, and was measured landing at index 0 mid-test), so a
    /// positional read silently drifts onto a control this suite is not about.
    private func ladderPopups(in window: NSWindow) -> [NSPopUpButton] {
        var out: [NSPopUpButton] = []
        if let root = window.contentView { collect(NSPopUpButton.self, in: root, into: &out) }
        return out.filter { $0.itemTitles.contains(PassLadder.untouchedTitle) }
    }

    /// Perform a ladder row's menu item the way a click does.
    private func choose(_ title: String, inRow row: Int, of window: NSWindow) throws {
        let popups = ladderPopups(in: window)
        let popup = try XCTUnwrap(popups.indices.contains(row) ? popups[row] : nil,
                                  "no ladder row \(row) — the mounted inspector "
                                  + "published \(popups.count) ladder popups")
        let index = try XCTUnwrap(
            popup.menu?.items.firstIndex { $0.title == title },
            "no \u{201C}\(title)\u{201D} item in this row: \(popup.itemTitles)")
        popup.menu?.performActionForItem(at: index)
    }

    // MARK: - Fixtures

    private func collection() async throws -> (URL, ProjectStore, DocumentStore, StructureItem) {
        let url = try await ProjectFactory.createCollectionProject(
            named: "Ladder", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)
        return (url, store, ds, piece)
    }

    private func novel() async throws -> (URL, ProjectStore, DocumentStore, StructureItem) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Ladder", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (url, store, ds, store.manifest.structure[0])
    }

    private func states(of id: String, in store: ProjectStore) -> [String: PassState]? {
        store.manifest.structure.first { $0.id == id }?.passStates
    }

    // MARK: - The ladder is the project's pass list

    /// One row per `effectiveReviewPasses` entry, each offering the four
    /// choices — and the row count follows a CUSTOMIZED list, which is what
    /// separates "the ladder reads the manifest" from "the ladder hardcodes the
    /// four presets and happens to agree with them".
    func test_theLadderIsOneRowPerEffectivePass_includingACustomizedList() async throws {
        let (_, store, ds, piece) = try await collection()
        defer { Task { await ds.close() } }

        let presets = mount(AnyView(PieceInspector(
            store: store, pieceId: piece.id, kind: .prose)))
        XCTAssertEqual(ladderPopups(in: presets).count, ReviewPass.presets.count,
                       "an uncustomized project shows one row per preset pass")
        for popup in ladderPopups(in: presets) {
            XCTAssertEqual(popup.itemTitles,
                           [PassLadder.untouchedTitle, PassLadder.inProgressTitle,
                            PassLadder.doneTitle, PassLadder.skipTitle])
            XCTAssertEqual(popup.title, PassLadder.untouchedTitle,
                           "a piece nobody has ruled on shows every pass untouched")
        }

        store.manifest.reviewPasses = [
            ReviewPass(id: "structural", name: "Structural"),
            ReviewPass(id: "read-aloud", name: "Read Aloud"),
        ]
        let custom = mount(AnyView(PieceInspector(
            store: store, pieceId: piece.id, kind: .prose)))
        XCTAssertEqual(ladderPopups(in: custom).count, 2,
                       "the ladder must be the project's own pass list, not the presets")
    }

    // MARK: - Choosing a state (the delivery path)

    /// Contract: setting a state from the inspector persists through a manifest
    /// round-trip. Driven through the Collection arm's ladder.
    func test_choosingDoneInThePieceInspectorPersistsThroughAManifestRoundTrip() async throws {
        let (url, store, ds, piece) = try await collection()
        defer { Task { await ds.close() } }
        let window = mount(AnyView(PieceInspector(
            store: store, pieceId: piece.id, kind: .prose)))

        try choose(PassLadder.doneTitle, inRow: 0, of: window)
        await pumpUntil(deadline: 5) { self.states(of: piece.id, in: store) != nil }

        let firstPassId = try XCTUnwrap(store.manifest.effectiveReviewPasses.first?.id)
        XCTAssertEqual(states(of: piece.id, in: store)?[firstPassId], .done)

        let reloaded = try await ProjectStore.load(from: url)
        let onDisk = try XCTUnwrap(reloaded.manifest.structure.first { $0.id == piece.id })
        XCTAssertEqual(onDisk.passStates?[firstPassId], .done,
                       "the ladder's write did not survive a manifest round-trip")
        XCTAssertNil(onDisk.status,
                     "the ladder must not write the legacy status string — it has "
                     + "no writers as of this task, and a second stored answer "
                     + "beside the derived one is what Task 3's projection replaced")
    }

    /// Choosing "Untouched" REMOVES the state — the nil arm of the store verb,
    /// reached through the control rather than through the verb directly.
    func test_choosingUntouchedClearsThePassFromTheMountedLadder() async throws {
        let (_, store, ds, piece) = try await collection()
        defer { Task { await ds.close() } }
        let window = mount(AnyView(PieceInspector(
            store: store, pieceId: piece.id, kind: .prose)))

        try choose(PassLadder.doneTitle, inRow: 0, of: window)
        await pumpUntil(deadline: 5) { self.states(of: piece.id, in: store) != nil }
        try choose(PassLadder.untouchedTitle, inRow: 0, of: window)
        await pumpUntil(deadline: 5) { self.states(of: piece.id, in: store) == nil }

        XCTAssertNil(states(of: piece.id, in: store),
                     "clearing the only touched pass leaves no map at all — not "
                     + "an empty one, and not a stored fourth state")
    }

    // MARK: - The document arm

    /// The ladder really is in the document inspector's Form, and it really is
    /// bound to `PassState`.
    ///
    /// **Identified by the picker coordinator's own generic type, because this
    /// Form's popups are empty until opened.** Measured (macOS 26.5): a
    /// `.menu` `Picker` inside `Form(.grouped)` publishes an
    /// `NSPopUpButton` whose `NSMenu` has ZERO items at mount, and stays empty
    /// through `menu.update()`, through the delegate's `menuNeedsUpdate`,
    /// through a 2000pt-tall window and through a second of pumping — the menu
    /// is built when the writer opens it. (`PieceInspector`'s plain `VStack`
    /// arm populates at mount, which is why the delivery-path drive above lives
    /// there.) What survives that is the delegate: SwiftUI's coordinator is
    /// generic over the picker's selection type, so its type name naming
    /// `MaughamCore.PassState` is evidence a `PassState?`-bound picker is
    /// mounted here — a `String`-bound status picker would not match.
    func test_theDocumentInspectorMountsAPassBoundLadderPerEffectivePass() async throws {
        let (_, store, ds, item) = try await novel()
        defer { Task { await ds.close() } }

        let window = mount(AnyView(InspectorView(
            store: store,
            selectedItemId: item.id,
            metrics: EditorMetrics(wordCount: 0, characterCount: 0, readingMinutes: 0),
            onOpenProjectSettings: {})))

        var popups: [NSPopUpButton] = []
        collect(NSPopUpButton.self, in: try XCTUnwrap(window.contentView), into: &popups)
        let passBound = popups.filter {
            String(describing: $0.menu?.delegate).contains("PassState")
        }
        XCTAssertEqual(passBound.count, store.manifest.effectiveReviewPasses.count,
                       "the document inspector published \(popups.count) popups, "
                       + "\(passBound.count) of them bound to PassState — the "
                       + "ladder is not mounted here, or is bound to something else")
    }

    /// …and the write it performs is the store verb, not the debounced draft.
    ///
    /// **The discriminator is not a stopwatch.** `scheduleSave()` writes the
    /// whole DRAFT back 500 ms later, so a ladder riding it would carry that
    /// draft's synopsis along — here the stored synopsis is moved on to
    /// "Second" while this instance's draft holds nothing, and the assertion
    /// waits out more than the debounce window before reading. A scheduled save
    /// would have landed inside it and clobbered the synopsis; the ladder's
    /// write must land and leave it alone.
    func test_theDocumentInspectorLadderWritesTheVerbAndNotTheDebouncedDraft() async throws {
        let (_, store, ds, item) = try await novel()
        defer { Task { await ds.close() } }
        try await store.updateInspector(id: item.id, synopsis: "First")

        let view = InspectorView(
            store: store,
            selectedItemId: item.id,
            metrics: EditorMetrics(wordCount: 0, characterCount: 0, readingMinutes: 0),
            onOpenProjectSettings: {})
        // Something else — another window, an MCP call, a rename sweep — moves
        // the stored synopsis on behind any draft.
        try await store.updateInspector(id: item.id, synopsis: "Second")

        let firstPassId = try XCTUnwrap(store.manifest.effectiveReviewPasses.first?.id)
        view.setPass(firstPassId, to: .done, on: item.id)
        await pumpUntil(deadline: 5) { self.states(of: item.id, in: store) != nil }
        XCTAssertEqual(states(of: item.id, in: store)?[firstPassId], .done)

        await waitOut(1.2)
        XCTAssertEqual(store.manifest.structure.first { $0.id == item.id }?.synopsis,
                       "Second",
                       "the ladder wrote through the debounced whole-draft save, "
                       + "which reverted a synopsis it had no business touching")
        XCTAssertNil(store.manifest.structure.first { $0.id == item.id }?.status,
                     "and it must not have written the legacy status string")
    }

    // MARK: - The projection is live

    /// A state set ANYWHERE — Task 8's board, Claude, another window — shows in
    /// the mounted ladder with no reload.
    ///
    /// **This is the milestone's live-projection assertion, and it is made on
    /// the popups because they are the only status surface whose rendered value
    /// is observable here.** Measured while writing this suite (macOS 26.5):
    /// `OutlineTable`'s Status column publishes no `NSTextField` at all — its
    /// cells are `TableCellHostingView<…Text…>` — and the table's whole
    /// accessibility tree comes back as 13 unlabelled nodes with no values, so
    /// a "the swatch says Final now" assertion there could only ever have been
    /// vacuous. What that column READS is pinned by source census instead
    /// (`PersonaPaneRegistryTests.test_theStatusStringHasNoProductionWriters`
    /// and its outline arm).
    func test_aPassStateSetElsewhereReachesTheMountedLadderWithNoReload() async throws {
        let (_, store, ds, piece) = try await collection()
        defer { Task { await ds.close() } }
        let window = mount(AnyView(PieceInspector(
            store: store, pieceId: piece.id, kind: .prose)))
        XCTAssertEqual(ladderPopups(in: window).map(\.title),
                       Array(repeating: PassLadder.untouchedTitle,
                             count: ReviewPass.presets.count),
                       "premise: nothing is ruled on yet")

        let secondPass = try XCTUnwrap(store.manifest.effectiveReviewPasses.dropFirst().first)
        try await store.setPassState(id: piece.id, passId: secondPass.id, .skipped)
        await pumpUntil(deadline: 5) {
            self.ladderPopups(in: window).map(\.title).contains(PassLadder.skipTitle)
        }

        XCTAssertEqual(ladderPopups(in: window).map(\.title)[1], PassLadder.skipTitle,
                       "the row for the pass that changed did not follow the store")
    }

    /// A state this build cannot interpret gets a row of its own and is not
    /// silently coerced to one of the four. Without it the popup shows blank (no
    /// tag matches) and the writer's next choice looks like a correction of
    /// nothing — while `PassState` goes on promising the value round-trips.
    func test_aNewerBuildsStateIsShownRatherThanSilentlyBlank() async throws {
        let (_, store, ds, piece) = try await collection()
        defer { Task { await ds.close() } }
        let firstPassId = try XCTUnwrap(store.manifest.effectiveReviewPasses.first?.id)
        try await store.setPassState(
            id: piece.id, passId: firstPassId, .unknown("awaiting_reader"))

        let window = mount(AnyView(PieceInspector(
            store: store, pieceId: piece.id, kind: .prose)))
        let row = try XCTUnwrap(ladderPopups(in: window).first)
        XCTAssertEqual(row.title, "awaiting_reader",
                       "the unknown state must be shown as itself")

        // …and the writer can still rule on it, which overwrites deliberately.
        try choose(PassLadder.doneTitle, inRow: 0, of: window)
        await pumpUntil(deadline: 5) {
            self.states(of: piece.id, in: store)?[firstPassId] == .done
        }
        XCTAssertEqual(states(of: piece.id, in: store)?[firstPassId], .done)
    }

    // MARK: - The dot's presence rule (Task 3 carry)

    /// `PieceRow` draws no dot for an UNTOUCHED piece, and the question is asked
    /// of the same two records the projection reads.
    ///
    /// The carry from Task 3's review: the old guard read the raw legacy string,
    /// so a piece ruled on entirely through the ladder — every piece from this
    /// task on — would derive a real status and draw nothing at all.
    func test_theDotAppearsWhenAPieceIsTouchedByEitherRecord() {
        XCTAssertFalse(StatusSwatch.showsDot(passStates: nil, legacyStatus: nil),
                       "an untouched piece draws no dot — a column of identical "
                       + "gray dots is what the old guard existed to prevent")
        XCTAssertFalse(StatusSwatch.showsDot(passStates: [:], legacyStatus: ""),
                       "an emptied record is untouched too")
        XCTAssertTrue(
            StatusSwatch.showsDot(passStates: ["structural": .done], legacyStatus: nil),
            "a piece ruled on through the ladder MUST draw its dot — this is the "
            + "case the raw-string guard got wrong")
        XCTAssertTrue(
            StatusSwatch.showsDot(passStates: nil, legacyStatus: "revising"),
            "a project written by an older build still has only the legacy string")
        XCTAssertTrue(
            StatusSwatch.showsDot(passStates: ["structural": .inProgress],
                                  legacyStatus: "draft"),
            "and both records together are still one dot")
    }

    /// The rule is TOUCHED, not "derived status is not draft". The tempting
    /// one-liner would hide a real dot: `.draft` is reachable WITH a record
    /// present, and a piece the writer has ruled on has something to say even
    /// when the verdict is still draft.
    func test_theDotRuleIsNotDerivedStatusInDisguise() {
        // A touched piece whose projection is still `.draft`: the legacy
        // string is what a pre-M3 project carries, and "draft" is its
        // commonest value — `showsDot` says yes where `!= .draft` would say no.
        XCTAssertEqual(
            ReviewStatus.derived(passStates: nil, passes: ReviewPass.presets,
                                 legacyStatus: "draft"),
            .draft,
            "premise")
        XCTAssertTrue(StatusSwatch.showsDot(passStates: nil, legacyStatus: "draft"),
                      "a writer who set draft said something; the untouched piece "
                      + "beside it did not, and the two must not draw the same")
        // The control: with nothing recorded the two questions agree.
        XCTAssertEqual(
            ReviewStatus.derived(passStates: nil, passes: ReviewPass.presets,
                                 legacyStatus: nil),
            .draft)
        XCTAssertFalse(StatusSwatch.showsDot(passStates: nil, legacyStatus: nil))
    }
}
