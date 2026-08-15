import CryptoKit
import Foundation
import MaughamCore

/// Assembles what a compiler run sends to the spawned Claude: the session's
/// one-time system preamble, and each run's message (delta + diffed-in
/// context + what the previous round raised + the output-shape instruction).
///
/// A pure function of its inputs — no I/O, no clock — so the prompt itself is
/// testable without a subprocess.
enum CompilerPrompt {

    /// The output contract: five line-delimited JSON objects, one per
    /// section, in fixed order (conformance, continuity, reader, facts,
    /// intent_drift). `DiagnosticIngestTests` reference this SAME constant,
    /// so prompt and parser cannot drift apart in a rewording.
    ///
    /// **`intent_drift` (M3-P3 Task 4) is the odd one and deliberately so.**
    /// The first four are things found IN the prose and each entry carries a
    /// `refs` array; the fifth is a verdict on the reading as a whole and
    /// carries none, because a judgement about the draft anchored to one
    /// paragraph is a judgement about that paragraph. Its `note` is asked for
    /// and thrown away at ingest — see `DiagnosticIngest.parseIntentDrift`.
    /// It shares nothing with M2's `DriftDetector`, which is a clause-strain
    /// PATTERN across run records and keeps its own meaning.
    ///
    /// No severity field, no suggestion field anywhere in this string —
    /// the register is enforced structurally, not by asking nicely
    /// (`test_theSchemaHasNowhereForYouShould`). References travel ONLY in
    /// each entry's `refs` array; prose never carries a bare paragraph id
    /// (`test_theSchemaForbidsIdsInProse`) — the enforcement with teeth is
    /// Task 2's ingest-side scrub, this is the instruction half.
    static let sectionSchemaDescription: String = """
        Respond with five lines, each one JSON object, in this exact order \
        — conformance, then continuity, then reader, then facts, then \
        intent_drift. Nothing else: no prose before, between, or after \
        them, and no line skipped — a section with nothing to report still \
        gets its line, with an empty array, and intent_drift always carries \
        a verdict:
        {"section":"conformance","checks":[{"clause_quote":<string>,"status":\
        "holds"|"strains"|"silent","refs":[<paragraph id>...],"what_pulls":\
        <string or null>}]}
        {"section":"continuity","questions":[{"cites":<string>,"refs":\
        [<paragraph id>...],"question":<string>}]}
        {"section":"reader","reports":[{"kind":"dream_break"|"belief","refs":\
        [<paragraph id>...],"report":<string>}]}
        {"section":"facts","candidates":[{"subject":<string>,"fact":<string>,\
        "refs":[<paragraph id>...]}]}
        {"section":"intent_drift","verdict":"holds"|"drifted","note":<one \
        sentence, only when drifted>}
        The last line answers one question about this reading as a whole: \
        has the draft drifted from the declared intent? Weigh the prose in \
        this run's delta against the intent declared above — holds when \
        the writing is still going where the writer said it was going, \
        drifted when it has moved away from what they declared. Judge the \
        draft, never the writer's decision to change their mind; if there \
        is no declared intent to measure against, the answer is holds. \
        Every reference to a paragraph travels in that entry's refs array, \
        copied exactly as the paragraph id appears above. Prose — \
        what_pulls, question, report, cites, and fact — never contains a \
        paragraph id: refer to the prose itself by a short quotation, the \
        way an editor would. clause_quote and cites are the writer's own \
        words, quoted, not summarized. what_pulls names what pulls \
        against the clause and stops there — never a fix. Every \
        continuity entry ends as a question, never a verdict. The reader \
        section holds at most 3 entries — the sharpest three, not every \
        dream-break you noticed.
        """

