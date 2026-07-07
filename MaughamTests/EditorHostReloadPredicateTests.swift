import XCTest
@testable import Maugham

/// Regression: renaming the currently-open document (the new-chapter flow
/// makes this near-inevitable — creation drops the row straight into rename
/// mode) moves its file through `DocumentStore.relocate`, which closes the
/// open `Document` (tripwire 14). EditorHost's reload decision keyed ONLY on
/// item id, which rename does not change — so the editor stayed bound to a
/// closed husk whose `setFullText` silently rejected every keystroke while
/// the stale `displayText` binding wiped the text view ("can't type until I
/// switch away and back", 2026-07-07). The decision must also key on the
/// item's path.
final class EditorHostReloadPredicateTests: XCTestCase {

    func test_nothingLoaded_needsReload() {
        XCTAssertTrue(EditorHost.needsReload(
            itemId: "ch-1", path: "manuscript/01-a.md",
            loadedItemId: nil, loadedPath: nil))
    }

    func test_differentItem_needsReload() {
        XCTAssertTrue(EditorHost.needsReload(
            itemId: "ch-2", path: "manuscript/02-b.md",
            loadedItemId: "ch-1", loadedPath: "manuscript/01-a.md"))
    }

    func test_sameItemSamePath_noReload() {
        XCTAssertFalse(EditorHost.needsReload(
            itemId: "ch-1", path: "manuscript/01-a.md",
            loadedItemId: "ch-1", loadedPath: "manuscript/01-a.md"))
    }

    func test_sameItem_pathChanged_needsReload() {
        // THE regression pin: rename keeps the id but moves the file; the
        // Document at the old path was closed by the typed mover.
        XCTAssertTrue(EditorHost.needsReload(
            itemId: "ch-1", path: "manuscript/01-real-title.md",
            loadedItemId: "ch-1", loadedPath: "manuscript/01-new-document.md"))
    }

    func test_sameItem_priorLoadFailed_retries() {
        // After a failed load EditorHost records the item id but no path;
        // the next trigger must retry rather than stay stuck on "Loading…".
        XCTAssertTrue(EditorHost.needsReload(
            itemId: "ch-1", path: "manuscript/01-a.md",
            loadedItemId: "ch-1", loadedPath: nil))
    }
}
