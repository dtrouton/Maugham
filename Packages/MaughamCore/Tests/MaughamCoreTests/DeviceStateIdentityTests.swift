import XCTest
@testable import MaughamCore

/// `op-log-state.json` belongs to ONE identity (the whole-branch review's I3).
///
/// The heads are keyed by project-path hash and filename — the DEVICE is not in
/// the key, and the file is not deleted when the identity changes. Application
/// Support is what Migration Assistant copies; the enclave blob it copies is not
/// loadable on the new Mac, so `DeviceIdentity.load` mints a new identity while
/// every remembered head for the OLD slug's files survives. If the old Mac is
/// still appending to `<doc>.<oldSlug>.jsonl`, the migrated Mac finds its stale
/// head mid-file and quarantines everything after it: the writer's own synced
/// ops, not applied, under the sentence "written by something that is not
/// Maugham". One field closes it.
final class DeviceStateIdentityTests: XCTestCase {

    private var stateURL: URL!

    override func setUp() {
        stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-state-identity-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: stateURL)
    }

    private let alpha = String(repeating: "a", count: 64)
    private let beta = String(repeating: "b", count: 64)

    func test_aStateFileWrittenUnderOneIdentityHasNoHeadsUnderAnother() {
        let first = OpLogDeviceState(fileURL: stateURL, identity: alpha)
        first.remember(head: "head-one", for: "key/one")
        first.markVerified(segmentDigest: "digest-one")

        let migrated = OpLogDeviceState(fileURL: stateURL, identity: beta)
        XCTAssertNil(migrated.head(for: "key/one"),
            "a head remembered by another device is not this device's word")
        XCTAssertFalse(migrated.isVerified(segmentDigest: "digest-one"),
            "and neither is a segment it verified")
    }

    func test_theSameIdentityStillReloadsItsOwnHeads() {
        let first = OpLogDeviceState(fileURL: stateURL, identity: alpha)
        first.remember(head: "head-one", for: "key/one")
        first.markVerified(segmentDigest: "digest-one")

        let reloaded = OpLogDeviceState(fileURL: stateURL, identity: alpha)
        XCTAssertEqual(reloaded.head(for: "key/one"), "head-one")
        XCTAssertTrue(reloaded.isVerified(segmentDigest: "digest-one"))
    }

    /// No migration (tripwire 11): a file predating this field reads as a
    /// mismatch and starts empty, which is exactly the adopt case the load path
    /// already handles.
    func test_aStateFilePredatingTheIdentityFieldStartsEmpty() throws {
        try Data(#"{"heads":{"key/one":"head-one"},"verifiedSegments":["digest-one"]}"#.utf8)
            .write(to: stateURL)

        let opened = OpLogDeviceState(fileURL: stateURL, identity: alpha)
        XCTAssertNil(opened.head(for: "key/one"))
        XCTAssertFalse(opened.isVerified(segmentDigest: "digest-one"))
    }

    /// The mismatch is not merely ignored in memory: the file is rewritten, so
    /// the stale identity's heads cannot come back on the next open.
    func test_aMismatchedStateFileIsRewrittenUnderTheNewIdentity() throws {
        let first = OpLogDeviceState(fileURL: stateURL, identity: alpha)
        first.remember(head: "head-one", for: "key/one")

        _ = OpLogDeviceState(fileURL: stateURL, identity: beta)

        let onDisk = try String(contentsOf: stateURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains(beta), "the file names its new owner")
        XCTAssertFalse(onDisk.contains("head-one"),
            "and carries none of the old owner's heads")
    }

    // MARK: - The previous head (I2's crash window)

    func test_rememberShiftsTheCurrentHeadIntoThePrevious() {
        let state = OpLogDeviceState(fileURL: stateURL, identity: alpha)
        XCTAssertNil(state.previousHead(for: "k"))

        state.remember(head: "one", for: "k")
        XCTAssertEqual(state.head(for: "k"), "one")
        XCTAssertNil(state.previousHead(for: "k"))

        state.remember(head: "two", for: "k")
        XCTAssertEqual(state.head(for: "k"), "two")
        XCTAssertEqual(state.previousHead(for: "k"), "one")
    }

    func test_thePreviousHeadSurvivesAReload() {
        let state = OpLogDeviceState(fileURL: stateURL, identity: alpha)
        state.remember(head: "one", for: "k")
        state.remember(head: "two", for: "k")

        let reloaded = OpLogDeviceState(fileURL: stateURL, identity: alpha)
        XCTAssertEqual(reloaded.previousHead(for: "k"), "one")
    }

    func test_forgettingAHeadForgetsItsPredecessorToo() {
        let state = OpLogDeviceState(fileURL: stateURL, identity: alpha)
        state.remember(head: "one", for: "k")
        state.remember(head: "two", for: "k")
        state.remember(head: nil, for: "k")

        XCTAssertNil(state.head(for: "k"))
        XCTAssertNil(state.previousHead(for: "k"))
    }
}