    /// Sent once, when the warm session is spawned — never repeated per run.
    static func sessionSystemPreamble(projectId: String) -> String {
        """
        You are reading a manuscript-in-progress as a close, tasteful \
        reader giving the writer near-live feedback while they are still \
        writing — two jobs in one pass, and neither of them is a critic's. \
        As continuity editor you check the wet ink against what the \
        writer has declared: their intent, their rules, and the facts \
        already established. As first reader you report what happens in \
        the reading itself: where the dream broke, what a reader believes \
        and when. Note the problem, never the solution; ask a question \
        rather than hand down a verdict. You are not a linter and you do \
        not rank your opinions — there are no severity levels. Give notes \
        worth reading: specific, concise, and grounded in what the prose \
        is actually doing against what the writer says they're going for. \
        Silence on a clause or a paragraph is a valid response; do not \
        manufacture a note to fill space.

        This session is long-lived: later messages will build on what \
        you've already read here. Each run gives you the wet ink since \
        the last run, the writer's declared world when they have one, and \
        the facts you've already read off the manuscript.

        Project: \(projectId)
        """
    }

    /// The run message: the declared world (essay + derived clauses/rules),
    /// the bible slice, the listings, the delta, and the section schema.
    ///
    /// The bible slice is rendered exactly as given — `bibleFacts` is the
    /// caller's job to compute (Task 3 slices by subjects the delta text
    /// mentions); this function only renders `subject: fact`, never a
    /// paragraph id, because a fact's `establishedAt` is an anchor for the
    /// pane's excerpt chip, not quotable prose this function has in hand.
    ///
    /// `briefingHash` covers essay + world + facts as ONE unit (the diff-in
    /// rule widened from v1's intent-only hash): unchanged since the last
    /// run's hash → a single marker line replaces all three; changed → all
    /// three re-embed together, never partially. `nil` when there is
    /// nothing declared at all (no essay, an empty or absent world, no
    /// facts) — an empty declared world is a valid, un-hashed state (spec
    /// §7: the conformance section is simply absent).
    ///
    /// `previousRound` is per-run state and is **never** part of that hash —
    /// see `roundSection`. Defaulted because "there is no previous round" is
    /// the ordinary answer (round 1 of a lane, a passless ⌘R, a fresh-eyes
    /// read) and because this function has exactly one production caller,
    /// `CompilerOrchestrator.beginRun`, which is where the lane rule is
    /// decided.
    static func runMessageV2(
        delta: CompilerDelta, world: DerivedWorld?, essay: String?,
        bibleFacts: [BibleFact], paletteListing: [String], pinnedListing: [String],
        previousRound: PriorRound? = nil,
        previousBriefingHash: String?
    ) -> (message: String, briefingHash: String?) {
        var sections: [String] = []

        let hash = briefingHashInput(essay: essay, world: world, bibleFacts: bibleFacts)
            .map(sha256Hex)
        if let hash, hash == previousBriefingHash {
            sections.append("Declared world and bible: unchanged since last run.")
        } else if hash != nil {
            if let essay, !essay.isEmpty {
                sections.append("Declared intent (essay):\n\(cleaned(essay))")
            }
            if let world, !(world.clauses.isEmpty && world.rules.isEmpty) {
                sections.append(worldSection(world))
            }
            if !bibleFacts.isEmpty {
                sections.append(bibleSection(bibleFacts))
            }
        }

        sections.append(
            contentsOf: listingSections(pinnedListing: pinnedListing, paletteListing: paletteListing))

        // Between the listings and the delta: context about the prose the
        // delta is about to show, rather than part of the standing briefing
        // above it or of the thing being checked below it.
        if let previousRound,
           let round = roundSection(
            previousRound: previousRound.record, notes: previousRound.notes) {
            sections.append(round)
        }

        sections.append(deltaSection(delta))

        sections.append(sectionSchemaDescription)

        return (sections.joined(separator: "\n\n"), hash)
    }

    // MARK: - v2 declared-world / bible sections

    private static func worldSection(_ world: DerivedWorld) -> String {
        var lines: [String] = ["Declared world — the writer's own sentences, and what checking each one means:"]
        for clause in world.clauses {
            lines.append("- \"\(cleaned(clause.quote))\" — \(clause.check)")
        }
        for rule in world.rules {
            lines.append("- \(rule.subject): \"\(cleaned(rule.quote))\" — \(rule.constraint)")
        }
        return lines.joined(separator: "\n")
    }

    private static func bibleSection(_ facts: [BibleFact]) -> String {
        var lines: [String] = ["Established so far:"]
        for fact in facts {
            lines.append("- \(fact.subject): \(cleaned(fact.fact))")
        }
        return lines.joined(separator: "\n")
    }

