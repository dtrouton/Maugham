import SwiftUI
import MaughamCore

// MARK: - The notices above the timeline

/// **History's standing notices**, in the order the pane has always drawn
/// them: each a statement of fact, a few with the one control that fact allows.
///
/// Owns no state. Every value is the pane's, read in the pane's own `body`
/// pass, and every press is the pane's verb (`HistoryPaneVerbs`), passed in
/// under the verb's own name. `body` returns the notices as a flat sequence,
/// so each lays out as its own child of the pane's `VStack(spacing: 0)`.
@MainActor
struct HistoryNotices: View {
    let projectURL: URL
    let unreadableCheckpointFiles: [CheckpointLoad.UnreadableFile]
    let heldQuarantineRecords: [QuarantineRecord]
    let isRetryingQuarantine: Bool
    let documentProvenance: OpLogProvenance?
    let setAsideChangesByReason: [String: Int]
    let lostHistoryRows: [HistoryPane.LostHistoryRow]
    let chainDeviceNames: [String: String]
    let heldRows: [SetAsideDoor.HeldRow]
    let retirementLine: String?
    let joinedChainLine: String?
    let setAsideRows: [SetAsideDoor.Row]
    let sendToInboxError: String?
    let recoveredReport: RecoveredHistoryReport?
    @Binding var showingRecoveredHistorySheet: Bool
    let retryQuarantine: () -> Void
    let acknowledgeSetAside: () -> Void
    let acknowledgeLostHistory: (String) -> Void
    let sendHeldWordsToInbox: (SetAsideDoor.HeldRow) -> Void
    let sendSetAsideToInbox: (SetAsideDoor.Row) -> Void

