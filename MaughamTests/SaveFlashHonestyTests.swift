import XCTest
import MaughamCore
@testable import Maugham

/// **⌘S must not flash "saved" over a checkpoint that did not land.**
///
/// The whole-branch review's finding: both ⌘S sites (`CheckpointModifier`'s
/// key command and the Shift-⌘S label sheet, `ProjectWindow.swift`) used to
/// swallow `CheckpointCapture.run`'s throw with `try?` and flash regardless —
/// in a read-only recovery state the write is refused and the flash lied.
/// `CheckpointFlashDecision.run` is the fix, and the one shape both sites
/// call: `onSuccess` fires only when `capture` returns; a throw posts a
/// `.maughamDocumentNotice` instead and never calls `onSuccess`.
///
/// Exercised directly against `CheckpointFlashDecision` rather than by
/// mounting `ProjectWindow` — the decision is a small testable unit with no
/// view dependency, and this is the cheaper, equally honest pin.
@MainActor
final class SaveFlashHonestyTests: XCTestCase {

    private struct Boom: Error, LocalizedError {
        var errorDescription: String? { "the manuscript is read-only" }
    }

    /// Collects every `.maughamDocumentNotice` message posted while the block
    /// runs — same pattern as `DocumentNoticeTests`.
    private func notices(during body: () async -> Void) async -> [String] {
        var seen: [String] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil
        ) { note in
            if let m = note.userInfo?[MaughamEvent.noticeMessageKey] as? String {
                seen.append(m)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        await body()
        return seen
    }

    // MARK: - The lie this fixes

    /// A throwing capture must not flash, and must tell the writer why.
    func test_aThrowingCaptureNeverFlashes_andPostsANoticeNamingWhy() async {
        var flashed = false

        let seen = await notices {
            await CheckpointFlashDecision.run(
                projectURL: URL(fileURLWithPath: "/tmp/nonexistent-project"),
                onSuccess: { flashed = true }
            ) {
                throw Boom()
            }
        }

        XCTAssertFalse(flashed, "a checkpoint that did not land must not flash")
        XCTAssertEqual(seen.count, 1, "exactly one notice, naming the failure")
        XCTAssertTrue(
            seen.first?.contains("Couldn’t save a checkpoint") == true,
            "the notice must say a checkpoint failed — got \(seen)")
        XCTAssertTrue(
            seen.first?.contains("read-only") == true,
            "the notice must carry the underlying reason — got \(seen)")
    }

    // MARK: - The control

    /// Without this, deleting `onSuccess()` entirely would still pass the
    /// throwing test above.
    func test_ASucceedingCaptureFlashes_andPostsNoNotice() async {
        var flashed = false

        let seen = await notices {
            await CheckpointFlashDecision.run(
                projectURL: URL(fileURLWithPath: "/tmp/nonexistent-project"),
                onSuccess: { flashed = true }
            ) {
                // lands cleanly
            }
        }

        XCTAssertTrue(flashed, "a checkpoint that landed must flash")
        XCTAssertTrue(seen.isEmpty, "a landed checkpoint must not post a notice — got \(seen)")
    }
}
