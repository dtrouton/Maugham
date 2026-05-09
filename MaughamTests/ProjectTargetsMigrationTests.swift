import XCTest
@testable import Maugham

final class ProjectTargetsMigrationTests: XCTestCase {

    func test_decode_legacyTargetsWithoutPageTarget_leavesPageTargetNil() throws {
        let json = """
        { "totalWords": 50000 }
        """.data(using: .utf8)!
        let targets = try JSONDecoder().decode(ProjectTargets.self, from: json)
        XCTAssertEqual(targets.totalWords, 50000)
        XCTAssertNil(targets.pageTarget)
    }

    func test_decode_targetsWithPageTarget_populates() throws {
        let json = """
        { "totalWords": 0, "pageTarget": 110 }
        """.data(using: .utf8)!
        let targets = try JSONDecoder().decode(ProjectTargets.self, from: json)
        XCTAssertEqual(targets.pageTarget, 110)
    }

    func test_roundTrip_preservesPageTarget() throws {
        let original = ProjectTargets(
            totalWords: nil, deadline: nil, pageTarget: 110)
        let data = try JSONEncoder().encode(original)
        let roundTripped = try JSONDecoder().decode(
            ProjectTargets.self, from: data)
        XCTAssertEqual(roundTripped, original)
    }

    @MainActor
    func test_updateProjectTargets_persistsPageTarget() async throws {
        let temp = try TempDirectory()
        let url = try await ProjectFactory.createScreenplayProject(
            named: "PageTargetTest", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        try await store.updateProjectTargets(pageTarget: 110)
        XCTAssertEqual(store.manifest.targets?.pageTarget, 110)

        // Re-load from disk and confirm persistence.
        let reloaded = try await ProjectStore.load(from: url)
        XCTAssertEqual(reloaded.manifest.targets?.pageTarget, 110)
    }

    @MainActor
    func test_updateProjectTargets_zeroPageTargetClearsField() async throws {
        let temp = try TempDirectory()
        let url = try await ProjectFactory.createScreenplayProject(
            named: "PageTargetClear", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        try await store.updateProjectTargets(pageTarget: 110)
        try await store.updateProjectTargets(pageTarget: 0)
        XCTAssertNil(store.manifest.targets?.pageTarget)
    }
}
