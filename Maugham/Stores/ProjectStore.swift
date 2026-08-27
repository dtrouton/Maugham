import AppKit
import MaughamCore
import Foundation
import SwiftUI
import os

// Subsystem from the running bundle id so dev/stable logs separate without
// hardcoding "com.maugham" (tripwire 13 spirit).
// `internal` (not `private`) so the `ProjectStore+*.swift` peer extensions can
// log source-of-truth op-append failures through the same facility.
internal let projectStoreLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "ProjectStore")

public enum StructureItemKind: Equatable, Sendable {
    case document(extension: String)  // "md" or "fountain"
    case group
}

public enum ProjectStoreError: Error, Equatable {
    case manifestNotFound
    case manifestUnreadable(String)
    case manifestUnwritable(String)
    /// The on-disk manifest declares a `schemaVersion` newer than this build
    /// supports. Refused rather than degraded — see ADR 0015.
    case manifestSchemaTooNew(found: Int, supported: Int)
    case structureMissing
    /// The `(kind, scope)` pair has no row in the statement storage table
    /// (M1A spec §2.2) — visual language is project-scope only, and a `kind` or
    /// `scope` written by a newer build (ADR 0015's `.unknown`) is retained and
    /// ignored, never given a file. Refused rather than redirected to project
    /// scope: a chapter's intent written into the book's file is a loss.
    case statementHasNoStorage(kind: String, scope: String)
    case parentNotFound(String)
    case fileSystemError(String)
    case cycle
    /// RULING-40: one delete gesture is restored whole or refused with its
    /// reason. Thrown before anything is moved, so a refusal restores nothing.
    case deletionNotRestorableWhole(label: String, reason: String)
    /// RULING-43: a trash entry whose wiring cannot be put back is refused
    /// rather than "restored" into a success message that means nothing.
    case trashEntryNotRewirable(title: String, reason: String)
    /// RULING-7: "Empty Trash" could not destroy everything it was asked to.
    /// Reported rather than swallowed — a failed destruction must never read as
    /// a completed one — and what survived is still in the pane.
    case trashNotEmptied(undestroyed: Int, total: Int)
    /// Denver's ruling on a recorded collision: a shared-root research group
    /// titled "Palette" mints `research/palette`, the same path as the
    /// role-bearing Palette folder — its children then route to
    /// `PaletteCardEditor` by the path-prefix rule and show "Card
    /// unavailable". Refused at creation AND rename, never adopted or
    /// redirected — matches `statementHasNoStorage`'s refuse-don't-redirect
    /// precedent. `name` is the reserved title, for the message.
    case researchNameReserved(name: String)
    /// A translator was asked for with a blank language tag. Refused rather than
    /// minted: `Role.translator(language: "")` encodes as `"translator:"`, which
    /// decodes back as `.unknown` — the row would stop matching its own language
    /// on the next load and every later ask would mint another one.
    case productionRoleLanguageEmpty
    /// A rename whose name is empty once trimmed. `ProductionRole.effectiveName`
    /// promises never-empty; a blank byline reads as a bug, not as an unnamed
    /// person.
    case productionRoleNameEmpty
    /// A rename naming a role this project does not have. Refused rather than
    /// no-opped — a rename that silently changes nothing is the writer typing a
    /// name into a surface that keeps showing the old one.
    case productionRoleMissing(id: String)
    /// A language tag that is not a language tag — `TranslationRecord`
    /// `.isValidLanguageTag`'s rule, the same one the translation files and the
    /// MCP write tools already hold to. Carries the tag **as it arrived**, so a
    /// message can show the writer what was rejected rather than a normalised
    /// echo of it.
    ///
    /// **The two choke points that throw this apply the rule at different
    /// strengths, and the difference is deliberate.**
    /// `translatorRole(for:)` tests the tag *lowercased*: a role is matched
    /// case-insensitively (`storedTranslator(for:)`) and normalised on read
    /// (`EditionStatus.storedTranslatorLanguages`), so `ES` and `es-MX` are
    /// well-formed there and only something no lowercasing could rescue —
    /// `../evil`, `a b` — is refused. `createStatement(.editionBrief(lang))`
    /// tests it *verbatim*, because the tag is spelled into the filename
    /// `editions/<lang>.md` and every reader looks for the lowercase spelling:
    /// an `editions/EN.md` would be a brief the writer wrote and no session
    /// ever found again. A path character is refused at both, which is the
    /// point — the tag would otherwise reach `appendingPathComponent`.
    case languageTagInvalid(String)
    /// A statement's project-relative path did not resolve inside the project
    /// (`SafeRelativePath.PathError`, whose description is carried in `reason`).
    ///
    /// The last gate rather than the first: every kind's path is minted from
    /// the §2.2 table, and the one segment a caller supplies — a document's
    /// slug — is already sanitized by `Slugifier`. This catches the kind that
    /// forgets, and it is refused rather than clamped because a statement
    /// written to a *corrected* path is a file the manifest row would then
    /// point at by luck.
    case statementPathUnsafe(relativePath: String, reason: String)
}

