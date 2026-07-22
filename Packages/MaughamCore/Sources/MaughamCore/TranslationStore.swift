import Foundation

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
    public static func languages(forDocId docId: String, in projectURL: URL) -> [String] {
        let dir = directoryURL(in: projectURL)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var langs = Set<String>()
        for n in names where n.hasPrefix("\(docId).") && n.hasSuffix(".jsonl") {
            let rest = n.dropFirst(docId.count + 1).dropLast(".jsonl".count)
            let parts = rest.split(separator: ".")
            if parts.count == 2, TranslationRecord.isValidLanguageTag(String(parts[0])) {
                langs.insert(String(parts[0]))
            }
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

    /// opId-ascending, canonical-content tiebreak, first-wins dedup by opId —
    /// same total-order discipline as OpLogStore.mergeSortedDedup.
    public static func loadMerged(forDocId docId: String, language: String,
                                  in projectURL: URL) -> [TranslationRecord] {
        var all: [TranslationRecord] = []
        for url in fileURLs(forDocId: docId, language: language, in: projectURL) {
            guard let bytes = try? Data(contentsOf: url) else { continue }
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
