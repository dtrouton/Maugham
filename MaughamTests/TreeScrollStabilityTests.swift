import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The tree's scroll position is nobody else's business** — and in
/// particular it is not the review pass's.
///
/// Denver's 2026-08-18 smoke: swapping the pass from the round cockpit's lane
/// picker (Review, some window sizes) left the binder tree scrolled down, with
/// the project row and the first chapters off the top. Nothing about a pass
/// concerns the tree, so the contract is simply that the offset does not move.
///
/// **The positive control is what makes the negative assertions worth
/// anything.** A test that watches a number stay still passes just as happily
/// on a harness that could never have seen it move —
/// `test_control_aRevealRequestDoesMoveTheTree` fires the one mechanism in the
/// app that CAN scroll this list (`BinderTreeSectionsState.consumePendingScroll`,
/// the only production `scrollTo` the tree has) and measures a real jump to the
/// foot of the tree, which is the shape the smoke reported: 0 → the research
/// header, project row and first pieces gone. The reveal's own suites
/// (`FindMatchScrollTests`, `AltitudeKeyspaceTests`) own its behaviour; what is
/// asserted here is only that this harness can tell a scrolled tree from a
/// still one.
///
/// **Two hosts, deliberately.** The probe view is the production shape in
/// miniature (a `NavigationSplitView` whose sidebar is the real
/// `BinderPaneToggle`, with an ancestor reading `uiState` so a write really does
/// re-render the subtree); the second mounts the REAL `ProjectWindow` on a real
/// project, so nothing about the window's own modifiers is modelled rather than
/// run. The write in both is production's own — `updateUIState { … }`, the one
/// line `ProjectWindow.recordActivePass` is.
@MainActor
final class TreeScrollStabilityTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        documentStores.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - The contract

    /// A pass swap over a tree taller than its column, with a chapter selected
    /// well below the fold — the smoke's own posture.
    func test_aPassSwapDoesNotMoveTheTree() async throws {
        let store = try await novel(chapters: 40)
        let documentStore = try XCTUnwrap(store.documentStore)
        let treeState = BinderTreeSectionsState()
        let probe = BinderSubjectProbe(.project)
        let chapters = store.manifest.structure

        let window = try await mount(store: store, documentStore: documentStore,
                                     treeState: treeState, probe: probe)
        let table = try XCTUnwrap(firstTableView(in: window))
        let scrollView = try XCTUnwrap(table.enclosingScrollView)
        XCTAssertGreaterThan(
            table.frame.height, scrollView.contentView.bounds.height,
            "premise: the tree must overflow its column, or there is no scroll "
            + "position for a pass to move")

        // The writer clicks a chapter well down the tree, then scrolls back up.
        table.selectRowIndexes(IndexSet(integer: 26), byExtendingSelection: false)
        _ = await pumpUntil(deadline: 5) { probe.subject != .project }
        scrollToTop(scrollView)
        let before = scrollView.contentView.bounds.origin.y

        // The pass swap: `ProjectWindow.recordActivePass`'s one line.
        documentStore.updateUIState {
            $0.activePassMemory.record(piece: chapters[26].id, passId: "line")
        }
        pump(0.6)

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, before, accuracy: 0.5,
                       "the tree scrolled on a pass swap — the pass is a fact "
                       + "about a piece, not about where the writer is looking "
                       + "in their own binder")
    }

    /// The same write in the REAL window, so the negative covers every modifier
    /// `ProjectWindow` hangs off itself rather than the handful a probe models.
    func test_aPassSwapDoesNotMoveTheRealWindowsTree() async throws {
        let store = try await novel(chapters: 40)
        let chapters = store.manifest.structure
        let url = store.url
        // Open in Review, on a chapter, with the annotations queue up — where
        // the cockpit's lane picker lives.
        try XCTUnwrap(store.documentStore).updateUIState {
            $0.persona = .review
            $0.selectedSubject = .item(chapters[25].id)
            $0.detailSegment = .annotations
        }
        await waitOut(1.2)   // the 500ms UI-state debounce reaches disk

        let registry = ProjectRegistry()
        let window = try await mountProjectWindow(url: url, registry: registry)
        let table = try XCTUnwrap(firstTableView(in: window))
        let scrollView = try XCTUnwrap(table.enclosingScrollView)
        XCTAssertGreaterThan(
            table.frame.height, scrollView.contentView.bounds.height,
            "premise: the tree overflows its column")

        let liveStore = try XCTUnwrap(
            registry.lookup(id: ProjectIdentifier.id(for: url))?.store,
            "the window registers its own store — without it this test would "
            + "be writing to a second `DocumentStore` the window never reads")
        let liveDocumentStore = try XCTUnwrap(liveStore.documentStore)

        table.selectRowIndexes(IndexSet(integer: 26), byExtendingSelection: false)
        pump(0.5)
        scrollToTop(scrollView)
        let before = scrollView.contentView.bounds.origin.y
        let frameBefore = window.frame

        liveDocumentStore.updateUIState {
            $0.activePassMemory.record(piece: chapters[25].id, passId: "line")
        }
        pump(0.8)

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, before, accuracy: 0.5,
                       "the real window's tree scrolled on a pass swap")
        XCTAssertEqual(window.frame, frameBefore,
                       "…and the window did not resize under it either — a "
                       + "grown window is the other way a writer loses the top "
                       + "of a column")
    }

    // MARK: - The frame

    /// **A tree can be displaced without scrolling, and only a FRAME reads
    /// that.** Denver's second reproduction (2026-08-18) logged not one
    /// clip-bounds move while the column he was looking at had lost its top
    /// rows — so the two assertions above, and every instrument the first two
    /// sessions built, were watching the wrong number. A scroll view laid out
    /// somewhere the window cannot show moves every row on screen and moves no
    /// offset at all.
    ///
    /// So: the tree's scroll view must be INSIDE the window, before and after
    /// the pass write, at every height a writer's window can have — swept
    /// rather than sampled, because the report is explicitly "at some window
    /// sizes", and because the one thing measured to perturb this column is the
    /// window's own height (`ProjectWindow`'s minimum layout height rises by
    /// 45pt on a pass write, so windows in that band are the suspects).
    ///
    /// Green on unmodified code — see `test_control_…OutsideIt` below for the
    /// proof that this assertion can fail at all.
    ///
    /// **And green on the DEFECTIVE code too, which is why it is not the test
    /// that guards the fix.** On this fixture the real window's minimum is
    /// `ProjectWindow`'s own explicit `.frame(minHeight: 540)` and the
    /// annotations column asks for far less, so the column's rise is masked
    /// here — that masking is why the window-level sweep stayed green through
    /// three sessions of investigation. The two tests that CAN fail on it are
    /// `test_aPassSwapDoesNotRaiseTheAnnotationColumnsMinimumHeight` (the cause)
    /// and `test_aPassSwapCannotPushTheTreeOutOfAWindowThatAlreadyFitsIt` (the
    /// mechanism). This one covers the whole real composition, at every height,
    /// against the NEXT thing that tries it.
    func test_aPassSwapLeavesTheTreeInsideItsWindow() async throws {
        let store = try await novel(chapters: 40)
        let chapters = store.manifest.structure
        let url = store.url
        try XCTUnwrap(store.documentStore).updateUIState {
            $0.persona = .review
            $0.selectedSubject = .item(chapters[25].id)
            $0.detailSegment = .annotations
        }
        await waitOut(1.2)

        let registry = ProjectRegistry()
        let window = try await mountProjectWindow(url: url, registry: registry)
        let liveStore = try XCTUnwrap(
            registry.lookup(id: ProjectIdentifier.id(for: url))?.store)
        let liveDocumentStore = try XCTUnwrap(liveStore.documentStore)

        // 20pt steps, not 100: the report is explicitly "at some window sizes",
        // and a coarse sweep steps over its own subject. The second, finer
        // sweep WALKS the band the third session measured — 596–636, where the
        // split view was seen laid out shorter than the window after the write.
        //
        // **Walks, not reproduces.** `NSHostingView` stamps the window's
        // `contentMinSize` (980×540 on this fixture) and the window clamps every
        // `setContentSize` back up, so no step here can put the window below its
        // content's minimum — which is the only state that produces the defect.
        // The band steps are honest coverage of those heights and nothing
        // stronger.
        //
        // The sweep stops at the floor for the same reason: asking for 520 got
        // 540 and measured a height the sweep did not choose. A step that
        // silently becomes another step is not a step.
        let coarse = Array(stride(from: 880.0, through: 540.0, by: -20.0))
        let band = Array(stride(from: 636.0, through: 596.0, by: -8.0))
        for height in coarse + band {
            window.setContentSize(NSSize(width: 1000, height: height))
            pump(0.25)
            try assertTreeIsInsideItsWindow(window, "asked for \(Int(height)), before")
            try assertSplitViewFillsItsWindow(window, "asked for \(Int(height)), before")

            liveDocumentStore.updateUIState {
                $0.activePassMemory.record(piece: chapters[25].id,
                                           passId: "line")
            }
            pump(0.3)
            try assertTreeIsInsideItsWindow(window, "asked for \(Int(height)), after")
            try assertSplitViewFillsItsWindow(window, "asked for \(Int(height)), after")

            liveDocumentStore.updateUIState {
                $0.activePassMemory.record(piece: chapters[25].id,
                                           passId: "structural")
            }
            pump(0.3)
            try assertTreeIsInsideItsWindow(window, "asked for \(Int(height)), back")
            try assertSplitViewFillsItsWindow(window, "asked for \(Int(height)), back")
        }
    }

    /// **The window's floor is `ProjectWindow`'s own declared number, in every
    /// state the window can be in.**
    ///
    /// With the hosting view answering the minimum question
    /// (`sizingOptions = [.minSize]`), `window.contentMinSize.height` must be
    /// `ProjectWindow.windowHeightFloor` exactly — the number `body` declares.
    /// Equality rather than "at most": a resolved minimum BELOW the declared
    /// floor means `body`'s `.frame(minHeight:)` has stopped applying, which is
    /// its own defect and should be as red as an overrun.
    ///
    /// The states are persona × that persona's own `panes` × the two subject
    /// shapes (a chapter, which centres the editor; the project row, which
    /// centres the altitude view) — the registry's own product, so a pane added
    /// to `DetailSegment` is swept the day it joins a persona, with no list in
    /// this file to update. A failure names the state it happened in.
    ///
    /// **What no pane can currently do to it, measured 2026-08-18 with planted
    /// offenders against this very window.** A `.frame(minHeight: 700)` planted
    /// on `AnnotationsPane` (outside its own `doesNotRaiseTheWindowFloor()`, so
    /// nothing absorbed it there), on the sidebar column, on the centre column,
    /// and on the detail column's own root each left this assertion **green at
    /// 540**. The same offender on `ProjectWindow`'s `body`, outside the split
    /// view, turned it **red at 700** in every state.
    ///
    /// So in this window's composition a column's minimum height does not reach
    /// the window. **Where exactly it is absorbed was NOT isolated, and the
    /// obvious guess is wrong**: the same offender in a minimal three-column
    /// `NavigationSplitView` probe propagates to 700, so this is something about
    /// `ProjectWindow`'s own split-view chrome and not a general property of
    /// `NavigationSplitView`. Recorded as a measurement rather than pinned as a
    /// test, because a test asserting it would be pinning behaviour nobody has
    /// explained.
    ///
    /// **That limit does not weaken this census, and it is worth being clear
    /// why.** The dangerous state is a surface that both exceeds the floor AND
    /// reaches the window — and that is exactly what is asserted here, whatever
    /// the surface and whatever the route. Today's panes fail the second half,
    /// so none of them can go red; the day one does, only a demand above 540
    /// matters, and this is what catches it.
    ///
    /// It is also why the 2026-08-18 nudge finding is HARDENING and not the fix
    /// for Denver's report: the leak it closes never reached the window. See the
    /// note.
    func test_theWindowsMinimumHeightIsProjectWindowsOwnFloor() async throws {
        try await sweepTheWindowsMinimumHeight()
    }

    private func sweepTheWindowsMinimumHeight() async throws {
        let store = try await novel(chapters: 3)
        let chapters = store.manifest.structure
        let url = store.url
        let documentStore = try XCTUnwrap(store.documentStore)
        // A pass recorded on the chapter, so every state below is swept with
        // the queue's advisory nudge live rather than in its quiet state — the
        // one measured to have raised this number.
        documentStore.updateUIState {
            $0.persona = .review
            $0.selectedSubject = .item(chapters[0].id)
            $0.activePassMemory.record(piece: chapters[0].id, passId: "line")
        }
        await waitOut(1.2)

        let registry = ProjectRegistry()
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let hosting = NSHostingView(rootView: AnyView(
            ProjectWindow(url: url)
                .environment(UserPreferences())
                .environment(registry)
                .environment(BackupCoordinator())))
        hosting.sizingOptions = [.minSize]
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame,
                                      styleMask: [.titled, .resizable],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        _ = await pumpUntil(deadline: 20) {
            (self.firstTableView(in: window)?.numberOfRows ?? 0) > 2
        }
        pump(0.6)

        let liveStore = try XCTUnwrap(
            registry.lookup(id: ProjectIdentifier.id(for: url))?.store)
        let liveDocumentStore = try XCTUnwrap(liveStore.documentStore)

        let subjects: [(String, BinderSubject)] = [
            ("a chapter", .item(chapters[0].id)),
            ("the project row", .project),
        ]
        var swept = 0
        for persona in Persona.allCases {
            for pane in persona.panes {
                for (subjectName, subject) in subjects {
                    liveDocumentStore.updateUIState {
                        $0.persona = persona
                        $0.detailSegment = pane
                        $0.selectedSubject = subject
                    }
                    pump(0.25)
                    swept += 1
                    XCTAssertEqual(
                        window.contentMinSize.height,
                        ProjectWindow.windowHeightFloor, accuracy: 0.5,
                        "the window's minimum height is "
                        + "\(window.contentMinSize.height) in "
                        + "\(persona.rawValue)/\(pane.rawValue) on "
                        + "\(subjectName) — `ProjectWindow.windowHeightFloor` "
                        + "(\(ProjectWindow.windowHeightFloor)) is the only "
                        + "thing entitled to set it. Something outside the "
                        + "split view's columns is demanding height: a floor "
                        + "that rises AFTER `contentMinSize` is stamped leaves "
                        + "the window at a size it still believes legal while "
                        + "the content has decided otherwise, and SwiftUI "
                        + "CENTRES what it cannot compress — which takes the "
                        + "top of the binder tree off screen. (Measured "
                        + "2026-08-18: a COLUMN's demand does not reach this "
                        + "window at all, so look outside the split view "
                        + "first — see this test's doc.)")
                }
            }
        }
        XCTAssertGreaterThan(
            swept, 10,
            "premise: the registry must have yielded a real product of states — "
            + "an empty sweep asserts nothing at all")
    }

    /// **The column's minimum height is not the pass's business** — the cause,
    /// pinned where it is measurable without a window at all.
    ///
    /// **Weaker than it looks on its own, and deliberately kept anyway.** Its
    /// premise is a nil-check (`PassOrderAdvice.advice` became non-nil), which
    /// says the nudge's CONDITION turned true, not that the nudge cost the
    /// column any height. The measured-band premise in
    /// `test_aPassSwapCannotPushTheTreeOutOfAWindowThatAlreadyFitsIt` is the
    /// strong one — it asserts the pane's ideal actually GREW across the write
    /// and fails loudly if it did not — and the two are read together: this one
    /// says the minimum did not move, that one says there was something there
    /// to move it.
    ///
    /// A pass write makes `AnnotationsPane`'s advisory nudge appear, and the
    /// pane's stack is non-scrolling: every strip in it demands its full height
    /// as a MINIMUM, and that minimum propagates out to `NSHostingView`.
    /// Measured 2026-08-18 on unmodified code: this pane's minimum height rose
    /// 244.5 → 270.5 on the write, exactly the nudge's own 26pt.
    ///
    /// Why that is a defect rather than a curiosity: `window.contentMinSize` is
    /// stamped ONCE at mount, so a minimum that rises afterwards cannot push
    /// the window back out. The writer's window keeps a height the window still
    /// considers legal while the layout has decided it needs more, and SwiftUI
    /// CENTRES what it cannot compress — which drives the binder tree's scroll
    /// view above the window's top edge with its scroller never having moved
    /// (`test_control_…OutsideIt`).
    ///
    /// `sizingOptions = [.minSize]` is what makes the hosting view answer the
    /// minimum question at all: it is then `window.contentMinSize` that carries
    /// the answer — literally the production quantity, since that stamp is what
    /// a window measures its own legal sizes against. Measured on unmodified
    /// code with this fixture: 50 → 76, the nudge's 26pt exactly.
    func test_aPassSwapDoesNotRaiseTheAnnotationColumnsMinimumHeight() async throws {
        let store = try await novel(chapters: 3)
        let documentStore = try XCTUnwrap(store.documentStore)
        let docPath = try XCTUnwrap(store.manifest.structure.first?.path)
        let document = try await Document.load(
            url: store.url.appendingPathComponent(docPath),
            device: "test-mac", session: "s", presenter: nil)
        documentStore.register(document: document, for: docPath)

        let width: CGFloat = 320
        let hosting = NSHostingView(rootView: AnyView(
            AnnotationsPaneProbe(document: document, store: store,
                                 documentStore: documentStore,
                                 orchestrator: nil, diagnostics: nil)
                .frame(width: width)))
        hosting.sizingOptions = [.minSize]
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 900)
        let window = SilentTestWindow(
            contentRect: hosting.frame, styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump(1.0)

        let before = window.contentMinSize.height

        documentStore.updateUIState {
            $0.activePassMemory.record(piece: document.docId, passId: "line")
        }
        pump(0.8)

        // The premise: the write really did give this pane something new to
        // draw. Without it the assertion below would pass on a pane that never
        // grew because nothing about it changed.
        XCTAssertNotNil(
            PassOrderAdvice.advice(
                forPiece: document.docId,
                memory: documentStore.uiState.activePassMemory,
                passes: store.manifest.effectiveReviewPasses,
                passStates: nil),
            "premise: recording the LINE pass over an unfinished STRUCTURAL one "
            + "must produce the nudge — it is the strip whose appearance moved "
            + "the minimum")

        XCTAssertEqual(
            window.contentMinSize.height, before, accuracy: 0.5,
            "the annotations column raised its minimum height on a pass swap "
            + "(\(before) → \(window.contentMinSize.height)). A pane's content "
            + "growing is a reason to compress or scroll that pane, never a "
            + "reason to move the window's floor — and a floor that rises after "
            + "`contentMinSize` is stamped is what centres the split view and "
            + "pushes the tree out of the top of its column")
    }

    /// **The mechanism, end to end, at the one height that can show it.**
    ///
    /// The sweep above runs on a window whose floor is `ProjectWindow`'s own
    /// explicit `.frame(minHeight: 540)`, which on this fixture is comfortably
    /// above anything the annotations column asks for — so the column's rise is
    /// masked there and the sweep cannot fail on it. This host is the same
    /// three-column composition WITHOUT that floor, so the annotations column
    /// is what sets the minimum, and the container is sized from the measured
    /// minimum rather than a constant: just above what the layout needs BEFORE
    /// the write, which is inside the band the write used to open.
    ///
    /// The squeeze goes through a container view for `test_control_…`'s reason:
    /// `NSHostingView` stamps `contentMinSize` and the window clamps every
    /// `setContentSize` back up.
    func test_aPassSwapCannotPushTheTreeOutOfAWindowThatAlreadyFitsIt() async throws {
        let store = try await novel(chapters: 40)
        let documentStore = try XCTUnwrap(store.documentStore)
        let docPath = try XCTUnwrap(store.manifest.structure.first?.path)
        let document = try await Document.load(
            url: store.url.appendingPathComponent(docPath),
            device: "test-mac", session: "s", presenter: nil)
        documentStore.register(document: document, for: docPath)
        let treeState = BinderTreeSectionsState()
        let probe = BinderSubjectProbe(.project)
        let orchestrator = CompilerOrchestrator()
        let diagnostics = DiagnosticsStore(
            projectRoot: store.url, device: DeviceSlug.make(from: "test-mac"))

        // **The band, measured rather than guessed.** The pane's IDEAL height
        // is what its minimum used to be: every strip in its non-scrolling
        // stack demanded its full height. So the two ideals either side of the
        // write bracket the band the defect opened, and a container halfway
        // between them is a window the layout fitted BEFORE the write and did
        // not after. Measuring it here keeps the test honest across fixtures,
        // fonts and OS versions — a hardcoded height would silently stop
        // straddling the band the day any of the three moved.
        documentStore.updateUIState {   // the neutral state: no earlier pass is
            // open before the FIRST pass, so no nudge.
            $0.activePassMemory.record(piece: document.docId, passId: "structural")
        }
        let ruler = NSHostingView(rootView: AnyView(
            AnnotationsPaneProbe(document: document, store: store,
                                 documentStore: documentStore,
                                 orchestrator: orchestrator,
                                 diagnostics: diagnostics)
                .frame(width: 320)))
        ruler.sizingOptions = [.intrinsicContentSize]
        ruler.frame = CGRect(x: 0, y: 0, width: 320, height: 900)
        let rulerWindow = SilentTestWindow(
            contentRect: ruler.frame, styleMask: [.titled],
            backing: .buffered, defer: false)
        rulerWindow.contentView = ruler
        rulerWindow.orderFront(nil)
        windows.append(rulerWindow)
        pump(0.8)
        let idealWithoutNudge = ruler.intrinsicContentSize.height
        documentStore.updateUIState {
            $0.activePassMemory.record(piece: document.docId, passId: "line")
        }
        pump(0.8)
        let idealWithNudge = ruler.intrinsicContentSize.height
        XCTAssertGreaterThan(
            idealWithNudge, idealWithoutNudge,
            "premise: the pass write must give this column something more to "
            + "draw (the advisory nudge) — with no growth there is no band, and "
            + "the containment assertions below would be measuring nothing")
        documentStore.updateUIState {
            $0.activePassMemory.record(piece: document.docId, passId: "structural")
        }
        pump(0.4)
        rulerWindow.contentView = NSView(frame: .zero)

        let height = ((idealWithoutNudge + idealWithNudge) / 2).rounded()
        let frame = CGRect(x: 0, y: 0, width: 1000, height: height)
        let hosting = NSHostingView(rootView: AnyView(PassSwapColumnProbe(
            store: store, documentStore: documentStore, document: document,
            treeState: treeState, probe: probe,
            orchestrator: orchestrator, diagnostics: diagnostics)))
        hosting.frame = frame
        let container = NSView(frame: frame)
        container.addSubview(hosting)
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = container
        window.orderFront(nil)
        container.layoutSubtreeIfNeeded()
        windows.append(window)
        _ = await pumpUntil(deadline: 20) {
            (self.firstTableView(in: window)?.numberOfRows ?? 0) > 5
        }
        pump(0.6)

        // A window the writer's layout already fits, which is the whole point:
        // nothing they do to a pass may make it stop fitting.
        try assertTreeIsInsideIts(
            container,
            "before the write (host \(Int(height))pt, band "
            + "\(idealWithoutNudge)–\(idealWithNudge))")

        documentStore.updateUIState {
            $0.activePassMemory.record(piece: document.docId, passId: "line")
        }
        pump(0.8)

        try assertTreeIsInsideIts(
            container,
            "after the write (host \(Int(height))pt, band "
            + "\(idealWithoutNudge)–\(idealWithNudge))")
    }

    /// **The frame assertion's positive control.** Squeeze `ProjectWindow`
    /// below the height its own layout needs and SwiftUI does not compress —
    /// it keeps the minimum size and CENTRES it, which drives the tree's scroll
    /// view partly out of the window with its origin NEGATIVE: the top rows
    /// above the window's top edge, the scroller untouched. That is the
    /// reported picture exactly, and it is why the frame is worth asserting.
    ///
    /// The squeeze goes through a container view rather than the window's own
    /// `setContentSize`, because `NSHostingView` stamps the window's
    /// `contentMinSize` and the window then clamps every request back up — the
    /// harness would silently measure a legal size and pass.
    func test_control_aWindowShorterThanItsMinimumPutsTheTreeOutsideIt() async throws {
        let store = try await novel(chapters: 40)
        let chapters = store.manifest.structure
        // A chapter subject, so the centre column is the editor and the first
        // table in the tree is the TREE — the altitude view a project subject
        // would put there brings a table of its own.
        try XCTUnwrap(store.documentStore).updateUIState {
            $0.persona = .review
            $0.selectedSubject = .item(chapters[25].id)
        }
        await waitOut(1.2)

        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let registry = ProjectRegistry()
        let hosting = NSHostingView(rootView: AnyView(
            ProjectWindow(url: store.url)
                .environment(UserPreferences())
                .environment(registry)
                .environment(BackupCoordinator())))
        hosting.frame = frame
        let container = NSView(frame: frame)
        container.addSubview(hosting)
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = container
        window.orderFront(nil)
        container.layoutSubtreeIfNeeded()
        windows.append(window)
        _ = await pumpUntil(deadline: 20) {
            (self.firstTableView(in: window)?.numberOfRows ?? 0) > 5
        }
        pump(0.5)

        hosting.frame = CGRect(x: 0, y: 0, width: 1000, height: 300)
        hosting.layoutSubtreeIfNeeded()
        pump(0.5)

        let table = try XCTUnwrap(firstTableView(in: window))
        let scrollView = try XCTUnwrap(table.enclosingScrollView)
        let rect = hosting.convert(scrollView.bounds, from: scrollView)
        XCTAssertFalse(
            hosting.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect),
            "a window shorter than its content's minimum must put the tree "
            + "outside it — without that, the containment assertions above are "
            + "watching a number that could never have gone wrong")
        XCTAssertLessThan(
            rect.origin.y, 0,
            "…and it must go out of the TOP: SwiftUI centres what it cannot "
            + "compress, which is what takes the project row off the top of a "
            + "column whose scroller never moved")
    }

    /// Both halves of the frame contract in one place, so the sweep above reads
    /// as a sweep. `scrollView.convert(bounds, to: nil)` is the probe's own
    /// spelling; the containment question is asked in the content view's
    /// coordinates, where "inside the window" is a rectangle comparison rather
    /// than an argument about which way y points.
    private func assertTreeIsInsideItsWindow(
        _ window: NSWindow, _ moment: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let root = try XCTUnwrap(window.contentView, file: file, line: line)
        try assertTreeIsInsideIts(root, moment, file: file, line: line)
    }

    /// **The split view fills the window it is in.**
    ///
    /// The third session's other measurement: after the pass write, at window
    /// heights inside the raised band, the whole `NavigationSplitView` was laid
    /// out shorter than the window (596 → 585) and stayed that way. That is the
    /// same centring seen one level up, and it is what shortens every column —
    /// so it is asserted directly rather than inferred from the tree.
    ///
    /// **What it can and cannot catch.** It cannot catch the third session's
    /// band from inside this suite: `NSHostingView` stamps `contentMinSize` and
    /// the window clamps every `setContentSize` back up, so the sweep can never
    /// place the window below its content's minimum and this assertion is
    /// unfalsifiable for those heights. What it DOES guard is the state that
    /// makes such a window reachable at all — a pane whose chrome pushes the
    /// layout's minimum past `ProjectWindow`'s own 540pt floor, after the stamp
    /// has been taken. `test_theWindowsMinimumHeightIsProjectWindowsOwnFloor`
    /// is the census that catches that by name; this is the same condition
    /// caught by its consequence, over the whole real composition.
    private func assertSplitViewFillsItsWindow(
        _ window: NSWindow, _ moment: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let root = try XCTUnwrap(window.contentView, file: file, line: line)
        let split = try XCTUnwrap(
            firstSubview(of: NSSplitView.self, in: root),
            "the composition is a NavigationSplitView — without its NSSplitView "
            + "this assertion has nothing to measure", file: file, line: line)
        XCTAssertEqual(
            split.frame.height, root.bounds.height, accuracy: 1,
            "the split view is laid out shorter than its window (\(moment)): "
            + "\(split.frame.height) in \(root.bounds.height) — SwiftUI centres "
            + "what it cannot compress, and every column shortens with it",
            file: file, line: line)
    }

    private func assertTreeIsInsideIts(
        _ root: NSView, _ moment: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let window = try XCTUnwrap(root.window, file: file, line: line)
        let table = try XCTUnwrap(firstTableView(in: window), file: file, line: line)
        let scrollView = try XCTUnwrap(table.enclosingScrollView,
                                       file: file, line: line)
        let rect = root.convert(scrollView.bounds, from: scrollView)
        XCTAssertTrue(
            root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect),
            "the tree's scroll view left its window (\(moment)): frame \(rect) "
            + "in a window of \(root.bounds) — the rows on screen are displaced "
            + "and no scroll offset says so",
            file: file, line: line)
    }

    // MARK: - The control

    /// **The harness can see a scroll when there is one.** This fires the tree's
    /// only production scroll — a reveal request — and measures the jump the
    /// smoke describes: the tree ends at its foot with row zero off the top.
    func test_control_aRevealRequestDoesMoveTheTree() async throws {
        let store = try await novel(chapters: 40)
        let documentStore = try XCTUnwrap(store.documentStore)
        let treeState = BinderTreeSectionsState()
        let probe = BinderSubjectProbe(.project)

        let window = try await mount(store: store, documentStore: documentStore,
                                     treeState: treeState, probe: probe)
        let table = try XCTUnwrap(firstTableView(in: window))
        let scrollView = try XCTUnwrap(table.enclosingScrollView)
        scrollToTop(scrollView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 0.5)

        treeState.scrollRequest = .researchHeader
        _ = await pumpUntil(deadline: 5) { treeState.scrollRequest == nil }
        pump(0.6)

        XCTAssertGreaterThan(
            scrollView.contentView.bounds.origin.y, 100,
            "a reveal request must scroll this list, or every negative in this "
            + "suite is measuring a harness that cannot move")
        XCTAssertNil(treeState.scrollRequest, "the one-shot is consumed")
    }

    // MARK: - Fixtures

    private func novel(chapters: Int) async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        documentStores.append(ds)
        while store.manifest.structure.count < chapters {
            _ = try await store.addStructureItem(
                parentId: nil,
                title: "Chapter \(store.manifest.structure.count + 1)",
                kind: .document(extension: "md"))
        }
        await store.wordCountPopulationTask?.value
        return store
    }

    private func scrollToTop(_ scrollView: NSScrollView) {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        pump(0.3)
    }

    private func mount(store: ProjectStore,
                       documentStore: DocumentStore,
                       treeState: BinderTreeSectionsState,
                       probe: BinderSubjectProbe) async throws -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 1100, height: 420)
        let hosting = NSHostingView(rootView: AnyView(TreeScrollProbeView(
            store: store, documentStore: documentStore,
            treeState: treeState, probe: probe)))
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        _ = await pumpUntil(deadline: 10) { self.firstTableView(in: window) != nil }
        pump(0.4)
        return window
    }

    private func mountProjectWindow(
        url: URL, registry: ProjectRegistry
    ) async throws -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 500)
        let hosting = NSHostingView(rootView: AnyView(
            ProjectWindow(url: url)
                .environment(UserPreferences())
                .environment(registry)
                .environment(BackupCoordinator())))
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame,
                                      styleMask: [.titled, .resizable],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        _ = await pumpUntil(deadline: 20) {
            (self.firstTableView(in: window)?.numberOfRows ?? 0) > 30
        }
        pump(0.6)
        return window
    }

    private func firstTableView(in window: NSWindow) -> NSTableView? {
        guard let root = window.contentView else { return nil }
        return firstSubview(of: NSTableView.self, in: root)
    }

    private func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let hit = view as? T { return hit }
        for sub in view.subviews {
            if let hit = firstSubview(of: type, in: sub) { return hit }
        }
        return nil
    }
}

