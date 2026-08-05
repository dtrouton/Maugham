import Foundation
import MaughamCore

/// Turns a compiler turn's final structured message into `Diagnostic` values.
///
/// Two rules carry the weight here:
///
/// **Anchors are captured live, at ingest.** A note's `anchorText` is whatever
/// the paragraph says *now*, read through `liveParagraphText` — never text the
/// model echoed back. That is what makes `DiagnosticsStore.live`'s exact-match
/// staleness rule correct, and it makes the mid-run edit a non-case: a writer
/// who revises a paragraph while the run is in flight gets the note anchored to
/// the revision, so it reads as live until their next edit. One staleness rule,
/// uniformly applied, instead of a special case that can only be wrong.
///
/// **A bad note never fails the run.** An id the document does not know, an
/// empty body, an entry that is not an object at all — each is dropped and
/// counted in `droppedDangling`. Only output that is unusable *as a whole*
/// (not JSON, or JSON of some other shape) returns `nil`, because there is
/// then nothing to salvage. The compiler is a background convenience; it does
/// not get to interrupt the writer over one malformed note.
enum DiagnosticIngest {

    /// What one turn yielded. `drift` is reported on its own and is never
    /// doubled into `accepted` — a caller that wants both concatenates them.
    struct Outcome: Equatable {
        let accepted: [Diagnostic]
        /// Notes discarded on their own merits: an unknown `paragraph_id`, an
        /// empty body, or an entry that isn't an object. Reported so a run can
        /// say it lost something without failing.
        let droppedDangling: Int
        let drift: Diagnostic?
    }

    /// The wire names, in one place. `DiagnosticIngestTests` asserts every one
    /// of them appears in `CompilerPrompt.outputSchemaDescription`, so the
    /// prompt and the parser cannot drift apart in a rewording.
    enum Field {
        static let diagnostics = "diagnostics"
        static let paragraphId = "paragraph_id"
        static let category = "category"
        static let body = "body"
        static let intentDrift = "intent_drift"
    }

    /// The category stamped on the drift note. The schema carries drift in its
    /// own field, so the category is ours to assign rather than the model's.
    static let driftCategory = "intent"

    /// Parse one turn's result text. Returns `nil` only for output that cannot
    /// be read at all — prose with no JSON in it, truncated JSON, or JSON of
    /// another shape. Fenced (```` ```json ... ``` ````) and bare JSON both
    /// parse, including a fence with the model's prose around it.
    static func parse(
        resultText: String, runId: String, docId: String,
        liveParagraphText: (String) -> String?
    ) -> Outcome? {
        guard let object = jsonObject(in: resultText) else { return nil }

        var accepted: [Diagnostic] = []
        var dropped = 0

        for entry in object[Field.diagnostics] as? [Any] ?? [] {
            guard let item = entry as? [String: Any],
                  let body = nonEmptyString(item[Field.body])
            else {
                dropped += 1
                continue
            }

            let anchor: Diagnostic.Anchor?
            switch item[Field.paragraphId] {
            case let raw as String:
                guard let resolved = resolve(raw, liveParagraphText) else {
                    dropped += 1
                    continue
                }
                anchor = Diagnostic.Anchor(
                    paragraphId: resolved.paragraphId, anchorText: resolved.text)
            case nil, is NSNull:
                // The schema's own escape hatch: a note about the delta rather
                // than one paragraph. Anchorless, but not drift — it keeps the
                // category the model gave it.
                anchor = nil
            default:
                dropped += 1
                continue
            }

            accepted.append(
                Diagnostic(
                    id: ULID.generate(), docId: docId, anchor: anchor, body: body,
                    category: nonEmptyString(item[Field.category]), runId: runId))
        }

        var drift: Diagnostic? = nil
        if let driftBody = nonEmptyString(object[Field.intentDrift]) {
            drift = Diagnostic(
                id: ULID.generate(), docId: docId, anchor: nil, body: driftBody,
                category: driftCategory, runId: runId)
        }

        return Outcome(accepted: accepted, droppedDangling: dropped, drift: drift)
    }

    // MARK: - Paragraph resolution

    /// The prompt prints ids as `[a1b2]`, so a model that copies the brackets
    /// (or reaches for a `¶`) has still named a paragraph the document knows.
    /// The raw spelling is tried first and the *resolved* id is what gets
    /// stored — the decoration never reaches a `Diagnostic`.
    private static func resolve(
        _ raw: String, _ liveParagraphText: (String) -> String?
    ) -> (paragraphId: String, text: String)? {
        let undecorated = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]\u{00b6}"))
        for candidate in [raw, undecorated] where !candidate.isEmpty {
            if let text = liveParagraphText(candidate) {
                return (candidate, text)
            }
        }
        return nil
    }

    // MARK: - JSON extraction

    /// The first candidate that parses as an object of our shape wins: fenced
    /// blocks first (a model that fences usually also narrates), then the whole
    /// text, then the widest brace-to-brace span.
    private static func jsonObject(in resultText: String) -> [String: Any]? {
        var candidates = fencedBlocks(in: resultText)
        candidates.append(resultText)
        if let span = widestBraceSpan(in: resultText) { candidates.append(span) }

        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  // Neither key present is some other shape entirely — a
                  // dictionary alone is not evidence this is our output.
                  dictionary[Field.diagnostics] != nil || dictionary[Field.intentDrift] != nil
            else { continue }
            return dictionary
        }
        return nil
    }

    /// Contents of every ```` ``` ````-delimited block, with an opening
    /// language tag (`json`) dropped.
    private static func fencedBlocks(in text: String) -> [String] {
        let parts = text.components(separatedBy: "```")
        guard parts.count >= 3 else { return [] }
        return stride(from: 1, to: parts.count, by: 2).map { index -> String in
            let block = parts[index]
            guard let newline = block.firstIndex(of: "\n") else { return block }
            let firstLine = block[block.startIndex..<newline]
            let isLanguageTag = !firstLine.contains("{")
                && firstLine.trimmingCharacters(in: .whitespaces).count <= 12
            return isLanguageTag ? String(block[block.index(after: newline)...]) : block
        }
    }

    private static func widestBraceSpan(in text: String) -> String? {
        guard let open = text.firstIndex(of: "{"),
              let close = text.lastIndex(of: "}"),
              open < close
        else { return nil }
        return String(text[open...close])
    }

    // MARK: - Values

    /// A `String` value with something in it. Whitespace-only is nothing: an
    /// empty body is unusable content for one note, and an empty
    /// `intent_drift` is the model saying no in a roundabout way.
    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
