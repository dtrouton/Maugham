import XCTest
@testable import Maugham

final class PublishConfigStoreTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublishConfigStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testLoad_returnsNilWhenAbsent() async throws {
        let store = PublishConfigStore(projectURL: tmp)
        let result = try await store.load()
        XCTAssertNil(result)
    }

    func testSave_thenLoad_roundTrips() async throws {
        let store = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig()
        cfg.metadata.title = "Round Trip"
        try await store.save(cfg)

        let loaded = try await store.load()
        XCTAssertEqual(loaded?.metadata.title, "Round Trip")
    }

    func testSave_writesPrettyPrintedJSON_withSnakeCaseKeys() async throws {
        let store = PublishConfigStore(projectURL: tmp)
        try await store.save(PublishConfig())
        let data = try Data(contentsOf: tmp.appendingPathComponent(".maugham/publish/config.json"))
        let s = String(data: data, encoding: .utf8)!
        XCTAssertTrue(s.contains("\"schema_version\""))
        XCTAssertTrue(s.contains("\"next_version\""))
        XCTAssertTrue(s.contains("\n"))   // pretty-printed
    }

    func testSave_createsIntermediateDirectories() async throws {
        let store = PublishConfigStore(projectURL: tmp)
        try await store.save(PublishConfig())
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent(".maugham/publish").path,
            isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }
}
