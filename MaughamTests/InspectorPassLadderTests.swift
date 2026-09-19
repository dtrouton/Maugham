import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// The Inspector's pass ladder (M3 P1 Task 4) — the control that replaced the
/// free-string draft/revising/final picker in both inspector arms.
///
/// **The control is READ, and the write is pinned where it is made** (macOS 27
/// shell slice, Task 4).
///
/// This suite used to perform the popup's own menu item, on the argument that
/// it was the only route proving the binding reaches the store —
/// `selectItem(withTitle:)` plus `sendAction` had been measured writing
/// nothing, since the popup's target and action are both nil. That argument
/// died with its premise. On macOS 27 a SwiftUI `Picker(.menu)` mounts **no
/// AppKit control at all**: the whole view-hierarchy trace is a `KeyViewProxy`
/// and a `_FocusRingView`, the inspector publishes zero `NSPopUpButton`, and
/// the `AccessibilityNode` that replaces it has an empty
/// `accessibilityActionNames`, no children and no `NSMenu`. There is no
/// mounted delivery path left to drive.
///
/// So the suite is in two halves, and neither presses anything:
///
/// - **What a choice MEANS** is asserted at the host that performs it —
///   `PieceInspector.setPass` / `InspectorView.setPass`, the two files
///   `PersonaPaneRegistryTests`' `setPassState` census names — with no window
///   between the call and the answer.
/// - **That the control is DRAWN, and what it reads**, goes through
///   `axMenuControl(_:in:)` and nothing else. Each row is found by the
///   identifier `PassLadder.identifier(forPass:)` mints, never by position:
///   the row's own label is a separate sibling node, and the inspector
///   publishes a fifth `AXPopUpButton` that is not a ladder row (Publishing's
///   *Start on*) — which is the drift this suite already recorded once, when
///   the page-range menu was measured arriving at index 0 mid-test.
///
/// The measurements are in
/// `docs/superpowers/notes/2026-09-19-split-view-tie-break-spike.md`'s *The
/// accessibility tree on 27*.
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

    /// One ladder row, by the pass it is for — the only way this suite names a
    /// row.
    private func ladderRow(_ passId: String,
                           in window: NSWindow) throws -> AXMenuControl? {
        try axMenuControl(PassLadder.identifier(forPass: passId), in: window)
    }

    /// The ladder row for `passId`, or a failure naming what the surface DID
    /// publish.
    private func requireLadderRow(_ passId: String,
                                  in window: NSWindow) throws -> AXMenuControl {
        let row = try ladderRow(passId, in: window)
        let published = try axIdentifiers(in: window)
        return try XCTUnwrap(
            row,
            "the mounted inspector published no ladder row for \u{201C}\(passId)\u{201D}. "
            + "Identifiers on the surface: \(published)")
    }

    /// What each effective pass's row currently reads, in the project's own
    /// pass order — `nil` for a pass with no row at all.
    private func ladderReadings(in window: NSWindow,
                                of store: ProjectStore) throws -> [String?] {
        try store.manifest.effectiveReviewPasses.map {
            try ladderRow($0.id, in: window)?.reading
        }
    }

    /// What one row reads, for a poll predicate — which cannot throw, and
    /// should not have to unwrap two layers of optional to ask a question about
    /// a string. An unreadable tree and an absent row are the same answer here:
    /// not yet.
    private func ladderReading(_ passId: String, in window: NSWindow) -> String? {
        ((try? ladderRow(passId, in: window)) ?? nil)?.reading
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
        for pass in ReviewPass.presets {
            let row = try requireLadderRow(pass.id, in: presets)
            XCTAssertEqual(row.role, "AXPopUpButton",
                           "\(pass.id)'s row is published as \(row.role ?? "nothing") "
                           + "— the ladder row must be a pop-up button")
            XCTAssertEqual(row.reading, PassLadder.untouchedTitle,
                           "a piece nobody has ruled on shows every pass untouched")
            XCTAssertEqual(row.isEnabled, true, "and every row is rulable")
        }

        store.manifest.reviewPasses = [
            ReviewPass(id: "structural", name: "Structural"),
            ReviewPass(id: "read-aloud", name: "Read Aloud"),
        ]
        let custom = mount(AnyView(PieceInspector(
            store: store, pieceId: piece.id, kind: .prose)))
        _ = try requireLadderRow("read-aloud", in: custom)
        let droppedPreset = try ladderRow("line", in: custom)
        let published = try axIdentifiers(in: custom)
        XCTAssertNil(
            droppedPreset,
            "the ladder must be the project's own pass list, not the presets — "
            + "a preset the customized list drops still has a row. Identifiers: "
            + "\(published)")
    }

    // MARK: - Choosing a state (the delivery path)

    /// Contract: setting a state from the Collection arm persists through a
    /// manifest round-trip.
    ///
    /// **Asserted at `PieceInspector.setPass`, which is where the write is
    /// made**, rather than through the mounted row — the row publishes no menu,
    /// no children and no press action on 27, so there is nothing to choose
    /// from. The window is still here because the claim is about *the
    /// inspector's* write reaching disk, and the same mount also witnesses that
    /// the row this write is about is on screen.
    func test_choosingDoneInThePieceInspectorPersistsThroughAManifestRoundTrip() async throws {
        let (url, store, ds, piece) = try await collection()
        defer { Task { await ds.close() } }
        let inspector = PieceInspector(store: store, pieceId: piece.id, kind: .prose)
        let window = mount(AnyView(inspector))
        let firstPassId = try XCTUnwrap(store.manifest.effectiveReviewPasses.first?.id)
        _ = try requireLadderRow(firstPassId, in: window)

        inspector.setPass(firstPassId, to: .done, on: piece.id)
        await pumpUntil(deadline: 5) { self.states(of: piece.id, in: store) != nil }
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
    /// reached through the inspector's own write rather than the store's.
    func test_choosingUntouchedClearsThePassFromTheMountedLadder() async throws {
        let (_, store, ds, piece) = try await collection()
        defer { Task { await ds.close() } }
        let inspector = PieceInspector(store: store, pieceId: piece.id, kind: .prose)
        let window = mount(AnyView(inspector))
        let firstPassId = try XCTUnwrap(store.manifest.effectiveReviewPasses.first?.id)

        inspector.setPass(firstPassId, to: .done, on: piece.id)
        await pumpUntil(deadline: 5) { self.states(of: piece.id, in: store) != nil }
        // The row follows the store on its way through, which is the same live
        // projection `aPassStateSetElsewhere…` is about — read here because the
        // mount is already standing.
        await pumpUntil(deadline: 5) {
            self.ladderReading(firstPassId, in: window) == PassLadder.doneTitle
        }
        XCTAssertEqual(try requireLadderRow(firstPassId, in: window).reading,
                       PassLadder.doneTitle)

        inspector.setPass(firstPassId, to: nil, on: piece.id)
        await pumpUntil(deadline: 5) { self.states(of: piece.id, in: store) == nil }

        XCTAssertNil(states(of: piece.id, in: store),
                     "clearing the only touched pass leaves no map at all — not "
                     + "an empty one, and not a stored fourth state")
    }

    // MARK: - The document arm

    /// The ladder really is in the document inspector's Form, and it really is
    /// bound to `PassState`.
    ///
    /// **Identified by the row's own identifier, and read for a `PassState`
    /// title.** The old spelling asked the picker coordinator's generic type
    /// name whether it mentioned `MaughamCore.PassState`, because this Form's
    /// `NSPopUpButton`s were empty until the writer opened them and the
    /// delegate was the only thing that survived that. There is no
    /// `NSPopUpButton` here at all any more, and the replacement is better
    /// evidence rather than a substitute for it: a row identified as *this
    /// pass* that reads back one of `PassState`'s own titles is bound to a
    /// `PassState?`, where a `String`-bound status picker would read "Draft".
    func test_theDocumentInspectorMountsAPassBoundLadderPerEffectivePass() async throws {
        let (_, store, ds, item) = try await novel()
        defer { Task { await ds.close() } }

        let window = mount(AnyView(InspectorView(
            store: store,
            selectedItemId: item.id,
            metrics: EditorMetrics(wordCount: 0, characterCount: 0, readingMinutes: 0),
            onOpenProjectSettings: {})))

        for pass in store.manifest.effectiveReviewPasses {
            let row = try requireLadderRow(pass.id, in: window)
            XCTAssertEqual(row.role, "AXPopUpButton")
            XCTAssertEqual(
                row.reading, PassLadder.untouchedTitle,
                "\(pass.id)'s row reads \u{201C}\(row.reading ?? "nothing")\u{201D} — "
                + "the ladder is bound to something that is not a `PassState?`, "
                + "which is what the legacy status string would look like here")
        }
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
    /// the ladder because it is the only status surface whose rendered value is
    /// observable here.** Measured while writing this suite (macOS 26.5):
    /// `OutlineTable`'s Status column publishes no `NSTextField` at all — its
    /// cells are `TableCellHostingView<…Text…>` — and the table's whole
    /// accessibility tree comes back as 13 unlabelled nodes with no values, so
    /// a "the swatch says Final now" assertion there could only ever have been
    /// vacuous. What that column READS is pinned by source census instead
    /// (`PersonaPaneRegistryTests.test_theStatusStringHasNoProductionWriters`
    /// and its outline arm).
    ///
    /// **The poll here is not a control's effect** (tripwire 33): nothing on
    /// this surface was pressed, and what is being waited for is a store change
    /// made elsewhere reaching a mounted view — which is the entire claim.
    ///
    /// It also used to be the suite's crash. `ladderPopups(…).map(\.title)[1]`
    /// subscripted an array that `NSPopUpButton`'s disappearance had emptied,
    /// so a premise failure became a trap; reading each row BY ITS PASS means
    /// there is no index to be out of.
    func test_aPassStateSetElsewhereReachesTheMountedLadderWithNoReload() async throws {
        let (_, store, ds, piece) = try await collection()
        defer { Task { await ds.close() } }
        let window = mount(AnyView(PieceInspector(
            store: store, pieceId: piece.id, kind: .prose)))
        XCTAssertEqual(try ladderReadings(in: window, of: store),
                       Array(repeating: PassLadder.untouchedTitle,
                             count: ReviewPass.presets.count),
                       "premise: nothing is ruled on yet")

        let secondPass = try XCTUnwrap(store.manifest.effectiveReviewPasses.dropFirst().first)
        try await store.setPassState(id: piece.id, passId: secondPass.id, .skipped)
        await pumpUntil(deadline: 5) {
            self.ladderReading(secondPass.id, in: window) == PassLadder.skipTitle
        }

        XCTAssertEqual(try requireLadderRow(secondPass.id, in: window).reading,
                       PassLadder.skipTitle,
                       "the row for the pass that changed did not follow the store")
        let first = try XCTUnwrap(store.manifest.effectiveReviewPasses.first)
        XCTAssertEqual(try requireLadderRow(first.id, in: window).reading,
                       PassLadder.untouchedTitle,
                       "and no other row moved with it")
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

        let inspector = PieceInspector(store: store, pieceId: piece.id, kind: .prose)
        let window = mount(AnyView(inspector))
        XCTAssertEqual(try requireLadderRow(firstPassId, in: window).reading,
                       "awaiting_reader",
                       "the unknown state must be shown as itself")

        // …and the writer can still rule on it, which overwrites deliberately.
        inspector.setPass(firstPassId, to: .done, on: piece.id)
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
