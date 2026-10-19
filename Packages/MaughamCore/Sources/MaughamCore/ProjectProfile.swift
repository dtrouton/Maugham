import Foundation

/// What kind of writing a project is set up for, beyond its `ProjectType`
/// (report foundations, schema 10). Stored as a plain string on the manifest.
///
/// `.unknown` keeps the raw string and re-encodes it VERBATIM, so a profile a
/// later build added survives this build's save unchanged (the lossless
/// `Statement.Kind` shape, not the lossy `"unknown"` one).
public enum ProjectProfile: Codable, Equatable, Sendable {
    case report
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .report: return "report"
        case .unknown(let raw): return raw
        }
    }

    public init(rawValue: String) {
        self = rawValue == "report" ? .report : .unknown(rawValue)
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// The profile's default for each switch; nil where it has none.
    fileprivate var defaultSwitches: ProjectSwitches? {
        switch self {
        case .report:
            return ProjectSwitches(
                numberSections: true, listOfFigures: true, listOfTables: true, webAccess: true)
        case .unknown:
            return nil
        }
    }
}

/// The four switches a project may set. Each is optional: nil means "the
/// profile's default", which `ProjectManifest.effectiveSwitches` resolves.
public struct ProjectSwitches: Codable, Equatable, Sendable {
    public var numberSections: Bool?
    public var listOfFigures: Bool?
    public var listOfTables: Bool?
    public var webAccess: Bool?

    public init(
        numberSections: Bool? = nil,
        listOfFigures: Bool? = nil,
        listOfTables: Bool? = nil,
        webAccess: Bool? = nil
    ) {
        self.numberSections = numberSections
        self.listOfFigures = listOfFigures
        self.listOfTables = listOfTables
        self.webAccess = webAccess
    }
}

extension ProjectManifest {
    /// Each switch's stored value, else the profile's default, else false.
    /// Computed, never written back to `switches` (tripwire 11).
    public var effectiveSwitches: (numberSections: Bool, listOfFigures: Bool, listOfTables: Bool, webAccess: Bool) {
        let stored = switches
        let defaults = profile?.defaultSwitches
        return (
            numberSections: stored?.numberSections ?? defaults?.numberSections ?? false,
            listOfFigures: stored?.listOfFigures ?? defaults?.listOfFigures ?? false,
            listOfTables: stored?.listOfTables ?? defaults?.listOfTables ?? false,
            webAccess: stored?.webAccess ?? defaults?.webAccess ?? false)
    }

    /// The lowest schema this manifest's CONTENT needs: 10 when it carries a
    /// profile, switches, or any research item (groups' children included)
    /// with citation details; otherwise 0. `encodeForDisk` raises to it.
    public var contentSchemaFloor: Int {
        // 10 is the schema that INTRODUCED this content, fixed for ever; never
        // `currentSchemaVersion`, or every later bump would raise these books.
        if profile != nil || switches != nil { return 10 }
        return Self.anyCitation(in: research) ? 10 : 0
    }

    private static func anyCitation(in items: [ResearchItem]) -> Bool {
        items.contains { $0.citation != nil || anyCitation(in: $0.children ?? []) }
    }
}
