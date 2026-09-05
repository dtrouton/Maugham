import XCTest
import AppKit
import SwiftUI
import Observation
import MaughamCore
@testable import Maugham

/// The window state find lives in now, outside the view, so a test can open the
/// overlay the way `⌘⌥F`'s handler opens it and read what closing it wrote back.
/// At file scope because `@Observable` cannot expand inside a `private` nested
/// type.
@Observable
@MainActor
final class FindOverlayBox {
    var treeFindActive: Bool
    var subject: BinderSubject?
    /// The mounted window, handed in by the test after `host()` builds it.
    ///
    /// **Not `WindowAccessor`**, which is how production resolves it: its
    /// `DispatchQueue.main.async` write never landed under a hosted test mount
    /// (measured 2026-08-09 — the receiver's window stayed nil and every
    /// key-window post was dropped by the real filter, silently). Handing the
    /// real window in keeps the whole delivery path production — the post, the
    /// scope filter, the receiver helper — and stubs only the lookup.
    var window: NSWindow?
    init(treeFindActive: Bool) {
        self.treeFindActive = treeFindActive
    }
}

/// **Find in Project is an overlay of the left column** (shell-finish stage 2b
/// Task 1) — the first of the strip's rivals to go, and the one that had to go
/// first because it was a *state* wearing a segment's clothes.
///
/// What that means, and what this suite holds:
///
/// - `⌘⌥F` writes `treeFindActive` and nothing else. It used to write a `.find`
///   binder segment, which is how find came to be in the strip at all; the
///   strip and the segment are both gone (Task 7).
/// - The overlay REPLACES the column while it is up — strip included, since a
///   strip left visible underneath would let the writer change what is behind
///   the panel they are looking at.
/// - The ✕ and Escape are one route, not two: both call
///   `ProjectSearchView.close()`, which posts `.maughamCloseFind`, whose handler
///   runs `ProjectWindow.applyCloseFind` — the flag and the results cleared
///   together. Closing moves the binder nowhere, because the column it was
///   covering is still there.
/// - A match click writes the window's SUBJECT, research matches included. That
///   was a recorded gap for two slices (an old pane's own selection alone, over
///   a centre column find had taken hostage), and the overlay is what closed it.
///
/// **The salvaged contract**, re-homed here from
/// `BinderSegmentPickerMountTests`' AX reachability class: the command reaches
/// find's content in a persona whose picker was not in the hierarchy at all. It
/// is asserted in every persona here rather than in Author alone.
@MainActor
final class TreeFindOverlayTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

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

    // MARK: - Opening: every persona, and the strip never mediates it

    /// **The salvaged contract, widened.** `⌘⌥F` never touched the picker,
    /// clicked a segment or consulted `visibleSegments` — and now there is no
    /// segment for it to select either. Mounted in every persona of every
    /// project type: the field appears, and the segmented control that was there
    /// (in Plan) or was not (in Author, whose list is one element long) is gone
    /// while the overlay is up, because the overlay is the whole column.
    func test_theCommandReachesFindsContentInEveryPersonaWithNoStripInvolved() async throws {
        for type in ProjectType.allCases where type != .unknown {
            let store = try await project(of: type)
            for persona in Persona.allCases {
                let box = FindOverlayBox(treeFindActive: false)
                let window = host(box, FindOverlayProbeView(
                    store: store, box: box, persona: persona))
                XCTAssertNil(queryField(in: window),
                             "\(persona)/\(type) premise: find is not open yet")

                // Exactly what the real `.maughamFindInProject` handler does:
                // one write, to the window's own state, with no persona,
                // segment or picker consulted.
                box.treeFindActive = true
                await pumpUntil(deadline: 5) { self.queryField(in: window) != nil }

                XCTAssertNotNil(queryField(in: window),
                                "\(persona)/\(type): the Find command did not "
                                + "reach its content")
                XCTAssertNil(segmentedControl(in: window),
                             "\(persona)/\(type): a segmented control is in "
                             + "the hierarchy under the overlay — the overlay "
                             + "replaces the whole column, and since Task 7 "
                             + "there is no strip for it to be replacing")
            }
        }
    }

    /// **The centre column is untouched, so the footer cannot be taken away.**
    /// Denver's 2026-08-02 ruling — running `⌘⌥F` must not silently remove the
    /// goal capsule, the session words and the `¶id`/element readout — used to
    /// be carried by `BinderSegment.showsManuscriptStatusFooter`'s `.find` arm.
    /// It holds by construction now: the gate's inputs are the persona, the
    /// subject and (since Task 8) the palette wall, and opening the overlay
    /// writes none of them. (The predicate the `.find` arm lived on was deleted
    /// in stage 2b Task 6 and the gate re-based onto the persona; the segment
    /// left the gate's inputs entirely in Task 7; Task 8 added the wall term
    /// and the overlay does not touch that either. This assertion is what says
    /// the ruling survived all three moves, because it never depended on the
    /// arm.) `showsPaletteWall` is fixed at `false` throughout — this test is
    /// about the overlay's independence from the gate, not the wall's own
    /// effect on it, which is `ResearchSubjectRoutingTests`'
    /// `test_theManuscriptStatusFooterIsSilentUnderThePaletteWall`.
    func test_openingTheOverlayCannotTakeTheStatusFooterAway() async throws {
        let store = try await project(of: .novel)
        // The project's OWN first chapter, not a made-up id: since stage 3a Task
        // 2 the gate resolves the subject against the manifest, and a subject
        // naming nothing is the altitude view — which has no footer to lose, so
        // the premise below would pass vacuously for the wrong reason.
        let structure = store.manifest.structure
        let document = try XCTUnwrap(
            TreeWalk.first(in: structure, where: { $0.type == .document }),
            "fixture precondition: a novel opens with a chapter")
        let subject = BinderSubject.item(document.id)
        for persona in Persona.allCases {
            let box = FindOverlayBox(treeFindActive: false)
            box.subject = subject
            let window = host(box, FindOverlayProbeView(
                store: store, box: box, persona: persona))
            let before = ProjectWindow.showsStatusFooter(
                persona: persona, subject: box.subject, showsPaletteWall: false,
                structure: structure)

            box.treeFindActive = true
            await pumpUntil(deadline: 5) { self.queryField(in: window) != nil }

            let after = ProjectWindow.showsStatusFooter(
                persona: persona, subject: box.subject, showsPaletteWall: false,
                structure: structure)
            XCTAssertEqual(before, after,
                           "\(persona): opening find changed the footer's "
                           + "answer, so it moved one of the inputs the centre "
                           + "column is judged by")
        }
        XCTAssertTrue(
            ProjectWindow.showsStatusFooter(persona: .author, subject: subject,
                                            showsPaletteWall: false,
                                            structure: structure),
            "premise: the case the ruling is about — a writer in Author with a "
            + "document in the centre — has a footer to lose in the first place")
    }

    // MARK: - Closing: one route, reached twice

    /// **The whole route, from the call both exits make.** `close()` is the ✕'s
    /// action and `.onExitCommand`'s, held to exactly those two callers by
    /// `test_theOverlayHasExactlyOneWayDown`; from there everything is
    /// production — the real post, the real key-window filter, the real
    /// receiver and the real `applyCloseFind`. Nothing here can be skipped for
    /// want of an assistive client.
    func test_theOverlaysOneExitClosesItAndClearsTheResultsTogether() async throws {
        let store = try await project(of: .novel)
        let (box, window) = try await openOverlay(on: store, persona: .author)
        store.currentSearch = SearchResults(
            query: "loud", options: SearchOptions(), matches: [Self.researchMatch])

        ProjectSearchView.close()
        await pumpUntil(deadline: 5) { box.treeFindActive == false }

        XCTAssertFalse(box.treeFindActive, "the exit did not close the overlay")
        XCTAssertNil(store.currentSearch,
                     "the results outlived the overlay — the ✕ used to own this "
                     + "half and the handler the other, which is the split "
                     + "`applyCloseFind` exists to close")
        await pumpUntil(deadline: 5) { self.queryField(in: window) == nil }
        XCTAssertNil(queryField(in: window),
                     "the column did not come back after the overlay closed")
    }

    /// **A REAL Escape, at a REAL focused field.**
    ///
    /// The mechanism cannot be the canvas arbiter: `CanvasEscapeMonitor`'s third
    /// refusal passes Escape straight through whenever a text responder is
    /// editing, and the query field autofocuses on appear, so the overlay is in
    /// that state for essentially its whole life. This drives the key the way
    /// AppKit does — a `.keyDown` with keyCode 53 through the window, with the
    /// field editor holding first responder — because a test that called
    /// `close()` directly could not see whether the key reaches it at all.
    ///
    /// **One press is enough, and that is the measured answer** (macOS 26.5,
    /// 2026-08-09). AppKit's field-editor cancel does not consume it first here:
    /// SwiftUI's `TextField` leaves `cancelOperation:` to travel up the
    /// responder chain, where `.onExitCommand` takes it. If this ever needs a
    /// second press, pin the second press — do not delete the first assertion.
    func test_aRealEscapeAtTheFocusedQueryFieldClosesTheOverlay() async throws {
        let store = try await project(of: .novel)
        let (box, window) = try await openOverlay(on: store, persona: .author)

        let field = try XCTUnwrap(queryField(in: window))
        window.makeFirstResponder(field)
        pump(0.2)
        XCTAssertTrue(
            CanvasEscapeMonitor.isEditingText(window.firstResponder),
            "premise: the writer's keyboard is in the query field, which is the "
            + "state the canvas arbiter refuses to act in")

        window.sendEvent(Self.escapeKeyEvent(for: window))
        await pumpUntil(deadline: 5) { box.treeFindActive == false }

        XCTAssertFalse(box.treeFindActive,
                       "a real Escape at the focused field did not reach the "
                       + "overlay's exit")
        await pumpUntil(deadline: 5) { self.queryField(in: window) == nil }
        XCTAssertNil(queryField(in: window),
                     "Escape closed the flag but the column did not come back")
    }

    // MARK: - It is window state, not segment state

    /// A writer mid-search who switches persona keeps their search. The old
    /// `.find` segment rode through `applyPersonaChange` on a transient
    /// whitelist; the overlay is not in that pipeline at all, and this is what
    /// says so out loud — the pure change is applied exactly as `PersonaModifier`
    /// applies it, and the overlay is still up on the other side.
    func test_theOverlaySurvivesAPersonaSwitch() async throws {
        let store = try await project(of: .novel)
        let (box, window) = try await openOverlay(on: store, persona: .plan)

        _ = PersonaModifier.applyPersonaChange(
            to: .author, from: .plan,
            currentSegment: .inspector,
            memory: .empty)
        await waitOut(0.4)

        XCTAssertTrue(box.treeFindActive,
                      "the persona switch closed the overlay — find is window "
                      + "state, and a writer mid-search must not be ejected "
                      + "from it by ⌘2")
        XCTAssertNotNil(queryField(in: window),
                        "the flag survived but the panel did not")
    }

    // MARK: - A match click writes the subject

    /// **The recorded gap, closed.** A research match used to write an old
    /// pane's private selection alone, and the centre column was the manuscript
    /// editor regardless, so clicking a research result showed the writer their
    /// manuscript. The subject is the answer, and the two arms now differ only
    /// in which tree the path is looked up in.
    func test_aMatchClickNamesTheWindowsSubjectFromEitherTree() async throws {
        let store = try await project(of: .novel)
        let manuscriptPath = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.structure) { $0.type == .document }?.path,
            "premise: the fixture has a manuscript document to match in")
        let researchItem = try await store.addResearchTextNote(parentId: nil)
        let researchPath = try XCTUnwrap(researchItem.path)

        XCTAssertEqual(
            ProjectWindow.matchSubject(Self.match(at: manuscriptPath,
                                                  source: .manuscript), in: store),
            .item(TreeWalk.first(in: store.manifest.structure) {
                $0.path == manuscriptPath
            }!.id))
        XCTAssertEqual(
            ProjectWindow.matchSubject(Self.match(at: researchPath,
                                                  source: .research), in: store),
            .research(researchItem.id),
            "a research match must name the item as the window's SUBJECT, not "
            + "as a pane's private selection")
        XCTAssertNil(
            ProjectWindow.matchSubject(Self.match(at: "research/gone.md",
                                                  source: .research), in: store),
            "a match whose path left the manifest between the search and the "
            + "click is stale, not a place to send anyone")
    }

    /// **And the subject actually lands somewhere**, which is the half that
    /// makes the fix real rather than a rename. With the segment left alone by
    /// the overlay, stage 2a's placement routes the research subject the way it
    /// routes every other research selection.
    ///
    /// **Plan refused a research subject entirely while its left column was a
    /// picker, and Task 7 is what let it stop.** Two of Plan's four tabs put an
    /// old pane in the left column, and neither of those panes wrote the
    /// window's subject — so a subject taking one of Plan's columns would have
    /// been a room with no door, which is the 2a final review's Critical. Every
    /// persona's left column is the subject-writing tree now, so Plan routes the
    /// note beside the board like every other research selection.
    func test_theResearchSubjectFromAMatchReachesAColumn() throws {
        let subject = BinderSubject.research("res-note")
        XCTAssertEqual(
            ProjectWindow.researchSubjectPlacement(
                persona: .author, subject: subject),
            .takesTheCentre("res-note"),
            "in Author the note the writer just found must take the centre — "
            + "the whole of the gap was that it took nothing")
        XCTAssertEqual(
            ProjectWindow.researchSubjectPlacement(
                persona: .plan, subject: subject),
            .besideTheCanvas("res-note"),
            "in Plan the canvas stays mounted and the right column previews it")
        XCTAssertEqual(
            ProjectWindow.researchSubjectPlacement(
                persona: .author, subject: .item("ch-1")),
            .nothingMoves,
            "the control: a subject that names no research item moves neither "
            + "column, or every answer above is the same answer")
    }

    // **The legacy-restore test died with the field it was about** (stage 2b
    // Task 7). `UIState.binderSegment` was persisted on every change, so a quit
    // taken mid-search under the old shape left `.find` on disk — Denver's own
    // machine included — and `ProjectWindow.binderSegment(restoring:)` coerced
    // that, `.trash` and `.palette` to the persona's home while restoring
    // everything else verbatim. The field, the coercion and the enum are all
    // gone: a `ui-state.json` carrying any of those values meets a decoder with
    // no case for the key, so the value decodes away with no coercion to get
    // wrong (`UIStateTests.test_everyLegacyBinderSegmentValueDecodesAwayWithoutCost`,
    // which is where that guarantee lives now).

    // MARK: - Census: ⌘⌥F writes the overlay flag and nothing else

    /// **The half a mounted probe cannot see.** The probe drives the write the
    /// handler makes; this reads the handler. `⌘⌥F` writing a second piece of
    /// window state would leave every test above green — the overlay would open
    /// AND something else would move — so the handler's body is read for exactly
    /// one write.
    ///
    /// **The offender this replaced cannot be spelled any more** (stage 2b Task
    /// 7): it asked, with a planted offender, that nothing wrote
    /// `binderSegment = .find`, and both the field and the enum are gone. The
    /// question that outlives it is the one the segment write was an instance of
    /// — *does opening find move anything but find?* — and it is asked of the
    /// handler's own body rather than of a spelling.
    func test_theFindCommandsHandlerWritesNothingButTheOverlayFlag() throws {
        let text = try source("Maugham/Views/ProjectWindow.swift")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let start = try XCTUnwrap(
            lines.firstIndex(where: { $0.contains("(.maughamFindInProject,") }),
            "no receiver for the Find command at all in ProjectWindow")
        let body = lines[(start + 1)..<min(start + 6, lines.count)]
            .prefix(while: { !$0.contains("}") })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        XCTAssertEqual(body, ["treeFindActive = true"],
                       "⌘⌥F must write the overlay flag and nothing else. A "
                       + "second write here is a writer taken somewhere they "
                       + "did not ask to go — which is what the `.find` segment "
                       + "write was, and what closing find then had to undo.")
    }

    /// And the positive half, spelled without the body slicing above so the two
    /// cannot fail for the same reason: deleting the write outright leaves no
    /// wrong spelling for any census to find — `⌘⌥F` would simply stop doing
    /// anything.
    func test_theCommandsHandlerOpensTheOverlay() throws {
        let text = try source("Maugham/Views/ProjectWindow.swift")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let start = try XCTUnwrap(
            lines.firstIndex(where: { $0.contains("(.maughamFindInProject,") }),
            "no receiver for ⌘⌥F at all in ProjectWindow")
        let body = lines[start..<min(start + 5, lines.count)].joined(separator: "\n")
        XCTAssertTrue(body.contains("treeFindActive = true"),
                      "⌘⌥F no longer opens the find overlay")
    }

    /// The ✕ and Escape are ONE route. Both live in `ProjectSearchView`, and
    /// both must call `close()` — a second spelling of "set the flag and clear
    /// the results" beside it is the shape this task deleted.
    func test_theOverlayHasExactlyOneWayDown() throws {
        let text = try source("Maugham/Views/ProjectSearchView.swift")
        XCTAssertEqual(
            text.components(separatedBy: "Self.close()").count - 1, 2,
            "the ✕ and `.onExitCommand` are this view's two callers of "
            + "`close()`; a third caller, or a missing one, means the routes "
            + "out of find have stopped agreeing")
        XCTAssertFalse(text.contains("store.clearSearch()"),
                       "the view clears the search itself again — that half "
                       + "belongs to `ProjectWindow.applyCloseFind`, with the "
                       + "flag it must be cleared beside")
    }

    // MARK: - Driving it

    /// Mounts the real binder shell with the overlay already up, and waits for
    /// the panel to actually be in the hierarchy before handing it back.
    private func openOverlay(on store: ProjectStore,
                             persona: Persona) async throws
    -> (FindOverlayBox, NSWindow) {
        let box = FindOverlayBox(treeFindActive: true)
        let window = host(box, FindOverlayProbeView(store: store, box: box,
                                                    persona: persona))
        await pumpUntil(deadline: 5) { self.queryField(in: window) != nil }
        XCTAssertNotNil(queryField(in: window), "premise: the overlay is up")
        return (box, window)
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

    /// Hosted in a `KeyTestWindow` — **a window that reports itself key** —
    /// because `.maughamCloseFind` is key-window scoped and a window hosted by
    /// `xcodebuild`'s test host never becomes key even after `activate` +
    /// `makeKeyAndOrderFront` (`StatementMountFixture`'s measurement,
    /// 2026-08-01). Everything else on the path stays production: the real post,
    /// the real `shouldDeliver` filter, the real receiver helper and the real
    /// `applyCloseFind`. It is a `SilentTestWindow` for its own reason — this
    /// suite sends real key events and a declined one beeps.
    private func host(_ box: FindOverlayBox, _ view: some View) -> NSWindow {
        let window = TestWindow.mount(AnyView(view),
                                      size: CGSize(width: 320, height: 600),
                                      as: KeyTestWindow.self)
        windows.append(window)
        box.window = window
        pump(0.15)
        return window
    }

    /// A real Escape, built the way AppKit delivers one —
    /// `AssistantColumnTests.escapeKeyEvent`'s shape.
    private static func escapeKeyEvent(for window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil,
                         characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                         isARepeat: false, keyCode: 53)!
    }

    private static func match(at path: String,
                              source: SearchDocumentSource) -> SearchMatch {
        SearchMatch(documentPath: path, documentTitle: "Found",
                    documentSource: source, lineNumber: 1,
                    charRangeInDocument: NSRange(location: 0, length: 4),
                    linePreview: "loud", matchRangeInLine: NSRange(location: 0, length: 4))
    }

    private static let researchMatch = match(at: "research/note.md", source: .research)

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - Reading the hierarchy

    private func queryField(in window: NSWindow) -> NSTextField? {
        guard let root = window.contentView else { return nil }
        var found: [NSTextField] = []
        collect(NSTextField.self, in: root, into: &found)
        return found.first { $0.placeholderString == "Find in project" }
    }

    private func segmentedControl(in window: NSWindow) -> NSSegmentedControl? {
        guard let root = window.contentView else { return nil }
        var found: [NSSegmentedControl] = []
        collect(NSSegmentedControl.self, in: root, into: &found)
        return found.first
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }
}

