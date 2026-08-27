import Foundation

/// A generic JSON value used where a typed struct cannot represent the
/// data — specifically the merge-patch fragments on `PublishConfig.Imprint`
/// (`metadata`, `outputs`, `cover`), which need `null` to mean *delete*
/// per RFC 7396. A typed struct's `Optional` can't hold that distinction
/// (absent vs. explicitly null); this enum can.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:
            try c.encodeNil()
        case .bool(let v):
            try c.encode(v)
        case .number(let v):
            try c.encode(v)
        case .string(let v):
            try c.encode(v)
        case .array(let v):
            try c.encode(v)
        case .object(let v):
            try c.encode(v)
        }
    }
}
