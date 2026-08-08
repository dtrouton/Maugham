import Foundation

/// **What a promoted note says once it is a task** (M2 Task 9).
///
/// A diagnostic lives in a per-device sidecar that the next run wholly
/// supersedes. A task is op-logged, syncs, and survives — so a note the writer
/// wants to keep is promoted rather than answered twice. What survives with it
/// is the note's own words plus one line of provenance: who raised it, when,
/// in which model, and against what the writing was being read.
///
/// Pure and static so every clause is a direct assertion — the composition is
/// the interesting part, and it should not need a mounted pane to check.
enum DiagnosticPromotion {

    /// How much of the intent's first line the provenance line carries. Long
    /// enough to recognise the intent, short enough that the record stays one
    /// line under the note it belongs to.
    static let intentExcerptLimit = 60

    /// The task body: the note, then a blank line, then the record.
    ///
    /// **The ¶ id is deliberately absent.** It rides the task's anchor
    /// (`Document.createPaneTask(paragraphId:)`), which is what makes the task
    /// navigable; repeating it here would put plumbing in front of a writer
    /// reading their own list.
    ///
    /// **The record names which section raised it** (spec §5's fates line:
    /// "body cites the section it came from") — the same words the pane's own
    /// section headers use (`sectionLabel`), so a task read months later still
    /// says whether it was a conformance strain, a continuity question, or the
    /// reader's own report. Absent for a `kind == nil` record — a v1-shaped
    /// diagnostic never carried a section to cite.
    ///
    /// Without a run record there is no provenance to claim, and the note's
    /// words stand alone rather than gaining a line with holes in it.
    static func taskBody(for diagnostic: Diagnostic, run: CompilerRun?) -> String {
        guard let run else { return diagnostic.body }
        var record = "\u{2014} compiler, \(dateStamp(run.at)), \(run.model)"
        if let section = sectionLabel(diagnostic.kind) {
            record += ", from \(section)"
        }
        if let excerpt = intentExcerpt(run.intentSnapshot) {
            record += ", checked against: \u{201C}\(excerpt)\u{201D}"
        }
        return diagnostic.body + "\n\n" + record
    }

    /// The section a note came from, in the pane's own words
    /// (`DiagnosticsPane`'s `PaneSectionHeader` titles, lowercased). `nil` for
    /// `kind == nil` — a record from before the sectioned contract had no
    /// section to name.
    private static func sectionLabel(_ kind: DiagnosticKind?) -> String? {
        switch kind {
        case .conformanceStrain: return "conformance"
        case .continuity: return "continuity"
        case .readerReport: return "the reader"
        case nil: return nil
        }
    }

    /// The intent's first real line, cut at `intentExcerptLimit` with the cut
    /// made visible. `nil` when the run checked against no intent at all — the
    /// clause is then omitted rather than rendered with empty quotes.
    ///
    /// **"Real" is `IntentStrip.line(from:)`'s answer, not a second one of this
    /// file's.** The naive first-non-empty-line rule recorded `checked
    /// against: "## Rulings"` into a durable, op-logged task for exactly the
    /// statement Answer/bless mints on a piece that had only project intent: an
    /// empty essay above a rulings heading. The strip already solved this
    /// through `MarkdownBlockParser` — headings, ornaments, fences and tables
    /// skipped, so the first *sentence* answers, which for that statement is
    /// the first ruling the run was genuinely checked against. A third
    /// first-line rule here is the drift the shared block parser exists to end;
    /// only the budget differs, and it is applied after.
    static func intentExcerpt(_ intentSnapshot: String?) -> String? {
        guard let firstLine = IntentStrip.line(from: intentSnapshot) else { return nil }
        guard firstLine.count > intentExcerptLimit else { return firstLine }
        return String(firstLine.prefix(intentExcerptLimit)) + "\u{2026}"
    }

    /// `yyyy-MM-dd` in the writer's own calendar. A fixed, sortable stamp
    /// rather than a localised phrase: this is a record inside a durable task
    /// that may be read months later, next to notes written on other days.
    static func dateStamp(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
