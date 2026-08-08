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

    // MARK: - Values

    /// A `String` value with something in it. Whitespace-only is nothing: an
    /// empty body is unusable content for one note.
    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - The sectioned contract

/// Reads `CompilerPrompt.sectionSchemaDescription`'s four sections. Two rules
/// carry the weight, stated once at the top of this file and still true here:
/// anchors are captured live at ingest, and a bad entry is dropped and
/// counted rather than failing the run. Three more are this contract's own:
///
/// **One section is one unit.** `parseSection` turns a single line into that
/// section's whole contribution, so sections can be ingested as they arrive.
/// `parseAll` is that function folded over the turn's objects and NOTHING
/// else, which is why the two can never disagree about what a section means.
///
/// **Refusal is per entry, uniformly.** If any prose the writer would read out
/// of one entry breaks a contract — a paragraph id where a quotation belongs,
/// or a fix where an observation belongs — the whole entry goes, counted in
/// `droppedDangling`. A half-refused entry ("this clause strains" with the
/// explanation removed) is a worse thing to show than nothing.
///
/// **The register is enforced twice.** The schema has no severity field and no
/// suggestion field, so there is structurally nowhere for a fix to go; this is
/// the backstop for a model that writes one into a prose field anyway. It is a
/// small list of second-person directives, not a classifier — see
/// `fixShapedMarkers`.
extension DiagnosticIngest {

    /// The wire names and enumerated values, in one place.
    /// `DiagnosticIngestTests` asserts every one of them appears in
    /// `CompilerPrompt.sectionSchemaDescription`, so the prompt and the parser
    /// cannot drift apart in a rewording.
    enum SectionField {
        static let section = "section"

        static let conformance = "conformance"
        static let checks = "checks"
        static let clauseQuote = "clause_quote"
        static let status = "status"
        static let whatPulls = "what_pulls"
        static let holds = "holds"
        static let strains = "strains"
        static let silent = "silent"

        static let continuity = "continuity"
        static let questions = "questions"
        static let cites = "cites"
        static let question = "question"

        static let reader = "reader"
        static let reports = "reports"
        /// The reader entry's own `kind` — not `DiagnosticKind`, which is the
        /// section itself.
        static let readerKind = "kind"
        static let report = "report"
        static let dreamBreak = "dream_break"
        static let belief = "belief"

        static let facts = "facts"
        static let candidates = "candidates"
        static let subject = "subject"
        static let fact = "fact"

        /// Every paragraph reference travels here, in every section.
        static let refs = "refs"
    }

    /// What one turn yielded under the v2 contract.
    ///
    /// `conformance` is the summary the pane leads with — every clause the run
    /// checked, held or strained or silent. `accepted` is what the writer
    /// reads as notes; a clause that holds produces no note, and a fact
    /// candidate never becomes one.
    struct SectionedOutcome: Equatable {
        let accepted: [Diagnostic]
        let facts: [BibleFact]
        let conformance: [ClauseStatus]
        /// Entries discarded on their own merits: a dangling ref, an empty
        /// body, an unknown status, a leaked id, a fix in place of an
        /// observation. Reported so a run can say it lost something without
        /// failing (`CompilerRun.droppedDangling`).
        let droppedDangling: Int
        /// Reader reports past the schema's cap of three. **Counted apart from
        /// `droppedDangling` deliberately**: the model over-reporting is not a
        /// run that lost something, and the register the writer reads must not
        /// say it did. The run record may carry it; the register never shows
        /// it.
        let truncatedReader: Int

        static let empty = SectionedOutcome(
            accepted: [], facts: [], conformance: [], droppedDangling: 0, truncatedReader: 0)
    }

    /// One section's contribution has exactly the shape of a whole turn's —
    /// that is what makes `parseAll` a fold, and it is why there is one
    /// spelling of the accumulation rather than two that can drift.
    typealias PartialSection = SectionedOutcome

    /// One clause the run checked, and how it fared. Every check becomes one
    /// of these whatever it says; only `strains` also becomes a note.
    struct ClauseStatus: Equatable, Codable, Sendable {
        /// The writer's own sentence, quoted — never a summary of it.
        let clauseQuote: String
        /// `holds` / `strains` / `silent`, and nothing else: an entry with any
        /// other status is dropped rather than shown under a word the pane
        /// has no glyph for.
        let status: String
        let refs: [Diagnostic.Ref]
    }

    // MARK: - Parsing

