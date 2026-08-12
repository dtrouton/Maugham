import XCTest
import AppKit
import SwiftUI
import Observation
import MaughamCore
@testable import Maugham

// MARK: - The pure rule

/// **The destination rule, over the boolean it is actually about** — the same
/// falsification shape `ManuscriptNavigationTests` uses for
/// `Persona.showsManuscriptDocuments`: the travel rule reads
/// `Persona.centresTheCanvas`, never `== .plan`, so a persona named anything
/// else that started centring the board would travel too, and the assertions
/// below are written against the boolean rather than the name to make that
/// swap invisible to this suite.
@MainActor
final class TreeTravelDestinationTests: XCTestCase {

    func test_planTravelsToAuthor() {
        XCTAssertEqual(TreeTravel.treeTravelDestination(persona: .plan), .author,
                       "Plan is the one persona whose centre column is the "
                       + "board — a double-clicked row has nowhere to open "
                       + "there")
    }

    func test_everyPersonaThatAlreadyShowsTheManuscriptHasNowhereToTravel() {
        for persona in Persona.allCases where persona != .plan {
            XCTAssertNil(TreeTravel.treeTravelDestination(persona: persona),
                        "\(persona) already centres the manuscript — a "
                        + "double-click there means nothing beyond the click "
                        + "a single click already gave it")
        }
    }

    /// **Anti-degeneracy control.** A rule that answered a constant would
    /// satisfy the two assertions above on their own; pinning the answer
    /// against the boolean it is actually asking is what
    /// `ManuscriptNavigationTests` does for the sibling rule, and this is the
    /// same shape.
    func test_theRuleAgreesWithCentresTheCanvasForEveryPersona() {
        for persona in Persona.allCases {
            XCTAssertEqual(
                TreeTravel.treeTravelDestination(persona: persona) != nil,
                persona.centresTheCanvas,
                "\(persona): the travel rule and centresTheCanvas must agree "
                + "on whether there is a destination")
        }
    }
}

// MARK: - Mounted: the receiver

