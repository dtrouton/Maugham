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
}
