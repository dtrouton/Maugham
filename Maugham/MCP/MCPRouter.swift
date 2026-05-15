import Foundation

public enum MCPRouterError: Error, Equatable {
    case methodNotFound(String)
}

/// Pure dispatch: method name → registered handler. Each handler takes the
/// raw params JSON (or nil) and returns the raw result JSON. Tools register
/// themselves with the router during MCPServer initialization.
@MainActor
public final class MCPRouter {
    public typealias Handler = (Data?) async throws -> Data

    private var handlers: [String: Handler] = [:]

    public init() {}

    public func register(method: String, handler: @escaping Handler) {
        handlers[method] = handler
    }

    public func dispatch(method: String, paramsJSON: Data?) async throws -> Data {
        guard let handler = handlers[method] else {
            throw MCPRouterError.methodNotFound(method)
        }
        return try await handler(paramsJSON)
    }
}
