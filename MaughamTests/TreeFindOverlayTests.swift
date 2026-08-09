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
    var segment: BinderSegment
    var subject: BinderSubject?
    var researchId: String?
    /// The mounted window, handed in by the test after `host()` builds it.
    ///
    /// **Not `WindowAccessor`**, which is how production resolves it: its
    /// `DispatchQueue.main.async` write never landed under a hosted test mount
    /// (measured 2026-08-09 — the receiver's window stayed nil and every
    /// key-window post was dropped by the real filter, silently). Handing the
    /// real window in keeps the whole delivery path production — the post, the
    /// scope filter, the receiver helper — and stubs only the lookup.
    var window: NSWindow?
    init(treeFindActive: Bool, segment: BinderSegment) {
        self.treeFindActive = treeFindActive
        self.segment = segment
    }
}

/// **Find in Project is an overlay of the left column** (shell-finish stage 2b
/// Task 1) — the first of the strip's rivals to go, and the one that had to go
/// first because it was a *state* wearing a segment's clothes.
///
/// What that means, and what this suite holds:
///
/// - `⌘⌥F` writes `treeFindActive` and nothing else. It used to write
///   `binderSegment = .find`, which is how find came to be in the strip at all;
///   nothing selects `.find` any more, in any persona.
/// - The overlay REPLACES the column while it is up — strip included, since a
///   strip left visible underneath would let the writer change what is behind
///   the panel they are looking at.
/// - The ✕ and Escape are one route, not two: both call
///   `ProjectSearchView.close()`, which posts `.maughamCloseFind`, whose handler
///   runs `ProjectWindow.applyCloseFind` — the flag and the results cleared
///   together. Closing moves the binder nowhere, because the column it was
///   covering is still there.
/// - A match click writes the window's SUBJECT, research matches included. That
///   was a recorded gap for two slices (`selectedResearchId` alone, over a
///   centre column find had taken hostage), and the overlay is what closed it.
///
/// **The salvaged contract**, re-homed here from
/// `BinderSegmentPickerMountTests`' AX reachability class: the command reaches
/// find's content in a persona whose picker is not in the hierarchy at all. It
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
                let box = FindOverlayBox(treeFindActive: false,
                                         segment: persona.binderHome(for: type))
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
                             "\(persona)/\(type): the strip is still in the "
                             + "hierarchy under the overlay — the overlay "
                             + "replaces the column, strip included")
                XCTAssertEqual(box.segment, persona.binderHome(for: type),
                               "\(persona)/\(type): opening find moved the "
                               + "binder segment. It must move nothing: that is "
                               + "what keeps the status footer's ruling true, "
                               + "and what makes closing a reveal rather than a "
                               + "return")
            }
        }
    }

    /// **The centre column is untouched, so the footer cannot be taken away.**
    /// Denver's 2026-08-02 ruling — running `⌘⌥F` must not silently remove the
    /// goal capsule, the session words and the `¶id`/element readout — used to
    /// be carried by `BinderSegment.showsManuscriptStatusFooter`'s `.find` arm.
    /// It holds by construction now: the gate's two inputs are the segment and
    /// the subject, and opening the overlay writes neither.
    func test_openingTheOverlayCannotTakeTheStatusFooterAway() async throws {
        let store = try await project(of: .novel)
        let subject = BinderSubject.item("ch-1")
        for persona in Persona.allCases {
            let home = persona.binderHome(for: .novel)
            let box = FindOverlayBox(treeFindActive: false, segment: home)
            box.subject = subject
            let window = host(box, FindOverlayProbeView(
                store: store, box: box, persona: persona))
            let before = ProjectWindow.showsStatusFooter(
                binderSegment: box.segment, subject: box.subject)

            box.treeFindActive = true
            await pumpUntil(deadline: 5) { self.queryField(in: window) != nil }

            let after = ProjectWindow.showsStatusFooter(
                binderSegment: box.segment, subject: box.subject)
            XCTAssertEqual(before, after,
                           "\(persona): opening find changed the footer's "
                           + "answer, so it moved one of the two inputs the "
                           + "centre column is judged by")
        }
        XCTAssertTrue(
            ProjectWindow.showsStatusFooter(
                binderSegment: Persona.author.binderHome(for: .novel),
                subject: subject),
            "premise: the case the ruling is about — a writer in Author with a "
            + "document in the centre — has a footer to lose in the first place")
    }

    // MARK: - Closing: one route, reached twice

    /// **The whole route, from the call both exits make.** `close()` is the ✕'s
    /// action and `.onExitCommand`'s, held to exactly those two callers by
    /// `test_theOverlayHasExactlyOneWayDown`; from there everything is
    /// production — the real post, the real key-window filter, the real
    /// receiver and the real `applyCloseFind`. Nothing here can be skipped for
    /// want of an assistive client, which is why the ✕'s own press is a second
    /// test rather than this one.
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

    /// The ✕ itself, pressed through the accessibility tree — the only way to
    /// reach a SwiftUI `Button`'s action from a test. Skips rather than fails
    /// where no assistive client can attach to the process, the idiom
    /// `AssistantColumnTests.findButton` established; the route it presses is
    /// asserted unconditionally above.
    func test_theCloseButtonPressesThatExit() async throws {
        let store = try await project(of: .novel)
        let (box, window) = try await openOverlay(on: store, persona: .author)

        let close = try closeButton(in: window)
        _ = close.perform(NSSelectorFromString("accessibilityPerformPress"))
        await pumpUntil(deadline: 5) { box.treeFindActive == false }

        XCTAssertFalse(box.treeFindActive, "the ✕ did not close the overlay")
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
    /// `.find` segment rode through `applyPersonaChange` on the transient
    /// whitelist; the overlay is not in that pipeline at all, and this is what
    /// says so out loud — the pure change is applied exactly as `PersonaModifier`
    /// applies it, and the overlay is still up on the other side.
    func test_theOverlaySurvivesAPersonaSwitch() async throws {
        let store = try await project(of: .novel)
        let (box, window) = try await openOverlay(on: store, persona: .plan)

        let change = PersonaModifier.applyPersonaChange(
            to: .author, from: .plan,
            currentSegment: .inspector,
            currentBinderSegment: box.segment,
            projectType: .novel,
            memory: .empty)
        box.segment = change.binderSegment
        await waitOut(0.4)

        XCTAssertTrue(box.treeFindActive,
                      "the persona switch closed the overlay — find is window "
                      + "state, and a writer mid-search must not be ejected "
                      + "from it by ⌘2")
        XCTAssertNotNil(queryField(in: window),
                        "the flag survived but the panel did not")
    }

    // MARK: - A match click writes the subject

    /// **The recorded gap, closed.** A research match used to write
    /// `selectedResearchId` alone, and the centre column was the manuscript
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
    /// **Plan's `.canvas` is the one segment that still refuses, and it is not
    /// this task's to change.** Its left pane is the research tree, which writes
    /// its own `selectedResearchId` rather than the window's subject, so a
    /// subject taking one of its columns would be a room with no door — the 2a
    /// final review's Critical, guarded by
    /// `BinderSegment.leftPaneWritesTheSubject`. A match clicked there is still
    /// visible: the second write puts the selection in that same tree, which is
    /// what the writer sees when the overlay comes down. Plan's `.tree` — the
    /// segment whose left column IS the subject-writing tree — routes it beside
    /// the canvas, which is where the fix is felt in Plan.
    func test_theResearchSubjectFromAMatchReachesAColumn() throws {
        let subject = BinderSubject.research("res-note")
        XCTAssertEqual(
            ProjectWindow.researchSubjectPlacement(
                binderSegment: Persona.author.binderHome(for: .novel),
                subject: subject),
            .takesTheCentre("res-note"),
            "in Author the note the writer just found must take the centre — "
            + "the whole of the gap was that it took nothing")
        XCTAssertEqual(
            ProjectWindow.researchSubjectPlacement(
                binderSegment: .tree, subject: subject),
            .besideTheCanvas("res-note"),
            "on Plan's tree the canvas stays mounted and the right column "
            + "previews it")
        XCTAssertEqual(
            ProjectWindow.researchSubjectPlacement(
                binderSegment: Persona.plan.binderHome(for: .novel),
                subject: subject),
            .segmentStands,
            "Plan's canvas home still refuses a research subject, and must — "
            + "its left pane cannot write the subject, so taking a column "
            + "would strand the writer in a state they cannot clear")
    }

    /// **The one place `.find` can still arrive from: a `UIState` written by an
    /// earlier build.** `binderSegment` is persisted on every change, so a quit
    /// taken mid-search under the old shape leaves `.find` on disk — Denver's
    /// own machine included — and restoring it verbatim would put a phantom Find
    /// segment in the strip over a pane that is now the tree. Everything else
    /// must still restore as itself, out-of-persona selections included, which
    /// is the half a coercion is always in danger of eating.
    /// **`.trash` joined `.find` here in shell-finish stage 2b Task 2's fix
    /// round 1** — a review-caught Critical, not the original task's call
    /// (which restored it verbatim, same as every other still-itself
    /// segment). Restoring it verbatim didn't just land the writer somewhere
    /// odd, the way an inert `.find` fallback would have: the picker's own
    /// append-if-selected fallback re-adds a phantom Trash tab even with
    /// `hasTrash: false`, and both toggles' `.trash` switch arm renders the
    /// same trashed rows a SECOND time in the main area — a duplicate, not
    /// merely a stale destination.
    ///
    /// **`.palette` joined the two here in stage 2b Task 5** — same precedent,
    /// different shape: the wall's inspector auto-hide no longer keys off this
    /// segment (`applyPaletteWallChange`'s doc comment), so restoring it
    /// verbatim would land the writer on a segment that no longer stashes the
    /// inspector on entry. Unlike find and trash, the CASE itself survives
    /// until Task 7 — only the restore coercion moved early.
    func test_aSavedFindTrashOrPaletteSegmentIsRestoredAsThePersonasHome() {
        for persona in Persona.allCases {
            for type in ProjectType.allCases where type != .unknown {
                for legacy in [BinderSegment.find, .trash, .palette] {
                    XCTAssertEqual(
                        ProjectWindow.binderSegment(restoring: legacy, persona: persona,
                                                    projectType: type),
                        persona.binderHome(for: type),
                        "\(persona)/\(type): a legacy \(legacy) segment must "
                        + "restore as this persona's home")
                }
                XCTAssertEqual(
                    ProjectWindow.binderSegment(restoring: .manuscript,
                                                persona: persona, projectType: type),
                    .documentHome(for: type),
                    "\(persona)/\(type): the screenplay coercion still stands")
                for saved in [BinderSegment.tree, .scenes, .research, .canvas] {
                    XCTAssertEqual(
                        ProjectWindow.binderSegment(restoring: saved, persona: persona,
                                                    projectType: type),
                        saved,
                        "\(persona)/\(type): \(saved) must restore as itself — "
                        + "the picker appends an out-of-persona selection so it "
                        + "renders highlighted, and coercing here is what ate "
                        + "the writer's last explicit choice in the right pane")
                }
            }
        }
    }

    // MARK: - Census: nothing selects the segment any more

    /// **The half a mounted probe cannot see.** The probe drives the write the
    /// handler makes; this reads the handler. `⌘⌥F` writing `.find` again would
    /// leave every test above green — the overlay would open AND the binder
    /// would move — so the offending spelling is asked for by name, with a
    /// planted offender proving the pattern still matches something.
    func test_nothingInTheWindowSelectsTheFindSegment() throws {
        let pattern = #"(?:binderSegment|segment) = \.find\b"#
        XCTAssertNotNil(
            "                    binderSegment = .find"
                .range(of: pattern, options: .regularExpression),
            "the pattern no longer matches its own planted offender, so the "
            + "census below is vacuous")

        for path in ["Maugham/Views/ProjectWindow.swift",
                     "Maugham/Views/BinderPaneToggle.swift",
                     "Maugham/Views/CollectionBinderPaneToggle.swift"] {
            let text = try source(path)
            XCTAssertFalse(text.isEmpty, "\(path): read nothing")
            let hits = text.split(separator: "\n").filter {
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                    && $0.range(of: pattern, options: .regularExpression) != nil
            }
            XCTAssertTrue(hits.isEmpty,
                          "\(path): something still selects the find segment — "
                          + "\(hits). Find is an overlay; ⌘⌥F writes "
                          + "`treeFindActive` and nothing else.")
        }
    }

    /// And the converse: the command's handler still opens the overlay. Deleting
    /// the write outright leaves no wrong spelling for the census above to find
    /// — `⌘⌥F` would simply stop doing anything.
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
        let box = FindOverlayBox(
            treeFindActive: true,
            segment: persona.binderHome(for: store.manifest.type))
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

    /// **A window that reports itself key**, because `.maughamCloseFind` is
    /// key-window scoped and a window hosted by `xcodebuild`'s test host never
    /// becomes key even after `activate` + `makeKeyAndOrderFront`
    /// (`StatementMountFixture`'s measurement, 2026-08-01). Everything else on
    /// the path stays production: the real post, the real `shouldDeliver`
    /// filter, the real receiver helper and the real `applyCloseFind`.
    ///
    /// `SilentTestWindow` for its own reason — this suite sends real key events
    /// and a declined one beeps.
    private final class KeyTestWindow: SilentTestWindow {
        override var isKeyWindow: Bool { true }
    }

    private func host(_ box: FindOverlayBox, _ view: some View) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = frame
        let window = KeyTestWindow(contentRect: frame, styleMask: [.titled],
                                   backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
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

    /// The ✕, found by the accessibility label it shares with its tooltip.
    /// `AssistantColumnTests.findButton`'s shape, verbatim in its essentials:
    /// the retry loop is because SwiftUI builds the tree lazily, and the skip is
    /// because it builds no tree at all unless an assistive client is attached.
    private func closeButton(in window: NSWindow) throws -> NSObject {
        for _ in 0..<10 {
            let tree = try axTree(in: window)
            if let hit = tree.first(where: {
                (axAttribute($0, "accessibilityRole") as? String) == "AXButton"
                    && ((axAttribute($0, "accessibilityLabel") as? String) ?? "")
                        .contains(ProjectSearchView.closeHelp)
            }) as? NSObject {
                return hit
            }
            pump(0.1)
        }
        throw XCTSkip("no button labelled \"\(ProjectSearchView.closeHelp)\" was "
                      + "built in this process")
    }

    private func axAttribute(_ element: AnyObject, _ attribute: String) -> Any? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(attribute)) else { return nil }
        return object.value(forKey: attribute)
    }

    private func axElements(under root: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 40 else { return [] }
        let children = axAttribute(root, "accessibilityChildren") as? [AnyObject] ?? []
        return [root] + children.flatMap { axElements(under: $0, depth: depth + 1) }
    }

    /// SwiftUI only builds an accessibility tree when an assistive client is
    /// attached to the process. `AssistantColumnTests`' guard.
    private func axTree(in window: NSWindow) throws -> [AnyObject] {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process, so "
                + "SwiftUI builds no accessibility tree to press a button in")
        }
        guard let root = window.contentView else { return [] }
        return axElements(under: root)
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
    @State private var paletteCardId: String?
    @State private var renamingItemId: String?

    private var segment: Binding<BinderSegment> {
        Binding(get: { box.segment }, set: { box.segment = $0 })
    }

    private var treeFindActive: Binding<Bool> {
        Binding(get: { box.treeFindActive }, set: { box.treeFindActive = $0 })
    }

    private var subject: Binding<BinderSubject?> {
        Binding(get: { box.subject }, set: { box.subject = $0 })
    }

    private var researchId: Binding<String?> {
        Binding(get: { box.researchId }, set: { box.researchId = $0 })
    }

    var body: some View {
        Group {
            switch ProjectWindow.BinderShell.shell(for: store.manifest.type) {
            case .standard:
                BinderPaneToggle(
                    store: store,
                    segment: segment,
                    selectedSubject: subject,
                    selectedResearchId: researchId,
                    selectedPaletteCardId: $paletteCardId,
                    projectType: store.manifest.type,
                    lastParsedScript: nil,
                    treeFindActive: treeFindActive,
                    persona: persona)
            case .collection:
                CollectionBinderPaneToggle(
                    store: store,
                    segment: segment,
                    selectedSubject: subject,
                    selectedResearchId: researchId,
                    selectedPaletteCardId: $paletteCardId,
                    treeFindActive: treeFindActive,
                    renamingItemId: $renamingItemId,
                    activePiece: nil,
                    onAddSharedNote: {},
                    onAddPieceNote: {},
                    persona: persona)
            }
        }
        .onKeyWindowCommand(.maughamCloseFind, window: box.window) { _ in
            ProjectWindow.applyCloseFind(treeFindActive: &box.treeFindActive,
                                         store: store)
        }
    }
}
