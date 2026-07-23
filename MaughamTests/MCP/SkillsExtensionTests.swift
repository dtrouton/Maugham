import XCTest
import CryptoKit
@testable import Maugham

final class SkillsExtensionTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }
    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    private func makeIndex() throws -> SkillIndex {
        let dir = temp.url.appendingPathComponent("transcribing-notebooks")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: transcribing-notebooks\ndescription: Transcribe pages.\n---\nBody here."
            .write(to: dir.appendingPathComponent("SKILL.md"),
                   atomically: true, encoding: .utf8)
        return try SkillIndex(directory: temp.url, strict: true)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_list_entryShape() throws {
        let result = try SkillsExtension.handleList(paramsJSON: nil, index: makeIndex())
        let obj = try json(result)
        let skills = try XCTUnwrap(obj["skills"] as? [[String: Any]])
        XCTAssertEqual(skills.count, 1)
        let entry = skills[0]
        XCTAssertEqual(entry["name"] as? String, "transcribing-notebooks")
        XCTAssertEqual(entry["description"] as? String, "Transcribe pages.")
        XCTAssertEqual(entry["uri"] as? String,
                       "skill://transcribing-notebooks/SKILL.md")
        let fm = try XCTUnwrap(entry["frontmatter"] as? [String: Any])
        XCTAssertEqual(fm["name"] as? String, "transcribing-notebooks")
        let resources = try XCTUnwrap(entry["resources"] as? [[String: Any]])
        XCTAssertEqual(resources[0]["uri"] as? String,
                       "skill://transcribing-notebooks/SKILL.md")
        let digest = try XCTUnwrap(resources[0]["digest"] as? String)
        XCTAssertTrue(digest.hasPrefix("sha256:"))
        XCTAssertNil(obj["nextCursor"], "single page — no cursor")
    }

    func test_read_roundTrips_andDigestMatches() throws {
        let index = try makeIndex()
        let listObj = try json(
            try SkillsExtension.handleList(paramsJSON: nil, index: index))
        let entry = (listObj["skills"] as! [[String: Any]])[0]
        let resource = (entry["resources"] as! [[String: Any]])[0]
        let uri = resource["uri"] as! String
        let digest = resource["digest"] as! String

        let params = try JSONSerialization.data(withJSONObject: ["uri": uri])
        let readObj = try json(
            try SkillsExtension.handleRead(paramsJSON: params, index: index))
        let contents = try XCTUnwrap(readObj["contents"] as? [[String: Any]])
        let text = try XCTUnwrap(contents[0]["text"] as? String)
        let computed = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual("sha256:\(computed)", digest,
                       "published digest must match read bytes")
        XCTAssertTrue(text.contains("Body here."))
    }

    func test_get_knownAndUnknown() throws {
        let index = try makeIndex()
        let known = try JSONSerialization.data(
            withJSONObject: ["uri": "skill://transcribing-notebooks/SKILL.md"])
        let obj = try json(
            try SkillsExtension.handleGet(paramsJSON: known, index: index))
        XCTAssertEqual((obj["skill"] as? [String: Any])?["name"] as? String,
                       "transcribing-notebooks")

        let unknown = try JSONSerialization.data(
            withJSONObject: ["uri": "skill://nope/SKILL.md"])
        XCTAssertThrowsError(
            try SkillsExtension.handleGet(paramsJSON: unknown, index: index))
    }

    func test_read_nonSkillUri_failsLoudly() throws {
        let params = try JSONSerialization.data(
            withJSONObject: ["uri": "file:///etc/passwd"])
        XCTAssertThrowsError(
            try SkillsExtension.handleRead(paramsJSON: params, index: makeIndex()))
    }

    func test_initialize_declaresExtension() async throws {
        let result = try await MCPInitializeHandler.handle(paramsJSON: nil)
        let obj = try json(result)
        let caps = try XCTUnwrap(obj["capabilities"] as? [String: Any])
        // Exact nesting per the SEP-2640 pin (Step 1): the extension id is a
        // key under capabilities.extensions. (Asserting the parsed key rather
        // than string-matching re-serialized JSON, which escapes the id's `/`
        // as `\/` and would spuriously fail a substring check.)
        let extensions = try XCTUnwrap(caps["extensions"] as? [String: Any])
        XCTAssertNotNil(extensions["io.modelcontextprotocol/skills"],
                        "SEP-2640 extension must be declared under capabilities.extensions")
    }

    func test_list_underOneMegabyte() throws {
        let result = try SkillsExtension.handleList(paramsJSON: nil, index: makeIndex())
        XCTAssertLessThan(result.count, 1_000_000)
    }

    /// Helper: add a second skill folder alongside makeIndex()'s.
    private func writeSkill(folder: String, name: String, description: String) throws {
        let dir = temp.url.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: \(description)\n---\nBody \(name)."
            .write(to: dir.appendingPathComponent("SKILL.md"),
                   atomically: true, encoding: .utf8)
    }

    func test_get_matchesByURI_notByName() throws {
        // Two skills; each get must return the entry whose uri matches the
        // request — identity is the URI, not a name-coincidence lookup.
        // (Colliding frontmatter names cannot reach this surface: SkillIndex
        // refuses them at load, pinned in SkillIndexTests.)
        _ = try makeIndex()
        try writeSkill(folder: "editing-pass", name: "editing-pass", description: "Edit.")
        let index = try SkillIndex(directory: temp.url, strict: true)

        for name in ["editing-pass", "transcribing-notebooks"] {
            let uri = "skill://\(name)/SKILL.md"
            let params = try JSONSerialization.data(withJSONObject: ["uri": uri])
            let obj = try json(try SkillsExtension.handleGet(paramsJSON: params, index: index))
            let skill = try XCTUnwrap(obj["skill"] as? [String: Any])
            XCTAssertEqual(skill["uri"] as? String, uri,
                           "get must return the entry with the requested URI")
            XCTAssertEqual(skill["name"] as? String, name)
        }
    }

    func test_read_jsonSibling_correctMimeTypeAndText() throws {
        _ = try makeIndex()
        let jsonBody = "{\"key\": \"value\"}"
        try jsonBody.write(
            to: temp.url.appendingPathComponent("transcribing-notebooks/config.json"),
            atomically: true, encoding: .utf8)
        let index = try SkillIndex(directory: temp.url, strict: true)

        let params = try JSONSerialization.data(
            withJSONObject: ["uri": "skill://transcribing-notebooks/config.json"])
        let obj = try json(try SkillsExtension.handleRead(paramsJSON: params, index: index))
        let content = try XCTUnwrap((obj["contents"] as? [[String: Any]])?.first)
        XCTAssertEqual(content["mimeType"] as? String, "application/json")
        XCTAssertEqual(content["text"] as? String, jsonBody)
        XCTAssertNil(content["blob"], "UTF-8 file must use text, not blob")
    }

    func test_read_binarySibling_returnsBlobNotEmptyText() throws {
        _ = try makeIndex()
        let bytes = Data([0xFF, 0xFE, 0x00])  // not valid UTF-8
        try bytes.write(
            to: temp.url.appendingPathComponent("transcribing-notebooks/data.bin"))
        let index = try SkillIndex(directory: temp.url, strict: true)

        let params = try JSONSerialization.data(
            withJSONObject: ["uri": "skill://transcribing-notebooks/data.bin"])
        let obj = try json(try SkillsExtension.handleRead(paramsJSON: params, index: index))
        let content = try XCTUnwrap((obj["contents"] as? [[String: Any]])?.first)
        XCTAssertNil(content["text"], "non-UTF-8 must not emit a (lossy) text field")
        let blob = try XCTUnwrap(content["blob"] as? String)
        XCTAssertEqual(Data(base64Encoded: blob), bytes,
                       "blob must round-trip the exact bytes")
        XCTAssertEqual(content["mimeType"] as? String, "application/octet-stream")
    }

    /// W8: a skill with no files can serve nothing — skip it rather than
    /// crash on `files[0]`. Unreachable for the static bundle; defensive.
    func test_list_skipsSkillWithNoFiles_defensive() throws {
        let ghost = SkillIndex.Skill(
            name: "ghost", description: "d", body: "",
            raw: "---\nname: ghost\ndescription: d\n---\n", files: [])
        let index = SkillIndex(skills: [ghost], bootstrapTemplate: nil)
        let obj = try json(try SkillsExtension.handleList(paramsJSON: nil, index: index))
        XCTAssertEqual((obj["skills"] as? [[String: Any]])?.count, 0)
    }
}
