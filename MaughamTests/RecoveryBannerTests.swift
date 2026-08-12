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
        XCTAssertFalse(model.setAsideOffered,
                       "unasked-for, the third rung stays out of sight: a writer "
                       + "who has not tried to type has not yet been stopped")
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
        XCTAssertTrue(model.setAsideOffered)
        readable = true
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(model.setAsideOffered,
            "the offer to set the history aside comes down with the flare, and "
            + "for the same reason twice over: the history is BACK, so there is "
            + "nothing left to set aside, and pressing it now would move a file "
            + "that reads perfectly well")
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

    /// Plan A emphasised and said no more, because it had nothing to offer.
    /// Plan B does: the refused keystroke is the moment the writer has told us
    /// they want to write, and it is the moment the third rung appears. The
    /// emphasis stays — the flare is what makes them look at the banner they
    /// have been ignoring.
    func test_typingRefusal_emphasisesTheBanner_andRaisesTheOffer() {
        let model = RecoveryBannerModel(
            unreadableFiles: files, opsDirectory: opsDir,
            probeInterval: .seconds(1), blockageCleared: { _ in false })
        XCTAssertFalse(model.emphasised)
        XCTAssertFalse(model.setAsideOffered)
        model.noteTypingRefused()
        XCTAssertTrue(model.emphasised)
        XCTAssertTrue(model.setAsideOffered)
    }

    /// The copy census. Two promises are load-bearing and both are made here
    /// rather than in a sheet the writer may never open: the words they are
    /// looking at are **kept**, and the history comes **back** by itself. And
    /// the word for what happens to it is never the one the code uses.
    func test_theOfferPromisesKeptSafeAndAReturn_andNeverSaysQuarantine() {
        let model = RecoveryBannerModel(
            unreadableFiles: files, opsDirectory: opsDir,
            probeInterval: .seconds(1), blockageCleared: { _ in false })
        let offer = model.setAsideOffer
        XCTAssertTrue(offer.localizedCaseInsensitiveContains("set"))
        XCTAssertTrue(offer.localizedCaseInsensitiveContains("aside"))
        XCTAssertTrue(offer.localizedCaseInsensitiveContains("kept safe"),
                      "the file is moved, never deleted — and the writer is told "
                      + "so before they press, not after")
        XCTAssertFalse(offer.localizedCaseInsensitiveContains("quarantine"),
                       "'quarantine' is the code's word and the folder's name, "
                       + "never the writer's")
        XCTAssertFalse(model.message.localizedCaseInsensitiveContains("quarantine"))
    }
}
