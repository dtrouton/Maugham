import CryptoKit
import Foundation
import MaughamCore

/// Assembles what a compiler run sends to the spawned Claude: the session's
/// one-time system preamble, and each run's message (delta + diffed-in
/// context + the standing drift question + the output-shape instruction).
///
/// A pure function of its inputs — no I/O, no clock — so the prompt itself is
/// testable without a subprocess.
enum CompilerPrompt {

    /// The output contract: four line-delimited JSON objects, one per
    /// section, in fixed order (conformance, continuity, reader, facts).
    /// `DiagnosticIngestTests` reference this SAME constant, so prompt and
    /// parser cannot drift apart in a rewording.
    ///
    /// No severity field, no suggestion field anywhere in this string —
    /// the register is enforced structurally, not by asking nicely
    /// (`test_theSchemaHasNowhereForYouShould`). References travel ONLY in
    /// each entry's `refs` array; prose never carries a bare paragraph id
    /// (`test_theSchemaForbidsIdsInProse`) — the enforcement with teeth is
    /// Task 2's ingest-side scrub, this is the instruction half.
    static let sectionSchemaDescription: String = """
        Respond with four lines, each one JSON object, in this exact order \
        — conformance, then continuity, then reader, then facts. Nothing \
        else: no prose before, between, or after them, and no line \
        skipped — a section with nothing to report still gets its line, \
        with an empty array:
        {"section":"conformance","checks":[{"clause_quote":<string>,"status":\
        "holds"|"strains"|"silent","refs":[<paragraph id>...],"what_pulls":\
        <string or null>}]}
        {"section":"continuity","questions":[{"cites":<string>,"refs":\
        [<paragraph id>...],"question":<string>}]}
        {"section":"reader","reports":[{"kind":"dream_break"|"belief","refs":\
        [<paragraph id>...],"report":<string>}]}
        {"section":"facts","candidates":[{"subject":<string>,"fact":<string>,\
        "refs":[<paragraph id>...]}]}
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
    static func runMessageV2(
        delta: CompilerDelta, world: DerivedWorld?, essay: String?,
        bibleFacts: [BibleFact], paletteListing: [String], pinnedListing: [String],
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
