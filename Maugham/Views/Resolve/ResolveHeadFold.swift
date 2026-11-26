import SwiftUI
import MaughamCore

// MARK: - The decisions (pure)

/// **To resolve's head folds** (the owner's report, 2026-11-26: "i can barely
/// see the items needing to be resolved because of the settings"). Folded is
/// the default and the list gets the room; open is the head as it was, with
/// the chevron to fold it again. One setting per window
/// (`UIState.resolveHeadOpen`), whatever piece or language the faces show.
///
/// **Folding hides controls, never state.** Folded, a piece's head is three
/// short rows at most: its name and where it stands, one action row (Run
/// Round, Reread, Cancel while something runs — the same offers, refusals and
/// tooltips as open), and one line only when there is something to say
/// (`pieceLine`): a run in progress, a failure, a run elsewhere holding the
/// session, the pass-order nudge, or the latest letter. A newly arrived
/// letter does not spring the head open: it shows its one line, and a click
/// on the line opens the head.
@MainActor
enum ResolveHeadFold {

    // MARK: Row 1: where the piece stands

    /// **Where the piece stands on the ladder, in a few words**: the first
    /// pass in progress ("Line in progress"), else the first pass not yet
    /// ruled on ("Structural next"), else every pass ruled ("all four passes
    /// done"; one pass: "Proof done"). The ladder's own words and the
    /// project's own pass names. `nil` for a project with no passes. A state
    /// written by a newer build counts as open, `PassOrderAdvice`'s rule.
    static func ladderPhrase(passes: [ReviewPass], passStates: [String: PassState]?) -> String? {
        guard !passes.isEmpty else { return nil }
        if let working = passes.first(where: { passStates?[$0.id] == .inProgress }) {
            return "\(working.name) \(PassLadder.inProgressTitle.lowercased())"
        }
        if let next = passes.first(where: { pass in
            switch passStates?[pass.id] {
            case .done, .skipped: return false
            case .inProgress, .unknown, nil: return true
            }
        }) {
            return "\(next.name) next"
        }
        if passes.count == 1, let only = passes.first {
            return "\(only.name) \(PassLadder.doneTitle.lowercased())"
        }
        return "all \(countWord(passes.count)) passes \(PassLadder.doneTitle.lowercased())"
    }

