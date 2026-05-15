import XCTest
@testable import Maugham

@MainActor
final class MCPRouterTests: XCTestCase {
    func test_unknownMethod_throwsMethodNotFound() async {
        let router = MCPRouter()
        do {
            _ = try await router.dispatch(method: "nope", paramsJSON: nil)
            XCTFail("expected throw")
        } catch let MCPRouterError.methodNotFound(method) {
            XCTAssertEqual(method, "nope")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_registeredMethod_dispatchesAndReturnsResult() async throws {
        let router = MCPRouter()
        router.register(method: "echo") { params in
            return params ?? Data("null".utf8)
        }
        let result = try await router.dispatch(method: "echo",
                                               paramsJSON: Data("\"hi\"".utf8))
        XCTAssertEqual(String(data: result, encoding: .utf8), "\"hi\"")
    }
}
