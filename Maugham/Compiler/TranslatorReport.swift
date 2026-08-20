import Foundation

/// What one turn of the translator's Claude session must return, and how
/// Maugham reads it back.
///
/// **One object, not a sectioned stream.** The compiler's contract
/// (`DiagnosticIngest`) is five line-delimited JSON objects because five
/// different kinds of finding can arrive independently; a translator answers
/// one question — "here is this round's work" — so the wire shape is a
/// single JSON object naming two arrays.
///
/// **All-or-nothing starts at parse, not at ingest.** `DiagnosticIngest`
/// drops a bad ENTRY and keeps the rest of the turn, because a compiler run
/// that lost one note out of twenty is still worth showing. A translator
/// turn that gets one entry wrong is different: an entry that supplies both
/// `text` and `verbatim`, or neither, is a model that has lost the contract,
/// and there is no way to know which of its OTHER entries to trust either.
/// So `parse` refuses the whole report rather than salvage around the bad
/// entry — the orchestrator surfaces that as an `unusableOutput`-shaped
/// failure, same as a turn that produced no usable text at all.
///
/// **`delete` is deliberately absent from this contract.** A translation
/// disappearing is the writer's own act (or an orphan-purge outside any
/// run) — never something a run decides on its own.
struct TranslatorReport: Equatable {

    /// One paragraph's translation, or the instruction to carry the source
    /// over unchanged. Exactly one of `text` / `verbatim` is non-nil in any
    /// value this type is asked to hold — `parse` is the only way to build
    /// one from wire data, and it enforces that; a value built directly by a
    /// test is the caller's responsibility, same discipline
    /// `TranslationWritePipeline.Entry` uses for the sibling contract.
    struct Entry: Equatable {
        let paragraphId: String
        let text: String?
        let verbatim: Bool?
    }

    /// A question for the writer, not a translation choice. `paragraphId`
    /// is `nil` for a question about the piece as a whole — omitted or
    /// explicit `null` on the wire, both read the same way.
    struct Query: Equatable {
        let paragraphId: String?
        let text: String
    }

    let entries: [Entry]
    let queries: [Query]

    // MARK: - Wire names

    /// The wire names, in one place — `DiagnosticIngest.SectionField`'s
    /// discipline. `TranslatorReportTests` asserts every one of them appears
    /// in `schemaDescription`, so the briefing text and the parser cannot
    /// drift apart in a rewording.
    enum WireField {
        static let entries = "entries"
        static let queries = "queries"
        static let paragraphId = "paragraph_id"
        static let text = "text"
        static let verbatim = "verbatim"
    }

    /// The prose+JSON description of this contract, stated once. Task 3's
    /// briefing embeds this verbatim rather than restating the shape — one
    /// source of truth for what a translator must produce, the same reason
    /// `CompilerPrompt.sectionSchemaDescription` exists for the compiler.
    static let schemaDescription: String = """
        Respond with exactly one fenced JSON object — no prose before, \
        inside, or after it:
        {"entries":[{"paragraph_id":<id>,"text":<translated paragraph>}|\
        {"paragraph_id":<id>,"verbatim":true}],"queries":\
        [{"paragraph_id":<id, or omit for a whole-document question>,\
        "text":<the question>}]}
        Every entry names the paragraph it answers for and supplies \
        exactly one of two forms: "text" is the translated paragraph in \
        full, replacing the source; "verbatim": true means this \
        paragraph carries over unchanged — a proper name, a line of \
        code, anything left untranslated on purpose — and takes no \
        "text" beside it. An entry with both forms or neither makes the \
        whole report unusable, so when unsure about one paragraph, leave \
        it out of entries rather than guess at a form. A query is a \
        question for the writer, never a translation decision: give it \
        "paragraph_id" when it is about one paragraph, or leave that key \
        out for a question about the piece as a whole. There is no way \
        to retract a translation through this report — un-translating a \
        paragraph is the writer's own act, not this run's. An empty \
        "entries" and an empty "queries" is a complete, valid answer for \
        a round that needs nothing further from you.
        """

    // MARK: - Parsing

    /// Parse one turn's output. `nil` means unusable as a whole: no
    /// complete JSON object could be found, the object found is not shaped
    /// like this contract, or any entry breaks the exactly-one-form rule.
    /// An empty `entries` and empty `queries` — a fully fresh document, or a
    /// round with nothing left to do — parses successfully.
    static func parse(_ raw: String) -> TranslatorReport? {
        guard let object = reportObject(in: raw),
              let entries = parseList(object, key: WireField.entries, parseItem: parseEntry),
              let queries = parseList(object, key: WireField.queries, parseItem: parseQuery)
        else { return nil }
        return TranslatorReport(entries: entries, queries: queries)
    }