    /// Parse one section object. Returns `nil` for a line that is not a
    /// section at all — prose, a fence marker, a truncated object, or a
    /// section name this build has never heard of (forward tolerance: a later
    /// contract's fifth section must not cost the four this one knows).
    ///
    /// Tolerant of what surrounds the object, the way v1 is: a fenced or
    /// narrated line still parses. Given a whole turn it reads only the FIRST
    /// section in it — `parseAll` is the whole-turn entry point.
    static func parseSection(
        line: String, runId: String, docId: String,
        liveParagraphText: (String) -> String?
    ) -> PartialSection? {
        guard let object = sectionObject(in: line),
              let name = nonEmptyString(object[SectionField.section])?.lowercased()
        else { return nil }

        switch name {
        case SectionField.conformance:
            return parseConformance(object, runId: runId, docId: docId, live: liveParagraphText)
        case SectionField.continuity:
            return parseContinuity(object, runId: runId, docId: docId, live: liveParagraphText)
        case SectionField.reader:
            return parseReader(object, runId: runId, docId: docId, live: liveParagraphText)
        case SectionField.facts:
            return parseFacts(object, docId: docId, live: liveParagraphText)
        default:
            return nil
        }
    }

    /// Parse a whole turn: every JSON object in the text, folded through
    /// `parseSection`. Returns `nil` only when not one section could be read,
    /// because there is then nothing to salvage (v1's rule).
    static func parseAll(
        resultText: String, runId: String, docId: String,
        liveParagraphText: (String) -> String?
    ) -> SectionedOutcome? {
        let sections = objectSpans(in: resultText).compactMap {
            parseSection(
                line: $0, runId: runId, docId: docId, liveParagraphText: liveParagraphText)
        }
        guard !sections.isEmpty else { return nil }
        return sections.reduce(.empty, combining)
    }

    /// The fold's one step. `internal` because the orchestrator accumulates
    /// the same way when sections arrive one at a time.
    static func combining(
        _ accumulated: SectionedOutcome, _ next: SectionedOutcome
    ) -> SectionedOutcome {
        SectionedOutcome(
            accepted: accumulated.accepted + next.accepted,
            facts: accumulated.facts + next.facts,
            conformance: accumulated.conformance + next.conformance,
            droppedDangling: accumulated.droppedDangling + next.droppedDangling,
            truncatedReader: accumulated.truncatedReader + next.truncatedReader)
    }

    // MARK: - Sections

    private static func parseConformance(
        _ object: [String: Any], runId: String, docId: String, live: (String) -> String?
    ) -> PartialSection {
        var statuses: [ClauseStatus] = []
        var notes: [Diagnostic] = []
        var dropped = 0

        for entry in object[SectionField.checks] as? [Any] ?? [] {
            guard let item = entry as? [String: Any],
                  let quote = nonEmptyString(item[SectionField.clauseQuote]),
                  let status = nonEmptyString(item[SectionField.status])?.lowercased(),
                  [SectionField.holds, SectionField.strains, SectionField.silent].contains(status)
            else {
                dropped += 1
                continue
            }

            let whatPulls = nonEmptyString(item[SectionField.whatPulls])
            guard !leaksAnId([quote, whatPulls], live),
                  !isFixShaped(whatPulls)
            else {
                dropped += 1
                continue
            }

            guard let resolved = resolveRefs(item[SectionField.refs], live) else {
                dropped += 1
                continue
            }
            statuses.append(
                ClauseStatus(clauseQuote: quote, status: status, refs: resolved.refs))

            guard status == SectionField.strains else { continue }
            // A strain with nothing to say keeps its status — "this clause
            // strains" is still true — but the note it owed is counted lost.
            guard let whatPulls else {
                dropped += 1
                continue
            }
            notes.append(
                Diagnostic(
                    id: ULID.generate(), docId: docId, anchor: resolved.anchor, body: whatPulls,
                    category: nil, runId: runId, kind: .conformanceStrain, refs: resolved.refs,
                    clauseQuote: quote))
        }

        return PartialSection(
            accepted: notes, facts: [], conformance: statuses, droppedDangling: dropped,
            truncatedReader: 0)
    }

    private static func parseContinuity(
        _ object: [String: Any], runId: String, docId: String, live: (String) -> String?
    ) -> PartialSection {
        var notes: [Diagnostic] = []
        var dropped = 0

        for entry in object[SectionField.questions] as? [Any] ?? [] {
            let cites = nonEmptyString((entry as? [String: Any])?[SectionField.cites])
            guard let item = entry as? [String: Any],
                  let question = nonEmptyString(item[SectionField.question]),
                  !leaksAnId([question, cites], live),
                  !isFixShaped(question),
                  let resolved = resolveRefs(item[SectionField.refs], live)
            else {
                dropped += 1
                continue
            }
            notes.append(
                Diagnostic(
                    id: ULID.generate(), docId: docId, anchor: resolved.anchor, body: question,
                    category: nil, runId: runId, kind: .continuity, refs: resolved.refs,
                    clauseQuote: cites))
        }

        return PartialSection(
            accepted: notes, facts: [], conformance: [], droppedDangling: dropped,
            truncatedReader: 0)
    }

