import CryptoKit
import Foundation
import MaughamCore

/// What a compiler run needs to know beyond the delta itself: the resolved
/// intent (piece-first, project-fallback — the caller resolves which), and
/// the pinned/palette listings the prompt names but never inlines.
struct CompilerContext: Equatable, Sendable {
    let projectId: String
    let intentText: String?          // resolved piece-first (caller resolves)
    let intentScopeLabel: String     // "this chapter" / "the project"
    let pinnedListing: [String]      // "title (id)" lines — ids the run can feed to read tools
    let paletteListing: [String]
}

/// Assembles what a compiler run sends to the spawned Claude: the session's
/// one-time system preamble, and each run's message (delta + diffed-in
/// context + the standing drift question + the output-shape instruction).
///
/// A pure function of its inputs — no I/O, no clock — so the prompt itself is
/// testable without a subprocess.
enum CompilerPrompt {

    /// The output contract every run message ends with, verbatim. Task 6's
    /// parser tests reference this SAME constant, so prompt and parser cannot
    /// drift apart.
    static let outputSchemaDescription: String = """
        Respond with a single JSON object and nothing else — no prose before \
        or after it:
        {"diagnostics":[{"paragraph_id":<string or null>,"category":<string \
        or null>,"body":<string>}],"intent_drift":<string or null>}
        Copy each paragraph_id exactly as it appears above — do not alter, \
        invent, abbreviate, or omit it. A diagnostic with no natural \
        paragraph (e.g. it concerns the whole delta rather than one \
        paragraph) uses null. intent_drift is null unless the standing \
        drift question below is answered yes.
        """

    /// Sent once, when the warm session is spawned — never repeated per run.
    static func sessionSystemPreamble(projectId: String) -> String {
        """
        You are reading a manuscript-in-progress as a literary compiler: a \
        close, tasteful reader giving the writer near-live feedback while \
        they are still writing. You are not a linter and you do not rank \
        your opinions — there are no severity levels. Give notes worth \
        reading: specific, concise, and grounded in what the prose is \
        actually doing against what the writer says they're going for. \
        Silence on a paragraph is a valid response; do not manufacture a \
        note to fill space.

        This session is long-lived: later messages will build on what you've \
        already read here. You will be asked to check new and revised \
        prose against a declared intent, and to flag when that intent \
        itself looks stale.

        Project: \(projectId)
        """
    }

    /// One run's message: the delta, diffed-in context, the standing drift
    /// question, and the output-format instruction. Returns the message text
    /// plus the intent hash to pass as `previousIntentHash` on the NEXT run
    /// (`nil` when there is no intent to track).
    static func runMessage(
        delta: CompilerDelta, context: CompilerContext, previousIntentHash: String?
    ) -> (message: String, intentHash: String?) {
        var sections: [String] = []
        var intentHash: String? = nil

        if let intentText = context.intentText {
            let hash = sha256Hex(intentText)
            intentHash = hash
            if hash == previousIntentHash {
                sections.append(
                    "Intent (\(context.intentScopeLabel)): unchanged since last run.")
            } else {
                sections.append(
                    "Intent (\(context.intentScopeLabel)):\n\(cleaned(intentText))")
            }
        }

        if !context.pinnedListing.isEmpty {
            sections.append(
                "Pinned references (id and title only — fetch full contents "
                    + "with read_document if a note needs them):\n"
                    + context.pinnedListing.map { "- \($0)" }.joined(separator: "\n"))
        }

        if !context.paletteListing.isEmpty {
            sections.append(
                "Palette cards (id and title only — fetch full contents "
                    + "with read_palette_card if a note needs them):\n"
                    + context.paletteListing.map { "- \($0)" }.joined(separator: "\n"))
        }

        sections.append(deltaSection(delta))

        sections.append(
            "Standing question: does this delta suggest the declared intent "
                + "is stale, incomplete, or missing something the writer "
                + "should now say explicitly? Answer only when it does; "
                + "otherwise intent_drift is null.")

        sections.append(outputSchemaDescription)

        return (sections.joined(separator: "\n\n"), intentHash)
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

    // MARK: - Intent hashing

    private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