    /// The one place the v2 briefing hash's input is assembled, so the hash
    /// gate and the embed decision can never compute it two ways. `nil`
    /// when essay, world (empty counts as absent) and facts are ALL absent
    /// — nothing to diff in means no hash to track.
    private static func briefingHashInput(
        essay: String?, world: DerivedWorld?, bibleFacts: [BibleFact]
    ) -> String? {
        let essayEmpty = essay?.isEmpty ?? true
        let worldEmpty = world.map { $0.clauses.isEmpty && $0.rules.isEmpty } ?? true
        guard !essayEmpty || !worldEmpty || !bibleFacts.isEmpty else { return nil }

        var parts: [String] = ["essay:\(essay ?? "")"]
        if let world {
            parts.append(
                "clauses:" + world.clauses.map { "\($0.quote)|\($0.check)" }.joined(separator: ";"))
            parts.append(
                "rules:" + world.rules.map { "\($0.subject)|\($0.quote)|\($0.constraint)" }
                    .joined(separator: ";"))
        }
        parts.append("facts:" + bibleFacts.map { "\($0.subject)|\($0.fact)" }.joined(separator: ";"))
        return parts.joined(separator: "\n")
    }

    // MARK: - The previous round (M3-P3 §6)

    /// One note the previous round raised, as the next round's briefing sees
    /// it: what it said, which section said it, and whether the writer has
    /// been working behind it since.
    ///
    /// `kind` is the enum rather than its string, on tripwire 12's reasoning —
    /// the section a note came from is its whole classification, and a
    /// stringly-typed one here would be a second vocabulary to keep in step
    /// with `DiagnosticIngest.SectionField`.
    struct PriorNote {
        let body: String
        let kind: DiagnosticKind
        /// The paragraph this note was anchored to no longer reads as it did
        /// — `DiagnosticsStore.live`'s own anchor-text equality, asked at the
        /// keystroke. An anchorless note is never "since edited": it has
        /// nothing to track, exactly as it has nothing to go stale against.
        let sinceEdited: Bool
    }

    /// The previous round in this run's lane, with what it found.
    ///
    /// The record and the notes travel together because the section needs
    /// both halves and neither is derivable from the other: the round's
    /// identity lives on the record, and its prose lives only in the standing
    /// sidecar (`DiagnosticsStore.standingRound`).
    struct PriorRound {
        let record: RoundRecord
        let notes: [PriorNote]
    }

    /// **The partition the app knows and the model cannot**: the writer has
    /// rewritten the prose one of these notes was measured against, so the
    /// note may already be answered by the draft itself.
    static let sinceEditedHeading = "The writer has since edited the prose behind these:"

    /// Its complement — the prose still reads exactly as it did when the note
    /// landed, so anything that has changed is the reading, not the draft.
    static let untouchedHeading = "Untouched since that round:"

