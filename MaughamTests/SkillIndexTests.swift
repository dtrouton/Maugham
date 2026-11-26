import XCTest
import CryptoKit
@testable import Maugham

final class SkillIndexTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }
    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func writeSkill(_ name: String, frontmatter: String, body: String) throws {
        let dir = temp.url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\n\(frontmatter)\n---\n\(body)".write(
            to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    func test_load_parsesFrontmatterAndBody() throws {
        try writeSkill("alpha",
            frontmatter: "name: alpha\ndescription: Does alpha things.",
            body: "# Alpha\nStep one.")
        let index = try SkillIndex(directory: temp.url, strict: true)
        let skill = try XCTUnwrap(index.skill(named: "alpha"))
        XCTAssertEqual(skill.description, "Does alpha things.")
        XCTAssertEqual(skill.body, "# Alpha\nStep one.")
        XCTAssertTrue(skill.raw.hasPrefix("---\n"))
    }

    func test_files_haveStableSha256() throws {
        try writeSkill("alpha", frontmatter: "name: alpha\ndescription: d", body: "B")
        let index = try SkillIndex(directory: temp.url, strict: true)
        let file = try XCTUnwrap(index.skill(named: "alpha")?.files.first)
        XCTAssertEqual(file.relativePath, "SKILL.md")
        let expected = SHA256.hash(data: file.bytes)
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(file.sha256Hex, expected)
    }

    func test_extraFiles_listedAfterSkillMd() throws {
        try writeSkill("alpha", frontmatter: "name: alpha\ndescription: d", body: "B")
        try "ref".write(
            to: temp.url.appendingPathComponent("alpha/reference.md"),
            atomically: true, encoding: .utf8)
        let index = try SkillIndex(directory: temp.url, strict: true)
        let paths = index.skill(named: "alpha")?.files.map(\.relativePath)
        XCTAssertEqual(paths, ["SKILL.md", "reference.md"])
    }

    func test_bootstrap_excludedFromSkillsButExposed() throws {
        try writeSkill("alpha", frontmatter: "name: alpha\ndescription: d", body: "B")
        try writeSkill("maugham-bootstrap",
            frontmatter: "name: maugham\ndescription: router", body: "R")
        let index = try SkillIndex(directory: temp.url, strict: true)
        XCTAssertEqual(index.skills.map(\.name), ["alpha"])
        XCTAssertEqual(index.bootstrapTemplate?.body, "R")
    }

    func test_strict_malformedFrontmatterThrows() throws {
        try writeSkill("bad", frontmatter: "no-colon-here", body: "B")
        XCTAssertThrowsError(try SkillIndex(directory: temp.url, strict: true)) { error in
            XCTAssertEqual(error as? SkillIndex.LoadError, .malformedFrontmatter("bad"))
        }
    }

    func test_lenient_malformedFrontmatterSkipsSkill() throws {
        try writeSkill("bad", frontmatter: "no-colon-here", body: "B")
        try writeSkill("good", frontmatter: "name: good\ndescription: d", body: "B")
        let index = try SkillIndex(directory: temp.url, strict: false)
        XCTAssertEqual(index.skills.map(\.name), ["good"])
    }

    func test_strict_duplicateFrontmatterNameThrows() throws {
        // Distinct folders, colliding frontmatter `name` — would mint
        // colliding skill:// URIs (the namespace derives from the name).
        try writeSkill("aaa-folder", frontmatter: "name: dup\ndescription: first", body: "A")
        try writeSkill("bbb-folder", frontmatter: "name: dup\ndescription: second", body: "B")
        XCTAssertThrowsError(try SkillIndex(directory: temp.url, strict: true)) { error in
            XCTAssertEqual(error as? SkillIndex.LoadError, .duplicateSkillName("dup"))
        }
    }

    func test_lenient_duplicateFrontmatterNameKeepsFirst() throws {
        try writeSkill("aaa-folder", frontmatter: "name: dup\ndescription: first", body: "A")
        try writeSkill("bbb-folder", frontmatter: "name: dup\ndescription: second", body: "B")
        let index = try SkillIndex(directory: temp.url, strict: false)
        XCTAssertEqual(index.skills.map(\.name), ["dup"], "one survivor — URIs stay unique")
        XCTAssertEqual(index.skills.first?.description, "first",
                       "folder-name sort order: first loaded wins")
    }

    func test_bundledSkills_loadAndAreNonEmpty() throws {
        // The real bundled content: all skills present with descriptions.
        let index = try SkillIndex.bundled()
        XCTAssertEqual(index.skills.map(\.name),
                       ["editing-pass", "edition-brief", "publishing-setup", "transcribing-notebooks", "translation-pass", "visual-language"])
        XCTAssertNotNil(index.bootstrapTemplate)
        for skill in index.skills {
            XCTAssertFalse(skill.description.isEmpty)
            XCTAssertGreaterThan(skill.body.count, 200)
        }
    }

    // MARK: - What the served text names (shell p5 Task 9)

    /// Every name the served text sends Claude to load — "`get_help` topic
    /// `x`", "the `x` skill", "load `x`" — in the order found.
    static func namedTopics(in text: String) -> [String] {
        let patterns = [
            #"topic\s+[`"]([a-z]+(?:-[a-z]+)*)[`"]"#,
            #"[`"]([a-z]+(?:-[a-z]+)+)[`"]\s+skill"#,
            #"\bload\s+[`"]([a-z]+(?:-[a-z]+)+)[`"]"#,
        ]
        let ns = text as NSString
        return patterns.flatMap { pattern in
            try! NSRegularExpression(pattern: pattern)
                .matches(in: text, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range(at: 1)) }
        }
    }

    /// **The router and every skill send Claude only to what `get_help`
    /// serves**: a skill by its name, a guide page by its slug, or "skills".
    func test_everyTopicTheServedTextNamesIsServed() throws {
        let skills = try SkillIndex.bundled()
        let guide = try HelpTopicIndex.bundled()
        let served = Set(skills.skills.map(\.name) + guide.topics.map(\.slug) + ["skills"])
        let bodies = skills.skills.map { ($0.name, $0.body) } + [("maugham-bootstrap", skills.bootstrapTemplate?.body ?? "")]
        let named = bodies.flatMap { name, body in Self.namedTopics(in: body).map { (name, $0) } }
        XCTAssertTrue(named.contains { $0.1 == "publishing-setup" }, "premise: the router names publishing-setup")
        XCTAssertEqual(named.filter { !served.contains($0.1) }.map { "\($0.0): \($0.1)" }, [],
                       "a skill sends Claude to a topic get_help does not serve")
    }

    func test_theNamedTopicReaderCatchesAPlantedName() {
        XCTAssertEqual(Self.namedTopics(in: "Call `get_help` with topic `retired-skill`; run the `visual-language` skill; load `transcribing-notebooks`."),
                       ["retired-skill", "visual-language", "transcribing-notebooks"])
        XCTAssertEqual(Self.namedTopics(in: "Pass `document_id` and the `a1` key."), [])
    }
}
