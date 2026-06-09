import XCTest
import MaughamCore
@testable import Maugham

final class TectonicCacheTests: XCTestCase {

    /// The tectonic cache lives under the variant-specific support-folder name
    /// so dev and stable builds write separate caches on the same machine.
    /// Tests run as `.dev`, so the expected suffix uses the dev folder name.
    func testCacheURL_underLibraryCachesVariantFolder() throws {
        let url = try TectonicCache.cacheURL()
        let expectedSuffix = "Library/Caches/\(BuildVariant.current.supportFolderName)/tectonic"
        XCTAssertTrue(url.path.hasSuffix(expectedSuffix),
                      "expected suffix '\(expectedSuffix)', got \(url.path)")
    }

    func testEnsureExists_createsDirectory() throws {
        let url = try TectonicCache.ensureCacheExists()
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }
}
