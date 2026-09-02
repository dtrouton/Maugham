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

/// Reads `CompilerPrompt.sectionSchemaDescription`'s six sections. Two rules
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

        /// The fifth section (M3-P3 Task 4) — the round's verdict on whether
        /// the draft has drifted from the declared intent. Nothing to do with
        /// `DriftDetector`, which is M2's clause-strain pattern across run
        /// records; the wire word is `intent_drift` and the app word for the
        /// pattern is `drift`, and neither may be spelled the other's way.
        static let intentDrift = "intent_drift"
        static let verdict = "verdict"
        /// `holds` is shared with a conformance check's status — the same
        /// English word for the same shape of answer, on purpose. Its
        /// opposite here is `drifted`, and there is no third value: an
        /// unrecognised word reads as no verdict at all.
        static let drifted = "drifted"
        /// The model's one sentence of explanation, asked for and DROPPED —
        /// see `parseIntentDrift`. Named here because the parser reads it, and
        /// everything the parser reads has to be something the prompt asks
        /// for (`test_v2FieldNamesComeFromTheSectionSchema`).
        static let driftNote = "note"

        /// The sixth section (editorial letter P1 Task 2): an editorial
        /// letter about the reading as a whole. Its parts are prose the
        /// writer reads rather than findings the writer disposes of — except
        /// `questions`, which is both, and which shares its wire name with
        /// the continuity section's array on purpose: it is the same word for
        /// the same shape of answer, read out of a different object.
        static let letter = "letter"
        /// The letter's answer to what the writer asked this round (P2
        /// Task 3). FIRST in the letter's schema line, because it is the
        /// first thing the model is told to write — a question the writer
        /// typed is answered before the reading it prompted.
        static let answer = "answer"
        static let about = "about"
        static let oneThing = "one_thing"
        static let working = "working"
        static let what = "what"
        static let why = "why"
        static let habits = "habits"
        /// The habit's own `name` — spelled `habitName` here because
        /// `SectionField.name` beside `SectionField.section` would read as the
        /// section's name, which is a different thing entirely.
        static let habitName = "name"
        static let cost = "cost"
        static let lesson = "lesson"
        static let exercise = "exercise"
        /// The lessons-ledger heading a letter question was raised under (P2
        /// Task 4) — a key of the QUESTION entry, not of the letter, and
        /// spelled singular where `habits` beside it is the array of habits
        /// the letter raised. It is the model echoing back a heading it was
        /// briefed on; whether it names one is decided app-side
        /// (`LessonsLedger.matches`, global constraint 15).
        static let habit = "habit"
        static let scenes = "scenes"
        static let wants = "wants"
        static let changes = "changes"
        static let turn = "turn"
        static let charge = "charge"
        /// The two values `charge` admits. Named, on `holds`/`dreamBreak`'s
        /// rule: an enumerated value the parser matches against is part of the
        /// contract, so it has to be a value the prompt asked for.
        static let chargePositive = "+"
        static let chargeNegative = "-"

        /// The briefed lessons this reading found no instance of (P2 Task 4)
        /// — a key of the LETTER, last in its schema line, because it is a
        /// statement about the reading as a whole rather than a part of it.
        static let retired = "retired"

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
        /// The round's verdict on intent drift: `holds`, `drifted`, or `nil`
        /// for a turn that did not answer the fifth section (a four-section
        /// v2 answer, and every answer this build streamed before the drift
        /// line arrived). Never a `Diagnostic`: it has no anchor, no id and
        /// no reply — it is a projection onto `CompilerRun.intentDriftVerdict`
        /// and is never re-encoded, which is why an unrecognised word becomes
        /// `nil` here rather than an `unknown` case.
        let intentDriftVerdict: String?
        /// The sixth section's letter, or `nil` for a turn that did not
        /// answer it (Task 1 only — no section parses one yet, so every
        /// production caller passes `nil`; Task 2 wires the parse).
        let letter: Letter?

        static let empty = SectionedOutcome(
            accepted: [], facts: [], conformance: [], droppedDangling: 0, truncatedReader: 0,
            intentDriftVerdict: nil, letter: nil)

        /// **What stays in the sidecar: conformance strains, and only them**
        /// (M4 P1 Task 3).
        ///
        /// A strain is measured against a clause the writer declared, and it is
        /// read next to that clause's own row — it is part of the report, not a
        /// finding about the prose that outlives the run. Continuity questions
        /// and the reader's reports are the opposite: they are about the words,
        /// they survive the next check, and the writer answers them where every
        /// other note about their prose lives. So they leave here for the
        /// annotation layer (`mintable`), and **one finding has one home**.
        var sidecarDiagnostics: [Diagnostic] {
            accepted.filter { $0.kind == .conformanceStrain }
        }

        /// The other half of the same split: what the run mints as annotations.
        /// Built from the accepted diagnostics rather than parsed a second
        /// time, so the anchor, the register scrub and the dangling-ref
        /// disposal are all the ones the ingest already applied.
        var mintable: [CompilerNote] {
            accepted.compactMap(CompilerNote.init(diagnostic:))
        }
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
    /// contract's sixth section must not cost the five this one knows — which
    /// is exactly what let M3-P3's `intent_drift` land, harmlessly ignored, on
    /// a build that had never heard of it).
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
        case SectionField.intentDrift:
            return parseIntentDrift(object)
        case SectionField.letter:
            return parseLetter(object, runId: runId, docId: docId, live: liveParagraphText)
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
            truncatedReader: accumulated.truncatedReader + next.truncatedReader,
            // The one field that is not a sum: the latest non-nil wins. A
            // stream folds the sections one at a time in whatever order they
            // arrive, and every section but one carries no verdict — so `next`
            // alone would erase a verdict already folded in, and `accumulated`
            // alone would ignore a model that restated the section.
            intentDriftVerdict: next.intentDriftVerdict ?? accumulated.intentDriftVerdict,
            // Same rule as `intentDriftVerdict`, for the same reason: exactly
            // one section carries a letter, so last-non-nil-wins is
            // indistinguishable from "the one section that had it" in
            // practice, and stays correct if a model ever restates it.
            letter: next.letter ?? accumulated.letter)
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
            truncatedReader: 0, intentDriftVerdict: nil, letter: nil)
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
            truncatedReader: 0, intentDriftVerdict: nil, letter: nil)
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
            droppedDangling: dropped, truncatedReader: truncated, intentDriftVerdict: nil,
            letter: nil)
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
            // The establishing paragraph travels as BOTH its id and its words:
            // the id is what a jump would need, the excerpt is what the pane
            // prints (requirement 3 — the caption never says ¶anything). The
            // live text is resolvable here and nowhere downstream, so throwing
            // it away is what left the stratum with an id to render.
            facts.append(
                BibleFact(
                    id: ULID.generate(), subject: subject, fact: fact,
                    establishedAt: resolved.refs.first?.paragraphId,
                    excerpt: resolved.refs.first?.excerpt, docId: docId,
                    recordedAt: recordedAt))
        }

        return PartialSection(
            accepted: [], facts: facts, conformance: [], droppedDangling: dropped,
            truncatedReader: 0, intentDriftVerdict: nil, letter: nil)
    }

    /// **The fifth section: one verdict, and nothing the writer reads**
    /// (M3-P3 Task 4).
    ///
    /// Three things this does not do, each a decision:
    ///
    /// - **It mints no `Diagnostic`.** v1 raised drift as an anchorless note
    ///   with an id, a dismissal and a reply field; a judgement about the whole
    ///   reading has nothing to anchor to and nothing to answer. The verdict
    ///   rides `CompilerRun.intentDriftVerdict` and is drawn from there.
    /// - **It counts nothing as dropped.** `droppedDangling` is what the
    ///   REGISTER lost — entries the writer would have read. An unusable
    ///   verdict costs the register nothing, and reporting it as a loss would
    ///   put the pane's "lost some notes" seal over a complete report.
    /// - **It admits no third value.** `holds` and `drifted`, or `nil`. There
    ///   is no `unknown` case because the verdict is a projection this build
    ///   never re-encodes (tripwire 12's discipline read in the direction that
    ///   applies): a word we cannot draw must not reach a surface that has no
    ///   glyph for it, and a later contract widening the vocabulary is an
    ///   additive change on both sides.
    private static func parseIntentDrift(_ object: [String: Any]) -> PartialSection {
        // **The model's sentence is read here and dropped here.** ADR 0027:
        // nothing model-produced renders in the editor's chrome, and the mark
        // this verdict raises is app-authored from the verdict alone — so
        // there is nowhere for a sentence of the model's own to go.
        //
        // Read rather than left unmentioned, for two reasons. The drop is a
        // decision, and a decision belongs at the site that makes it rather
        // than in the absence of a line. And `driftNote` is a name the parser
        // uses, which is what earns it a place in the schema census
        // (`test_v2FieldNamesComeFromTheSectionSchema`) — a field nothing
        // reads has no business being asserted against the prompt.
        _ = nonEmptyString(object[SectionField.driftNote])

        let spoken = nonEmptyString(object[SectionField.verdict])?.lowercased()
        let verdict = [SectionField.holds, SectionField.drifted].contains(spoken ?? "")
            ? spoken : nil

        return PartialSection(
            accepted: [], facts: [], conformance: [], droppedDangling: 0,
            truncatedReader: 0, intentDriftVerdict: verdict, letter: nil)
    }

    // MARK: - The sixth section: the letter

    /// **The letter (editorial letter P1 Task 2, spec §3.1/§3.2).** An
    /// editorial letter about the manuscript as a whole, parsed into
    /// `PartialSection.letter` — prose the writer reads rather than findings
    /// the writer disposes of.
    ///
    /// Four rules this section does not share with the five above it:
    ///
    /// - **A dangling ref costs the entry its jump links and nothing else**
    ///   (`letterRefs`). A habit is still true when one of its instances was
    ///   rewritten.
    /// - **`droppedDangling` never moves here.** It counts what the REGISTER
    ///   lost — notes the writer would have read — and the letter is not a
    ///   note. A cap does not move it either: a model that wrote four habits
    ///   has lost the writer nothing, and the pane's "lost some notes" seal
    ///   must not appear over a complete report.
    /// - **A missing `about` is not a refusal.** The say-back is the schema's
    ///   one always-present part, and a letter without it is still a letter;
    ///   an object with not ONE recognised key is `nil`, because that is a
    ///   model that answered the line without writing anything.
    /// - **`scenes` absent or `null` is `nil`, not `[]`** — the position said
    ///   there is nothing to say about scenes (a lyric piece), which is a
    ///   different answer from a table with no rows.
    ///
    /// **Two scrubs, and they are asked of different things.** Every prose
    /// field of every part is scrubbed for a leaked paragraph id, and only
    /// `questions` is scrubbed for a fix's shape — `letterProseLeaksAnId`'s
    /// doc carries both reasons, including why `exercise` is exempt from the
    /// second. Neither moves `droppedDangling`.
    ///
    /// The one part that is also a finding is `questions`: each one that
    /// resolves at least one ref ALSO becomes a `.letterQuestion` diagnostic
    /// in `accepted`, so it rides `mintable` into the queue as a `.query` and
    /// stays out of `sidecarDiagnostics`. One with no surviving ref is
    /// letter-only: a `.query` cannot be minted without a paragraph, and a
    /// fingerprint needs an anchor or a clause.
    private static func parseLetter(
        _ object: [String: Any], runId: String, docId: String, live: (String) -> String?
    ) -> PartialSection {
        let recognised = [
            SectionField.answer, SectionField.about, SectionField.oneThing,
            SectionField.working, SectionField.habits, SectionField.questions,
            SectionField.scenes, SectionField.retired,
        ]
        guard recognised.contains(where: { object[$0] != nil }) else {
            return PartialSection(
                accepted: [], facts: [], conformance: [], droppedDangling: 0,
                truncatedReader: 0, intentDriftVerdict: nil, letter: nil)
        }

        let working: [Letter.Working] = entries(object[SectionField.working])
            .compactMap { item in
                guard let what = nonEmptyString(item[SectionField.what]),
                      let why = nonEmptyString(item[SectionField.why]),
                      !letterProseLeaksAnId([what, why], live)
                else { return nil }
                return Letter.Working(
                    refs: letterRefs(item[SectionField.refs], live).refs, what: what, why: why)
            }

        let raisedHabits: [Letter.Habit] = entries(object[SectionField.habits])
            .compactMap { item in
                guard let name = nonEmptyString(item[SectionField.habitName]),
                      let cost = nonEmptyString(item[SectionField.cost])
                else { return nil }
                let lesson = nonEmptyString(item[SectionField.lesson])
                // **`exercise` is scrubbed for a leaked id like every other
                // field, and NOT for a fix's shape** — see
                // `letterProseLeaksAnId`'s doc for why the second scrub stops
                // at `questions`.
                let exercise = nonEmptyString(item[SectionField.exercise])
                guard !letterProseLeaksAnId([name, cost, lesson, exercise], live)
                else { return nil }
                return Letter.Habit(
                    name: name,
                    refs: Array(letterRefs(item[SectionField.refs], live)
                        .refs.prefix(letterHabitRefsCap)),
                    cost: cost, lesson: lesson, exercise: exercise)
            }

        // **Capped HERE, above the questions loop, rather than at the `Letter`
        // below.** The cap is what decides which habits this letter HAS, and a
        // question is stamped only with one of them (next paragraph) — take
        // the names off the uncapped list and a third habit's heading could
        // stamp a question about a habit the letter never shows.
        let habits = Array(raisedHabits.prefix(letterHabitsCap))

        // **Read after the habits, because a citation is checked against
        // them** (global constraint 15). The model was briefed on the ledger
        // and echoes a heading back; nothing here trusts that spelling to
        // address the writer's file, so a question is stamped only where its
        // `habit` names a habit THIS letter raised — a near-miss stamps
        // nothing rather than the wrong ledger row.
        //
        // **Matched on the NAME, stamped with the `ledgerHeading`.** The name
        // is what the schema asks the model to cite, so it is what a citation
        // is checked against; the heading is what the ledger knows the habit
        // by, and it is the one thing a surface may file (`Letter.Habit`'s
        // own doc). Stamping the name instead put one habit in the writer's
        // ledger under two identities — the queue's choice under the name,
        // the letter's Keep under the lesson sentence.

        var questions: [Letter.Question] = []
        var notes: [Diagnostic] = []
        for item in entries(object[SectionField.questions]) {
            guard questions.count < letterQuestionsCap,
                  let question = nonEmptyString(item[SectionField.question]),
                  !letterProseLeaksAnId([question], live),
                  // **The one part that also mints, and the one the fix-shape
                  // scrub is asked of.** A `.letterQuestion` reaches the queue
                  // as a `.query` the writer is asked to answer, and "you
                  // should cut this" is not a question they can answer — it is
                  // the suggested change the register exists to refuse.
                  !isFixShaped(question)
            else { continue }
            let resolved = letterRefs(item[SectionField.refs], live)
            // No id-leak scrub of its own: what survives is one habit's own
            // `name` or `lesson`, and both were scrubbed as the habit was
            // parsed. Anything else — including a heading with an id in it —
            // matches nothing and resolves to nil.
            let raisedUnder = nonEmptyString(item[SectionField.habit]).flatMap { cited in
                habits.first { LessonsLedger.matches(cited, heading: $0.name) }?
                    .ledgerHeading
            }
            questions.append(
                Letter.Question(
                    refs: resolved.refs, question: question, lessonHeading: raisedUnder))
            guard let anchor = resolved.anchor else { continue }
            var note = Diagnostic(
                id: ULID.generate(), docId: docId, anchor: anchor, body: question,
                category: nil, runId: runId, kind: .letterQuestion, refs: resolved.refs,
                clauseQuote: nil)
            // The same heading on both halves of what this loop produces: the
            // letter's own question, which the letter section draws, and the
            // note that becomes a `.query` in the queue. A stamp on one and not
            // the other is two surfaces disagreeing about the same question.
            note.lessonHeading = raisedUnder
            notes.append(note)
        }

        let scenes: [Letter.Scene]? = (object[SectionField.scenes] as? [Any]).map { raw in
            raw.compactMap { entry -> Letter.Scene? in
                guard let item = entry as? [String: Any] else { return nil }
                let wants = nonEmptyString(item[SectionField.wants]) ?? ""
                let changes = nonEmptyString(item[SectionField.changes]) ?? ""
                let turn = nonEmptyString(item[SectionField.turn]) ?? ""
                // **A blank cell is an observation, and so is a row of them**
                // (spec §3.4). Le Guin's letter may ask "nothing shifts here
                // that I can see; is that the point?" — a scene the model
                // could say nothing at all about is the sharpest form of that,
                // and its refs are what the writer clicks to go and read it.
                // This carried a guard dropping such a row; the spec says
                // otherwise and the guard is gone.
                guard !letterProseLeaksAnId([wants, changes, turn], live)
                else { return nil }
                let charge = nonEmptyString(item[SectionField.charge])
                return Letter.Scene(
                    refs: letterRefs(item[SectionField.refs], live).refs,
                    wants: wants, changes: changes, turn: turn,
                    charge: [SectionField.chargePositive, SectionField.chargeNegative]
                        .contains(charge ?? "") ? charge : nil)
            }
        }

        // **`about` and `one_thing` are FIELDS, not entries, so a leaked id
        // empties them rather than dropping anything.** There is no entry to
        // lose, and refusing the whole letter over one token in the say-back
        // would cost the writer everything the letter got right — the opposite
        // of the rule that a letter is never refused for a missing say-back.
        let about = nonEmptyString(object[SectionField.about])
        let oneThing = nonEmptyString(object[SectionField.oneThing])
        // **`answer` is a field on the same terms** (P2 Task 3), so a leaked
        // id empties it and costs the writer nothing else. It empties to
        // `nil` rather than `""` like `about`, because the letter's answer is
        // optional where the say-back is not: an empty string here would draw
        // an answer section with nothing in it.
        let answer = nonEmptyString(object[SectionField.answer])

        // **Entries, not a field**: a heading carrying a leaked paragraph id
        // costs that heading and leaves the rest of the list intact, the way a
        // working entry or a habit is dropped alone. Nothing is matched to the
        // writer's ledger here — resolving a heading to a row the app may
        // rewrite is the offer's job at the point of the write (global
        // constraint 15), and a heading that names nothing simply draws no
        // offer.
        let retired = (object[SectionField.retired] as? [Any] ?? [])
            .compactMap { nonEmptyString($0) }
            .filter { !letterProseLeaksAnId([$0], live) }

        let letter = Letter(
            about: letterProseLeaksAnId([about], live) ? "" : (about ?? ""),
            oneThing: letterProseLeaksAnId([oneThing], live) ? nil : oneThing,
            working: Array(working.prefix(letterWorkingCap)),
            habits: habits,
            questions: questions,
            scenes: scenes,
            scenePosition: nil,
            answer: letterProseLeaksAnId([answer], live) ? nil : answer,
            // Stamped at `record` from the run rather than read off the wire:
            // what was ASKED is the app's own fact, and a model echoing it
            // back would be the letter telling us what we told it.
            asked: nil,
            // Absent stays absent, so a letter that said nothing about
            // retirement does not decode as one that retired nothing —
            // indistinguishable downstream (`retiredHeadings`), and the
            // distinction costs nothing to keep.
            retired: object[SectionField.retired] == nil
                ? nil : Array(retired.prefix(letterRetiredCap)))

        return PartialSection(
            accepted: notes, facts: [], conformance: [], droppedDangling: 0,
            truncatedReader: 0, intentDriftVerdict: nil, letter: letter)
    }

    /// The schema's caps on the letter's parts, enforced at ingest the way
    /// `readerReportCap` is, because the section is the unit that arrives.
    /// Extras are dropped and NOT counted — see `parseLetter`.
    static let letterWorkingCap = 3
    static let letterHabitsCap = 2
    static let letterHabitRefsCap = 4
    static let letterQuestionsCap = 3
    /// **The cap the schema does not state** (P2 Task 4), enforced here on
    /// `readerReportCap`'s rule all the same: a reading that retired everything
    /// it was briefed on is a reading that stopped looking, and the writer's
    /// ledger must not be emptied by one careless letter. Six is more open
    /// lessons than a ledger is meant to carry at once.
    static let letterRetiredCap = 6

    /// One array of section entries, as objects. A non-array, or an element
    /// that is not an object, is simply absent — the letter drops a malformed
    /// entry the way every section does, minus the counting.
    private static func entries(_ value: Any?) -> [[String: Any]] {
        (value as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    /// **Resolve one LETTER entry's refs — the one place `resolveRefs`'
    /// dangling rule is deliberately not applied** (spec §3.1, and global
    /// constraint 8).
    ///
    /// `resolveRefs` answers `nil` when an entry claimed references and not
    /// one of them resolved, and its callers drop that entry: a note IS a
    /// pointer at a paragraph, so a note pointing nowhere is nothing. A letter
    /// entry is the opposite kind of thing. A habit is a pattern across what
    /// was read and stays true when one of its instances has since been
    /// rewritten; what it loses is its jump links, not its meaning. So a
    /// letter entry whose refs all fail keeps its prose with `refs: []` — and
    /// its `anchor` is `nil`, which is what makes a letter question with no
    /// surviving ref letter-only rather than a note the mint would refuse.
    private static func letterRefs(
        _ value: Any?, _ live: (String) -> String?
    ) -> ResolvedRefs {
        resolveRefs(value, live) ?? ResolvedRefs(refs: [], anchor: nil)
    }

    /// **The id-scrub, asked of the letter's prose** — `leaksAnId` under a
    /// name that says where the answer is used, because what happens to a
    /// `true` here is not what happens to it anywhere else.
    ///
    /// The schema's standing rule is the letter's too: refer to the prose by a
    /// short quotation, the way an editor would, never by a four-character
    /// token. The letter is the part the writer READS, so it is the most
    /// visible place that rule could break. An entry whose prose names a live
    /// paragraph is dropped — and dropping is right here in a way it is not
    /// for a dangling ref: a dead ref costs an entry a jump link it can live
    /// without, while a leaked id is in the words themselves and there is no
    /// half of the entry worth showing. `about` and `one_thing` are fields
    /// rather than entries and are emptied instead; see `parseLetter`.
    ///
    /// **Neither this nor the fix-shape scrub touches `droppedDangling`.**
    /// That counter is what the REGISTER lost — notes the writer would have
    /// read — and the letter is not a note, so a scrubbed letter entry must
    /// not put the pane's "lost some notes" seal over a complete report. It is
    /// the same reason a letter's dangling ref does not move it.
    ///
    /// **The fix-shape scrub stops at `questions`, deliberately.** That is the
    /// one part that leaves the letter and becomes a `.query` the writer is
    /// asked to answer, and a directive is not answerable. `exercise` is
    /// exempt for the opposite reason: Le Guin's feed-forward is a thing to go
    /// and DO — *rewrite the scene without a single "was"* — and it is phrased
    /// as a directive because that is what an exercise IS (spec §3.1).
    /// Scrubbing it would delete the one part of the letter that teaches. The
    /// letter's other prose is exempt too: `fixShapedMarkers` is a small
    /// hand-written list, and pointed at everything it would refuse real
    /// sentences the writer only ever reads in place.
    private static func letterProseLeaksAnId(
        _ prose: [String?], _ live: (String) -> String?
    ) -> Bool {
        leaksAnId(prose, live)
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

        // A model that names the same paragraph twice gets one ref, not two.
        // The pane keys its chip `ForEach` on `paragraphId`, and SwiftUI's
        // behaviour on duplicate ids is undefined — so the deduplication
        // belongs here, at the boundary where the model's list becomes ours,
        // rather than at each surface that renders it. First spelling wins,
        // which keeps the order the run reported.
        var seen = Set<String>()
        for element in raw {
            guard let spelling = element as? String,
                  let resolved = resolve(spelling, live)
            else { continue }
            if anchor == nil {
                anchor = Diagnostic.Anchor(
                    paragraphId: resolved.paragraphId, anchorText: resolved.text)
            }
            guard seen.insert(resolved.paragraphId).inserted else { continue }
            refs.append(
                Diagnostic.Ref(paragraphId: resolved.paragraphId, excerpt: excerpt(of: resolved.text)))
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
