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

    /// All device files for one (docId, language), any device slug.
    public static func fileURLs(forDocId docId: String, language: String,
                                in projectURL: URL) -> [URL] {
        let dir = directoryURL(in: projectURL)
        let prefix = "\(docId).\(language)."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".jsonl") }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    /// Distinct languages present for a doc (scans filenames).
    /// Parses from the right: filename must be `{docId}.{language}.{deviceSlug}.jsonl`
    /// where deviceSlug is non-empty. Rejects files with wrong component counts or
    /// mismatched docId prefix to avoid false matches when docId is a dotted prefix
    /// of another (e.g., "doc.a" vs "doc.a.b").
    public static func languages(forDocId docId: String, in projectURL: URL) -> [String] {
        let dir = directoryURL(in: projectURL)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var langs = Set<String>()

        for n in names where n.hasSuffix(".jsonl") {
            // Remove .jsonl extension (5 characters)
            let withoutExt = String(n.dropLast(".jsonl".count))

            // Split by . and parse from the right:
            // The rightmost part is deviceSlug, second-from-right is language,
            // and everything before that should join back to docId
            let parts = withoutExt.split(separator: ".", omittingEmptySubsequences: false)
                .map(String.init)

            // Need at least 3 components: docId (≥1), language (1), deviceSlug (1)
            guard parts.count >= 3 else { continue }

            let deviceSlug = parts[parts.count - 1]
            let language = parts[parts.count - 2]
            let reconstructedDocId = parts.dropLast(2).joined(separator: ".")

            // Verify docId matches exactly (prevents false matches on dotted prefixes)
            guard reconstructedDocId == docId else { continue }

            // Verify deviceSlug is non-empty (should be guaranteed by split, but explicit)
            guard !deviceSlug.isEmpty else { continue }

            // Validate language tag
            guard TranslationRecord.isValidLanguageTag(language) else { continue }

            langs.insert(language)
        }

        return Array(langs)
    }

    @MainActor
    public static func append(_ record: TranslationRecord, forDocId docId: String,
                              deviceSlug: DeviceSlug, in projectURL: URL) async throws {
        let url = fileURL(forDocId: docId, language: record.language,
                          deviceSlug: deviceSlug, in: projectURL)
        try await JSONLAppendStore<TranslationRecord>(fileURL: url).append(record)
    }

    /// Appends every record in `records` to one device's file in a SINGLE
    /// coordinated write — the whole batch is serialized to one `Data` first,
    /// so a failure (bad directory, coordination error) writes nothing rather
    /// than a partial file. `language` is explicit rather than read off the
    /// records so an empty batch and the file it would target are unambiguous;
    /// callers building a batch for one write_translation call already know it
    /// (task 2 makes that call atomic on top of this).
    public static func appendBatch(_ records: [TranslationRecord], forDocId docId: String,
                                   language: String, deviceSlug: DeviceSlug, in projectURL: URL) throws {
        guard !records.isEmpty else { return }
        let url = fileURL(forDocId: docId, language: language, deviceSlug: deviceSlug, in: projectURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<TranslationRecord>.dateEncoding
        enc.outputFormatting = [.sortedKeys]
        var data = Data()
        for r in records {
            data.append(try enc.encode(r))
            data.append(0x0A)
        }
        let coord = NSFileCoordinator()
        var coordErr: NSError?
        var writeErr: Error?
        coord.coordinate(writingItemAt: url, options: [], error: &coordErr) { wu in
            do {
                if FileManager.default.fileExists(atPath: wu.path) {
                    let h = try FileHandle(forWritingTo: wu)
                    try h.seekToEnd()
                    try h.write(contentsOf: data)
                    try h.close()
                } else {
                    try data.write(to: wu, options: .atomic)
                }
            } catch { writeErr = error }
        }
        if let coordErr { throw coordErr }
        if let writeErr { throw writeErr }
    }

    /// opId-ascending, canonical-content tiebreak, first-wins dedup by opId —
    /// same total-order discipline as OpLogStore.mergeSortedDedup.
    public static func loadMerged(forDocId docId: String, language: String,
                                  in projectURL: URL) -> [TranslationRecord] {
        var all: [TranslationRecord] = []
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
            all.append(contentsOf:
                JSONLAppendStore<TranslationRecord>.parse(bytes: bytes, dedupKey: nil, sortedBy: nil).elements)
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
