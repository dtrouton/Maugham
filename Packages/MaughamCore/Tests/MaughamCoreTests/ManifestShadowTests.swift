import XCTest
@testable import MaughamCore

final class ManifestShadowTests: XCTestCase {
    private func tempProject() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func test_write_thenRecover_roundTrips() throws {
        let proj = tempProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        let data = Data(#"{"id":"proj-1","title":"X"}"#.utf8)
        try ManifestShadow.write(data, in: proj)
        XCTAssertEqual(ManifestShadow.recover(in: proj), data)
    }

    func test_recover_nilWhenNoShadow() {
        let proj = tempProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        XCTAssertNil(ManifestShadow.recover(in: proj))
    }

    func test_recover_nilWhenShadowItselfCorrupt() throws {
        let proj = tempProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        try ManifestShadow.write(Data("good".utf8), in: proj)
        // Corrupt the shadow bytes but leave the (now-stale) checksum.
        try Data("TAMPERED".utf8).write(
            to: proj.appendingPathComponent(".maugham/\(ManifestShadow.shadowName)"),
            options: .atomic)
        XCTAssertNil(ManifestShadow.recover(in: proj),
                     "a shadow whose checksum no longer matches must not be trusted")
    }

    func test_write_overwritesPriorShadow() throws {
        let proj = tempProject()
        defer { try? FileManager.default.removeItem(at: proj) }
        try ManifestShadow.write(Data("v1".utf8), in: proj)
        try ManifestShadow.write(Data("v2".utf8), in: proj)
        XCTAssertEqual(ManifestShadow.recover(in: proj), Data("v2".utf8))
    }
}
