import XCTest
@testable import MaughamCore

/// `InboxManifest.inboxManifestURL` is the SINGLE SOURCE OF TRUTH for the
/// per-device inbox manifest filename. These assertions are the contract: both
/// surfaces (phone `InboxCaptureWriter`, Mac `InboxStore`) must produce a URL
/// whose last path component is `inbox.<slug>.jsonl` inside `.maugham/inbox/`.
final class InboxManifestTests: XCTestCase {
    func test_inboxManifestURL_lastPathComponentMatchesTemplate() {
        let tmp = URL(fileURLWithPath: "/tmp/TestProject")
        let url = InboxManifest.inboxManifestURL(forDeviceSlug: "phoneA-1234", in: tmp)
        XCTAssertEqual(url.lastPathComponent, "inbox.phoneA-1234.jsonl")
    }

    func test_inboxManifestURL_parentDirEndsInMaughamInbox() {
        let tmp = URL(fileURLWithPath: "/tmp/TestProject")
        let url = InboxManifest.inboxManifestURL(forDeviceSlug: "phoneA-1234", in: tmp)
        let parent = url.deletingLastPathComponent().path
        XCTAssertTrue(parent.hasSuffix("/.maugham/inbox"),
                      "Expected parent to end in '/.maugham/inbox', got: \(parent)")
    }

    func test_inboxManifestURL_fullPathMatchesExpected() {
        let tmp = URL(fileURLWithPath: "/tmp/TestProject")
        let url = InboxManifest.inboxManifestURL(forDeviceSlug: "macA-5678", in: tmp)
        XCTAssertEqual(url.path, "/tmp/TestProject/.maugham/inbox/inbox.macA-5678.jsonl")
    }

    func test_inboxManifestURL_differentSlugsProduceDifferentFiles() {
        let tmp = URL(fileURLWithPath: "/tmp/Proj")
        let phone = InboxManifest.inboxManifestURL(forDeviceSlug: "phone-abc", in: tmp)
        let mac   = InboxManifest.inboxManifestURL(forDeviceSlug: "mac-xyz",   in: tmp)
        XCTAssertNotEqual(phone.lastPathComponent, mac.lastPathComponent)
        // Both share the same parent directory
        XCTAssertEqual(phone.deletingLastPathComponent(), mac.deletingLastPathComponent())
    }
}
