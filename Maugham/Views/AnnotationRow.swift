import SwiftUI
import AppKit
import MaughamCore

/// RULING-35's other half as a modifier: a reason when there is one, and no
/// tooltip at all when there is not.
private struct RowDisabledReason: ViewModifier {
    let reason: String?

    func body(content: Content) -> some View {
        if let reason {
            content.help(reason)
        } else {
            content
        }
    }
}

/// Row-level control policy — pure, so RULING-35's no-dead-controls rule is
/// testable without mounting the pane.
enum AnnotationRowPolicy {
    /// Revert makes sense only for an accepted suggestion whose anchor
    /// paragraph still exists — an enabled Revert that silently does nothing
    /// was the M5-AN-030 defect.
    static func revertEnabled(_ ann: Annotation, livePids: Set<String>) -> Bool {
        guard ann.status == .accepted, ann.kind == .suggestedChange,
              let pid = ann.paragraphId else { return true }
        return livePids.contains(pid)
    }
}

/// **Which of a queue row's verbs this Mac may offer** (P3c Task 5) — asked of
/// the ROW'S OWN document's posture, never the window's: the cross-document
/// queue shows a pieces-author's own piece with its verbs beside somebody
/// else's without them.
///
/// Hidden, never disabled: a greyed Accept reads as broken. The door behind
/// each is the Document's own (`Document.requireDispositionPermitted`).
///
/// **Independent of the note's kind**, deliberately: every kind's Accept (and a
/// query's Reply…) writes the same accept op and every Stet / Archive / Triage
/// / Reopen the same disposition group, so the kind decides which verbs a row
/// HAS (`AnnotationRow.dispositions`) and never whether this Mac may press
/// them. Pinned over every kind in `PostureSurfaceTests`.
struct AnnotationRowVerbs: Equatable {
    /// Accept, Got it, Reply…, Reject…, Revert — they move the words or settle
    /// the note with the writer's answer.
    let acceptOrReject: Bool
    /// Stet, Archive, the triage menu and Reopen. (A deleted note's Restore
    /// is `restoresDeleted`: it undoes a withdrawal, not a disposition.)
    let dispose: Bool
    /// *Answer as ruling…* — a reply AND a dated ruling in the statement it
    /// files under, so both halves have to be this Mac's to write.
    let answerAsRuling: Bool
    /// *This is a choice* — a stet AND a lessons-ledger row.
    let makeChoice: Bool
    /// *Keep as lesson…* — a lessons-ledger row, no annotation op.
    let keepAsLesson: Bool
    /// Edit / Delete of the local writer's OWN note — the reviewer row, which
    /// every rung holds, so it follows ownership alone.
    let ownNote: Bool

    /// **The one decision.** `rulingStatement` is the posture of the statement
    /// *Answer as ruling…* would file under (nil where the row offers none);
    /// `lessons` is the lessons ledger's. Both are asked of the same door as
    /// the row's own (`StatementEditorHost.postureDocId`), and Task 7's door on
    /// `RulingPerformer` is what refuses the write; here they only hide.
    static func decide(
        posture: Posture, isOwn: Bool,
        rulingStatement: Posture?, lessons: Posture
    ) -> AnnotationRowVerbs {
        let answer = posture.allows(.acceptOrReject)
        let dispose = posture.allows(.dispose)
        let ledger = lessons.allows(.editStatement)
        return AnnotationRowVerbs(
            acceptOrReject: answer,
            dispose: dispose,
            answerAsRuling: answer
                && (rulingStatement?.allows(.editStatement) ?? false),
            makeChoice: dispose && ledger,
            keepAsLesson: ledger,
            ownNote: isOwn)
    }

