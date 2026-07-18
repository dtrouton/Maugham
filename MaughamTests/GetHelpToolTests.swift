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

    /// Injected skills index with one skill (`editing-pass`) so `respond`'s
    /// skills-branching can be exercised without touching the bundled skills.
    private func tempSkills() throws -> SkillIndex {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghi-skills-\(UUID().uuidString)")
        let skillDir = dir.appendingPathComponent("editing-pass")
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "---\nname: editing-pass\ndescription: Run an editing pass.\n---\nRead craft intent first."
            .write(to: skillDir.appendingPathComponent("SKILL.md"),
                   atomically: true, encoding: .utf8)
        return try SkillIndex(directory: dir, strict: true)
    }

    func test_noTopicReturnsIndex() throws {
        let data = try GetHelpTool.respond(paramsJSON: nil, index: tempIndex(), skills: tempSkills())
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let topics = obj["topics"] as! [[String: Any]]
        XCTAssertEqual(topics.first?["slug"] as? String, "focus")
        XCTAssertEqual(topics.first?["title"] as? String, "Focus")
    }

    func test_knownTopicReturnsMarkdown() throws {
        let params = #"{"topic":"focus"}"#.data(using: .utf8)
        let data = try GetHelpTool.respond(paramsJSON: params, index: tempIndex(), skills: tempSkills())
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["slug"] as? String, "focus")
        XCTAssertEqual(obj["markdown"] as? String, "# Focus\nUse Cmd-backslash.")
    }

    func test_unknownTopicThrows() throws {
        let params = #"{"topic":"nope"}"#.data(using: .utf8)
        XCTAssertThrowsError(try GetHelpTool.respond(paramsJSON: params, index: tempIndex(), skills: tempSkills()))
    }

    func test_skillsIndexTopic_listsSkills() throws {
        let data = try GetHelpTool.respond(
            paramsJSON: try JSONSerialization.data(withJSONObject: ["topic": "skills"]),
            index: tempIndex(), skills: tempSkills())
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let skills = try XCTUnwrap(obj["skills"] as? [[String: Any]])
        XCTAssertEqual(skills.first?["name"] as? String, "editing-pass")
        XCTAssertEqual(skills.first?["description"] as? String, "Run an editing pass.")
        XCTAssertEqual(obj["hint"] as? String, "Pass a skill name as topic to load its full procedure.")
    }

    func test_skillName_returnsBodyWithoutFrontmatter() throws {
        let data = try GetHelpTool.respond(
            paramsJSON: try JSONSerialization.data(withJSONObject: ["topic": "editing-pass"]),
            index: tempIndex(), skills: tempSkills())
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["slug"] as? String, "editing-pass")
        let md = try XCTUnwrap(obj["markdown"] as? String)
        XCTAssertTrue(md.contains("Read craft intent first."))
        XCTAssertFalse(md.contains("---"), "frontmatter stripped")
    }

    func test_topicList_includesSkillsSection() throws {
        let data = try GetHelpTool.respond(
            paramsJSON: nil, index: tempIndex(), skills: tempSkills())
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(obj["skills"])
        XCTAssertNotNil(obj["topics"])
    }

    func test_unknownTopic_stillThrows() throws {
        XCTAssertThrowsError(try GetHelpTool.respond(
            paramsJSON: try JSONSerialization.data(withJSONObject: ["topic": "nope"]),
            index: tempIndex(), skills: tempSkills()))
    }

    /// M3: user documentation must not be held hostage to the skills bundle.
    /// When the skills index is empty (e.g. a packaging regression dropped the
    /// `skills/` folder), help topics must still resolve.
    func test_helpTopicsResolve_whenSkillsIndexEmpty() throws {
        let data = try GetHelpTool.respond(
            paramsJSON: #"{"topic":"focus"}"#.data(using: .utf8),
            index: tempIndex(), skills: .empty)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["slug"] as? String, "focus")
        XCTAssertEqual(obj["markdown"] as? String, "# Focus\nUse Cmd-backslash.")
    }

    /// The topic list still serves (with an empty skills section) when the
    /// skills index is empty.
    func test_topicList_servesWithEmptySkillsIndex() throws {
        let data = try GetHelpTool.respond(paramsJSON: nil, index: tempIndex(), skills: .empty)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((obj["skills"] as? [[String: Any]])?.count, 0)
        XCTAssertNotNil(obj["topics"])
    }

    /// Namespace disjointness: the real bundled guide slugs and the real
    /// bundled skill names must not collide, and no skill may be named
    /// "skills" (the literal topic id) — pinning the shadowing rules so a
    /// future content addition can't silently shadow a help topic or the
    /// skills-list branch.
    func test_bundledGuideSlugsAndSkillNames_areDisjoint() throws {
        let guideSlugs = Set(try HelpTopicIndex.bundled().topics.map(\.slug))
        let skillNames = Set(try SkillIndex.bundled().skills.map(\.name))
        XCTAssertTrue(guideSlugs.isDisjoint(with: skillNames),
                      "guide slugs and skill names overlap: \(guideSlugs.intersection(skillNames))")
        XCTAssertFalse(skillNames.contains("skills"),
                       "no skill may be named \"skills\" — it's the literal topic id")
        XCTAssertFalse(guideSlugs.contains("skills"),
                       "no guide topic may be named \"skills\" — the literal topic id wins over it")
    }

    /// "skills" is a literal topic id that wins over any hypothetical help
    /// topic of the same name — pin the precedence so a future help topic
    /// named "skills" can't silently shadow this branch.
    func test_skillsTopic_takesPrecedenceOverHelpTopicNamed() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"[{"slug":"skills","title":"Skills (help topic)","order":1}]"#
            .write(to: dir.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
        try "# Not the real skills response".write(
            to: dir.appendingPathComponent("skills.md"), atomically: true, encoding: .utf8)
        let index = try HelpTopicIndex(directory: dir)

        let data = try GetHelpTool.respond(
            paramsJSON: try JSONSerialization.data(withJSONObject: ["topic": "skills"]),
            index: index, skills: tempSkills())
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(obj["skills"], "literal \"skills\" topic must win over a same-named help topic")
        XCTAssertNil(obj["markdown"])
    }
}
