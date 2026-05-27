import XCTest
@testable import Maugham

final class TectonicCacheTests: XCTestCase {

    func testCacheURL_underLibraryCachesMaugham() throws {
        let url = try TectonicCache.cacheURL()
        XCTAssertTrue(url.path.hasSuffix("Library/Caches/Maugham/tectonic"),
                      "got \(url.path)")
    }

    func testEnsureExists_createsDirectory() throws {
        let url = try TectonicCache.ensureCacheExists()
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }
}