/// The annotations column on its own, so its minimum height can be asked for
/// without a window's own floor standing in front of the answer.
@MainActor
private struct AnnotationsPaneProbe: View {
    let document: Document
    @Bindable var store: ProjectStore
    @Bindable var documentStore: DocumentStore
    /// The cockpit is part of what Review's column IS, and the strip's own
    /// 56pt is what lifts this column's demand clear of the sidebar's floor —
    /// without it the band the nudge opens sits below a height the tree column
    /// can be laid out in at all, and the harness measures the sidebar's
    /// minimum instead of the queue's.
    let orchestrator: CompilerOrchestrator?
    let diagnostics: DiagnosticsStore?
    @State private var scope: AnnotationScope = .document

    var body: some View {
        AnnotationsPane(
            document: document, store: store, documentStore: documentStore,
            scope: $scope, onTravel: { _ in },
            orchestrator: orchestrator, diagnostics: diagnostics,
            onSetActivePass: { _, _ in })
        .environment(UserPreferences())
    }
}

/// The three-column composition with the REAL tree on the left and the REAL
/// annotations queue on the right, and no `ProjectWindow.frame(minHeight:)` in
/// front of them — so whatever the queue asks for is what the layout's minimum
/// is, which is the only arrangement in which the queue's rise is observable.
@MainActor
private struct PassSwapColumnProbe: View {
    @Bindable var store: ProjectStore
    @Bindable var documentStore: DocumentStore
    let document: Document
    let treeState: BinderTreeSectionsState
    @Bindable var probe: BinderSubjectProbe
    let orchestrator: CompilerOrchestrator?
    let diagnostics: DiagnosticsStore?

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var findActive = false
    @State private var scope: AnnotationScope = .document

