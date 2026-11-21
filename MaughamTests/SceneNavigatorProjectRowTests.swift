import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// `SceneNavigatorPane` as `BinderPaneToggle` mounts it, with a handle on the
/// subject it writes and on the scroll it asks for.
@MainActor
private struct SceneNavigatorProbeView: View {
    let store: ProjectStore
    let script: FountainScript?
    let probe: BinderSubjectProbe
    let onSelect: (Int) -> Void
    let treeState = BinderTreeSectionsState()

    var body: some View {
        TreeHostFixture.scenes(
            store: store,
            script: script,
            subject: .tree(Binding(get: { probe.subject },
                                     set: { probe.subject = $0 })),
            treeState: treeState,
            onSelect: onSelect)
    }
}

/// **The planted offender.** The navigator with its List bound STRAIGHT to the
/// subject — the shape anyone would write first, and the one the projection
/// exists to refuse. Its scene rows carry no `.tag`, so selecting one writes
/// `nil` through the binding and the window loses its subject.
///
/// It is here so that `test_selectingASceneRowDoesNotClearTheSubject` cannot be
/// vacuous: if AppKit had simply left the subject alone on an untagged row, that
/// assertion would pass against the real pane while proving nothing, and this
/// offender would pass too. It has to FAIL.
@MainActor
private struct NaiveSceneNavigatorOffender: View {
    let script: FountainScript?
    let probe: BinderSubjectProbe

