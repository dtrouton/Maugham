import SwiftUI
import MaughamCore

/// The gate, drawn above a statement's editor while a proposal stands for it
/// (spec §10): who proposed what and when, why, the diff against the current
/// text, and Adopt / Discard. Value-taking; the pane owns the reads and the
/// verbs. Every sentence is `StatementProposalCopy`'s.
struct StatementProposalBanner: View {
    struct Model: Equatable {
        let title: String
        let when: String
        let rationale: String?
        let glossaryLine: String?
        let createsLine: String?
        let diff: [StatementProposalDiff.Line]
    }

    static func model(proposal: StatementProposalStore.Proposal, current: String?,
                      statementExists: Bool, now: Date) -> Model {
        let glossary: Int
        if case .editionBrief = proposal.kind {
            glossary = (try? StatementProposalStore.glossaryLines(in: proposal.markdown).count) ?? 0
        } else { glossary = 0 }
        let compared = StatementProposalDiff.compared(current: current ?? "", proposal: proposal)
        return Model(
            title: StatementProposalCopy.bannerTitle(proposal),
            when: StatementProposalCopy.bannerWhen(proposal.proposedAt, now: now),
            rationale: proposal.rationale?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? proposal.rationale : nil,
            glossaryLine: StatementProposalCopy.glossaryLine(count: glossary),
            createsLine: statementExists ? nil : StatementProposalCopy.firstAdoptCreatesLine(proposal.kind),
            diff: StatementProposalDiff.lines(current: compared.current, proposed: compared.proposed))
    }

    let proposal: StatementProposalStore.Proposal
    let current: String?
    let statementExists: Bool
    let now: Date
    let notice: String?
    let busy: Bool
    /// What this window may offer over the statement the proposal is FOR
    /// (P3c Task 7) — asked by the pane of the drawing door. Without
    /// `.editStatement` the banner still draws: a reviewer reads the proposal,
    /// its reason and its diff; only Adopt and Discard are not hers.
    let posture: Posture
    let onAdopt: () -> Void
    let onDiscard: () -> Void

    /// **Whether Adopt and Discard are drawn** — the one rule, asked of the
    /// posture of the statement the proposal would change. Hidden, not
    /// disabled: a greyed Adopt reads as broken. Discard follows Adopt,
    /// because what becomes of a proposal to a statement is that statement's
    /// writer's decision (`StatementProposalGate.discard`'s own note).
    static func offersVerbs(_ posture: Posture) -> Bool {
        posture.allows(.editStatement)
    }

    private var model: Model {
        Self.model(proposal: proposal, current: current, statementExists: statementExists, now: now)
    }

    var body: some View {
        let model = model
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.title).font(.callout.weight(.medium))
                Text(model.when).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if Self.offersVerbs(posture) { verbs }
            }
            if let rationale = model.rationale {
                Text(StatementProposalCopy.rationaleHeading).font(.caption).foregroundStyle(.secondary)
                Text(rationale).font(.callout)
            }
            if let line = model.createsLine { Text(line).font(.caption).foregroundStyle(.secondary) }
            if let line = model.glossaryLine { Text(line).font(.caption).foregroundStyle(.secondary) }
            Text(StatementProposalCopy.diffHeading).font(.caption).foregroundStyle(.secondary)
            if current == nil {
                Text(StatementProposalCopy.noCurrentTextLine).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.diff.enumerated()), id: \.offset) { _, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(.body, design: .serif))
                            .strikethrough(line.kind == .removed)
                            .underline(line.kind == .added)
                            .foregroundStyle(line.kind == .removed ? Color.red
                                             : line.kind == .added ? Color.green : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxHeight: Self.diffCeiling)
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.title)
    }

    /// Discard and Adopt, drawn only where `offersVerbs` says so.
    @ViewBuilder
    private var verbs: some View {
        Button(StatementProposalCopy.discardTitle, action: onDiscard)
            .controlSize(.small)
            .disabled(busy)
            .help(StatementProposalCopy.discardHelp)
            .accessibilityLabel(StatementProposalCopy.discardAccessibilityLabel(proposal.kind))
        Button(StatementProposalCopy.adoptTitle, action: onAdopt)
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(busy)
            .help(StatementProposalCopy.adoptHelp(proposal.kind))
            .accessibilityLabel(StatementProposalCopy.adoptAccessibilityLabel(proposal.kind))
    }

    /// The diff scrolls past this rather than pushing the editor off the pane.
    static let diffCeiling: CGFloat = 220
}