    /// **Restore on a deleted note** (P3c plan 2, ruling P; controller
    /// Ruling D). A restore is a reopen that undoes a WITHDRAWAL, and the
    /// deriver honours it from the same writer as the one who DELETED the note
    /// or from author rights (`AnnotationOwnership.mayAmend`, handed the
    /// withdrawal): what she deleted herself is hers to restore whatever her
    /// rung — so her own note, since a reviewer's Delete of anybody else's is
    /// never honoured — and anybody's is a posture that may settle notes
    /// here. The root's Delete of her note is the root's. Hidden otherwise.
    ///
    /// `standing` is the DOOR's answer (`Document.restoreStanding`, which asks
    /// `requireRestoreHonoured` of the very op a press would append), so the
    /// drawn Restore and the act agree by construction (P3c plan 2 Task 8):
    /// it used to be decided by display name while the door decides by key.
    /// A restore honoured only as the deleter is the reviewer row and is
    /// always drawn; one honoured on author rights is a disposition's footing
    /// and follows the posture, so the root's cooperative yield still hides it.
    static func restoresDeleted(
        posture: Posture, standing: Document.RestoreStanding
    ) -> Bool {
        switch standing {
        case .refused: return false
        case .asTheDeleter: return true
        case .withAuthorRights: return posture.allows(.dispose)
        }
    }

    /// **The P1 surface, by name** — every verb its kind has. For a row built
    /// outside the pane (a test's, a measurement's), which must say so; the
    /// pane — the one production host — always passes `decide`'s answer.
    static func unrestricted(isOwn: Bool) -> AnnotationRowVerbs {
        AnnotationRowVerbs(
            acceptOrReject: true, dispose: true, answerAsRuling: true,
            makeChoice: true, keepAsLesson: true, ownNote: isOwn)
    }
}

struct AnnotationRow: View {
    let annotation: Annotation
    var revertIsEnabled: Bool = true
    var showingStet: Bool = false
    /// **Which verbs this Mac may offer on this row** (P3c Task 5), asked of
    /// the row's own document's posture by the pane (`AnnotationRowVerbs
    /// .decide`). REQUIRED, deliberately: a host that forgot to thread the
    /// posture would otherwise draw every verb, so every host — a test's
    /// included — says what it means (`.unrestricted(isOwn:)` is the P1
    /// surface, by name). Carries ownership too (`ownNote`): Edit + Delete of
    /// the local writer's own note. A verb the posture forbids is not drawn;
    /// `verbsEnabled` below is a different question (is there a live document
    /// to append to at all).
    let verbs: AnnotationRowVerbs
    /// **Whether this row's verbs can act** (M3 P2 Task 7). False in the
    /// cross-document scope when the row's piece is closed: there is no live
    /// `Document` to append to, and the alternative — a transient one — would
    /// land an op the writer's ⌘Z could never reach. Disabled WITH a reason,
    /// never enabled and silently inert (RULING-35).
    var verbsEnabled: Bool = true
    var verbsDisabledReason: String? = nil
    /// Multiselect (M3 P2 Task 5) — true only while the pane is in selection
    /// mode. The control is a `Button`, so it takes the click the row's
    /// whole-body `.onTapGesture` would otherwise read as navigation: selecting
    /// a note and travelling to it are different intentions and must not share
    /// a gesture.
    var isSelectable: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: () -> Void = {}
    let onAccept: () -> Void
    let onReject: () -> Void
    /// M3 P2's fourth resolution — read, considered, and the words stand.
    var onStet: () -> Void = {}
    /// Set or clear the note's triage mark (nil clears). Pane-only: the margin
    /// card deliberately has no triage affordance — see `ReviewCardActions`.
    var onTriage: (TriageMark?) -> Void = { _ in }
    let onArchive: () -> Void
    let onReply: () -> Void
    /// The translator's answer that becomes doctrine (publish department, Task
    /// 8). Defaulted to a no-op so every host predating it still compiles —
    /// and never drawn where it would do nothing, since the affordance is
    /// gated on `QueryRuling.offersARuling` rather than on the closure.
    var onAnswerAsRuling: () -> Void = {}
    /// **This is a choice** — a stet that also files the habit heading this
    /// note was raised under (editorial letter P2 Task 8). Defaulted to a no-op
    /// on `onAnswerAsRuling`'s reasoning, and gated on the same shape of
    /// predicate rather than on the closure: nothing draws it where it would do
    /// nothing (`QueueLedgerVerbs.offersAChoice`).
    var onMakeChoice: () -> Void = {}
    /// **Keep as lesson…** on an accepted craft note — spec §6's second door,
    /// gated by `QueueLedgerVerbs.offersAKeep`.
    var onKeepAsLesson: () -> Void = {}
    var onEdit: () -> Void = {}
    var onWithdraw: () -> Void = {}
    var onRevert: () -> Void = {}
    /// RULING-29: resolution is the writer's to reverse, from the surface that
    /// shows it — rendered for archived, rejected and (M3 P2) stetted rows.
    var onReopen: () -> Void = {}
    let onJumpToParagraph: () -> Void
    /// The lessons ledger's markdown as the host last read it — what withdraws
    /// *Keep as lesson…* over a sentence that already stands (P3 Task 8,
    /// Denver's ruling B). Defaulted to nil, which is the ledger of a project
    /// whose writer has kept nothing: every offer stands.
    var ledgerText: String? = nil
    /// **The project's own identity, for the one control that needs it** (two
    /// loops P2 Task 5): whether this note is the first reader's is a question
    /// about `ProjectManifest.firstReaderName`, and the row is where the
    /// affordance is drawn.
    ///
    /// **Undefaulted, deliberately** (P2 Task 6, Task 5's review): a row built
    /// with no project identity draws the translator's *Answer as ruling…* —
    /// which turns on the note's own language tag — and never hers, which
    /// needs a name to file under (`RulingDestination.offered`). A default of
    /// nil would let a second host withdraw her offer by simply not mentioning
    /// her, with nothing red anywhere. `nil` stays a valid ANSWER; it just has
    /// to be given.
    let manifest: ProjectManifest?