    private static func parseReader(
        _ object: [String: Any], runId: String, docId: String, live: (String) -> String?
    ) -> PartialSection {
        var notes: [Diagnostic] = []
        var dropped = 0

        for entry in object[SectionField.reports] as? [Any] ?? [] {
            guard let item = entry as? [String: Any],
                  let report = nonEmptyString(item[SectionField.report]),
                  !leaksAnId([report], live),
                  !isFixShaped(report),
                  let resolved = resolveRefs(item[SectionField.refs], live)
            else {
                dropped += 1
                continue
            }
            let kind = nonEmptyString(item[SectionField.readerKind])?.lowercased()
            notes.append(
                Diagnostic(
                    id: ULID.generate(), docId: docId, anchor: resolved.anchor, body: report,
                    category: [SectionField.dreamBreak, SectionField.belief].contains(kind ?? "")
                        ? kind : nil,
                    runId: runId, kind: .readerReport, refs: resolved.refs, clauseQuote: nil))
        }

        // The cap the schema asks for, enforced here because the section is
        // the unit that arrives. A model that splits its reports across two
        // reader lines has already left the contract; the cap does not chase
        // it, and the run record's count is what says so.
        let truncated = max(0, notes.count - readerReportCap)
        return PartialSection(
            accepted: Array(notes.prefix(readerReportCap)), facts: [], conformance: [],
            droppedDangling: dropped, truncatedReader: truncated)
    }

    /// The schema's "at most 3 entries — the sharpest three".
    static let readerReportCap = 3

    private static func parseFacts(
        _ object: [String: Any], docId: String, live: (String) -> String?
    ) -> PartialSection {
        var facts: [BibleFact] = []
        var dropped = 0
        let recordedAt = Date()

        for entry in object[SectionField.candidates] as? [Any] ?? [] {
            guard let item = entry as? [String: Any],
                  let subject = nonEmptyString(item[SectionField.subject]),
                  let fact = nonEmptyString(item[SectionField.fact]),
                  !leaksAnId([subject, fact], live),
                  let resolved = resolveRefs(item[SectionField.refs], live)
            else {
                dropped += 1
                continue
            }
            // The register scrub does NOT apply here: "Kelly should have been
            // at the dock" is a claim about the story, not advice to the
            // writer, and a fact never reaches the pane as a note anyway.
            facts.append(
                BibleFact(
                    id: ULID.generate(), subject: subject, fact: fact,
                    establishedAt: resolved.refs.first?.paragraphId, docId: docId,
                    recordedAt: recordedAt))
        }

        return PartialSection(
            accepted: [], facts: facts, conformance: [], droppedDangling: dropped,
            truncatedReader: 0)
    }

    // MARK: - Refs

    private struct ResolvedRefs {
        let refs: [Diagnostic.Ref]
        /// The first ref, as an anchor carrying the paragraph's WHOLE live
        /// text — `DiagnosticsStore.live`'s exact-match staleness rule reads
        /// this, and an excerpt would never match.
        let anchor: Diagnostic.Anchor?
    }

    /// Resolve an entry's `refs`. `nil` means the entry claimed references and
    /// not one of them named a paragraph the document still has — v1's
    /// dangling-id disposal, at entry granularity. An entry that claims none
    /// resolves to no refs and no anchor, which is valid: the schema's own
    /// escape hatch for a note about the delta rather than one paragraph.
    private static func resolveRefs(
        _ value: Any?, _ live: (String) -> String?
    ) -> ResolvedRefs? {
        let raw = value as? [Any] ?? []
        var refs: [Diagnostic.Ref] = []
        var anchor: Diagnostic.Anchor? = nil

        for element in raw {
            guard let spelling = element as? String,
                  let resolved = resolve(spelling, live)
            else { continue }
            refs.append(
                Diagnostic.Ref(paragraphId: resolved.paragraphId, excerpt: excerpt(of: resolved.text)))
            if anchor == nil {
                anchor = Diagnostic.Anchor(
                    paragraphId: resolved.paragraphId, anchorText: resolved.text)
            }
        }

        if !raw.isEmpty && refs.isEmpty { return nil }
        return ResolvedRefs(refs: refs, anchor: anchor)
    }