/// **`TreeTravelModifier`, mounted and driven through a real
/// `.maughamTreeTravel` post** — the same shape `PaletteWallDoorTests` uses
/// for `CanvasClaudeArrivalModifier.show`/`ManuscriptNavigation.go`: post the
/// event the row's own gesture would post, and watch what the mounted
/// receiver does with it. `MaughamEvent.post` is the one sanctioned spelling
/// of that post (`Maugham/Events/MaughamEvent.swift`), so driving it directly
/// exercises the exact call `treeTravelOnDoubleClick` makes — nothing about
/// the receiver's own behaviour depends on how the row got there.
///
/// **This class posts directly; the mounted class below drives real clicks.**
/// Until 2026-08-12 nothing drove a real one, and the note here said a
/// synthetic double-click was unreachable: the `.onTapGesture(count: 2)`
/// recognizer never fired for any synthetic timing tried. That was true, and
/// it was a symptom — SwiftUI's gesture graph is not driven by
/// `NSApp.postEvent`-delivered events. It is no longer a limit, because the
/// travel rule is no longer a SwiftUI gesture: it is an `NSEvent` monitor over
/// a hit-test-transparent marker (`TreeTravel.swift`'s doc comment has the
/// measurement), and AppKit-level mechanisms ARE reachable synthetically.
/// `TreeTravelRowMountingTests.test_aDoubleClickOnTheRowsNameTravelsToAuthor`
/// is that test. What is proven here instead is the receiver's own behaviour —
/// the persona guard, the memory write, the `.keyWindow` scope — which a click
/// would only reach through three more layers.
@MainActor
final class TreeTravelReceiverTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []

    override func setUp() async throws {
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        temp.cleanup()
        temp = nil
    }

    /// **Contract: double-click travels to Author with the row's own
    /// subject.** Posted directly rather than clicked — see the class doc.
    func test_postedInPlanMovesToAuthorWithThePostedSubject() async throws {
        let probe = try await hostReceiver(persona: .plan, detailSegment: .inbox)
        let subject = BinderSubject.item("abcd")

        post(subject, window: probe.window)
        await pumpUntil(deadline: 5) { probe.persona == .author }

        XCTAssertEqual(probe.persona, .author,
                       "Plan is the one persona whose centre is the board — "
                       + "a travel must land in Author")
        XCTAssertEqual(probe.subject, subject,
                       "the receiver must write the POSTED subject — the "
                       + "row's own tag, never something re-derived from "
                       + "selection state")
    }

    /// **Contract: "In Author, a double-click is a no-op — one control."**
    /// The poster does not know the persona — `treeTravelOnDoubleClick`
    /// always posts unconditionally; the guard lives entirely on the
    /// receiver (`TreeTravel.treeTravelDestination`). Neither field moves,
    /// because the guard returns before either write.
    func test_postedInAuthorIsANoOp() async throws {
        let probe = try await hostReceiver(persona: .author, detailSegment: .inbox)

        post(.project, window: probe.window)
        await waitOut(0.4)

        XCTAssertEqual(probe.persona, .author,
                       "there is no persona to travel to from Author")
        XCTAssertNil(probe.subject,
                     "the guard refuses before writing anything at all — "
                     + "including the subject")
    }

    /// **The same refusal for the other two personas that show the
    /// manuscript** — Review and Publish, so the guard is proven over the
    /// actual set rather than just its most obvious member.
    func test_postedInReviewOrPublishIsANoOp() async throws {
        for persona in [Persona.review, .publish] {
            let probe = try await hostReceiver(persona: persona, detailSegment: .inbox)
            post(.project, window: probe.window)
            await waitOut(0.3)
            XCTAssertEqual(probe.persona, persona,
                           "\(persona) already centres the manuscript — no "
                           + "destination, so no move")
        }
    }

    /// **Contract: "the departing Plan position is recorded — one
    /// applyPersonaChange-shaped assertion."** ⌘1 has to bring the writer
    /// back to the tree they were arranging, which only happens if the
    /// travel records where Plan itself was standing before it moves off it
    /// — `ManuscriptNavigation.go`'s own reasoning, reused here (through
    /// `PersonaModifier.applyPersonaChange` directly) rather than re-derived.
    func test_theDepartingPlanPositionIsRecordedInPersonaMemory() async throws {
        let probe = try await hostReceiver(persona: .plan, detailSegment: .inbox)

        post(.item("chap1"), window: probe.window)
        await pumpUntil(deadline: 5) { probe.persona == .author }

        XCTAssertEqual(probe.persona, .author, "precondition: the travel fired")
        let memory = try XCTUnwrap(probe.documentStore?.uiState.personaMemory)
        XCTAssertEqual(memory.restoredDetailSegment(for: .plan), .inbox,
                       "the pane Plan was standing on before the travel must "
                       + "be recorded, so ⌘1 restores it rather than Plan's "
                       + "bare default")
    }

    /// **`.keyWindow` scope, declared at the post site (ADR 0021).** A
    /// window that never became key must not act — the same liveness/scope
    /// contract every other `.keyWindow` receiver in `ProjectWindow` carries.
    func test_aNonKeyWindowDoesNotReceiveTheTravel() async throws {
        let probe = try await hostReceiver(persona: .plan, detailSegment: .inbox,
                                           makeKey: false)
        post(.item("chap1"), window: probe.window)
        await waitOut(0.4)
        XCTAssertEqual(probe.persona, .plan,
                       "a non-key window must not travel on a `.keyWindow`-"
                       + "scoped post")
    }

    // MARK: - Hosting

    private func post(_ subject: BinderSubject, window: NSWindow?) {
        MaughamEvent.post(.maughamTreeTravel, to: .keyWindow,
                          payload: [MaughamEvent.treeTravelSubjectKey: subject])
    }

    private func hostReceiver(
        persona: Persona, detailSegment: DetailSegment, makeKey: Bool = true
    ) async throws -> TreeTravelProbe {
        let url = try await ProjectFactory.createNovelProject(
            named: "Receiver-\(UUID().uuidString.prefix(6))", in: temp.url)
        let ds = try await DocumentStore.open(url: url)
        documentStores.append(ds)

        let probe = TreeTravelProbe(persona: persona, detailSegment: detailSegment,
                                    documentStore: ds)
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let hosting = NSHostingView(rootView: AnyView(TreeTravelReceiverProbeView(probe: probe)))
        hosting.frame = frame
        let window = TreeTravelKeyTestWindow(
            contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.reportsKey = makeKey
        window.contentView = hosting
        if makeKey { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        await pumpUntil(deadline: 5) { probe.window != nil }
        return probe
    }
}

// MARK: - Mounted: rows still select and still drag

/// **The half of the row wiring a mounted test CAN prove safely**: a single
/// click still only selects (no persona move, whatever the row), and every
/// row this milestone touched still mounts the platform view `.draggable` /
/// `.dropDestination` install — unwidened by the added gesture.
/// `BinderProjectRowTests.test_theProjectRowIsNeitherDraggableNorADropTarget`'s
/// own shape.
@MainActor
final class TreeTravelRowMountingTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []

    override func setUp() async throws {
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        temp.cleanup()
        temp = nil
    }

    /// **The regression this suite did not have, 2026-08-12.** A single click
    /// on a row's NAME — the text itself, not the icon and not the whitespace
    /// after it — must select the row.
    ///
    /// Stage 3b's `.onTapGesture(count: 2)` on the label swallowed it: the
    /// writer could select a chapter by clicking its icon or the empty space to
    /// the right of its title, but clicking the title did nothing at all. Every
    /// test in this file was green throughout, because
    /// `test_aSingleClickOnTheChapterRowOnlySelects` (below, now clicking the
    /// name) clicked `rect.midX` against a project's DEFAULT short title — and
    /// at a 420pt tree width the midpoint of the row falls in the trailing
    /// `Spacer`, past where the text ends, which is the one part of the row
    /// that never broke. That is the whole gap: a click is not "on the row", it
    /// is at a POINT, and the point that mattered was the one over the glyphs.
    ///
    /// **The premise is read off the geometry it actually got** (the CI
    /// display-width rule in CLAUDE.md): the click lands at the midpoint of the
    /// travel mark's OWN frame, which is the label leaf's frame, rather than at
    /// a hardcoded x that a different font or a clamped window would move out
    /// from under. `labelFrame` failing is itself the mark being missing.
    func test_aSingleClickOnTheRowsNameSelectsIt() async throws {
        let store = try await novel(named: "NameClick")
        let firstDoc = try XCTUnwrap(store.manifest.structure.first)
        // Long enough that the label spans well past the row's own midpoint,
        // so "the name" and "the middle of the row" are different places —
        // with a short title the bug is invisible to a midX click.
        try await store.renameStructureItem(
            id: firstDoc.id, newTitle: "A Chapter With A Rather Long Name")
        let (window, probe, table) = try await hostBinder(store: store)

        let label = try XCTUnwrap(labelFrame(ofRow: 1, in: table),
                                  "row 1 carries no travel mark at all — "
                                  + "`treeTravelOnDoubleClick` is missing, or "
                                  + "has gone back to being a gesture")
        XCTAssertGreaterThan(label.width, 40,
                             "the label is too narrow for this test to be "
                             + "about clicking text — premise failing, not "
                             + "the row")
        XCTAssertLessThan(label.width, table.rect(ofRow: 1).width,
                          "the mark spans the whole row, so it is on the "
                          + "container rather than the label leaf — the "
                          + "TaskRow scar (tripwire 9)")

        await click(at: CGPoint(x: label.midX, y: label.midY),
                    in: table, window: window)
        await pumpUntil(deadline: 5) { probe.subject == .item(firstDoc.id) }

        XCTAssertEqual(table.selectedRow, 1,
                       "a single click on the row's NAME must select it — "
                       + "this is stage 3b's regression: the icon and the "
                       + "trailing whitespace selected, the title did not")
        XCTAssertEqual(probe.subject, .item(firstDoc.id),
                       "and the selection must reach the window's subject "
                       + "through `List(selection:)`'s own binding")
        XCTAssertEqual(probe.persona, .plan,
                       "one click is not a travel")
    }

    /// **The other half of the same click, now reachable.** A double-click on
    /// the name travels to Author on that row's subject — driven as a real
    /// synthetic double-click, which the SwiftUI gesture this replaced could
    /// not be (see `TreeTravelReceiverTests`' class doc). A mechanism that can
    /// be driven end-to-end is worth more than one that has to be asserted in
    /// two disconnected halves, and it is the reason the fix went to AppKit
    /// rather than to a different SwiftUI gesture.
    func test_aDoubleClickOnTheRowsNameTravelsToAuthor() async throws {
        let store = try await novel(named: "NameDoubleClick")
        let firstDoc = try XCTUnwrap(store.manifest.structure.first)
        try await store.renameStructureItem(
            id: firstDoc.id, newTitle: "A Chapter With A Rather Long Name")
        let (window, probe, table) = try await hostBinder(store: store)
        // The receiver is `.keyWindow`-scoped and reads the window
        // `WindowAccessor` resolves a runloop hop after mount; clicking before
        // it lands drives a live poster at a dead receiver.
        let ready = await pumpUntil(deadline: 5) { probe.window != nil }
        XCTAssertTrue(ready, "the probe's window never resolved — premise")

        let label = try XCTUnwrap(labelFrame(ofRow: 1, in: table))
        await click(at: CGPoint(x: label.midX, y: label.midY),
                    in: table, window: window, clicks: 2)
        await pumpUntil(deadline: 5) { probe.persona == .author }

        XCTAssertEqual(probe.persona, .author,
                       "a double-click on a tree row's name in Plan takes the "
                       + "writer to Author — Denver's travel rule")
        XCTAssertEqual(probe.subject, .item(firstDoc.id),
                       "on that row's OWN subject")
    }

    /// **The control the pair above needs**: the same double-click, at the same
    /// row, on the whitespace PAST the name, travels nowhere. Without it, a
    /// mark that had quietly widened onto the row container would satisfy both
    /// tests above while changing what the writer can double-click — and the
    /// widening is invisible to every other assertion here, because a wider
    /// mark still selects and still drags.
    func test_aDoubleClickPastTheNameDoesNotTravel() async throws {
        let store = try await novel(named: "PastTheName")
        let firstDoc = try XCTUnwrap(store.manifest.structure.first)
        try await store.renameStructureItem(id: firstDoc.id, newTitle: "Ch")
        let (window, probe, table) = try await hostBinder(store: store)
        let ready = await pumpUntil(deadline: 5) { probe.window != nil }
        XCTAssertTrue(ready, "the probe's window never resolved — premise")

        let rect = table.rect(ofRow: 1)
        let label = try XCTUnwrap(labelFrame(ofRow: 1, in: table))
        let past = (label.maxX + rect.maxX) / 2
        XCTAssertGreaterThan(past, label.maxX,
                             "there is no whitespace past this label to click "
                             + "— premise failing")

        await click(at: CGPoint(x: past, y: rect.midY),
                    in: table, window: window, clicks: 2)
        await waitOut(0.5)

        XCTAssertEqual(probe.persona, .plan,
                       "the travel mark is the label leaf, not the row — a "
                       + "double-click on the row's empty trailing space is "
                       + "not a travel")
        XCTAssertEqual(table.selectedRow, 1,
                       "…though it still selects, like any other click on the "
                       + "row")
    }

    /// **`TreeTravelClickWatcher.stop()` really removes the monitor** — the
    /// one claim that method's "test-only" doc makes, and this is the caller
    /// that makes it true rather than unexercised code whose comment asserts
    /// something nothing checks.
    ///
    /// It also pins the half that matters most about the whole mechanism: with
    /// the watcher gone the click STILL selects. The monitor is not in the
    /// dispatch path, so removing it takes the travel away and leaves
    /// `List(selection:)` exactly as it was — which is the same property, seen
    /// from the other side, that makes the fix safe for selection and drag.
    ///
    /// **Hosted on the tree rather than on a bare marked label**, though a
    /// label plus a monitor is the whole mechanism and a smaller host was
    /// tried first. Measured: in a plain `NSHostingView` window the watcher
    /// receives the synthetic double-click with `locationInWindow` reading the
    /// REAL cursor position rather than the posted one — resolved subject
    /// `nil`, no post, for a mechanism that is working. Routed through an
    /// `NSTableView` the posted location survives, which is why every click
    /// test in this file goes through a real tree.
    func test_aStoppedWatcherTravelsNowhereButStillSelects() async throws {
        let store = try await novel(named: "StoppedWatcher")
        let firstDoc = try XCTUnwrap(store.manifest.structure.first)
        try await store.renameStructureItem(
            id: firstDoc.id, newTitle: "A Chapter With A Rather Long Name")
        let (window, probe, table) = try await hostBinder(store: store)
        let ready = await pumpUntil(deadline: 5) { probe.window != nil }
        XCTAssertTrue(ready, "the probe's window never resolved — premise")

        TreeTravelClickWatcher.shared.stop()
        // The watcher is process-global and every other mounted suite in this
        // worker has already run its `TreeTravelModifier.onAppear`, which will
        // not fire again to re-install it.
        defer { TreeTravelClickWatcher.shared.start() }

        let label = try XCTUnwrap(labelFrame(ofRow: 1, in: table))
        await click(at: CGPoint(x: label.midX, y: label.midY),
                    in: table, window: window, clicks: 2)
        await waitOut(0.5)

        XCTAssertEqual(probe.persona, .plan,
                       "a stopped watcher must not travel — its monitor is "
                       + "still installed")
        XCTAssertEqual(table.selectedRow, 1,
                       "…while the very same click still selects, because the "
                       + "monitor never sat in the dispatch path to begin with")
    }

    /// A single click — the first half of any double-click — must only
    /// select. The dim moves (a subject write via `List(selection:)`); the
    /// persona does not, because `.maughamTreeTravel` is never posted by one
    /// click alone.
    ///
    /// **Clicks the NAME, not `rect.midX`.** It clicked the row's midpoint
    /// until 2026-08-12, which against a default short title is the trailing
    /// `Spacer` — see `test_aSingleClickOnTheRowsNameSelectsIt` for what that
    /// cost.
    func test_aSingleClickOnTheChapterRowOnlySelects() async throws {
        let store = try await novel(named: "SingleClick")
        let firstDoc = try XCTUnwrap(store.manifest.structure.first)
        let (window, probe, table) = try await hostBinder(store: store)

        let label = try XCTUnwrap(labelFrame(ofRow: 1, in: table))
        await click(at: CGPoint(x: label.midX, y: label.midY),
                    in: table, window: window)
        await pumpUntil(deadline: 5) { probe.subject == .item(firstDoc.id) }

        // **The delivery premise, asserted before the contract** — a synthetic
        // click that AppKit never turned into a click leaves the row unselected,
        // and read off the subject alone that is indistinguishable from a broken
        // selection binding. It cost a whole debugging session on 2026-08-12 to
        // tell those two apart (`click`'s own note has the measurement), so the
        // harness's half now fails in its own words.
        XCTAssertEqual(table.selectedRow, 1,
                       "the synthetic click was never recognised as a click — "
                       + "this is the harness's premise failing, not the row's "
                       + "selection binding")
        XCTAssertEqual(probe.subject, .item(firstDoc.id))
        XCTAssertEqual(probe.persona, .plan,
                       "a single click must never move the persona — that "
                       + "needs the second click of a double-click, which "
                       + "this test never sends")
    }

    func test_theChapterRowStillMountsItsDragMachinery() async throws {
        let store = try await novel(named: "DragMachinery")
        let (_, _, table) = try await hostBinder(store: store)

        XCTAssertTrue(hasDraggingDestination(row: 1, in: table),
                      "the chapter row must still mount .draggable / "
                      + ".dropDestination after the travel gesture was added "
                      + "to its label")
    }

    /// **What a mounted test CAN prove for this row kind, and why the other
    /// rows' technique doesn't reach it.** The palette card's row is a
    /// `Label` with ONLY `.draggable` attached — never `.dropDestination` /
    /// `.onDrop`; a card is not a drop target (`paletteSection`'s own doc
    /// comment: "the section's rows are not drop targets either"). Measured
    /// directly against every row in this fixture (a full AppKit subview
    /// walk, row by row), `hasDraggingDestination`'s
    /// `_PlatformDraggingDestinationView` answers a narrower question than
    /// its name suggests: it is present for `.dropDestination`/`.onDrop`
    /// (true for the chapter row, which carries both that AND `.draggable`;
    /// true for the Research section's header and its empty-state
    /// placeholder, NEITHER of which is `.draggable` at all) and genuinely
    /// absent for a row that carries `.draggable` alone — this row, every
    /// single time, independent of load timing (tried with the card present
    /// from the first layout pass, tried waiting on `state.cards` loading
    /// after mount, tried forcing an extra `layoutSubtreeIfNeeded()` — the
    /// same false throughout). So it is not usable as a falsifier here, and
    /// this test proves the half that IS reachable without it: the row
    /// renders with the card's own subject and `List(selection:)`'s real
    /// binding selects it. `TreeTravelGestureAttachmentTests` is what proves
    /// `.draggable` itself is still there, ahead of the travel gesture, in
    /// source.
    func test_thePaletteCardRowRendersAndSelectsThroughTheRealBinding() async throws {
        let store = try await novel(named: "PaletteSelect")
        let card = try await store.addPaletteCard(title: "Select Card", kind: .other)
        let treeState = BinderTreeSectionsState()
        let (_, probe, table) = try await hostBinder(store: store, treeState: treeState)
        let loaded = await pumpUntil(deadline: 5) { !treeState.cards.isEmpty }
        XCTAssertTrue(loaded, "the palette card never loaded into state.cards")

        table.selectRowIndexes(IndexSet(integer: table.numberOfRows - 1),
                               byExtendingSelection: false)
        await pumpUntil(deadline: 5) { probe.subject == .research(card.id) }

        XCTAssertEqual(probe.subject, .research(card.id),
                       "the palette card's row must select through the "
                       + "tree's real binding — a card's subject IS its "
                       + "research id (`PaletteCard.id`)")
    }

    func test_thePieceRowStillMountsItsDragMachinery() async throws {
        let store = try await collection(named: "PieceDrag")
        _ = try await store.addLoosePiece(title: "Drag Piece", mode: .prose)
        let (_, _, table) = try await hostCollectionPieces(store: store)
        // `CollectionPiecesPane` carries the same Research/Palette sections
        // BinderView does: project, the piece, Research header, Research's
        // own empty-section placeholder, Palette header, Palette's own
        // empty-section placeholder.
        try await waitForRowCount(6, in: table)

        XCTAssertTrue(hasDraggingDestination(row: 1, in: table),
                      "the piece row must still mount .draggable after the "
                      + "travel gesture was added to its label")
    }

    /// **The project row's own control, mirroring
    /// `BinderProjectRowTests.test_theProjectRowIsNeitherDraggableNorADropTarget`**:
    /// it was never draggable, and the travel gesture must not have made it
    /// one — a whole-row `.treeTravelOnDoubleClick` widened onto `.tag`
    /// rather than the label would be indistinguishable from this row's
    /// intended behaviour by every OTHER assertion in this file, since the
    /// project row is not draggable either way.
    func test_theProjectRowStillMountsNoDragMachinery() async throws {
        let store = try await novel(named: "ProjectRowControl")
        let (_, _, table) = try await hostBinder(store: store)

        XCTAssertFalse(hasDraggingDestination(row: 0, in: table),
                       "the project row has never been a drag source — "
                       + "confirms the travel gesture did not add one")
    }

    /// **The same control, for the Collection's own project row** — a
    /// separate row from `BinderView`'s (`ProjectWindow.binderColumn` mounts
    /// `BinderView` only for non-collection projects; `CollectionPiecesPane`
    /// carries its own), and the plan's original file list under-specified it
    /// — Denver's recorded rule is "double-click ANY tree row", and this row
    /// tags `.project` exactly like `BinderView`'s.
    func test_theCollectionProjectRowStillMountsNoDragMachinery() async throws {
        let store = try await collection(named: "CollectionProjectRowControl")
        let (_, _, table) = try await hostCollectionPieces(store: store)

        XCTAssertFalse(hasDraggingDestination(row: 0, in: table),
                       "the Collection's project row has never been a drag "
                       + "source — confirms the travel gesture did not add one")
    }

    /// **The same control, for the Scenes navigator's own project row.**
    /// `TreePane(for: .screenplay)` is `.sceneNavigator`, so `BinderView` is
    /// never mounted for a screenplay at all — without this row
    /// `BinderSubject.project` would be unconstructible there, exactly the
    /// gap `SceneNavigatorPane.swift`'s own doc comment records. It tags
    /// `.project` like the other two, and neither it nor `scriptRow` beside
    /// it carries `.draggable` — both now carry the travel gesture, neither
    /// a drag source.
    func test_theSceneNavigatorProjectRowStillMountsNoDragMachinery() async throws {
        let store = try await screenplay(named: "SceneNavProjectRowControl")
        let (_, _, table) = try await hostSceneNavigator(store: store)

        XCTAssertFalse(hasDraggingDestination(row: 0, in: table),
                       "the Scenes navigator's project row has never been a "
                       + "drag source — confirms the travel gesture did not "
                       + "add one")
    }

    /// **The screenplay's own document row.** Structurally a structure row
    /// in every way that matters (it tags `.item(documentID)`, exactly what
    /// `BinderRow` tags for a chapter) — `scriptRow`'s own doc comment is
    /// clear that it names the *kind* of thing rather than being a special
    /// case, and the travel rule treats it the same way. `hostSceneNavigator`
    /// always passes a `documentID`, so this row is always row 1, right below
    /// the project row (`SceneNavigatorProjectRowTests`' own row layout).
    func test_theScriptRowStillMountsNoDragMachinery() async throws {
        let store = try await screenplay(named: "ScriptRowControl")
        let (_, _, table) = try await hostSceneNavigator(store: store)

        XCTAssertFalse(hasDraggingDestination(row: 1, in: table),
                       "the script row has never been a drag source — "
                       + "confirms the travel gesture did not add one")
    }

    // MARK: - Fixtures

    private func novel(named name: String) async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "\(name)-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        documentStores.append(ds)
        await store.wordCountPopulationTask?.value
        return store
    }

    private func collection(named name: String) async throws -> ProjectStore {
        let url = try await ProjectFactory.createCollectionProject(
            named: "\(name)-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        documentStores.append(ds)
        await store.wordCountPopulationTask?.value
        return store
    }

    private func screenplay(named name: String) async throws -> ProjectStore {
        let url = try await ProjectFactory.createScreenplayProject(
            named: "\(name)-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        documentStores.append(ds)
        await store.wordCountPopulationTask?.value
        return store
    }

    // MARK: - Hosting and driving

    private func hostBinder(
        store: ProjectStore, persona: Persona = .plan,
        treeState: BinderTreeSectionsState? = nil
    ) async throws -> (NSWindow, TreeTravelProbe, NSTableView) {
        let treeState = treeState ?? BinderTreeSectionsState()
        let probe = TreeTravelProbe(persona: persona, detailSegment: .inbox,
                                    documentStore: store.documentStore)
        let frame = CGRect(x: 0, y: 0, width: 420, height: 700)
        let hosting = NSHostingView(rootView: AnyView(
            BinderTravelProbeView(store: store, probe: probe, treeState: treeState)))
        hosting.frame = frame
        let window = TreeTravelKeyTestWindow(contentRect: frame, styleMask: [.titled],
                                             backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        let table = try await pumpUntilTable(in: window)
        return (window, probe, table)
    }

    private func hostCollectionPieces(
        store: ProjectStore, persona: Persona = .plan
    ) async throws -> (NSWindow, TreeTravelProbe, NSTableView) {
        let probe = TreeTravelProbe(persona: persona, detailSegment: .inbox,
                                    documentStore: store.documentStore)
        let frame = CGRect(x: 0, y: 0, width: 420, height: 700)
        let hosting = NSHostingView(rootView: AnyView(
            CollectionPiecesTravelProbeView(store: store, probe: probe)))
        hosting.frame = frame
        let window = TreeTravelKeyTestWindow(contentRect: frame, styleMask: [.titled],
                                             backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        let table = try await pumpUntilTable(in: window)
        return (window, probe, table)
    }

    /// `documentID` is the literal `"doc-1"`, unconnected to any real
    /// structure item — `SceneNavigatorProjectRowTests`' own vocabulary, and
    /// the project row this test drives does not read it at all. `script:
    /// nil` for the same reason: the project row's contract has nothing to
    /// do with slugline content.
    private func hostSceneNavigator(
        store: ProjectStore, persona: Persona = .plan
    ) async throws -> (NSWindow, TreeTravelProbe, NSTableView) {
        let probe = TreeTravelProbe(persona: persona, detailSegment: .inbox,
                                    documentStore: store.documentStore)
        let frame = CGRect(x: 0, y: 0, width: 420, height: 700)
        let hosting = NSHostingView(rootView: AnyView(
            SceneNavigatorTravelProbeView(store: store, probe: probe)))
        hosting.frame = frame
        let window = TreeTravelKeyTestWindow(contentRect: frame, styleMask: [.titled],
                                             backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        let table = try await pumpUntilTable(in: window)
        return (window, probe, table)
    }

    private func pumpUntilTable(in window: NSWindow) async throws -> NSTableView {
        await pumpUntil(deadline: 5) { self.firstTableView(in: window) != nil }
        return try XCTUnwrap(firstTableView(in: window),
                             "the tree's List never reached the hierarchy")
    }

    private func waitForRowCount(_ count: Int, in table: NSTableView) async throws {
        let reached = await pumpUntil(deadline: 5) { table.numberOfRows == count }
        XCTAssertTrue(reached, "expected \(count) rows, found \(table.numberOfRows) — "
                      + "fixture row-count assumption is stale")
    }

    private func firstTableView(in window: NSWindow) -> NSTableView? {
        guard let root = window.contentView else { return nil }
        var found: [NSTableView] = []
        collect(NSTableView.self, in: root, into: &found)
        return found.first
    }

    /// A single click, real AppKit event delivery — the row's own selection
    /// binding is what this proves, so it goes through `NSApp.postEvent` +
    /// drain like every other synthetic click here (a draggable row's
    /// `mouseDown:` engages AppKit's own drag-disambiguation loop even for a
    /// single click; see `TreeTravelReceiverTests`' class doc for the
    /// measurement behind that).
    /// The frame of a row's travel mark — i.e. of its LABEL — in table
    /// coordinates, or `nil` when the row carries none.
    ///
    /// This is what makes the click tests read their premise off the geometry
    /// they actually got rather than off a hardcoded x: the mark is installed
    /// as the label's `.background`, so it has exactly the label's frame, and a
    /// click at its midpoint is a click on the writer's own text whatever the
    /// font, the title or the window width turn out to be.
    private func labelFrame(ofRow row: Int, in table: NSTableView) -> CGRect? {
        guard let rowView = table.rowView(atRow: row, makeIfNecessary: true)
        else { return nil }
        var found: CGRect?
        walk(rowView) { view in
            guard let target = view as? TreeTravelTargetView,
                  target.subject != nil else { return }
            found = target.convert(target.bounds, to: table)
        }
        return found
    }

    private func click(row: Int, in table: NSTableView, window: NSWindow) async {
        let rect = table.rect(ofRow: row)
        await click(at: CGPoint(x: rect.midX, y: rect.midY),
                    in: table, window: window)
    }

    /// `clicks: 2` sends the pair AppKit itself would: two down/up pairs with
    /// ascending `clickCount`, which is what `NSEvent.clickCount == 2` — the
    /// watcher's own discriminator — is reading.
    private func click(at point: CGPoint, in table: NSTableView,
                       window: NSWindow, clicks: Int = 1) async {
        let inWindow = table.convert(point, to: nil)
        let app = NSApplication.shared
        // **The queue has to be QUIET before the pair goes in** — this helper's
        // premise, and until 2026-08-12 an assumed one. `hostBinder` calls
        // `makeKeyAndOrderFront`, and ordering a window front leaves AppKit's
        // own `appKitDefined` (type 13) traffic for the PREVIOUSLY key window in
        // `NSApp`'s queue. Post the click on top of that and the drain below
        // dequeues the mouseDown first, `-[NSTableView mouseDown:]` opens its
        // drag-vs-click disambiguation loop, and the next event that loop finds
        // is the stale one rather than this click's own mouseUp: the pair is
        // consumed WITHOUT a click being recognised, `table.selectedRow` stays
        // -1, and nothing is ever selected. Measured directly (three variants,
        // one build): with the stale event in the queue, red — `drained #2
        // type=13 win=<ours − 1>`, `selectedRow(after)=-1`; draining it first,
        // green — `selectedRow(after)=1`. Whether it has drained on its own by
        // the time this runs is a function of machine load, which is how the
        // same unchanged test passed three gates and then failed four runs in a
        // row on a busier machine the same day.
        //
        // Deterministic rather than a sleep: drain to empty and require the
        // queue to STAY empty across three polls, so an event still in flight
        // has a run loop to arrive on before the click is posted.
        var quietPolls = 0
        while quietPolls < 3 {
            if let stray = app.nextEvent(matching: .any, until: Date(),
                                         inMode: .default, dequeue: true) {
                app.sendEvent(stray)
                quietPolls = 0
            } else {
                quietPolls += 1
            }
            pump(0.02)
        }
        var pairs: [(NSEvent.EventType, Int)] = []
        for n in 1...max(1, clicks) {
            pairs.append((.leftMouseDown, n))
            pairs.append((.leftMouseUp, n))
        }
        for (type, count) in pairs {
            guard let event = NSEvent.mouseEvent(
                with: type, location: inWindow, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: count,
                pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            app.postEvent(event, atStart: false)
        }
        while let next = app.nextEvent(matching: .any, until: Date(),
                                       inMode: .default, dequeue: true) {
            app.sendEvent(next)
            pump(0.02)
        }
        await waitOut(0.4)
    }

    /// Matched by class NAME, same as `BinderProjectRowTests` — the type is
    /// SwiftUI-internal, so a rename fails this loudly rather than passing
    /// vacuously.
    private func hasDraggingDestination(row: Int, in table: NSTableView) -> Bool {
        guard let view = table.rowView(atRow: row, makeIfNecessary: true)
        else { return false }
        var found = false
        walk(view) { if "\(type(of: $0))".contains("DraggingDestination") { found = true } }
        return found
    }

    private func walk(_ view: NSView, _ visit: (NSView) -> Void) {
        visit(view)
        for sub in view.subviews { walk(sub, visit) }
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }
}

// MARK: - Source census: the mark is on the label leaf, not the row

/// **Two source censuses over the travel rule's own files**: the mark is
/// attached to the label leaf, and it is not a SwiftUI gesture.
///
/// The ordering half reads the files named in
/// `test_theGestureAttachesBeforeTheRowWidens`'s own `expectations` array —
/// not counted here, so a row kind added later cannot go stale in prose while
/// the array right below it grows — and checks that
/// `.treeTravelOnDoubleClick(` sits BEFORE the row's own
/// `.tag`/`.contentShape`/`.draggable`. Since 2026-08-12 that is a question
/// about GEOMETRY rather than about stolen clicks: the mark is installed as a
/// `.background`, so it takes the frame of whatever it is attached to, and
/// attached after those calls it would take the ROW's frame — making a
/// double-click anywhere on the row a travel, including the empty space past
/// the title. `TreeTravelRowMountingTests.test_aDoubleClickPastTheNameDoesNotTravel`
/// is the behavioural half of the same contract.
///
/// The second half — `test_noTreeRowCarriesASwiftUITapGesture` — is the one
/// the stage 3b regression needed and the ordering check could not be: that
/// gesture was correctly ordered and still ate the writer's single click.
final class TreeTravelGestureAttachmentTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every file the travel rule touches, including `TreeTravel.swift` itself.
    private var travelFiles: [String] {
        ["Maugham/Views/BinderRow.swift",
         "Maugham/Views/PieceRow.swift",
         "Maugham/Views/ResearchRow.swift",
         "Maugham/Views/BinderTreeSections.swift",
         "Maugham/Views/BinderView.swift",
         "Maugham/Views/CollectionPiecesPane.swift",
         "Maugham/Views/SceneNavigatorPane.swift",
         "Maugham/Views/TreeTravel.swift"]
    }

    /// The spellings that re-introduce the bug class. Both, because
    /// `.onTapGesture(count:)` and a bare `TapGesture(count:)` handed to
    /// `.gesture`/`.simultaneousGesture`/`.highPriorityGesture` were measured
    /// to behave identically here.
    private static let tapGestureSpellings = ["onTapGesture(", "TapGesture("]

    /// Text with its comment lines removed. **Pure, and separate from
    /// `code(_:)`**, so the planted offender below can be run through the
    /// REAL stripper rather than through a hand-written imitation of it.
    ///
    /// **`TreeTravel.swift` names both rejected spellings in prose**, at
    /// length, because why they are wrong is the most valuable thing in that
    /// file — so a census that grepped raw text would either fail on the
    /// explanation or have to skip the one file where the mechanism actually
    /// lives. Stripping comments keeps the file in scope and keeps the
    /// explanation.
    static func strippingComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// **The detector itself** — the one path both the census and its planted
    /// offender go through. Returns the offending spellings found in `text`
    /// once its comments are gone.
    static func tapGestureOffences(in text: String) -> [String] {
        let code = strippingComments(text)
        return tapGestureSpellings.filter { code.contains($0) }
    }

    private func code(_ path: String) throws -> String {
        Self.strippingComments(try source(path))
    }

    private func lineIndex(of needle: String, in lines: [Substring]) -> Int? {
        lines.firstIndex(where: { $0.contains(needle) })
    }

    /// The mark line belonging to THIS `widenLine` — the nearest
    /// `.treeTravelOnDoubleClick(` occurrence at or before it, never the
    /// file's first — so a file carrying more than one row (`SceneNavigatorPane
    /// .swift`'s project row AND its own script row, both mark-bearing)
    /// pairs each widening call with the mark actually above IT, rather
    /// than one row's mark silently vouching for a different row's widen
    /// call by virtue of coming first in the file.
    private func nearestGestureLine(before widenLine: Int, in lines: [Substring]) -> Int? {
        lines[0..<widenLine].lastIndex(where: { $0.contains(".treeTravelOnDoubleClick(") })
    }

    /// One row kind per case: the file, and the call that widens the row
    /// AFTER the mark must already be attached — `.draggable(` for every
    /// row that drags, a row-specific `.tag(...)` for the rows that don't
    /// drag at all. `widensAt` must be unique in its file (verified as each
    /// entry was added) so it always anchors the SAME row's own widen call.
    func test_theGestureAttachesBeforeTheRowWidens() throws {
        struct Expectation {
            let file: String
            let widensAt: String
        }
        let expectations = [
            Expectation(file: "Maugham/Views/BinderRow.swift", widensAt: ".draggable("),
            Expectation(file: "Maugham/Views/PieceRow.swift", widensAt: ".draggable("),
            Expectation(file: "Maugham/Views/ResearchRow.swift", widensAt: ".draggable("),
            Expectation(file: "Maugham/Views/BinderTreeSections.swift", widensAt: ".draggable("),
            Expectation(file: "Maugham/Views/BinderView.swift", widensAt: ".tag(BinderSubject.project)"),
            // The other two project rows — `ProjectWindow.binderColumn`
            // mounts exactly one of the three per project type, but the
            // gesture belongs on all three since the rule is "any tree row",
            // not "any tree row this app happens to show at once".
            Expectation(file: "Maugham/Views/CollectionPiecesPane.swift",
                       widensAt: ".tag(BinderSubject.project)"),
            Expectation(file: "Maugham/Views/SceneNavigatorPane.swift",
                       widensAt: ".tag(BinderSubject.project)"),
            // `SceneNavigatorPane`'s SECOND mark-bearing row: the script
            // row, tagging the screenplay's one document — the last row the
            // set closes with (structure rows, project rows, research/palette
            // rows, and this one; scene rows excluded because they already
            // navigate through `ManuscriptNavigation` on a single click).
            Expectation(file: "Maugham/Views/SceneNavigatorPane.swift",
                       widensAt: ".tag(BinderSubject.item(documentID))"),
        ]
        for expectation in expectations {
            let text = try source(expectation.file)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let widenLine = try XCTUnwrap(
                lineIndex(of: expectation.widensAt, in: lines),
                "\(expectation.file): the row-widening call itself is missing "
                + "— fixture assumption is stale")
            let gestureLine = try XCTUnwrap(
                nearestGestureLine(before: widenLine, in: lines),
                "\(expectation.file): no .treeTravelOnDoubleClick( precedes "
                + "\(expectation.widensAt) at all — the travel mark is "
                + "missing outright for this row")
            XCTAssertLessThan(gestureLine, widenLine,
                              "\(expectation.file): .treeTravelOnDoubleClick must "
                              + "come BEFORE \(expectation.widensAt). The mark is "
                              + "a `.background`, so it takes the frame of "
                              + "whatever it is attached to, and that frame is "
                              + "what the watcher hit-tests — i.e. it is the "
                              + "definition of what counts as \"the name\". "
                              + "Attached after this call it takes the ROW's "
                              + "frame instead of the label's, and a "
                              + "double-click on the empty space past the title "
                              + "starts travelling too")
        }
    }

    /// **No tree row may carry a SwiftUI tap gesture, 2026-08-12.**
    ///
    /// This is the census the ordering check above could not be. Stage 3b's
    /// `.onTapGesture(count: 2)` was correctly placed by every rule this file
    /// knew — on the label leaf, before `.draggable` — and still cost the
    /// writer the single click, because the defect was never about WHERE the
    /// gesture sat. `NSHostingView` gives SwiftUI's gesture graph the mouseDown
    /// first, and a gesture whose hit region covers the point consumes it
    /// rather than passing it to the enclosing `NSTableView`; the double-tap
    /// recognizer waits for a second click that never comes, and the first one
    /// is gone. `.simultaneousGesture(TapGesture(count: 2))` was measured on
    /// the same rig and does the same thing.
    ///
    /// So the rule is the stronger one: in these files the travel rule is an
    /// AppKit marker plus an `NSEvent` monitor, and a tap gesture of ANY count
    /// re-introduces the bug class. A prose warning is what this replaces —
    /// the distinction "label leaf, but not a gesture" is exactly the kind a
    /// reader merges back together.
    func test_noTreeRowCarriesASwiftUITapGesture() throws {
        for path in travelFiles {
            let offences = Self.tapGestureOffences(in: try source(path))
            XCTAssertTrue(
                offences.isEmpty,
                "\(path) contains \(offences.joined(separator: ", ")) — a "
                + "SwiftUI tap gesture on a row inside `List(.sidebar)` eats "
                + "the single click that selects it, wherever it is attached. "
                + "The travel rule is `treeTravelOnDoubleClick`'s "
                + "hit-test-transparent marker plus `TreeTravelClickWatcher`; "
                + "see TreeTravel.swift.")
        }
    }

    /// **The planted offender, injected into the REAL detector.**
    ///
    /// It matters that this goes through `tapGestureOffences(in:)` — the same
    /// function the census above calls, comment-stripper and all — rather than
    /// asserting that a hand-written string contains a substring. The latter
    /// tests `String.contains`, which is not the thing that could break: what
    /// could break is the stripper eating a real code line, or the spelling
    /// list drifting away from what the census greps for.
    ///
    /// Three fixtures, because this detector has two ways to be wrong:
    ///
    /// - the offending line as CODE must be caught;
    /// - the same text in a COMMENT must not be — otherwise the stripper is
    ///   inert and `TreeTravel.swift`, which explains both rejected spellings
    ///   at length, could never stay in scope;
    /// - a clean row must come back empty, so the detector is not simply
    ///   answering "yes".
    func test_theTapGestureCensusCatchesAPlantedOffender() throws {
        let clean = """
            Text(item.title)
                .lineLimit(1)
                .treeTravelOnDoubleClick(.item(item.id))
            """
        let commentDecoy = """
            // Never `.onTapGesture(count: 2)` here — see TreeTravel.swift for
            // why a SwiftUI TapGesture(count: 2) eats the single click.
            \(clean)
            """
        let offender = """
            \(commentDecoy)
                .onTapGesture(count: 2) { travel() }
            """

        XCTAssertEqual(Self.tapGestureOffences(in: clean), [],
                       "the detector fired on a row that carries no gesture "
                       + "at all — it is answering yes to everything")
        XCTAssertEqual(Self.tapGestureOffences(in: commentDecoy), [],
                       "the detector fired on a COMMENT mentioning the "
                       + "rejected spelling. The comment-stripper is what "
                       + "keeps TreeTravel.swift — whose doc comment names "
                       + "both spellings — inside the census rather than "
                       + "exempted from it")
        XCTAssertEqual(Self.tapGestureOffences(in: offender),
                       Self.tapGestureSpellings,
                       "the detector missed a planted copy of the very line "
                       + "that shipped the regression, sitting in code "
                       + "directly beneath a comment about it")
    }

    /// **The stripper is load-bearing on a REAL file, not just on a fixture.**
    ///
    /// `TreeTravel.swift` names both rejected spellings in its doc comment. If
    /// comment-stripping ever became inert the census would start failing on
    /// that file — and the tempting fix would be to drop it from `travelFiles`,
    /// which is the one file where the mechanism actually lives. Pinning both
    /// halves here means the pressure lands on the stripper instead.
    func test_theStripperIsWhatKeepsTreeTravelInScope() throws {
        let path = "Maugham/Views/TreeTravel.swift"
        XCTAssertTrue(travelFiles.contains(path),
                      "the file the census most needs has been dropped from it")
        let raw = try source(path)
        XCTAssertTrue(Self.tapGestureSpellings.allSatisfy(raw.contains),
                      "TreeTravel.swift no longer explains the rejected "
                      + "spellings by name — either the doc comment was "
                      + "thinned, or this test's premise is stale")
        XCTAssertEqual(Self.tapGestureOffences(in: raw), [],
                       "…and after stripping comments none may remain: the "
                       + "explanation is prose, the mechanism is not a gesture")
    }

    /// The control every absence-shaped/ordering assertion needs: the files
    /// are really being read, so a path typo fails loudly here rather than
    /// silently passing the ordering check above.
    func test_theCensusIsReadingRealFiles() throws {
        for path in travelFiles {
            XCTAssertFalse(try source(path).isEmpty, "\(path): read nothing")
            XCTAssertFalse(try code(path).isEmpty,
                           "\(path): comment-stripping left nothing, so the "
                           + "tap-gesture census would pass vacuously")
        }
    }
}

// MARK: - Probe + hosting views

/// A window that reports itself key on demand — `.maughamTreeTravel` is
/// `.keyWindow` scoped (ADR 0021), so a window that never becomes key never
/// receives it. `PaletteWallDoorTests.KeyTestWindow`'s own reasoning, widened
/// with a flag so `TreeTravelReceiverTests` can drive the negative case too.
private final class TreeTravelKeyTestWindow: SilentTestWindow {
    var reportsKey = true
    override var isKeyWindow: Bool { reportsKey }
}

/// Holds the three values `TreeTravelModifier` reads and writes, outside the
/// view — `BinderSubjectProbe`'s own shape, widened for the persona and
/// detail segment `TreeTravelModifier` also owns. `window` is read back by
/// the receiver tests once `WindowAccessor` resolves it, so a post can be
/// scoped correctly without the test threading its own window reference
/// through two layers of `Binding`.
@Observable
@MainActor
final class TreeTravelProbe {
    var persona: Persona
    var detailSegment: DetailSegment
    var subject: BinderSubject?
    var window: NSWindow?
    let documentStore: DocumentStore?

    init(persona: Persona, detailSegment: DetailSegment,
        subject: BinderSubject? = nil, documentStore: DocumentStore? = nil) {
        self.persona = persona
        self.detailSegment = detailSegment
        self.subject = subject
        self.documentStore = documentStore
    }
}

/// The receiver alone — no tree, just the one-line mount
/// `ProjectWindow.body` carries, so a post can be driven straight at it.
@MainActor
private struct TreeTravelReceiverProbeView: View {
    let probe: TreeTravelProbe
    @State private var window: NSWindow?

    var body: some View {
        Color.clear
            .background(WindowAccessor(window: $window))
            .modifier(TreeTravelModifier(
                window: window,
                persona: Binding(get: { probe.persona }, set: { probe.persona = $0 }),
                detailSegment: Binding(get: { probe.detailSegment },
                                       set: { probe.detailSegment = $0 }),
                selectedSubject: Binding(get: { probe.subject }, set: { probe.subject = $0 }),
                documentStore: probe.documentStore))
            .onChange(of: window, initial: true) { _, new in probe.window = new }
    }
}

/// `BinderView` — as `BinderPaneToggle` mounts it — plus the real
/// `TreeTravelModifier` `ProjectWindow.body` mounts one line of.
@MainActor
private struct BinderTravelProbeView: View {
    let store: ProjectStore
    let probe: TreeTravelProbe
    let treeState: BinderTreeSectionsState
    @State private var window: NSWindow?

    var body: some View {
        BinderView(
            store: store,
            selectedSubject: Binding(get: { probe.subject }, set: { probe.subject = $0 }),
            treeState: treeState)
            .background(WindowAccessor(window: $window))
            .modifier(TreeTravelModifier(
                window: window,
                persona: Binding(get: { probe.persona }, set: { probe.persona = $0 }),
                detailSegment: Binding(get: { probe.detailSegment },
                                       set: { probe.detailSegment = $0 }),
                selectedSubject: Binding(get: { probe.subject }, set: { probe.subject = $0 }),
                documentStore: probe.documentStore))
            // The click tests wait on this before driving a double-click: the
            // receiver is `.keyWindow`-scoped and reads the window
            // `WindowAccessor` resolves a runloop hop after mount, so a click
            // sent before it lands drives a live poster at a dead receiver —
            // and reads exactly like a broken travel rule.
            .onChange(of: window, initial: true) { _, new in probe.window = new }
    }
}

/// `CollectionPiecesPane`'s own twin.
@MainActor
private struct CollectionPiecesTravelProbeView: View {
    let store: ProjectStore
    let probe: TreeTravelProbe
    let treeState = BinderTreeSectionsState()
    @State private var renamingItemId: String?
    @State private var window: NSWindow?

    var body: some View {
        CollectionPiecesPane(
            store: store,
            selectedSubject: Binding(get: { probe.subject }, set: { probe.subject = $0 }),
            renamingItemId: $renamingItemId,
            treeState: treeState)
            .background(WindowAccessor(window: $window))
            .modifier(TreeTravelModifier(
                window: window,
                persona: Binding(get: { probe.persona }, set: { probe.persona = $0 }),
                detailSegment: Binding(get: { probe.detailSegment },
                                       set: { probe.detailSegment = $0 }),
                selectedSubject: Binding(get: { probe.subject }, set: { probe.subject = $0 }),
                documentStore: probe.documentStore))
    }
}

/// `SceneNavigatorPane`'s own twin — as `BinderPaneToggle` mounts it
/// (`SceneNavigatorProjectRowTests.SceneNavigatorProbeView`'s shape).
@MainActor
private struct SceneNavigatorTravelProbeView: View {
    let store: ProjectStore
    let probe: TreeTravelProbe
    let treeState = BinderTreeSectionsState()
    @State private var window: NSWindow?

    var body: some View {
        SceneNavigatorPane(
            store: store,
            script: nil,
            projectTitle: "Screenplay",
            selectedSubject: Binding(get: { probe.subject }, set: { probe.subject = $0 }),
            documentID: "doc-1",
            treeState: treeState,
            onSelect: { _ in })
            .background(WindowAccessor(window: $window))
            .modifier(TreeTravelModifier(
                window: window,
                persona: Binding(get: { probe.persona }, set: { probe.persona = $0 }),
                detailSegment: Binding(get: { probe.detailSegment },
                                       set: { probe.detailSegment = $0 }),
                selectedSubject: Binding(get: { probe.subject }, set: { probe.subject = $0 }),
                documentStore: probe.documentStore))
    }
}
