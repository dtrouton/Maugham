import Foundation

/// The writer's stated intent, the book's visual language, an edition's brief,
/// the lessons ledger, the first reader: one artifact, several kinds, scoped to
/// the project or to a single manuscript document. Count `Kind`'s cases, never a
/// number here.
///
/// A statement's content lives in the open at the project root — `intent.md`,
/// `intent/<slug>.md`, `visual-language.md`, `lessons.md`, `first-reader.md` —
/// carried as an ordinary `Document` so history, undo and cross-device merge
/// arrive built rather than invented.
/// This type is only the manifest's registry entry: identity, what it is, what
/// it is about, and where it currently sits.
///
/// `kind` and `scope` are separate fields rather than one fused enum on purpose.
/// They are not independent in practice (visual language is project-scope only),
/// but they describe *different objects that happen to look alike*; a fused
/// `projectIntent | documentIntent | visualLanguage` would have to be reopened
/// the moment a second project-scope kind arrives.
public struct Statement: Codable, Equatable, Identifiable, Sendable {

    /// What this statement *is*.
    ///
    /// ADR-0015 safe round-trip: `kind` is **identity-bearing**, so — unlike the
    /// tolerant `ItemType`/`AssetKind` decoders that degrade to a benign default
    /// — an unrecognised (future) value is preserved verbatim in `.unknown(raw)`
    /// and re-encoded as that same raw string. See `ResearchRole` for the full
    /// reasoning; the short version is that a statement is the writer's prose,
    /// and an old build that degraded a newer kind and then re-saved the
    /// manifest would permanently relabel prose it could not read. Nothing looks
    /// up `.unknown`, so such a statement is retained and ignored — never
    /// dropped, never renamed.
    ///
    /// Not a `String`-raw enum: the associated value can't ride on `rawValue`,
    /// so the conformance is hand-written.
    public enum Kind: Codable, Equatable, Sendable {
        case intent
        case visualLanguage
        case editionBrief(String)   // language tag, e.g. "es"
        /// What the writer has learned about their own writing: a project-scope
        /// ledger whose entries are ordinary rulings under `## Rulings`, read
        /// through `LessonsLedger`'s grammar.
        case lessons
        /// **Who reads this project's checks as a reader** — the writer's own
        /// first reader, named on the manifest (`ProjectManifest.firstReaderName`)
        /// and described here: what she knows about the book, what she has
        /// already read, and the standing instructions she is to read under.
        /// Project scope only, for the lessons ledger's reason — a first reader
        /// is a person the whole book is read by, not a fact a chapter holds a
        /// private copy of.
        case firstReader
        /// A kind written by a newer build. Carries the original raw string so
        /// re-encode is lossless (see type doc).
        case unknown(String)

        private static let intentRaw = "intent"
        private static let visualLanguageRaw = "visual_language"
        private static let editionBriefPrefix = "edition_brief:"
        private static let lessonsRaw = "lessons"
        private static let firstReaderRaw = "first-reader"

        /// The stable on-disk string. Known cases emit their canonical value;
        /// an `.unknown` emits the preserved original raw.
        public var rawValue: String {
            switch self {
            case .intent: return Self.intentRaw
            case .visualLanguage: return Self.visualLanguageRaw
            case .editionBrief(let lang): return Self.editionBriefPrefix + lang
            case .lessons: return Self.lessonsRaw
            case .firstReader: return Self.firstReaderRaw
            case .unknown(let raw): return raw
            }
        }

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case Self.intentRaw: self = .intent
            case Self.visualLanguageRaw: self = .visualLanguage
            case Self.lessonsRaw: self = .lessons
            case Self.firstReaderRaw: self = .firstReader
            default:
                if raw.hasPrefix(Self.editionBriefPrefix) {
                    let lang = String(raw.dropFirst(Self.editionBriefPrefix.count))
                    self = lang.isEmpty ? .unknown(raw) : .editionBrief(lang)
                } else {
                    self = .unknown(raw)
                }
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// What this statement is *about* — the whole project, or one manuscript
    /// document.
    ///
    /// **On-disk shape: a single JSON string.** `"project"` for the project
    /// scope; `"document:<documentId>"` for a document scope. The split is on
    /// the FIRST colon, so a document id containing one survives whole; the id
    /// is otherwise opaque here. Any other string — including `"document:"`
    /// with no id, which would otherwise mint a scope that matches nothing
    /// while looking valid — decodes to `.unknown(raw)` and re-encodes as that
    /// same raw string.
    ///
    /// A string rather than an object because that is what makes the
    /// forward-tolerance above trivially lossless (the `ResearchRole` shape):
    /// there is exactly one thing to preserve, and it is preserved verbatim.
    /// Same identity-bearing reasoning as `Kind` — flattening an unrecognised
    /// scope to `.project` would silently re-point one document's intent at the
    /// whole book.
    public enum Scope: Codable, Equatable, Sendable {
        case project
        case document(String)
        /// A scope written by a newer build. Carries the original raw string so
        /// re-encode is lossless (see type doc).
        case unknown(String)

        private static let projectRaw = "project"
        private static let documentPrefix = "document:"

        /// The stable on-disk string (see type doc for the grammar).
        public var rawValue: String {
            switch self {
            case .project: return Self.projectRaw
            case .document(let id): return Self.documentPrefix + id
            case .unknown(let raw): return raw
            }
        }

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            if raw == Self.projectRaw {
                self = .project
            } else if raw.hasPrefix(Self.documentPrefix) {
                let id = String(raw.dropFirst(Self.documentPrefix.count))
                self = id.isEmpty ? .unknown(raw) : .document(id)
            } else {
                self = .unknown(raw)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Stable identity, minted once and never derived from the path — a
    /// statement's file is free to drift from its title after a rename.
    public var id: String
    public var kind: Kind
    public var scope: Scope
    /// Project-relative path to the statement's content. May change; identity
    /// is `id`. Moves go through the typed `DocumentStore` mover (tripwire 14).
    public var path: String

    public init(id: String, kind: Kind, scope: Scope, path: String) {
        self.id = id
        self.kind = kind
        self.scope = scope
        self.path = path
    }
}