    var body: some View {
        List(selection: Binding(get: { probe.subject },
                                set: { probe.subject = $0 })) {
            ProjectRowLabel(title: "Screenplay")
                .tag(BinderSubject.project)
            Text("Script").tag(BinderSubject.item("doc-1"))
            ForEach(Array((script?.sceneSummaries() ?? []).enumerated()),
                    id: \.offset) { _, summary in
                Button { } label: {
                    Text(summary.line.content).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
    }
}

/// **The second planted offender** (smoke fix, 2026-08-01). The navigator with
/// the script row added but the projection left at its old rule — accept
/// `.project`, ignore everything else — which is the shape a fix that adds the
/// row without touching `subject(_:whenListWrites:documentID:)` produces.
///
/// It compiles, it draws the row, the row highlights on click, and the trap is
/// still there: the List's `.item("doc-1")` is swallowed and the subject stays
/// on the project. That is the failure mode the reachability test has to catch,
/// so it is here to prove the test catches it.
@MainActor
private struct StaleProjectionOffender: View {
    let script: FountainScript?
    let probe: BinderSubjectProbe

    var body: some View {
        List(selection: Binding<BinderSubject?>(
            get: { probe.subject == .project ? .project : nil },
            set: { written in
                if written == .project { probe.subject = .project }
            })) {
            ProjectRowLabel(title: "Screenplay")
                .tag(BinderSubject.project)
            Text("Script").tag(BinderSubject.item("doc-1"))
            ForEach(Array((script?.sceneSummaries() ?? []).enumerated()),
                    id: \.offset) { _, summary in
                Button { } label: {
                    Text(summary.line.content).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
    }
}

/// **The third planted offender** (stage-2a Task 4). The navigator with the
/// Research section's rows added but the projection left at Task 1's
/// pass-through-foreign rule for `.research` — which is the shape a change that
/// mounts the sections without revisiting
/// `subject(_:whenListWrites:documentID:)` produces.
///
/// It compiles, it draws the research row, the row highlights on click, and the
/// write is swallowed: the window's subject never moves, so the centre column
/// keeps showing whatever it was showing and the section is decoration. That is
/// the failure mode `BinderTreeSectionsTests`'
/// `test_aResearchRowInTheScreenplayTreeMakesItselfTheSubject` has to catch, so
/// it is here to prove the test catches it.
@MainActor
private struct ForeignResearchProjectionOffender: View {
    let probe: BinderSubjectProbe

    var body: some View {
        List(selection: Binding<BinderSubject?>(
            get: {
                switch probe.subject {
                case .project: return .project
                case .item(let id): return id == "doc-1" ? .item(id) : nil
                case .research: return nil   // the Task 1 rule, kept past its date
                case .figure: return nil      // the offender draws no figure row
                case .inbox, .canvas, .palette, .edition, .none: return nil
                }
            },
            set: { written in
                switch written {
                case .project: probe.subject = .project
                case .item(let id): if id == "doc-1" { probe.subject = .item(id) }
                case .research: break        // swallowed — the defect
                case .figure, .inbox, .canvas, .palette, .edition: break
                case .none: break
                }
            })) {
            ProjectRowLabel(title: "Screenplay")
                .tag(BinderSubject.project)
            Text("Script").tag(BinderSubject.item("doc-1"))
            Section("Research") {
                Text("Ships").tag(BinderSubject.research("r-1"))
            }
        }
        .listStyle(.sidebar)
    }
}

/// **The project row in a screenplay** (slice 1 whole-branch review, Critical).
///
/// A screenplay's document home is `.scenes` and no persona offers it
/// `.manuscript`, so `BinderView` — which carries the project row for every other
/// non-collection type — is never mounted for one. Until this row existed
/// `BinderSubject.project` was **unconstructible in a screenplay**, and slice 1
/// had already deleted `StatementPane`'s `[Chapter | Project]` switch, so
/// project-scope Intent was unreachable. `ProjectSubjectReachabilityTests` is the
/// census that asks the question of every project type; this file is the
/// navigator's own behaviour, which is where it gets interesting: this pane's
/// other rows are `Button`s that navigate and select nothing.
///
/// **Mounted, not reasoned about**, for the reason `BinderProjectRowTests`
/// records — whether `List(selection:)` matches a `.tag` is invisible to a test
/// built out of the view's own data — and because the load-bearing question here
/// is what a click on an UNTAGGED row does to the binding, which is not something
/// anyone can reason their way to. It was measured, and it is why the pane's
/// selection binding is a projection.
@MainActor
final class SceneNavigatorProjectRowTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var temp: TempDirectory!
    /// A real screenplay project, for the Research and Palette sections the
    /// pane now carries (stage-2a Task 4), which this fixture leaves empty, so
    /// each contributes a header and one placeholder row. **It is also the
    /// source of the script row's document** (`scriptID`), as
    /// `BinderPaneToggle` derives it: until shell p4 Task 1 this suite handed
    /// the pane a literal `"doc-1"` no store held, which production never does.
    private var store: ProjectStore!
    /// The screenplay's one document, as production derives it.
    private var scriptID: String!

    override func setUp() async throws {
        temp = TempDirectory()
        let url = try await ProjectFactory.createScreenplayProject(
            named: "Nav-\(UUID().uuidString.prefix(6))", in: temp.url)
        store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        scriptID = try XCTUnwrap(TreeHostFixture.sceneDocumentID(in: store),
                                 "premise: a new screenplay holds its one document")
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        store = nil
        temp.cleanup()
        temp = nil
    }

    /// Rows the two empty sections contribute below every slugline: a Research
    /// header and its placeholder, a Palette header and its placeholder. Named
    /// once so the counts below read as "what the navigator had, plus the
    /// furniture", which is exactly what Task 4 changed.
    private let emptySectionRows = TreeFurniture.topRows + TreeFurniture.emptySections

    private static let twoScenes = FountainTokenizer().parse(
        "INT. KITCHEN - DAY\n\nLarry sits.\n\nEXT. ROOF - NIGHT\n\nHe climbs.\n")

    // MARK: - The row exists, and it is at the head

    func test_theProjectRowAddsExactlyOneRowAndDisplacesNoScene() async throws {
        let (window, _, _) = try await host(script: Self.twoScenes)
        let table = try XCTUnwrap(firstTableView(in: window),
                                  "the navigator's List never reached the hierarchy")

        XCTAssertEqual(table.numberOfRows, 1 + 1 + 2 + emptySectionRows,
                       "the project row and the script row should be one row "
                       + "each, at the head, and should not have displaced a "
                       + "slugline — with the two empty sections' furniture "
                       + "below all of it (stage-2a Task 4)")
    }

    func test_selectingTheHeadRowMakesTheSubjectTheProject() async throws {
        let (window, probe, _) = try await host(script: Self.twoScenes)
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertNil(probe.subject)
        await select(row: 0, in: table, until: { probe.subject == .project })

        XCTAssertEqual(probe.subject, .project,
                       "selecting the head row must produce BinderSubject.project "
                       + "— in a screenplay this is the ONLY thing that does")
    }

    // MARK: - The scene rows, which are not subjects

    /// **The measurement the whole design turns on.** A scene row carries no
    /// `.tag`, and an untagged row is selected anyway — `BinderView` measured
    /// that a `.selectionDisabled()` message row was selected and wrote `nil`.
    /// A `nil` subject blanks the centre column, so if this pane handed its List
    /// `$selectedSubject` directly, clicking a slugline would take the editor
    /// away. The projection is what refuses it.
    func test_selectingASceneRowDoesNotClearTheSubject() async throws {
        let (window, probe, _) = try await host(script: Self.twoScenes)
        let table = try XCTUnwrap(firstTableView(in: window))

        await select(row: 0, in: table, until: { probe.subject == .project })
        XCTAssertEqual(probe.subject, .project, "precondition")

        // Row 2 — row 1 is the script row, which IS a subject.
        // fixed window: asserting nothing happens — the subject must still be
        // .project after a scene row's write has had its full chance to arrive.
        await select(row: 3, in: table)
        XCTAssertEqual(probe.subject, .project,
                       "a scene row is not a subject — selecting one must leave "
                       + "the window's subject exactly where it was")
    }

    /// The offender, showing the assertion above reads something real: bound
    /// straight to the subject, the same selection DOES clear it.
    func test_plantedOffender_theNaiveBindingLosesTheSubjectOnASceneRow() async throws {
        let probe = BinderSubjectProbe()
        let window = try await mount(
            AnyView(NaiveSceneNavigatorOffender(script: Self.twoScenes, probe: probe)))
        let table = try XCTUnwrap(firstTableView(in: window))

        await select(row: 0, in: table, until: { probe.subject == .project })
        XCTAssertEqual(probe.subject, .project, "precondition")

        // fixed window: the assertion below is an XCTAssertNil, and a plant that
        // failed to fire looks exactly like one that has not landed yet.
        await select(row: 2, in: table)
        XCTAssertNil(probe.subject,
                     "PLANT DID NOT FIRE: an untagged scene row was expected to "
                     + "write nil through a direct binding. If this is nil-safe "
                     + "on this macOS, the projection in SceneNavigatorPane is "
                     + "guarding nothing and the test above is vacuous — read "
                     + "the finding, do not delete this test")
    }

    /// A real click on a slugline — synthesised through the window, not driven
    /// through `selectRowIndexes` — must still navigate, and must bring the
    /// subject back off the project onto the document.
    func test_clickingASceneNavigatesAndTakesTheSubjectOffTheProject() async throws {
        let (window, probe, navigations) = try await host(script: Self.twoScenes)
        let table = try XCTUnwrap(firstTableView(in: window))

        await select(row: 0, in: table, until: { probe.subject == .project })
        XCTAssertEqual(probe.subject, .project, "precondition")

        // Row 2 — the first slugline, one below the script row.
        await click(row: 3, in: table, window: window,
                    until: { navigations.locations.count == 1
                             && probe.subject == .item(self.scriptID) })

        XCTAssertEqual(navigations.locations.count, 1,
                       "the scene row must still navigate — its Button is the "
                       + "pane's whole purpose, and adding a selection to the "
                       + "List must not have eaten the click")
        XCTAssertEqual(probe.subject, .item(scriptID),
                       "clicking a slugline while the project row holds the "
                       + "subject must restore the document — otherwise the "
                       + "centre column stays blank and there is nothing to scroll")
    }

    // MARK: - The empty script

    /// **Every new screenplay opens here** — `createScreenplayProject` writes an
    /// empty `.fountain`, so there are no sluglines until the writer types one.
    /// The empty state must not replace the list, or a brand-new screenplay has
    /// no subject it can be given at all.
    func test_theEmptyNavigatorHasTheProjectRowAndTheScriptRowAndNothingElse() async throws {
        let (window, probe, _) = try await host(script: nil)
        let table = try XCTUnwrap(
            firstTableView(in: window),
            "the empty navigator must still be a List — both selectable rows "
            + "live in it")

        XCTAssertEqual(table.numberOfRows, 2 + emptySectionRows,
                       "the project row, the script row, and then only the two "
                       + "sections' furniture: the 'No scenes yet' message must "
                       + "not be a row — an untagged row is selectable and "
                       + "writes through the binding when it is clicked")
        await select(row: 0, in: table, until: { probe.subject == .project })
        XCTAssertEqual(probe.subject, .project)
        await select(row: 2, in: table, until: { probe.subject == .item(self.scriptID) })
        XCTAssertEqual(probe.subject, .item(scriptID))
    }

    /// A screenplay with no document at all — nothing for the script row to
    /// name, so it must not be drawn. This is not a state the factory produces;
    /// it is what `documentID == nil` means, and a row tagged with a document
    /// that does not exist would blank the centre column on click. The
    /// document is removed from the store, so the pane derives `nil` exactly
    /// as `BinderPaneToggle` would (shell p4 Task 1: no hand-given id).
    func test_aScreenplayWithNoDocumentDrawsNoScriptRow() async throws {
        try await store.deleteStructureItem(id: scriptID)
        XCTAssertNil(TreeHostFixture.sceneDocumentID(in: store), "premise: no document left")
        let probe = BinderSubjectProbe()
        let window = try await mount(AnyView(SceneNavigatorProbeView(
            store: store, script: nil, probe: probe,
            onSelect: { _ in })))
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertEqual(table.numberOfRows, 1 + emptySectionRows,
                       "with no document there is only the project row, and "
                       + "below it the two empty sections' furniture")
    }

    /// **Measured here rather than inherited.** `BinderView`'s empty state is a
    /// `VStack` with buttons in it and `CollectionPiecesPane`'s is a
    /// `ContentUnavailableView`; this one is a third thing, and task 2b's finding
    /// was that the reasoning did not transfer. So ask AppKit, at the middle of
    /// each row.
    ///
    /// **Both selectable rows**, not just the head one: the script row is the
    /// way OUT of the project subject and it lives in exactly the state this
    /// overlay is up in, so an overlay that swallowed only the second row would
    /// leave the trap intact with every assertion above still green.
    ///
    /// **And every row the sections contribute** (stage-2a Task 4). The overlay
    /// is sized to the whole list, and the sections now sit inside it — a
    /// screenplay with no sluglines is exactly the state a writer gathers
    /// research in, so an overlay that covered the research rows would take the
    /// only thing there is to do in that window.
    func test_theEmptyStateOverlayDoesNotSwallowEitherSelectableRow() async throws {
        let (window, _, _) = try await host(script: nil)
        let table = try XCTUnwrap(firstTableView(in: window))
        XCTAssertEqual(table.numberOfRows, 2 + emptySectionRows, "precondition")

        for row in 0..<table.numberOfRows {
            let hit = try XCTUnwrap(hitTestCentre(ofRow: row, in: table, window: window),
                                    "nothing at all was hit at row \(row)'s centre")
            XCTAssertTrue(hit.isDescendant(of: table),
                          "the empty-state overlay must not intercept row "
                          + "\(row)'s clicks — hit \(type(of: hit)) instead of "
                          + "the table")
        }
    }

    // MARK: - The way back out (smoke, 2026-08-01)

    /// **The way back out, smoke 2026-08-01.** On a screenplay the writer
    /// selects the project row, the centre column blanks (the project is not a
    /// document), and the escape the navigator's author built — a scene click,
    /// through `subject(_:whenNavigatingTo:)` — does not exist when there are
    /// no scenes. The row under the project is the way out: the script, which
    /// IS a subject. On an empty screenplay that is
    /// `test_theEmptyNavigatorHasTheProjectRowAndTheScriptRowAndNothingElse`;
    /// this is the same question of a screenplay that HAS sluglines, so the
    /// fix cannot be read as "the empty case only".
    ///
    /// **It has to distinguish the script row from the first slugline**, or it
    /// is vacuous. Selecting it does: a slugline is an untagged row, so
    /// selecting one writes `nil` through the projection and the subject stays
    /// on the project (`test_selectingASceneRowDoesNotClearTheSubject`); only
    /// the script row's tag moves it onto the document. It also clicked row 2
    /// until plan 3's C14 — that sluglines still navigate is
    /// `test_clickingASceneNavigatesAndTakesTheSubjectOffTheProject`'s (tripwire 33).
    func test_theRowUnderTheProjectIsTheScriptAndNotTheFirstSlugline() async throws {
        let (window, probe, _) = try await host(script: Self.twoScenes)
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertEqual(table.numberOfRows, 1 + 1 + 2 + emptySectionRows,
                       "project row, script row, the two sluglines, then the "
                       + "two sections' furniture")

        await select(row: 0, in: table, until: { probe.subject == .project })
        XCTAssertEqual(probe.subject, .project, "precondition")

        await select(row: 2, in: table, until: { probe.subject == .item(self.scriptID) })

        XCTAssertEqual(
            probe.subject, .item(scriptID),
            "the row directly under the project row must open the script — so "
            + "the navigator reads like every other binder: the project, then "
            + "the project's documents. A subject still on the project means "
            + "row 1 is an untagged slugline and the writer has no way out")
    }

    /// The plant for the way out: the script row present, the projection
    /// stale. If selecting it ever reaches a document, the reachability tests
    /// are satisfied by something other than the projection accepting the
    /// script row, and they are not measuring what they claim.
    func test_plantedOffender_aScriptRowWithTheOldProjectionIsStillATrap() async throws {
        let probe = BinderSubjectProbe()
        let window = try await mount(
            AnyView(StaleProjectionOffender(script: nil, probe: probe)))
        let table = try XCTUnwrap(firstTableView(in: window))

        await select(row: 0, in: table, until: { probe.subject == .project })
        XCTAssertEqual(probe.subject, .project, "precondition: in the trap")

        // Row 1 — the script row. fixed window: the assertion below is that the
        // write was swallowed, and a plant that failed to fire looks exactly
        // like one still in flight.
        await select(row: 1, in: table)

        XCTAssertEqual(
            probe.subject, .project,
            "PLANT DID NOT FIRE: a projection that accepts only .project was "
            + "expected to swallow the script row's write and keep the writer "
            + "trapped. If it escapes anyway, something other than "
            + "subject(_:whenListWrites:documentID:) is moving the subject and "
            + "the reachability tests above are not measuring the fix — read the "
            + "finding, do not delete this test")
    }

    /// The plant for the navigator's research row: the row present, the
    /// projection still treating `.research` as foreign. If the subject moves
    /// anyway, something other than `subject(_:whenListWrites:documentID:)` is
    /// moving it and `BinderTreeSectionsTests`' screenplay research-row test is
    /// not measuring what it claims.
    func test_plantedOffender_aResearchRowWithTheForeignProjectionIsSwallowed() async throws {
        let probe = BinderSubjectProbe()
        let window = try await mount(
            AnyView(ForeignResearchProjectionOffender(probe: probe)))
        let table = try XCTUnwrap(firstTableView(in: window))

        await select(row: 0, in: table, until: { probe.subject == .project })
        XCTAssertEqual(probe.subject, .project, "precondition")

        // Row 3 — the project row, the script row, the Research header, then the
        // note. fixed window: the assertion below is that nothing happened, and
        // a plant that failed to fire looks exactly like one still in flight.
        await select(row: 3, in: table)

        XCTAssertEqual(
            probe.subject, .project,
            "PLANT DID NOT FIRE: a projection that treats .research as foreign "
            + "was expected to swallow the research row's write and leave the "
            + "subject on the project. If it moves anyway, the projection is "
            + "not what carries a research click in this pane and the mounted "
            + "test in BinderTreeSectionsTests is vacuous — read the finding, "
            + "do not delete this test")
    }

    // MARK: - The rules, over their whole input

    func test_theSelectionShowsThisPanesOwnRowsAndNothingElse() {
        XCTAssertEqual(
            SceneNavigatorPane.listSelection(for: .project, documentID: "doc-1"),
            .project)
        XCTAssertEqual(
            SceneNavigatorPane.listSelection(for: .item("doc-1"), documentID: "doc-1"),
            .item("doc-1"),
            "the script row is a row of this pane's — it shows as selected when "
            + "the window is about the script")
        XCTAssertNil(
            SceneNavigatorPane.listSelection(for: .item("doc-9"), documentID: "doc-1"),
            "a subject naming a document this pane draws no row for must select "
            + "nothing — highlighting the script would say the window is about "
            + "the script when it is not")
        XCTAssertNil(SceneNavigatorPane.listSelection(for: nil, documentID: "doc-1"))
        XCTAssertNil(
            SceneNavigatorPane.listSelection(for: .item("doc-1"), documentID: nil),
            "with no document there is no script row to select")
        XCTAssertEqual(
            SceneNavigatorPane.listSelection(for: .research("r-1"), documentID: "doc-1"),
            .research("r-1"),
            "a research subject IS this pane's own now — the Research and "
            + "Palette sections put rows in this List that mean one (stage-2a "
            + "Task 4). Unlike a foreign document, a research id this tree does "
            + "not happen to draw highlights nothing rather than the wrong row, "
            + "so passing it through is safe as well as right")
    }

    /// **The writes the projection has to tell apart** (shell p1 Task 3):
    /// the shared click rule, with this pane's one refusal — a document it
    /// draws no row for. `.project`, the script's own item, research and the
    /// shell's rows are a click; an untagged scene row's empty write and a
    /// foreign item leave the subject alone.
    func test_onlyThisPanesOwnRowsMoveTheSubjectThroughTheList() {
        let structure = [StructureItem(id: "doc-1", title: "Scene 1", type: .document,
                                       path: "script.fountain")]
        func write(_ written: Set<BinderSubject>, over current: WindowSubject) -> WindowSubject {
            BinderTreeSelection.resolved(
                written: written, stored: [],
                shown: BinderTreeSelection.shown([], subject: current, clickedAt: nil),
                subject: current, structure: structure,
                research: [], figures: [], projectType: .screenplay,
                accepts: { SceneNavigatorPane.listSelection(for: $0, documentID: "doc-1") != nil }
            ).subject
        }
        for current in [WindowSubject.book, SubjectSamples.opened(.item("doc-1")),
                        SubjectSamples.opened(.canvas)] {
            let where_ = "current: \(current)"
            for row: BinderSubject in [.project, .item("doc-1"), .research("r-1"),
                                       .inbox, .canvas, .palette] {
                XCTAssertEqual(
                    write([row], over: current),
                    ClickRule.resolve(row, gesture: .click, current: current,
                                      structure: structure, projectType: .screenplay),
                    "\(row) is this pane's own row — a click (\(where_))")
            }
            XCTAssertEqual(write([], over: current), current,
                           "an untagged scene row's empty write moves nothing (\(where_))")
            XCTAssertEqual(write([.item("doc-9")], over: current), current,
                           "this pane draws no row for another document — such an "
                           + "item arriving through the List is not a signal it can "
                           + "act on (\(where_))")
        }
    }

    /// **A scene click opens the script** from every subject whose centre is
    /// not a document, through the click rule; a document already open is left
    /// alone.
    func test_aSceneClickRestoresTheDocumentFromEverySubjectThatIsNotADocument() {
        let structure = [StructureItem(id: "doc-1", title: "Scene 1", type: .document,
                                       path: "script.fountain")]
        func navigate(_ current: WindowSubject, to doc: String?) -> WindowSubject {
            SceneNavigatorPane.subject(current, whenNavigatingTo: doc,
                                       structure: structure, projectType: .screenplay)
        }
        XCTAssertEqual(navigate(.book, to: "doc-1"), SubjectSamples.opened(.item("doc-1")))
        XCTAssertEqual(navigate(SubjectSamples.opened(.item("doc-2")), to: "doc-1"),
                       SubjectSamples.opened(.item("doc-2")),
                       "the navigator does not know better than the window which "
                       + "document is open")
        XCTAssertEqual(navigate(.book, to: nil), .book,
                       "a screenplay with no document at all has nothing to restore to")
        XCTAssertEqual(navigate(SubjectSamples.opened(.research("r-1")), to: "doc-1"),
                       SubjectSamples.opened(.item("doc-1")),
                       "a note in the centre: the scene post would reach no editor")
        XCTAssertEqual(navigate(SubjectSamples.opened(.inbox), to: "doc-1"),
                       SubjectSamples.opened(.item("doc-1")))
        XCTAssertEqual(navigate(SubjectSamples.opened(.canvas), to: "doc-1"),
                       WindowSubject(open: .canvas, faces: .item("doc-1")),
                       "with the canvas open a piece click moves the faces")
    }

    // MARK: - Hosting and driving

    /// Records what the pane asked the editor to scroll to.
    @MainActor
    private final class NavigationProbe {
        var locations: [Int] = []
    }

    private func host(
        script: FountainScript?,
        initial: BinderSubject? = nil
    ) async throws -> (NSWindow, BinderSubjectProbe, NavigationProbe) {
        let probe = BinderSubjectProbe(initial)
        let navigations = NavigationProbe()
        let window = try await mount(AnyView(SceneNavigatorProbeView(
            store: store,
            script: script,
            probe: probe,
            onSelect: { navigations.locations.append($0) })))
        return (window, probe, navigations)
    }

    private func mount(_ root: AnyView) async throws -> NSWindow {
        let window = TestWindow.mount(root, size: CGSize(width: 320, height: 600))
        windows.append(window)
        await pumpUntil(deadline: 5) { self.firstTableView(in: window) != nil }
        await pumpUntil(deadline: 2) { TreeFurniture.isSettled(in: self.firstTableView(in: window)) }
        return window
    }

    /// Drives the table's selection and lets SwiftUI's list coordinator write it
    /// back through the projection.
    ///
    /// `until` is the thing the caller's next assertion checks, so the wait costs
    /// what the write-back really takes rather than its worst case. A caller with
    /// no condition to name — a NEGATIVE assertion ("the subject did not move",
    /// "the write was swallowed"), where the window of wall clock *is* the test —
    /// passes nothing and gets the fixed wait.
    private func select(row: Int, in table: NSTableView,
                        until settled: (() -> Bool)? = nil) async {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if let settled {
            await pumpUntil(deadline: 5, settled)
        } else {
            // fixed window: no condition named — the caller is asserting an absence
            await waitOut(0.4)
        }
    }

    /// A real click at the centre of a row: down and up, through the window, so
    /// the Button in the row gets its chance exactly as it does under a mouse.
    /// `selectRowIndexes` proves nothing about a Button — it drives the table's
    /// selection directly and never touches the row's own hit-testing.
    ///
    /// `until` follows the same rule as `select`'s: name what the next assertion
    /// checks and the wait ends when it holds; name nothing and the fixed window
    /// stands, because proving a click did NOT do something needs the wall clock.
    private func click(row: Int, in table: NSTableView, window: NSWindow,
                       until settled: (() -> Bool)? = nil) async {
        let rect = table.rect(ofRow: row)
        let inWindow = table.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: inWindow, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(event)
            }
            pump(0.05)
        }
        if let settled {
            await pumpUntil(deadline: 5, settled)
        } else {
            // fixed window: no condition named — the caller is asserting an absence
            await waitOut(0.4)
        }
    }

    private func hitTestCentre(ofRow row: Int, in table: NSTableView,
                               window: NSWindow) -> NSView? {
        guard let content = window.contentView else { return nil }
        let rect = table.rect(ofRow: row)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        // `hitTest(_:)` takes a point in the receiver's SUPERVIEW's
        // coordinates. The hosting content view is flipped and its superview
        // is not, so converting into the content view mirrored every row
        // top-to-bottom — invisible while the overlay sat centred (shell p1
        // Task 3 moved it to the column's foot).
        let point = content.superview.map { $0.convert(centre, from: table) }
            ?? content.convert(centre, from: table)
        return content.hitTest(point)
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