/// Human-readable messages so `error.localizedDescription` in the pane alerts
/// (the binder tree's Research section) renders real text rather than the
/// Foundation fallback "(Maugham.ProjectStoreError error N)". `fileSystemError`
/// carries an already-composed message, so it renders its payload verbatim.
extension ProjectStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .manifestNotFound:
            return "The project could not be found."
        case .manifestUnreadable(let detail):
            return "The project could not be read: \(detail)"
        case .manifestUnwritable(let detail):
            return "The project could not be saved: \(detail)"
        case .manifestSchemaTooNew(let found, let supported):
            return "This project was created by a newer version of Maugham "
                + "(format \(found); this build supports \(supported)). "
                + "Update Maugham to open it."
        case .structureMissing:
            return "That item is no longer in the project."
        case .statementHasNoStorage(let kind, let scope):
            return "A “\(kind)” statement can’t be kept for “\(scope)”."
        case .parentNotFound(let id):
            return "The destination “\(id)” could not be found."
        case .fileSystemError(let message):
            return message
        case .cycle:
            return "An item can’t be moved into one of its own descendants."
        case .deletionNotRestorableWhole(let label, let reason):
            return "“\(label)” can’t be restored: \(reason)"
        case .trashEntryNotRewirable(let title, let reason):
            return "“\(title)” can’t be restored: \(reason)"
        case .trashNotEmptied(let undestroyed, let total):
            return "\(undestroyed) of \(total) item\(total == 1 ? "" : "s") could not be "
                + "permanently deleted. \(undestroyed == 1 ? "It is" : "They are") "
                + "still in the Trash."
        case .researchNameReserved(let name):
            return "“\(name)” is reserved for the Palette section. Choose a different name."
        case .productionRoleLanguageEmpty:
            return "A translator needs a language."
        case .productionRoleNameEmpty:
            return "A name can’t be empty."
        case .productionRoleMissing(let id):
            return "The role “\(id)” could not be found."
        case .languageTagInvalid(let tag):
            return "“\(tag)” isn’t a language tag. Use a code like “es” or “pt-br”."
        case .statementPathUnsafe(let relativePath, let reason):
            return "“\(relativePath)” isn’t a place inside this project: \(reason)"
        }
    }
}

/// Manages an open Maugham project: its manifest and structure.
/// The op log (under .maugham/ops/) is the source of truth for manuscript
/// content; .md files on disk are derived. See CLAUDE.md hard invariants.
@MainActor
@Observable
public final class ProjectStore {
    public let url: URL
    public internal(set) var manifest: ProjectManifest

    /// Optional reference to the DocumentStore that owns this project's
    /// coordinated I/O. Set by ProjectWindow at open time. When non-nil,
    /// manifest saves route through DocumentStore.writeManifest. When nil
    /// (e.g., during initial load before DocumentStore exists), saves use
    /// the legacy direct atomic-write path.
    public weak var documentStore: DocumentStore?

