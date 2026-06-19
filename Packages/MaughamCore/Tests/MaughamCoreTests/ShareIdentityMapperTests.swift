import XCTest
@testable import MaughamCore

final class ShareIdentityMapperTests: XCTestCase {

    // nil metadata → still resolving → .unknown, never write-presumptive.
    func test_nilMetadata_yieldsUnknownAndReadOnly() {
        let c = ShareIdentityMapper.resolve(nil)
        XCTAssertEqual(c.role, .unknown)
        XCTAssertNil(c.currentUserName)
        XCTAssertNil(c.ownerName)
        XCTAssertFalse(c.canWrite)
    }

    // Not shared = the writer's own copy → author, writable.
    func test_notShared_yieldsAuthorWritable() {
        let meta = ShareMetadata(
            isShared: false, isOwner: nil, canWrite: nil,
            ownerName: nil, currentUserName: "Ada Lovelace")
        let c = ShareIdentityMapper.resolve(meta)
        XCTAssertEqual(c.role, .author)
        XCTAssertEqual(c.currentUserName, "Ada Lovelace")
        XCTAssertNil(c.ownerName)
        XCTAssertTrue(c.canWrite)
    }

    // Shared + I am the owner → author.
    func test_sharedOwner_yieldsAuthor() {
        let meta = ShareMetadata(
            isShared: true, isOwner: true, canWrite: true,
            ownerName: "Ada Lovelace", currentUserName: "Ada Lovelace")
        let c = ShareIdentityMapper.resolve(meta)
        XCTAssertEqual(c.role, .author)
        XCTAssertEqual(c.ownerName, "Ada Lovelace")
        XCTAssertTrue(c.canWrite)
    }

    // Shared + I am a participant → reviewer; names + canWrite carried.
    func test_sharedParticipant_yieldsReviewerCarryingNamesAndPermission() {
        let meta = ShareMetadata(
            isShared: true, isOwner: false, canWrite: false,
            ownerName: "Ada Lovelace", currentUserName: "Charles Babbage")
        let c = ShareIdentityMapper.resolve(meta)
        XCTAssertEqual(c.role, .reviewer)
        XCTAssertEqual(c.ownerName, "Ada Lovelace")
        XCTAssertEqual(c.currentUserName, "Charles Babbage")
        XCTAssertFalse(c.canWrite)
    }

    // Participant with read-write permission still resolves reviewer, canWrite true.
    func test_sharedParticipant_readWrite_carriesWritable() {
        let meta = ShareMetadata(
            isShared: true, isOwner: false, canWrite: true,
            ownerName: "Ada Lovelace", currentUserName: "Charles Babbage")
        let c = ShareIdentityMapper.resolve(meta)
        XCTAssertEqual(c.role, .reviewer)
        XCTAssertTrue(c.canWrite)
    }

    // Shared but isOwner unknown (role not yet populated by the OS) → conservatively
    // a participant (reviewer), not presumed owner.
    func test_sharedOwnerNil_defaultsToReviewer() {
        let meta = ShareMetadata(
            isShared: true, isOwner: nil, canWrite: nil,
            ownerName: "Ada Lovelace", currentUserName: nil)
        let c = ShareIdentityMapper.resolve(meta)
        XCTAssertEqual(c.role, .reviewer)
        // canWrite unknown on a share defaults to true (iCloud's default grant).
        XCTAssertTrue(c.canWrite)
    }
}
