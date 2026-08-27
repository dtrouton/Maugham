import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// `ProjectAltitudePane` is `OutlinePane` renamed (shell-finish stage 3a Task
/// 1) plus one addition: a `title` prop for the header, so the pane can show
/// the project's own name at altitude rather than the pane label "Outline".
/// This task is the rename + readiness step only — at the time, the pane
/// still mounted in the right-pane `.outline` arm (`DetailPaneToggle.swift`),
/// unchanged in behaviour. Tasks 2-3 moved it into the centre column
/// alongside that arm, and Task 6 deleted the arm outright — the centre is the
/// pane's only mount now (see `test_theCentreMountPassesTheProjectsOwnTitle`
/// below, which replaced this file's premise about `DetailPaneToggle`). What
/// this file pins is the contract the brief names: the title prop is
/// genuinely wired into the header (not the old hardcoded label), the data
/// derivation is unchanged (documents only, no per-row I/O), and the
/// corkboard's adaptive grid still produces one card per document at a
/// centre-typical width.
@MainActor
final class ProjectAltitudePaneTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - The title prop

    /// **Why a source census rather than a mounted-text assertion.** A bare
    /// SwiftUI `Text` outside a `List` row does not materialize as an
    /// `NSTextField` on this SDK (measured: macOS 26.5, Xcode 26 — the header's
    /// `Text` sits beside a segmented `Picker`, which DOES bridge to a real
    /// `AppKitPlatformViewHost<...SystemSegmentedControl>`, but the `Text`
    /// itself leaves no discrete `NSView` in the mounted hierarchy at all), and
    /// `accessibilityChildren()` returns empty from this same headless test
    /// host (the same finding `BinderProjectRowTests.swift` already recorded
    /// for `Text` inside a `List` row). So the header's rendered string is not
    /// independently observable here; what IS reliably checkable is that the
    /// header's source reads the `title` prop rather than the old literal —
    /// the actual wiring this task's contract is about.
    func test_headerReadsTheTitlePropNotTheOldHardcodedLabel() throws {
        let code = try Self.codeLines(of: "Views/ProjectAltitudePane.swift")

        XCTAssertTrue(code.contains { $0.contains("Text(title)") },
                     "the header must read the `title` prop")
        XCTAssertFalse(code.contains { $0.contains("Text(\"Outline\")") },
                       "the old hardcoded pane label must be gone, not merely "
                       + "joined by the title")
    }

    /// The census's control: a header that keeps BOTH the prop read and the old
    /// literal would satisfy a naive "contains `Text(title)`" check alone. This
    /// pins that the two assertions above are independent — the second is not
    /// simply always true because the first is.
    func test_plantedOffender_theOldLabelAlongsideTheNewPropStillFails() {
        let offender = [
            "HStack {",
            "    Text(title).font(.headline)",
            "    Text(\"Outline\")",
            "}"
        ]
        XCTAssertTrue(offender.contains { $0.contains("Text(title)") })
        XCTAssertTrue(offender.contains { $0.contains("Text(\"Outline\")") },
                     "premise: the offender really does keep both")
    }

    // MARK: - The title prop reaches the pane from its one production mount

    /// The prop is only load-bearing if the one production call site actually
    /// passes something other than a literal. `ProjectWindow`'s centre-column
    /// overlay is the pane's only mount since stage 3a Task 6 deleted the
    /// right-pane `.outline` arm this test used to read instead — pinned so a
    /// future edit cannot quietly go back to a fixed string.
    func test_theCentreMountPassesTheProjectsOwnTitle() throws {
        let code = try Self.codeLines(of: "Views/ProjectWindow.swift")

        XCTAssertTrue(
            code.contains { $0.contains("title: store.manifest.title") },
            "the centre's altitude mount must hand the pane the project's own "
            + "name, not a hardcoded pane label")
    }

    // MARK: - Data derivation unchanged (tripwire 4: no per-row I/O, documents only)

    /// `TreeWalk.collect(..., where: { $0.type == .document })` is unchanged
    /// by the rename. Pinned behaviourally: a group among the structure items
    /// must not appear as a row, only its document children do.
    func test_dataDerivationIsDocumentsOnlyGroupsExcluded() async throws {
        let store = try await novel(named: "Derivation")
        let group = try await store.addStructureItem(
            parentId: nil, title: "Part One", kind: .group)
        _ = try await store.addStructureItem(
            parentId: group.id, title: "Chapter 2", kind: .document(extension: "md"))
        _ = try await store.addStructureItem(
            parentId: nil, title: "Chapter 3", kind: .document(extension: "md"))

        let window = try await hostPane(store: store, layout: .table, title: "Derivation")
        let table = try await pumpUntilTableFound(in: window, expectingAtLeast: 3)

        XCTAssertEqual(table.numberOfRows, 3,
                       "one row per document (the factory's Chapter 1, plus "
                       + "Chapter 2 and Chapter 3) — the group itself is not a row")
    }

    // MARK: - The corkboard's adaptive grid at a centre-typical width

    /// **Why `_FocusRingView`, not `NSButton`.** `CorkboardGrid`'s cards are
    /// `Button(...).buttonStyle(.plain)` wrapping composed label content, and
    /// on this SDK that does not materialize a discrete `NSButton` either
    /// (measured alongside the header finding above) — but each button DOES
    /// mount its own focus-ring container as a real `NSView` in the hierarchy,
    /// one per `ForEach` row, at the frame the grid actually laid it out to.
    /// Counting that container is what is actually observable here, and it
    /// still answers the brief's question: does the grid produce one card per
    /// document at a width this window actually got.
    func test_corkboardProducesOneCardPerDocumentAtACentreTypicalWidth() async throws {
        let store = try await novel(named: "Corkboard")
        for title in ["Chapter 2", "Chapter 3", "Chapter 4"] {
            _ = try await store.addStructureItem(
                parentId: nil, title: title, kind: .document(extension: "md"))
        }
        let documentCount = TreeWalk.collect(
            in: store.manifest.structure, where: { $0.type == .document }).count
        XCTAssertEqual(documentCount, 4, "premise: four documents to card up")

        let requestedWidth: CGFloat = 720
        let window = try await hostPane(store: store, layout: .cards,
                                        title: "Corkboard", windowWidth: requestedWidth)
        // Read the width off the window this display actually granted, per
        // the CI-display rule — a runner narrower than requested still gives
        // a grid wide enough for at least one 180pt-minimum column.
        let actualWidth = window.frame.width
        try XCTSkipUnless(actualWidth >= 200,
                          "this display mounted only \(actualWidth)pt, too "
                          + "narrow to afford even one adaptive column")

        let cards = try await pumpUntilCardsFound(in: window, expectingAtLeast: documentCount)
        XCTAssertEqual(cards.count, documentCount,
                       "one card per document, whatever this window's actual "
                       + "width laid the columns out at")
    }

    // MARK: - Fixtures and hosting

    private func novel(named name: String) async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "\(name)-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        return store
    }

    private func hostPane(store: ProjectStore, layout: OutlineLayout, title: String,
                          windowWidth: CGFloat = 520) async throws -> NSWindow {
        let window = TestWindow.mount(
            AnyView(AltitudeProbeView(store: store, initialLayout: layout, title: title)),
            size: CGSize(width: windowWidth, height: 600))
        windows.append(window)
        pump()
        return window
    }

    private func pumpUntilTableFound(in window: NSWindow, expectingAtLeast rows: Int) async throws -> NSTableView {
        var found: NSTableView?
        _ = await pumpUntil(deadline: 5) {
            found = self.firstView(NSTableView.self, in: window)
            return (found?.numberOfRows ?? 0) >= rows
        }
        return try XCTUnwrap(found, "the outline table never mounted")
    }

    /// See this file's doc comment on `test_corkboardProducesOneCardPerDocumentAtACentreTypicalWidth`
    /// for why a focus-ring container, rather than `NSButton`, is the signal.
    private func pumpUntilCardsFound(in window: NSWindow, expectingAtLeast count: Int) async throws -> [NSView] {
        var found: [NSView] = []
        _ = await pumpUntil(deadline: 5) {
            found = self.collect(NSView.self, in: window)
                .filter { String(describing: type(of: $0)).contains("FocusRingView") }
            return found.count >= count
        }
        return found
    }

    private func firstView<T: NSView>(_ type: T.Type, in window: NSWindow) -> T? {
        collect(type, in: window).first
    }

    private func collect<T: NSView>(_ type: T.Type, in window: NSWindow) -> [T] {
        guard let root = window.contentView else { return [] }
        var found: [T] = []
        collect(type, in: root, into: &found)
        return found
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }

    private func pump(_ seconds: TimeInterval = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Census helpers

    private static var appSourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
    }

    private static func codeLines(of relativePath: String) throws -> [String] {
        let url = appSourceDir.appendingPathComponent(relativePath)
        return SourceScan.codeLines(of: try String(contentsOf: url, encoding: .utf8))
    }
}

/// `ProjectAltitudePane` hosted with a fixed layout choice, standing in for
/// where the pane is mounted today — the centre column's overlay holds the
/// layout as `@State` on `ProjectWindow`; this probe does the same at a
/// smaller scale rather than standing up the whole window.
@MainActor
private struct AltitudeProbeView: View {
    let store: ProjectStore
    @State var initialLayout: OutlineLayout
    let title: String

    var body: some View {
        ProjectAltitudePane(
            store: store,
            layout: $initialLayout,
            selectedSubject: .constant(nil),
            title: title)
    }
}
