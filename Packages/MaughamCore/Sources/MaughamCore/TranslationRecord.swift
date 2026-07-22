import Foundation

/// One translated paragraph for one language. Append-only wire type; newest
/// opId per (paragraphId, language) wins. `text == nil` is a tombstone.
public struct TranslationRecord: Codable, Equatable, Sendable {
    public let opId: String
    public let paragraphId: String
    public let language: String
    public let text: String?
    public let sourceHash: String
    public let verbatim: Bool
    public let at: Date

    public init(opId: String = ULID.generate(), paragraphId: String, language: String,
                text: String?, sourceHash: String, verbatim: Bool = false, at: Date = Date()) {
        self.opId = opId; self.paragraphId = paragraphId; self.language = language
        self.text = text; self.sourceHash = sourceHash; self.verbatim = verbatim; self.at = at
    }

    enum CodingKeys: String, CodingKey {
        case opId = "op_id", paragraphId = "paragraph_id", language, text
        case sourceHash = "source_hash", verbatim, at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        opId = try c.decode(String.self, forKey: .opId)
        paragraphId = try c.decode(String.self, forKey: .paragraphId)
        language = try c.decode(String.self, forKey: .language)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        sourceHash = try c.decode(String.self, forKey: .sourceHash)
        verbatim = try c.decodeIfPresent(Bool.self, forKey: .verbatim) ?? false
        at = try c.decode(Date.self, forKey: .at)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(opId, forKey: .opId)
        try c.encode(paragraphId, forKey: .paragraphId)
        try c.encode(language, forKey: .language)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encode(sourceHash, forKey: .sourceHash)
        try c.encode(verbatim, forKey: .verbatim)
        try c.encode(at, forKey: .at)
    }

    /// Lowercase BCP-47-ish: primary subtag 2-3 letters, optional subtags.
    public static func isValidLanguageTag(_ s: String) -> Bool {
        s.range(of: "^[a-z]{2,3}(-[a-z0-9]{2,8})*$", options: .regularExpression) != nil
    }

}
