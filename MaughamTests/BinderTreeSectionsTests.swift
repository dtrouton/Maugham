import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The Research and Palette sections, in all three trees** (shell-finish
/// stage-2a Task 4).
///
/// Every persona gets ONE left column, so the sections are not a pane the writer
/// switches to — they are furniture at the foot of whichever tree the project
/// type puts up. There are three of those (`BinderView` for prose,
/// `CollectionPiecesPane` for a Collection, `SceneNavigatorPane` for a
/// screenplay) and the whole point of the milestone is that a writer cannot tell
/// which one they are looking at from the sections' behaviour. So every
/// assertion here is asked of all three.
///
/// **Mounted, not reasoned about**, for the reason `BinderProjectRowTests`
/// records: a row's whole implementation is a label and a `.tag`, and whether
/// `List(selection:)` matches that tag is exactly what a test built out of the
/// view's own data cannot see.
@MainActor
final class BinderTreeSectionsTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    /// Every fixture opens one — `addResearchTextNote` and `addPaletteCard`
    /// write through the typed mover and refuse outright without it. Closed in
    /// teardown so their autosave schedulers do not outlive the test.
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

    // MARK: - The sections exist, below everything the tree already had

    func test_theNovelTreeGrowsBothSectionsBelowItsChapters() async throws {
        let store = try await novel(notes: ["Ships", "Tides"], cards: ["Harbour"])
        let (window, _) = try await hostBinder(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))

        let chapters = store.manifest.structure.count
        XCTAssertEqual(
            table.numberOfRows,
            1 + chapters + (1 + 2) + (1 + 1),
            "the project row, the chapters, then a Research section (header + "
            + "two notes) and a Palette section (header + one card)")
    }

    func test_theCollectionTreeGrowsBothSectionsBelowItsPieces() async throws {
        let store = try await collection(pieces: ["One"],
                                         notes: ["Ships", "Tides"], cards: ["Harbour"])
        let (window, _) = try await hostCollection(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertEqual(
            table.numberOfRows,
            1 + store.manifest.structure.count + (1 + 2) + (1 + 1),
            "the project row, the pieces, then both sections")
    }

    func test_theScreenplayTreeGrowsBothSectionsBelowItsSluglines() async throws {
        let store = try await screenplay(notes: ["Ships", "Tides"], cards: ["Harbour"])
        let (window, _, _) = try await hostNavigator(store: store, script: Self.twoScenes)
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertEqual(
            table.numberOfRows,
            1 + 1 + 2 + (1 + 2) + (1 + 1),
            "the project row, the script row, the two sluglines, then both sections")
    }

    // MARK: - The Figures section (report plan 8a Task 4)

    /// Two figures the window's listing would give: one numbered, one unused.
    private func plantedFigures() -> BinderTreeSectionsState {
        let state = BinderTreeSectionsState()
        state.refreshFigureRows(listing: [
            FigureListing.Row(figureId: "fig-0a1b2c3d", kind: .table, name: "cash",
                              caption: "Cash", number: "Table 1", usedIn: [],
                              referencedFrom: [], pieceOfLine: nil),
            FigureListing.Row(figureId: "fig-1a1b2c3d", kind: .table, name: "spare",
                              caption: "", number: FigureListing.unusedNumber, usedIn: [],
                              referencedFrom: [], pieceOfLine: nil)])
        return state
    }

    /// **Between the manuscript and Research** (spec §7), in the tree's one
    /// `List`, and a figure row is a subject of the window like any other —
    /// selected through `List(selection:)`, tagged `.figure(id)`.
    func test_theNovelTreeDrawsTheFiguresSectionBetweenItsChaptersAndResearch() async throws {
        let store = try await novel(notes: ["Ships", "Tides"], cards: ["Harbour"])
        let (window, probe) = try await hostBinder(store: store, treeState: plantedFigures())
        let table = try XCTUnwrap(firstTableView(in: window))

        let chapters = store.manifest.structure.count
        XCTAssertEqual(table.numberOfRows, 1 + chapters + (1 + 2) + (1 + 2) + (1 + 1),
                       "the project row, the chapters, the Figures section (header + two "
                       + "figures), then Research and Palette")

        await select(row: 1 + chapters + 1, in: table,
                     until: { probe.subject == .figure("fig-0a1b2c3d") })
        XCTAssertEqual(probe.subject, .figure("fig-0a1b2c3d"),
                       "the first figure row is the Figures section's first row")
    }

    /// **The piece row's figure count takes its own click** (review I2): it
    /// is the first `Button` inside a `.draggable` tree row, and `.draggable`
    /// is known to intercept a child control (BinderRow's rename split). A
    /// real click at the count's centre must filter the section to the
    /// chapter and must not select the chapter's row.
    ///
    /// The count is found by its focus-ring view inside the chapter's row, so
    /// the click lands where the button is drawn on whatever display this runs.
    /// The window reads as key, as the writer's does: since Xcode 27B47 a
    /// click on a row in a window that is not key selects nothing (measured
    /// 2026-10-30: hit point on the row's cell, `selectedRow` -1 either
    /// delivery), while the count's `Button` still takes it.
    func test_aClickOnAPieceRowsFigureCountFiltersAndSelectsNothing() async throws {
        let store = try await novel(notes: [], cards: [])
        let chapter = try XCTUnwrap(TreeWalk.first(in: store.manifest.structure,
                                                   where: { $0.type == .document }))
        let state = BinderTreeSectionsState()
        state.refreshFigureRows(listing: [
            FigureListing.Row(figureId: "fig-0a1b2c3d", kind: .table, name: "cash",
                              caption: "Cash", number: "Table 1",
                              usedIn: [FigureListing.Use(docId: chapter.id, lineIndex: 0)],
                              referencedFrom: [], pieceOfLine: chapter.id)])
        let (window, probe) = try await hostBinder(store: store, treeState: state, key: true)
        let table = try XCTUnwrap(firstTableView(in: window))
        let rowIndex = 1 + (store.manifest.structure.firstIndex { $0.id == chapter.id } ?? 0)
        let rowRect = table.convert(table.rect(ofRow: rowIndex), to: nil)
        // The count is the row's one control: SwiftUI mounts a focus-ring view
        // for a `Button(.plain)` (as for the section chevrons), which is where
        // the button is drawn on whatever display this runs.
        var all: [NSView] = []
        collect(NSView.self, in: try XCTUnwrap(window.contentView), into: &all)
        let rings = all.map { $0.convert($0.bounds, to: nil) }
            .enumerated().filter { String(describing: type(of: all[$0.offset])).contains("FocusRing") }
            .map(\.element).filter { $0.intersects(rowRect) }
        XCTAssertEqual(rings.count, 1, "the chapter row draws one control, its count: \(rings)")
        let ring = try XCTUnwrap(rings.first)
        let point = CGPoint(x: ring.midX, y: ring.midY)
        let subjectBefore = probe.subject
        // The premise, asked as TreeTravelTests asks it (a no-op unless the
        // run opts in with MAUGHAM_ALLOW_ACTIVATION=1, as CI does).
        _ = await TestWindow.activate(window)

        clickCount(at: point, in: window)
        await pumpUntil(deadline: 3) { state.pieceFilter != nil }
        let filterAfterCount = state.pieceFilter, subjectAfterCount = probe.subject

        // Control, and the measurement, BEFORE any assertion: the same click on
        // the row's title, away from the count, does select it — so "selects
        // nothing" below is the button's doing, not a click that never reached
        // the table; a window that takes no clicks at all is skipped by name.
        let title = CGPoint(x: rowRect.minX + 60, y: rowRect.midY)
        clickCount(at: title, in: window)
        await pumpUntil(deadline: 3) { probe.subject == .item(chapter.id) }
        try skipIfTheClickWasNeverDelivered(at: table.convert(title, from: nil), in: table)

        XCTAssertEqual(filterAfterCount, chapter.id,
                       "the click on the count did not reach its button — the row's "
                       + "drag or selection took it")
        XCTAssertEqual(subjectAfterCount, subjectBefore,
                       "the count's click selected the chapter row; it must select nothing")
        XCTAssertEqual(probe.subject, .item(chapter.id))
    }

    /// **Raised after the control click, on a measurement** — TreeTravelTests'
    /// discriminator: the host is not the active app AND the row under the
    /// point is not the row that ended up selected, i.e. AppKit never turned
    /// the events into a click (a locked screen). Never on `NSApp.isActive`
    /// alone: where the click lands, nothing is skipped.
    private func skipIfTheClickWasNeverDelivered(at point: CGPoint, in table: NSTableView,
                                                 function: StaticString = #function) throws {
        let row = table.row(at: point)
        guard !NSApplication.shared.isActive, row >= 0, table.selectedRow != row else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        throw XCTSkip(
            "\(function): the synthetic click on row \(row) was measurably not delivered "
            + "(`selectedRow` \(table.selectedRow)) and the test host is not the active app "
            + "(frontmost: \(frontmost)) — a locked screen, or a front app that will not yield. "
            + "Set TEST_RUNNER_MAUGHAM_ALLOW_ACTIVATION=1 to ask for activation.")
    }

    /// One real click (down, up) at `point`, in window coordinates, as
    /// `TreeTravelRowMountingTests.click(at:)` delivers it: the app's queue
    /// drained until it stays quiet (a stale `appKitDefined` event left by
    /// ordering the window front would be read by the table's tracking loop
    /// in place of this click's mouseUp), then the pair posted to `NSApp` and
    /// dispatched as AppKit's own loop would.
    private func clickCount(at point: CGPoint, in window: NSWindow) {
        let app = NSApplication.shared
        var quietPolls = 0
        while quietPolls < 3 {
            if let stray = app.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                app.sendEvent(stray)
                quietPolls = 0
            } else {
                quietPolls += 1
            }
            pump(0.02)
        }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0) {
                app.postEvent(event, atStart: false)
            }
        }
        while let next = app.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
            app.sendEvent(next)
            pump(0.02)
        }
    }

    /// A screenplay's manuscript holds no figures: the same rows draw nothing.
    func test_theScreenplayTreeDrawsNoFiguresSection() async throws {
        let store = try await screenplay(notes: ["Ships", "Tides"], cards: ["Harbour"])
        let (window, _, _) = try await hostNavigator(store: store, script: Self.twoScenes,
                                                     treeState: plantedFigures())
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertEqual(table.numberOfRows, 1 + 1 + 2 + (1 + 2) + (1 + 1),
                       "the screenplay tree is what it was: no Figures section")
    }

    /// **The palette group is not research.** It is a research group on disk —
    /// `addPaletteCard` writes under `research/palette/` — so a tree that renders
    /// `manifest.research` raw shows it twice: once as a group in Research and
    /// once as the Palette section. `TreeSectionDerivation.sharedResearchRoots`
    /// is what filters it, and this is the mounted proof it is being called.
    func test_thePaletteGroupIsNotAlsoARowInTheResearchSection() async throws {
        let store = try await novel(notes: ["Ships"], cards: ["Harbour"])
        XCTAssertNotNil(store.paletteGroup(), "fixture precondition: a palette group exists")

        let (window, _) = try await hostBinder(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertEqual(
            table.numberOfRows,
            1 + store.manifest.structure.count + (1 + 1) + (1 + 1),
            "Research must hold the ONE note and not the palette group beside it")
    }

    // MARK: - Selecting a research row, through the list

    func test_aResearchRowInTheNovelTreeMakesItselfTheSubject() async throws {
        let store = try await novel(notes: ["Ships"], cards: ["Harbour"])
        let (window, probe) = try await hostBinder(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))
        let note = try XCTUnwrap(researchNote(named: "Ships", in: store))

        let row = 1 + store.manifest.structure.count + 1
        await select(row: row, in: table, until: { probe.subject == .research(note.id) })

        XCTAssertEqual(probe.subject, .research(note.id),
                       "a research row is a subject of the window like any other")
    }

    func test_aResearchRowInTheCollectionTreeMakesItselfTheSubject() async throws {
        let store = try await collection(pieces: ["One"], notes: ["Ships"], cards: ["Harbour"])
        let (window, probe) = try await hostCollection(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))
        let note = try XCTUnwrap(researchNote(named: "Ships", in: store))

        let row = 1 + store.manifest.structure.count + 1
        await select(row: row, in: table, until: { probe.subject == .research(note.id) })

        XCTAssertEqual(probe.subject, .research(note.id))
    }

    func test_aResearchRowInTheScreenplayTreeMakesItselfTheSubject() async throws {
        let store = try await screenplay(notes: ["Ships"], cards: ["Harbour"])
        let (window, probe, _) = try await hostNavigator(store: store, script: Self.twoScenes)
        let table = try XCTUnwrap(firstTableView(in: window))
        let note = try XCTUnwrap(researchNote(named: "Ships", in: store))

        // project, script, two sluglines, Research header, then the note.
        await select(row: 5, in: table, until: { probe.subject == .research(note.id) })

        XCTAssertEqual(probe.subject, .research(note.id),
                       "the navigator's projection has to let a research write "
                       + "through — its List now draws rows that mean one")
    }

    // MARK: - Selecting a palette card, through the list

    /// A palette card IS a research item (`PaletteCard.id == researchItemId`), so
    /// it takes the same subject case. This is the mounted proof the tree agrees
    /// with that — a `.paletteCard` case would have been a second name for one id.
    func test_aPaletteCardRowMakesItselfTheSubjectInEveryTree() async throws {
        let novelStore = try await novel(notes: ["Ships"], cards: ["Harbour"])
        let (novelWindow, novelProbe) = try await hostBinder(store: novelStore)
        let novelTable = try XCTUnwrap(firstTableView(in: novelWindow))
        let novelCard = try XCTUnwrap(novelStore.loadPaletteCards().first)
        let novelRow = 1 + novelStore.manifest.structure.count + 2 + 1
        await select(row: novelRow, in: novelTable,
                     until: { novelProbe.subject == .research(novelCard.id) })
        XCTAssertEqual(novelProbe.subject, .research(novelCard.id), "novel tree")

        let collectionStore = try await collection(
            pieces: ["One"], notes: ["Ships"], cards: ["Harbour"])
        let (collectionWindow, collectionProbe) = try await hostCollection(store: collectionStore)
        let collectionTable = try XCTUnwrap(firstTableView(in: collectionWindow))
        let collectionCard = try XCTUnwrap(collectionStore.loadPaletteCards().first)
        let collectionRow = 1 + collectionStore.manifest.structure.count + 2 + 1
        await select(row: collectionRow, in: collectionTable,
                     until: { collectionProbe.subject == .research(collectionCard.id) })
        XCTAssertEqual(collectionProbe.subject, .research(collectionCard.id), "collection tree")

        let screenplayStore = try await screenplay(notes: ["Ships"], cards: ["Harbour"])
        let (screenplayWindow, screenplayProbe, _) = try await hostNavigator(
            store: screenplayStore, script: Self.twoScenes)
        let screenplayTable = try XCTUnwrap(firstTableView(in: screenplayWindow))
        let screenplayCard = try XCTUnwrap(screenplayStore.loadPaletteCards().first)
        await select(row: 7, in: screenplayTable,
                     until: { screenplayProbe.subject == .research(screenplayCard.id) })
        XCTAssertEqual(screenplayProbe.subject, .research(screenplayCard.id), "screenplay tree")
    }

    // MARK: - Managing a card from the tree (final review's I2)

    /// **A card can be deleted again.** Every palette management verb lived on
    /// `ResearchView`'s rows and died with that pane in Task 7 — and the
    /// capability census missed it, because 2a's palette rows were already bare
    /// `Label`s: there was nothing on the tree for the deletion to take away, so
    /// nothing went red and nothing looked lost. A writer could make a card and
    /// edit it and never remove it, from any surface in the app.
    ///
    /// Driven through the bundle the row's menu calls — a `contextMenu` button
    /// is not pressable headlessly, which is the same reason the drop verbs are
    /// asked of `actions` directly one section down — and asserted on the tree:
    /// the row goes, not just the manifest entry.
    func test_aPaletteCardCanBeDeletedFromTheTree() async throws {
        // TWO cards, so the row that goes is not replaced by the empty
        // section's placeholder — deleting the last one leaves the count
        // unchanged and would say nothing about the row.
        let store = try await novel(notes: [], cards: ["Harbour", "Quay"])
        let card = try XCTUnwrap(store.loadPaletteCards().first)
        let (window, _) = try await hostBinder(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))
        let before = table.numberOfRows
        XCTAssertTrue(store.paletteCardItems().contains { $0.id == card.id },
                      "premise: the card is in the palette group")

        let state = BinderTreeSectionsState()
        BinderTreeSections(store: store, state: state,
                           selectedSubject: .constant(nil))
            .actions.delete(card.id)
        await pumpUntil(deadline: 5) { store.paletteCardItems().count == 1 }

        XCTAssertFalse(store.paletteCardItems().contains { $0.id == card.id },
                      "the card is still in the palette group — a card is an "
                      + "ordinary research document and `deleteResearchItem` is "
                      + "its verb. The verb's own error: "
                      + "\(state.pendingError ?? "none")")
        await pumpUntil(deadline: 5) { table.numberOfRows == before - 1 }
        XCTAssertEqual(table.numberOfRows, before - 1,
                       "…and its row is still in the tree")
    }

    /// The other verb, and the control that keeps the one above from passing
    /// against a bundle that only ever destroys.
    func test_aPaletteCardCanBeDuplicatedFromTheTree() async throws {
        let store = try await novel(notes: [], cards: ["Harbour"])
        let card = try XCTUnwrap(store.loadPaletteCards().first)
        let (window, _) = try await hostBinder(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))
        let before = table.numberOfRows

        BinderTreeSections(store: store, state: BinderTreeSectionsState(),
                           selectedSubject: .constant(nil))
            .actions.duplicate(card.id)
        await pumpUntil(deadline: 5) { store.paletteCardItems().count == 2 }

        XCTAssertEqual(store.paletteCardItems().count, 2,
                       "Duplicate must make a second card in the palette group")
        await pumpUntil(deadline: 5) { table.numberOfRows == before + 1 }
        XCTAssertEqual(table.numberOfRows, before + 1)
    }

    /// **The row's own affordances, censused** — the menu and the drag are the
    /// two halves no headless test can press, and they are exactly what went
    /// missing without a red test. A card drags by its BARE id because that is
    /// the canvas's drop contract; the Inbox's prefixed payload is the one
    /// exception in the app and declares itself at its own site.
    func test_thePaletteRowsCarryTheirVerbsAndTheirDrag() throws {
        let text = try source("Maugham/Views/BinderTreeSections.swift")
        XCTAssertTrue(text.contains(".draggable(card.id)"),
                      "a palette card must drag by its bare research id — the "
                      + "canvas derives its node id from exactly that")
        XCTAssertTrue(text.contains(".contextMenu { paletteRowMenu(for: card) }"),
                      "the palette rows are bare Labels again — no delete, no "
                      + "duplicate, no way to remove a card from anywhere")
        XCTAssertTrue(text.contains("actions.duplicate(card.id)")
                      && text.contains("actions.delete(card.id)"),
                      "the row's verbs must be the shared bundle's, not a "
                      + "second spelling of the store calls")
        // The menu's own body, read on its own: Move to would take the card out
        // of the palette group — which is what makes it a card — and Rename
        // belongs to `PaletteCardEditor`, whose title is the card's H1.
        let menu = try XCTUnwrap(
            text.range(of: "private func paletteRowMenu").map { start in
                String(text[start.lowerBound...].prefix(900))
            },
            "the palette row's menu builder is gone")
        for absent in ["Move to", "Rename"] {
            XCTAssertFalse(menu.contains(absent),
                           "\(absent) must not be offered on a palette row — see "
                           + "`paletteRowMenu`'s own doc comment for which "
                           + "surface owns it instead")
        }
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path),
                          encoding: .utf8)
    }

    // MARK: - The project row is still row zero

    func test_theProjectRowIsStillRowZeroInEveryTree() async throws {
        let novelStore = try await novel(notes: ["Ships"], cards: ["Harbour"])
        let (novelWindow, novelProbe) = try await hostBinder(store: novelStore)
        await select(row: 0, in: try XCTUnwrap(firstTableView(in: novelWindow)),
                     until: { novelProbe.subject == .project })
        XCTAssertEqual(novelProbe.subject, .project, "novel tree")

        let collectionStore = try await collection(
            pieces: ["One"], notes: ["Ships"], cards: ["Harbour"])
        let (collectionWindow, collectionProbe) = try await hostCollection(store: collectionStore)
        await select(row: 0, in: try XCTUnwrap(firstTableView(in: collectionWindow)),
                     until: { collectionProbe.subject == .project })
        XCTAssertEqual(collectionProbe.subject, .project, "collection tree")

        let screenplayStore = try await screenplay(notes: ["Ships"], cards: ["Harbour"])
        let (screenplayWindow, screenplayProbe, _) = try await hostNavigator(
            store: screenplayStore, script: Self.twoScenes)
        await select(row: 0, in: try XCTUnwrap(firstTableView(in: screenplayWindow)),
                     until: { screenplayProbe.subject == .project })
        XCTAssertEqual(screenplayProbe.subject, .project, "screenplay tree")
    }

    // MARK: - The empty sections

    /// The headers are furniture: they are there whether or not the writer has
    /// made anything yet, because a section that appears and disappears is not a
    /// place. Each empty one carries exactly ONE placeholder row — Task 7's
    /// drop target, and the affordance that says where a note would land.
    func test_anEmptySectionKeepsItsHeaderAndCarriesOnePlaceholderRow() async throws {
        let store = try await novel(notes: [], cards: [])
        XCTAssertTrue(store.manifest.research.isEmpty, "fixture precondition")

        let (window, _) = try await hostBinder(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertEqual(
            table.numberOfRows,
            1 + store.manifest.structure.count + (1 + 1) + (1 + 1),
            "each empty section is its header plus one placeholder row")
    }

    /// **The placeholder row must not become the subject, and must not clear
    /// it.** `BinderView` measured (macOS 26.5) that an untagged row is selected
    /// anyway and writes `nil` through the binding — which blanks the centre
    /// column. That measurement is why the empty state is an overlay rather than
    /// a row; the placeholder rows re-open exactly that hazard, so every tree's
    /// selection binding refuses a `nil` write.
    func test_clickingAnEmptySectionsPlaceholderLeavesTheSubjectAlone() async throws {
        let store = try await novel(notes: [], cards: [])
        let (window, probe) = try await hostBinder(store: store)
        let table = try XCTUnwrap(firstTableView(in: window))

        await select(row: 0, in: table, until: { probe.subject == .project })
        XCTAssertEqual(probe.subject, .project, "precondition")

        // The Research section's placeholder: header, then the row.
        let placeholder = 1 + store.manifest.structure.count + 1
        // fixed window: asserting an absence — the subject must still be there
        // after the placeholder's write has had its full chance to arrive.
        await select(row: placeholder, in: table)

        XCTAssertEqual(probe.subject, .project,
                       "a placeholder row is not a subject — selecting one must "
                       + "leave the window's subject exactly where it was")
    }

    /// The plant for the test above. Bound straight to the subject — the shape
    /// anyone writes first — the same untagged placeholder DOES clear it.
    func test_plantedOffender_aPlaceholderRowOnANaiveBindingClearsTheSubject() async throws {
        let probe = BinderSubjectProbe(.project)
        let window = try await mount(AnyView(NaivePlaceholderOffender(probe: probe)))
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertEqual(probe.subject, .project, "precondition")
        // fixed window: the assertion below is an XCTAssertNil, and a plant that
        // failed to fire looks exactly like one that has not landed yet.
        await select(row: 2, in: table)

        XCTAssertNil(probe.subject,
                     "PLANT DID NOT FIRE: an untagged placeholder row was "
                     + "expected to write nil through a direct binding. If this "
                     + "is nil-safe on this macOS then the trees' nil-refusing "
                     + "selection binding is guarding nothing and the test above "
                     + "is vacuous — read the finding, do not delete this test")
    }

    // MARK: - Creating from a header selects the new thing (fix round 1)

    /// **Add Link is a creation verb, so it points the window at the link.**
    ///
    /// It shipped discarding the created item, which made it the one verb on
    /// these headers that left the writer looking at whatever they were looking
    /// at before — and a regression against both panes the tree replaces, which
    /// have always selected a new link. New Note, New Group and New Card all go
    /// through `create`, which does the same thing; only the link, which needs a
    /// sheet, went the long way round and lost it.
    func test_addLinkPointsTheWindowAtTheLinkItMade() async throws {
        let store = try await novel(notes: [], cards: [])
        let probe = BinderSubjectProbe(.project)
        let state = BinderTreeSectionsState()

        await BinderTreeSections.addLink(
            title: "Tide tables", url: "https://example.invalid/tides",
            parentId: nil, store: store, state: state,
            selectedSubject: Binding(get: { probe.subject },
                                     set: { probe.subject = $0 }))

        let link = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.research,
                           where: { $0.title == "Tide tables" }),
            "precondition: the link reached the manifest")
        XCTAssertEqual(probe.subject, .research(link.id),
                       "creating from a section header selects the new thing — "
                       + "the writer asked for a link, so the link is what the "
                       + "window is now about")
        XCTAssertNil(state.pendingRenameId,
                     "…but not into rename mode: the sheet already asked for "
                     + "the title, and asking twice is what both old panes "
                     + "deliberately avoid")
    }

    // MARK: - A drop the tree cannot route refuses (fix round 1, kept by Task 7)

    /// **A drop the tree cannot route must BOUNCE, not vanish.**
    ///
    /// `ResearchRow`'s `.dropDestination` used to `return true` unconditionally,
    /// so "accepted" was a property of the row rather than of the handler: a
    /// note dragged onto a populated research row animated home as accepted and
    /// was then silently discarded — the writer's drag, gone, with the
    /// animation that says it worked. The drop closures return `Bool` all the
    /// way down now.
    ///
    /// **Task 7 filled the routing and this test did not change**, which is the
    /// point of it: the ids here belong to nothing in the project, and an id the
    /// tree cannot place is refused by `TreeDropIntent` for exactly the reason
    /// the stub refused it. Where the drag CAN be routed is
    /// `BinderTreeDropRoutingTests`; that the row forwards this answer rather
    /// than a literal is `TripwireGrepTests`'.
    func test_theTreeRefusesADropItCannotPlace() async throws {
        let store = try await novel(notes: ["Ships"], cards: ["Harbour"])
        let target = try XCTUnwrap(researchNote(named: "Ships", in: store))
        let sections = BinderTreeSections(
            store: store,
            state: BinderTreeSectionsState(),
            selectedSubject: .constant(nil))

        XCTAssertFalse(
            sections.actions.internalDrop("some-other-id", .middle, target),
            "an id from outside this project — a canvas node, another window's "
            + "row — must bounce back to where the writer took it from. "
            + "Returning true accepts it and drops it on the floor")
        // **The external half is no longer a refusal, and that is stage-2b Task
        // 4's whole point.** A Finder file has no id to be unplaceable: what
        // decides it is the TARGET, and a shared research row is a scope the
        // tree can name. The refusals that remain are the target's — a
        // screenplay's script, a referenced piece, a stale row — and they are
        // asserted where the routing lives (`BinderTreeDropRoutingTests`,
        // `TreeDropIntentTests`).
        XCTAssertTrue(
            sections.actions.externalDrop([], .middle, target),
            "a research row is a scope the tree can import into — the drop is "
            + "accepted on the strength of the target, since whether the "
            + "providers yield anything is only knowable asynchronously (the "
            + "answer both replaced panes gave)")
    }

    /// …and the refusal it replaced still exists where a target really cannot
    /// take a file. Without this, "the external drop accepts" above would be
    /// indistinguishable from a route that accepts everything.
    func test_theTreeStillRefusesAnExternalDropOnATargetThatCannotTakeOne() async throws {
        let store = try await screenplay(notes: [], cards: [])
        let script = try XCTUnwrap(TreeWalk.first(
            in: store.manifest.structure, where: { $0.type == .document }))
        let verbs = BinderTreeVerbs(store: store, state: BinderTreeSectionsState(),
                                    selectedSubject: .constant(nil))

        XCTAssertFalse(
            verbs.routeExternalDrop(providers: [], position: .middle,
                                    target: .pieceRow(script.id)),
            "a screenplay keeps all its research shared, so its script row has "
            + "no scope a dropped file could be asking for — and the bounce is "
            + "what tells the writer, rather than a file appearing elsewhere")
    }

    /// **The anti-vacuity control, rebuilt on the tree's own verbs** (stage 2b
    /// Task 7). It used to be built on `ResearchView` — one of the two panes the
    /// tree replaced — because a control that genuinely ACCEPTS is what stops
    /// "refuses" above being a property of `ResearchTreeActions` itself rather
    /// than of the payload. Task 7 deleted the pane, and a resurrected one would
    /// be a control that tests nothing the app still does.
    ///
    /// So the control is the same bundle with a routable payload: a real
    /// research note, dragged onto a real research row in the same project. If
    /// `ResearchTreeActions` had become a type that always refuses, this would
    /// go red and the refusal above would stop meaning anything.
    func test_theSameBundleAcceptsTheDropsItCanRoute() async throws {
        let store = try await novel(notes: ["Ships", "Harbour"], cards: [])
        let target = try XCTUnwrap(researchNote(named: "Ships", in: store))
        let dragged = try XCTUnwrap(researchNote(named: "Harbour", in: store))
        let sections = BinderTreeSections(
            store: store,
            state: BinderTreeSectionsState(),
            selectedSubject: .constant(nil))

        XCTAssertTrue(
            sections.actions.internalDrop(dragged.id, .middle, target),
            "control: an id the tree CAN place is accepted through the very "
            + "same bundle — so 'refuses' above is a property of the payload, "
            + "not of the type every caller shares")
    }

    // MARK: - The disclosure state (stage-3a Task 4)

    /// **Both sections start open**, which is the shape the tree shipped with:
    /// before this task neither `Section` took a binding at all and SwiftUI drew
    /// them expanded. The state exists so something can CLOSE them and something
    /// else can open them again — not to change what a writer sees on a fresh
    /// window.
    ///
    /// Groups start closed for the same reason: a `DisclosureGroup` with no
    /// binding is closed, and `expandedResearchGroups` holding the OPEN ids is
    /// what keeps an empty set meaning exactly what SwiftUI's own default meant.
    func test_theSectionsStartOpenAndTheGroupsStartClosed() {
        let state = BinderTreeSectionsState()
        XCTAssertTrue(state.researchSectionExpanded)
        XCTAssertTrue(state.paletteSectionExpanded)
        XCTAssertTrue(state.expandedResearchGroups.isEmpty)
    }

    /// **A reveal opens the section AND every group between the item and the
    /// root.** Opening the section alone would leave a nested note as invisible
    /// as it was — the ancestors are the whole of what a writer would otherwise
    /// have to click through by hand.
    func test_revealOpensTheSectionAndEveryAncestorGroup() async throws {
        let store = try await novel(notes: [], cards: [])
        let outer = try await store.addResearchItem(
            parentId: nil, title: "World", kind: nil)
        let inner = try await store.addResearchItem(
            parentId: outer.id, title: "Maps", kind: nil)
        let note = try await store.addResearchTextNote(
            parentId: inner.id, title: "Harbour")

        let state = BinderTreeSectionsState()
        state.researchSectionExpanded = false

        let shown = state.reveal(note.id, structure: store.manifest.structure,
                                 research: store.manifest.research,
                                 projectType: store.manifest.type)

        XCTAssertEqual(shown, .research(note.id),
                       "and it answers with the row the tree can now show — "
                       + "the scroll target its caller needs")
        XCTAssertTrue(state.researchSectionExpanded,
                      "the section holding the item opens")
        XCTAssertEqual(state.expandedResearchGroups, [outer.id, inner.id],
                       "and so does every group between the item and the root — "
                       + "an item inside a closed group is not revealed by "
                       + "opening the section over it")
    }

    /// A card is a research item under the palette group, and the Palette
    /// section is where it is drawn — so revealing one opens THAT section and
    /// leaves the Research section exactly as the writer left it.
    func test_revealingACardOpensThePaletteSectionAndNotTheResearchOne() async throws {
        let store = try await novel(notes: ["Ships"], cards: ["Harbour"])
        let card = try XCTUnwrap(researchNote(named: "Harbour", in: store))

        let state = BinderTreeSectionsState()
        state.researchSectionExpanded = false
        state.paletteSectionExpanded = false

        let shown = state.reveal(card.id, structure: store.manifest.structure,
                                 research: store.manifest.research,
                                 projectType: store.manifest.type)

        XCTAssertEqual(shown, .research(card.id),
                       "a card's row is its own subject, section or no section")
        XCTAssertTrue(state.paletteSectionExpanded, "the card's own section")
        XCTAssertFalse(state.researchSectionExpanded,
                       "and not the other one — a reveal opens what holds the "
                       + "item, not everything")
        XCTAssertTrue(state.expandedResearchGroups.isEmpty,
                      "the palette group is not an ancestor the Research "
                      + "section draws: its cards are flat rows of their own "
                      + "section, so opening it would open a group nothing shows")
    }

    /// An id the manifest does not hold names no row, so there is nothing to
    /// reveal and nothing to open. Asserted rather than left to fall out: the
    /// alternative shape — open the Research section on anything — would move a
    /// writer's tree for a stale id arriving from a deleted note's Show banner.
    func test_revealingSomethingTheManifestDoesNotHoldOpensNothing() async throws {
        let store = try await novel(notes: ["Ships"], cards: [])
        let state = BinderTreeSectionsState()
        state.researchSectionExpanded = false
        state.paletteSectionExpanded = false

        let shown = state.reveal("no-such-item", structure: store.manifest.structure,
                                 research: store.manifest.research,
                                 projectType: store.manifest.type)

        XCTAssertNil(shown, "an id in no tree names no row to scroll to")
        XCTAssertFalse(state.researchSectionExpanded)
        XCTAssertFalse(state.paletteSectionExpanded)
        XCTAssertTrue(state.expandedResearchGroups.isEmpty)
        XCTAssertTrue(state.expandedPieceFolds.isEmpty)
    }

    /// **The reveal only ever opens.** A second reveal of a note in one group
    /// must not close the group the writer opened for another — the state is a
    /// set of open ids, and revealing is an insert, never an assignment.
    func test_revealNeverClosesWhatTheWriterOpened() async throws {
        let store = try await novel(notes: [], cards: [])
        let first = try await store.addResearchItem(
            parentId: nil, title: "World", kind: nil)
        let second = try await store.addResearchItem(
            parentId: nil, title: "People", kind: nil)
        let note = try await store.addResearchTextNote(
            parentId: second.id, title: "Harbour")

        let state = BinderTreeSectionsState()
        state.expandedResearchGroups = [first.id]

        state.reveal(note.id, structure: store.manifest.structure,
                     research: store.manifest.research,
                     projectType: store.manifest.type)

        XCTAssertEqual(state.expandedResearchGroups, [first.id, second.id],
                       "the group the writer had open is still open")
    }

    // MARK: - The fold opens for a reveal (stage-3b Task 7)

    /// **The regression this task exists for.** A collection piece's research
    /// lives in the piece's own folder and is drawn in that piece's FOLD — it is
    /// not in the shared Research section at all
    /// (`TreeSectionDerivation.sharedResearchRoots` filters `pieces/…` out). The
    /// old guard was `TreeWalk.contains` over the whole manifest, which a
    /// piece-scoped id passes, so the reveal opened the shared section — onto a
    /// list that does not hold the row — and left the fold that does hold it
    /// shut. Show a note Claude wrote into a piece and the writer got a tree
    /// that moved and still did not show the note.
    func test_revealingAPieceScopedNoteOpensThatPiecesFoldAndNotTheSharedSection() async throws {
        let store = try await collection(pieces: ["Alpha"], notes: [], cards: [])
        let piece = try XCTUnwrap(store.manifest.structure.first)
        let owned = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Alpha's Note")

        let state = BinderTreeSectionsState()
        state.researchSectionExpanded = false

        let shown = state.reveal(owned.id, structure: store.manifest.structure,
                                 research: store.manifest.research,
                                 projectType: store.manifest.type)

        XCTAssertEqual(state.expandedPieceFolds, [piece.id],
                       "the fold that actually holds the row opens")
        XCTAssertFalse(state.researchSectionExpanded,
                       "and the shared section does not — it does not hold this "
                       + "row, and opening it moves the writer's tree for nothing")
        XCTAssertEqual(shown, .item(piece.id),
                       "the row the tree can now show is the PIECE: a closed "
                       + "fold has no row of its own to scroll to, and its "
                       + "chevron is on the piece's row")
    }

    /// A group between the piece's root and the note opens too — the fold is a
    /// tree in a `.contained` piece, so opening the fold alone leaves a nested
    /// note exactly as hidden as the closed section used to.
    func test_revealingANoteInsideAFoldsGroupOpensTheGroupAsWell() async throws {
        let store = try await collection(pieces: ["Alpha"], notes: [], cards: [])
        let piece = try XCTUnwrap(store.manifest.structure.first)
        let group = try await store.addResearchItem(
            parentId: nil, title: "Sources", kind: nil)
        let child = try await store.addResearchTextNote(
            parentId: group.id, title: "A Clipping")
        try await store.moveResearchItems(ids: [group.id], to: .piece(piece.id))

        let state = BinderTreeSectionsState()
        let shown = state.reveal(child.id, structure: store.manifest.structure,
                                 research: store.manifest.research,
                                 projectType: store.manifest.type)

        XCTAssertEqual(state.expandedPieceFolds, [piece.id])
        XCTAssertTrue(state.expandedResearchGroups.contains(group.id),
                      "the group inside the fold is an ancestor like any other")
        XCTAssertEqual(shown, .item(piece.id))
    }

    /// **A novel chapter's fold is a view of SHARED items**, so a linked note is
    /// revealed through the shared section it actually lives in — the fold's
    /// duplicate row is a second drawing of that same item and needs no opening
    /// of its own. (Opening the chapter's fold instead would scroll the writer
    /// to a chapter for a note that is the project's.)
    func test_revealingALinkedNoteOpensTheSharedSectionAndNotTheChaptersFold() async throws {
        let store = try await novel(notes: ["Tides"], cards: [])
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let note = try XCTUnwrap(researchNote(named: "Tides", in: store))
        try await store.linkResearch(researchId: note.id, toDocumentId: chapter.id)

        let state = BinderTreeSectionsState()
        state.researchSectionExpanded = false

        let shown = state.reveal(note.id, structure: store.manifest.structure,
                                 research: store.manifest.research,
                                 projectType: store.manifest.type)

        XCTAssertTrue(state.researchSectionExpanded)
        XCTAssertTrue(state.expandedPieceFolds.isEmpty,
                      "the chapter's fold holds a DUPLICATE of a shared row; "
                      + "the shared section is where the item lives")
        XCTAssertEqual(shown, .research(note.id))
    }

    /// The narrowed guard is about OWNERSHIP, not about the id being unknown: a
    /// piece-scoped id in a project whose piece the manifest no longer holds is
    /// the same nothing. Control for the pair above — with the piece present the
    /// very same call opens a fold.
    func test_revealingAPieceScopedNoteOfADeletedPieceMovesNothing() async throws {
        let store = try await collection(pieces: ["Alpha"], notes: [], cards: [])
        let piece = try XCTUnwrap(store.manifest.structure.first)
        let owned = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Alpha's Note")

        let state = BinderTreeSectionsState()
        state.researchSectionExpanded = false
        // The item survives in the manifest's research (this is the shape a
        // half-swept manifest has); the piece that owned it does not.
        let orphanedStructure: [StructureItem] = []

        let shown = state.reveal(owned.id, structure: orphanedStructure,
                                 research: store.manifest.research,
                                 projectType: store.manifest.type)

        XCTAssertNil(shown)
        XCTAssertFalse(state.researchSectionExpanded)
        XCTAssertTrue(state.expandedPieceFolds.isEmpty)
    }

    // MARK: - The scroll request is a one-shot (stage-3b Task 8)

    /// Nothing pending on a fresh state — the same "no binding, no request"
    /// shape every other piece of disclosure state starts in.
    func test_thereIsNoScrollRequestOnAFreshState() {
        XCTAssertNil(BinderTreeSectionsState().scrollRequest)
    }

    /// **Two requests in a row land the second.** There is no coalescing or
    /// debounce here — `scrollRequest` is a plain optional, and a write before
    /// the previous one is consumed simply replaces it, exactly the way
    /// `pendingSweep`/`pendingRenameId` and every other single-slot "next
    /// thing to do" flag in this app already behaves.
    func test_theSecondOfTwoUnconsumedScrollRequestsWins() {
        let state = BinderTreeSectionsState()
        state.scrollRequest = .researchHeader
        state.scrollRequest = .paletteHeader
        XCTAssertEqual(state.scrollRequest, .paletteHeader,
                       "the second write, made before the first was consumed, "
                       + "is what a consumer sees")
    }

    /// **The folds start closed**, which is what the no-binding
    /// `DisclosureGroup`s the hosts used before this task already drew — binding
    /// them must change nothing a writer sees on a fresh window.
    func test_theFoldsStartClosedAndTheirBindingRoundTrips() {
        let state = BinderTreeSectionsState()
        XCTAssertTrue(state.expandedPieceFolds.isEmpty)

        let binding = state.foldExpansion(of: "doc-1")
        XCTAssertFalse(binding.wrappedValue)
        binding.wrappedValue = true
        XCTAssertEqual(state.expandedPieceFolds, ["doc-1"])
        XCTAssertTrue(state.foldExpansion(of: "doc-1").wrappedValue)
        binding.wrappedValue = false
        XCTAssertTrue(state.expandedPieceFolds.isEmpty,
                      "closing is a removal — the set holds the OPEN ids, so a "
                      + "closed fold is an id that is not in it")
    }

    // MARK: - Fixtures

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
        for title in pieces { _ = try await store.addLoosePiece(title: title, format: .markdown) }
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

    private func researchNote(named title: String, in store: ProjectStore) -> ResearchItem? {
        TreeWalk.first(in: store.manifest.research, where: { $0.title == title })
    }

    // MARK: - Hosting and driving

    private func hostBinder(
        store: ProjectStore, treeState: BinderTreeSectionsState? = nil, key: Bool = false
    ) async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        let window = try await mount(AnyView(
            BinderSectionsProbeView(store: store, probe: probe,
                                    treeState: treeState ?? BinderTreeSectionsState())), key: key)
        return (window, probe)
    }

    private func hostCollection(
        store: ProjectStore
    ) async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        let window = try await mount(AnyView(
            CollectionSectionsProbeView(store: store, probe: probe)))
        return (window, probe)
    }

    private func hostNavigator(
        store: ProjectStore, script: FountainScript?,
        treeState: BinderTreeSectionsState? = nil
    ) async throws -> (NSWindow, BinderSubjectProbe, String?) {
        let probe = BinderSubjectProbe()
        let documentID = TreeWalk.first(
            in: store.manifest.structure, where: { $0.type == .document })?.id
        let window = try await mount(AnyView(NavigatorSectionsProbeView(
            store: store, probe: probe, script: script, documentID: documentID,
            treeState: treeState ?? BinderTreeSectionsState())))
        return (window, probe, documentID)
    }

    private func mount(_ root: AnyView, key: Bool = false) async throws -> NSWindow {
        let window: NSWindow = key
            ? TestWindow.mount(root, size: CGSize(width: 320, height: 800), as: KeyTestWindow.self, present: .key)
            : TestWindow.mount(root, size: CGSize(width: 320, height: 800), as: SilentTestWindow.self)
        windows.append(window)
        await pumpUntil(deadline: 5) { self.firstTableView(in: window) != nil }
        // The palette section loads its cards from disk once per manifest change,
        // so the rows it contributes arrive a turn after the table does.
        pump(0.2)
        return window
    }

    /// Move the table's selection and let SwiftUI's list coordinator write it
    /// back through the binding. `until` names what the caller's next assertion
    /// checks; a caller asserting an ABSENCE passes nothing and gets the fixed
    /// wall-clock window instead.
    private func select(row: Int, in table: NSTableView,
                        until settled: (() -> Bool)? = nil) async {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if let settled {
            await pumpUntil(deadline: 5, settled)
        } else {
            await waitOut(0.4)
        }
    }

    private func firstTableView(in window: NSWindow) -> NSTableView? {
        guard let root = window.contentView else { return nil }
        var found: [NSTableView] = []
        collect(NSTableView.self, in: root, into: &found)
        return found.first
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }
}

