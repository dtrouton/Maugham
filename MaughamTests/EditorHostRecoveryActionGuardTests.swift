import XCTest
@testable import Maugham

/// **The refusal pane's actions must not fire for a document the writer has
/// left** (recovery spec §3, fix round 1).
///
/// The pane's two actions are minted ONCE, when a cause is classified, and one
/// of them is fired by a poller rather than by a press: the iCloud rung opens
/// the document by itself the moment the file lands. A `View` is a struct, so
/// those closures carry `selectedItemId` — a `let` — from the moment they were
/// built, and `EditorHost` keeps its identity across a document switch
/// (`ProjectWindow.manuscriptEditor` layers rather than branches), so the pane
/// and its poll survive the writer selecting something else. The window is not
/// a hair's breadth: it is the whole of the next document's load.
///
/// Firing stale, the action closes the document the writer is now in and
/// re-binds the one they left, with the binder still highlighting the other —
/// no words lost (the close flushes), but the wrong manuscript silently on
/// screen. Tripwires 2/3/6/7 are all this shape.
///
/// **Two independent defences, and these tests pin the second one.** The first
/// is `loadDocumentIfNeeded` stopping and dropping the model as soon as a new
/// load is claimed; that one lives inside a private method and is pinned by the
/// census in `ReadOnlyRecoveryTests`. The second is the guard below, which
/// costs nothing and holds even if a future edit moves the first.
@MainActor
final class EditorHostRecoveryActionGuardTests: XCTestCase {

    private let proj = URL(fileURLWithPath: "/tmp/ehrag-fixture")
    private let fileURL = URL(fileURLWithPath: "/tmp/ehrag-fixture/.maugham/ops/doc-1.mac.jsonl")

    // MARK: - The rule

    func test_theGuardAdmitsTheHostsCurrentModelAndNothingElse() {
        let a = makeModel(onOpenEditable: {})
        let b = makeModel(onOpenEditable: {})

        XCTAssertTrue(EditorHost.recoveryActionIsCurrent(minted: a, current: a),
                      "the host's own current model acts")
        XCTAssertFalse(EditorHost.recoveryActionIsCurrent(minted: a, current: b),
                       "a model the host has replaced does not")
        XCTAssertFalse(EditorHost.recoveryActionIsCurrent(minted: a, current: nil),
                       "nor one the host has dropped — the ordinary case, since "
                       + "a document that opens clears the pane")
        XCTAssertFalse(EditorHost.recoveryActionIsCurrent(minted: nil, current: nil),
                       "a deallocated mint is not 'current' by matching nil — "
                       + "the capture is weak, so this is the shape the guard "
                       + "sees once the host has let go of the model entirely")
    }

    // MARK: - The rule, composed with a real watcher

    /// **The premise.** Without this, the test below could pass because the
    /// wiring never fires at all rather than because the guard refused it.
    func test_thePremise_aCurrentModelsWatchDoesReachTheHost() async {
        var reloads = 0
        var refusals = 0
        var readable = false
        var current: RecoveryPaneModel?

        weak var minted: RecoveryPaneModel?
        let model = makeModel(probe: { readable }, onOpenEditable: {
            if EditorHost.recoveryActionIsCurrent(minted: minted, current: current) {
                reloads += 1
            } else {
                refusals += 1
            }
        })
        minted = model
        current = model

        model.beginWatching()
        readable = true
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(reloads, 1, "the host's current pane auto-opens as it must")
        XCTAssertEqual(refusals, 0)
        model.stopWatching()
    }

    /// **The fix.** The writer selects another document while the poll runs, so
    /// the host's current model is no longer this one. The file then becomes
    /// readable — the very event this watch exists for — and the auto-open must
    /// go nowhere.
    ///
    /// The watcher is deliberately NOT stopped here: stopping it is the first
    /// defence, and stopping it would test that instead of this.
    func test_aModelTheHostHasLeftBehindCannotReloadIt() async {
        var reloads = 0
        var refusals = 0
        var readable = false
        var current: RecoveryPaneModel?

        weak var minted: RecoveryPaneModel?
        let left = makeModel(probe: { readable }, onOpenEditable: {
            if EditorHost.recoveryActionIsCurrent(minted: minted, current: current) {
                reloads += 1
            } else {
                refusals += 1
            }
        })
        minted = left
        current = left
        left.beginWatching()

        // The writer clicks another document. The host's model moves on; this
        // one is still mounted and still polling.
        current = makeModel(onOpenEditable: {
            XCTFail("the model that replaced it has its own action, untouched")
        })
        readable = true
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(reloads, 0,
                       "a pane the host has left behind must not reload it — "
                       + "that is the wrong document silently bound")
        XCTAssertGreaterThanOrEqual(
            refusals, 1,
            "premise: the watch DID fire and was refused, rather than never "
            + "firing (which would make this assertion vacuous)")
        left.stopWatching()
    }

    // MARK: - Fixture

    private func makeModel(
        probe: @escaping () -> Bool = { false },
        onOpenEditable: @escaping () -> Void
    ) -> RecoveryPaneModel {
        RecoveryPaneModel(
            cause: .unreadableFile(fileName: "doc-1.mac.jsonl",
                                   fileURL: fileURL, reason: "permission denied"),
            projectURL: proj,
            probeInterval: .milliseconds(5),
            blockageCleared: { _ in probe() },
            startDownload: { _ in XCTFail("no download for a non-stub cause") },
            onOpenEditable: onOpenEditable,
            onOpenReadOnly: {},
            onSetAside: {})
    }
}
