import Foundation
import MaughamCore

/// A research item's citation details on the wire, shared by
/// `update_research_citation` (in and out) and `list_research` (out).
/// Snake-case keys; `accessed` is an ISO calendar day (`YYYY-MM-DD`), read and
/// written as UTC midnight, the day `CitationStyle` prints. Every field is
/// emitted, `null` where unset (a fact, not an omission).
public struct ResearchCitationWire: Codable, Equatable {
    public var key: String?
    public var authors: [String]?
    public var source_title: String?
    public var publisher: String?
    public var year: Int?
    public var accessed: String?
    public var pages: String?

    init(_ info: CitationInfo) {
        key = info.key
        authors = info.authors
        source_title = info.sourceTitle
        publisher = info.publisher
        year = info.year
        accessed = info.accessed.map(Self.formatDay)
        pages = info.pages
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(authors ?? [], forKey: .authors)
        try c.encode(source_title, forKey: .source_title)
        try c.encode(publisher, forKey: .publisher)
        try c.encode(year, forKey: .year)
        try c.encode(accessed, forKey: .accessed)
        try c.encode(pages, forKey: .pages)
    }

    /// The store's value. A missing key reaches the door as blank, so the
    /// door's own rule answers (`needsAKey`, or removal when nothing is set).
    func citationInfo() throws -> CitationInfo {
        var day: Date?
        if let accessed, !accessed.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let parsed = Self.parseDay(accessed) else {
                throw MCPError.invalidArgument(
                    "accessed must be an ISO date, YYYY-MM-DD (got \"\(accessed)\")")
            }
            day = parsed
        }
        return CitationInfo(
            key: key ?? "", authors: authors ?? [], sourceTitle: source_title,
            publisher: publisher, year: year, accessed: day, pages: pages)
    }

    private static func dayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }

    /// `YYYY-MM-DD` → that day's UTC midnight; nil for anything else,
    /// an impossible day included.
    static func parseDay(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let date = dayFormatter().date(from: t),
              formatDay(date) == t else { return nil }
        return date
    }

    static func formatDay(_ date: Date) -> String {
        dayFormatter().string(from: date)
    }
}

/// `update_research_citation(project_id, research_id, citation)` — set or
/// remove a research item's citation details (the `[@key]` a manuscript cites
/// it by). It writes the research manifest only, never manuscript text,
/// through `ProjectStore.updateCitation`, the research inspector's own door:
/// a refusal (a bad key, a key another source or one in the Trash holds,
/// details with no key) is an invalid argument in the writer's words.
public enum UpdateResearchCitationTool: MCPTool {
    public static let method = "update_research_citation"
    public static let description =
        "Set or remove a research item's citation details, which manuscripts cite " +
        "as [@key]. citation replaces the whole set: {key, authors, source_title, " +
        "publisher, year, accessed (YYYY-MM-DD), pages}; null (or every field blank) " +
        "removes it. key is required whenever any other field is set, uses letters, " +
        "digits, - and _, and must be unique across the project's research, Trash " +
        "included. Write each author \"Given Surname\" or \"Surname, Given\". " +
        "list_research shows the current citations."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"research_id":{"type":"string"},"citation":{"type":["object","null"],"properties":{"key":{"type":"string"},"authors":{"type":"array","items":{"type":"string"}},"source_title":{"type":"string"},"publisher":{"type":"string"},"year":{"type":"integer"},"accessed":{"type":"string","description":"ISO date, YYYY-MM-DD"},"pages":{"type":"string"}}}},"required":["project_id","research_id","citation"]}"#

    struct Params: Decodable {
        let project_id: String
        let research_id: String
        /// Present-and-null removes; absent is a malformed call, never a removal.
        let hasCitation: Bool
        let citation: ResearchCitationWire?

        enum CodingKeys: String, CodingKey { case project_id, research_id, citation }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            project_id = try c.decode(String.self, forKey: .project_id)
            research_id = try c.decode(String.self, forKey: .research_id)
            hasCitation = c.contains(.citation)
            citation = try c.decodeIfPresent(ResearchCitationWire.self, forKey: .citation)
        }
    }

    public struct Result: Encodable {
        public let research_id: String
        public let citation: ResearchCitationWire?

        enum CodingKeys: String, CodingKey { case research_id, citation }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(research_id, forKey: .research_id)
            try c.encode(citation, forKey: .citation)
        }
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let store = try resolveProject(params.project_id, in: registry).store
        guard params.hasCitation else {
            throw MCPError.invalidArgument(
                "citation is required: an object to set the details, or null to remove them")
        }
        guard TreeWalk.find(id: params.research_id, in: store.manifest.research) != nil else {
            throw MCPError.invalidArgument("Unknown research_id: \(params.research_id)")
        }
        let info = try params.citation?.citationInfo()
        do {
            try await store.updateCitation(researchId: params.research_id, info)
        } catch let refusal as CitationEditError {
            throw MCPError.invalidArgument(refusal.localizedDescription)
        } catch ProjectStoreError.structureMissing {
            throw MCPError.invalidArgument("Unknown research_id: \(params.research_id)")
        }
        let stored = TreeWalk.find(id: params.research_id, in: store.manifest.research)?.citation
        return try JSONEncoder().encode(
            Result(research_id: params.research_id, citation: stored.map(ResearchCitationWire.init)))
    }
}
