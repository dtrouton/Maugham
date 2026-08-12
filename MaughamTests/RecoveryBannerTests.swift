import XCTest
import MaughamCore
@testable import Maugham

/// Recovery spec §4: the banner names what's missing, OFFERS the return
/// (never yanks), and answers typing with emphasis. Plan B swaps the typing
/// copy for the quarantine offer; Plan A's copy promises nothing unbuilt.
@MainActor
final class RecoveryBannerTests: XCTestCase {
    private let files = [CheckpointLoad.UnreadableFile(name: "doc-1.phone.jsonl", reason: "permission denied")]
    private let opsDir = URL(fileURLWithPath: "/tmp/rb-fixture/.maugham/ops")

    func test_message_namesTheFiles_andReasonRidesInDetail() {
        let model = RecoveryBannerModel(
            unreadableFiles: files, opsDirectory: opsDir,
            probeInterval: .seconds(1), blockageCleared: { _ in false })
        XCTAssertTrue(model.message.contains("doc-1.phone.jsonl"))
        XCTAssertTrue(model.message.localizedCaseInsensitiveContains("read-only"))
        XCTAssertFalse(model.offersReopen)
    }

    func test_reopenIsOffered_whenEveryNamedFileReads_neverBefore() async {
        var readable = false
        let model = RecoveryBannerModel(
            unreadableFiles: files, opsDirectory: opsDir,
            probeInterval: .milliseconds(5), blockageCleared: { _ in readable })
        model.beginWatching()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(model.offersReopen)
        // The writer tried to type while they waited. The flare is standing
        // when the history comes back…
        model.noteTypingRefused()
        XCTAssertTrue(model.emphasised)
        readable = true
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(model.emphasised,
            "…and comes down with the offer: the banner has stopped saying "
            + "\"you can't type here\" and started saying \"come back\", so one "
            + "refused keystroke must not tint it for the rest of the session")
        XCTAssertTrue(model.offersReopen,
            "the offer appears — and `offersReopen` is the model's ONLY output: "
            + "there is no reload callback to misuse, the return is an offer, "
            + "never a yank (ruling 2)")
        model.stopWatching()
    }

    func test_typingRefusal_emphasisesTheBanner() {
        let model = RecoveryBannerModel(
            unreadableFiles: files, opsDirectory: opsDir,
            probeInterval: .seconds(1), blockageCleared: { _ in false })
        XCTAssertFalse(model.emphasised)
        model.noteTypingRefused()
        XCTAssertTrue(model.emphasised)
    }
}
