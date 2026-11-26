import XCTest
import MaughamCore
@testable import Maugham

/// **Brief's line is saved without a blur** (shell p3 final wave, I1).
///
/// The line used to commit only on focus loss, Return and `.onDisappear`. At
/// ⌘Q no view disappears and a teardown `Task` never runs, so a line typed
/// and not left was gone on relaunch. It now also commits 500 ms after the
/// last edit (the old Inspector's debounce), and a pending line is written by
/// `DocumentStore.flushPendingSave` — the one door ⌘S, a window's close and
/// ⌘Q's `closeForQuit` already settle every debounced editor through.
@MainActor
final class BriefLineSaveTests: XCTestCase {

    private func synopsis(_ id: String, in store: ProjectStore) -> String? {
        TreeWalk.find(id: id, in: store.manifest.structure)?.synopsis
    }

    func test_theLineIsWrittenOnADebounceWithNoBlur() async throws {
        let f = try await StatementMountFixture.novel(named: "brief-line-debounce")
        addTeardownBlock { await f.closeAndTearDown() }
        let line = "A line typed and never left"

        f.documentStore.scheduleBriefLine(docId: f.documentItemId, line: line)
        XCTAssertNotEqual(synopsis(f.documentItemId, in: f.store), line,
                          "premise: debounced, not written in the same turn")
        await pumpUntil(deadline: 3) { self.synopsis(f.documentItemId, in: f.store) == line }
        XCTAssertEqual(synopsis(f.documentItemId, in: f.store), line,
                       "the line lands on its own, with no blur, Return or disappear")
    }

    /// ⌘Q: `QuitCoordinator` → `ProjectSession.closeForQuit` →
    /// `DocumentStore.close` → `flushPendingSave`. Nothing else runs.
    func test_aPendingLineIsWrittenByTheStoresCloseAtQuit() async throws {
        let f = try await StatementMountFixture.novel(named: "brief-line-quit")
        addTeardownBlock { await f.closeAndTearDown() }
        let line = "Typed a moment before ⌘Q"

        f.documentStore.scheduleBriefLine(docId: f.documentItemId, line: line)
        await f.documentStore.close()

        let reopened = try await ProjectStore.load(from: f.projectURL)
        XCTAssertEqual(synopsis(f.documentItemId, in: reopened), line,
                       "the line is on disk after the close ⌘Q waits for")
    }

    /// Two pieces' lines pending at once: neither drops the other.
    func test_twoPiecesLinesPendingTogetherAreBothWritten() async throws {
        let f = try await StatementMountFixture.novel(named: "brief-line-two")
        addTeardownBlock { await f.closeAndTearDown() }
        let first = f.documentItemId
        let second = try await f.store.addStructureItem(
            parentId: nil, title: "Second", kind: .document(.markdown)).id

        f.documentStore.scheduleBriefLine(docId: first, line: "First piece's line")
        f.documentStore.scheduleBriefLine(docId: second, line: "Second piece's line")
        try await f.documentStore.flushPendingSave()

        XCTAssertEqual(synopsis(first, in: f.store), "First piece's line")
        XCTAssertEqual(synopsis(second, in: f.store), "Second piece's line")
    }

    /// The field schedules on every edit; its blur, Return and disappear
    /// commit through the same slot.
    func test_briefsLineFieldSchedulesOnEveryEdit() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Maugham/Views/Brief/BriefPieceView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".onChange(of: lineDraft)"),
                      "an edit to the line schedules its save")
        XCTAssertTrue(source.contains("scheduleBriefLine("),
                      "through the store's one debounced slot")
    }
}