    /// Optional reference to the `CanvasModel` this project's window is showing.
    /// Set by ProjectWindow at open time, exactly as `documentStore` above is,
    /// and weak for the same reason: the window owns it and it must not outlive
    /// the window.
    ///
    /// **What it buys is the canvas's version of tripwire 20.** An MCP tool is
    /// handed a `ProjectRegistry.Entry` — an id, a URL and this store — and the
    /// canvas's state lives in SwiftUI `@State` on `ProjectWindow`, which no
    /// store owns. Without this the only reachable canvas is the derived sidecar
    /// on disk, so a tool would write behind the back of the canvas the writer is
    /// looking at and be overwritten by its next save. With it, a tool can tell
    /// the live canvas from the sidecar and address the one that is real.
    ///
    /// **Non-nil is not the same as usable.** The model is created eagerly with
    /// the window and is only attached while the Plan persona is on screen; ask
    /// `CanvasModel.isAttached`, whose doc comment spells out what a write into
    /// an unattached one costs.
    weak var liveCanvas: CanvasModel?

    /// The `Document`s that statement panes currently have open, by statement id
    /// (M1A). Implementation lives in `ProjectStore+Statements.swift`; the
    /// storage must sit on the class body because `@Observable` extensions
    /// cannot synthesize it.
    ///
    /// **This registry exists because a statement is deliberately in NO other
    /// one.** `StatementEditorHost` does not register its `Document` with
    /// `DocumentStore` — that would put it in `allOpenDocuments()`, which the
    /// project Tasks aggregation iterates (spec §8) — so
    /// `DocumentStore.document(forDocId:)` cannot find an open statement, and
    /// anything else that wanted to write into one would open a SECOND
    /// `Document` on the same path, each with its own `PendingBuffer` writing
    /// the same file. `@ObservationIgnored` because it is a lifecycle handle,
    /// never a rendered dependency.
    @ObservationIgnored internal var openStatementDocuments: [String: OpenStatementDocument] = [:]

