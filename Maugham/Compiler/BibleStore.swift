import Foundation
import MaughamCore

/// One fact Claude read off the manuscript during a compiler run: a claim
/// about a subject, traced back to the paragraph that established it.
///
/// Provisional by construction (spec §3.3: "derived entries in a visibly
/// provisional register"). Nothing here is truth — it is a reading, and the
/// writer's three actions on it (bless / correct / dismiss) are what promote
/// or discard a reading, never this store.
struct BibleFact: Codable, Equatable, Sendable, Identifiable {
    /// ULID.
    let id: String
    /// Who or what the fact is about ("Kelly").
    let subject: String
    let fact: String
    /// The ¶id of the paragraph that established this fact, when the run
    /// could anchor it. `nil` for a fact read off prose the anchor scan
    /// could not place (mirrors `Diagnostic.anchor` being optional).
    let establishedAt: String?
    let docId: String
    let recordedAt: Date
}

/// Project-scoped, per-device cache of the facts Claude has read off the
/// manuscript: the Bible stratum of the Intent pane (spec §3.3), and Stage
/// 2's slice of "what does the compiler already believe."
///
/// Derived state, on `DiagnosticsStore`'s and `DeclaredWorldStore`'s shared
/// contract: a missing or corrupt sidecar reads as empty rather than
/// throwing, and there is no repair path — the next compiler run repopulates
/// it. One file per device under `.maugham/`, so a run on one Mac never races
/// a run on another (tripwire 17's spirit; tripwire 24 at the filename
/// point).
///
/// **`init` loads, on `DeclaredWorldStore`'s departure from
/// `DiagnosticsStore`'s shape, not the plain sidecar's.** A missing
/// `DiagnosticsStore.load(docId:)` call shows an empty pane — visible. A
/// missing load here would silently starve `facts(subjects:)`, which Stage 2
/// reads as "the manuscript has established nothing yet" and answers by
/// re-deriving facts a previous run already recorded, with no symptom a
/// writer or a test would notice. So `init` reads the one sidecar this
/// device has, and both readers (`facts(subjects:)`, `allFacts()`) are pure
/// in-memory lookups with no ceremony a caller can forget.
///
/// One file, not per-doc (unlike `DiagnosticsStore`): facts already carry
/// their own `docId`, and cross-piece aggregation is explicitly out of scope
/// (spec §9) — the slice the store offers is by subject, not by document.
@Observable @MainActor
final class BibleStore {
    /// Monotonic; bumped by every mutation (`record`, `dismiss`, `load`) so
    /// an observing pane can invalidate a cached read without diffing
    /// arrays.
    private(set) var version: Int = 0

    private let projectRoot: URL
    private let device: DeviceSlug

    private var byId: [String: BibleFact] = [:]

    init(projectRoot: URL, device: DeviceSlug) {
        self.projectRoot = projectRoot
        self.device = device
        load()
    }

    /// The run's slice: every fact about any of `subjects`, regardless of
    /// which document established it. Subject match only — `docId` plays no
    /// part here (cross-piece aggregation is a separate question from
    /// whether Stage 2 should see a subject's facts at all, and the answer
    /// to this one is yes; spec §9 scopes the OTHER direction, a pane
    /// listing every piece a character has ever appeared in).
    func facts(subjects: Set<String>) -> [BibleFact] {
        byId.values.filter { subjects.contains($0.subject) }
    }

    /// The pane's stratum: every fact this device has recorded, for the
    /// caller to slice by `docId` itself (the Bible pane shows one piece's
    /// facts; a project-wide view shows all of them). The store does not
    /// pre-filter by document — see the type doc.
    func allFacts() -> [BibleFact] {
        Array(byId.values)
    }