    /// Where an *Answer as ruling…* press on this row would file — asked once,
    /// so the control, its help and the commit cannot disagree about the
    /// destination.
    private var rulingDestination: RulingDestination? {
        RulingDestination.offered(for: annotation, manifest: manifest)
    }

    private var offered: AnnotationRowVerbs { verbs }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isSelectable { selectionToggle }
            rowContent
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onJumpToParagraph() }
        .animation(.easeInOut(duration: 0.3), value: showingStet)
    }

    @ViewBuilder
    private var selectionToggle: some View {
        Button(action: onToggleSelection) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
        .help(isSelected ? "Deselect this note" : "Select this note")
        .accessibilityLabel(isSelected ? "Selected" : "Not selected")
    }

    @ViewBuilder
    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Text(annotation.body)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = annotation.previousRejectionReason, !reason.isEmpty {
                // RULING-31: the writer's rejection reason is part of the
                // note's history and stays visible after a reopen.
                Text("Previously rejected: \(reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }
            // Stet reaches every kind now, so the flourish has to as well —
            // it can no longer live inside the suggestion-only diff card.
            if showingStet {
                stetCard
            } else if annotation.kind == .suggestedChange {
                diffCard
            }
            actionRow
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Label(annotation.kind.displayName, systemImage: annotation.kind.systemImageName)
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(kindColor)
            authorBadge
            if annotation.isStale {
                Text("Stale")
                    .font(.caption2.smallCaps())
                    .padding(.horizontal, 4)
                    .background(Color.orange.opacity(0.3))
                    .clipShape(Capsule())
            }
            Spacer()
            Text(relativeTimestamp)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Author provenance badge: a colour dot (matching the editor review marks
    /// via `ReviewPalette`) plus the author's display label. nil author → Claude
    /// with the reserved terracotta dot.
    @ViewBuilder
    private var authorBadge: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(authorColor)
                .frame(width: 7, height: 7)
            Text(AnnotationAuthorPresentation.label(for: annotation.author))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .help("Authored by \(AnnotationAuthorPresentation.label(for: annotation.author))")
    }

    private var authorColor: Color {
        Color(nsColor: ReviewPalette().color(for: annotation.author))
    }

    /// Strips inline task anchors (`<!--t-XXXXXX-->`) from annotation text before
    /// display. Mirrors `AnnotationDetailView.displayText` on the phone side.
    /// Pure + nonisolated so it's directly unit-testable.
    nonisolated static func displayText(_ raw: String) -> String {
        MarkdownDisplayFilter.stripTaskAnchorsInline(raw)
    }

    @ViewBuilder
    private var diffCard: some View {
        VStack(alignment: .leading, spacing: 1) {
            // "Before" matches the suggestion's grain: the SPAN's original
            // text for a sub-paragraph suggestion, else the whole paragraph —
            // so a one-word suggestion reads `very angry → furious`, not
            // `<whole paragraph> → furious` (SuggestionDisplay, shared w/ phone).
            if let prior = SuggestionDisplay.before(for: annotation) {
                Text("\u{2212} \(AnnotationRow.displayText(prior))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
            }
            if let suggested = annotation.suggestedText {
                Text("+ \(AnnotationRow.displayText(suggested))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.08))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// The proofreader's "stet" treatment shown briefly on stetting a note: for
    /// a suggestion the struck prior text is reinstated (no strike), marked with a
    /// dotted underline, and headed by a clear "STET — let it stand" badge so the
    /// gesture is unmistakable rather than a faint italic aside. A subtle tinted
    /// card + the row-level fade give the eye something to catch in the ~2.5s
    /// dwell before the row resolves.
    @ViewBuilder
    private var stetCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("STET")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(stetAccent)
                    .clipShape(Capsule())
                Text("let it stand")
                    .font(.caption2.italic())
                    .foregroundStyle(stetAccent)
            }
            if let prior = SuggestionDisplay.before(for: annotation) {
                Text(AnnotationRow.displayText(prior))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .underline(true, pattern: .dot, color: stetAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(stetAccent.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(stetAccent.opacity(0.5), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .transition(.opacity)
    }

    /// A legible, intentional editor's-ink colour for the stet mark — distinct
    /// from the red/green diff so the eye reads it as a separate gesture.
    private var stetAccent: Color { Color(red: 0.20, green: 0.45, blue: 0.78) }

    /// RULING-29's arm: a resolution is the writer's to reverse, from the
    /// surface that shows it. Stet joined archive and reject there in M3 P2 — it
    /// is a resolution like the other two. Exhaustive on purpose: a fifth status
    /// must decide whether it is reopenable, not inherit an `else`.
    private var showsReopen: Bool {
        switch annotation.status {
        case .archived, .rejected, .stetted: return true
        case .open, .accepted: return false
        }
    }

    /// The row's answers. Every verb keeps its word at the pane's default width;
    /// under pressure (a 240pt column, an own suggestion carrying seven
    /// controls) the secondary ones fall back to icons with the same word as the
    /// tooltip, the way `AdaptiveFilterRow` degrades the kind filter above. The
    /// primary verb — Accept / Got it / Reply — never loses its label.
    ///
    /// **Three variants, not two, because `ViewThatFits` draws its LAST child
    /// whether it fits or not.** Measured 2026-08-15 on the worst honest row —
    /// the writer's own open suggestion, carrying Accept / Reject / Stet /
    /// Archive / triage / edit / delete — the icon variant at the row's default
    /// `spacing: 8` wanted 245pt in a 240pt column and 280.6pt in a 280pt one.
    /// A few points over is the same defect as a hundred: it inflates the pane's
    /// layout width, and everything in the column is then centred against a
    /// width the column does not have. The third variant closes the gaps instead
    /// of taking anything else away, since by that point there is no word left
    /// to lose. `AnnotationsQueueToolbarWidthTests.test_theRowsVerbsFitTheColumn`
    /// is the measurement.
    @ViewBuilder
    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            actions(useIcons: false)
            actions(useIcons: true)
            actions(useIcons: true, spacing: Self.tightVerbSpacing)
        }
        .controlSize(.small)
        // The whole row of verbs, gated together: a closed piece's note is
        // readable and not actable, and the tooltip says what to do about it.
        // The `.help` is applied only when there IS something to say — an
        // empty help string is a tooltip that opens with nothing in it.
        .disabled(!verbsEnabled)
        .modifier(RowDisabledReason(
            reason: verbsEnabled ? nil : verbsDisabledReason))
    }

    /// The gap the last-resort variant closes to. Small enough to buy back the
    /// points the seven-control row was over by, large enough that two bordered
    /// buttons still read as two.
    static let tightVerbSpacing: CGFloat = 3

    @ViewBuilder
    private func actions(useIcons: Bool, spacing: CGFloat = 8) -> some View {
        HStack(spacing: spacing) {
            if showsReopen {
                // (An accepted suggestion keeps its Revert below — reopening it
                // is Revert's job, text included.)
                if offered.dispose {
                    Button("Reopen", action: onReopen).buttonStyle(.bordered)
                        .help("Return this to the open list — resolution is yours to reverse (⌘Z re-applies it)")
                }
            } else {
                dispositions(useIcons: useIcons)
            }
            if offered.dispose { triageMenu }
            if offered.ownNote {
                Spacer(minLength: 4)
                ownAffordances
            }
        }
    }

    /// Every verb here is drawn only where `offered` says this Mac may press
    /// it (P3c Task 5) — hidden, not disabled. The kind still decides which
    /// verbs the row HAS; the posture decides which of those are drawn.
    @ViewBuilder
    private func dispositions(useIcons: Bool) -> some View {
        switch annotation.kind {
        case .comment:
            if offered.acceptOrReject {
                Button("Got it", action: onAccept).buttonStyle(.borderedProminent)
            }
            stetButton(useIcons: useIcons)
            archiveButton(useIcons: useIcons)
        case .suggestedChange:
            if annotation.status == .accepted {
                // Accepted rows (visible under the resolved/All filter):
                // the one meaningful action is putting the text back.
                // ⌘Z only reaches the MOST RECENT accept; this reaches
                // any accepted suggestion at any time.
                if offered.acceptOrReject {
                    Button("Revert", action: onRevert).buttonStyle(.bordered)
                        .disabled(!revertIsEnabled)
                        .help(revertIsEnabled
                              ? "Restore the pre-accept text and reopen this suggestion"
                              : "Its paragraph was deleted — there is nothing to revert into")
                }
            } else {
                if offered.acceptOrReject {
                    Button("Accept", action: onAccept).buttonStyle(.borderedProminent)
                    secondary("Reject\u{2026}", symbol: "xmark", useIcons: useIcons, action: onReject)
                }
                stetButton(useIcons: useIcons)
                archiveButton(useIcons: useIcons)
            }
        case .query:
            if offered.acceptOrReject {
                Button("Reply\u{2026}", action: onReply).buttonStyle(.borderedProminent)
            }
            answerAsRulingButton(useIcons: useIcons)
            choiceButton(useIcons: useIcons)
            stetButton(useIcons: useIcons)
            archiveButton(useIcons: useIcons)
        case .craftNote:
            if offered.acceptOrReject {
                Button("Accept", action: onAccept).buttonStyle(.borderedProminent)
            }
            answerAsRulingButton(useIcons: useIcons)
            keepAsLessonButton(useIcons: useIcons)
            if offered.acceptOrReject {
                secondary("Reject\u{2026}", symbol: "xmark", useIcons: useIcons, action: onReject)
            }
            stetButton(useIcons: useIcons)
            archiveButton(useIcons: useIcons)
        }
    }

    /// Archive — a disposition, drawn only where one may be written here.
    @ViewBuilder
    private func archiveButton(useIcons: Bool) -> some View {
        if offered.dispose {
            secondary("Archive", symbol: "archivebox", useIcons: useIcons, action: onArchive)
        }
    }

    /// **A habit the writer makes on purpose can be settled from the queue**
    /// (editorial letter P2 Task 8, spec §6) — the ledger row and the stet in
    /// one press.
    ///
    /// Beside Stet rather than in place of it, because it is a stet *and* a
    /// declaration: a writer who only means "let it stand this once" still has
    /// the plain verb, and the second time they press it the app asks whether
    /// they meant this one.
    ///
    /// Secondary, and it degrades to its icon under column pressure with the
    /// rest — a question raised under a habit carries one more control than one
    /// that was not, and the narrow column is where that costs a word.
    @ViewBuilder
    private func choiceButton(useIcons: Bool) -> some View {
        if offered.makeChoice, QueueLedgerVerbs.offersAChoice(annotation) {
            secondary(QueueLedgerVerbs.choiceTitle, symbol: "checkmark.seal",
                      useIcons: useIcons,
                      help: QueueLedgerVerbs.choiceHelp,
                      action: onMakeChoice)
        }
    }

    /// **Spec §6's second door** — an accepted craft note's point, kept.
    /// `QueueLedgerVerbs.offersAKeep` says why it is accepted notes and no
    /// others.
    @ViewBuilder
    private func keepAsLessonButton(useIcons: Bool) -> some View {
        if offered.keepAsLesson,
           QueueLedgerVerbs.offersAKeep(annotation, ledgerText: ledgerText) {
            secondary(QueueLedgerVerbs.keepTitle, symbol: "graduationcap",
                      useIcons: useIcons,
                      help: QueueLedgerVerbs.keepHelp,
                      action: onKeepAsLesson)
        }
    }

    /// **A question can be answered into doctrine** — a translator's, into that
    /// edition's brief (publish department, Task 8), or the first reader's own
    /// note, into her statement (two loops P2 Task 5).
    ///
    /// **ONE control, whichever it is.** The two destinations are mutually
    /// exclusive by construction — an edition query carries a `language` and
    /// hers never does — so `RulingDestination.offered` answers at most one,
    /// and the row cannot end up drawing two identical buttons that file in
    /// different places. Only the help changes, because that is the only part
    /// of the control that has to name where the sentence goes.
    ///
    /// Secondary rather than primary: Reply is still the ordinary answer, and
    /// most notes in this queue are neither. It degrades to its icon under
    /// column pressure with the others — such a note carries one more control
    /// than its neighbours, and the narrow column is exactly where that has to
    /// cost a word rather than the pane's layout width.
    @ViewBuilder
    private func answerAsRulingButton(useIcons: Bool) -> some View {
        if offered.answerAsRuling, let destination = rulingDestination {
            secondary("Answer as ruling\u{2026}", symbol: "building.columns",
                      useIcons: useIcons,
                      help: destination.help,
                      action: onAnswerAsRuling)
        }
    }

    /// Stet — offered wherever Archive is, and the margin card mirrors it
    /// (`ReviewCardActions`). The symbol is the proofreader's own mark: dots
    /// under the words that stand.
    @ViewBuilder
    private func stetButton(useIcons: Bool) -> some View {
        if offered.dispose {
            secondary(
                "Stet", symbol: "textformat.abc.dottedunderline", useIcons: useIcons,
                help: "Read, considered — and the words stand. Resolves the note without applying or refusing anything.",
                action: onStet)
        }
    }

    @ViewBuilder
    private func secondary(
        _ title: String, symbol: String, useIcons: Bool,
        help: String? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if useIcons {
                Image(systemName: symbol)
            } else {
                Text(title)
            }
        }
        .buttonStyle(.bordered)
        .help(help ?? title)
    }

    /// What the writer plans to DO about this note — the queue's sort key, not a
    /// resolution. The mark it already holds is checked AND disabled: re-applying
    /// it appends an op whose ⌘Z undoes nothing the writer can see, so the
    /// affordance refuses rather than the verb.
    @ViewBuilder
    private var triageMenu: some View {
        Menu {
            ForEach(TriageMark.allCases, id: \.self) { mark in
                Button {
                    onTriage(mark)
                } label: {
                    if annotation.triage == mark {
                        Label(mark.queueLabel, systemImage: "checkmark")
                    } else {
                        Text(mark.queueLabel)
                    }
                }
                .disabled(annotation.triage == mark)
            }
            if annotation.triage != nil {
                Divider()
                Button("Clear") { onTriage(nil) }
            }
        } label: {
            if let mark = annotation.triage {
                Label(mark.queueLabel, systemImage: mark.symbolName)
            } else {
                Image(systemName: "flag")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(annotation.triage.map { "Triaged \($0.queueLabel) — change or clear it" }
              ?? "Mark what you plan to do about this note")
    }

    /// Edit (pencil) + Delete (trash) for the reviewer's own annotation only.
    @ViewBuilder
    private var ownAffordances: some View {
        Button(action: onEdit) {
            Image(systemName: "pencil")
        }
        .buttonStyle(.bordered)
        .help("Edit your annotation")
        Button(action: onWithdraw) {
            Image(systemName: "trash")
        }
        .buttonStyle(.bordered)
        .help("Delete your annotation")
    }

    private var kindColor: Color {
        switch annotation.kind {
        case .comment: return .blue
        case .suggestedChange: return .orange
        case .query: return .purple
        case .craftNote: return .yellow
        }
    }
    private var relativeTimestamp: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(
            for: annotation.createdAt, relativeTo: Date())
    }
}
