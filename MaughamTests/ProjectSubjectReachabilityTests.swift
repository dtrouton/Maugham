import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **Can the writer point the window at the project — in every project type?**
///
/// `BinderSubject.project` is the scope project-level Intent and Visual Language
/// resolve to (`StatementPane.effectiveScope`), and since slice 1 deleted the
/// pane's own `[Chapter | Project]` switch the tree is the ONLY thing that
/// constructs it. So "is there a project row" is not a question about a view; it
/// is a question about a project type, and it has to be asked of all of them.
///
/// **Why this shape and not one more test per view.** Each of slice 1's tasks
/// tested the surface it touched — task 2 `BinderView`, task 2b
/// `CollectionPiecesPane` — and both passed while a screenplay had no project row
/// at all, because a screenplay's document home is the Scenes navigator and no
/// task's diff contained it. A per-view test cannot see a surface nobody wrote a
/// test for. This one enumerates `ProjectType.allCases` and re-drives
/// **production's own routing** to reach whatever surface that type actually
/// mounts:
///
/// - `ProjectWindow.BinderShell.shell(for:)` — which binder shell the left column
///   mounts. It is the single rule `binderColumn` itself switches on, so a third
///   shell is a new case and this file stops compiling until it is enumerated
///   here too.
/// - `TreePane(for:)` — which of the three trees that shell puts up. For a
///   screenplay that is the slugline navigator, which is the whole reason the
///   defect existed.
///
/// **Mounted, not reasoned about**, for the reason `BinderProjectRowTests`
/// records: a project row's implementation is a label and a `.tag`, and whether
/// `List(selection:)` matches that tag is invisible to a test built from the
/// view's own data. These drive the real `NSTableView` and read the real binding.
@MainActor
final class ProjectSubjectReachabilityTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    /// Rows the Research and Palette sections contribute at the foot of every
    /// tree when a project has neither yet (stage-2a Task 4): a header and one
    /// placeholder row each. Every fixture here is a bare factory project, so
    /// each count below is "the tree's own rows, plus the furniture".
    private let emptySectionRows = (1 + 1) + (1 + 1)

    override func setUp() async throws {
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - The census

    /// Every project type, at its own document home, as a **fresh project** —
    /// which for a screenplay means no parsed script yet, because nothing has
    /// opened the `.fountain`, and for a Collection means no pieces at all.
    /// Those are the states in which a writer most wants project-scope intent,
    /// and the states in which an empty-state view that REPLACES its list takes
    /// the only project row with it.
    func test_everyProjectTypeCanNameItsOwnProject() async throws {
        for type in ProjectType.allCases {
            let store = try await project(of: type)
            let (window, probe) = try await host(store: store, script: nil)
            let table = try XCTUnwrap(
                firstTableView(in: window),
                "\(type.rawValue): its tree "
                + "(\(TreePane(for: type).rawValue)) never put a "
                + "List in the hierarchy — there is no row to select, so the "
                + "project is unreachable")

            await select(row: 0, in: table, until: { probe.subject == .project })

            XCTAssertEqual(
                probe.subject, .project,
                "\(type.rawValue): selecting the head row of its "
                + "\(TreePane(for: type).rawValue) tree must produce "
                + "BinderSubject.project — nothing else constructs it, and "
                + "without it project-scope Intent is unreachable in this "
                + "project type")
        }
    }

    /// The same question of a screenplay that has been **opened and parsed**, so
    /// the navigator is a real list of sluglines rather than its empty state.
    /// The empty and non-empty shapes are two different view bodies, and the
    /// project row has to survive both.
    func test_aScreenplayWithScenesCanStillNameItsProject() async throws {
        let store = try await project(of: .screenplay)
        let script = try await productionScript(for: store, text: Self.twoScenes)
        XCTAssertEqual(script?.sceneSummaries().count, 2, "fixture precondition")

        let (window, probe) = try await host(store: store, script: script)
        let table = try XCTUnwrap(firstTableView(in: window))

        await select(row: 0, in: table, until: { probe.subject == .project })
        XCTAssertEqual(probe.subject, .project,
                       "the scene navigator's head row must be the project row, "
                       + "not the first slugline")
    }

    // MARK: - Plan's tree (slice 2)

    /// **The same census, in the persona whose centre column is the board.**
    /// Plan shows the project's own manuscript tree with the canvas still in
    /// the middle (spec §3.1), and "the tree" is three views — so the question
    /// this file was written to ask has to be asked in Plan too, or Plan is
    /// exactly where the slice-1 Critical returns. It was asked of a `.tree`
    /// SEGMENT until shell-finish stage 2b Task 7; the persona is what carries
    /// the difference now, and the tree it mounts is the same one Author gets.
    func test_everyProjectTypeCanNameItsOwnProjectFromPlansTree() async throws {
        for type in ProjectType.allCases {
            let store = try await project(of: type)
            let (window, probe) = try await host(store: store, script: nil,
                                                 persona: .plan)
            let table = try XCTUnwrap(
                firstTableView(in: window),
                "\(type.rawValue): Plan's left column put no List in the "
                + "hierarchy — the writer opens Plan and gets a blank column")

            await select(row: 0, in: table, until: { probe.subject == .project })

            XCTAssertEqual(
                probe.subject, .project,
                "\(type.rawValue): the head row of Plan's tree must be the "
                + "project row, exactly as at the document home")
        }
    }

    /// **The discriminator, and the reason the test above is not enough on its
    /// own.** Every one of the three trees carries a project row at row 0, so a
    /// left column that mounted `BinderView` for a screenplay would pass it —
    /// which is the 2026-07-02 bug's exact shape (the writer lands in a one-row
    /// `BinderView` instead of the navigator).
    ///
    /// A parsed screenplay tells them apart by what is BELOW the head row:
    /// `SceneNavigatorPane` renders project + script + one row per slugline,
    /// `BinderView` renders project + the one document. Row 1 selects the script
    /// in the navigator; in a `BinderView` it would be the document too, so the
    /// count is what discriminates and the count is asserted.
    ///
    /// `selectRowIndexes` is the right driver here and the Button half is not
    /// needed: both rows under test are `List(selection:)` rows carrying a
    /// `.tag` (the sluglines below them are the `Button`s, and this test never
    /// touches one).
    func test_aScreenplaysTreeIsItsSceneNavigatorAndNotAOneRowBinder() async throws {
        let store = try await project(of: .screenplay)
        let script = try await productionScript(for: store, text: Self.twoScenes)
        XCTAssertEqual(script?.sceneSummaries().count, 2, "fixture precondition")

        let (window, probe) = try await host(store: store, script: script,
                                             persona: .plan)
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertEqual(table.numberOfRows, 4 + emptySectionRows,
                       "project + script + two sluglines, then the sections' "
                       + "furniture. A `BinderView` here "
                       + "would show two rows and no scenes at all — the "
                       + "2026-07-02 one-row-binder defect, in Plan")

        await select(row: 0, in: table, until: { probe.subject == .project })
        XCTAssertEqual(probe.subject, .project)
    }

    /// **The planted offender for the fixture above, and the shape of the
    /// defect it used to hide.**
    ///
    /// `nil` is what Plan's tree actually received before this fix — the value
    /// `ProjectWindow` held whenever no editor had ever mounted in the window —
    /// and it is what the pane will receive again if `ScreenplayScriptSource`
    /// ever stops producing one. Two rows and `SceneNavigatorPane`'s "No scenes
    /// yet" overlay, on a screenplay with two scenes.
    ///
    /// If this test ever goes GREEN at four rows, the fixture above has stopped
    /// discriminating and both are worthless.
    func test_plantedOffender_withNoScriptPlansTreeSaysAScreenplayHasNoScenes() async throws {
        let store = try await project(of: .screenplay)
        let script = try await productionScript(for: store, text: Self.twoScenes)
        XCTAssertEqual(script?.sceneSummaries().count, 2, "fixture precondition")

        let (window, _) = try await host(store: store, script: nil,
                                         persona: .plan)
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertEqual(table.numberOfRows, 2 + emptySectionRows,
                       "the plant must fire: with no parsed script the navigator "
                       + "draws the project row, Script, and the two sections' "
                       + "furniture, and no slugline at all. If this matches the "
                       + "count above, the test above is passing on something "
                       + "other than the script it was handed")
    }

    /// **The defect itself, at the seam that produces the value** — the half no
    /// mounted fixture can reach, because `lastParsedScript` is `@State` inside
    /// `ProjectWindow` and a test cannot ask a window for it.
    ///
    /// The chain was: `lastParsedScript` ← `.maughamScriptDidUpdate` ←
    /// `EditorCoordinator` ← `EditorHost`, and the canvas takes the centre
    /// column in Plan before the editor is ever built. So in Plan the window
    /// could never produce a parse at all, and the fixture above was green only
    /// because it injected one.
    ///
    /// Asked of a project that has **never had an editor mounted in it**: the
    /// store is loaded from disk, no `DocumentStore` is attached, and the only
    /// thing that has ever touched the script is the op log.
    func test_planCanParseAScreenplayWithNoEditorEverMounted() async throws {
        let store = try await project(of: .screenplay)
        _ = try await productionScript(for: store, text: Self.twoScenes)
        XCTAssertNil(store.documentStore,
                     "precondition: nothing has opened a document in this "
                     + "project, which is Plan on a freshly opened window")

        XCTAssertTrue(
            ScreenplayScriptSource.needsDerivation(
                persona: .plan, projectType: .screenplay, existing: nil),
            "Plan with no parse yet is exactly the state that has to derive one")
        let derived = try XCTUnwrap(
            ScreenplayScriptSource.derive(store: store),
            "the window has no way to show a screenplay's scenes in Plan")
        XCTAssertEqual(
            derived.sceneSummaries().map(\.line.content),
            ["INT. KITCHEN - DAY", "EXT. ROOF - NIGHT"],
            "Plan's Structure tab must list the script's real sluglines")
    }

    /// A Collection's tree is its Pieces pane — asserted by the pane that is
    /// mounted rather than by the routing table, because
    /// `CollectionBinderPaneToggle` is a second toggle deriving the same answer
    /// and two toggles answering one question their own way is how the
    /// 2026-07-02 bug shipped.
    func test_aCollectionsTreeIsItsPiecesPane() async throws {
        let store = try await project(of: .collection)
        _ = try await store.addLoosePiece(title: "Piece One", mode: .prose)
        let (window, probe) = try await host(store: store, script: nil,
                                             persona: .plan)
        let table = try XCTUnwrap(firstTableView(in: window))
        XCTAssertEqual(table.numberOfRows, 2 + emptySectionRows,
                       "the project row, the one piece, and the sections' furniture")

        await select(row: 0, in: table, until: { probe.subject == .project })
        XCTAssertEqual(probe.subject, .project)
    }

    // MARK: - The way out of a research subject (stage-2a final review, C)

    /// **Every window state that lets a research subject stand must also be able
    /// to clear it.**
    ///
    /// The missing class of test, and the one the Critical fell through. Stage
    /// 2a's Task 5 asked *which column does a research subject take* and
    /// answered it exhaustively; nobody asked *and how does the writer get
    /// back*. Two of Plan's four left-hand tabs took a column apiece from a
    /// subject their panes could not write — the old research pane wrote its own
    /// private selection, `TrashView` wrote nothing — so the region, scrap, line
    /// and item inspectors were replaced with no control anywhere in the window
    /// to give them back, and the subject persists through `UIState` into the
    /// next launch.
    ///
    /// **Driven through the real binder shell**, in each persona, with the
    /// subject seeded the way a persona switch delivers it: if selecting the
    /// head row of the left column cannot move the subject off the research
    /// item, the state is a trap. Row 0 is the project row in every tree, which
    /// is exactly the population this loop is about.
    ///
    /// **The segment dimension left the loop in stage 2b Task 7**, and the
    /// answer moved with it rather than shrinking: the two panes that could not
    /// write the subject are gone, every persona's left column is the tree, and
    /// the placement no longer refuses anybody. The two helpers that paired a
    /// segment with the persona and project type it was a real state in
    /// (`persona(hosting:)`, `projectType(hosting:)`) went with the enum — they
    /// existed so a mount could not model a state no writer could reach, and
    /// there is no unreachable pairing left to guard against.
    func test_everyWindowStateThatLetsAResearchSubjectStandCanAlsoClearIt() async throws {
        let stuck = BinderSubject.research("r1")
        var held = 0
        for persona in Persona.allCases {
            let placement = ProjectWindow.researchSubjectPlacement(
                persona: persona, subject: stuck)
            guard placement != .nothingMoves else { continue }
            held += 1

            let store = try await project(of: .novel)
            let (window, probe) = try await host(
                store: store, script: nil, persona: persona, subject: stuck)
            let table = try XCTUnwrap(
                firstTableView(in: window),
                "\(persona) lets a research subject take a column "
                + "(\(placement)) and its left pane puts no List in the "
                + "hierarchy at all — there is no row to select, so nothing can "
                + "clear the subject and the window's own columns never come "
                + "back")

            await select(row: 0, in: table, until: { probe.subject != stuck })

            XCTAssertNotEqual(
                probe.subject, stuck,
                "\(persona): a research subject takes a column here "
                + "(\(placement)), so some control in a visible column has to be "
                + "able to write the subject away again. The head row of the "
                + "left column wrote nothing — this is the trap: it survives a "
                + "relaunch, because the subject is persisted in `UIState`")
        }
        XCTAssertEqual(
            held,
            Persona.allCases.filter { !$0.previewsThePublishedBook }.count,
            "the control: every persona but Publish holds a research subject in "
            + "one column or the other, so a `continue` beyond the expected one "
            + "would mean the placement started refusing somebody else and this "
            + "loop went quiet about it")
    }

    /// **Publish's `.nothingMoves` is exempt from the loop above by that loop's
    /// own rule, and this is what says it is not a trap** (shell-finish stage 3b
    /// Task 5).
    ///
    /// The rule is *"every window state that lets a research subject STAND must
    /// be able to clear it"*. Publish no longer lets one stand: the placement
    /// moves neither column (spec §4's "—" row), so the centre shows the
    /// compiled book or the project at altitude and the subject is holding
    /// nothing hostage. The trap the loop guards against needs a surface that
    /// the subject took AND no control able to give it back; Publish has neither
    /// half.
    ///
    /// Driven anyway, because "exempt" is the shape of claim that goes quietly
    /// wrong: the tree is still there and its head row still writes the subject
    /// away.
    func test_publishHoldsNoResearchSubjectAndItsTreeCanStillWriteTheSubjectAway() async throws {
        let stuck = BinderSubject.research("r1")
        XCTAssertEqual(
            ProjectWindow.researchSubjectPlacement(persona: .publish, subject: stuck),
            .nothingMoves,
            "premise: Publish takes neither column for a research subject, "
            + "which is why the loop above skips it")

        let store = try await project(of: .novel)
        let (window, probe) = try await host(
            store: store, script: nil, persona: .publish, subject: stuck)
        let table = try XCTUnwrap(
            firstTableView(in: window),
            "Publish's left column is the tree like everyone else's")

        await select(row: 0, in: table, until: { probe.subject != stuck })

        XCTAssertNotEqual(
            probe.subject, stuck,
            "the subject persists through `UIState`, so even a subject holding "
            + "no column has to be clearable — otherwise a relaunch reopens onto "
            + "it and the writer cannot tell what the window is about")
    }

    /// **And the surviving form of the same question.**
    ///
    /// Since Task 7 the tree is the whole left column in every persona, so
    /// "can the writer point the window somewhere else again" is answered yes by
    /// construction — with ONE exception, and it is the reason the question
    /// survives at all: the find overlay REPLACES the column
    /// (`BinderPaneToggle.body`), so while it is up there is no row to click.
    ///
    /// **That is not a trap, and this is what says so rather than assuming it.**
    /// The 2a Critical was a trap because nothing in the window could clear the
    /// subject AND the state persisted — the binder segment was written to
    /// `UIState` on every change and Plan landed on one whose pane could not
    /// write the subject, so a relaunch reopened into it. The overlay has
    /// neither property: `treeFindActive` is window `@State` that no `UIState`
    /// carries, and `close()` puts the tree back. So the research subject may
    /// stand while find is open, the way out is Escape rather than a row, and
    /// the tree that comes back can clear it.
    func test_theFindOverlayIsNotATrapBecauseTheTreeComesBack() async throws {
        let stuck = BinderSubject.research("r1")
        for persona in Persona.allCases {
            let placement = ProjectWindow.researchSubjectPlacement(
                persona: persona, subject: stuck)
            let store = try await project(of: .novel)

            // With the overlay up there is no tree at all — which is the
            // premise, not the finding.
            let (covered, _) = try await host(
                store: store, script: nil, persona: persona,
                subject: stuck, findActive: true)
            XCTAssertNil(firstTableView(in: covered),
                         "\(persona): premise — the overlay replaces the "
                         + "column, so no tree row is available to clear a "
                         + "subject with")

            // And the way out restores it. `applyCloseFind` is the production
            // path both exits take (the ✕ and `.onExitCommand`).
            let (window, probe) = try await host(
                store: store, script: nil, persona: persona,
                subject: stuck)
            guard placement != .nothingMoves else { continue }
            let table = try XCTUnwrap(
                firstTableView(in: window),
                "\(persona): with find closed the tree is back, and it is the "
                + "control that can write the subject away")
            await select(row: 0, in: table, until: { probe.subject != stuck })
            XCTAssertNotEqual(probe.subject, stuck,
                              "\(persona): the restored tree cleared it")
        }
    }

    // MARK: - Clicking a slugline in Plan (slice 2 review, F2)

    /// **A slugline click on Plan's Structure tab really does post the
    /// screenplay's navigation** — driven with a synthesised mouse event through
    /// the real `BinderPaneToggle`, because the click is a `Button` inside a
    /// `List(.sidebar)` and whether it survives being embedded in Plan's tree is
    /// not something a test built from the view's own data can see.
    ///
    /// This is the half of F2 nobody had looked at. The other half — that the
    /// window then MOVES rather than swallowing the post — is the receiver, and
    /// it is pinned two ways: `ManuscriptNavigation.destination`'s own decision
    /// tests, and `ManuscriptForceCensusTests`'
    /// `test_everyNavigationReceiverStillRoutesThroughTheNavigation`, which now
    /// names this notification alongside its two siblings. The `.keyWindow`
    /// delivery filter itself is not exercisable headless (the OS does not grant
    /// key status), which is the same limit its two siblings sit behind — see
    /// `MaughamEventLivenessTests`.
    func test_aSluglineOnPlansTreePostsTheScreenplaysNavigation() async throws {
        let store = try await project(of: .screenplay)
        let script = try await productionScript(for: store, text: Self.twoScenes)
        let (window, _) = try await host(store: store, script: script,
                                         persona: .plan)
        let table = try XCTUnwrap(firstTableView(in: window))
        XCTAssertEqual(table.numberOfRows, 4 + emptySectionRows,
                       "precondition: project + script + 2, then the furniture")

        var posted: [Int] = []
        let observer = NotificationCenter.default.addObserver(  // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamNavigateToScene, object: nil, queue: nil
        ) { note in
            if let location = note.userInfo?["lineLocation"] as? Int {
                posted.append(location)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Row 2 — the first slugline, one below the script row. Fixed window,
        // deliberately: `posted.count == 1` is half a negative assertion — that
        // the click posted the navigation ONCE — and a wait that stopped at the
        // first arrival would no longer see a duplicate.
        await click(row: 2, in: table, window: window)

        XCTAssertEqual(posted.count, 1,
                       "the click on Plan's Structure tab must reach the "
                       + "navigation. Before the F2 fix it did reach it and "
                       + "nothing was listening; if it stops being posted the "
                       + "receiver is unreachable in the other direction")
        XCTAssertEqual(posted.first, 0,
                       "and it must carry the slugline's own line location — "
                       + "the first scene starts at 0")
    }

    /// **Where that click takes the window**, as a value. Plan does not show
    /// manuscript documents, so the ruling applies and the writer moves to
    /// Author — where the same slugline navigator is on the left and the script
    /// is in the centre.
    ///
    /// **It used to assert the landing segment too** (`.scenes`, a screenplay's
    /// document home, never `.manuscript`, which was the 2026-07-02 defect). A
    /// destination carries no binder position since stage 2b Task 7, and which
    /// tree a screenplay puts up is `TreePaneTests`'.
    func test_thatNavigationTakesAScreenplayWriterFromPlanToAuthor() {
        let destination = ManuscriptNavigation.destination(
            from: .plan, currentDetailSegment: .inspector, memory: .empty)
        XCTAssertEqual(destination.persona, .author)
        XCTAssertTrue(destination.movesPersona,
                      "the departing Plan position has to be recorded, or ⌘1 "
                      + "does not come back to the pane the writer was on")
    }

    // MARK: - Fixtures

    static let twoScenes =
        "INT. KITCHEN - DAY\n\nLarry sits.\n\nEXT. ROOF - NIGHT\n\nHe climbs.\n"

    /// Puts `text` into the screenplay's one document **through the op log** —
    /// the only way anything reaches a manuscript (ADR 0018) — and then returns
    /// the script **the way `ProjectWindow` gets it**, through
    /// `ScreenplayScriptSource`.
    ///
    /// **Why the round trip instead of one `FountainTokenizer().parse(…)`.**
    /// This file used to hand `BinderPaneToggle` a parse of a string that had
    /// never been near the project. That is a value production could not
    /// produce on Plan's tree — `lastParsedScript` came only from a mounted
    /// editor and Plan mounts none — so the assertion below passed over a pane
    /// drawing "No scenes yet" on a script with scenes (slice 2 review, F1). A
    /// fixture that injects what production cannot produce cannot fail when
    /// production stops producing it; deriving it here means the fixture is
    /// exactly as good as the seam is.
    private func productionScript(for store: ProjectStore,
                                  text: String) async throws -> FountainScript? {
        let item = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.structure,
                           where: { $0.type == .document }),
            "a screenplay has exactly one document (the Phase 3d invariant)")
        let url = store.url.appendingPathComponent(try XCTUnwrap(item.path))
        try text.write(to: url, atomically: true, encoding: .utf8)
        // `Document.load` bootstraps a doc with no op log from its file, which
        // is the sanctioned import read — after this the ops are the truth and
        // the `.fountain` is derived output.
        let doc = try await Document.load(
            url: url, device: "test", session: "s", presenter: nil)
        await doc.close()
        return ScreenplayScriptSource.derive(store: store)
    }

    private func project(of type: ProjectType) async throws -> ProjectStore {
        let name = "\(type.rawValue)-\(UUID().uuidString.prefix(6))"
        let url: URL
        switch type {
        case .shortStory:
            url = try await ProjectFactory.createShortStoryProject(named: name, in: temp.url)
        case .novel:
            url = try await ProjectFactory.createNovelProject(named: name, in: temp.url)
        case .screenplay:
            url = try await ProjectFactory.createScreenplayProject(named: name, in: temp.url)
        case .collection:
            url = try await ProjectFactory.createCollectionProject(named: name, in: temp.url)
        case .unknown:
            throw XCTSkip("`.unknown` is excluded from allCases and cannot be created")
        }
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        return store
    }

    // MARK: - Hosting and driving

    /// Mounts the binder shell production mounts for this store's type. The
    /// `switch` in the probe below is the whole point of the file: it is
    /// exhaustive, so a new shell cannot be added without answering this
    /// question for it.
    /// - Parameter subject: the window's subject before the first render, for
    ///   the census that asks whether a window state can CLEAR one. Seeded
    ///   rather than clicked, because the whole question is about a subject no
    ///   click in that state could have produced.
    private func host(store: ProjectStore,
                      script: FountainScript?,
                      persona: Persona = .author,
                      subject: BinderSubject? = nil,
                      findActive: Bool = false)
    async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        probe.subject = subject
        let frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        let hosting = NSHostingView(
            rootView: AnyView(
                BinderShellProbeView(store: store, probe: probe, script: script,
                                     persona: persona,
                                     findActive: findActive)))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        await pumpUntil(deadline: 5) { self.firstTableView(in: window) != nil }
        return (window, probe)
    }

    /// A real click, synthesised through the window — the delivery path a
    /// slugline `Button` actually takes. `selectRowIndexes` cannot stand in:
    /// scene rows carry no `.tag`, so the selection path and the Button path are
    /// two different things (`SceneNavigatorProjectRowTests` measures why).
    ///
    /// The trailing wait stays a fixed window: its one caller counts the posts
    /// the click produced, and "exactly one" is not a condition a wait can stop
    /// at without ceasing to see the second.
    private func click(row: Int, in table: NSTableView, window: NSWindow) async {
        let rect = table.rect(ofRow: row)
        let inWindow = table.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: inWindow, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(event)
            }
            pump(0.05)
        }
        await waitOut(0.4)
    }

    /// - Parameter settled: what the caller is about to assert. Given a
    ///   condition, the wait ends the moment the selection has been written
    ///   through the binding rather than burning its worst case; the caller's
    ///   own assertion still reports the failure in its own words. Given none,
    ///   the wait is a fixed window, which is what a caller asserting that the
    ///   selection changed NOTHING would need.
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

