import CryptoKit
import Foundation
import MaughamCore

/// One clause of the writer's declared world: a sentence they wrote, and the
/// checkable reading of it.
///
/// `quote` is the writer's own text, verbatim — the pane shows *that*, never
/// `check`. The derivation is mechanics, and mechanics are not what a writer
/// asked to be checked against (spec §3.1: "never shown as mechanics").
struct DerivedClause: Codable, Equatable, Sendable {
    /// A sentence lifted verbatim from the statement.
    let quote: String
    /// What checking that sentence against the prose means, in one line.
    let check: String
}

/// A rule is intent about a subject — "Kelly only ever acts on things she's
/// actually heard". Same shape as a clause plus the subject it is about, which
/// is what lets a run carry only the rules the wet ink can violate.
struct DerivedRule: Codable, Equatable, Sendable {
    /// Who or what the rule constrains ("Kelly").
    let subject: String
    /// The writer's own sentence, verbatim.
    let quote: String
    /// What the prose must not do, in one line.
    let constraint: String
}

/// Claude's reading of one statement document into checkable units.
///
/// Disposable and never sacred (spec §3.1). Nothing here is truth: it is a
/// cache of a reading, keyed by the exact text it was read from, and losing it
/// costs one re-derivation. It never enters the writer-owned layer — that
/// membrane is crossed only by bless / correct / rule / the writer's own
/// editing (spec §3.4).
struct DerivedWorld: Codable, Equatable, Sendable {
    /// SHA-256 of the statement text this reading was made from. The cache key
    /// half that makes a stale derivation unservable.
    let sourceHash: String
    let clauses: [DerivedClause]
    let rules: [DerivedRule]
    let derivedAt: Date

