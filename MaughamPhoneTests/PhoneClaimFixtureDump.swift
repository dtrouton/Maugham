import XCTest
@testable import MaughamCore
@testable import MaughamPhone

/// **Regenerates the phone-written bytes `MaughamCore`'s
/// `PhoneClaimRoundTripTests` reads on macOS** (your devices are you, plan 2
/// Task 1). OPT-IN: skipped unless `MAUGHAM_PHONE_CLAIM_FIXTURE_DIR` names a
/// directory, because a gate must not write outside `TestTemp`. Run it with
///
///     TEST_RUNNER_MAUGHAM_PHONE_CLAIM_FIXTURE_DIR=/some/dir \
///       xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone \
///       -destination 'platform=iOS Simulator,name=iPhone 17' test \
///       CODE_SIGNING_ALLOWED=NO -only-testing:MaughamPhoneTests/PhoneClaimFixtureDump
///
/// and paste `phone-record.json`, its fingerprint (`phone-record-name.txt`,
/// minus `.json`) and `person-item.json` into that suite's three literals.
/// It captures through the real `InboxCaptureWriter` → `PhoneDeviceRecord`
/// → `RegistryPresence.declareDevice` path, with an in-memory person-key
/// store a "Mac" seeded (the phone only finds it) — never a keychain.
@MainActor
final class PhoneClaimFixtureDump: XCTestCase {

    static let environmentKey = "MAUGHAM_PHONE_CLAIM_FIXTURE_DIR"

    override func tearDown() async throws {
        PhonePersonKeyAccess.storeForTesting = nil
        PhoneDeviceRecord.forgetDeclarationsForTesting()
    }

    func test_dumpAPhoneWrittenDeviceRecordWithItsClaim() async throws {
        guard let dir = ProcessInfo.processInfo.environment[Self.environmentKey],
              !dir.isEmpty
        else { throw XCTSkip("opt-in: set \(Self.environmentKey) to regenerate the fixture") }

        let root = TestTemp.root.appendingPathComponent("claim-dump-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InMemoryPersonKeyStore()
        _ = try XCTUnwrap(PersonKey.findOrCreate(in: store, seedName: "Denver Trouton"))
        PhonePersonKeyAccess.storeForTesting = store
        PhoneDeviceRecord.forgetDeclarationsForTesting()
        let phone = DeviceIdentity.softwareForTesting()

        _ = try await InboxCaptureWriter(projectRoot: root, identity: phone)
            .writeText("On the train")

        let record = RegistryWriter.url(.devices, fingerprint: phone.fingerprint, in: root)
        guard case .found(let item) = store.find() else { return XCTFail("the seeded item") }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data(contentsOf: record).write(to: out.appendingPathComponent("phone-record.json"))
        try JSONEncoder().encode(item).write(to: out.appendingPathComponent("person-item.json"))
        try record.lastPathComponent.write(
            to: out.appendingPathComponent("phone-record-name.txt"), atomically: true, encoding: .utf8)
    }
}
