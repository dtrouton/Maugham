import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class ProjectStoreTypographyTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    func test_setOverride_persistsInManifest() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Typo", in: temp.url)
        let store = try await ProjectStore.load(from: url)

        var custom = TypographySettings.defaults
        custom.fontSize = 22
        try await store.setProjectTypography(custom)

        XCTAssertEqual(store.manifest.typography?.fontSize, 22)

        let reloaded = try await ProjectStore.load(from: url)
        XCTAssertEqual(reloaded.manifest.typography?.fontSize, 22)
    }

    func test_setOverride_nil_clearsManifestField() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Typo", in: temp.url)
        let store = try await ProjectStore.load(from: url)

        var custom = TypographySettings.defaults
        custom.fontSize = 22
        try await store.setProjectTypography(custom)

        try await store.setProjectTypography(nil)
        XCTAssertNil(store.manifest.typography)
    }

    func test_effectiveTypography_returnsOverrideWhenSet() {
        var override = TypographySettings.defaults
        override.fontSize = 24
        let result = ProjectStore.effectiveTypography(
            override: override, userDefault: .defaults)
        XCTAssertEqual(result.fontSize, 24)
    }

    func test_effectiveTypography_fallsBackToUserDefault() {
        var userDefault = TypographySettings.defaults
        userDefault.fontSize = 19
        let result = ProjectStore.effectiveTypography(
            override: nil, userDefault: userDefault)
        XCTAssertEqual(result.fontSize, 19)
    }
}
