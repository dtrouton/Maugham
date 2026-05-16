import XCTest
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
        XCTAssertEqual(name, "maugham")
        // capabilities.tools
        guard case .object(let caps) = obj["capabilities"] else { return XCTFail("no capabilities") }
        XCTAssertNotNil(caps["tools"])
    }

    func test_toolsList_returnsAllTenTools() async throws {
        let data = try await MCPToolsListHandler.handle(paramsJSON: nil)
        let any = try JSONDecoder().decode(AnyJSON.self, from: data)
        guard case .object(let obj) = any,
              case .array(let tools) = obj["tools"] else {
            return XCTFail("expected {tools: [...]}")
        }
        let names: [String] = tools.compactMap { t in
            if case .object(let o) = t, case .string(let n) = o["name"] { return n }
            return nil
        }
        XCTAssertEqual(Set(names), Set([
            "list_projects", "get_metadata", "get_outline",
            "read_document", "search_text", "list_scenes",
            "find_references", "get_session_stats", "add_note",
            "list_research"
        ]))
    }

    func test_toolsList_eachToolHasNameDescriptionAndSchema() async throws {
        let data = try await MCPToolsListHandler.handle(paramsJSON: nil)
        let any = try JSONDecoder().decode(AnyJSON.self, from: data)
        guard case .object(let obj) = any,
              case .array(let tools) = obj["tools"] else {
            return XCTFail("expected {tools: [...]}")
        }
        XCTAssertEqual(tools.count, 10)
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
        } catch {
            // Either methodNotFound or invalidArgument is acceptable;
            // the point is we don't return a success response.
        }
    }
}
