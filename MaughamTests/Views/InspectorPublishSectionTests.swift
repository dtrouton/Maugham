import XCTest
@testable import Maugham

/// `InspectorPublishSection` is a SwiftUI view whose state is driven by
/// `PublishConfigStore`. We test the persistence contract directly: a piece's
/// `Section` override round-trips through save/load, and absent overrides
/// default to `Section()`.
final class InspectorPublishSectionTests: XCTestCase {

    private func makeProject() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublishSectionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    func testRoundTrip_writeReadOverride() async throws {
        let tmp = try makeProject()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig()
        cfg.sections["piece-abc"] = PublishConfig.Section(
            titleOverride: "Custom Title",
            startOn: .recto,
            includeInToc: false)
        try await store.save(cfg)

        let loaded = try await store.load()
        XCTAssertNotNil(loaded)
        let section = loaded?.sections["piece-abc"]
        XCTAssertEqual(section?.titleOverride, "Custom Title")
        XCTAssertEqual(section?.startOn, .recto)
        XCTAssertEqual(section?.includeInToc, false)
    }

    func testAbsentOverride_defaultsToInitial() async throws {
        let tmp = try makeProject()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PublishConfigStore(projectURL: tmp)
        try await store.save(PublishConfig())

        let loaded = try await store.load()
        // A piece with no override should default to .init() when consumed.
        let section = loaded?.sections["piece-never-written"] ?? .init()
        XCTAssertEqual(section.titleOverride, nil)
        XCTAssertEqual(section.startOn, .any)
        XCTAssertEqual(section.includeInToc, true)
    }

    func testMultiplePieces_independentlyPersisted() async throws {
        let tmp = try makeProject()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig()
        cfg.sections["piece-a"] = PublishConfig.Section(
            titleOverride: "A", startOn: .recto, includeInToc: true)
        cfg.sections["piece-b"] = PublishConfig.Section(
            titleOverride: "B", startOn: .verso, includeInToc: false)
        try await store.save(cfg)

        let loaded = try await store.load()
        XCTAssertEqual(loaded?.sections["piece-a"]?.titleOverride, "A")
        XCTAssertEqual(loaded?.sections["piece-a"]?.startOn, .recto)
        XCTAssertEqual(loaded?.sections["piece-b"]?.titleOverride, "B")
        XCTAssertEqual(loaded?.sections["piece-b"]?.startOn, .verso)
        XCTAssertEqual(loaded?.sections["piece-b"]?.includeInToc, false)
    }
}
