import XCTest
import AppKit
import SwiftUI
import Observation
import MaughamCore
@testable import Maugham

/// **The keyspace keeps its promises** (shell-finish stage-3a Task 5).
///
/// ⌘⌥R, ⌘⌥O and ⌘⌥P used to open a right-pane segment. The panes they opened
/// are dying (Task 6) — Research and Palette because every tree grew its own
/// section for them (stage 2a), Outline because the project row now shows the
/// same corkboard/outline at the centre (Tasks 1–3). The keys re-point FIRST,
/// ahead of the panes' death, so a writer's muscle memory never meets a
/// dangling shortcut.
///
/// Driven the way `TreeFindOverlayTests`/`TreeTrashDisclosureTests` drive their
/// key-window commands: a probe view mounts the real tree shell
/// (`BinderPaneToggle`) and attaches the same three `.onKeyWindowCommand`
/// bodies `ProjectWindow` carries, so the post, the scope filter and the
/// receiver's own guard are all production — the only stand-in is which
/// object the write lands on.
@MainActor
final class AltitudeKeyspaceTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

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

    // MARK: - ⌘⌥O selects the project row

    /// The centre altitude view's new home is the project row (Tasks 1–3);
    /// ⌘⌥O's job is landing the writer there — the same
    /// `selectedSubject = .project` write Escape and the canvas's own
    /// `selectTheProjectRow` closure already make.
    func test_cmdOptOSelectsTheProjectRow() async throws {
        let store = try await novel()
        let chapterId = try XCTUnwrap(store.manifest.structure.first?.id,
                                      "premise: a novel opens with a chapter")
        let box = AltitudeKeyspaceProbeBox()
        box.selectedSubject = .item(chapterId)
        _ = mount(store: store, box: box)
        XCTAssertEqual(box.selectedSubject, .item(chapterId),
                       "precondition: the writer starts on a chapter, not the "
                       + "project row")

        MaughamEvent.post(.maughamSelectProjectRow, to: .keyWindow)
        await pumpUntil(deadline: 5) { box.selectedSubject == .project }

        XCTAssertEqual(box.selectedSubject, .project,
                       "⌘⌥O did not land the writer on the project row")
    }

    // MARK: - ⌘⌥R / ⌘⌥P reveal the tree's sections

    /// **The gap this key closes**: a writer who collapsed the tree's Research
    /// section could not get it back except by clicking its header. ⌘⌥R now
    /// reopens it — matching `BinderTreeSectionsState.reveal`'s own "it only
    /// ever opens" discipline (never closes what a click did).
    func test_cmdOptRExpandsTheResearchSectionTheWriterHadClosed() async throws {
        let store = try await novel()
        let box = AltitudeKeyspaceProbeBox()
        _ = mount(store: store, box: box)
        box.treeState.researchSectionExpanded = false

        MaughamEvent.post(.maughamRevealResearchSection, to: .keyWindow)
        await pumpUntil(deadline: 5) { box.treeState.researchSectionExpanded }

        XCTAssertTrue(box.treeState.researchSectionExpanded,
                      "⌘⌥R did not reopen the Research section")
    }

    /// ⌘⌥P's twin, for the Palette section.
    func test_cmdOptPExpandsThePaletteSectionTheWriterHadClosed() async throws {
        let store = try await novel()
        let box = AltitudeKeyspaceProbeBox()
        _ = mount(store: store, box: box)
        box.treeState.paletteSectionExpanded = false

        MaughamEvent.post(.maughamRevealPaletteSection, to: .keyWindow)
        await pumpUntil(deadline: 5) { box.treeState.paletteSectionExpanded }

        XCTAssertTrue(box.treeState.paletteSectionExpanded,
                      "⌘⌥P did not reopen the Palette section")
    }

    // MARK: - Refused while the find overlay covers the column

    /// **The overlay is the tree's replacement, not its sibling.**
    /// `BinderTreeSections` (and its two `Section`s) is not even mounted while
    /// `treeFindActive` is true — `BinderPaneToggle` swaps in
    /// `ProjectSearchView` instead — so ⌘⌥R/⌘⌥P must refuse rather than mutate
    /// state nothing on screen reflects, no-op and no crash.
    func test_cmdOptRIsRefusedWhileFindCoversTheColumn() async throws {
        let store = try await novel()
        let box = AltitudeKeyspaceProbeBox()
        box.treeFindActive = true
        _ = mount(store: store, box: box)
        box.treeState.researchSectionExpanded = false

        MaughamEvent.post(.maughamRevealResearchSection, to: .keyWindow)
        pump(0.3)

        XCTAssertFalse(box.treeState.researchSectionExpanded,
                       "⌘⌥R must no-op while the find overlay covers the tree")
    }

    /// ⌘⌥P's twin refusal.
    func test_cmdOptPIsRefusedWhileFindCoversTheColumn() async throws {
        let store = try await novel()
        let box = AltitudeKeyspaceProbeBox()
        box.treeFindActive = true
        _ = mount(store: store, box: box)
        box.treeState.paletteSectionExpanded = false

        MaughamEvent.post(.maughamRevealPaletteSection, to: .keyWindow)
        pump(0.3)

        XCTAssertFalse(box.treeState.paletteSectionExpanded,
                       "⌘⌥P must no-op while the find overlay covers the tree")
    }

    /// **⌘⌥O is not part of the refusal** — selecting the project row moves
    /// the centre column, which the find overlay (a left-column affordance)
    /// never covers, so nothing in the contract asks this key to refuse.
    func test_cmdOptOStillActsWhileFindCoversTheColumn() async throws {
        let store = try await novel()
        let chapterId = try XCTUnwrap(store.manifest.structure.first?.id)
        let box = AltitudeKeyspaceProbeBox()
        box.selectedSubject = .item(chapterId)
        box.treeFindActive = true
        _ = mount(store: store, box: box)

        MaughamEvent.post(.maughamSelectProjectRow, to: .keyWindow)
        await pumpUntil(deadline: 5) { box.selectedSubject == .project }

        XCTAssertEqual(box.selectedSubject, .project,
                       "⌘⌥O must still land the writer on the project row with "
                       + "find open — the overlay is a left-column affordance "
                       + "and never covers the centre")
    }

    // MARK: - Fixtures

    private func novel() async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        return store
    }

    // MARK: - Hosting

    /// A window that reports itself key — `TreeFindOverlayTests.KeyTestWindow`'s
    /// twin, needed for the same reason: every command here is key-window
    /// scoped and a window hosted by `xcodebuild`'s test host never becomes key
    /// on its own.
    private final class KeyTestWindow: SilentTestWindow {
        override var isKeyWindow: Bool { true }
    }

    private func mount(store: ProjectStore, box: AltitudeKeyspaceProbeBox) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 700)
        let hosting = NSHostingView(rootView: AnyView(
            AltitudeKeyspaceProbeView(store: store, box: box)))
        hosting.frame = frame
        let window = KeyTestWindow(contentRect: frame, styleMask: [.titled],
                                   backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        // Set BEFORE the settling pump — `.onKeyWindowCommand`'s closure
        // captures whatever `box.window` was at the body evaluation it was
        // attached from (`TreeFindOverlayTests.host`'s exact reason).
        box.window = window
        pump(0.2)
        return window
    }
}

