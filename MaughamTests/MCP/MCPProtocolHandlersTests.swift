import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class MCPProtocolHandlersTests: XCTestCase {
    func test_initialize_returnsServerInfoAndCapabilities() async throws {
        let data = try await MCPInitializeHandler.handle(paramsJSON: nil)
        let any = try JSONDecoder().decode(AnyJSON.self, from: data)
        guard case .object(let obj) = any else { return XCTFail("not an object") }
        // protocolVersion
        guard case .string(let pv) = obj["protocolVersion"] else { return XCTFail("no protocolVersion") }
        XCTAssertFalse(pv.isEmpty)
        // serverInfo
        guard case .object(let info) = obj["serverInfo"] else { return XCTFail("no serverInfo") }
        guard case .string(let name) = info["name"] else { return XCTFail("no name") }
        XCTAssertEqual(name, BuildVariant.current.mcpServerKey)
        // capabilities.tools
        guard case .object(let caps) = obj["capabilities"] else { return XCTFail("no capabilities") }
        XCTAssertNotNil(caps["tools"])
    }

    func test_toolsList_returnsAllExpectedTools() async throws {
        let data = try await MCPToolsListHandler.handle(paramsJSON: nil)
        let any = try JSONDecoder().decode(AnyJSON.self, from: data)
        guard case .object(let obj) = any,
              case .array(let tools) = obj["tools"] else {
            return XCTFail("expected {tools: [...]}")
        }
        let allNames: [String] = tools.compactMap { t in
            if case .object(let o) = t, case .string(let n) = o["name"] { return n }
            return nil
        }
        // Dev builds also advertise the dev-only `test_` tools (so Claude Code
        // can discover them). Exclude them here — this test pins the PRODUCTION
        // catalog exactly. The test_ catalog has its own coverage in
        // TestMCPCatalogConsistencyTests.
        let names = allNames.filter { !$0.hasPrefix("test_") }
        XCTAssertEqual(Set(names), Set([
            "list_projects", "get_metadata", "get_outline",
            "read_document", "search_text", "list_scenes",
            "find_references", "get_session_stats", "add_note",
            "list_research", "list_documents_by_tag",
            "link_research", "unlink_research", "list_all_links",
            "add_comment", "add_suggested_change", "add_query",
            "add_craft_note", "list_annotations", "get_annotation",
            "list_tasks", "get_task",
            "initialize_publish_template",
            "get_publish_config", "set_publish_config",
            "list_publish_files", "read_publish_file",
            "read_publish_image", "write_publish_file",
            "delete_publish_file",
            "compile", "preview_compile",
            "compile_status", "compile_cancel",
            "list_publications", "read_publication_page", "republish",
            "set_piece_style", "clear_piece_style",
            "list_inbox", "read_inbox_entry", "promote_inbox_entry",
            "list_maugham_tools", "get_help"
        ]))
    }

    func test_toolsList_eachToolHasNameDescriptionAndSchema() async throws {
        let data = try await MCPToolsListHandler.handle(paramsJSON: nil)
        let any = try JSONDecoder().decode(AnyJSON.self, from: data)
        guard case .object(let obj) = any,
              case .array(let tools) = obj["tools"] else {
            return XCTFail("expected {tools: [...]}")
        }
        // Every advertised tool (production AND the dev-only test_ tools, which
        // dev builds also list) must carry name/description/schema — validate
        // the whole set. The production count is pinned separately by filtering
        // out test_ tools.
        let productionTools = tools.filter { t in
            if case .object(let o) = t, case .string(let n) = o["name"] { return !n.hasPrefix("test_") }
            return true
        }
        XCTAssertEqual(productionTools.count, MCPToolCatalog.all.count)
        for t in tools {
            guard case .object(let o) = t else { return XCTFail("tool not object") }
            XCTAssertNotNil(o["name"])
            XCTAssertNotNil(o["description"])
            XCTAssertNotNil(o["inputSchema"])
        }
    }

    func test_toolsCall_dispatchesViaRouter_andWrapsAsContent() async throws {
        let router = MCPRouter()
        router.register(method: "echo") { params in
            // Echo back as JSON string
            return Data("\"hi\"".utf8)
        }
        let req = """
        {"name":"echo","arguments":{}}
        """
        let resp = try await MCPToolsCallHandler.handle(
            paramsJSON: Data(req.utf8), router: router)
        // MCP spec: {content: [{type: "text", text: <stringified>}]}
        let any = try JSONDecoder().decode(AnyJSON.self, from: resp)
        guard case .object(let obj) = any,
              case .array(let content) = obj["content"],
              let first = content.first,
              case .object(let block) = first,
              case .string(let typ) = block["type"],
              case .string(let txt) = block["text"] else {
            return XCTFail("expected MCP content shape, got: \(any)")
        }
        XCTAssertEqual(typ, "text")
        XCTAssertTrue(txt.contains("hi"))
    }

    func test_toolsCall_unknownTool_throws() async throws {
        let router = MCPRouter()
        let req = """
        {"name":"nope","arguments":{}}
        """
        do {
            _ = try await MCPToolsCallHandler.handle(
                paramsJSON: Data(req.utf8), router: router)
            XCTFail("expected throw")
        } catch MCPRouterError.methodNotFound {
            // Protocol-level failure: stays as JSON-RPC error so the
            // wire-level method-not-found semantics are preserved.
        }
    }

    func test_toolsCall_invalidArgument_becomesStructuredIsErrorResult() async throws {
        let router = MCPRouter()
        router.register(method: "bad") { _ in
            throw MCPError.invalidArgument("project_id required")
        }
        let req = #"{"name":"bad","arguments":{}}"#
        let resp = try await MCPToolsCallHandler.handle(
            paramsJSON: Data(req.utf8), router: router)
        let any = try JSONDecoder().decode(AnyJSON.self, from: resp)
        guard case .object(let obj) = any else {
            return XCTFail("expected object envelope, got: \(any)")
        }
        // isError must be true.
        guard case .bool(let isErr) = obj["isError"], isErr else {
            return XCTFail("expected isError=true; got \(String(describing: obj["isError"]))")
        }
        // Content block carries the structured payload as text.
        guard case .array(let content) = obj["content"],
              case .object(let block) = content.first ?? .null,
              case .string(let text) = block["text"] else {
            return XCTFail("expected content block with text payload")
        }
        let payload = try JSONSerialization.jsonObject(
            with: Data(text.utf8)) as? [String: Any] ?? [:]
        XCTAssertEqual(payload["error"] as? String, "invalid_argument")
        XCTAssertEqual(payload["message"] as? String, "project_id required")
    }

    func test_toolsCall_genericSwiftError_becomesStructuredInternalError() async throws {
        struct Boom: Error { let why: String }
        let router = MCPRouter()
        router.register(method: "boom") { _ in
            throw Boom(why: "kaboom")
        }
        let req = #"{"name":"boom","arguments":{}}"#
        let resp = try await MCPToolsCallHandler.handle(
            paramsJSON: Data(req.utf8), router: router)
        let any = try JSONDecoder().decode(AnyJSON.self, from: resp)
        guard case .object(let obj) = any,
              case .bool(true) = obj["isError"] ?? .null,
              case .array(let content) = obj["content"],
              case .object(let block) = content.first ?? .null,
              case .string(let text) = block["text"] else {
            return XCTFail("expected isError=true with text payload, got \(any)")
        }
        let payload = try JSONSerialization.jsonObject(
            with: Data(text.utf8)) as? [String: Any] ?? [:]
        XCTAssertEqual(payload["error"] as? String, "internal_error")
        XCTAssertTrue((payload["message"] as? String ?? "").contains("kaboom"))
    }

    func test_toolsCall_toolErrorPayload_passesThroughUnchanged() async throws {
        let router = MCPRouter()
        let custom = MCPError.ToolErrorPayload(
            error: "paragraph_not_found",
            message: "paragraph X is gone",
            hint: "re-read the document",
            fields: ["paragraph_id": .string("X")])
        router.register(method: "anno") { _ in
            throw MCPError.toolError(payload: custom)
        }
        let req = #"{"name":"anno","arguments":{}}"#
        let resp = try await MCPToolsCallHandler.handle(
            paramsJSON: Data(req.utf8), router: router)
        let any = try JSONDecoder().decode(AnyJSON.self, from: resp)
        guard case .object(let obj) = any,
              case .bool(true) = obj["isError"] ?? .null,
              case .array(let content) = obj["content"],
              case .object(let block) = content.first ?? .null,
              case .string(let text) = block["text"] else {
            return XCTFail("expected isError=true with text payload, got \(any)")
        }
        let payload = try JSONSerialization.jsonObject(
            with: Data(text.utf8)) as? [String: Any] ?? [:]
        XCTAssertEqual(payload["error"] as? String, "paragraph_not_found")
        XCTAssertEqual(payload["message"] as? String, "paragraph X is gone")
        XCTAssertEqual(payload["hint"] as? String, "re-read the document")
        XCTAssertEqual(payload["paragraph_id"] as? String, "X")
    }
}
