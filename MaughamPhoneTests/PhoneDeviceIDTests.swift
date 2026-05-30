import XCTest
@testable import MaughamPhone

final class PhoneDeviceIDTests: XCTestCase {
    /// Use an isolated suite so we never touch the real install's persisted id.
    private func freshDefaults() -> UserDefaults {
        let suite = "phone-device-id-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func test_deviceId_isStableAcrossCalls() {
        let defaults = freshDefaults()
        let first = PhoneDeviceID.current(defaults: defaults)
        let second = PhoneDeviceID.current(defaults: defaults)
        XCTAssertEqual(first, second, "second call must return the persisted id")
        XCTAssertTrue(first.hasPrefix("phone:"), "id must use the phone:<uuid> convention")
    }
}