    var body: some View {
        let current = probe.subject
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            BinderPaneToggle(
                store: store,
                selectedSubject: Binding(get: { current },
                                         set: { probe.subject = $0 }),
                projectType: store.manifest.type,
                lastParsedScript: nil,
                treeState: treeState,
                treeFindActive: $findActive,
                persona: .review)
            .navigationSplitViewColumnWidth(
                min: ProjectWindow.binderColumnFloor, ideal: 240)
        } content: {
            Text("centre").frame(maxWidth: .infinity, maxHeight: .infinity)
        } detail: {
            AnnotationsPane(
                document: document, store: store, documentStore: documentStore,
                scope: $scope, onTravel: { _ in },
                orchestrator: orchestrator, diagnostics: diagnostics,
                onSetActivePass: { _, _ in })
        }
        .environment(UserPreferences())
    }
}

/// The production shape in miniature: a split view whose sidebar is the real
/// tree shell, under an ancestor that READS `uiState` — which is what makes an
/// unrelated write re-render the subtree, exactly as the window's own readers do.
@MainActor
private struct TreeScrollProbeView: View {
    @Bindable var store: ProjectStore
    @Bindable var documentStore: DocumentStore
    let treeState: BinderTreeSectionsState
    @Bindable var probe: BinderSubjectProbe

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var findActive = false

    var body: some View {
        // Read the subject HERE so the body has an observation dependency on it
        // — the window holds it in `@State`, and a binding whose `get` is only
        // ever called from inside `List` does not re-render on a write.
        let current = probe.subject
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            BinderPaneToggle(
                store: store,
                selectedSubject: Binding(get: { current },
                                         set: { probe.subject = $0 }),
                projectType: store.manifest.type,
                lastParsedScript: nil,
                treeState: treeState,
                treeFindActive: $findActive,
                persona: .review)
            .navigationSplitViewColumnWidth(
                min: ProjectWindow.binderColumnFloor, ideal: 240)
        } content: {
            Text("centre").frame(maxWidth: .infinity, maxHeight: .infinity)
        } detail: {
            // Reads `uiState` the way the cockpit's own lane line does.
            Text(documentStore.uiState.activePassMemory
                    .activePass(forPiece: "x") ?? "-")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