    /// The statements somebody is currently OPENING a `Document` for, and whoever
    /// is queued behind them. The registry above answers for a `Document` that is
    /// already open; these two cover the window in which one is being opened,
    /// which is a suspension (`await Document.load`) that both openers have and
    /// neither can see. See `lockStatementOpen(_:)`.
    @ObservationIgnored internal var statementOpensInFlight: Set<String> = []
    @ObservationIgnored internal var statementOpenWaiters:
        [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Per-project cache fronting `DerivedManuscript` for CLOSED docs (F5).
    /// Owned here — not on `DocumentStore` — because every adopter (search,
    /// word counts, wiki-rename pre-check, the link tools) already holds a
    /// `ProjectStore` directly, and word-count population (below) needs the
    /// cache during/just-after `load`, when the weak `documentStore` isn't
    /// wired yet. Content-keyed on op-log file mtimes, so even the fresh
    /// `ProjectStore` the Statistics window loads derives correctly against
    /// its own (cold) instance. `@ObservationIgnored`: the cache is internal
    /// machinery, never an observed SwiftUI dependency.
    @ObservationIgnored public let derivedCache = DerivedManuscriptCache()

    /// Per-document cached word counts. Refreshed by EditorHost on text
    /// change. Aggregate sum is used by SessionTracker for project-wide
    /// net delta calculation.
    private var wordCountCache: [String: Int] = [:]

    public var projectWordCount: Int {
        wordCountCache.values.reduce(0, +)
    }

    public func recordWordCount(forDocumentId id: String, wordCount: Int) {
        wordCountCache[id] = wordCount
    }

    public func cachedWordCount(for id: String) -> Int? {
        wordCountCache[id]
    }

    /// Async word-count population kicked off at the tail of `load(from:)`.
    /// Held so tests can await it (`await store.wordCountPopulationTask?.value`)
    /// and so it's cancelled if the store is torn down mid-sweep.
    /// `@ObservationIgnored`: internal lifecycle handle, not observed.
    @ObservationIgnored public internal(set) var wordCountPopulationTask: Task<Void, Never>?

    static let manifestFilename = ProjectManifest.fileName

    public let trashStore: TrashStore
    public internal(set) var trashEntries: [TrashEntry] = []

    /// The trash entries ONE delete gesture made — a batch of fifty or a single
    /// row — in the order they were made. "Restore Last Deletion" (⌘⌥Z) is
    /// scoped to this action: it returns the whole of it or refuses and says
    /// why, never part of it silently (RULING-40).
    public internal(set) var lastDeletion: TrashDeletion?

    // MARK: - Search state

    public internal(set) var currentSearch: SearchResults?
    public internal(set) var searchInProgress: Bool = false
    var searchTask: Task<Void, Never>?

    // MARK: - Project-scope task state (milestone-tasks)
    //
    // Cross-project task aggregation cache + the sync mirror of
    // `.maugham/ops/__project__.jsonl`. Implementation lives in
    // `ProjectStore+Tasks.swift`; stored properties must live on the class
    // body because `@Observable` extensions can't synthesize storage.
    // See `docs/superpowers/specs/2026-05-23-tasks-design.md` §9.

    /// Sync mirror of the project-scope op log. Read-after-write within the
    /// same actor sees the latest state; the disk append is fire-and-forget
    /// (mirrors the per-doc task append pattern from Task 3).
    internal var _projectOpLogMirror: [Op] = []

    /// Set to true once the project op log has been loaded from disk (or
    /// the first append fires, whichever comes first). Lazy load on first
    /// `listTasksAcrossProject` / `projectTasksOpLog` call.
    internal var _projectOpLogLoaded: Bool = false

    /// Version counter for the project op log. Bumped on every append.
    /// Part of the cross-project cache key per spec §9.5.
    internal var _projectLogVersion: Int = 0

    /// Cross-project task derivation cache. Invalidated when the cache key
    /// changes (per-doc tasksVersion sum + closed-doc op-log mtime hash sum
    /// + project log version).
    internal var _projectTasksCache: [WriterTask] = []
    internal var _projectTasksCacheKey: ProjectTasksCacheKey? = nil

    /// SwiftUI-observable version token. Bumped on every append and on every
    /// rebuild. The pane in Task 8 binds to this. Mutation is only via
    /// `bumpProjectTasksVersion()` so the set surface is auditable.
    public internal(set) var projectTasksVersion: Int = 0

    internal func bumpProjectTasksVersion() {
        projectTasksVersion &+= 1
    }

    /// Stable device + session identifiers for project-scope ops. The
    /// per-Document `device` / `session` are not visible here, and project
    /// ops live in a separate log anyway, so we mint our own per-instance.
    /// `@ObservationIgnored` because these are computed-once internal
    /// identifiers, never observed by SwiftUI.
    @ObservationIgnored internal var projectOpDevice: String = MacDeviceID.current
    @ObservationIgnored internal var projectOpSession: String = UUID().uuidString

    /// Handle to the async op-log append triggered by the last project-task
    /// undo/redo hop. Mirror of `Document._lastUndoWorkTask` — tests await it
    /// to know the compensating op has landed before asserting. Not observable.
    @ObservationIgnored internal var _lastUndoWorkTask: Task<Void, Never>?

    #if DEBUG
    /// Debug counter for cache-rebuild tests. Increments every time the
    /// cross-project derivation actually runs. A hit on the cache key leaves
    /// this unchanged.
    internal var _debugTasksRebuildCount: Int = 0

    /// Debug counter for the craft-intent adoption gate (M1A). Increments once
    /// per `load` that actually SCANS the research tree. A gated-out open leaves
    /// it at zero — which is the only difference a test can observe between "the
    /// schema gate held" and "the scan ran and found nothing", and so the only
    /// way the once-and-never-again contract can be falsified.
    internal var _debugAdoptionScanCount: Int = 0

    /// What a failed promotion's rollback could NOT put back (M1A Task 13),
    /// one entry per staged path left in the staging tree. Empty is the normal
    /// state, including after a rollback that succeeded.
    ///
    /// The compensation reports through `projectStoreLog` because the writer
    /// must see why the promotion failed, not why its cleanup did — and a log
    /// line is not assertable, so "it was not silent" would be untestable
    /// without this. Mirrors `_debugAdoptionScanCount`: the only observable
    /// difference between "nothing was stranded" and "something was stranded
    /// quietly".
    internal var _debugPromotionStrandedMoveBacks: [String] = []
    #endif

    /// Cache-key struct kept on the class so the extension can read/write it.
    /// Two keys with identical fields compare equal; that's how the cache
    /// short-circuits.
    public struct ProjectTasksCacheKey: Equatable {
        let perDocVersionSum: Int
        let projectLogVersion: Int
    }

    // MARK: - Project-wide annotation state (M3 P2)
    //
    // Behaviour lives in `ProjectStore+Annotations.swift`; only the storage is
    // here, for the `@Observable` reason above.
    //
    // `@ObservationIgnored` deliberately, where the task cache is not: these
    // are written from inside a READ (`listAnnotationsAcrossProject`), and a
    // read that publishes is a view-update loop waiting to happen in the board
    // and the queue, which call it from a body. What tells SwiftUI a note
    // changed is the annotation event, not this cache.

    @ObservationIgnored
    internal var _projectAnnotationsCache: ProjectAnnotationsSnapshot? = nil
    @ObservationIgnored
    internal var _projectAnnotationsCacheKey: ProjectAnnotationsCacheKey? = nil

    /// Cache key for the project-wide annotation walk: open documents'
    /// `annotationsVersion` sum plus closed documents' op-log mtimes, and the
    /// number of documents the manifest holds.
    public struct ProjectAnnotationsCacheKey: Equatable {
        let perDocVersionSum: Int
        let documentCount: Int
    }

    #if DEBUG
    /// Debug counter for the annotation-cache tests, mirroring
    /// `_debugTasksRebuildCount`. A hit on the cache key leaves it unchanged —
    /// the only observable difference between a cache hit and a re-derive that
    /// happens to produce the same answer.
    @ObservationIgnored
    internal var _debugAnnotationsRebuildCount: Int = 0
    #endif

    private init(
        url: URL,
        manifest: ProjectManifest,
        trashStore: TrashStore,
        trashEntries: [TrashEntry]
    ) {
        self.url = url
        self.manifest = manifest
        self.trashStore = trashStore
        self.trashEntries = trashEntries
    }

    /// Load a project from disk by URL.
    public static func load(from url: URL) async throws -> ProjectStore {
        let manifestURL = url.appendingPathComponent(manifestFilename)
        let fm = FileManager.default

        guard fm.fileExists(atPath: manifestURL.path) else {
            throw ProjectStoreError.manifestNotFound
        }

        var manifest: ProjectManifest
        do {
            let data = try Data(contentsOf: manifestURL) // adr-0018-ok: project manifest JSON read, not manuscript
            // Schema-version gate (ADR 0015): refuse a project written by a
            // NEWER Maugham rather than degrade-and-resave it (which would
            // overwrite values this build can't represent). The per-enum
            // safe-default decoders only handle same-schema unexpected values.
            manifest = try ProjectManifest.decodeGuardingSchema(data)
        } catch let e as ProjectManifest.SchemaTooNewError {
            throw ProjectStoreError.manifestSchemaTooNew(
                found: e.found, supported: e.supported)
        } catch {
            // The live manifest is unreadable (corrupt / truncated). Recover from the
            // verified shadow if one exists, and repair the live file from it — so a
            // damaged `project.maugham.json` no longer means "can't open the project."
            guard let shadow = ManifestShadow.recover(in: url),
                  let recovered = try? ProjectManifest.makeDecoder()
                      .decode(ProjectManifest.self, from: shadow) else {
                throw ProjectStoreError.manifestUnreadable(error.localizedDescription)
            }
            manifest = recovered
            try? shadow.write(to: manifestURL, options: [.atomic])
            projectStoreLog.error(
                "Recovered project manifest from shadow for \(url.path, privacy: .public)")
        }

        // Backfill a stable project id for pre-`id` manifests (one-time, on open).
        // New projects are written by ProjectFactory with id == nil and acquire
        // theirs here on first load; existing projects acquire one the next time
        // they're opened. The phone keys capture-target selection + recents on
        // this id, so it must reach disk — persist it before the store is built.
        // `modified` is intentionally left untouched: backfilling an identifier
        // is not a content edit, and the milestone-1a whole-second ISO8601
        // round-trip on `modified` must not shift just because we added a field.
        if manifest.id == nil {
            manifest.id = ULID.generate()
            do {
                let data = try ProjectManifest.makeEncoder().encode(manifest)
                try data.write(to: manifestURL, options: [.atomic])
            } catch {
                projectStoreLog.error("Project id backfill failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        let trashStore = TrashStore(projectURL: url)
        try? await trashStore.sweep()
        let trashEntries = (try? await trashStore.list()) ?? []

        let store = ProjectStore(
            url: url,
            manifest: manifest,
            trashStore: trashStore,
            trashEntries: trashEntries)
        // S1: eagerly stamp the durable `role` on legacy (role == nil) palette /
        // craft-intent items BEFORE the window (and any rename affordance) is
        // reachable, so a rename made before the palette wall is ever opened
        // can't orphan the cards. Idempotent + zero-write once healed; awaited
        // so identity is durable before `load` returns. documentStore isn't
        // wired yet, so the stamp's manifest save uses the direct-write path
        // (same as the project-id backfill above).
        await store.healPaletteRolesEagerly()
        // M1A: adopt legacy craft-intent research notes into the intent
        // `Statement`, once, gated on the on-disk schema version. Runs AFTER the
        // role heal above (which is what makes the role-first detection see a
        // legacy note) and awaited, so the store handed back is already past its
        // migration. Never throws — a project that cannot be adopted still
        // opens, with its note untouched (spec §5).
        await store.adoptLegacyCraftIntentIfNeeded()
        // F5: word counts move OFF the blocking load path. `load` returns as
        // soon as the manifest is ready so the window appears immediately; the
        // per-doc derive sweep (the JSONL-decode cost, ~tens of ms/doc on a
        // month-old project × 50–100 docs) runs async afterward, publishing
        // counts as they land. Trade-off: `projectWordCount` is partial until
        // the sweep finishes, so a session started by typing in the first
        // instant captures a partial baseline — accepted (a transient live-
        // counter skew, self-corrects as counts land). See `Stores/AREA.md`.
        store.beginWordCountPopulation(from: manifest, at: url)
        return store
    }

    /// Walk every document in `manifest.structure`, derive its word count from
    /// the op-log-materialised text (ADR 0018) via the shared `derivedCache`,
    /// and record it. Runs asynchronously off `load`'s blocking path with a
    /// `Task.yield()` between docs so a big project doesn't monopolise the main
    /// actor; each `recordWordCount` publishes through `@Observable`, so
    /// consumers (goal indicator, Statistics window, binder) render counts
    /// incrementally as they populate.
    func beginWordCountPopulation(
        from manifest: ProjectManifest,
        at projectURL: URL
    ) {
        wordCountPopulationTask?.cancel()
        wordCountPopulationTask = Task { @MainActor [weak self] in
            for item in Self.collectDocuments(in: manifest.structure) {
                if Task.isCancelled { return }
                guard let self, let path = item.path else { continue }
                // ADR 0018: derive from the op log, never the .md file.
                // RULING-54 lenient, reason recorded: a background stats
                // pass skips an unreadable doc; opening it refuses loudly.
                guard let state = try? self.derivedCache.state(
                    forDocId: item.id, in: projectURL) else { continue }
                let text = state.paragraphs.values.joined(separator: " ")
                let count = WritingModeFactory.mode(for: path).wordCount(text)
                self.recordWordCount(forDocumentId: item.id, wordCount: count)
                await Task.yield()
            }
        }
    }

    static func collectDocuments(
        in items: [StructureItem]
    ) -> [StructureItem] {
        var out: [StructureItem] = []
        for item in items {
            if item.type == .document { out.append(item) }
            if let children = item.children {
                out.append(contentsOf: collectDocuments(in: children))
            }
        }
        return out
    }

    nonisolated static func newId(prefix: String) -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "\(prefix)-\(suffix)"
    }

    /// Returns `base` when `isTaken(base)` is false, otherwise tries
    /// `"\(base)-2"`, `"\(base)-3"`, ... until `isTaken` returns false.
    ///
    /// Used throughout ProjectStore+* to dedup slugs and folder names against
    /// either a `Set<String>` or a filesystem-existence check.  Pass the
    /// appropriate closure for each call site.
    ///
    /// - Note: Extension-qualified filenames (e.g. `"\(slug)-2.md"`) are NOT
    ///   handled here — those sites build the final filename outside the helper
    ///   and pass a closure that checks the full path.
    nonisolated static func dedupedName(
        _ base: String,
        isTaken: (String) -> Bool
    ) -> String {
        guard isTaken(base) else { return base }
        var n = 2
        while isTaken("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

}
