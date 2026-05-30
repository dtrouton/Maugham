import XCTest
@testable import MaughamPhone
import MaughamCore

/// Unit coverage for the one genuinely pure bit of the Capture tab: the project
/// picker's filtering + sectioning. The interactive surfaces (camera, recorder,
/// pickers) are verified by compilation, not unit tests.
final class ProjectPickerSectionsTests: XCTestCase {

    // MARK: - Fixtures

    /// Build a `BrowsedProject` from a minimal manifest. The url is irrelevant to
    /// sectioning (only id + title matter), so we use a deterministic temp path.
    private func project(id: String, title: String) -> BrowsedProject {
        let manifest = ProjectManifest(
            id: id,
            type: .novel,
            title: title,
            author: "Tester",
            created: Date(timeIntervalSince1970: 1_700_000_000),
            modified: Date(timeIntervalSince1970: 1_700_000_500),
            structure: [],
            research: [])
        return BrowsedProject(
            id: id,
            url: URL(fileURLWithPath: "/tmp/\(id)"),
            manifest: manifest)
    }

    // MARK: - Empty query

    func test_emptyQuery_recentIsSubset_allIsEverything() {
        // Input already title-sorted, as ProjectsBrowser delivers it.
        let projects = [
            project(id: "a", title: "Anna Karenina"),
            project(id: "b", title: "Beloved"),
            project(id: "c", title: "Catch-22"),
        ]
        let recents: Set<ProjectId> = ["b"]

        let sections = projectPickerSections(projects: projects, recents: recents, query: "")

        // recent = only projects whose id ∈ recents.
        XCTAssertEqual(sections.recent.map(\.id), ["b"])
        // all = every project, in input (alpha) order.
        XCTAssertEqual(sections.all.map(\.id), ["a", "b", "c"])
    }

    // MARK: - Non-empty query

    func test_query_filtersBothSectionsCaseInsensitively() {
        let projects = [
            project(id: "a", title: "Anna Karenina"),
            project(id: "b", title: "Beloved"),
            project(id: "c", title: "Crime and Punishment"),
        ]
        // Both a recent and a non-recent contain "an" (case-insensitive):
        // "Anna Karenin**a**"? — match on "an" in "Anna" and "Crime **an**d".
        let recents: Set<ProjectId> = ["a"]

        let sections = projectPickerSections(projects: projects, recents: recents, query: "AN")

        // all matches: "Anna Karenina" (An) and "Crime and Punishment" (an).
        XCTAssertEqual(sections.all.map(\.id), ["a", "c"])
        // recent is the matched subset whose id ∈ recents.
        XCTAssertEqual(sections.recent.map(\.id), ["a"])
    }

    func test_query_excludesNonMatches() {
        let projects = [
            project(id: "a", title: "Anna Karenina"),
            project(id: "b", title: "Beloved"),
        ]
        let sections = projectPickerSections(projects: projects, recents: ["a", "b"], query: "zzz")
        XCTAssertTrue(sections.all.isEmpty)
        XCTAssertTrue(sections.recent.isEmpty)
    }

    // MARK: - Recent is a highlight, not a removal

    func test_recentProjectAlsoAppearsInAll() {
        let projects = [
            project(id: "a", title: "Anna"),
            project(id: "b", title: "Beloved"),
        ]
        let sections = projectPickerSections(projects: projects, recents: ["a"], query: "")

        // Chosen semantics: `all` always contains everything matching; `recent`
        // is an additional highlight subset. So "a" appears in BOTH.
        XCTAssertTrue(sections.all.contains { $0.id == "a" })
        XCTAssertTrue(sections.recent.contains { $0.id == "a" })
    }

    // MARK: - Robustness

    func test_recentsWithUnknownId_isIgnored() {
        let projects = [project(id: "a", title: "Anna")]
        // "ghost" isn't among projects — must be silently ignored, no crash.
        let sections = projectPickerSections(projects: projects, recents: ["ghost", "a"], query: "")

        XCTAssertEqual(sections.recent.map(\.id), ["a"])
        XCTAssertEqual(sections.all.map(\.id), ["a"])
    }
}
