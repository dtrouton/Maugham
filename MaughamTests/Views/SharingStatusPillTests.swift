import XCTest
@testable import Maugham
@testable import MaughamCore

/// **The share is an indicator, never a role** (signed op log P3c, Task 4).
///
/// The WF1 share-role system (`CollaborationRole`, `ShareIdentityMapper`,
/// `ReviewPosturePolicy`) is retired: what a device may write is its permit's,
/// asked through `Posture`. Two things about the share survive, and both are
/// pinned here without a window — the pill's words, and iCloud's own
/// read-only grant as a lock that claims no role.
final class SharingStatusPillTests: XCTestCase {

    private func share(
        isShared: Bool = true, isOwner: Bool? = false, canWrite: Bool? = true,
        ownerName: String? = nil
    ) -> ShareMetadata {
        ShareMetadata(isShared: isShared, isOwner: isOwner, canWrite: canWrite,
                      ownerName: ownerName, currentUserName: nil)
    }

    // MARK: - The pill's three texts

    func test_thePillSaysSharedOrSharedByAndNothingElse() {
        XCTAssertNil(SharingStatusPill.label(for: nil),
                     "still resolving: a role-free pill has nothing to check, so it draws nothing")
        XCTAssertNil(SharingStatusPill.label(for: share(isShared: false, isOwner: nil, canWrite: nil)),
                     "an unshared project draws nothing")
        XCTAssertEqual(SharingStatusPill.label(for: share(isOwner: true)), "Shared",
                       "a share this user owns")
        XCTAssertEqual(SharingStatusPill.label(for: share(ownerName: "Sam")), "Shared by Sam",
                       "somebody else's share names its owner")
        XCTAssertEqual(SharingStatusPill.label(for: share(ownerName: nil)), "Shared",
                       "a participant whose owner the OS has not named")
        XCTAssertEqual(SharingStatusPill.label(for: share(canWrite: false, ownerName: "Sam")),
                       "Shared by Sam",
                       "read-only changes nothing the pill says — the notice says it")
    }

    func test_thePillNamesNoRole() {
        let every: [ShareMetadata?] = [
            nil,
            share(isShared: false, isOwner: nil, canWrite: nil),
            share(isOwner: true), share(isOwner: nil, canWrite: nil),
            share(ownerName: "Sam"), share(canWrite: false, ownerName: "Sam"),
        ]
        for snapshot in every {
            let label = (SharingStatusPill.label(for: snapshot) ?? "").lowercased()
            for word in ["reviewer", "author", "owner", "checking"] {
                XCTAssertFalse(label.contains(word),
                    "the pill says '\(label)', naming '\(word)' — the share decides no role")
            }
        }
    }

    // MARK: - The read-only share lock

    func test_onlyAnExplicitReadOnlyGrantOnAShareIsReadOnly() {
        XCTAssertFalse(ProjectWindow.shareIsReadOnly(nil), "still resolving never locks")
        XCTAssertFalse(ProjectWindow.shareIsReadOnly(
            share(isShared: false, isOwner: nil, canWrite: nil)), "an unshared project")
        XCTAssertFalse(ProjectWindow.shareIsReadOnly(
            share(isShared: false, isOwner: nil, canWrite: false)),
            "a grant on something that is not a share is no lock")
        XCTAssertFalse(ProjectWindow.shareIsReadOnly(share(canWrite: nil)),
                       "an unresolved grant does not lock the writer out")
        XCTAssertFalse(ProjectWindow.shareIsReadOnly(share(canWrite: true)))
        XCTAssertFalse(ProjectWindow.shareIsReadOnly(share(isOwner: true, canWrite: true)))
        XCTAssertTrue(ProjectWindow.shareIsReadOnly(share(canWrite: false, ownerName: "Sam")),
                      "iCloud's read-only grant")
    }

    /// Both directions, through the editor's one mirror function: a read-only
    /// share locks on a book with no registry (the `.unrestricted` posture),
    /// and a read-write share over an author posture does not.
    func test_aReadOnlyShareLocksAndAReadWriteShareDoesNot() {
        let readOnly = EditorControlMirror.membrane(
            posture: Posture(.unrestricted), manualReview: false,
            shareIsReadOnly: ProjectWindow.shareIsReadOnly(share(canWrite: false)))
        XCTAssertTrue(readOnly.lockEditing,
                      "a read-only share locks the editor on a book with no registry")
        XCTAssertFalse(readOnly.isReviewMode,
                       "and claims no role: it is not the reviewer's review render")

        let readWrite = EditorControlMirror.membrane(
            posture: Posture(.unrestricted), manualReview: false,
            shareIsReadOnly: ProjectWindow.shareIsReadOnly(share(canWrite: true)))
        XCTAssertFalse(readWrite.lockEditing,
                       "a read-write share over an author posture does not lock")
        XCTAssertEqual(readWrite, EditorControlMirror.membrane(
            posture: Posture(.unrestricted), manualReview: false,
            shareIsReadOnly: ProjectWindow.shareIsReadOnly(nil)),
            "a read-write participant edits exactly as the unshared writer does — the share is not a role")
    }
}
