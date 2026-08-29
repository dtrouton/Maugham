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
///
/// The wire object names two arrays in translate mode, and in a fix leg the
/// four fields `Mode` describes.
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

    /// A note the translator stands against rather than acting on.
    struct Declined: Equatable {
        let noteId: String
        let reason: String
    }

    /// A term the edition should fix a rendering for, going forward.
    struct GlossaryProposal: Equatable {
        let term: String
        let rendering: String
        let reason: String
    }

    /// Which leg is reading. `.fix` carries the note ids the leg was briefed
    /// with, and the parser holds the report to them: every one in exactly one
    /// of `addressed`/`declined`, none from anywhere else. Silence on a note
    /// fails the report (spec §4) — an unaddressed note would otherwise land in
    /// the author's queue with no verdict from anybody.
    enum Mode: Equatable {
        case translate
        case fix(briefedNoteIds: Set<String>)
    }

    let entries: [Entry]
    let queries: [Query]
    let addressed: [String]
    let declined: [Declined]
    let summary: String?
    let glossaryProposals: [GlossaryProposal]

    init(entries: [Entry], queries: [Query], addressed: [String] = [],
         declined: [Declined] = [], summary: String? = nil,
         glossaryProposals: [GlossaryProposal] = []) {
        self.entries = entries
        self.queries = queries
        self.addressed = addressed
        self.declined = declined
        self.summary = summary
        self.glossaryProposals = glossaryProposals
    }

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
        static let addressed = "addressed"
        static let declined = "declined"
        static let noteId = "note_id"
        static let reason = "reason"
        static let summary = "summary"
        static let glossaryProposals = "glossary_proposals"
        static let term = "term"
        static let rendering = "rendering"
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
        full and never empty, replacing the source; "verbatim": true \
        means this paragraph carries over unchanged — a proper name, a line of \
        code, anything left untranslated on purpose — and takes no \
        "text" beside it. An entry with both forms or neither makes the \
        whole report unusable, so when unsure about one paragraph, leave \
        it out of entries rather than guess at a form. A query is a \
        question for the writer, never a translation decision: give it \
        "paragraph_id" when it is about one paragraph, or leave that key \
        out for a question about the piece as a whole; its "text" must not \
        be empty either. There is no way \
        to retract a translation through this report — un-translating a \
        paragraph is the writer's own act, not this run's. An empty \
        "entries" and an empty "queries" is a complete, valid answer for \
        a round that needs nothing further from you.
        """

    /// Appended to `schemaDescription` by a fix leg's briefing (spec §2).
    static let fixSchemaDescription: String = """
        This is a repair of the noted paragraphs, not a polish: an entry for a \
        paragraph you were not asked to fix makes the report unusable. The \
        object also carries "addressed": [note_id, …] for every note you \
        rewrote in response to, and "declined": [{"note_id":<id>,"reason":<why \
        the translation stands>}] for every note you stand against. Every note \
        you were given must appear in exactly one of the two — never neither, \
        never both. "summary" is a short paragraph, in the author's language, \
        saying what this round settled. "glossary_proposals": [{"term":<in the \
        source language>,"rendering":<in this edition's language>,"reason":<why>}] \
        names terms the edition should fix a rendering for.
        """

    // MARK: - Parsing

    /// Parse one turn's output. `nil` means unusable as a whole: no
    /// complete JSON object could be found, the object found is not shaped
    /// like this contract, any entry breaks the exactly-one-form rule, or any
    /// entry or query carries empty text (which is the same refusal — an
    /// empty `text` reads as no `text` at all).
    /// An empty `entries` and empty `queries` — a fully fresh document, or a
    /// round with nothing left to do — parses successfully. An empty LIST is
    /// a complete answer; an empty STRING inside one never is.
    /// The shape keys `lastObject` looks for are mode-dependent: translate
    /// mode looks only for `entries`/`queries`, exactly as before this type
    /// grew fix fields, so an object carrying only `summary` or `addressed`
    /// is not a translate-mode report at all; a fix mode also accepts an
    /// object shaped by its own fields, since a round with nothing to
    /// translate can still carry a summary alone.
    static func parse(_ raw: String, mode: Mode = .translate) -> TranslatorReport? {
        let shapeKeys: [String]
        switch mode {
        case .translate:
            shapeKeys = [WireField.entries, WireField.queries]
        case .fix:
            shapeKeys = [WireField.entries, WireField.queries, WireField.addressed,
                         WireField.declined, WireField.summary]
        }
        guard let object = ReportJSON.lastObject(in: raw, shapedBy: shapeKeys),
              let entries = ReportJSON.parseList(object, key: WireField.entries, parseItem: parseEntry),
              let queries = ReportJSON.parseList(object, key: WireField.queries, parseItem: parseQuery)
        else { return nil }

        guard case .fix(let briefed) = mode else {
            return TranslatorReport(entries: entries, queries: queries)
        }
        guard let addressed = parseIdList(object, key: WireField.addressed),
              let declined = ReportJSON.parseList(object, key: WireField.declined, parseItem: parseDeclined),
              let proposals = ReportJSON.parseList(object, key: WireField.glossaryProposals,
                                                   parseItem: parseGlossaryProposal),
              accounts(for: briefed, addressed: addressed, declined: declined)
        else { return nil }
        let summary = ReportJSON.nonEmptyString(object[WireField.summary])
        return TranslatorReport(entries: entries, queries: queries, addressed: addressed,
                                declined: declined, summary: summary, glossaryProposals: proposals)
    }

    /// Every briefed id in exactly one list; nothing in either list that was
    /// not briefed; no id twice.
    private static func accounts(for briefed: Set<String>, addressed: [String], declined: [Declined]) -> Bool {
        let all = addressed + declined.map(\.noteId)
        guard Set(all).count == all.count else { return false }
        return Set(all) == briefed
    }

    private static func parseIdList(_ object: [String: Any], key: String) -> [String]? {
        guard let value = object[key] else { return [] }
        guard let raw = value as? [Any] else { return nil }
        var ids: [String] = []
        for element in raw {
            guard let id = ReportJSON.nonEmptyString(element) else { return nil }
            ids.append(id)
        }
        return ids
    }

    private static func parseDeclined(_ item: [String: Any]) -> Declined? {
        guard let noteId = ReportJSON.nonEmptyString(item[WireField.noteId]),
              let reason = ReportJSON.nonEmptyString(item[WireField.reason]) else { return nil }
        return Declined(noteId: noteId, reason: reason)
    }

    private static func parseGlossaryProposal(_ item: [String: Any]) -> GlossaryProposal? {
        guard let term = ReportJSON.nonEmptyString(item[WireField.term]),
              let rendering = ReportJSON.nonEmptyString(item[WireField.rendering]),
              let reason = ReportJSON.nonEmptyString(item[WireField.reason]) else { return nil }
        return GlossaryProposal(term: term, rendering: rendering, reason: reason)
    }

    private static func parseEntry(_ item: [String: Any]) -> Entry? {
        guard let paragraphId = ReportJSON.nonEmptyString(item[WireField.paragraphId]) else { return nil }
        // **`nonEmptyString`, the same discipline the id gets.** `"text": ""`
        // is not a translation and neither is `"   "`; taken at face value it
        // would blank the paragraph in the published edition through a path
        // that never touched the manuscript, and the record would carry the
        // current source's hash, so it would read FRESH and no later
        // derivation would ever raise it. Reading an empty text as ABSENT is
        // what routes it into the exactly-one-form rule below, which refuses
        // the whole report — an entry with neither form, which is what an
        // empty text is.
        let text = ReportJSON.nonEmptyString(item[WireField.text])
        let verbatim = (item[WireField.verbatim] as? Bool) == true
        // Exactly one of the two forms. `(text != nil) != verbatim` is an
        // XOR over two booleans: equal (both true, both false) refuses,
        // unequal (exactly one true) accepts.
        guard (text != nil) != verbatim else { return nil }
        return Entry(paragraphId: paragraphId, text: text, verbatim: verbatim ? true : nil)
    }

    private static func parseQuery(_ item: [String: Any]) -> Query? {
        // A question with no words in it is not a question, and all-or-nothing
        // applies here as everywhere else in this parser: a model that emitted
        // an empty query has lost the contract, and there is no knowing what
        // else in the turn to trust.
        guard let text = ReportJSON.nonEmptyString(item[WireField.text]),
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
        guard let string = ReportJSON.nonEmptyString(raw) else { return nil }
        return .some(string)
    }
}