// MARK: - Probes

@MainActor
private struct BinderSectionsProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe

    var treeState = BinderTreeSectionsState()

    var body: some View {
        BinderView(store: store,
                   selectedSubject: Binding(get: { probe.subject },
                                            set: { probe.subject = $0 }),
                   treeState: treeState)
    }
}

@MainActor
private struct CollectionSectionsProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    @State private var renaming: String?
    let treeState = BinderTreeSectionsState()

    var body: some View {
        CollectionPiecesPane(
            store: store,
            selectedSubject: Binding(get: { probe.subject },
                                     set: { probe.subject = $0 }),
            renamingItemId: $renaming,
            treeState: treeState)
    }
}

@MainActor
private struct NavigatorSectionsProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    let script: FountainScript?
    let documentID: String?
    var treeState = BinderTreeSectionsState()

    var body: some View {
        SceneNavigatorPane(
            store: store,
            script: script,
            projectTitle: store.manifest.title,
            selectedSubject: Binding(get: { probe.subject },
                                     set: { probe.subject = $0 }),
            documentID: documentID,
            treeState: treeState,
            onSelect: { _ in })
    }
}

/// **The planted offender.** A tree whose List is bound STRAIGHT to the subject,
/// with an untagged placeholder row in it — the shape the empty sections would
/// take if nobody had measured what an untagged row does. Selecting the
/// placeholder must clear the subject here, or the guard the real trees carry is
/// protecting nothing.
@MainActor
private struct NaivePlaceholderOffender: View {
    let probe: BinderSubjectProbe

    var body: some View {
        List(selection: Binding(get: { probe.subject },
                                set: { probe.subject = $0 })) {
            ProjectRowLabel(title: "Offender")
                .tag(BinderSubject.project)
            Section("Research") {
                Text("No research yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }
}