    /// How many words of a paragraph stand in for it on the pane.
    static let excerptWordLimit = 8

    /// The head of a paragraph, as it reads right now. Anchors are stripped
    /// through the one shared transform (CLAUDE.md: no target-local copy) —
    /// this is text a writer reads, and it is the reason the pane never has to
    /// print an id.
    private static func excerpt(of text: String) -> String {
        let words = MarkdownDisplayFilter.stripAnchors(text)
            .split(whereSeparator: { $0.isWhitespace })
        let head = words.prefix(excerptWordLimit).joined(separator: " ")
        return words.count > excerptWordLimit ? head + "\u{2026}" : head
    }

    // MARK: - The id-scrub

    /// Does any of this entry's prose name a paragraph the document knows?
    ///
    /// **The boundary, stated.** A token is read as a leaked id when it
    /// resolves against live text AND is either decorated the way the prompt
    /// prints ids (`[a1b2]`, `¶a1b2`) or carries a digit. A bare, all-letter,
    /// four-character token that merely happens to be a live id is read as the
    /// English word it looks like — because it usually is one. Ids are four
    /// characters over a 32-symbol alphabet that includes the letters, so in a
    /// document of a few hundred paragraphs the odds that some id spells
    /// "they" or "that" are not small, and refusing every note containing that
    /// word would delete good work over a coincidence the writer could never
    /// diagnose. The leak this misses is narrow: a model that leaks an id
    /// leaks one the prompt showed it in brackets, and roughly four in five
    /// minted ids carry a digit regardless.
    private static func leaksAnId(_ prose: [String?], _ live: (String) -> String?) -> Bool {
        prose.compactMap { $0 }.contains { namesALiveParagraph($0, live) }
    }

    private static let idDecoration = CharacterSet(charactersIn: "[]()\u{00b6}#")
    private static let tokenTrim = CharacterSet(charactersIn: "[]()<>{}\u{00b6}#.,;:!?\"'\u{2018}\u{2019}\u{201c}\u{201d}")

    private static func namesALiveParagraph(
        _ prose: String, _ live: (String) -> String?
    ) -> Bool {
        for rawToken in prose.split(whereSeparator: { $0.isWhitespace }) {
            let token = String(rawToken).trimmingCharacters(in: tokenTrim)
            guard token.count == 4, live(token) != nil else { continue }
            let decorated = rawToken.unicodeScalars.contains { idDecoration.contains($0) }
            if decorated || token.contains(where: { $0.isNumber }) { return true }
        }
        return false
    }

    // MARK: - The register

    /// Second-person directives and explicit suggestions — the shapes a fix
    /// takes when a model writes one into a field meant for an observation.
    ///
    /// **Deliberately small, and deliberately not a classifier.** The
    /// structural enforcement is the schema, which has no field for a fix at
    /// all; this catches the model that ignores it. The list only matches
    /// prose aimed AT the writer, so "Should she already know?" — a question,
    /// which is exactly the register the contract asks for — survives, and so
    /// does any observation naming the same problem without prescribing.
    /// Applied only to model-authored prose: never to `clause_quote` or
    /// `cites`, which are the writer's own sentences quoted back, and never to
    /// a fact.
    static let fixShapedMarkers = [
        "you should", "you could", "you might want", "you may want", "you'll want",
        "you want to", "you need to", "i'd suggest", "i suggest", "i would suggest",
        "i'd recommend", "i recommend", "my suggestion", "suggested fix",
        "consider cutting", "consider adding", "consider rewriting", "try cutting",
        "try rewriting", "try moving",
    ]

    private static func isFixShaped(_ prose: String?) -> Bool {
        guard let prose else { return false }
        // Smart typography reaches the model's output too, so a curly
        // apostrophe must not be a way past the list.
        let normalized = prose.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return fixShapedMarkers.contains { normalized.contains($0) }
    }

    // MARK: - JSON extraction

    /// The first complete JSON object in `text` that names a section.
    private static func sectionObject(in text: String) -> [String: Any]? {
        for span in objectSpans(in: text) {
            guard let data = span.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  dictionary[SectionField.section] is String
            else { continue }
            return dictionary
        }
        return nil
    }

    /// Every top-level `{...}` span in `text`, brace-balanced and
    /// string-aware.
    ///
    /// This is what makes the four-lines contract tolerant without a second
    /// parser: for output that honours it, each line is exactly one span; for
    /// a model that fences, the fence markers hold no braces; for one that
    /// pretty-prints, the objects are still there across the newlines it
    /// added. A truncated final object never balances and is simply not a
    /// span, which is the same disposal v1 gives truncated JSON.
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
