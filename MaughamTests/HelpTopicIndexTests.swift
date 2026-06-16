import XCTest
@testable import Maugham

final class HelpTopicIndexTests: XCTestCase {
    private func makeGuideDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("guide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = """
        [{"slug":"b-topic","title":"B Topic","order":2},
         {"slug":"a-topic","title":"A Topic","order":1}]
        """
        try index.write(to: dir.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
        try "# A Topic\nHello A.".write(to: dir.appendingPathComponent("a-topic.md"), atomically: true, encoding: .utf8)
        try "# B Topic\nHello B.".write(to: dir.appendingPathComponent("b-topic.md"), atomically: true, encoding: .utf8)
        return dir
    }

    func test_topicsSortedByOrder() throws {
        let index = try HelpTopicIndex(directory: makeGuideDir())
        XCTAssertEqual(index.topics.map(\.slug), ["a-topic", "b-topic"])
        XCTAssertEqual(index.topics.map(\.title), ["A Topic", "B Topic"])
    }

    func test_markdownForKnownSlug() throws {
        let index = try HelpTopicIndex(directory: makeGuideDir())
        XCTAssertEqual(try index.markdown(for: "a-topic"), "# A Topic\nHello A.")
    }

    func test_unknownSlugThrows() throws {
        let index = try HelpTopicIndex(directory: makeGuideDir())
        XCTAssertThrowsError(try index.markdown(for: "missing"))
    }
}