/// The window state this suite drives and reads, standing in for
/// `ProjectWindow`'s own `@State` triad (`selectedSubject`, `treeState`,
/// `treeFindActive`).
@Observable
@MainActor
final class AltitudeKeyspaceProbeBox {
    var selectedSubject: BinderSubject? = .project
    var treeFindActive: Bool = false
    let treeState = BinderTreeSectionsState()
    var window: NSWindow?
}

/// The left column as `ProjectWindow.binderShell` builds it, plus the THREE
/// receivers this task adds — spelled exactly as `ProjectWindow`'s own
/// `.onKeyWindowCommand` arms, so the rule under test is production's rule
/// rather than a copy of it.
@MainActor
private struct AltitudeKeyspaceProbeView: View {
    let store: ProjectStore
    let box: AltitudeKeyspaceProbeBox

    private var selectedSubject: Binding<BinderSubject?> {
        Binding(get: { box.selectedSubject }, set: { box.selectedSubject = $0 })
    }

    private var treeFindActive: Binding<Bool> {
        Binding(get: { box.treeFindActive }, set: { box.treeFindActive = $0 })
    }

    var body: some View {
        BinderPaneToggle(
            store: store,
            selectedSubject: selectedSubject,
            projectType: store.manifest.type,
            lastParsedScript: nil,
            treeState: box.treeState,
            treeFindActive: treeFindActive,
            persona: .author)
        .onKeyWindowCommand(.maughamSelectProjectRow, window: box.window) { _ in
            box.selectedSubject = .project
        }
        .onKeyWindowCommand(.maughamRevealResearchSection, window: box.window) { _ in
            guard !box.treeFindActive else { return }
            box.treeState.researchSectionExpanded = true
        }
        .onKeyWindowCommand(.maughamRevealPaletteSection, window: box.window) { _ in
            guard !box.treeFindActive else { return }
            box.treeState.paletteSectionExpanded = true
        }
    }
}