/// The left column as `ProjectWindow.binderColumn` builds it, plus the ONE
/// receiver that closes the overlay — `.maughamCloseFind`, calling the same
/// `ProjectWindow.applyCloseFind` the production handler calls, so the rule
/// under test is the production rule rather than a copy of it.
@MainActor
private struct FindOverlayProbeView: View {
    let store: ProjectStore
    let box: FindOverlayBox
    let persona: Persona
    @State private var renamingItemId: String?

    private var treeFindActive: Binding<Bool> {
        Binding(get: { box.treeFindActive }, set: { box.treeFindActive = $0 })
    }

    private var subject: Binding<BinderSubject?> {
        Binding(get: { box.subject }, set: { box.subject = $0 })
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
                    lastParsedScript: nil,
                    treeState: treeState,
                    treeFindActive: treeFindActive,
                    persona: persona)
            case .collection:
                CollectionBinderPaneToggle(
                    store: store,
                    selectedSubject: subject,
                    treeFindActive: treeFindActive,
                    renamingItemId: $renamingItemId,
                    treeState: treeState,
                    persona: persona)
            }
        }
        .onKeyWindowCommand(.maughamCloseFind, window: box.window) { _ in
            ProjectWindow.applyCloseFind(treeFindActive: &box.treeFindActive,
                                         store: store)
        }
    }
}
