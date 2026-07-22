import Foundation

public enum TranslationHash {
    /// Display form (anchors stripped), per-line trailing whitespace stripped,
    /// outer whitespace trimmed. Consequence (accepted, documented): an edit
    /// that only changes trailing whitespace — including a markdown two-space
    /// hard break — does not flip staleness.
    public static func normalize(_ text: String) -> String {
        MarkdownDisplayFilter.stripAnchors(text)
            .components(separatedBy: "\n")
            .map { line in
                var l = Substring(line)
                while let last = l.last, last == " " || last == "\t" { l = l.dropLast() }
                return String(l)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func hash(_ text: String) -> String {
        StableHash.fnv1a64Hex(normalize(text))
    }
}

public enum TranslationStatus: String, Codable, Sendable { case fresh, stale, missing }

public struct TranslatedDocument: Sendable {
    public struct Entry: Sendable {
        public let paragraphId: String
        public let sourceText: String
        public let translatedText: String?
        public let status: TranslationStatus
        public let verbatim: Bool
    }
    public let language: String
    public let entries: [Entry]
    public let orphans: [TranslationRecord]

    public var freshCount: Int { entries.lazy.filter { $0.status == .fresh }.count }
    public var staleCount: Int { entries.lazy.filter { $0.status == .stale }.count }
    public var missingCount: Int { entries.lazy.filter { $0.status == .missing }.count }
}

public enum TranslationDeriver {
    /// `sequence` is authoritative order (hard invariant). Freshness is derived,
    /// never stored.
    public static func derive(records: [TranslationRecord], sequence: [String],
                              paragraphs: [String: String], language: String) -> TranslatedDocument {
        let latest = TranslationStore.latestByParagraph(records)
        let inSequence = Set(sequence)
        var entries: [TranslatedDocument.Entry] = []
        for id in sequence {
            let source = paragraphs[id] ?? ""
            if let rec = latest[id] {
                let status: TranslationStatus =
                    rec.sourceHash == TranslationHash.hash(source) ? .fresh : .stale
                entries.append(.init(paragraphId: id, sourceText: source,
                                     translatedText: rec.text, status: status,
                                     verbatim: rec.verbatim))
            } else {
                // A whitespace-only source paragraph has nothing to translate,
                // so a missing record is not a real gap: derive it `.fresh`
                // (the coverage gate already excludes blanks — this keeps
                // translation_status from reporting a permanently-"missing"
                // blank). The entry is KEPT either way so the render still shows
                // its source-text fallback; `translatedText` stays nil.
                let isBlank = source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                entries.append(.init(paragraphId: id, sourceText: source,
                                     translatedText: nil,
                                     status: isBlank ? .fresh : .missing, verbatim: false))
            }
        }
        let orphans = records.filter { !inSequence.contains($0.paragraphId) }
        return TranslatedDocument(language: language, entries: entries, orphans: orphans)
    }
}