    /// **What the last round in this lane raised, so this one confirms rather
    /// than reconstructs** (spec §6, M3-P3 §6).
    ///
    /// `nil` — no section at all — in two cases, neither of them a round the
    /// model should hear about:
    ///
    /// - the record carries no lane, or no round number. The comparison lane
    ///   is `(document, pass)` and a passless run is an ordinary M2 run; this
    ///   is the second door on the room `CompilerOrchestrator` guards first.
    /// - the round raised no notes. There is nothing to confirm, and a
    ///   sentence saying so is a paragraph of prompt telling the model
    ///   nothing it can act on. What that round DID is still counted — the
    ///   pane's line reads the ring, not this.
    ///
    /// **It is never folded into `briefingHashInput`, and that is the whole
    /// reason it is assembled here rather than up there.** This section
    /// changes every single round by construction, so a hash covering it would
    /// never match its predecessor and the essay, the declared world and the
    /// bible slice would re-embed in full on every ⌘R — the diff-in the hash
    /// exists to make possible, undone by the one thing that can never be
    /// diffed. `CompilerPromptTests.test_theRoundSectionNeverFoldsIntoTheBriefingHash`
    /// asserts the hash is byte-identical across two rounds with unchanged
    /// intent.
    ///
    /// **No new answer section comes with it.** The model's confirmation rides
    /// the note sections it already answers in; what resolved and what
    /// persists is computed app-side from fingerprints (`RoundComparison`),
    /// never parsed back out of prose the model wrote.
    static func roundSection(previousRound: RoundRecord, notes: [PriorNote]) -> String? {
        guard let passId = previousRound.passId, let round = previousRound.round else {
            return nil
        }
        guard !notes.isEmpty else { return nil }

        var lines: [String] = [
            "Round \(round) of the \u{201C}\(passId)\u{201D} pass raised these notes."
        ]
        // The edited-behind half first: it is the one the model would
        // otherwise re-raise against prose that has moved under it.
        for (heading, partition) in [
            (sinceEditedHeading, notes.filter(\.sinceEdited)),
            (untouchedHeading, notes.filter { !$0.sinceEdited }),
        ] where !partition.isEmpty {
            lines.append("")
            lines.append(heading)
            for note in partition {
                lines.append("- (\(sectionName(of: note.kind))) \(cleaned(note.body))")
            }
        }

        lines.append("")
        lines.append(
            "Confirm rather than reconstruct. Where one of these still stands "
            + "against the prose as it reads now, raise it again in its own "
            + "section, in your own words and from your own reading. Where it "
            + "no longer stands, let it go and say nothing about it. And raise "
            + "whatever this round shows you that the last one did not \u{2014} a "
            + "note is not worth less for being new, or more for having been "
            + "made before.")
        return lines.joined(separator: "\n")
    }

    /// The section a note came out of, in the schema's own vocabulary — read
    /// off `DiagnosticIngest.SectionField` rather than restated, so the words
    /// the model is reminded of are the words it was asked to answer in.
    private static func sectionName(of kind: DiagnosticKind) -> String {
        switch kind {
        case .conformanceStrain: return DiagnosticIngest.SectionField.conformance
        case .continuity: return DiagnosticIngest.SectionField.continuity
        case .readerReport: return DiagnosticIngest.SectionField.reader
        }
    }

    // MARK: - Listings (pinned / palette)

    private static func listingSections(pinnedListing: [String], paletteListing: [String]) -> [String] {
        var sections: [String] = []
        if !pinnedListing.isEmpty {
            sections.append(
                "Pinned references (id and title only — fetch full contents "
                    + "with read_document if a note needs them):\n"
                    + pinnedListing.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !paletteListing.isEmpty {
            sections.append(
                "Palette cards (id and title only — fetch full contents "
                    + "with read_palette_card if a note needs them):\n"
                    + paletteListing.map { "- \($0)" }.joined(separator: "\n"))
        }
        return sections
    }

    // MARK: - Delta section

    private static func deltaSection(_ delta: CompilerDelta) -> String {
        var lines: [String] = ["This run's delta:"]

        if delta.new.isEmpty && delta.revised.isEmpty {
            lines.append("Nothing new or revised since the last run.")
            return lines.joined(separator: "\n")
        }

        if !delta.new.isEmpty {
            lines.append("\nNew paragraphs — these answer only to intent, "
                + "there is no prior version to compare against:")
            for paragraph in delta.new {
                lines.append("[\(paragraph.paragraphId)] (new)")
                lines.append(cleaned(paragraph.text))
            }
        }

        if !delta.revised.isEmpty {
            lines.append("\nRevised paragraphs — each carries what it said "
                + "before and what it says now, because a revision implies "
                + "a goal the writer already had in mind:")
            for paragraph in delta.revised {
                lines.append("[\(paragraph.paragraphId)] (revised)")
                lines.append("Before: \(cleaned(paragraph.prior))")
                lines.append("After: \(cleaned(paragraph.text))")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Anchor hygiene

    /// Defense in depth: the delta is expected to already carry clean text
    /// (anchors are a materialize-time artifact, never part of an in-memory
    /// paragraph's text), but nothing embedded in a prompt should ever leak
    /// one if it somehow did. Reuses the one shared anchor-stripping
    /// transform (CLAUDE.md: don't add a target-local copy).
    private static func cleaned(_ text: String) -> String {
        MarkdownDisplayFilter.stripAnchors(text)
    }

    // MARK: - Hashing

    private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
