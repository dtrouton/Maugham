import SwiftUI

/// **One paragraph of the author's prose the round changed, facing them**
/// (translation pipeline P4 Task 3, spec §8 item 2).
///
/// The row a writer reads to answer one question — *is this still my book?* —
/// which is why what it draws by default is entirely in the author's own
/// language: their source paragraph, the collator's gloss of what the
/// translation now says, the note, and what the translator did about it. The
/// **translation itself is behind a disclosure** (spec §12): the author may not
/// read the target language, and prose they cannot judge drawn beside prose they
/// can is noise standing where the decision goes.
///
/// **A dismissed row draws no verbs.** The author already said this one was
/// fine; offering Fine again over their own answer is the shape that trains a
/// writer to stop trusting what a row says about itself.
///
/// A value in, closures out — nothing here reads a store, and the row is drawn
/// from `TranslationRoundReport.DepartureRow`, which carries no store either.
@MainActor
struct DepartureRowView: View {
    let row: TranslationRoundReport.DepartureRow
    let isExpanded: Bool
    var onFine: () -> Void = { }
    var onKeepMine: () -> Void = { }
    var onMakeRule: () -> Void = { }
    var onReveal: () -> Void = { }
    var onToggleExpanded: () -> Void = { }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            sourceLine
            Text(row.gloss)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.note)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let outcomeLine = row.outcomeLine {
                Text(outcomeLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if row.before != nil || row.after != nil { disclosure }
            if !row.isDismissed { verbs }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    /// What kind of departure this was, and how the collator judged it.
    private var header: some View {
        Text("\(TranslationRoundReport.verdictLabel(row.verdict)) \u{00b7} "
             + TranslationRoundReport.verdictLabel(row.kind))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The author's own paragraph, and the way back to it in the manuscript.
    ///
    /// `Button(.plain)` rather than a tap gesture (tripwire 9) — and a button
    /// even when the paragraph is gone, because the reveal is what says so: the
    /// writer asks to be shown it and the manuscript is where the answer is.
    private var sourceLine: some View {
        Button(action: onReveal) {
            Text(row.source ?? TranslationRoundReport.sourceMissingLine)
                .font(row.source == nil ? .caption : .callout)
                .foregroundStyle(row.source == nil ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            TranslationRoundReport.revealAccessibilityLabel(paragraphId: row.paragraphId))
    }

    /// **The one place target-language text appears**, and only once the writer
    /// opens it. Both halves, because "what it said before" is the half that
    /// makes the change legible to somebody using a dictionary.
    @ViewBuilder
    private var disclosure: some View {
        Button(action: onToggleExpanded) {
            Label(isExpanded
                    ? DepartureRowCopy.hideTranslation
                    : DepartureRowCopy.showTranslation,
                  systemImage: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            TranslationRoundReport.expandLabel(id: row.id, expanded: isExpanded))
        if isExpanded {
            VStack(alignment: .leading, spacing: 4) {
                if let before = row.before {
                    labelled(DepartureRowCopy.beforeLabel, before)
                }
                if let after = row.after {
                    labelled(DepartureRowCopy.afterLabel, after)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func labelled(_ heading: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(heading)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(.caption, design: .serif))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verbs: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(TranslationRoundReport.fineTitle, action: onFine)
                .controlSize(.small)
                .accessibilityLabel(TranslationRoundReport.fineLabel(id: row.id))
                .help(DepartureRowCopy.fineHelp)
            Button(TranslationRoundReport.keepMineTitle, action: onKeepMine)
                .controlSize(.small)
                .accessibilityLabel(TranslationRoundReport.keepMineLabel(id: row.id))
                .help(DepartureRowCopy.keepMineHelp)
            Button(TranslationRoundReport.makeRuleTitle, action: onMakeRule)
                .controlSize(.small)
                .accessibilityLabel(TranslationRoundReport.makeRuleLabel(id: row.id))
                .help(DepartureRowCopy.makeRuleHelp)
        }
    }
}

/// The row's own words.
enum DepartureRowCopy {
    static let showTranslation = "Show the translation"
    static let hideTranslation = "Hide the translation"
    static let beforeLabel = "Before"
    static let afterLabel = "After"

    static let fineHelp =
        "Accept this change. The departure is marked settled and no rule is "
        + "written."
    static let keepMineHelp =
        "Write a translator\u{2019}s note on this paragraph, so every later "
        + "round is briefed to keep what you wrote."
    static let makeRuleHelp =
        "Turn this note into a dated ruling in the edition brief."
}
