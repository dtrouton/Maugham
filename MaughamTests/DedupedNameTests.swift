import XCTest
@testable import Maugham

/// Tests for `ProjectStore.dedupedName(_:isTaken:)`.
///
/// The helper returns `base` when it's free, otherwise `base-2`, `base-3`, ...
/// This format matches the slug-dedup loops throughout ProjectStore+*.swift.
final class DedupedNameTests: XCTestCase {

    // MARK: - Base cases

    func test_freeName_returnsBaseUnchanged() {
        let taken: Set<String> = ["other"]
        let result = ProjectStore.dedupedName("chapter-one") { taken.contains($0) }
        XCTAssertEqual(result, "chapter-one")
    }

    func test_emptyTakenSet_returnsBaseUnchanged() {
        let taken: Set<String> = []
        let result = ProjectStore.dedupedName("my-slug") { taken.contains($0) }
        XCTAssertEqual(result, "my-slug")
    }

    // MARK: - Collision at base

    func test_baseCollision_returnsSuffixTwo() {
        let taken: Set<String> = ["chapter-one"]
        let result = ProjectStore.dedupedName("chapter-one") { taken.contains($0) }
        XCTAssertEqual(result, "chapter-one-2")
    }

    // MARK: - Chain of collisions

    func test_twoAndThreeTaken_returnsFour() {
        let taken: Set<String> = ["my-slug", "my-slug-2", "my-slug-3"]
        let result = ProjectStore.dedupedName("my-slug") { taken.contains($0) }
        XCTAssertEqual(result, "my-slug-4")
    }

    func test_onlyBaseAndTwoTaken_returnsThree() {
        let taken: Set<String> = ["note", "note-2"]
        let result = ProjectStore.dedupedName("note") { taken.contains($0) }
        XCTAssertEqual(result, "note-3")
    }

    // MARK: - Exact suffix format

    func test_suffixUsesHyphenAndInteger_notSpace() {
        let taken: Set<String> = ["slug"]
        let result = ProjectStore.dedupedName("slug") { taken.contains($0) }
        // Must be "slug-2", NOT "slug 2" or "slug_2"
        XCTAssertEqual(result, "slug-2")
        XCTAssertFalse(result.contains(" "))
        XCTAssertFalse(result.contains("_"))
    }

    func test_counterStartsAtTwo_notOne() {
        let taken: Set<String> = ["base", "base-1"]
        // "base-1" is taken but we should land on "base-2" regardless,
        // because the counter starts at 2 (not 1).
        let result = ProjectStore.dedupedName("base") { taken.contains($0) }
        XCTAssertEqual(result, "base-2")
    }

    // MARK: - Filesystem closure variant

    func test_filesystemClosure_variant() {
        // Demonstrates the helper works with any isTaken closure,
        // e.g. one backed by a Set of filesystem paths.
        let existingPaths: Set<String> = [
            "research/note.md",
            "research/note-2.md",
        ]
        let folder = "research"
        let slug = "note"
        let ext = "md"

        let result = ProjectStore.dedupedName(slug) { candidate in
            existingPaths.contains("\(folder)/\(candidate).\(ext)")
        }
        XCTAssertEqual(result, "note-3")
    }
}
