import XCTest
@testable import MaughamCore

final class ProjectShareEligibilityTests: XCTestCase {

    func test_notInICloud_yieldsNotInICloud_regardlessOfMetadata() {
        XCTAssertEqual(
            ProjectShareEligibility.evaluate(isInICloudDrive: false, metadata: nil),
            .notInICloud)
        let shared = ShareMetadata(
            isShared: true, isOwner: true, canWrite: true,
            ownerName: "Ada", currentUserName: "Ada")
        XCTAssertEqual(
            ProjectShareEligibility.evaluate(isInICloudDrive: false, metadata: shared),
            .notInICloud)
    }

    func test_inICloud_notYetShared_isShareableNotAlreadyShared() {
        let meta = ShareMetadata(
            isShared: false, isOwner: nil, canWrite: nil,
            ownerName: nil, currentUserName: nil)
        XCTAssertEqual(
            ProjectShareEligibility.evaluate(isInICloudDrive: true, metadata: meta),
            .shareable(alreadyShared: false))
    }

    func test_inICloud_nilMetadata_isShareableNotAlreadyShared() {
        XCTAssertEqual(
            ProjectShareEligibility.evaluate(isInICloudDrive: true, metadata: nil),
            .shareable(alreadyShared: false))
    }

    func test_inICloud_alreadyShared_isShareableAlreadyShared() {
        let meta = ShareMetadata(
            isShared: true, isOwner: true, canWrite: true,
            ownerName: "Ada", currentUserName: "Ada")
        XCTAssertEqual(
            ProjectShareEligibility.evaluate(isInICloudDrive: true, metadata: meta),
            .shareable(alreadyShared: true))
    }

    /// The one spelling of the read-only share lock: only an explicit
    /// `canWrite == false` on a share locks.
    func test_onlyAnExplicitReadOnlyGrantOnAShareIsReadOnly() {
        func meta(_ shared: Bool, _ canWrite: Bool?) -> ShareMetadata {
            ShareMetadata(isShared: shared, isOwner: false, canWrite: canWrite, ownerName: nil, currentUserName: nil)
        }
        XCTAssertFalse(ShareMetadata.isReadOnly(nil), "still resolving never locks")
        XCTAssertFalse(ShareMetadata.isReadOnly(meta(false, false)), "not a share")
        XCTAssertFalse(ShareMetadata.isReadOnly(meta(true, nil)), "an unresolved grant")
        XCTAssertFalse(ShareMetadata.isReadOnly(meta(true, true)))
        XCTAssertTrue(ShareMetadata.isReadOnly(meta(true, false)))
    }
}
