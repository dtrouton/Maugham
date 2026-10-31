import XCTest
@testable import Maugham
@testable import MaughamCore

/// The Mac's book-language read goes through Core's `BookLanguage`, the one the phone uses, so
/// a config the full `PublishConfig` decode would refuse still gives its language.
@MainActor
final class BookLanguageTagTests: XCTestCase {
    private func store(config: String?) async throws -> ProjectStore {
        let url = TestTemp.root.appendingPathComponent("booklang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let manifest = ProjectManifest(type: .novel, title: "T", author: "A", created: Date(),
                                       modified: Date(), structure: [], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: url.appendingPathComponent(ProjectManifest.fileName))
        if let config {
            let file = BookLanguage.configURL(in: url)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(config.utf8).write(to: file)
        }
        return try await ProjectStore.load(from: url)
    }

    func test_aConfigWithUnrelatedMalformedKeysStillYieldsItsLanguage() async throws {
        let s = try await store(config: #"{"outputs":"not an object","sections":[1,2],"metadata":{"title":"T","language":" es "}}"#)
        let tag = await s.bookLanguageTag()
        XCTAssertEqual(tag, "es")
    }

    func test_noConfigIsNil() async throws {
        let s = try await store(config: nil)
        let tag = await s.bookLanguageTag()
        XCTAssertNil(tag)
    }
}
