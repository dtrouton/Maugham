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

/// The other half of the same decision: `needsReload` says whether to START a
/// load, and this says whether the one that has just come back may still bind.
///
/// Sibling of `StatementEditorHost.loadMayBind` (whole-branch review, C1) and
/// the reason the same defect lives here: `loadDocumentIfNeeded` is reached
/// from two `.onChange`s firing unstructured `Task`s that nothing cancels, and
/// nothing between `Document.load`'s suspension and the marker writes asked
/// whether the load was still wanted. It differs from the statement pane's in
/// its damage only — the body refuses to bind a `Document` whose
/// `loadedItemId`/`priorLoadedPath` do not match the selection, so no keystroke
/// reaches the wrong file; what is lost is that the pane sticks on "Loading…"
/// and the `Document` the writer IS looking at is left registered and unclosed.
@MainActor
final class EditorHostLoadGenerationTests: XCTestCase {

    func test_theOnlyClaimIsCurrent() {
        let loads = EditorHostLoadGeneration()
        XCTAssertTrue(loads.isCurrent(loads.claim()),
                      "a load with nothing racing it refused to bind, so the "
                      + "editor would never show a document at all")
    }

    func test_aSupersededClaimIsRefusedWhicheverReturnsFirst() {
        let loads = EditorHostLoadGeneration()
        let first = loads.claim()
        let second = loads.claim()
        XCTAssertFalse(loads.isCurrent(first),
                       "the superseded load was allowed to bind — it overwrites "
                       + "`document`/`loadedItemId` with the file the writer had "
                       + "already clicked away from")
        XCTAssertTrue(loads.isCurrent(second),
                      "the load the writer is waiting for was refused, which is "
                      + "the stuck-on-Loading… outcome with the sign flipped")
    }

    /// Both `.onChange(of: selectedItemId)` and `.onChange(of: currentItem?.path)`
    /// fire on one selection change, so two loads of the SAME destination are
    /// routinely in flight. A destination check would let both bind, leaving two
    /// `Document`s on one path each with its own `PendingBuffer`; a generation
    /// refuses the older one, which is why this is a counter and not a key.
    func test_twoLoadsOfTheSameDestinationDoNotBothBind() {
        let loads = EditorHostLoadGeneration()
        let fromSelectionChange = loads.claim()
        let fromPathChange = loads.claim()
        XCTAssertFalse(loads.isCurrent(fromSelectionChange))
        XCTAssertTrue(loads.isCurrent(fromPathChange))
    }

    func test_teardownSupersedesEverythingInFlight() {
        let loads = EditorHostLoadGeneration()
        let inFlight = loads.claim()
        loads.abandon()
        XCTAssertFalse(loads.isCurrent(inFlight),
                       "a load in flight when the host went away still bound, "
                       + "registering a `Document` the teardown has already "
                       + "walked past and nothing is left to close")
    }
}