/// The left column as `ProjectWindow.binderColumn` builds it — the same shell
/// rule, the same tree rule, with a handle on the subject it writes.
@MainActor
private struct BinderShellProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    let script: FountainScript?
    let persona: Persona
    @State private var treeFindActive: Bool
    @State private var renamingItemId: String?

    /// - Parameter findActive: mount with the find overlay already up. Seeded
    ///   in `init` rather than in `.onAppear`: a frame with the tree in the
    ///   hierarchy before the overlay covers it is a frame a table query would
    ///   latch onto, and a test asserting the tree's ABSENCE would pass against
    ///   the surface it was asserting the absence of.
    init(store: ProjectStore, probe: BinderSubjectProbe, script: FountainScript?,
         persona: Persona = .author, findActive: Bool = false) {
        self.store = store
        self.probe = probe
        self.script = script
        self.persona = persona
        _treeFindActive = State(initialValue: findActive)
    }

    private var subject: Binding<BinderSubject?> {
        Binding(get: { probe.subject }, set: { probe.subject = $0 })
    }

    let treeState = BinderTreeSectionsState()

    var body: some View {
        Group {
            switch ProjectWindow.BinderShell.shell(for: store.manifest.type) {
            case .standard:
                BinderPaneToggle(
                    store: store,
                    selectedSubject: subject,
                    projectType: store.manifest.type,
                    lastParsedScript: script,
                    treeState: treeState,
                    treeFindActive: $treeFindActive,
                    persona: persona)
            case .collection:
                CollectionBinderPaneToggle(
                    store: store,
                    selectedSubject: subject,
                    treeFindActive: $treeFindActive,
                    renamingItemId: $renamingItemId,
                    treeState: treeState,
                    persona: persona)
            }
        }
    }
}
