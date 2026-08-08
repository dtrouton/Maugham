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
    ///
    /// **A payload, never a caption.** Requirement 3 — no bare ¶ids anywhere
    /// the writer reads — applies to this stratum exactly as it applies to the
    /// diagnostics pane; what the writer sees is `excerpt`.
    let establishedAt: String?
    /// The head of `establishedAt`'s paragraph as it read when the run
    /// anchored it — `Diagnostic.Ref.excerpt`'s discipline, captured at ingest
    /// from the same resolution (`DiagnosticIngest.resolveRefs`), because the
    /// live text is in hand there and nowhere else.
    ///
    /// `nil` for a fact with no anchor, and for a row written by a build
    /// before this field existed: the sidecar is derived state, so an old row
    /// decodes with a nil excerpt and the pane shows the subject alone rather
    /// than falling back to the id it must never print.
    let excerpt: String?
    let docId: String
    let recordedAt: Date

    /// Explicit rather than synthesized so `excerpt` can default — the field
    /// is additive on a derived sidecar and a call site that has no excerpt to
    /// give (a test, a fact carried across a redaction) says so by omission.
    init(id: String, subject: String, fact: String, establishedAt: String?,
         excerpt: String? = nil, docId: String, recordedAt: Date) {
        self.id = id
        self.subject = subject
        self.fact = fact
        self.establishedAt = establishedAt
        self.excerpt = excerpt
        self.docId = docId
        self.recordedAt = recordedAt
    }
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
    /// Monotonic; bumped by every mutation (`record`, `dismiss`,
    /// `markGraduated`, `load`) so an observing pane can invalidate a cached
    /// read without diffing arrays.
    private(set) var version: Int = 0

    private let projectRoot: URL
    private let device: DeviceSlug

    private var byId: [String: BibleFact] = [:]

    /// The dedupe keys of readings the writer has GRADUATED — blessed or
    /// corrected into a ruling of their own. The one thing this store
    /// remembers about a fact that has left it, and the reason it remembers
    /// exactly this and nothing else is in `markGraduated`'s doc.
    private var graduatedKeys: Set<String> = []

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
    /// was DISMISSED and must not grow one.
    ///
    /// **A GRADUATED pair is the one exception, and it is a different
    /// question.** A blessed or corrected reading is now a ruling in the
    /// writer's own layer, briefed to every run as a derived clause; letting
    /// it back in would put the same declaration in front of the model twice
    /// and invite a second bless that mints a duplicate ruling row
    /// (`Maugham/Compiler/AREA.md`, "the third door"). Dismissed means "not
    /// so" and the manuscript may argue; graduated means "so, and mine" and
    /// there is nothing left to offer.
    func record(_ candidates: [BibleFact]) {
        var seen = Set(byId.values.map { dedupeKey(subject: $0.subject, fact: $0.fact) })
        var changed = false
        for candidate in candidates {
            let key = dedupeKey(subject: candidate.subject, fact: candidate.fact)
            guard !seen.contains(key), !graduatedKeys.contains(key) else { continue }
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

    /// **The writer graduated this reading**: it is a ruling in their own
    /// layer now, and the register must not offer it again.
    ///
    /// Called by `BibleStratum.graduate` AFTER `RulingPerformer.rule` succeeds
    /// and BEFORE the fact is dismissed — the same ordering rule the dismiss
    /// already obeyed, one step earlier: a refused ruling must leave both the
    /// fact and the door exactly as it found them, or the writer loses the
    /// reading to a graduation that never happened.
    ///
    /// **A correction marks TWO keys, and both of them earn it.** It rules
    /// "Kelly is a paramedic" over a reading of "Kelly is a nurse", and the
    /// manuscript can go on to establish either sentence: the reading, because
    /// the prose that produced it is still there, and the ruling, because the
    /// writer has since written toward what they decided. Neither is news any
    /// more — one was superseded and the other was declared — and a candidate
    /// matching either would invite a bless of something already settled,
    /// which `RulingsSection.appending` would happily write as a duplicate
    /// row. A bless has one sentence in both roles and marks one key.
    ///
    /// **Revoking the ruling does not reopen this door**, and that is a
    /// decision rather than an omission. A revoke is the writer unmaking a
    /// decision they made; it is not a request to be asked the question again
    /// by a compiler run that may not happen for days, about prose they have
    /// since rewritten. Resurrection would also have to guess WHICH reading a
    /// revoked ruling came from — the corrected case has two sentences and
    /// only one of them was ever a fact. If a smoke says otherwise, the fix is
    /// one `graduatedKeys.remove` at the revoke site, not a second memory.
    func markGraduated(subject: String, fact: String) {
        guard graduatedKeys.insert(dedupeKey(subject: subject, fact: fact)).inserted else {
            return
        }
        persist()
        version += 1
    }

    /// Whether this `(subject, fact)` pair has graduated. The pane has no use
    /// for it — a graduated fact is not on the pane — but the door has to be
    /// assertable from outside, and `record`'s silence is not evidence.
    func isGraduated(subject: String, fact: String) -> Bool {
        graduatedKeys.contains(dedupeKey(subject: subject, fact: fact))
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
        let decoder = Self.makeDecoder()
        guard let data = try? Data(contentsOf: url) // adr-0018-ok: bible sidecar, derived, not manuscript
        else { return adopt(facts: [], graduated: []) }

        if let sidecar = try? decoder.decode(Sidecar.self, from: data) {
            adopt(facts: sidecar.facts, graduated: Set(sidecar.graduated))
        } else if let legacy = try? decoder.decode([BibleFact].self, from: data) {
            // A sidecar this build's envelope did not write: every row is a
            // fact and nothing has graduated. Derived state takes no
            // migration (tripwire 11) — but silently discarding a ledger a
            // previous build spent real runs building is a cost with no
            // symptom, so the old shape is READ and the next `persist`
            // rewrites it as an envelope.
            adopt(facts: legacy, graduated: [])
        } else {
            adopt(facts: [], graduated: [])
        }
    }

    private func adopt(facts: [BibleFact], graduated: Set<String>) {
        byId = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: Self.survivor)
        graduatedKeys = graduated
        version += 1
    }

    /// The sidecar as this build writes it: the ledger, and the keys that have
    /// graduated out of it.
    ///
    /// An envelope rather than a second file, because the two answer one
    /// question — *what does this device's register hold, and what has it
    /// already handed over* — and a graduated key that outlived its ledger (or
    /// the reverse) would put the blessed fact back on the pane on exactly the
    /// launch after somebody deleted the wrong half.
    private struct Sidecar: Codable {
        let facts: [BibleFact]
        /// Dedupe keys (`dedupeKey`), sorted on the way out so the file does
        /// not churn on a rewrite that changed nothing.
        let graduated: [String]
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
        let sidecar = Sidecar(facts: Array(byId.values), graduated: graduatedKeys.sorted())
        if let data = try? encoder.encode(sidecar) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
