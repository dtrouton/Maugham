import XCTest
@testable import Maugham

@MainActor
final class AddProjectReferenceTests: XCTestCase {
    private func makeCollectionAndTarget() async throws -> (collection: URL, target: URL, store: ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("APR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let collection = try await ProjectFactory.createCollectionProject(
            named: "Anthology", in: tmp)
        let target = try await ProjectFactory.createShortStoryProject(
            named: "The Long One", in: tmp)
        let store = try await ProjectStore.load(from: collection)
        return (collection, target, store)
    }

    func test_addProjectReference_seedsTitleFromTarget() async throws {
        let (_, target, store) = try await makeCollectionAndTarget()
        let piece = try await store.addProjectReference(targetURL: target)
        XCTAssertEqual(piece.title, "The Long One")
        XCTAssertEqual(piece.pieceKind, .reference)
        XCTAssertNotNil(piece.linkedProjectBookmark)
        XCTAssertEqual(piece.linkedProjectPath, target.path)
    }

    func test_addProjectReference_writesLinkFile() async throws {
        let (collection, target, store) = try await makeCollectionAndTarget()
        let piece = try await store.addProjectReference(targetURL: target)
        let linkFileURL = collection.appendingPathComponent(piece.path!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: linkFileURL.path))
        let data = try Data(contentsOf: linkFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let link = try decoder.decode(CollectionLinkFile.self, from: data)
        XCTAssertEqual(link.title, "The Long One")
        XCTAssertEqual(link.path, target.path)
        XCTAssertFalse(link.bookmark.isEmpty)
    }

    func test_addProjectReference_failsOnNonProjectFolder() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("APR-bad-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let collection = try await ProjectFactory.createCollectionProject(
            named: "Anthology", in: tmp)
        let store = try await ProjectStore.load(from: collection)

        let notAProject = tmp.appendingPathComponent("just-a-folder")
        try FileManager.default.createDirectory(at: notAProject, withIntermediateDirectories: true)

        do {
            _ = try await store.addProjectReference(targetURL: notAProject)
            XCTFail("expected throw")
        } catch {
            // ok
        }
    }
}
