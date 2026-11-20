import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// The pass ladder (M3 P1 Task 4) — where a writer says where a piece stands
/// on a pass — in its one host: To resolve's head, in the right column
/// (shell plan 2; the two inspector panes that also hosted it were deleted in
/// shell plan 3 Task 9, and this suite was theirs).
///
/// **The control is READ, and the write is pinned where it is made** (macOS 27
/// shell slice, Task 4). On macOS 27 a SwiftUI `Picker(.menu)` mounts no
/// AppKit control at all, and the `AccessibilityNode` that replaces it has an
/// empty `accessibilityActionNames`, no children and no `NSMenu`: there is no
/// mounted delivery path to drive. So the suite is in two halves, and neither
/// presses anything (tripwire 33):
///
/// - **What a choice MEANS** is asserted at the host that performs it —
///   `RightColumn.setPassState`, the write `PassStateWriterCensusTests` names
///   — with no window between the call and the answer.
/// - **That the control is DRAWN, and what it reads**, goes through
///   `axMenuControl(_:in:)` and nothing else. Each row is found by the
///   identifier `PassLadder.identifier(forPass:)` mints, never by position.
///
/// The mount is the real `RightColumn` on To resolve over a piece
/// (`RightColumnFixture`), so the ladder is read where the writer meets it.
@MainActor
final class PassLadderTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    override func setUp() async throws { temp = try TempDirectory() }

    override func tearDown() async throws {
        PieceWriterFixture.reset()
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        temp = nil
    }

    // MARK: - Hosting + reading the mounted window

    /// The right column on To resolve over `piece`.
    private func column(_ store: ProjectStore, _ documentStore: DocumentStore,
                        piece: String) -> RightColumn {
        RightColumnFixture.column(
            store: store, documentStore: documentStore,
            probe: RightColumnFixture.Probe(
                position: .resolve,
                subject: WindowSubject(open: .item(piece), faces: .item(piece))),
            width: 420)
    }

    private func mount(_ column: RightColumn) -> NSWindow {
        let suite = "PassLadder-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let window = TestWindow.mount(
            AnyView(RightColumnFixture.Pane { column }
                .environment(UserPreferences(defaults: UserDefaults(suiteName: suite)!))),
            size: CGSize(width: 420, height: 700))
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
    /// publish. A bounded poll first: To resolve reads its list in a `.task`.
    private func requireLadderRow(_ passId: String,
                                  in window: NSWindow) async throws -> AXMenuControl {
        _ = await pumpUntil(deadline: 5) {
            ((try? self.ladderRow(passId, in: window)) ?? nil) != nil
        }
        let row = try ladderRow(passId, in: window)
        let published = try axIdentifiers(in: window)
        return try XCTUnwrap(
            row,
            "the mounted column published no ladder row for \u{201C}\(passId)\u{201D}. "
            + "Identifiers on the surface: \(published)")
    }

    /// What one row reads, for a poll predicate — which cannot throw. An
    /// unreadable tree and an absent row are the same answer here: not yet.
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
        let piece = try await store.addLoosePiece(title: "Story A", format: .markdown)
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

    /// One row per `effectiveReviewPasses` entry — and the row count follows a
    /// CUSTOMIZED list, which is what separates "the ladder reads the
    /// manifest" from "the ladder hardcodes the four presets and happens to
    /// agree with them". A Collection's loose piece and a novel's chapter
    /// draw the same ladder: there is one host now.
    func test_theLadderIsOneRowPerEffectivePass_includingACustomizedList() async throws {
        try requireAssistiveClient()
        let (_, store, ds, piece) = try await collection()
        defer { Task { await ds.close() } }

        let presets = mount(column(store, ds, piece: piece.id))
        for pass in ReviewPass.presets {
            let row = try await requireLadderRow(pass.id, in: presets)
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
        let custom = mount(column(store, ds, piece: piece.id))
        _ = try await requireLadderRow("read-aloud", in: custom)
        let droppedPreset = try ladderRow("line", in: custom)
        let published = try axIdentifiers(in: custom)
        XCTAssertNil(
            droppedPreset,
            "the ladder must be the project's own pass list, not the presets — "
            + "a preset the customized list drops still has a row. Identifiers: "
            + "\(published)")
    }

    /// The same ladder over a novel's chapter, bound to `PassState`: a row
    /// identified as *this pass* that reads back one of `PassState`'s own
    /// titles is bound to a `PassState?`, where a `String`-bound status picker
    /// would read "Draft".
    func test_aChapterMountsAPassBoundLadderPerEffectivePass() async throws {
        try requireAssistiveClient()
        let (_, store, ds, item) = try await novel()
        defer { Task { await ds.close() } }

        let window = mount(column(store, ds, piece: item.id))
        for pass in store.manifest.effectiveReviewPasses {
            let row = try await requireLadderRow(pass.id, in: window)
            XCTAssertEqual(row.role, "AXPopUpButton")
            XCTAssertEqual(
                row.reading, PassLadder.untouchedTitle,
                "\(pass.id)'s row reads \u{201C}\(row.reading ?? "nothing")\u{201D} — "
                + "the ladder is bound to something that is not a `PassState?`, "
                + "which is what the legacy status string would look like here")
        }
    }

    // MARK: - Choosing a state (the delivery path)

    /// Contract: setting a state persists through a manifest round-trip.
    ///
    /// **Asserted at `RightColumn.setPassState`, which is where the write is
    /// made**, rather than through the mounted row — the row publishes no
    /// menu, no children and no press action on 27, so there is nothing to
    /// choose from. The window is still here because the claim is about *the
    /// column's* write reaching disk, and the same mount also witnesses that
    /// the row this write is about is on screen.
    func test_choosingDonePersistsThroughAManifestRoundTrip() async throws {
        try requireAssistiveClient()
        let (url, store, ds, piece) = try await collection()
        defer { Task { await ds.close() } }
        let host = column(store, ds, piece: piece.id)
        let window = mount(host)
        let firstPassId = try XCTUnwrap(store.manifest.effectiveReviewPasses.first?.id)
        _ = try await requireLadderRow(firstPassId, in: window)

        host.setPassState(piece.id, firstPassId, .done)
        await pumpUntil(deadline: 5) { self.states(of: piece.id, in: store) != nil }
        XCTAssertEqual(states(of: piece.id, in: store)?[firstPassId], .done)

        let reloaded = try await ProjectStore.load(from: url)
        let onDisk = try XCTUnwrap(reloaded.manifest.structure.first { $0.id == piece.id })
        XCTAssertEqual(onDisk.passStates?[firstPassId], .done,
                       "the ladder's write did not survive a manifest round-trip")
        XCTAssertNil(onDisk.status,
                     "the ladder must not write the legacy status string — it has "
                     + "no writers, and a second stored answer beside the derived "
                     + "one is what the projection replaced")
    }

    /// Choosing "Untouched" REMOVES the state — the nil arm of the store verb,
    /// reached through the column's own write rather than the store's.
    func test_choosingUntouchedClearsThePassFromTheMountedLadder() async throws {
        try requireAssistiveClient()
        let (_, store, ds, piece) = try await collection()
        defer { Task { await ds.close() } }
        let host = column(store, ds, piece: piece.id)
        let window = mount(host)
        let firstPassId = try XCTUnwrap(store.manifest.effectiveReviewPasses.first?.id)

        host.setPassState(piece.id, firstPassId, .done)
        await pumpUntil(deadline: 5) { self.states(of: piece.id, in: store) != nil }
        // The row follows the store on its way through, which is the same live
        // projection `aPassStateSetElsewhere…` is about — read here because the
        // mount is already standing.
        await pumpUntil(deadline: 5) {
            self.ladderReading(firstPassId, in: window) == PassLadder.doneTitle
        }
        let reading1 = try await requireLadderRow(firstPassId, in: window).reading
        XCTAssertEqual(reading1,
                       PassLadder.doneTitle)

        host.setPassState(piece.id, firstPassId, nil)
        await pumpUntil(deadline: 5) { self.states(of: piece.id, in: store) == nil }

        XCTAssertNil(states(of: piece.id, in: store),
                     "clearing the only touched pass leaves no map at all — not "
                     + "an empty one, and not a stored fourth state")
    }

    /// **The write is the store verb and nothing else**: it moves one pass
    /// state and leaves every other field of the piece as stored. (The old
    /// document inspector kept a debounced whole-draft save, which this pinned
    /// the ladder against riding; the ladder's host holds no draft now, and
    /// what stays pinned is that its write is not a whole-item write.)
    func test_theLadderWriteMovesThePassStateAndNothingElse() async throws {
        let (_, store, ds, item) = try await novel()
        defer { Task { await ds.close() } }
        try await store.updateInspector(id: item.id, synopsis: "The line as stored")
        let host = column(store, ds, piece: item.id)

        let firstPassId = try XCTUnwrap(store.manifest.effectiveReviewPasses.first?.id)
        host.setPassState(item.id, firstPassId, .done)
        await pumpUntil(deadline: 5) { self.states(of: item.id, in: store) != nil }
        XCTAssertEqual(states(of: item.id, in: store)?[firstPassId], .done)

        let stored = try XCTUnwrap(store.manifest.structure.first { $0.id == item.id })
        XCTAssertEqual(stored.synopsis, "The line as stored",
                       "the ladder's write touched a field it had no business touching")
        XCTAssertNil(stored.status, "and it must not have written the legacy status string")
        let write = try SourceTree.declaration(named: "func setPassState(_ pieceId: String,",
                                               under: "Maugham/Views")
        XCTAssertTrue(write.contains("store.setPassState(id: pieceId, passId: passId, state)"), write)
        XCTAssertFalse(write.contains("updateInspector("), "never a whole-item write")
    }

    // MARK: - The projection is live

    /// A state set ANYWHERE — the board, Claude, another window — shows in the
    /// mounted ladder with no reload.
    ///
    /// **This is the live-projection assertion, and it is made on the ladder
    /// because it is the only status surface whose rendered value is
    /// observable here.**
    ///
    /// **The poll here is not a control's effect** (tripwire 33): nothing on
    /// this surface was pressed, and what is being waited for is a store change
    /// made elsewhere reaching a mounted view — which is the entire claim.
    func test_aPassStateSetElsewhereReachesTheMountedLadderWithNoReload() async throws {
        try requireAssistiveClient()
        let (_, store, ds, piece) = try await collection()
        defer { Task { await ds.close() } }
        let window = mount(column(store, ds, piece: piece.id))
        for pass in store.manifest.effectiveReviewPasses {
            let reading2 = try await requireLadderRow(pass.id, in: window).reading
            XCTAssertEqual(reading2,
                           PassLadder.untouchedTitle, "premise: nothing is ruled on yet")
        }

        let secondPass = try XCTUnwrap(store.manifest.effectiveReviewPasses.dropFirst().first)
        try await store.setPassState(id: piece.id, passId: secondPass.id, .skipped)
        await pumpUntil(deadline: 5) {
            self.ladderReading(secondPass.id, in: window) == PassLadder.skipTitle
        }

        let reading3 = try await requireLadderRow(secondPass.id, in: window).reading
        XCTAssertEqual(reading3,
                       PassLadder.skipTitle,
                       "the row for the pass that changed did not follow the store")
        let first = try XCTUnwrap(store.manifest.effectiveReviewPasses.first)
        let reading4 = try await requireLadderRow(first.id, in: window).reading
        XCTAssertEqual(reading4,
                       PassLadder.untouchedTitle,
                       "and no other row moved with it")
    }

    /// A state this build cannot interpret gets a row of its own and is not
    /// silently coerced to one of the four. Without it the popup shows blank (no
    /// tag matches) and the writer's next choice looks like a correction of
    /// nothing — while `PassState` goes on promising the value round-trips.
    func test_aNewerBuildsStateIsShownRatherThanSilentlyBlank() async throws {
        try requireAssistiveClient()
        let (_, store, ds, piece) = try await collection()
        defer { Task { await ds.close() } }
        let firstPassId = try XCTUnwrap(store.manifest.effectiveReviewPasses.first?.id)
        try await store.setPassState(
            id: piece.id, passId: firstPassId, .unknown("awaiting_reader"))

        let host = column(store, ds, piece: piece.id)
        let window = mount(host)
        let reading5 = try await requireLadderRow(firstPassId, in: window).reading
        XCTAssertEqual(reading5,
                       "awaiting_reader",
                       "the unknown state must be shown as itself")

        // …and the writer can still rule on it, which overwrites deliberately.
        host.setPassState(piece.id, firstPassId, .done)
        await pumpUntil(deadline: 5) {
            self.states(of: piece.id, in: store)?[firstPassId] == .done
        }
        XCTAssertEqual(states(of: piece.id, in: store)?[firstPassId], .done)
    }

    // MARK: - C15: a chosen pass state survives the view that carried it

    /// What a fixture leaves behind once the test lets go of it — the three
    /// values the C15 tests still need after the store is out of their hands.
    private struct Ladder {
        let url: URL
        let pieceId: String
        let passId: String
    }

    /// Build a book, hand its stores to `makeView`, and give back only the
    /// strings beside it. The `Book` — and with it this test's own strong
    /// reference to the store — dies at the end of this call, so from here the
    /// view the caller is holding has the only one.
    private func makeLadder<V>(
        named name: String, into makeView: (ProjectStore, DocumentStore, String) -> V
    ) async throws -> (Ladder, V) {
        let book = try await PieceWriterFixture.oneAuthor(named: name, in: temp.url)
        let pieceId = book.pieceIDs[0]
        let passId = try XCTUnwrap(
            book.store.manifest.effectiveReviewPasses.first?.id)
        return (Ladder(url: book.url, pieceId: pieceId, passId: passId),
                makeView(book.store, book.documentStore, pieceId))
    }

    /// The state on disk, read off the manifest file itself — never through
    /// the store under test, which by then is nobody's, and synchronously so
    /// it can be a poll predicate.
    private func passOnDisk(_ ladder: Ladder) -> PassState? {
        let url = ladder.url.appendingPathComponent(ProjectManifest.fileName)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? ProjectManifest.makeDecoder()
                  .decode(ProjectManifest.self, from: data)
        else { return nil }
        return manifest.structure
            .first { $0.id == ladder.pieceId }?.passStates?[ladder.passId]
    }

    /// **The premise, so the test below means something.** Nothing but the
    /// column holds the store: released, it goes. Without this, a write that
    /// dropped the store could still land — kept alive by something else
    /// entirely — and the C15 pin would be green for the wrong reason.
    func test_premise_nothingButTheColumnHoldsTheStore() async throws {
        defer { PieceWriterFixture.reset() }
        weak var observed: ProjectStore?
        var host: RightColumn?
        // The tuple is scoped: it holds the view too, and a `let` kept to the
        // end of the test would be the second reference this is about.
        do {
            let made = try await makeLadder(named: "C15premise") { store, documentStore, pieceId in
                observed = store
                return self.column(store, documentStore, piece: pieceId)
            }
            host = made.1
        }
        XCTAssertNotNil(observed, "premise: the column is holding it")

        host = nil
        _ = await pumpUntil(deadline: 5) { observed == nil }

        XCTAssertNil(observed,
                     "something other than the column retains the store, so the "
                     + "C15 test below cannot tell a strong capture from a weak one")
    }

    /// **The ladder's write holds the store until it lands** (P3b carry C15).
    ///
    /// The window closing, the position changing and the subject moving all
    /// tear the column's pane down, and all three can land in the same turn as
    /// the click — so a `guard let store else { return }` reached after the
    /// view went away is a pass state the writer chose and Maugham dropped,
    /// with nothing red anywhere.
    ///
    /// The column here holds the only strong reference (the premise above),
    /// and it is released in the same main-actor turn as the call — before
    /// the task's body can have run at all.
    func test_theLadderWriteLandsWhenTheColumnHeldTheOnlyReferenceToTheStore() async throws {
        defer { PieceWriterFixture.reset() }
        var host: RightColumn?
        var ladder: Ladder!
        do {
            let made = try await makeLadder(named: "C15") { store, documentStore, pieceId in
                self.column(store, documentStore, piece: pieceId)
            }
            ladder = made.0
            host = made.1
        }
        XCTAssertNil(passOnDisk(ladder), "premise: no pass state yet")

        host?.setPassState(ladder.pieceId, ladder.passId, .done)
        // Same turn, no await in between: the task cannot have started, so
        // what keeps the store alive from here is its capture and nothing else.
        host = nil

        _ = await pumpUntil(deadline: 5) { self.passOnDisk(ladder) == .done }

        XCTAssertEqual(passOnDisk(ladder), .done,
            "the pass the writer chose never reached disk — the task let the "
            + "store go before its own write")
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