    var body: some View {
        if let notice = HistoryPane.unreadableCheckpointNotice(unreadableCheckpointFiles.map(\.name)) {
            Label(notice, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(HistoryPane.unreadableCheckpointDetail(unreadableCheckpointFiles) ?? "")
                // .help is hover-only; the WHY must reach VoiceOver too.
                .accessibilityHint(Text(
                    HistoryPane.unreadableCheckpointDetail(unreadableCheckpointFiles) ?? ""))
            Divider()
        }
        if let notice = HistoryPane.quarantineNotice(heldCount: heldQuarantineRecords.count) {
            HStack(spacing: 8) {
                Label(notice, systemImage: "arrow.uturn.backward.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer(minLength: 4)
                Button("Retry", action: retryQuarantine)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(isRetryingQuarantine)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
        // Signed op log P1's two statements of fact. Orange and caption
        // like the notices above, but with NO control beside them: neither
        // is something the writer can act on. Unsigned history is history —
        // it stays unsigned. Set-aside lines are kept in the backup and are
        // never applied. Saying so is the whole job.
        if let notice = HistoryPane.unsignedHistoryNotice(provenance: documentProvenance) {
            Label(notice, systemImage: "signature")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
        if let notice = HistoryPane.setAsideChangesNotice(byReason: setAsideChangesByReason) {
            // The one control this statement of fact carries (P2a, D2):
            // there is still nothing to bring back, but a sentence that
            // could never be put down was an accusation the writer could
            // only silence by deleting forensics. Acknowledge records the
            // record names in THIS device's UI state and touches nothing
            // under `.maugham/conflicts/`.
            HStack(spacing: 8) {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer(minLength: 4)
                Button("Acknowledge", action: acknowledgeSetAside)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
        // **History this book is missing** (P3b Task 6). A fact about the
        // FOLDER rather than about the draft — every word Maugham had
        // applied is still in it — and the one fact here that a registry
        // verb refuses over, which is why it is the one that can be put
        // down. Orange while it is waiting to be read, secondary once the
        // writer has said they know, because an acknowledged row is a
        // standing explanation rather than a thing to do.
        ForEach(lostHistoryRows) { row in
            HStack(spacing: 8) {
                Label(row.sentence, systemImage: "clock.badge.xmark")
                    .font(.caption)
                    .foregroundStyle(row.acknowledged
                                     ? AnyShapeStyle(.secondary)
                                     : AnyShapeStyle(Color.orange))
                Spacer(minLength: 4)
                if !row.acknowledged {
                    Button("Acknowledge") {
                        acknowledgeLostHistory(row.streamKey)
                    }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .help(HistoryPane.acknowledgeLostHelp)
                        // .help is hover-only; the WHY must reach VoiceOver.
                        .accessibilityHint(Text(HistoryPane.acknowledgeLostHelp))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
        // Signed op log P2a's two chain sentences, drawn together and in
        // this order because the second is the first's context: what this
        // Mac is holding, and whose chain it is holding it against.
        if let notice = HistoryPane.pendingNotice(
            provenance: documentProvenance, names: chainDeviceNames) {
            HStack(spacing: 8) {
                Label(notice, systemImage: "person.badge.clock")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer(minLength: 4)
                // The one History line with a control. It asks the WINDOW
                // to put the sheet up rather than presenting one itself: a
                // pane is a column, the sheet belongs to the project
                // window, and the same request arrives from two other
                // places (a load that held lines, a stranger's file
                // syncing in) that this pane knows nothing about.
                //
                // `forced`, because this is the writer asking — a *Not
                // now* earlier in this session must not silence their own
                // press.
                Button(HistoryPane.admitTitle) {
                    MaughamEvent.postAdmissionRequested(
                        projectURL: projectURL, forced: true)
                }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help(HistoryPane.admitHelp)
                    // .help is hover-only; the WHY must reach VoiceOver.
                    .accessibilityHint(Text(HistoryPane.admitHelp))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
        // **And the held lines nobody can be admitted for** (P3b Task 7).
        // No control: there is nothing the writer could press here that
        // would change either one. A permit this build cannot read wants a
        // newer build; a piece nobody has claimed is settled in People &
        // Devices, where the sentence sends them; an unsigned stream's
        // words come back through the Inbox, which is Task 8's door and
        // which the sentence already names.
        ForEach(heldRows) { row in
            HeldLineNoticeRow(row: row) { sendHeldWordsToInbox($0) }
            Divider()
        }
        if let notice = retirementLine {
            // Orange, unlike the joined-chain fact beneath it: this one is
            // a DIVERGENCE the writer can see from nowhere else. This Mac
            // goes on applying what it writes (`.mine` outranks `.retired`)
            // and every peer sets those lines aside, so the machine holding
            // the words is the only one that can be told.
            Label(notice, systemImage: "moon.zzz")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
        if let notice = joinedChainLine {
            // Secondary, not orange: nothing is wrong, and nothing is
            // being asked of the writer. It is the standing fact the
            // sentence above is measured against.
            Label(notice, systemImage: "link")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
        if !setAsideRows.isEmpty {
            // Listed whether acknowledged or not — the archives are the
            // writer's to read at any time, and an acknowledgement is a
            // statement about the sentence above, never about the evidence.
            VStack(alignment: .leading, spacing: 4) {
                SetAsideRecordsDisclosure(
                    rows: setAsideRows, onSend: sendSetAsideToInbox)
                if let sendToInboxError {
                    Text("Couldn’t send to the Inbox: \(sendToInboxError)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("set-aside-send-error")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
        }
        if let report = recoveredReport, !report.orphans.isEmpty {
            HStack(spacing: 8) {
                Label(HistoryPane.recoveredHistoryNotice(orphanCount: report.orphans.count),
                      systemImage: "tray.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Spacer(minLength: 4)
                Button("View") { showingRecoveredHistorySheet = true }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
    }
}

/// **One held-line sentence, and the one control any of them can carry** (P3b
/// Task 8, extracted in Task 10 for the reason the disclosure beside it was).
///
/// A view of its own rather than an `HStack` in `body` so its width is
/// BOUNDABLE: Task 8's review left this row outside the suite that bounds the
/// set-aside row's button (M5), and a row drawn inline in a pane's body can
/// only be measured by mounting the pane. Its sibling
/// `SetAsideRecordsDisclosure` is the precedent, and `C13`'s whole lesson is
/// that a control added to a column that was already near its width is where
/// this pane goes wrong.
///
/// The sentence is bounded rather than hard-wrapped: these are long and
/// composed live (fix round 2's I1), so the row asks for a modest width and
/// takes whatever the column actually gives it.
@MainActor
struct HeldLineNoticeRow: View {
    let row: SetAsideDoor.HeldRow
    /// What a press does. The view decides nothing: whether a control is drawn
    /// at all is `SetAsideDoor.HeldRow.offersTheDoor`, and what a press writes
    /// is `HistoryPaneVerbs.sendHeldWordsToInbox`.
    var onSend: (SetAsideDoor.HeldRow) -> Void = { _ in }

    /// What the SENTENCE asks for. Narrower than the disclosure's rows, not
    /// wider, although its text is far longer: this row puts a control (or a
    /// *sent* note) on the same LINE, and the two demands add. Measured — at
    /// the disclosure's 220 the already-sent shape asked 415 pt against the
    /// suite's 400 pt bound.
    static let idealWidth: CGFloat = 180

    var body: some View {
        HStack(spacing: 8) {
            Label(row.sentence, systemImage: "clock.badge.questionmark")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .frame(idealWidth: Self.idealWidth, alignment: .leading)
                .accessibilityIdentifier("held-line-notice")
            Spacer(minLength: 4)
            // **The one held line with no other way in** (spec §7.4): a stream
            // nothing signs cannot be admitted, so the words come back as
            // captures or not at all.
            if row.offersTheDoor {
                Button("Send to Inbox") { onSend(row) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help(row.doorHelp)
                    .accessibilityIdentifier("held-line-send-to-inbox")
            } else if let sent = row.sentNote {
                Text(sent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("held-line-sent-note")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The set-aside records disclosure

/// **The list of set-aside archives, which must not decide how wide this window
/// is** (signed op log P2 smoke, find 8).
///
/// An archive's name is its op-log file's name plus a content hash plus an
/// ISO8601 stamp — 99 characters, with no space in it to break at. Drawn as a
/// plain `Text` with no line limit, three of them ask for **559 pt** while the
/// column they are in is pinned to the writer's own width (320 by default), and
/// opening the chevron blanked all three of Denver's columns with the main
/// thread idle.
///
/// **Why that demand is now dangerous.** `ProjectWindow.detailColumn` pins a
/// single width and has always relied on AppKit breaking its
/// `NSSplitViewItem.MaxSize` rather than the content's demand — undocumented
/// tie-breaking, which that method's own doc comment refuses to call a proof
/// and which `DetailColumnWidthTests.test_theFixedColumnWinsAgainstAnUnbreakablePane`
/// is the canary on. **On the macOS 27 SDK that canary is red, and the tie-break
/// has flipped**: the column pinned to 300 resolves to 528, the pane's own
/// demand, in all five of that file's fixed-width cases. So a pane's width is
/// no longer a hint here — it is what the column becomes, and 559 pt of right
/// column in a 1200 pt window leaves the prose below its own floor.
///
/// So two things, and the second is the one that matters. Each row is a single
/// truncated line (middle truncation, because the distinguishing part of these
/// names is the hash and the stamp at the END, and the tooltip carries the
/// whole thing). And the disclosure declares an ideal width OF ITS OWN — 220 pt,
/// measured, against the shipped shape's 559 — which is what actually bounds
/// the pane: `.lineLimit(1)` lowers a row's MINIMUM width, not the ideal it
/// reports upward, so a truncating row alone would have left the demand where
/// it was (falsified by reverting only the frame:
/// `SetAsideRecordsDisclosureTests`' two width cases go red, the truncation
/// still in place).
///
/// **What is NOT established**: that these rows are what collapsed Denver's
/// window. The collapse would not reproduce — a real `HistoryPane` over real
/// `.lines` records, expanded, in a real three-column split at 1200 pt and
/// 900 pt, holds `[240, 879, 320]` / `[200, 680, 240]` with the shipped shape
/// as well as with this one. The demand and the flipped tie-break are both
/// measured; the step from them to three blank columns is inference. The fix is
/// right either way — a forensic list must not bid for the window — and if the
/// blanking recurs with this shipped, the split view itself is the suspect, not
/// these rows.
///
/// `isExpanded` is state with an injectable seed so the expanded case — the one
/// that broke — is measurable windowlessly (`SetAsideRecordsDisclosureTests`);
/// production never passes it, and the disclosure opens closed.
///
/// **C13 was re-run before this list grew a control** (P3b Task 8, 2026-09-23)
/// and did not reproduce: the expanded disclosure inside a real three-column
/// split holds `[240, 639, 320]` at 1200 pt and `[200, 480, 320]` at 900 pt,
/// with the shipped framed detail column and with the pre-27 unframed one
/// alike. The layout is therefore untouched; what is new is a per-row button,
/// and its width is bounded by the same suite that bounds the names.
///
/// **The row carries at most one control, and only where there is something
/// to give back** (spec §7.4): a record whose refused lines held manuscript
/// text offers **Send to Inbox**, once. Everything else is a name and a
/// tooltip, which is what a forensic list is.
@MainActor
struct SetAsideRecordsDisclosure: View {
    let rows: [SetAsideDoor.Row]
    /// What a press does. The view decides nothing: which rows carry a control
    /// is `SetAsideDoor.Row.offersTheDoor`, and what a press writes is
    /// `HistoryPaneVerbs.sendSetAsideToInbox`.
    var onSend: (SetAsideDoor.Row) -> Void = { _ in }
    @State private var isExpanded: Bool

    /// What this list asks for, whatever its rows are called. Narrow enough to
    /// sit inside the History pane's own column at any window size; the rows
    /// stretch to fill whatever they are actually given.
    static let idealWidth: CGFloat = 220

    init(
        rows: [SetAsideDoor.Row],
        onSend: @escaping (SetAsideDoor.Row) -> Void = { _ in },
        initiallyExpanded: Bool = false
    ) {
        self.rows = rows
        self.onSend = onSend
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup("Set-aside records", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(row.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if row.offersTheDoor {
                            Button("Send to Inbox") { onSend(row) }
                                .controlSize(.small)
                                .buttonStyle(.link)
                                .font(.caption2)
                                .help(row.doorHelp)
                                .accessibilityIdentifier("set-aside-send-to-inbox")
                        } else if let sent = row.sentNote {
                            Text(sent)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .accessibilityIdentifier("set-aside-sent-note")
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
        .font(.caption)
        .frame(idealWidth: Self.idealWidth, maxWidth: .infinity, alignment: .leading)
    }
}
