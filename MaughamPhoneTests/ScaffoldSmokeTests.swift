import XCTest
import MaughamCore
@testable import MaughamPhone

/// Phase-D0 scaffold smoke: proves the iOS test target builds, hosts into the
/// MaughamPhone app, and can `@testable import` it alongside MaughamCore.
/// Replaced/augmented by the real D0 component tests.
final class ScaffoldSmokeTests: XCTestCase {
    func test_maughamCoreIsLinked() {
        // DeviceSlug is a Foundation-only MaughamCore type the phone will use
        // for per-device op-log partitioning; reaching it proves the package
        // dependency is wired into the iOS target.
        XCTAssertFalse(DeviceSlug.make(from: "phone:test").raw.isEmpty)
    }
}
