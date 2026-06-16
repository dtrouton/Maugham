import XCTest
@testable import Maugham

final class GetHelpToolTests: XCTestCase {
    private func tempIndex() throws -> HelpTopicIndex {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"[{"slug":"focus","title":"Focus","order":1}]"#
            .write(to: dir.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
        try "# Focus\nUse Cmd-backslash.".write(
            to: dir.appendingPathComponent("focus.md"), atomically: true, encoding: .utf8)
        return try HelpTopicIndex(directory: dir)
    }

    func test_noTopicReturnsIndex() throws {
        let data = try GetHelpTool.respond(paramsJSON: nil, index: tempIndex())
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let topics = obj["topics"] as! [[String: Any]]
        XCTAssertEqual(topics.first?["slug"] as? String, "focus")
        XCTAssertEqual(topics.first?["title"] as? String, "Focus")
    }

    func test_knownTopicReturnsMarkdown() throws {
        let params = #"{"topic":"focus"}"#.data(using: .utf8)
        let data = try GetHelpTool.respond(paramsJSON: params, index: tempIndex())
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["slug"] as? String, "focus")
        XCTAssertEqual(obj["markdown"] as? String, "# Focus\nUse Cmd-backslash.")
    }

    func test_unknownTopicThrows() throws {
        let params = #"{"topic":"nope"}"#.data(using: .utf8)
        XCTAssertThrowsError(try GetHelpTool.respond(paramsJSON: params, index: tempIndex()))
    }
}