    /// Add `candidates` to the ledger, deduping on `(subject, fact)`
    /// case-insensitively against what is already recorded — re-running a
    /// compiler pass over the same delta must not double an entry it already
    /// landed. A candidate whose `(subject, fact)` pair is already present
    /// (under a live id) is dropped silently; every other candidate is kept
    /// as given, including its own id.
    ///
    /// A dismissed fact's `(subject, fact)` pair is not in the ledger — it
    /// was removed — so a later `record` of the identical pair is not a
    /// duplicate here. That return is intended (spec §3.3: "may return if
    /// the manuscript re-establishes it"); this method has no memory of what
    /// was dismissed and must not grow one.
    func record(_ candidates: [BibleFact]) {
        var seen = Set(byId.values.map { dedupeKey(subject: $0.subject, fact: $0.fact) })
        var changed = false
        for candidate in candidates {
            let key = dedupeKey(subject: candidate.subject, fact: candidate.fact)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            byId[candidate.id] = candidate
            changed = true
        }
        guard changed else { return }
        persist()
        version += 1
    }

    /// Remove one fact (the writer dismissed it, spec §3.3). No-op if `id`
    /// is unknown. Persists immediately. Does not remember `id` or its
    /// `(subject, fact)` pair afterward — a later `record` of the same claim
    /// is a fresh entry, not blocked by this call (see `record`'s doc).
    func dismiss(_ id: String) {
        guard byId.removeValue(forKey: id) != nil else { return }
        persist()
        version += 1
    }

    /// `.maugham/bible.<slug>.json` — per-device so two machines running the
    /// compiler over the same project never race each other's sidecar.
    /// `.raw` is interpolated only here (tripwire 24).
    static func sidecarURL(projectRoot: URL, device: DeviceSlug) -> URL {
        projectRoot.appendingPathComponent(".maugham/bible.\(device.raw).json")
    }

    /// Re-read this device's sidecar. Called by `init`; public so a surface
    /// that knows the file moved underneath it can refresh.
    func load() {
        let url = Self.sidecarURL(projectRoot: projectRoot, device: device)
        guard let data = try? Data(contentsOf: url), // adr-0018-ok: bible sidecar, derived, not manuscript
              let facts = try? Self.makeDecoder().decode([BibleFact].self, from: data)
        else {
            byId = [:]
            version += 1
            return
        }
        byId = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: Self.survivor)
        version += 1
    }

    /// Which of two facts sharing one id survives the load (whole-branch
    /// review, I1).
    ///
    /// **A duplicate id is not a reason to take the app down.** `load` runs
    /// from `init`, which runs from `ProjectWindow.load()`, so
    /// `Dictionary(uniqueKeysWithValues:)`'s trap on a repeated key turned a
    /// decodable-but-corrupt sidecar into a crash at project open — one that
    /// repeated until somebody found and deleted a hidden file. Nothing here
    /// writes duplicates (`persist` serializes a dictionary); this is the
    /// contract in the type doc being kept: a corrupt sidecar reads as
    /// whatever can be salvaged, never as a throw.
    ///
    /// The newest reading wins, because a later run is the one that recorded
    /// it. Ties fall back to the words rather than to array order: the file is
    /// rewritten from a dictionary, so the order it lists two facts in is not
    /// stable, and a rule that depended on it would give a different answer on
    /// different launches over the same bytes.
    static func survivor(_ a: BibleFact, _ b: BibleFact) -> BibleFact {
        if a.recordedAt != b.recordedAt { return a.recordedAt > b.recordedAt ? a : b }
        return (a.subject, a.fact) <= (b.subject, b.fact) ? a : b
    }

    /// The one place the dedupe key is computed, so `record`'s guard and the
    /// candidate scan can never drift into two spellings. A null-character
    /// join keeps `subject: "AB", fact: "C"` distinct from `subject: "A",
    /// fact: "BC"`.
    private func dedupeKey(subject: String, fact: String) -> String {
        "\(subject.lowercased())\u{0}\(fact.lowercased())"
    }

    private func persist() {
        let url = Self.sidecarURL(projectRoot: projectRoot, device: device)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(Array(byId.values)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
