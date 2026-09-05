import Foundation
import MaughamCore

/// **The letter as a document the writer keeps** (editorial letter P1 Task 10,
/// spec §3.6).
///
/// A letter is derived: it rides its `CompilerRun` and ages out of the rounds
/// ring with it. *Keep this letter* is how one outlives its run, and what it
/// files is a research note — so the letter has to stop being a view model and
/// become prose. This is the whole of that translation; `LetterKeep` decides
/// where the prose lands.
///
/// **The register is the screen's, not the schema's** (global constraint 12).
/// Every part title and column header here is a `LetterSection` copy constant
/// rather than a literal, so a kept letter and the letter it was kept from
/// cannot call the same part two different things. Nothing in the output says
/// `one_thing` or `working`. The one exception is ``exerciseLabel``, which is
/// declared here because the word exists only in this rendering: on screen an
/// exercise is unlabelled prose with a button beside it, so `LetterSection`
/// has no constant to borrow.
///
/// **No paragraph ids, ever.** A ref reaches the note as the paragraph's own
/// words in italics, exactly as the jump chip draws it on screen — a kept
/// letter has no jump to offer, and a join key in prose is the schema showing
/// through. Every string this renderer emits passes through ``scrubbed(_:)``
/// on the way out, because a model that wrote an anchor into its own sentence
/// and an excerpt taken off a paragraph that still carries one are both
/// reachable, and neither is the renderer's caller's problem to notice.
/// `LetterMarkdownTests` asserts the absence with the tripwire's own regex and
/// plants an anchor as the control.
@MainActor
enum LetterMarkdown {

    /// Title and body. The title is the research note's own — it names the
    /// voice and the day, which is what a writer scanning a research list six
    /// months later has to tell two letters apart by.
    ///
    /// - Parameters:
    ///   - editorName: the run's own reader — `AuthorReader.editorName`
    ///     for a check, the stage's `effectiveEditorName` for a round.
    ///   - laneLine: the round's lane, already built by the caller
    ///     (`LetterKeep.laneLine`, which calls `ReviewRoundCockpit.laneLine`
    ///     for a stage and spells the coach's legacy lane itself). Empty for
    ///     a passless run, which has no lane to name.
    ///   - at: the run's own `at`, not "now" — a letter kept a week later is
    ///     still the letter that round wrote.
    static func render(
        _ letter: Letter, editorName: String, laneLine: String, at: Date
    ) -> (title: String, body: String) {
        let title = "Letter from \(scrubbed(editorName)) \u{2014} \(dateText(at))"
        var out: [String] = ["# \(title)"]

        let lane = scrubbed(laneLine)
        if !lane.isEmpty { out.append("*\(lane)*") }

        // **The answer first, before the say-back** — the reading order the
        // section keeps on screen (`LetterSection.answerPart`), for its reason:
        // a writer who asked something reads for that first. The ask draws only
        // as the answer's caption, in `LetterSection`'s own spelling, so a kept
        // letter and the letter it was kept from cannot word it differently.
        if let answer = letter.answer.map(scrubbed), !answer.isEmpty {
            if let asked = letter.asked.map(scrubbed), !asked.isEmpty {
                out.append("*\(LetterSection.askedCaption(asked))*")
            }
            out.append(answer)
        }

        let about = scrubbed(letter.about)
        if !about.isEmpty { out.append(about) }
        if let oneThing = letter.oneThing.map(scrubbed), !oneThing.isEmpty {
            // The one thing keeps the emphasis it has on screen, and no label:
            // a heading saying "One thing" over a single sentence would be the
            // schema showing through (`LetterSection.oneThingPart`).
            out.append("**\(oneThing)**")
        }

        if !letter.working.isEmpty {
            out.append("## \(LetterSection.workingTitle)")
            for entry in letter.working {
                out.append(contentsOf: prose(entry.what, entry.why))
                out.append(contentsOf: refLines(entry.refs))
            }
        }

        if !letter.habits.isEmpty {
            out.append("## \(LetterSection.habitsTitle)")
            for habit in letter.habits {
                out.append(contentsOf: prose(habit.name, habit.cost, habit.lesson))
                if let exercise = habit.exercise.map(scrubbed), !exercise.isEmpty {
                    out.append("**\(exerciseLabel):** \(exercise)")
                }
                out.append(contentsOf: refLines(habit.refs))
            }
        }

        if !letter.questions.isEmpty {
            out.append("## \(LetterSection.questionsTitle)")
            for entry in letter.questions {
                out.append(contentsOf: prose(entry.question))
                out.append(contentsOf: refLines(entry.refs))
            }
        }

        // `nil` (a lyric piece) and `[]` (a table with no rows) mean different
        // things upstream, and neither of them is a table.
        if let scenes = letter.scenes, !scenes.isEmpty {
            out.append("## \(LetterSection.scenesTitle)")
            out.append(contentsOf: sceneTable(scenes))
            for scene in scenes where !scene.refs.isEmpty {
                out.append(contentsOf: refLines(scene.refs))
            }
        }

        // **What the round looked for and did not find** (spec §6), after the
        // table because it is the letter's last observation rather than one of
        // its findings.
        //
        // **Unfiltered, unlike the screen's.** `LetterSection` narrows the same
        // list against the writer's ledger, because there it draws an OFFER and
        // an offer must name a row that is really there. Here it is a record of
        // what this round reported, and a note that quietly dropped half of it
        // because the ledger had moved by the time the letter was kept would be
        // a record of something else.
        let notFound = letter.retiredHeadings.map(scrubbed).filter { !$0.isEmpty }
        if !notFound.isEmpty {
            out.append("## \(notFoundTitle)")
            out.append(notFound.map { "- \($0)" }.joined(separator: "\n"))
        }

        // **The process line last** (P3 Task 5, spec §3.1/§5) — the letter's
        // one observation about how the writing is going rather than about the
        // prose, in the caption the screen gives it. `LetterSection`'s own
        // constant rather than a literal, this file's register rule.
        //
        // An empty line draws no heading, the rule every other part keeps.
        let process = scrubbed(letter.process ?? "")
        if !process.isEmpty {
            out.append("## \(LetterSection.processCaption)")
            out.append(process)
        }

        return (title: title, body: out.joined(separator: "\n\n") + "\n")
    }

