import XCTest
@testable import MaughamCore

/// The one function that names a project's kind (report plan 4, Task 6,
/// R-4-8): "Report" for a Report, otherwise the type's own name. Every
/// surface that names a kind asks it; the census in `TripwireGrepTests`
/// refuses a kind name spelled anywhere else.
final class ProjectKindNameTests: XCTestCase {

    private func manifest(_ type: ProjectType, profile: ProjectProfile? = nil) -> ProjectManifest {
        var m = ProjectManifest(
            type: type, title: "T", author: "A",
            created: Date(timeIntervalSince1970: 0),
            modified: Date(timeIntervalSince1970: 0),
            structure: [], research: [])
        m.profile = profile
        return m
    }

    func test_eachTypeHasItsName() {
        XCTAssertEqual(ProjectKindName.of(ProjectType.shortStory), "Short Story")
        XCTAssertEqual(ProjectKindName.of(ProjectType.novel), "Novel")
        XCTAssertEqual(ProjectKindName.of(ProjectType.screenplay), "Screenplay")
        XCTAssertEqual(ProjectKindName.of(ProjectType.collection), "Collection")
    }

    /// A newer build's type has no name this build knows: it is a project.
    func test_anUnknownTypeIsAProject() {
        XCTAssertEqual(ProjectKindName.of(ProjectType.unknown), "Project")
    }

    /// A Report is a profile over a short-story or novel structure; its name
    /// is "Report" whichever structure it sits on.
    func test_aReportIsNamedReportWhateverItsStructure() {
        XCTAssertEqual(ProjectKindName.of(manifest(.shortStory, profile: .report)), "Report")
        XCTAssertEqual(ProjectKindName.of(manifest(.novel, profile: .report)), "Report")
    }

    /// No profile, or one this build does not know, names the type.
    func test_withoutAKnownProfileTheManifestNamesItsType() {
        XCTAssertEqual(ProjectKindName.of(manifest(.novel)), "Novel")
        XCTAssertEqual(ProjectKindName.of(manifest(.screenplay)), "Screenplay")
        XCTAssertEqual(ProjectKindName.of(manifest(.shortStory, profile: .unknown("essay"))), "Short Story")
        XCTAssertEqual(ProjectKindName.of(manifest(.unknown)), "Project")
    }
}
