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
    ///
    /// 3 → 4 (M1A, the spine): the `statements` section. See its doc comment for
    /// why an additive, absent-tolerant section still needs the bump.
    ///
    /// 4 → 5 (RULING-33, the reject/accept convergence): `.claudeReject` became
    /// a manuscript-affecting kind (`Deriver.appliesToManuscript`) so the
    /// repair reject can carry the inverse of the accept it beat, and
    /// `SynthesisSource` gained `.rejectConvergence` to stamp it. The bump is
    /// load-bearing for the FIRST of those, not the second: an older build
    /// reads the repair op's kind fine and folds none of its changes, so it
    /// would show the suggestion's text under a `rejected` status — the exact
    /// disagreement the repair exists to end. Refusing the project outright is
    /// the honest answer.
    ///
    /// 5 → 6 (M3 P1, review passes): the `reviewPasses` section on the
    /// manifest, plus `passStates` on each `StructureItem` (Task 2). Both are
    /// additive and absent-tolerant — a schema-5 manifest with neither key
    /// opens fine — but the bump is load-bearing for the same reason 3 → 4
    /// was: an older build that opened a newer manifest and re-saved it would
    /// silently DROP a writer's per-piece pass state across an entire
    /// collection, with nothing on disk to say it ever existed. Honest
    /// refusal beats silent loss; this makes M3 a paired Mac + phone release
    /// (shipped phone builds refuse a v6 manifest via `decodeGuardingSchema`
    /// until updated — the M1A pattern).
    /// 6 → 7 (M3 P2, the queue): two new `OpKind` cases — `annotationStet` and
    /// `annotationTriage` — under `OpKind`'s own SCHEMA CONTRACT note ("adding
    /// a case ⇒ bump `ProjectManifest.currentSchemaVersion`"), plus the two
    /// additive `Op.Provenance` fields they ride on (`triage_mark`,
    /// `review_pass_id`). The op log is append-only, so the lossy `.unknown`
    /// re-encode is not the danger here; the danger is an older build deriving
    /// a project whose notes it silently mis-states — a stetted note reads as
    /// still OPEN there, so the writer is shown a queue they already cleared
    /// and can resolve the same note twice. Refusing the project outright is
    /// the honest answer, and it makes M3 a paired Mac + phone release.
    ///
    /// 7 → 8 (the publish department, P1): **two causes, either of which would
    /// have earned the bump on its own.**
    ///
    /// First, the `productionRoles` section on the manifest — the project's
    /// named translators and its designer. Additive and absent-tolerant, so a
    /// schema-7 manifest with no such key opens fine; the bump is load-bearing
    /// for the reason 3 → 4 and 5 → 6 were. An older build would read the
    /// project happily and then re-save the manifest **without the section**,
    /// silently discarding every translator the writer named and every brief
    /// they wrote — and worse than losing the names, the identities those names
    /// stand for: annotations already signed by a translator would be left
    /// pointing at a person the manifest no longer knows. Nothing in the
    /// additive shape protects against that; `decodeGuardingSchema` does, by
    /// refusing the file outright.
    ///
    /// Second, `Statement.Kind.editionBrief(String)` — the third statement kind
    /// (raw `edition_brief:<lang>`), under ADR 0015's unconditional "adding a
    /// case to any tolerant enum ⇒ bump this number". `Kind`'s `.unknown` is
    /// lossless, so the re-encode degradation that makes most such bumps urgent
    /// does not apply here: an old build preserves the raw string verbatim. The
    /// bump is still right, and the contract is deliberately not case-by-case.
    /// What an old build cannot do is *route* the kind — the Spanish edition's
    /// register, idiom policy and typographic conventions become a statement it
    /// retains and ignores, so a translation run made there is briefed on
    /// doctrine the writer wrote and this build cannot see. Refusing the project
    /// is the honest answer; presenting a book whose edition has rules nobody is
    /// reading is not.
    ///
    /// As with M1A and M3, this makes the milestone a **paired Mac + phone
    /// release**: shipped phone builds refuse a v8 manifest via
    /// `decodeGuardingSchema` until they are updated together.
    ///
    /// 8 → 9 (signed op log P3b, the permit's schema gate): **two causes, and
    /// the second is the one that matters.**
    ///
    /// First, the letter of the contract — `SynthesisSource` gained two cases
    /// (`pendingRecovery`, `anchorSplice`) so the load path's own `typingBurst`
    /// emissions say what they are. On its own that is the mildest kind of bump:
    /// the op log is append-only, so the lossy `.unknown` re-encode never
    /// happens, and an older build reading one of those ops simply shows a
    /// generic label in History.
    ///
    /// Second, and load-bearing: **this is the number the first NARROWING event
    /// writes.** Once a book's register says somebody is a reviewer, or an
    /// author of some pieces, every reader has to judge lines against that
    /// permit — and a v0.40 Mac cannot. It has no permit layer at all: it
    /// applies the reviewer's refused text, folds it into the manuscript, and
    /// re-asserts those words in its own file under its own book-author key,
    /// where every signed Mac then has to accept them. The demotion the writer
    /// made is undone by the oldest machine in the house, silently.
    /// `decodeGuardingSchema` is the only thing that can stop it, and it stops
    /// it by REFUSING the project — which is why the gate raises this number
    /// on disk before the narrowing event is written, and never after.
    ///
    /// **Only a narrowing raises an EXISTING book's number.** A manifest's
    /// `schemaVersion` is DECODED and carried through every ordinary save
    /// (`init(from:)` above), so a book nobody has narrowed keeps the number it
    /// has and goes on opening on every build that ever opened it. Nothing
    /// about a one-writer book moves.
    ///
    /// **A book MADE on this build starts at 9**, because the init default
    /// above stamps this constant on a manifest that is being constructed
    /// rather than read (`ProjectFactory`, a Collection piece promoted to its
    /// own project). That is not the gate — it is what every schema bump has
    /// always done — but it is worth saying plainly: a project created here
    /// will not open on v0.40, narrowed or not, and the release notes should
    /// say so.
    ///
    /// **And once raised it is never lowered.** `ProjectManifest.raising` is
    /// the rule and both manifest write doors obey it, because the file is one
    /// object rewritten whole from a copy each store read at open: without it,
    /// the first chapter rename on any OTHER Mac that had the book open would
    /// write the gate away. See that function for the whole of it.
    ///
    /// As with M1A, M3 and the publish department, this makes the milestone a
    /// **paired Mac + phone release**.
    public static let currentSchemaVersion = 9

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

    /// The registry of `Statement`s — the writer's intent and the book's visual
    /// language — alongside `structure` and `research`. New in M1A (schema 4).
    ///
    /// Non-optional, defaulting to `[]` in both the memberwise init and
    /// `init(from:)`, so a schema-3 manifest (which has no such key) still
    /// opens.
    ///
    /// **Why the bump is not ceremony**, since the next person will ask: this
    /// section is purely additive and decodes as absent-tolerant, so an older
    /// build would read the project *happily* — and then re-save the manifest
    /// **without the section**, destroying the registry that points at the
    /// writer's intent files while leaving the files themselves orphaned on
    /// disk. Nothing in the additive shape protects against that;
    /// `decodeGuardingSchema` does, by refusing the file outright. That is also
    /// what makes M1A a paired Mac + phone release.
    public var statements: [Statement]

    /// The project's named editing passes (M3 P1, schema 6) — the Review
    /// board's column headers. Non-optional, defaulting to `[]` in both the
    /// memberwise init and `init(from:)`, so a schema-5 manifest (which has
    /// no such key) still opens — the `statements` shape (`:206`).
    ///
    /// An empty or absent stored list is not itself the presets: read
    /// `effectiveReviewPasses`, never this property, when what's wanted is
    /// "what passes does this project have" — the presets are computed, not
    /// written back (tripwire 11). This property exists so a customized list
    /// round-trips, and so "no customization yet" is representable without a
    /// migration that would have to write the presets into every existing
    /// project's manifest.
    public var reviewPasses: [ReviewPass]

    /// The pass list a reader should actually use: the stored `reviewPasses`
    /// when the writer has customized it, else `ReviewPass.presets`. Never
    /// writes the presets back to `reviewPasses` — an absent or emptied list
    /// stays absent/empty on disk until the writer actually customizes it
    /// (tripwire 11, and Task 9's delete-all-restores-presets rule).
    public var effectiveReviewPasses: [ReviewPass] {
        reviewPasses.isEmpty ? ReviewPass.presets : reviewPasses
    }

    /// Whether the writer has **vacated the coach's seat** (editorial letter
    /// P1, spec §4.1). Tolerated-missing and `false` by default in both the
    /// memberwise init and `init(from:)`, so every manifest written before
    /// this milestone opens with the seat held — no schema bump, no
    /// migration (tripwire 11). Unlike `reviewPasses` it is always encoded:
    /// the field is not optional, and an absent key means "held" only for
    /// files older than the feature.
    ///
    /// Read `effectiveCoach`, never this flag, when what's wanted is "who
    /// coaches this project".
    public var coachVacated: Bool

    /// **The project's first reader, by name** — the person Author's checks are
    /// read by, chosen and named by the writer (two loops P2). `nil` is the
    /// state every project starts in and stays in until the writer names one:
    /// there is no default first reader, because a reader the writer did not
    /// choose is a stranger with opinions.
    ///
    /// Tolerated-missing and optional, so no schema bump and no migration
    /// (tripwire 11) — a manifest written before this milestone decodes to a
    /// project with no first reader, which is exactly what it is. Who she is
    /// beyond her name lives in her own statement (`Statement.Kind.firstReader`,
    /// `first-reader.md`); only the name is manifest metadata, because the name
    /// is what every surface that mentions her has to render.
    ///
    /// Always trimmed and never empty: `ProjectStore.setFirstReaderName` maps a
    /// blank to `nil`, so `""` and "no first reader" cannot both be reachable
    /// states meaning the same thing.
    public var firstReaderName: String?

    /// The coach a reader should actually use: `ReviewPass.coachPreset`
    /// while the seat is held, nil once it has been vacated.
    ///
    /// The coach is deliberately absent from `effectiveReviewPasses` — she
    /// is not a stage — so nothing that walks the ladder needs to learn
    /// about her. An unassigned piece is hers; with the seat vacant it goes
    /// back to the all-altitudes reader signed "Claude".
    public var effectiveCoach: ReviewPass? {
        coachVacated ? nil : ReviewPass.coachPreset
    }

    /// The project's publish department (schema 8) — its named translators and
    /// its designer. Non-optional, defaulting to `[]` in both the memberwise
    /// init and `init(from:)`, so a schema-7 manifest (which has no such key)
    /// still opens — the `reviewPasses` shape (`:138`).
    ///
    /// An empty or absent stored list is not "no designer": read
    /// `effectiveProductionRoles`, never this property, when what's wanted is
    /// "who works on this book". This property exists so a minted translator and
    /// a renamed designer round-trip, and so "nothing customized yet" is
    /// representable without a migration (tripwire 11).
    public var productionRoles: [ProductionRole]

    /// The department a reader should actually use: the stored roles, with
    /// `ProductionRole.presetDesigner` prepended when none of them is a
    /// designer. Never writes the preset back to `productionRoles`.
    ///
    /// **This is where it differs from `effectiveReviewPasses` above** — that
    /// one *replaces* an empty list with the presets, which is right when the
    /// presets are the whole set. Here they are not: a translator is minted into
    /// the stored list the first time a language edition exists, and the
    /// designer must survive beside it. So the preset **merges** rather than
    /// replaces. Copying the `isEmpty ? presets : stored` shape here would make
    /// the designer vanish the moment the first translator was minted.
    public var effectiveProductionRoles: [ProductionRole] {
        let hasDesigner = productionRoles.contains { role in
            if case .designer = role.role { return true }
            return false
        }
        return hasDesigner ? productionRoles : [ProductionRole.presetDesigner] + productionRoles
    }

    /// The STORED translator for a language tag, or nil — **the one spelling of
    /// the tag match**, shared by everything that asks the question:
    /// `ProjectStore.translatorRole(for:)`'s find-half, the read-only
    /// `translatorName(for:in:)`, and the translator loop's briefing.
    ///
    /// Asked of the stored list rather than `effectiveProductionRoles` on
    /// purpose: the merge only ever supplies a designer, and this is the list a
    /// mint appends to.
    ///
    /// Matching is **case-insensitive on the tag** — the tag arrives from
    /// whatever named the edition, and `ES` and `es` are one person's language
    /// — and otherwise exact: `es-MX` is a language of its own, exactly as it
    /// is in `ProductionRole.defaultTranslatorName`'s table.
    public func storedTranslator(for language: String) -> ProductionRole? {
        storedLanguageRole(for: language) { if case .translator(let t) = $0 { return t }; return nil }
    }

    /// The STORED reader for a language tag — `storedTranslator`'s rule, for
    /// the blind reader (translation pipeline P1).
    public func storedReader(for language: String) -> ProductionRole? {
        storedLanguageRole(for: language) { if case .reader(let t) = $0 { return t }; return nil }
    }

    /// The STORED collator for a language tag — `storedTranslator`'s rule.
    public func storedCollator(for language: String) -> ProductionRole? {
        storedLanguageRole(for: language) { if case .collator(let t) = $0 { return t }; return nil }
    }

    /// The one spelling of the case-insensitive tag match, for every role that
    /// carries a language.
    private func storedLanguageRole(
        for language: String, tag: (ProductionRole.Role) -> String?
    ) -> ProductionRole? {
        productionRoles.first { role in
            guard let stored = tag(role.role) else { return false }
            return stored.caseInsensitiveCompare(language) == .orderedSame
        }
    }

    public var targets: ProjectTargets?

    /// Per-project typography override. When non-nil, takes precedence over
    /// the user-level UserPreferences.typography.
    public var typography: TypographySettings?

    /// Per-project toggle for the element-type gutter (3b). Nil = use default
    /// (show for screenplay projects). Set explicitly to false to hide.
    public var showElementGutter: Bool?

    // MARK: - The write rule: raise-only on `schemaVersion`

    /// Just the one field, decoded out of a manifest's bytes — nil if they are
    /// not a JSON object with a numeric `schemaVersion`.
    ///
    /// Deliberately a MINIMAL decode rather than the whole manifest (signed op
    /// log P3b fix round 1). What it is for is the question *has somebody
    /// raised this book's gate* asked of a file this build may not be able to
    /// decode in full — a newer build's manifest, or one a half-finished write
    /// left with a field missing. The number is the only thing that question
    /// turns on, and refusing to read it because the rest of the file is odd
    /// would be answering *nobody has* when the honest answer is *I could not
    /// tell*.
    public static func schemaVersion(of data: Data) -> Int? {
        struct Probe: Decodable { let schemaVersion: Int }
        return (try? JSONDecoder().decode(Probe.self, from: data))?.schemaVersion
    }

    /// The same question asked of a file. Nil for a file that is not there, or
    /// will not read, or holds no number.
    public static func schemaVersion(ofFileAt url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url) else { return nil }  // adr-0018-ok: project manifest JSON read, not manuscript
        return schemaVersion(of: data)
    }

    /// **The manifest's write rule: a save RAISES `schemaVersion` to what is
    /// already on disk, and never lowers it** (signed op log P3b fix round 1,
    /// Critical 1).
    ///
    /// ## What it is defending
    ///
    /// The manifest is one JSON object, rewritten whole on every structural
    /// edit from a copy a store read once at open. So the moment one Mac
    /// narrows a book — which raises the number to shut permit-less builds out
    /// — every OTHER Mac with the book open is holding the old number, and the
    /// next chapter rename any of them makes writes it back. The gate is gone,
    /// from a machine that narrowed nobody and noticed nothing. iCloud's
    /// conflict pick can land the same 8 with no Mac involved at all.
    ///
    /// The fix is not in the callers — a caller that knew would not be the
    /// problem. It is here, at the door, so a store that does not know is not
    /// ABLE to lower it.
    ///
    /// ## What it does, and what it deliberately does not
    ///
    /// It raises and it never stamps. Where `floor` is nil (no file yet, or one
    /// whose number cannot be read) or not greater than the outgoing manifest's
    /// own, **the bytes are returned UNCHANGED — the same `Data`, not an
    /// equal one** — so every un-narrowed book's save is byte-for-byte what it
    /// has always been. Only when the file on disk genuinely carries a HIGHER
    /// number is the outgoing manifest re-encoded with it.
    ///
    /// **It never refuses a save.** Outgoing bytes this build cannot decode
    /// are returned as they are: the words are safe outranks the gate, and a
    /// save that threw because a version number would not parse would cost the
    /// writer an edit to protect a number.
    ///
    /// **It carries the rest of the outgoing manifest verbatim** — only the
    /// number moves. It is not a merge: the other Mac's structural edit is the
    /// writer's own act and lands exactly as they made it.
    ///
    /// ## And it stops at THIS build's own number (fix round 2)
    ///
    /// The floor is clamped to `currentSchemaVersion`, here rather than at the
    /// two call sites, so every future one inherits it.
    ///
    /// Without the clamp the rule reached a state worse than the one it was
    /// written to fix. A manifest from a LATER build can land on disk
    /// mid-session — `DocumentStore.handleManifestChanged` decodes an incoming
    /// manifest without `decodeGuardingSchema`, so nothing on that path refuses
    /// one — and the next ordinary save would then take that foreign number as
    /// its floor and stamp **this build's own content with it**. Two failures in
    /// one write: content labelled with a schema nobody here knows, and a file
    /// this build refuses on its next launch (`SchemaTooNewError`) — a
    /// self-lockout that neither v0.40 nor round 1's predecessor had.
    ///
    /// A build may raise a book as far as it can itself read and no further.
    /// Above that it writes exactly what it wrote before any of this existed:
    /// its own number.
    ///
    /// **The mid-session too-new manifest is a PRE-EXISTING gap** (the
    /// degrade-and-resave `decodeGuardingSchema` guards at OPEN and nothing
    /// guards during a session). This clamp neither widens nor closes it — it
    /// keeps this rule from making it worse. Closing it means a store that
    /// stops writing when a too-new manifest arrives, which is a roadmap item.
    public static func raising(_ outgoing: Data, toAtLeast floor: Int?) -> Data {
        guard let floor,
              let mine = schemaVersion(of: outgoing),
              case let ceiling = min(floor, currentSchemaVersion),
              mine < ceiling,
              var manifest = try? makeDecoder().decode(ProjectManifest.self, from: outgoing)
        else { return outgoing }
        manifest.schemaVersion = ceiling
        return (try? makeEncoder().encode(manifest)) ?? outgoing
    }

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
        statements: [Statement] = [],
        reviewPasses: [ReviewPass] = [],
        coachVacated: Bool = false,
        firstReaderName: String? = nil,
        productionRoles: [ProductionRole] = [],
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
        self.statements = statements
        self.reviewPasses = reviewPasses
        self.coachVacated = coachVacated
        self.firstReaderName = firstReaderName
        self.productionRoles = productionRoles
        self.targets = targets
        self.typography = typography
        self.showElementGutter = showElementGutter
    }

    /// Hand-written because `statements` is non-optional and absent from every
    /// schema-3 manifest: the synthesized decoder would throw `keyNotFound` and
    /// make every pre-M1A project unopenable. This is ADR 0015's
    /// `decodeIfPresent`-with-a-default shape (`TypographySettings.init(from:)`
    /// is the in-codebase template), applied to the one field that needs it —
    /// every other field keeps exactly the strictness it had.
    ///
    /// `CodingKeys` is still synthesized (from `encode(to:)`), deliberately: an
    /// explicit list would let a future property be silently omitted from the
    /// *encode* side. The trade is that a future property with a default value
    /// would be silently skipped here — a new property without one fails to
    /// compile, which is the case worth catching.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.id = try c.decodeIfPresent(String.self, forKey: .id)
        self.type = try c.decode(ProjectType.self, forKey: .type)
        self.title = try c.decode(String.self, forKey: .title)
        self.author = try c.decode(String.self, forKey: .author)
        self.created = try c.decode(Date.self, forKey: .created)
        self.modified = try c.decode(Date.self, forKey: .modified)
        self.structure = try c.decode([StructureItem].self, forKey: .structure)
        self.research = try c.decode([ResearchItem].self, forKey: .research)
        self.statements = try c.decodeIfPresent([Statement].self, forKey: .statements) ?? []
        self.reviewPasses = try c.decodeIfPresent([ReviewPass].self, forKey: .reviewPasses) ?? []
        self.coachVacated = try c.decodeIfPresent(Bool.self, forKey: .coachVacated) ?? false
        self.firstReaderName = try c.decodeIfPresent(String.self, forKey: .firstReaderName)
        self.productionRoles = try c.decodeIfPresent(
            [ProductionRole].self, forKey: .productionRoles) ?? []
        self.targets = try c.decodeIfPresent(ProjectTargets.self, forKey: .targets)
        self.typography = try c.decodeIfPresent(TypographySettings.self, forKey: .typography)
        self.showElementGutter = try c.decodeIfPresent(Bool.self, forKey: .showElementGutter)
    }
}
