import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// `SceneNavigatorPane` as `BinderPaneToggle` mounts it, with a handle on the
/// subject it writes and on the scroll it asks for.
@MainActor
private struct SceneNavigatorProbeView: View {
    let script: FountainScript?
    let probe: BinderSubjectProbe
    let documentID: String?
    let onSelect: (Int) -> Void

    var body: some View {
        SceneNavigatorPane(
            script: script,
            projectTitle: "Screenplay",
            selectedSubject: Binding(get: { probe.subject },
                                     set: { probe.subject = $0 }),
            documentID: documentID,
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

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
    }

    private static let twoScenes = FountainTokenizer().parse(
        "INT. KITCHEN - DAY\n\nLarry sits.\n\nEXT. ROOF - NIGHT\n\nHe climbs.\n")

    // MARK: - The row exists, and it is at the head

    func test_theProjectRowAddsExactlyOneRowAndDisplacesNoScene() async throws {
        let (window, _, _) = try await host(script: Self.twoScenes)
        let table = try XCTUnwrap(firstTableView(in: window),
                                  "the navigator's List never reached the hierarchy")

        XCTAssertEqual(table.numberOfRows, 1 + 1 + 2,
                       "the project row and the script row should be one row "
                       + "each, at the head, and should not have displaced a "
                       + "slugline")
    }

    func test_selectingTheHeadRowMakesTheSubjectTheProject() async throws {
        let (window, probe, _) = try await host(script: Self.twoScenes)
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertNil(probe.subject)
        await select(row: 0, in: table)

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

        await select(row: 0, in: table)
        XCTAssertEqual(probe.subject, .project, "precondition")

        // Row 2 — row 1 is the script row, which IS a subject.
        await select(row: 2, in: table)
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

        await select(row: 0, in: table)
        XCTAssertEqual(probe.subject, .project, "precondition")

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

        await select(row: 0, in: table)
        XCTAssertEqual(probe.subject, .project, "precondition")

        // Row 2 — the first slugline, one below the script row.
        await click(row: 2, in: table, window: window)

        XCTAssertEqual(navigations.locations.count, 1,
                       "the scene row must still navigate — its Button is the "
                       + "pane's whole purpose, and adding a selection to the "
                       + "List must not have eaten the click")
        XCTAssertEqual(probe.subject, .item("doc-1"),
                       "clicking a slugline while the project row holds the "
                       + "subject must restore the document — otherwise the "
                       + "centre column stays blank and there is nothing to scroll")
    }

    /// And a click on a scene while a document is already the subject leaves it
    /// alone: no churn on the editor's reload triggers.
    func test_clickingASceneWithADocumentSubjectLeavesItAlone() async throws {
        let (window, probe, navigations) = try await host(
            script: Self.twoScenes, initial: .item("doc-1"))
        let table = try XCTUnwrap(firstTableView(in: window))

        // Row 3 — the second slugline.
        await click(row: 3, in: table, window: window)

        XCTAssertEqual(navigations.locations.count, 1)
        XCTAssertEqual(probe.subject, .item("doc-1"))
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

        XCTAssertEqual(table.numberOfRows, 2,
                       "the project row and the script row, and nothing more: "
                       + "the 'No scenes yet' message must not be a row — an "
                       + "untagged row is selectable and writes through the "
                       + "binding when it is clicked")
        await select(row: 0, in: table)
        XCTAssertEqual(probe.subject, .project)
        await select(row: 1, in: table)
        XCTAssertEqual(probe.subject, .item("doc-1"))
    }

    /// A screenplay with no document at all — nothing for the script row to
    /// name, so it must not be drawn. This is not a state the factory produces;
    /// it is what `documentID == nil` means, and a row tagged with a document
    /// that does not exist would blank the centre column on click.
    func test_aScreenplayWithNoDocumentDrawsNoScriptRow() async throws {
        let probe = BinderSubjectProbe()
        let window = try await mount(AnyView(SceneNavigatorProbeView(
            script: nil, probe: probe, documentID: nil, onSelect: { _ in })))
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertEqual(table.numberOfRows, 1,
                       "with no document there is only the project row")
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
    func test_theEmptyStateOverlayDoesNotSwallowEitherSelectableRow() async throws {
        let (window, _, _) = try await host(script: nil)
        let table = try XCTUnwrap(firstTableView(in: window))
        XCTAssertEqual(table.numberOfRows, 2, "precondition")

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

    /// **The trap.** On a screenplay with no sluglines the writer selects the
    /// project row and cannot get back: the centre column blanks (the project is
    /// not a document), and the escape the navigator's author built — a scene
    /// click, through `subject(_:whenNavigatingTo:)` — does not exist, because
    /// there are no scenes. ⌘⌥O is a technical way out that nobody finds.
    ///
    /// **The property, not the row.** This asks whether the navigator offers ANY
    /// way from the project subject back onto a document, by trying every row it
    /// has. It names no row and no label on purpose: it is the reachability
    /// claim, and a future navigator that answers it differently should keep
    /// passing. `ProjectSubjectReachabilityTests` asks the mirror question — can
    /// the writer reach the project — and passed throughout the trap.
    func test_fromTheProjectAnEmptyScreenplayCanReachADocumentAgain() async throws {
        let (window, probe, _) = try await host(script: nil)
        let table = try XCTUnwrap(firstTableView(in: window))

        await select(row: 0, in: table)
        XCTAssertEqual(probe.subject, .project, "precondition: in the trap")

        let escape = await firstRowReachingADocument(
            in: table, window: window, probe: probe)

        XCTAssertEqual(
            escape, .item("doc-1"),
            "a screenplay with no sluglines must still offer a way from the "
            + "project subject back to a document — none of the navigator's "
            + "\(table.numberOfRows) row(s) produced one, so the project row is "
            + "a one-way door and the writer cannot reach the script to type")
    }

    /// The same question of a screenplay that HAS sluglines, so the fix cannot be
    /// read as "the empty case only": the way out must be there in both shapes.
    ///
    /// **This one has to distinguish the script row from the first slugline**, or
    /// it is vacuous — before the fix, clicking row 1 already restored the
    /// document, because row 1 WAS a scene and a scene click restores it. So the
    /// discriminator is the scroll: a slugline click asks the editor to scroll,
    /// and the script row must not, because it names no place in the file.
    func test_theRowUnderTheProjectIsTheScriptAndNotTheFirstSlugline() async throws {
        let (window, probe, navigations) = try await host(script: Self.twoScenes)
        let table = try XCTUnwrap(firstTableView(in: window))

        XCTAssertEqual(table.numberOfRows, 1 + 1 + 2,
                       "project row, script row, then the two sluglines")

        await select(row: 0, in: table)
        XCTAssertEqual(probe.subject, .project, "precondition")

        // Both drivers, because this test must not assume which kind of row it
        // is — see `actuate`.
        await actuate(row: 1, in: table, window: window)

        XCTAssertEqual(
            probe.subject, .item("doc-1"),
            "the row directly under the project row must open the script — so "
            + "the navigator reads like every other binder: the project, then "
            + "the project's documents")
        XCTAssertEqual(
            navigations.locations, [],
            "…and it must not be a slugline in disguise: the script row names "
            + "the whole file, so it asks for no scroll. A navigation here "
            + "means row 1 is still the first scene and this test proves nothing")

        await click(row: 2, in: table, window: window)
        XCTAssertEqual(navigations.locations.count, 1,
                       "the sluglines are still under it, and still navigate")
    }

    /// The plant for the test above: the row present, the projection stale. If
    /// this ever reaches a document, the reachability test is satisfied by
    /// something other than the projection accepting the script row, and it is
    /// not measuring what it claims.
    func test_plantedOffender_aScriptRowWithTheOldProjectionIsStillATrap() async throws {
        let probe = BinderSubjectProbe()
        let window = try await mount(
            AnyView(StaleProjectionOffender(script: nil, probe: probe)))
        let table = try XCTUnwrap(firstTableView(in: window))

        await select(row: 0, in: table)
        XCTAssertEqual(probe.subject, .project, "precondition: in the trap")

        let escape = await firstRowReachingADocument(
            in: table, window: window, probe: probe)

        XCTAssertNil(
            escape,
            "PLANT DID NOT FIRE: a projection that accepts only .project was "
            + "expected to swallow the script row's write and keep the writer "
            + "trapped. If it escapes anyway, something other than "
            + "subject(_:whenListWrites:documentID:) is moving the subject and "
            + "the reachability test above is not measuring the fix — read the "
            + "finding, do not delete this test")
    }

    /// Actuates each row in turn, restoring the trap between attempts, and
    /// returns the first subject that names a document. `nil` means the writer
    /// has no way out.
    private func firstRowReachingADocument(
        in table: NSTableView, window: NSWindow,
        probe: BinderSubjectProbe
    ) async -> BinderSubject? {
        for row in 0..<table.numberOfRows {
            await actuate(row: row, in: table, window: window)
            if case .item = probe.subject { return probe.subject }
            await select(row: 0, in: table)
        }
        return nil
    }

    /// Does to a row what a mouse does, **without knowing what kind of row it
    /// is** — which this pane needs, because it has two kinds and each answers
    /// to a different driver.
    ///
    /// **Measured while fixing the trap, and it is why this helper exists.** A
    /// synthesised `leftMouseDown`/`leftMouseUp` pair through the window drives
    /// a SwiftUI `Button` (the scene rows) but does **not** move
    /// `List(selection:)` — a click at the centre of the shipped project row,
    /// which selects perfectly under a real mouse, left the subject `nil`. So
    /// `click` alone silently skips every selectable row, and `select` alone
    /// silently skips every Button. A reachability test asking "is there ANY way
    /// out" has to try both on every row or it is measuring half the pane, and
    /// the half it skips is whichever one the next change breaks.
    private func actuate(row: Int, in table: NSTableView, window: NSWindow) async {
        await select(row: row, in: table)
        await click(row: row, in: table, window: window)
    }

    // MARK: - The rules, over their whole input

    func test_theSelectionShowsThisPanesOwnTwoRowsAndNothingElse() {
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
    }

    /// **The three writes the projection has to tell apart.** `.project` and the
    /// script's own item are rows; everything else — `nil` from an untagged
    /// scene row, and a foreign item — leaves the subject alone.
    func test_onlyThisPanesOwnRowsMoveTheSubjectThroughTheList() {
        for current: BinderSubject? in [nil, .project, .item("doc-1"), .item("doc-9")] {
            let where_ = "current: \(String(describing: current))"
            XCTAssertEqual(
                SceneNavigatorPane.subject(current, whenListWrites: .project,
                                           documentID: "doc-1"),
                .project, where_)
            XCTAssertEqual(
                SceneNavigatorPane.subject(current, whenListWrites: .item("doc-1"),
                                           documentID: "doc-1"),
                .item("doc-1"),
                "the script row must move the subject onto the document — this "
                + "is the way back off the project row, and on a screenplay "
                + "with no sluglines it is the ONLY one (\(where_))")
            XCTAssertEqual(
                SceneNavigatorPane.subject(current, whenListWrites: nil,
                                           documentID: "doc-1"),
                current,
                "a nil from an untagged scene row must leave the subject alone "
                + "(\(where_))")
            XCTAssertEqual(
                SceneNavigatorPane.subject(current, whenListWrites: .item("doc-9"),
                                           documentID: "doc-1"),
                current,
                "this pane draws no row for another document — such an item "
                + "arriving through the List is not a signal it can act on "
                + "(\(where_))")
        }
    }

    func test_aSceneClickRestoresTheDocumentOnlyWhenTheProjectHoldsTheSubject() {
        XCTAssertEqual(
            SceneNavigatorPane.subject(.project, whenNavigatingTo: "doc-1"),
            .item("doc-1"))
        XCTAssertEqual(
            SceneNavigatorPane.subject(nil, whenNavigatingTo: "doc-1"),
            .item("doc-1"))
        XCTAssertEqual(
            SceneNavigatorPane.subject(.item("doc-2"), whenNavigatingTo: "doc-1"),
            .item("doc-2"),
            "the navigator does not know better than the window which document "
            + "is open")
        XCTAssertEqual(
            SceneNavigatorPane.subject(.project, whenNavigatingTo: nil),
            .project,
            "a screenplay with no document at all has nothing to restore to")
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
            script: script,
            probe: probe,
            documentID: "doc-1",
            onSelect: { navigations.locations.append($0) })))
        return (window, probe, navigations)
    }

    private func mount(_ root: AnyView) async throws -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        await pumpUntil(deadline: 5) { self.firstTableView(in: window) != nil }
        return window
    }

    private func select(row: Int, in table: NSTableView) async {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        await waitOut(0.4)
    }

    /// A real click at the centre of a row: down and up, through the window, so
    /// the Button in the row gets its chance exactly as it does under a mouse.
    /// `selectRowIndexes` proves nothing about a Button — it drives the table's
    /// selection directly and never touches the row's own hit-testing.
    private func click(row: Int, in table: NSTableView, window: NSWindow) async {
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
        await waitOut(0.4)
    }

    private func hitTestCentre(ofRow row: Int, in table: NSTableView,
                               window: NSWindow) -> NSView? {
        guard let content = window.contentView else { return nil }
        let rect = table.rect(ofRow: row)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        return content.hitTest(content.convert(centre, from: table))
    }

    private func waitOut(_ seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            pump(0.02)
            try? await Task.sleep(for: .milliseconds(20))
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

    private func pumpUntil(deadline: TimeInterval, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return }
            pump(0.02)
            try? await Task.sleep(for: .milliseconds(20))
        }
        _ = condition()
    }

    private func pump(_ seconds: TimeInterval = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
