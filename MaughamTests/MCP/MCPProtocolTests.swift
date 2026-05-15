import XCTest
@testable import Maugham

final class MCPProtocolTests: XCTestCase {
    func test_request_decodes_methodAndId() throws {
        let raw = #"{"jsonrpc":"2.0","id":7,"method":"list_projects"}"#
        let req = try JSONDecoder().decode(MCPRequest.self, from: Data(raw.utf8))
        XCTAssertEqual(req.method, "list_projects")
        XCTAssertEqual(req.id, .int(7))
        XCTAssertNil(req.paramsJSON)
    }

    func test_request_decodes_stringId() throws {
        let raw = #"{"jsonrpc":"2.0","id":"abc","method":"x"}"#
        let req = try JSONDecoder().decode(MCPRequest.self, from: Data(raw.utf8))
        XCTAssertEqual(req.id, .string("abc"))
    }

    func test_request_preservesRawParams() throws {
        let raw = #"{"jsonrpc":"2.0","id":1,"method":"x","params":{"a":1}}"#
        let req = try JSONDecoder().decode(MCPRequest.self, from: Data(raw.utf8))
        XCTAssertNotNil(req.paramsJSON)
    }

    func test_successResponse_encodesResult() throws {
        let resp = MCPResponse.success(id: .int(7), resultJSON: Data("{\"ok\":true}".utf8))
        let encoded = try JSONEncoder().encode(resp)
        let json = String(data: encoded, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"jsonrpc\":\"2.0\""))
        XCTAssertTrue(json.contains("\"id\":7"))
        XCTAssertTrue(json.contains("\"result\""))
        XCTAssertFalse(json.contains("\"error\""))
    }

    func test_errorResponse_encodesError() throws {
        let resp = MCPResponse.failure(
            id: .int(7),
            code: MCPError.maughamNotRunning.code,
            message: "Maugham not running")
        let encoded = try JSONEncoder().encode(resp)
        let json = String(data: encoded, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"error\""))
        XCTAssertTrue(json.contains("-32001"))
    }

    func test_mcpError_codes() {
        XCTAssertEqual(MCPError.maughamNotRunning.code, -32001)
        XCTAssertEqual(MCPError.projectNotOpen.code, -32002)
        XCTAssertEqual(MCPError.mcpDisabled.code, -32003)
    }
}
