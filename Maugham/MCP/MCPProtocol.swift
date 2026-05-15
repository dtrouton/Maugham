import Foundation

/// JSON-RPC 2.0 request id: int or string, never both.
public enum MCPRequestId: Codable, Equatable, Hashable {
    case int(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.typeMismatch(
            MCPRequestId.self,
            DecodingError.Context(codingPath: decoder.codingPath,
                                  debugDescription: "id must be int or string"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }
}

/// Incoming JSON-RPC 2.0 request. params kept as raw JSON so tool handlers
/// decode their own typed shapes.
public struct MCPRequest: Codable, Equatable {
    public let jsonrpc: String
    public let id: MCPRequestId?
    public let method: String
    public let paramsJSON: Data?

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }

    public init(jsonrpc: String = "2.0", id: MCPRequestId?, method: String, paramsJSON: Data?) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.paramsJSON = paramsJSON
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try c.decode(String.self, forKey: .jsonrpc)
        self.id = try c.decodeIfPresent(MCPRequestId.self, forKey: .id)
        self.method = try c.decode(String.self, forKey: .method)
        if c.contains(.params) {
            let any = try c.decode(AnyJSON.self, forKey: .params)
            self.paramsJSON = try JSONEncoder().encode(any)
        } else {
            self.paramsJSON = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(method, forKey: .method)
        if let raw = paramsJSON {
            let any = try JSONDecoder().decode(AnyJSON.self, from: raw)
            try c.encode(any, forKey: .params)
        }
    }
}

/// Outgoing JSON-RPC 2.0 response. result kept as raw JSON so handlers
/// encode their own typed shapes.
public struct MCPResponse: Codable, Equatable {
    public let jsonrpc: String
    public let id: MCPRequestId?
    public let resultJSON: Data?
    public let error: ErrorObject?

    public struct ErrorObject: Codable, Equatable {
        public let code: Int
        public let message: String
    }

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }

    public static func success(id: MCPRequestId?, resultJSON: Data) -> MCPResponse {
        MCPResponse(jsonrpc: "2.0", id: id, resultJSON: resultJSON, error: nil)
    }

    public static func failure(id: MCPRequestId?, code: Int, message: String) -> MCPResponse {
        MCPResponse(
            jsonrpc: "2.0",
            id: id,
            resultJSON: nil,
            error: ErrorObject(code: code, message: message))
    }

    public init(jsonrpc: String, id: MCPRequestId?, resultJSON: Data?, error: ErrorObject?) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.resultJSON = resultJSON
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try c.decode(String.self, forKey: .jsonrpc)
        self.id = try c.decodeIfPresent(MCPRequestId.self, forKey: .id)
        if c.contains(.result) {
            let any = try c.decode(AnyJSON.self, forKey: .result)
            self.resultJSON = try JSONEncoder().encode(any)
        } else {
            self.resultJSON = nil
        }
        self.error = try c.decodeIfPresent(ErrorObject.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encodeIfPresent(id, forKey: .id)
        if let r = resultJSON {
            let any = try JSONDecoder().decode(AnyJSON.self, from: r)
            try c.encode(any, forKey: .result)
        }
        try c.encodeIfPresent(error, forKey: .error)
    }
}

/// Type-erased JSON for `params` and `result` round-tripping.
public enum AnyJSON: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyJSON])
    case object([String: AnyJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([AnyJSON].self) { self = .array(a); return }
        if let o = try? c.decode([String: AnyJSON].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
