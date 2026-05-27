import XCTest
@testable import Maugham

final class TectonicLocatorTests: XCTestCase {

    func testLocatesBundledBinary_inAppResources() throws {
        // Find the app bundle from the test context.
        // In unit tests, the test bundle is nested inside the app's PlugIns folder.
        let testBundle = Bundle(for: TectonicLocatorTests.self)
        let testBundlePath = testBundle.bundlePath

        // Navigate up from MaughamTests.xctest to Maugham.app
        // Typical path: .../Maugham.app/Contents/PlugIns/MaughamTests.xctest
        let appPath = testBundlePath.replacingOccurrences(of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        let appBundleURL = URL(fileURLWithPath: appPath)
        let url = try TectonicLocator.locateInBundle(at: appBundleURL)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path),
                      "tectonic binary not executable at \(url.path)")
    }

    func testThrows_whenBinaryMissing() {
        let unrealistic = URL(fileURLWithPath: "/tmp/definitely-not-an-app-bundle")
        XCTAssertThrowsError(try TectonicLocator.locateInBundle(at: unrealistic)) { err in
            guard case TectonicLocator.Error.notFound = err else {
                XCTFail("unexpected error \(err)")
                return
            }
        }
    }
}