    /// What the round's "not found" list is called in the note. Declared here
    /// for ``exerciseLabel``'s reason: on screen the same headings are a line
    /// per lesson in the round's own tense, or an offer with a Retire button
    /// beside it, so `LetterSection` has no heading to borrow.
    static let notFoundTitle = "Not found this time"

    /// What the exercise is called in the note. On screen it is unlabelled
    /// prose under a habit with an **Accept as task** button beside it; there
    /// is no button here, so the word has to do the button's job of saying
    /// this line is the thing to DO.
    static let exerciseLabel = "Exercise"

    // MARK: - Pieces

    /// The parts of an entry that have any words in them, each its own
    /// paragraph. An empty field contributes nothing rather than a blank line.
    private static func prose(_ fields: String?...) -> [String] {
        fields.compactMap { field in
            let text = scrubbed(field ?? "")
            return text.isEmpty ? nil : text
        }
    }

    /// **Every ref an entry carries, as the paragraph's own words in
    /// italics.** On screen the first is a jump chip and the rest are "and N
    /// more" behind it; a kept letter has nothing to travel to, so the words
    /// themselves are what it can offer.
    private static func refLines(_ refs: [Diagnostic.Ref]) -> [String] {
        refs.compactMap { ref in
            let words = scrubbed(ref.excerpt)
            return words.isEmpty ? nil : "*\(words)*"
        }
    }

    /// The scene table. The charge column is drawn only when the form has a
    /// charge in it (`LetterSection.hasCharge`) — a weak-form table has none,
    /// and a column of blanks would tell a writer their reader had nothing to
    /// say about charge when the form has no charge to say anything about.
    private static func sceneTable(_ scenes: [Letter.Scene]) -> [String] {
        let charged = LetterSection.hasCharge(scenes)
        var columns = [LetterSection.wantsColumn, LetterSection.changesColumn,
                       LetterSection.turnColumn]
        if charged { columns.append(LetterSection.chargeColumn) }
        var rows = ["| " + columns.joined(separator: " | ") + " |",
                    "| " + columns.map { _ in "---" }.joined(separator: " | ") + " |"]
        for scene in scenes {
            var cells = [cell(scene.wants), cell(scene.changes), cell(scene.turn)]
            if charged { cells.append(cell(scene.charge ?? "")) }
            rows.append("| " + cells.joined(separator: " | ") + " |")
        }
        // One block, so the rows stay a table rather than becoming paragraphs.
        return [rows.joined(separator: "\n")]
    }

    /// One table cell. A blank cell stays blank — filling it with a dash would
    /// put words in the reader's mouth, which is the rule the on-screen table
    /// keeps too. A pipe is escaped and a newline flattened, because a cell
    /// that broke its row would cost the writer every scene below it.
    private static func cell(_ text: String) -> String {
        scrubbed(text)
            .replacingOccurrences(of: "|", with: "\\|")
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
    }

    /// **The one scrub every emitted string passes through.**
    ///
    /// Takes an anchor comment whole, then any bare `¶`-prefixed token left
    /// behind, then the inline task anchors `MarkdownDisplayFilter` already
    /// owns. Deliberately NOT `MarkdownDisplayFilter.stripAnchors`: that one
    /// drops a paragraph anchor only when the anchor is the whole LINE, which
    /// is true of a stored manuscript and false of a one-line excerpt or a
    /// model's sentence — the two shapes this renderer actually receives.
    ///
    /// The sentence around the anchor survives; the collapse of the double
    /// space the removal leaves is what keeps that readable.
    static func scrubbed(_ text: String) -> String {
        var out = text
        var removedSomething = false
        for pattern in [anchorCommentPattern, bareAnchorTokenPattern] {
            let range = NSRange(location: 0, length: (out as NSString).length)
            guard pattern.firstMatch(in: out, range: range) != nil else { continue }
            removedSomething = true
            out = pattern.stringByReplacingMatches(
                in: out, range: range, withTemplate: "")
        }
        let taskStripped = MarkdownDisplayFilter.stripTaskAnchorsInline(out)
        if taskStripped != out { removedSomething = true }
        out = taskStripped
        // **Collapse only where something was taken out.** Removing an inline
        // anchor leaves the two spaces that bracketed it against each other,
        // and a doubled space mid-sentence reads as a typo the writer did not
        // make. Doing it unconditionally would be worse in the other
        // direction: a writer who double-spaces after a full stop would find
        // their own habit quietly undone in every letter they kept.
        while removedSomething, out.contains("  ") {
            out = out.replacingOccurrences(of: "  ", with: " ")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `<!-- ¶ab3d -->`, in any of the spacings the anchor is written with.
    private static let anchorCommentPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "<!--\\s*\u{00b6}[0-9A-Za-z]{4}\\s*-->")
    }()

    /// A bare `¶ab3d` with no comment around it — the shape a model leaks when
    /// it quotes an anchor out of a paragraph it was shown.
    private static let bareAnchorTokenPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "\u{00b6}[0-9A-Za-z]{4}(?![0-9A-Za-z])")
    }()

    /// The day, in the writer's own calendar and a fixed English spelling —
    /// the note's title is a filename as well as a sentence, so a
    /// locale-dependent format would give the same run two names on two Macs.
    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date)
    }
}
