import XCTest
import MaughamCore
@testable import Maugham

/// Recovery spec §3: classify the cause BEFORE writing the message. A
/// dataless iCloud stub is transient and gets the wait-and-retry treatment;
/// everything else gets the honest error plus the ladder's actions.
@MainActor
final class RecoveryCauseTests: XCTestCase {
    private let proj = URL(fileURLWithPath: "/tmp/recovery-cause-fixture")

    func test_unreadableFile_thatIsAStub_classifiesAsICloudNotDownloaded() {
        let err = OpLogStore.ReadError.unreadableFile(name: "doc-1.phone.jsonl", underlying: "x")
        let cause = RecoveryCause.classify(
            loadError: err, projectURL: proj, isDatalessStub: { _ in true })
        guard case .icloudNotDownloaded(let name, let url)? = cause else {
            return XCTFail("expected icloudNotDownloaded, got \(String(describing: cause))")
        }
        XCTAssertEqual(name, "doc-1.phone.jsonl")
        XCTAssertEqual(url.lastPathComponent, "doc-1.phone.jsonl")
        XCTAssertTrue(url.path.contains(".maugham/ops"))
    }

    func test_unreadableFile_notAStub_classifiesAsUnreadable_withReason() {
        let err = OpLogStore.ReadError.unreadableFile(name: "doc-1.phone.jsonl", underlying: "permission denied")
        let cause = RecoveryCause.classify(
            loadError: err, projectURL: proj, isDatalessStub: { _ in false })
        guard case .unreadableFile(let name, _, let reason)? = cause else {
            return XCTFail("expected unreadableFile, got \(String(describing: cause))")
        }
        XCTAssertEqual(name, "doc-1.phone.jsonl")
        XCTAssertEqual(reason, "permission denied")
    }

    func test_unlistableDirectory_classifies_andNeverProbesTheStub() {
        let err = OpLogStore.ReadError.unlistableOpsDirectory(underlying: "perm")
        var probed = false
        let cause = RecoveryCause.classify(
            loadError: err, projectURL: proj, isDatalessStub: { _ in probed = true; return true })
        guard case .unlistableOpsDirectory? = cause else {
            return XCTFail("expected unlistableOpsDirectory, got \(String(describing: cause))")
        }
        XCTAssertFalse(probed, "no file to probe — the directory case has no partial view (spec §3)")
    }

    func test_anUnrelatedError_isNotAClassifiedCause() {
        struct Other: Error {}
        XCTAssertNil(RecoveryCause.classify(
            loadError: Other(), projectURL: proj, isDatalessStub: { _ in true }))
    }
}
