import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class ProjectToolsTests: XCTestCase {
    private func makeProject(title: String = "Demo") async throws -> (URL, ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PT-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "x".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                       atomically: true, encoding: .utf8)
        let item = StructureItem(id: "ch-1", title: "Ch 1", type: .document,
                                  path: "manuscript/c1.md")
        let manifest = ProjectManifest(
            type: .novel, title: title, author: "A",
            created: Date(), modified: Date(),
            structure: [item], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, try await ProjectStore.load(from: tmp))
    }

    func test_listProjects_returnsRegisteredProjects() async throws {
        let (u1, s1) = try await makeProject(title: "A")
        let (u2, s2) = try await makeProject(title: "B")
        let reg = ProjectRegistry()
        reg.register(url: u1, store: s1)
        reg.register(url: u2, store: s2)
        let json = try await ListProjectsTool.handle(paramsJSON: nil, registry: reg)
        let result = try JSONDecoder().decode([ListProjectsTool.Project].self, from: json)
        XCTAssertEqual(Set(result.map(\.title)), ["A", "B"])
        XCTAssertEqual(Set(result.map(\.id)),
                       Set([ProjectIdentifier.id(for: u1), ProjectIdentifier.id(for: u2)]))
    }

    func test_getMetadata_returnsTitleAndType() async throws {
        let (url, store) = try await makeProject(title: "Mine")
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let json = try await GetMetadataTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meta = try decoder.decode(GetMetadataTool.Metadata.self, from: json)
        XCTAssertEqual(meta.title, "Mine")
        XCTAssertEqual(meta.type, "novel")
    }

    func test_getMetadata_unknownProject_throwsUnknownProjectID() async throws {
        let reg = ProjectRegistry()
        let req = "{\"project_id\":\"proj_deadbeef\"}"
        do {
            _ = try await GetMetadataTool.handle(
                paramsJSON: Data(req.utf8), registry: reg)
            XCTFail("expected throw")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "unknown_project_id")
        } catch {
            XCTFail("wrong: \(error)")
        }
    }
}

// MARK: - get_outline reports the derived review status (M3 P3 Task 8)

/// These assert the RAW JSON, not the tool's own `Codable` type. Decoding
/// through `GetOutlineTool.Outline` cannot see whether a key was EMITTED —
/// an absent key and an explicit `null` both decode to the same `nil` — and
/// `Node`'s hand-written encoder exists precisely to make that distinction
/// (uniform schema across nodes). A test that cannot see the difference
/// cannot guard it.
extension ProjectToolsTests {

