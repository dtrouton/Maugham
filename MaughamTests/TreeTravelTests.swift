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
/// **Why not a real synthetic double-click.** It was tried first: every row
/// this milestone touches is `.draggable`, and `-[NSTableView mouseDown:]` on
/// a draggable row enters AppKit's own drag-vs-click disambiguation
/// (`_dragShouldBeginFromMouseDown:`), which blocks on the real
/// `nextEventMatchingMask:untilDate:inMode:dequeue:` waiting for a
/// windowserver event a synthetic host never sends — measured directly with
/// `sample` on a run that never returned. Routing every event through
/// `NSApp.postEvent`/`NSApp.nextEvent` instead of `window.sendEvent(_:)`
/// stopped the hang, but the `.onTapGesture(count: 2)` recognizer itself
/// never fired for either synthetic timing tried (all-at-once, and a real
/// 50ms gap between the two presses) — zero posts observed both times. No
/// other suite in this codebase drives a SwiftUI `.onTapGesture` through
/// synthetic AppKit events (`grep -rn "clickCount: 2" MaughamTests/` outside
/// this file turns up nothing), so there is no established technique to
/// reach for here. `TreeTravelGestureAttachmentTests` covers the half a
/// mounted click can't prove safely: that the gesture is textually on the
/// label leaf and not the row container.
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

    /// A single click — the first half of any double-click — must only
    /// select. The dim moves (a subject write via `List(selection:)`); the
    /// persona does not, because `.maughamTreeTravel` is never posted by one
    /// click alone.
    func test_aSingleClickOnTheChapterRowOnlySelects() async throws {
        let store = try await novel(named: "SingleClick")
        let firstDoc = try XCTUnwrap(store.manifest.structure.first)
        let (window, probe, table) = try await hostBinder(store: store)

        await click(row: 1, in: table, window: window)
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
    private func click(row: Int, in table: NSTableView, window: NSWindow) async {
        let rect = table.rect(ofRow: row)
        let point = CGPoint(x: rect.midX, y: rect.midY)
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
        for (type, count) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 1)] {
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

// MARK: - Source census: the gesture is on the label leaf, not the row

/// **Tripwire 9's own check, as a census** — `TreeTravelReceiverTests`' class
/// doc records why a mounted double-click can't prove this directly. The
/// TaskRow scar this rule is named after (`TaskRow.swift:36-45`) is exactly
/// this failure: a row-wide `.simultaneousGesture(TapGesture(count: 2))` ate
/// drag initiation across the row's whole interior. So this reads the files
/// named in `test_theGestureAttachesBeforeTheRowWidens`'s own `expectations`
/// array — not counted here, so a row kind added later cannot go stale in
/// prose while the array right below it grows — and checks the ONE thing
/// that failure shape turns on: the gesture line sits BEFORE the row's own
/// `.tag`/`.contentShape`/`.draggable` widen the interactive area — i.e.,
/// attached to the label's own (smaller) view, not the container those calls
/// widen onto.
final class TreeTravelGestureAttachmentTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func lineIndex(of needle: String, in lines: [Substring]) -> Int? {
        lines.firstIndex(where: { $0.contains(needle) })
    }

    /// The gesture line belonging to THIS `widenLine` — the nearest
    /// `.treeTravelOnDoubleClick(` occurrence at or before it, never the
    /// file's first — so a file carrying more than one row (`SceneNavigatorPane
    /// .swift`'s project row AND its own script row, both gesture-bearing)
    /// pairs each widening call with the gesture actually above IT, rather
    /// than one row's gesture silently vouching for a different row's widen
    /// call by virtue of coming first in the file.
    private func nearestGestureLine(before widenLine: Int, in lines: [Substring]) -> Int? {
        lines[0..<widenLine].lastIndex(where: { $0.contains(".treeTravelOnDoubleClick(") })
    }

    /// One row kind per case: the file, and the call that widens the row
    /// AFTER the gesture must already be attached — `.draggable(` for every
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
            // `SceneNavigatorPane`'s SECOND gesture-bearing row: the script
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
                + "\(expectation.widensAt) at all — the travel gesture is "
                + "missing outright for this row")
            XCTAssertLessThan(gestureLine, widenLine,
                              "\(expectation.file): .treeTravelOnDoubleClick must "
                              + "come BEFORE \(expectation.widensAt) — attached "
                              + "after it, the gesture sits on the ROW's own "
                              + "widened interactive area rather than the label "
                              + "leaf, which is the TaskRow.swift trap")
        }
    }

    /// The control every absence-shaped/ordering assertion needs: the files
    /// are really being read, so a path typo fails loudly here rather than
    /// silently passing the ordering check above.
    func test_theCensusIsReadingRealFiles() throws {
        for path in ["Maugham/Views/BinderRow.swift", "Maugham/Views/PieceRow.swift",
                     "Maugham/Views/ResearchRow.swift",
                     "Maugham/Views/BinderTreeSections.swift",
                     "Maugham/Views/BinderView.swift",
                     "Maugham/Views/CollectionPiecesPane.swift",
                     "Maugham/Views/SceneNavigatorPane.swift",
                     "Maugham/Views/TreeTravel.swift"] {
            XCTAssertFalse(try source(path).isEmpty, "\(path): read nothing")
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
