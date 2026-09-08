import Foundation
import os

/// Diagnostic channel for translation-sidecar anomalies (M6: a device file
/// that exists in the directory listing but can't be read). Subsystem from the
/// running bundle id so dev/stable logs separate without hardcoding a literal
/// (tripwire 13 spirit); mirrors `Deriver.swift`'s `deriverLog`.
private let translationLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.core",
    category: "TranslationStore")

/// Sidecar store for per-paragraph translations. Per-device files under
/// `.maugham/translations/` (tripwire 17); newest-opId-wins per paragraph.
public enum TranslationStore {
    public static func directoryURL(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(".maugham/translations")
    }

    public static func fileURL(forDocId docId: String, language: String,
                               deviceSlug: DeviceSlug, in projectURL: URL) -> URL {
        directoryURL(in: projectURL)
            .appendingPathComponent("\(docId).\(language).\(deviceSlug.raw).jsonl")
    }

    /// One sidecar filename, parsed back into the three things that built it:
    /// `{docId}.{language}.{deviceSlug}.jsonl`. The docId may itself contain
    /// dots, so the parse reads from the RIGHT — deviceSlug, then language —
    /// and rejoins what is left as the docId. The guard a caller relies on is
    /// **reconstructed-docId equality**, not a component count: a file with an
    /// extra dot is not rejected for being long, it simply reconstructs to a
    /// DIFFERENT docId and so belongs to that doc ("doc.a" vs "doc.a.b").
    ///
    /// The single filename parser for this directory — both `fileURLs` (which
    /// used to prefix-match positionally, and so cross-matched a docId that is
    /// a dotted prefix of another) and `languages` come through here.
    static func parseFileName(_ name: String) -> (docId: String, language: String, deviceSlug: String)? {
        guard name.hasSuffix(".jsonl") else { return nil }
        let parts = name.dropLast(".jsonl".count)
            .split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)
        // docId (≥1) + language (1) + deviceSlug (1).
        guard parts.count >= 3 else { return nil }
        let deviceSlug = parts[parts.count - 1]
        let language = parts[parts.count - 2]
        let docId = parts.dropLast(2).joined(separator: ".")
        guard !deviceSlug.isEmpty, !docId.isEmpty else { return nil }
        return (docId, language, deviceSlug)
    }

    /// All device files for one (docId, language), any device slug.
    public static func fileURLs(forDocId docId: String, language: String,
                                in projectURL: URL) -> [URL] {
        let dir = directoryURL(in: projectURL)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { n in
            guard let p = parseFileName(n) else { return false }
            return p.docId == docId && p.language == language
        }
        .sorted()
        .map { dir.appendingPathComponent($0) }
    }

    /// Distinct languages present for a doc (scans filenames). A file counts
    /// only if it reconstructs to exactly this docId and its language component
    /// is a well-formed tag — the tag check is `languages`' alone, because this
    /// is the list a picker and `translation_status` are built from.
    public static func languages(forDocId docId: String, in projectURL: URL) -> [String] {
        let dir = directoryURL(in: projectURL)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var langs = Set<String>()
        for n in names {
            guard let p = parseFileName(n), p.docId == docId,
                  TranslationRecord.isValidLanguageTag(p.language) else { continue }
            langs.insert(p.language)
        }
        return Array(langs)
    }

    /// One record, one write — a thin wrapper over `appendBatch` so there is a
    /// single coordinated-write body (and a single tombstone rule) to reason
    /// about. No production caller today; the tests and seeding helpers that
    /// write one record at a time keep it.
    @MainActor
    public static func append(_ record: TranslationRecord, forDocId docId: String,
                              identity: DeviceIdentity, identities: LocalIdentities,
                              state: OpLogDeviceState = .shared,
                              in projectURL: URL) async throws {
        try await appendBatch([record], forDocId: docId, language: record.language,
                              identity: identity, identities: identities,
                              state: state, in: projectURL)
    }

    /// Appends every record in `records` to one device's file in a SINGLE
    /// coordinated write — the whole batch is serialized to one `Data` first,
    /// so a failure (bad directory, coordination error) writes nothing rather
    /// than a partial file. The SEAL that follows is a second write and
    /// deliberately so: a batch that lands and is not sealed is a run of
    /// unsealed lines, which is a state the walk already reads, whereas a seal
    /// inside the same write would have to be signed before the lines it
    /// commits to exist. `language` is explicit rather than read off the
    /// records so an empty batch and the file it would target are unambiguous;
    /// callers building a batch for one write_translation call already know it
    /// (task 2 makes that call atomic on top of this).
    ///
    /// A batch of nothing but tombstones for a (docId, language) that has no
    /// records anywhere writes NOTHING, because a translation file is not just
    /// a container of records — its existence is what puts the language in
    /// `languages(forDocId:)`, and so in `translation_status` and the writer's
    /// Translation Review picker, permanently. Minting one from deletions alone
    /// creates a language the writer never translated into and can never remove
    /// (there is nothing in it to purge). Nothing to remove → nothing to
    /// record. The check spans SIBLING device files, the same enumeration the
    /// phantom would appear in: once any device has translated into this
    /// language, a tombstone here is meaningful — it removes that record on
    /// merge — so the write proceeds. This device's own file is checked
    /// directly as well, so a directory listing that fails (permissions, an
    /// evicted iCloud folder) can never turn a real purge into a silent drop.
    /// **Who wrote it is the key it is signed with** (P1b): `identity` is the
    /// actor whose file this is and whose key signs the seal — the
    /// `translator` for the pipeline and `write_translation`, the `author` for
    /// the Translation Review pane's own edits — and it is where the filename's
    /// slug comes from, so a hand-built device string cannot reach this
    /// directory. `identities` is the whole device (all four actors) and is
    /// what the chain TRUSTS on read: a translator-signed file read on the
    /// author's next load must classify as this device's own word, not as
    /// another device's unsigned history.
    @MainActor
    public static func appendBatch(_ records: [TranslationRecord], forDocId docId: String,
                                   language: String, identity: DeviceIdentity,
                                   identities: LocalIdentities,
                                   state: OpLogDeviceState = .shared,
                                   in projectURL: URL) async throws {
        guard !records.isEmpty else { return }
        let url = fileURL(forDocId: docId, language: language,
                          deviceSlug: identity.slug, in: projectURL)
        if records.allSatisfy({ $0.text == nil }),
           !FileManager.default.fileExists(atPath: url.path),
           !languages(forDocId: docId, in: projectURL).contains(language) {
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // One chained line per record inside ONE coordinated write, then one
        // seal over the batch — the op log's own shape, from the op log's own
        // store, so a translation line and a manuscript line are readable by
        // exactly the same walk.
        let store = JSONLAppendStore<TranslationRecord>(
            fileURL: url,
            chain: ChainPolicy(
                identity: identity, state: state,
                docId: docId, projectURL: projectURL,
                trustedFingerprints: identities.fingerprints))
        try await store.appendBatch(records)
        try await store.appendSeal()
    }

    /// opId-ascending, canonical-content tiebreak, first-wins dedup by opId —
    /// same total-order discipline as OpLogStore.mergeSortedDedup.
    ///
    /// **Every file is walked before any of it is applied** (P1b). `trusted` is
    /// all four of this device's actors, so the translator's own file reads as
    /// this device's word; a file another device wrote carries a seal under a
    /// key that is not ours and reads as unsigned history, which is history and
    /// not damage. Lines the walk held back are recorded through the same
    /// forensic path the op log uses, under the manuscript's own `docId` — the
    /// language is in the filename, so a `.lines` record files under the
    /// document History already shows.
    ///
    /// This is `JSONLAppendStore.loadVerifiedStrict`'s body, spelled
    /// synchronously over the same nonisolated helpers, because `loadMerged` is
    /// read from thirty synchronous call sites (the publish AST, the coverage
    /// gate, the editor's translated surface) and because its per-file
    /// leniency — warn and skip one unreadable device file rather than fail the
    /// whole read — is the opposite of the strict reader's contract.
    public static func loadMerged(forDocId docId: String, language: String,
                                  in projectURL: URL,
                                  identities: LocalIdentities = .current,
                                  state: OpLogDeviceState = .shared) -> [TranslationRecord] {
        var all: [TranslationRecord] = []
        let trusted = identities.fingerprints
        for url in fileURLs(forDocId: docId, language: language, in: projectURL) {
            // The URL came from the directory listing, so it exists; a read
            // failure here means the device file is present but unreadable
            // (permissions, iCloud eviction, corruption). Warn before skipping
            // rather than silently dropping a whole device's translations.
            guard let bytes = try? Data(contentsOf: url) else {  // adr-0018-ok: translation sidecar JSONL bytes, not manuscript-as-truth (ADR 0018)
                translationLog.warning(
                    "skipping unreadable translation file: \(url.lastPathComponent, privacy: .public)")
                continue
            }
            let fileKey = OpLogDeviceState.fileKey(url)
            let walked = OpLogChain.verify(
                bytes: bytes,
                trusted: { trusted.contains($0) },
                rememberedHead: state.head(for: fileKey))
            // The same absent-head decision the chained WRITE makes. If the two
            // disagreed, a load that held a tail back would be followed by an
            // append that chained onto it.
            let (verification, _) = OpLogChain.resolveAbsentHead(
                walked,
                rememberedHead: state.head(for: fileKey),
                previousHead: state.previousHead(for: fileKey))
            do {
                try JSONLAppendStore<TranslationRecord>.setAside(
                    verification, from: url, docId: docId, in: projectURL)
            } catch {
                // The record is how the writer LEARNS that something wrote into
                // their translations; it is never how the read proceeds.
                translationLog.error("""
                    Could not record set-aside lines from \
                    \(url.lastPathComponent, privacy: .public): \
                    \(String(describing: error), privacy: .public).
                    """)
            }
            all.append(contentsOf: JSONLAppendStore<TranslationRecord>.parse(
                bytes: JSONLAppendStore<TranslationRecord>.applied(verification, whole: bytes),
                dedupKey: nil, sortedBy: nil).elements)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = JSONLAppendStore<TranslationRecord>.dateEncoding
        func canonical(_ r: TranslationRecord) -> String {
            (try? enc.encode(r)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        let sorted = all.sorted {
            $0.opId != $1.opId ? $0.opId < $1.opId : canonical($0) < canonical($1)
        }
        var seen = Set<String>()
        return sorted.filter { seen.insert($0.opId).inserted }
    }

    /// Highest opId per paragraphId wins; tombstones (text == nil) remove the key.
    public static func latestByParagraph(_ records: [TranslationRecord]) -> [String: TranslationRecord] {
        var out: [String: TranslationRecord] = [:]
        for r in records.sorted(by: { $0.opId < $1.opId }) {
            if r.text == nil { out.removeValue(forKey: r.paragraphId) }
            else { out[r.paragraphId] = r }
        }
        return out
    }
}
