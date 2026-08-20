import Foundation

/// What one turn of the designer's Claude session must return, and how
/// Maugham reads it back.
///
/// **One object, `TranslatorReport`'s shape.** A designer turn answers one
/// question — "here is this round's proposal" — so the wire shape is a
/// single JSON object naming the spec and the files it stages, same as a
/// translator turn names its entries and queries.
///
/// **All-or-nothing starts at parse, not at staging.** A file whose path
/// breaks any of the path rules below is a model that has lost the
/// contract — and a proposal Maugham cannot safely stage anywhere is worth
/// no more than one it cannot stage at all, so `parse` refuses the whole
/// report rather than drop the one bad file and stage the rest.
///
/// **`spec` is never optional; `files` may be empty.** A words-only round —
/// a question for the writer, a plan with nothing to show yet — is still a
/// complete answer, same as `TranslatorReport`'s empty `entries`/`queries`.
/// But there is always a spec: a report with files and no write-up is a
/// proposal nobody can review.
struct DesignerReport: Equatable {

    /// One file this round proposes to stage under `.maugham/publish/`.
    /// `content` MAY be empty — a stub partial, filled in on a later round,
    /// is a legitimate design choice, not a malformed answer.
    struct ProposedFile: Equatable {
        let path: String
        let content: String
    }

    let specMarkdown: String
    let files: [ProposedFile]

    // MARK: - Wire names

    /// The wire names, in one place — `TranslatorReport.WireField`'s
    /// discipline. `DesignerReportTests` asserts every one of them appears
    /// in `schemaDescription`, so the briefing text and the parser cannot
    /// drift apart in a rewording.
    enum WireField {
        static let spec = "spec"
        static let files = "files"
        static let path = "path"
        static let content = "content"
    }

    /// The one filename a design proposal may never write, in any
    /// directory: it is compile configuration (`PublishConfigStore`
    /// reads/writes `.maugham/publish/config.json`), not a design file.
    static let reservedConfigFilename = "config.json"

    /// The prose+JSON description of this contract, stated once. Task 5's
    /// briefing embeds this verbatim rather than restating the shape.
    static let schemaDescription: String = """
        Respond with exactly one fenced JSON object — no prose before, \
        inside, or after it:
        {"spec":<the design write-up, in Markdown, never empty>,"files":\
        [{"path":<file path, relative to .maugham/publish/>,\
        "content":<the file's full replacement content, may be empty>}]}
        "spec" is the design write-up in Markdown and must never be \
        empty — even a words-only round that proposes no files still has \
        something to say: a question for the writer, a plan, a "here's \
        what I'd change and why". Each entry in "files" proposes one \
        file under .maugham/publish/, addressed by "path" relative to \
        that directory — "template.tex", "styles.css", \
        "partials/dropcaps.tex" and so on. "content" is that file's full \
        replacement content and MAY be empty: a stub partial finished on \
        a later round is a legitimate design choice. A path must be \
        relative (no leading "/"), must not contain a ".." segment \
        anywhere in it, must not be named "config.json" in any case or \
        any directory — that file is compile configuration, so propose \
        template/style/partial files only — and must not repeat a path \
        already used earlier in this same "files" list. Any file \
        breaking one of those rules makes the whole report unusable, so \
        when unsure about a path, leave that file out rather than guess. \
        An empty "files" beside a non-empty "spec" is a complete, valid \
        answer for a round that only has words to offer.
        """

    // MARK: - Parsing

    /// Parse one turn's output. `nil` means unusable as a whole: no
    /// complete JSON object could be found, the object found is not shaped
    /// like this contract, `spec` is missing or empty, or any file breaks
    /// a path rule, is missing `content`, or repeats an earlier path.
    static func parse(_ raw: String) -> DesignerReport? {
        guard let object = reportObject(in: raw),
              let spec = nonEmptyString(object[WireField.spec]),
              let files = parseFiles(object)
        else { return nil }
        return DesignerReport(specMarkdown: spec, files: files)
    }

    /// A key that is absent reads as an empty list — a model that omits an
    /// empty array has still answered "nothing here". A key that is
    /// present but the wrong shape, any one file that fails `parseFile`,
    /// or a path repeated from an earlier entry fails the whole list.
    private static func parseFiles(_ object: [String: Any]) -> [ProposedFile]? {
        guard let value = object[WireField.files] else { return [] }
        guard let raw = value as? [Any] else { return nil }
        var results: [ProposedFile] = []
        results.reserveCapacity(raw.count)
        var seenPaths = Set<String>()
        for element in raw {
            guard let item = element as? [String: Any],
                  let file = parseFile(item),
                  seenPaths.insert(file.path).inserted
            else { return nil }
            results.append(file)
        }
        return results
    }

    private static func parseFile(_ item: [String: Any]) -> ProposedFile? {
        guard let path = nonEmptyString(item[WireField.path]),
              isSafePath(path),
              // `content` must be present as a string, even `""` — its
              // absence is a form the model has lost, the same discipline
              // `TranslatorReport.parseEntry` gives `text`/`verbatim`.
              let content = item[WireField.content] as? String
        else { return nil }
        return ProposedFile(path: path, content: content)
    }

    /// Every rule the contract states: relative, no `..` segment anywhere
    /// (the brief's own example — `a/../b` — is exactly a `..` segment
    /// that isn't the whole path, which is why this splits and checks
    /// segments rather than checking a prefix or a substring), never named
    /// `config.json` in any case in any directory. Duplicate detection
    /// lives in `parseFiles`, where the running set is.
    private static func isSafePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/") else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains("..") else { return false }
        guard let last = segments.last,
              last.lowercased() != reservedConfigFilename
        else { return false }
        return true
    }

    /// A `String` value with something in it. Mirrors
    /// `TranslatorReport.nonEmptyString` — same discipline, kept local for
    /// the same reason: this type owes the translator's contract no
    /// dependency.
    ///
    /// It TRIMS, and every field routed through it is kept trimmed: the
    /// spec, the path. `content` is deliberately NOT routed through this —
    /// file content is not prose the model composed around JSON
    /// formatting, it is the file, and trimming it would corrupt
    /// meaningful leading/trailing whitespace.
    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - JSON extraction

    /// The LAST complete top-level JSON object in `raw` that looks like a
    /// designer report — i.e. carries a `spec` or `files` key.
    ///
    /// Identical discipline to `TranslatorReport.reportObject`: reads
    /// spans in reverse and returns the first match found that way,
    /// because a model that reasons in prose before committing to its
    /// answer tends to put worked examples earlier and the real answer
    /// last.
    private static func reportObject(in raw: String) -> [String: Any]? {
        for span in objectSpans(in: raw).reversed() {
            guard let data = span.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  dictionary[WireField.spec] != nil || dictionary[WireField.files] != nil
            else { continue }
            return dictionary
        }
        return nil
    }

    /// Every top-level `{...}` span in `text`, brace-balanced and
    /// string-aware. Identical discipline to `TranslatorReport.objectSpans`
    /// — duplicated here rather than shared for the same reason that copy
    /// gives for its own duplication from `DiagnosticIngest`: it is
    /// `private` there, and this type owes the translator's contract no
    /// dependency either.
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
