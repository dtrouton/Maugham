import XCTest
import Foundation
@testable import Maugham

/// Tripwire 10's backstop (#114 F23): the response budget is enforced in
/// `MCPServer.encodeLine`, the one place a JSON-RPC response line is
/// serialized, so neither dispatch path (`tools/call`, or a tool's own
/// top-level method) can put a line over `MCPResponseBudget.maxLineBytes` on
/// the socket. A tool's own `MCPResponseBudget.enforce` stays the first guard,
/// with the better hint; this is the one a new tool cannot forget.
@MainActor
final class MCPResponseLineBudgetTests: XCTestCase {

    private func prefs() -> UserPreferences {
        UserPreferences(defaults: UserDefaults(suiteName: "mcp-line-\(UUID().uuidString)")!)
    }

    /// A router that also serves `tools/call`, as `MCPServer` wires it.
    private func router() -> MCPRouter {
        let router = MCPRouter()
        router.register(method: MCPToolsCallHandler.method) { [unowned router] params in
            try await MCPToolsCallHandler.handle(paramsJSON: params, router: router)
        }
        return router
    }

    private func send(_ line: String, to router: MCPRouter) async throws -> (Data, [String: Any]) {
        let data = await MCPServer.dispatch(
            lineData: Data(line.utf8), router: router, preferences: prefs())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (data, object)
    }

