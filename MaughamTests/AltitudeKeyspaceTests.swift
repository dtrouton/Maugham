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

    // MARK: - ⌘⌥R / ⌘⌥P scroll the header onto screen (stage-3b Task 8)

    /// **Arrival is visible, not just true.** Expanding a section scrolled far
    /// off-screen makes `researchSectionExpanded` `true` without putting
    /// anything a writer can see — this is the mounted proof that ⌘⌥R also
    /// scrolls the header into the tree's visible rect.
    func test_cmdOptRScrollsTheResearchHeaderOntoScreenWhenItWasFarBelow() async throws {
        let store = try await novel(extraChapters: 60)
        let box = AltitudeKeyspaceProbeBox()
        let window = mount(store: store, box: box)
        box.treeState.researchSectionExpanded = false
        let table = try XCTUnwrap(firstTableView(in: window))
        // With the section closed, its header is the row right after every
        // chapter — the project row, then every chapter, then the header.
        let headerRow = 1 + store.manifest.structure.count
        XCTAssertFalse(isRowVisible(headerRow, in: table),
                       "premise: sixty chapters push the header below the "
                       + "mounted window's visible rect")

        MaughamEvent.post(.maughamRevealResearchSection, to: .keyWindow)
        await pumpUntil(deadline: 5) { self.isRowVisible(headerRow, in: table) }

        XCTAssertTrue(isRowVisible(headerRow, in: table),
                      "⌘⌥R expanded the section but did not scroll its header "
                      + "onto screen")
    }

    /// ⌘⌥P's twin — the Palette header, with the Research section closed too
    /// so the row arithmetic stays exact.
    func test_cmdOptPScrollsThePaletteHeaderOntoScreenWhenItWasFarBelow() async throws {
        let store = try await novel(extraChapters: 60)
        let box = AltitudeKeyspaceProbeBox()
        let window = mount(store: store, box: box)
        box.treeState.researchSectionExpanded = false
        box.treeState.paletteSectionExpanded = false
        let table = try XCTUnwrap(firstTableView(in: window))
        // The project row, every chapter, the (closed) Research header, then
        // the Palette header.
        let headerRow = 1 + store.manifest.structure.count + 1
        XCTAssertFalse(isRowVisible(headerRow, in: table),
                       "premise: the Palette header is off-screen too")

        MaughamEvent.post(.maughamRevealPaletteSection, to: .keyWindow)
        await pumpUntil(deadline: 5) { self.isRowVisible(headerRow, in: table) }

        XCTAssertTrue(isRowVisible(headerRow, in: table),
                      "⌘⌥P expanded the section but did not scroll its header "
                      + "onto screen")
    }

    /// **The one-shot.** An unrelated state change after consumption must not
    /// re-scroll: the request is cleared, not merely acted on once and left
    /// standing.
    func test_theScrollRequestIsClearedAfterConsumption() async throws {
        let store = try await novel()
        let box = AltitudeKeyspaceProbeBox()
        _ = mount(store: store, box: box)
        box.treeState.researchSectionExpanded = false

        MaughamEvent.post(.maughamRevealResearchSection, to: .keyWindow)
        await pumpUntil(deadline: 5) { box.treeState.scrollRequest == nil }

        XCTAssertNil(box.treeState.scrollRequest,
                     "the one-shot must clear itself once the mounted tree "
                     + "has consumed it — a request left standing would "
                     + "re-fire on any later mount")
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

    /// - Parameter extraChapters: added on top of the factory's own first
    ///   chapter — enough of them pushes the tree's furniture below a
    ///   mounted window's visible rect, which is the premise the scroll
    ///   tests need.
    private func novel(extraChapters: Int = 0) async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        for i in 0..<extraChapters {
            _ = try await store.addStructureItem(
                parentId: nil, title: "Chapter \(i + 2)",
                kind: .document(extension: "md"))
        }
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

    private func firstTableView(in window: NSWindow) -> NSTableView? {
        guard let root = window.contentView else { return nil }
        var found: [NSTableView] = []
        collect(NSTableView.self, in: root, into: &found)
        return found.first
    }

    /// **Whether `row` is actually on screen**, not merely present in the
    /// list — `documentVisibleRect` is the scroll view's own answer to what
    /// a writer can see, and `⌘⌥R`/`⌘⌥P`'s scroll contract is about that
    /// rect, not about `table.numberOfRows`.
    private func isRowVisible(_ row: Int, in table: NSTableView) -> Bool {
        guard row >= 0, row < table.numberOfRows,
              let scrollView = table.enclosingScrollView else { return false }
        return scrollView.documentVisibleRect.intersects(table.rect(ofRow: row))
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
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
            box.treeState.scrollRequest = .researchHeader
        }
        .onKeyWindowCommand(.maughamRevealPaletteSection, window: box.window) { _ in
            guard !box.treeFindActive else { return }
            box.treeState.paletteSectionExpanded = true
            box.treeState.scrollRequest = .paletteHeader
        }
    }
}