    /// Builds a project whose single document carries `passStates`, plus a
    /// group with a child, so a group node's shape is assertable too.
    fileprivate func makeReviewProject(
        passStates: [String: PassState]?,
        legacyStatus: String?,
        reviewPasses: [ReviewPass] = []
    ) async throws -> (URL, ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PT-rev-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "x".write(to: tmp.appendingPathComponent("manuscript/c1.md"),
                      atomically: true, encoding: .utf8)
        let doc = StructureItem(
            id: "ch-1", title: "Ch 1", type: .document,
            path: "manuscript/c1.md",
            status: legacyStatus,
            passStates: passStates)
        let group = StructureItem(
            id: "part-1", title: "Part One", type: .group,
            children: [doc])
        let manifest = ProjectManifest(
            type: .novel, title: "Rev", author: "A",
            created: Date(), modified: Date(),
            structure: [group], research: [],
            reviewPasses: reviewPasses)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, try await ProjectStore.load(from: tmp))
    }

    fileprivate func outlineJSON(_ url: URL, _ store: ProjectStore) async throws -> [String: Any] {
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        let id = ProjectIdentifier.id(for: url)
        let data = try await GetOutlineTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(id)\"}".utf8), registry: reg)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_getOutline_reportsDerivedStatusAndPassStates() async throws {
        // One preset pass touched, three untouched → `.revising`.
        let (url, store) = try await makeReviewProject(
            passStates: ["structural": .done, "line": .inProgress],
            legacyStatus: nil)
        let root = try await outlineJSON(url, store)
        let nodes = try XCTUnwrap(root["nodes"] as? [[String: Any]])
        let children = try XCTUnwrap(nodes[0]["children"] as? [[String: Any]])
        let docNode = children[0]

        XCTAssertEqual(docNode["review_status"] as? String, "revising")
        let states = try XCTUnwrap(docNode["pass_states"] as? [String: Any])
        XCTAssertEqual(states["structural"] as? String, "done")
        XCTAssertEqual(states["line"] as? String, "in_progress")
        XCTAssertEqual(states.count, 2)
        // **The wire census.** `Node.encode` is hand-written, so a field added
        // to the struct and forgotten in the encoder vanishes with nothing
        // red. A DOCUMENT node's schema: every key emitted (null when nil),
        // and `children` absent, which is how a leaf says it is one.
        XCTAssertEqual(Set(docNode.keys), [
            "id", "title", "type", "status", "review_status", "pass_states",
            "synopsis", "word_count", "word_target", "modified",
        ], "get the encoder and this list back in step before changing either")
    }

    /// Without the ladder a reader cannot ORDER the `pass_states` map, so the
    /// outline carries the project's effective passes at its top level, in
    /// ladder order.
    func test_getOutline_carriesTheEffectivePassLadderInOrder() async throws {
        let custom = [
            ReviewPass(id: "beta", name: "Beta Read"),
            ReviewPass(id: "polish", name: "Polish"),
        ]
        let (url, store) = try await makeReviewProject(
            passStates: nil, legacyStatus: nil, reviewPasses: custom)
        let root = try await outlineJSON(url, store)
        let passes = try XCTUnwrap(root["review_passes"] as? [[String: Any]])
        XCTAssertEqual(passes.map { $0["id"] as? String }, ["beta", "polish"])
        XCTAssertEqual(passes.map { $0["name"] as? String }, ["Beta Read", "Polish"])
    }

    /// A project that has never customized its passes reports the presets —
    /// `effectiveReviewPasses`, never the raw stored array.
    func test_getOutline_uncustomizedProjectReportsThePresets() async throws {
        let (url, store) = try await makeReviewProject(
            passStates: nil, legacyStatus: nil)
        let root = try await outlineJSON(url, store)
        let passes = try XCTUnwrap(root["review_passes"] as? [[String: Any]])
        XCTAssertEqual(passes.map { $0["id"] as? String },
                       ReviewPass.presets.map(\.id))
    }

    /// The preset ladder (never customized) serves each preset's own brief —
    /// four non-null briefs, in ladder order.
    func test_getOutline_presetLadderServesFourNonNullBriefs() async throws {
        let (url, store) = try await makeReviewProject(
            passStates: nil, legacyStatus: nil)
        let root = try await outlineJSON(url, store)
        let passes = try XCTUnwrap(root["review_passes"] as? [[String: Any]])
        XCTAssertEqual(passes.count, ReviewPass.presets.count)
        for (pass, preset) in zip(passes, ReviewPass.presets) {
            let brief = try XCTUnwrap(pass["brief"] as? String,
                                       "preset \(preset.id) must serve a non-null brief")
            XCTAssertEqual(brief, preset.brief)
        }
    }

    /// A customized pass carrying its own brief serves that brief, not any
    /// preset's.
    func test_getOutline_customizedPassWithOwnBriefServesIt() async throws {
        let custom = [ReviewPass(id: "beta", name: "Beta Read", brief: "Read as a reader would.")]
        let (url, store) = try await makeReviewProject(
            passStates: nil, legacyStatus: nil, reviewPasses: custom)
        let root = try await outlineJSON(url, store)
        let passes = try XCTUnwrap(root["review_passes"] as? [[String: Any]])
        XCTAssertEqual(passes[0]["brief"] as? String, "Read as a reader would.")
    }

    /// A briefless custom pass — id matches no preset — serves the JSON `null`
    /// literal with the KEY present. Falsification: switching the emission to
    /// `encodeIfPresent` drops the key entirely and this goes red.
    func test_getOutline_brieflessCustomPassServesNullBriefKeyPresent() async throws {
        let custom = [ReviewPass(id: "beta", name: "Beta Read")]
        let (url, store) = try await makeReviewProject(
            passStates: nil, legacyStatus: nil, reviewPasses: custom)
        let root = try await outlineJSON(url, store)
        let passes = try XCTUnwrap(root["review_passes"] as? [[String: Any]])
        XCTAssertTrue(passes[0].keys.contains("brief"),
                      "brief must be emitted as null, not omitted")
        XCTAssertTrue(passes[0]["brief"] is NSNull)
    }

    /// A stored preset-id pass with no brief of its own (renamed/reordered,
    /// predates the field) falls back to the matching preset's brief — the
    /// `effectiveBrief` discriminator, never `$0.brief` raw.
    func test_getOutline_storedPresetIdPassWithoutBriefServesThePresetsBrief() async throws {
        let renamed = [ReviewPass(id: "structural", name: "Big Picture")]
        let (url, store) = try await makeReviewProject(
            passStates: nil, legacyStatus: nil, reviewPasses: renamed)
        let root = try await outlineJSON(url, store)
        let passes = try XCTUnwrap(root["review_passes"] as? [[String: Any]])
        XCTAssertEqual(passes[0]["name"] as? String, "Big Picture")
        XCTAssertEqual(passes[0]["brief"] as? String,
                       ReviewPass.presets.first { $0.id == "structural" }?.brief)
    }

    /// A pre-M3 piece: no pass states, a legacy `"final"` string. The derived
    /// status falls back to the legacy string, and `pass_states` is an emitted
    /// JSON `null` rather than a missing key.
    func test_getOutline_preM3Piece_derivesFromLegacyStatusAndNullsPassStates() async throws {
        let (url, store) = try await makeReviewProject(
            passStates: nil, legacyStatus: "final")
        let root = try await outlineJSON(url, store)
        let nodes = try XCTUnwrap(root["nodes"] as? [[String: Any]])
        let docNode = try XCTUnwrap((nodes[0]["children"] as? [[String: Any]])?[0])

        XCTAssertEqual(docNode["review_status"] as? String, "final")
        XCTAssertEqual(docNode["status"] as? String, "final",
                       "the legacy raw string stays on the wire")
        // The uniform-schema rule: the KEY is present, carrying null.
        XCTAssertTrue(docNode.keys.contains("pass_states"),
                      "pass_states must be emitted as null, not omitted")
        XCTAssertTrue(docNode["pass_states"] is NSNull)
    }

    /// A group is not a piece: it has no pass states and no derived status,
    /// and both keys are emitted as null so every node has one schema.
    func test_getOutline_groupNodesEmitBothReviewKeysAsNull() async throws {
        let (url, store) = try await makeReviewProject(
            passStates: ["structural": .done], legacyStatus: nil)
        let root = try await outlineJSON(url, store)
        let group = try XCTUnwrap((root["nodes"] as? [[String: Any]])?[0])
        XCTAssertEqual(group["type"] as? String, "group")
        XCTAssertTrue(group.keys.contains("review_status"))
        XCTAssertTrue(group["review_status"] is NSNull)
        XCTAssertTrue(group.keys.contains("pass_states"))
        XCTAssertTrue(group["pass_states"] is NSNull)
        // The census, the other half: a group's schema is the document's plus
        // `children`. Nothing else may differ between the two node kinds.
        XCTAssertEqual(Set(group.keys), [
            "id", "title", "type", "status", "review_status", "pass_states",
            "synopsis", "word_count", "word_target", "modified", "children",
        ], "get the encoder and this list back in step before changing either")
    }
}

extension ProjectToolsTests {
    func test_listProjects_includesCollection() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCP-coll-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(
            named: "C", in: tmp)
        let store = try await ProjectStore.load(from: url)
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        let data = try await ListProjectsTool.handle(paramsJSON: nil, registry: reg)
        let projects = try JSONDecoder().decode(
            [ListProjectsTool.Project].self, from: data)
        XCTAssertTrue(projects.contains { $0.type == "collection" })
    }

    func test_getOutline_Collection_returnsPiecesFlat() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCP-out-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createCollectionProject(
            named: "C", in: tmp)
        let store = try await ProjectStore.load(from: url)
        _ = try await store.addLoosePiece(title: "Story A", mode: .prose)
        _ = try await store.addLoosePiece(title: "Story B", mode: .screenplay)
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)

        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\"}"
        let data = try await GetOutlineTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let outline = try decoder.decode(
            GetOutlineTool.Outline.self, from: data)
        XCTAssertEqual(outline.nodes.count, 2)
        XCTAssertNil(outline.nodes[0].children)
    }
}