    private static func parseEntry(_ item: [String: Any]) -> Entry? {
        guard let paragraphId = nonEmptyString(item[WireField.paragraphId]) else { return nil }
        let text = item[WireField.text] as? String
        let verbatim = (item[WireField.verbatim] as? Bool) == true
        // Exactly one of the two forms. `(text != nil) != verbatim` is an
        // XOR over two booleans: equal (both true, both false) refuses,
        // unequal (exactly one true) accepts.
        guard (text != nil) != verbatim else { return nil }
        return Entry(paragraphId: paragraphId, text: text, verbatim: verbatim ? true : nil)
    }

    private static func parseQuery(_ item: [String: Any]) -> Query? {
        guard let text = item[WireField.text] as? String,
              let paragraphId = paragraphIdField(item)
        else { return nil }
        return Query(paragraphId: paragraphId, text: text)
    }

    /// `paragraph_id` on a query is optional — absent or explicit `null`
    /// both mean "document-level", present-but-wrong-shaped is malformed.
    /// The outer optional carries that third state: `nil` here means
    /// malformed (bail the whole report); `.some(nil)` means valid and
    /// document-level; `.some("id")` means valid and paragraph-scoped.
    private static func paragraphIdField(_ item: [String: Any]) -> String?? {
        guard let raw = item[WireField.paragraphId], !(raw is NSNull) else {
            return .some(nil)
        }
        guard let string = nonEmptyString(raw) else { return nil }
        return .some(string)
    }

    /// A key that is absent reads as an empty list — a model that omits an
    /// empty array has still answered "nothing here". A key that is present
    /// but the wrong shape, or any one element that fails `parseItem`, fails
    /// the whole list — which is what makes the caller's all-or-nothing hold
    /// once this returns `nil`.
    private static func parseList<T>(
        _ container: [String: Any], key: String, parseItem: ([String: Any]) -> T?
    ) -> [T]? {
        guard let value = container[key] else { return [] }
        guard let raw = value as? [Any] else { return nil }
        var results: [T] = []
        results.reserveCapacity(raw.count)
        for element in raw {
            guard let item = element as? [String: Any], let parsed = parseItem(item) else {
                return nil
            }
            results.append(parsed)
        }
        return results
    }

    /// A `String` value with something in it. Mirrors
    /// `DiagnosticIngest.nonEmptyString` — same discipline, kept local
    /// because this type owns no dependency on the compiler's ingest.
    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - JSON extraction

    /// The LAST complete top-level JSON object in `raw` that looks like a
    /// translator report — i.e. carries an `entries` or `queries` key.
    ///
    /// Mirrors `DiagnosticIngest`'s brace-balanced, string-aware span scan
    /// (`objectSpans`) — tolerant of a fence around the object and of prose
    /// before or after it, for the same reason: fence markers hold no
    /// braces, so a fenced block's object is still exactly one span. Where
    /// this differs from the compiler's discipline: `DiagnosticIngest`
    /// reads the FIRST section-shaped span, because a section-per-line turn
    /// puts its real content up front. A translator turn is answered by a
    /// single object, and a model that reasons in prose before committing
    /// to its answer tends to put worked examples earlier and the real
    /// answer last — so this reads spans in reverse and returns the first
    /// match found that way, i.e. the last complete block in the text.
    private static func reportObject(in raw: String) -> [String: Any]? {
        for span in objectSpans(in: raw).reversed() {
            guard let data = span.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  dictionary[WireField.entries] != nil || dictionary[WireField.queries] != nil
            else { continue }
            return dictionary
        }
        return nil
    }

    /// Every top-level `{...}` span in `text`, brace-balanced and
    /// string-aware. Identical discipline to `DiagnosticIngest.objectSpans`
    /// — see that copy for the reasoning; duplicated here rather than
    /// shared because it is `private` there and this type owes the
    /// compiler's ingest no dependency.
    private static func objectSpans(in text: String) -> [String] {
        var spans: [String] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false

        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"":
                inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                guard depth > 0 else { break }
                depth -= 1
                if depth == 0, let opening = start {
                    spans.append(String(text[opening...index]))
                    start = nil
                }
            default:
                break
            }
        }
        return spans
    }
}
