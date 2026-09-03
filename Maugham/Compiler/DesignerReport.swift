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
        relative (no leading "/" or "~"), must not contain a ".." \
        segment anywhere in it, must not be named "config.json" in any \
        case or any directory — that file is compile configuration, so \
        propose template/style/partial files only — and must not repeat \
        a path already used earlier in this same "files" list, even \
        under different capitalization ("Template.tex" and \
        "template.tex" are the same file). Any file breaking one of \
        those rules makes the whole report unusable, so when unsure \
        about a path, leave that file out rather than guess. \
        An empty "files" beside a non-empty "spec" is a complete, valid \
        answer for a round that only has words to offer.
        """

    // MARK: - Parsing

    /// Parse one turn's output. `nil` means unusable as a whole: no
    /// complete JSON object could be found, the object found is not shaped
    /// like this contract, `spec` is missing or empty, or any file breaks
    /// a path rule, is missing `content`, or repeats an earlier path.
    static func parse(_ raw: String) -> DesignerReport? {
        guard let object = ReportJSON.lastObject(in: raw, shapedBy: [WireField.spec, WireField.files]),
              let spec = ReportJSON.nonEmptyString(object[WireField.spec]),
              let files = parseFiles(object)
        else { return nil }
        return DesignerReport(specMarkdown: spec, files: files)
    }

    /// A key that is absent reads as an empty list — a model that omits an
    /// empty array has still answered "nothing here". A key that is
    /// present but the wrong shape, any one file that fails `parseFile`,
    /// or a path repeated from an earlier entry fails the whole list.
    ///
    /// Duplicate detection case-folds: `config.json`'s own refusal already
    /// case-folds (`isSafePath`), and on APFS's default case-insensitive
    /// volume "Template.tex" and "template.tex" collide at write time
    /// regardless of what the model spelled — so two proposals that would
    /// land on the same file are a duplicate even when their casing
    /// differs.
    private static func parseFiles(_ object: [String: Any]) -> [ProposedFile]? {
        guard let value = object[WireField.files] else { return [] }
        guard let raw = value as? [Any] else { return nil }
        var results: [ProposedFile] = []
        results.reserveCapacity(raw.count)
        var seenPaths = Set<String>()
        for element in raw {
            guard let item = element as? [String: Any],
                  let file = parseFile(item),
                  seenPaths.insert(file.path.lowercased()).inserted
            else { return nil }
            results.append(file)
        }
        return results
    }

    private static func parseFile(_ item: [String: Any]) -> ProposedFile? {
        guard let path = ReportJSON.nonEmptyString(item[WireField.path]),
              isSafePath(path),
              // `content` must be present as a string, even `""` — its
              // absence is a form the model has lost, the same discipline
              // `TranslatorReport.parseEntry` gives `text`/`verbatim`.
              let content = item[WireField.content] as? String
        else { return nil }
        return ProposedFile(path: path, content: content)
    }

    /// Every rule the contract states: relative (no leading `/` or `~` —
    /// the same two the sibling `PublicationSnapshotStore.extract` refuses,
    /// since a `~` is a shell/home-directory expansion this path is never
    /// entitled to), no embedded null byte (a string terminator in C-based
    /// filesystem APIs — truncates the path at the write site into
    /// something this check never saw), no `..` segment anywhere (the
    /// brief's own example — `a/../b` — is exactly a `..` segment that
    /// isn't the whole path, which is why this splits and checks segments
    /// rather than checking a prefix or a substring), never named
    /// `config.json` in any case in any directory. Duplicate detection
    /// lives in `parseFiles`, where the running set is.
    private static func isSafePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\0")
        else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains("..") else { return false }
        guard let last = segments.last,
              last.lowercased() != reservedConfigFilename
        else { return false }
        return true
    }

}
