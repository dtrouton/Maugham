import XCTest
@testable import Maugham

final class UpdateStateTests: XCTestCase {
    func test_readyToInstall_equatable() {
        let url = URL(fileURLWithPath: "/tmp/Maugham.app")
        let a = UpdateState.readyToInstall(bundleURL: url, version: "0.5.0", releaseNotes: "n")
        let b = UpdateState.readyToInstall(bundleURL: url, version: "0.5.0", releaseNotes: "n")
        XCTAssertEqual(a, b)
    }

    func test_installing_equatable() {
        XCTAssertEqual(UpdateState.installing(version: "0.5.0"),
                       UpdateState.installing(version: "0.5.0"))
    }
}