    /// "four", not "4", up to twelve; digits past it.
    static func countWord(_ count: Int) -> String {
        guard (0...12).contains(count) else { return String(count) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en")
        return formatter.string(from: NSNumber(value: count)) ?? String(count)
    }

    /// **The folded head's summary**: the derived Status (`StatusSwatch`'s
    /// word, the ladder's own first row) and the ladder phrase —
    /// "Revising · Line in progress", "Final · all four passes done".
    static func summary(status: ReviewStatus, passes: [ReviewPass],
                        passStates: [String: PassState]?) -> String {
        let label = StatusSwatch.label(for: status)
        guard let phrase = ladderPhrase(passes: passes, passStates: passStates) else { return label }
        return "\(label) \u{00B7} \(phrase)"
    }

    /// **What VoiceOver reads for row 1**: one sentence, the name then the
    /// summary.
    static func sentence(title: String, summary: String?) -> String {
        guard let summary, !summary.isEmpty else { return "\(title)." }
        return "\(title): \(summary.replacingOccurrences(of: " \u{00B7} ", with: ", "))."
    }

    // MARK: Row 3: the one line

    /// What the folded head's third row says, or nothing.
    enum Line: Equatable {
        /// This piece's round is running: the cockpit's clock
        /// (`ReviewRoundCockpit.statusLine`), redrawn once a second.
        case roundRunning
        /// This piece's check is running: the check header's clock
        /// (`CheckNarrative.headerCopy`), redrawn once a second.
        case checkRunning
        /// A translation round on this piece or edition, its leg.
        case running(String)
        /// The last run here failed or stopped — red when it failed.
        case failed(String)
        case stopped(String)
        /// A run elsewhere holds the window's one session, so Run waits.
        case otherRun(String)
        /// What the head said after a press (a translation head's notice).
        case notice(String)
        /// `PassOrderAdvice`'s caption; its verbs are in the open head.
        case nudge(String)
        /// "Letter from Perkins · 2 hours ago".
        case letter(String)

        /// Whether the line is drawn red.
        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// **A piece's third row**, first of: its round running, its check
    /// running, its round failed, its check failed, a run elsewhere holding
    /// the session, the pass-order nudge, the latest letter. A run's progress
    /// is never hidden while it runs (`test_aRunningRoundIsNeverHiddenFolded`).
    static func pieceLine(roundPhase: ReviewRoundCockpit.RunPhase,
                          checkState: CheckNarrative.HeaderState,
                          nudge: String?, letter: String?) -> Line? {
        if case .running = roundPhase { return .roundRunning }
        if case .running = checkState { return .checkRunning }
        if case .failed(let failure, _) = roundPhase { return .failed(RoundNarrative.failureCopy(failure)) }
        if case .failed = checkState {
            return .failed(CheckNarrative.headerCopy(for: checkState, annotations: nil, passes: []))
        }
        if let other = ReviewRoundCockpit.otherLoopLine(phase: roundPhase) { return .otherRun(other) }
        if let nudge { return .nudge(nudge) }
        if let letter { return .letter(letter) }
        return nil
    }

    /// **A translation head's third row** (an edition's, a piece read in a
    /// language's), first of: its round running, a round elsewhere, a
    /// failure, a stopped round, the head's notice, the latest letter.
    static func translationLine(running: String?, elsewhere: String?, failure: String?,
                                stopped: (line: String, failed: Bool)?, notice: String?,
                                letter: String?) -> Line? {
        if let running { return .running(running) }
        if let elsewhere { return .otherRun(elsewhere) }
        if let failure { return .failed(failure) }
        if let stopped { return stopped.failed ? .failed(stopped.line) : .stopped(stopped.line) }
        if let notice { return .notice(notice) }
        if let letter { return .letter(letter) }
        return nil
    }

    /// "Letter from <voice> · <when>", the latest letter in one line.
    static func letterLine(voice: String, at: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Letter from \(voice) \u{00B7} \(formatter.localizedString(for: at, relativeTo: now))"
    }

    // MARK: The routes

    /// **Which of To resolve's requests open the head first**: File ▸
    /// Translate…, which presses a language head's Run and answers in that
    /// head. The others address the list (a filter, a group, a finding, a
    /// paragraph) and leave the head as it is. Every other way to a head
    /// control is a press inside the head itself — a folded line's click
    /// opens it — and ⌘R, ⌃⌘R and ⌘⇧R run through the window, folded or not.
    static func opensTheHead(_ request: ResolveRequest) -> Bool {
        switch request {
        case .translate: return true
        case .filter, .focus, .focusFinding, .showParagraph: return false
        }
    }

    // MARK: Words

    /// The chevron's VoiceOver label, value and tooltip.
    static let chevronLabel = "Passes, letters and runs"
    static func chevronValue(isOpen: Bool) -> String { isOpen ? "Expanded" : "Collapsed" }
    static func chevronHelp(isOpen: Bool) -> String {
        isOpen ? "Fold the head so the list has the room"
            : "Open the head: the passes, the latest letter, Ask about\u{2026} and the run\u{2019}s settings"
    }

    /// The least height the list keeps under an open head — the head scrolls
    /// within itself past it (`ResolveHeadRoomLayout`).
    static let listFloor: CGFloat = 120
}

// MARK: - Row 1

/// **The head's first row**: the name and where it stands, and the chevron
/// that opens or folds the head. Drawn open and folded alike, so the chevron
/// never scrolls away. A `Button`, never a tap gesture.
struct ResolveHeadFoldBar: View {
    let title: String
    let summary: String?
    let isOpen: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                }
            }
            .help(summary.map { "\(title) \u{00B7} \($0)" } ?? title)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ResolveHeadFold.sentence(title: title, summary: summary))
            .accessibilityIdentifier("resolve.head.summary")
            Spacer(minLength: 4)
            Button(action: onToggle) {
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .font(.caption.weight(.semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(ResolveHeadFold.chevronHelp(isOpen: isOpen))
            .accessibilityLabel(ResolveHeadFold.chevronLabel)
            .accessibilityValue(ResolveHeadFold.chevronValue(isOpen: isOpen))
            .accessibilityIdentifier("resolve.head.chevron")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
    }
}

// MARK: - Row 3

/// **The folded head's one line**. A click opens the head, where the line's
/// verbs are (the nudge's Mark done, the letter's offers, Cancel's
/// neighbours). A running round or check is a clock, redrawn once a second
/// by `runningText` and only while it runs.
struct ResolveHeadFoldedLine: View {
    let line: ResolveHeadFold.Line
    /// The clock's sentence at a moment, for `.roundRunning`/`.checkRunning`.
    var runningText: (Date) -> String = { _ in "" }
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Group {
                switch line {
                case .roundRunning, .checkRunning:
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        text(runningText(context.date))
                    }
                case .running(let s), .failed(let s), .stopped(let s), .otherRun(let s),
                     .notice(let s), .nudge(let s), .letter(let s):
                    text(s)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(ResolveHeadFold.chevronHelp(isOpen: false))
        .accessibilityIdentifier("resolve.head.foldedLine")
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    private func text(_ s: String) -> some View {
        Text(s)
            .font(.caption)
            .foregroundStyle(line.isFailure ? Color.red : Color.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

// MARK: - The pane's room

/// **The list keeps its room under an open head** — To resolve's two parts,
/// the head and the rest (the filed line, the filter bar, the list). The
/// head takes its own height while the rest keeps its minimum and
/// `ResolveHeadFold.listFloor` for the list; past that the head is given
/// what is left and its open part scrolls within itself (its first row, the
/// chevron with it, stays). Folded, the head is short and this changes
/// nothing.
///
/// It measures and places two subviews and no more.
struct ResolveHeadRoomLayout: Layout {
    var listFloor: CGFloat = ResolveHeadFold.listFloor

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let head = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let rest = subviews[1].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? max(head.width, rest.width),
                      height: proposal.height ?? (head.height + rest.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        guard subviews.count == 2 else { return }
        let headHeight = Self.headHeight(
            total: bounds.height,
            headIdeal: subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height,
            headMinimum: subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: 0)).height,
            restMinimum: subviews[1].sizeThatFits(ProposedViewSize(width: bounds.width, height: 0)).height,
            listFloor: listFloor)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: headHeight))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + headHeight), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width,
                                                     height: max(0, bounds.height - headHeight)))
    }

    /// The head's height: its own, unless that would leave the list less
    /// than `listFloor`; never less than its own minimum (its first row).
    /// Pure.
    static func headHeight(total: CGFloat, headIdeal: CGFloat, headMinimum: CGFloat,
                           restMinimum: CGFloat, listFloor: CGFloat) -> CGFloat {
        let room = total - restMinimum - listFloor
        return max(headMinimum, min(headIdeal, room))
    }
}

/// **An open head's body, scrolling within itself** when the pane gives it
/// less than it asks (`ResolveHeadRoomLayout`); its own height otherwise.
struct ResolveHeadOpenBody<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("resolve.head.open")
    }
}