    /// The ONE place the source hash is computed — the deriver's call site and
    /// every reader ask here, so the value that gates the cache and the value
    /// stamped into it can never be computed two ways.
    ///
    /// Over the **exact** text, deliberately: no normalization, no
    /// anchor-stripping. The hash must mean "this reading was made from
    /// precisely this string", and any transform between the hash and the
    /// deriver's input is a way to serve a reading of text that was never read.
    /// The accepted cost is a re-derivation when only whitespace moved.
    static func sourceHash(of statementText: String) -> String {
        SHA256.hash(data: Data(statementText.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Per-device sidecar of Claude's readings of the writer's statements: one
/// `DerivedWorld` per statement scope, on THIS machine.
///
/// Derived state, on `DiagnosticsStore`'s contract: a missing or corrupt
/// sidecar reads as empty rather than throwing, and there is no repair path —
/// the next derivation repopulates it. One file per `(scope, device)` under
/// `.maugham/derived/`, so a derivation on one Mac never collides with one on
/// another reading the same statement (tripwire 17's spirit; tripwire 24 at the
/// filename point).
///
/// **Two differences from `DiagnosticsStore`, both deliberate:**
///
/// - **Reading takes no ceremony.** `init` materializes the whole derived
///   directory, so `cached` is a pure in-memory lookup with no `load` call to
///   forget. `DiagnosticsStore` can afford an explicit per-doc `load` because
///   missing it shows an empty pane; missing one here would silently re-derive
///   — spawning Claude and spending tokens — on every launch, with no symptom
///   a writer or a test would notice.
/// - **`cached` never mutates.** It is read from view bodies that also observe
///   `version`; a read-through cache would mutate observed state mid-body.
///
/// The hash gate is the whole point: a reading is served only against the exact
/// text it was made from. Edit the prose and the cache goes quiet on its own,
/// before anyone remembers to invalidate it.
@Observable @MainActor
final class DeclaredWorldStore {
    /// Monotonic; bumped by every mutation (`store`, `invalidate`, `load`) so
    /// an observing pane can invalidate a cached read without diffing.
    private(set) var version: Int = 0

    private let projectRoot: URL
    private let device: DeviceSlug

    private var byScope: [String: DerivedWorld] = [:]

    init(projectRoot: URL, device: DeviceSlug) {
        self.projectRoot = projectRoot
        self.device = device
        load()
    }

    /// The filename-safe spelling of a statement scope. **The one spelling** —
    /// the deriver's call site, the ruling performer and the Intent pane all
    /// ask here rather than each formatting `Statement.Scope` their own way,
    /// because two spellings mean two caches and one of them is never hit.
    ///
    /// - `.project` → `project`
    /// - `.document(id)` → `doc-<id>` (doc ids are `doc-<hex>` / `scene-<hex>`
    ///   and contain no dot, ADR 0008, so the suffix-strip in `load` stays
    ///   unambiguous). An id carrying anything outside the safe set — it should
    ///   not, but this string becomes a path component — is replaced by a
    ///   stable digest rather than sanitized, so two hostile ids cannot key the
    ///   same file.
    /// - `.unknown(raw)` → `unknown-<digest>`: a scope a newer build wrote
    ///   still has somewhere to cache, and the raw string is arbitrary.
    static func scopeKey(for scope: Statement.Scope) -> String {
        switch scope {
        case .project:
            return "project"
        case .document(let id):
            return "doc-" + (isFilenameSafe(id) ? id : StableHash.fnv1a64Hex(id))
        case .unknown(let raw):
            return "unknown-" + StableHash.fnv1a64Hex(raw)
        }
    }

    private static func isFilenameSafe(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// The reading cached for `scopeKey`, but only if it was made from text
    /// hashing to `sourceHash`. `nil` when absent OR when the prose has moved
    /// since — a stale derivation is never served.
    ///
    /// Pure: no disk, no mutation (see the type doc).
    func cached(forScopeKey scopeKey: String, sourceHash: String) -> DerivedWorld? {
        guard let world = byScope[scopeKey], world.sourceHash == sourceHash else { return nil }
        return world
    }

    /// A fresh reading wholly replaces the previous one for this scope — there
    /// is never more than one reading of one statement live. Persists
    /// immediately.
    func store(_ world: DerivedWorld, forScopeKey scopeKey: String) {
        byScope[scopeKey] = world
        persist(world, forScopeKey: scopeKey)
        version += 1
    }

    /// The prose behind this scope changed — a ruling landed, was edited or was
    /// revoked. Drops the reading and its sidecar.
    ///
    /// Reaches the disk on purpose: an entry dropped from memory alone returns
    /// on the next launch, and a writer who revoked a ruling would be checked
    /// against it again. A scope that was never derived is a no-op, so the
    /// mutation path can call this unconditionally.
    func invalidate(forScopeKey scopeKey: String) {
        byScope[scopeKey] = nil
        try? FileManager.default.removeItem(
            at: Self.sidecarURL(projectRoot: projectRoot, scopeKey: scopeKey, device: device))
        version += 1
    }

    /// Re-read this device's derived directory. Called by `init`; public so a
    /// surface that knows the sidecars moved underneath it can refresh.
    ///
    /// Every file is independent: one that will not decode is skipped, costing
    /// its own scope's derivation and no other's.
    func load() {
        let directory = Self.derivedDirectory(projectRoot: projectRoot)
        let suffix = ".\(device.raw).json"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var loaded: [String: DerivedWorld] = [:]
        for name in names where name.hasSuffix(suffix) {
            let scopeKey = String(name.dropLast(suffix.count))
            let url = directory.appendingPathComponent(name)
            guard !scopeKey.isEmpty,
                  let data = try? Data(contentsOf: url), // adr-0018-ok: derivation cache, derived
                  let world = try? Self.makeDecoder().decode(DerivedWorld.self, from: data)
            else { continue }
            loaded[scopeKey] = world
        }
        byScope = loaded
        version += 1
    }

    /// `.maugham/derived/<scopeKey>.<slug>.json` — per-device so two machines
    /// deriving the same statement never race each other's sidecar. `.raw` is
    /// interpolated only here (tripwire 24).
    static func sidecarURL(projectRoot: URL, scopeKey: String, device: DeviceSlug) -> URL {
        derivedDirectory(projectRoot: projectRoot)
            .appendingPathComponent("\(scopeKey).\(device.raw).json")
    }

    private static func derivedDirectory(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(".maugham/derived", isDirectory: true)
    }

    private func persist(_ world: DerivedWorld, forScopeKey scopeKey: String) {
        let url = Self.sidecarURL(projectRoot: projectRoot, scopeKey: scopeKey, device: device)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(world) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
