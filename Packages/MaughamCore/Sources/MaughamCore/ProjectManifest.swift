import Foundation

/// The root of a `project.maugham.json` manifest file.
///
/// Schema is versioned via `schemaVersion`. Phase 1a was at version 1; 1d
/// adds an optional `typography` override field while keeping schema 1
/// (older Maugham tolerates unknown fields rather than corrupting them).
/// The iPhone-companion milestone adds an optional `id` the same way —
/// additive optional field, schema stays 1, no migration. Decodes as nil
/// for pre-`id` manifests; `ProjectStore.load` backfills a minted ULID.
public struct ProjectManifest: Codable, Equatable, Sendable {
    /// The schema version this build writes and is the ceiling
    /// `decodeGuardingSchema` will accept.
    ///
    /// SCHEMA CONTRACT (ADR 0015, audit N4) — the destination for every tolerant
    /// `.unknown` enum's "adding a case ⇒ bump this" note (`OpKind`,
    /// `ProjectType`, `SynthesisSource`): **adding a case to any tolerant enum, or
    /// any other non-additive schema change, MUST bump this number.** Why it's
    /// load-bearing: each tolerant enum decodes an unrecognized raw value to
    /// `.unknown`, which re-encodes LOSSILY as the literal `"unknown"` (the
    /// String-raw encoder keeps no memory of the original). For append-only data
    /// (the op log) that's benign, but the manifest is rewritten on every
    /// structural edit — an old build that opened a newer manifest would
    /// permanently degrade the unknown value on its next save. `decodeGuardingSchema`
    /// is the actual protection: it REFUSES a file whose `schemaVersion` exceeds
    /// this, so the lossy `.unknown` path is only ever reached for a *same-version*
    /// file carrying an unexpected value — which only stays safe as long as every
    /// genuinely-new case is accompanied by a bump here.
    public static let currentSchemaVersion = 3

    /// The filename used by every Maugham project for its manifest.
    /// Both the Mac app and the iOS companion look for this name in a
    /// project folder. Centralised here so Mac + phone stay in sync if
    /// the name ever changes.
    public static let fileName = "project.maugham.json"

    /// Returns a `JSONDecoder` configured for manifest files.
    /// Both surfaces (Mac + phone) must use this to ensure identical
    /// date parsing; a divergence silently breaks Mac-written manifests
    /// on the phone.
    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Returns a `JSONEncoder` configured for manifest files.
    /// The output format (ISO8601 dates, pretty-printed, sorted keys) is
    /// the byte-identical shape the Mac has written since milestone-1a.
    /// Never change `outputFormatting` here without a migration strategy.
    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public var schemaVersion: Int

    /// Stable logical project identifier, minted once (ULID) and persisted.
    /// Survives folder rename/move within a projects root — unlike the path.
    /// The iPhone companion keys capture-target selection and recents on it.
    /// Optional on disk for backward compatibility; `ProjectStore.load`
    /// mints + persists one when absent. New in the iPhone-companion milestone.
    public var id: String?

    public var type: ProjectType
    public var title: String
    public var author: String
    public var created: Date
    public var modified: Date
    public var structure: [StructureItem]
    public var research: [ResearchItem]
    public var targets: ProjectTargets?

    /// Per-project typography override. When non-nil, takes precedence over
    /// the user-level UserPreferences.typography.
    public var typography: TypographySettings?

    /// Per-project toggle for the element-type gutter (3b). Nil = use default
    /// (show for screenplay projects). Set explicitly to false to hide.
    public var showElementGutter: Bool?

    /// Thrown by `decodeGuardingSchema` when a manifest's on-disk
    /// `schemaVersion` is GREATER than this build understands.
    ///
    /// This is the PRIMARY cross-version defence (ADR 0015). Refusing a
    /// genuinely-newer-schema project up front prevents the degrade-and-resave
    /// corruption: if an old build instead loaded a newer manifest via the
    /// per-enum safe-default decoders and then re-saved, it would overwrite the
    /// newer values it couldn't represent — silent forward-data-loss, worse
    /// than not opening. The per-enum tolerance is the *within-version* safety
    /// net (a same-schemaVersion file carrying an unexpected value degrades one
    /// item gracefully); the schemaVersion gate is what makes that safe.
    public struct SchemaTooNewError: Error, Equatable {
        public let found: Int
        public let supported: Int
        public init(found: Int, supported: Int) {
            self.found = found
            self.supported = supported
        }
    }

    /// Decode a manifest from raw bytes, REFUSING any whose `schemaVersion`
    /// exceeds this build's `currentSchemaVersion`. Mirrors the `UIState` /
    /// `SessionLog` schemaVersion guards (the in-codebase template). Both the
    /// Mac (`ProjectStore.load`) and the phone (`ProjectsBrowser`) decode
    /// manifests; routing both through this keeps the gate in one place.
    ///
    /// Throws `SchemaTooNewError` for a too-new schema, or rethrows the
    /// underlying decode error for malformed/incompatible bytes.
    public static func decodeGuardingSchema(_ data: Data) throws -> ProjectManifest {
        let manifest = try makeDecoder().decode(ProjectManifest.self, from: data)
        guard manifest.schemaVersion <= currentSchemaVersion else {
            throw SchemaTooNewError(
                found: manifest.schemaVersion,
                supported: currentSchemaVersion)
        }
        return manifest
    }

    public init(
        schemaVersion: Int = ProjectManifest.currentSchemaVersion,
        id: String? = nil,
        type: ProjectType,
        title: String,
        author: String,
        created: Date,
        modified: Date,
        structure: [StructureItem],
        research: [ResearchItem],
        targets: ProjectTargets? = nil,
        typography: TypographySettings? = nil,
        showElementGutter: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.type = type
        self.title = title
        self.author = author
        self.created = created
        self.modified = modified
        self.structure = structure
        self.research = research
        self.targets = targets
        self.typography = typography
        self.showElementGutter = showElementGutter
    }
}