    private func payload(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// A JSON string value of `count` bytes of `a`.
    private func bigString(_ count: Int) -> Data {
        Data(("\"" + String(repeating: "a", count: count) + "\"").utf8)
    }

    // MARK: - The top-level method path

    func test_anOversizedDirectMethodAnswersPayloadTooLargeNotAnOversizedLine() async throws {
        let router = router()
        let big = bigString(1_100_000)
        router.register(method: "unbounded_reader") { _ in big }
        let (data, object) = try await send(
            #"{"jsonrpc":"2.0","id":41,"method":"unbounded_reader"}"#, to: router)
        XCTAssertLessThan(data.count, MCPResponseBudget.maxLineBytes)
        XCTAssertEqual(object["id"] as? Int, 41)
        XCTAssertNil(object["result"])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, MCPError.payloadTooLargeCode)
        let body = try payload(try XCTUnwrap(error["message"] as? String))
        XCTAssertEqual(body["error"] as? String, "payload_too_large")
        XCTAssertEqual(body["max_bytes"] as? Int, MCPResponseBudget.maxLineBytes)
        XCTAssertGreaterThan(body["byte_count"] as? Int ?? 0, MCPResponseBudget.maxLineBytes)
        XCTAssertFalse((body["hint"] as? String ?? "").isEmpty)
    }

    // MARK: - The tools/call path

    /// Text under the 900 KB payload budget that re-escaping pushes past the
    /// line: every `"` in the payload is `\"`, and `\\\"` once wrapped.
    func test_escapeHeavyTextUnderTheTextBudgetIsCaughtOnTheLineUnderToolsCall() async throws {
        let router = router()
        let quotes = String(repeating: "\\\"", count: 400_000)
        let raw = Data(("\"" + quotes + "\"").utf8)
        XCTAssertLessThan(raw.count, MCPResponseBudget.maxTextBytes, "premise: passes enforce")
        router.register(method: "quote_heavy") { _ in raw }
        let (data, object) = try await send(
            #"{"jsonrpc":"2.0","id":"q","method":"tools/call","params":{"name":"quote_heavy"}}"#,
            to: router)
        XCTAssertLessThan(data.count, MCPResponseBudget.maxLineBytes)
        try assertToolErrorPayloadTooLarge(object, id: "q")
    }

    /// A `content` envelope passes `MCPToolsCallHandler`'s text backstop
    /// untouched (`read_palette_card`'s shape); the line still catches it.
    func test_anOversizedContentEnvelopeIsCaughtOnTheLineUnderToolsCall() async throws {
        let router = router()
        router.register(method: "big_envelope") { _ in
            try JSONEncoder().encode(AnyJSON.object(["content": .array([
                .object(["type": .string("text"),
                         "text": .string(String(repeating: "a", count: 1_100_000))]),
            ])]))
        }
        let (data, object) = try await send(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"big_envelope"}}"#,
            to: router)
        XCTAssertLessThan(data.count, MCPResponseBudget.maxLineBytes)
        try assertToolErrorPayloadTooLarge(object, id: "5")
    }

    private func assertToolErrorPayloadTooLarge(
        _ object: [String: Any], id: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual("\(object["id"] ?? "")", id, file: file, line: line)
        XCTAssertNil(object["error"], "an isError tool result, not a JSON-RPC error",
                     file: file, line: line)
        let result = try XCTUnwrap(object["result"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(result["isError"] as? Bool, true, file: file, line: line)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]], file: file, line: line)
        let body = try payload(try XCTUnwrap(content.first?["text"] as? String, file: file, line: line))
        XCTAssertEqual(body["error"] as? String, "payload_too_large", file: file, line: line)
        XCTAssertEqual(body["max_bytes"] as? Int, MCPResponseBudget.maxLineBytes, file: file, line: line)
    }

    // MARK: - What fits is untouched

    func test_aNormalResponseIsTheLineEncodedUnchanged() async throws {
        let router = router()
        router.register(method: "ping") { _ in Data(#"{"ok":true}"#.utf8) }
        let (_, object) = try await send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, to: router)
        // Compared as structure: JSONEncoder's key order is not stable run to run.
        let expected = try JSONEncoder().encode(
            MCPResponse.success(id: .int(1), resultJSON: Data(#"{"ok":true}"#.utf8)))
        let expectedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: expected) as? NSDictionary)
        XCTAssertEqual(object as NSDictionary, expectedObject)
    }

    // MARK: - A tool's own enforce keeps its hint on the direct path

    func test_aDirectMethodsOwnEnforceKeepsItsHintAndTheLineBackstopsCode() async throws {
        let router = router()
        let big = Data(repeating: UInt8(ascii: "a"), count: MCPResponseBudget.maxTextBytes + 1)
        router.register(method: "section_reader") { _ in
            try MCPResponseBudget.enforce(big, hint: "Read one section with search_text.")
        }
        let (_, object) = try await send(
            #"{"jsonrpc":"2.0","id":9,"method":"section_reader"}"#, to: router)
        XCTAssertEqual(object["id"] as? Int, 9)
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, MCPError.payloadTooLargeCode)
        let body = try payload(try XCTUnwrap(error["message"] as? String))
        XCTAssertEqual(body["error"] as? String, "payload_too_large")
        XCTAssertEqual(body["hint"] as? String, "Read one section with search_text.")
        XCTAssertEqual(body["max_bytes"] as? Int, MCPResponseBudget.maxTextBytes)
    }

    // MARK: - An unencodable response is answered, never silent

    func test_aResponseThatWillNotEncodeAnswersInternalErrorForTheSameId() async throws {
        let router = router()
        router.register(method: "broken") { _ in Data("not json".utf8) }
        let (data, object) = try await send(
            #"{"jsonrpc":"2.0","id":"b-1","method":"broken"}"#, to: router)
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(object["id"] as? String, "b-1")
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32603)
    }

    /// The worst image `ImageResponseBuilder` emits (a 720 KB JPEG, here
    /// random bytes so base64's `/` lands at its natural 1-in-64 and escapes
    /// to `\/`), with the fallback note, still fits the line ceiling.
    func test_theWorstCaseImageEnvelopeFitsTheLine() async throws {
        let router = router()
        var bytes = [UInt8](repeating: 0, count: 720_000)
        var rng = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        let envelope = try JSONEncoder().encode(AnyJSON.object(["content": .array([
            .object(["type": .string("text"),
                     "text": .string("Requested 4096px exceeded the 1 MB transport cap; returning at 1728px instead.")]),
            .object(["type": .string("image"),
                     "data": .string(Data(bytes).base64EncodedString()),
                     "mimeType": .string("image/jpeg")]),
        ])]))
        router.register(method: "image") { _ in envelope }
        let (data, object) = try await send(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"image"}}"#,
            to: router)
        XCTAssertLessThan(data.count, MCPResponseBudget.maxLineBytes)
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertNil(result["isError"])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.last?["type"] as? String, "image")
    }

    // MARK: - Census: encodeLine is the one line writer

    private static var mcpDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Maugham/MCP", isDirectory: true)
    }

    /// Code lines (comments dropped) that name `MCPResponse` (not the budget)
    /// outside the type's own file and the server, plus every `JSONEncoder`
    /// line of the server's that sits outside `encodeLine`'s body.
    static func lineWriterOffenders(files: [(name: String, text: String)]) -> [String] {
        var offenders: [String] = []
        for (name, text) in files {
            let lines = text.components(separatedBy: "\n")
            let code = lines.map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { return "" }
                return line.components(separatedBy: "//").first ?? line
            }
            if name != "MCPProtocol.swift" && name != "MCPServer.swift" {
                for (i, line) in code.enumerated()
                where line.replacingOccurrences(of: "MCPResponseBudget", with: "")
                    .contains("MCPResponse") {
                    offenders.append("\(name):\(i + 1)")
                }
            }
            guard name == "MCPServer.swift" else { continue }
            var inside = false, depth = 0
            for (i, line) in code.enumerated() {
                if !inside, line.contains("static func encodeLine(") { inside = true; depth = 0 }
                if inside {
                    depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
                    if depth <= 0 && line.contains("}") { inside = false }
                    continue
                }
                if line.contains("JSONEncoder") { offenders.append("\(name):\(i + 1)") }
            }
        }
        return offenders
    }

    func test_encodeLineIsTheOnlyPlaceAResponseLineIsSerialized() throws {
        let fm = FileManager.default
        let walker = try XCTUnwrap(fm.enumerator(at: Self.mcpDir, includingPropertiesForKeys: nil))
        var files: [(name: String, text: String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertTrue(files.contains { $0.name == "MCPServer.swift" }, "scope: the server was scanned")
        XCTAssertEqual(Self.lineWriterOffenders(files: files), [],
            "Serialize a JSON-RPC response only through MCPServer.encodeLine (tripwire 10)")
    }

    func test_theLineWriterCensusFiresOnPlantedOffenders() {
        let server = """
        final class MCPServer {
            static func dispatch() -> Data {
                // JSONEncoder() in a comment does not count
                return encodeLine(resp, method: nil)
            }
            static func shortcut() -> Data {
                return (try? JSONEncoder().encode(resp)) ?? Data()
            }
            nonisolated static func encodeLine(_ resp: MCPResponse, method: String?) -> Data {
                guard let line = try? JSONEncoder().encode(resp) else { return Data() }
                if line.count > 1 {
                    return (try? JSONEncoder().encode(resp)) ?? Data()
                }
                return line
            }
            static func after() -> Data { (try? JSONEncoder().encode(resp)) ?? Data() }
        }
        """
        let tool = """
        enum PlantedTool {
            // MCPResponse in a comment does not count
            static let budget = MCPResponseBudget.maxTextBytes
            static func reply() -> MCPResponse { .success(id: nil, resultJSON: Data()) }
        }
        """
        XCTAssertEqual(
            Self.lineWriterOffenders(files: [("MCPServer.swift", server), ("PlantedTool.swift", tool)]),
            ["MCPServer.swift:7", "MCPServer.swift:16", "PlantedTool.swift:4"])
    }
}
