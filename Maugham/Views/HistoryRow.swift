import SwiftUI
import MaughamCore

// MARK: - HistoryRow

@MainActor
struct HistoryRow: View {
    let entry: HistoryEntry
    let expanded: Bool
    let lookupOp: (String) -> Op?
    /// The op "Rewind to before this…" opens at — the row op's immediate
    /// predecessor in the opId-ordered log, resolved by the parent pane.
    /// `nil` for the first op (no "before" exists) and for checkpoint rows;
    /// the deep-link button is not offered then, because offering a rewind
    /// that cannot land before the op would be the M4-RW-002 lie again.
    let rewindTarget: Op?
    let onToggle: () -> Void
    let onJump: () -> Void
    let onRevert: () -> Void
    /// Whether *Rewind to before this…* is drawn — only where this Mac may
    /// write the document's text (P3c whole-branch fix wave, C1).
    let offersRewind: Bool
    /// Whether a checkpoint row's *Revert here…* is drawn — only where the
    /// picker would offer at least one document this Mac may write.
    let offersRevert: Bool
    /// Names the project scope the per-row Rewind button posts
    /// `.maughamOpenRewind` to (ADR 0021), so multi-window setups dispatch the
    /// modal only on the window on that project.
    let projectURL: URL

    /// For lifecycle ops (claudeAccept/claudeReject/claudeArchive) the body
    /// of interest is on the CREATION op (claudeComment/claudeSuggestion/
    /// claudeQuery/claudeCraftNote) pointed to by provenance.sourceAnnotationId.
    /// Resolves it from `HistoryTimeline`'s op index when present.
    private func resolvedBody(for op: Op) -> String? {
        if let body = op.provenance?.annotationBody, !body.isEmpty {
            return body
        }
        if let sourceId = op.provenance?.sourceAnnotationId,
           let source = lookupOp(sourceId) {
            return source.provenance?.annotationBody
        }
        return nil
    }

    /// Short paragraph-id chip for the header. Returns nil for ops without
    /// a paragraph anchor (e.g. craft_note creation, checkpoint).
    private func paragraphAnchor(for op: Op) -> String? {
        if let pid = op.changes.first?.paragraphId, !pid.isEmpty {
            return pid
        }
        if let sourceId = op.provenance?.sourceAnnotationId,
           let source = lookupOp(sourceId),
           let pid = source.changes.first?.paragraphId, !pid.isEmpty {
            return pid
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if expanded {
                expandedDetail
            } else {
                collapsedPreview
            }
            if case .checkpoint = entry, offersRevert {
                Button("Revert here…", action: onRevert)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .simultaneousGesture(TapGesture().onEnded { })
            } else if case .op(let op) = entry, mutatesManuscript(op.kind),
                      offersRewind, let before = rewindTarget {
                Button {
                    MaughamEvent.post(
                        .maughamOpenRewind, to: .project(for: projectURL),
                        payload: ["scrub_op_id": before.opId,
                                  "scrub_op_at": before.at])
                } label: {
                    Label("Rewind to before this…", systemImage: "arrow.uturn.backward")
                        .labelStyle(.iconOnly)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("Rewind to before this point…")
                .simultaneousGesture(TapGesture().onEnded { })
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .simultaneousGesture(
            TapGesture().modifiers(.command).onEnded { _ in onJump() })
    }

    private func mutatesManuscript(_ kind: OpKind) -> Bool {
        switch kind {
        case .typingBurst, .externalEdit, .claudeAccept, .claudeAcceptRevert,
             .checkpointRestore:
            return true
        case .bootstrap, .checkpoint, .claudeComment, .claudeSuggestion,
             .claudeQuery, .claudeCraftNote, .claudeReject, .claudeArchive,
             .annotationEdit, .annotationWithdraw, .annotationReopen,
             .annotationStet, .annotationTriage,
             .taskCreate, .taskStatusChange, .taskPriorityChange,
             .taskParentChange, .taskBodyEdit, .taskArchive:
            return false
        case .figureCreate, .figureParked, .figureResumed, .figureCellSet,
             .figureStructure, .figureSettings, .figureImageSet,
             .figurePinSet, .figurePinClear:
            // A figure's own stream: the table or image changes, the words
            // do not (`Deriver.appliesToManuscript`).
            return false
        case .unknown:
            // Newer-build op (ADR 0015): treated as inert by the Deriver, so
            // it doesn't mutate the manuscript on this build.
            return false
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Label(kindLabel, systemImage: kindIcon)
                .font(.caption)
                .foregroundStyle(kindColor)
            if case .op(let op) = entry,
               let pid = paragraphAnchor(for: op) {
                Text("¶\(pid.prefix(6))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Spacer()
            Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var collapsedPreview: some View {
        switch entry {
        case .op(let op):
            switch op.kind {
            case .typingBurst:
                Text("\(op.changes.count) paragraph\(op.changes.count == 1 ? "" : "s") edited")
                    .font(.caption).foregroundStyle(.secondary)
            case .claudeComment, .claudeQuery, .claudeCraftNote, .claudeSuggestion:
                Text(op.provenance?.annotationBody ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            case .claudeAccept:
                if let body = resolvedBody(for: op) {
                    Text(body).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Accepted").font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .claudeAcceptRevert:
                // Inverse of claudeAccept: reverts a previously accepted
                // suggestion, restoring the prior paragraph text.
                // `provenance.sourceAnnotationId` points at the creation op.
                if let body = resolvedBody(for: op) {
                    Text(body).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Accepted suggestion reverted").font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .claudeReject:
                if let r = op.provenance?.userResponse {
                    Text("\"\(r)\"").italic()
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let body = resolvedBody(for: op) {
                    Text(body).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            case .claudeArchive:
                // Show the original annotation body when we have it so the
                // forensic record is legible (the synthesisSource alone
                // — "paragraph deleted" — gives the cause but not the
                // content). Auto-archives from paragraph deletion get
                // both: body + cause.
                if let body = resolvedBody(for: op) {
                    let cause: String = {
                        switch op.provenance?.synthesisSource {
                        case .paragraphDeleted: return " · paragraph deleted"
                        case .rewind:           return " · removed by rewind"
                        default:                return ""
                        }
                    }()
                    Text("\(body)\(cause)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text({
                        switch op.provenance?.synthesisSource {
                        case .paragraphDeleted: return "paragraph deleted"
                        case .rewind:           return "removed by rewind"
                        default:                return "archived"
                        }
                    }() as String)
                    .font(.caption).foregroundStyle(.secondary)
                }
            case .annotationEdit:
                Text(op.provenance?.annotationBody ?? "Annotation edited")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            case .annotationWithdraw:
                Text("Annotation withdrawn")
                    .font(.caption).foregroundStyle(.secondary)
            case .annotationReopen:
                Text("Annotation reopened")
                    .font(.caption).foregroundStyle(.secondary)
            case .annotationStet:
                // Same shape as the reject arm: the writer's own words about
                // why it stands, else the note they were answering.
                if let r = op.provenance?.userResponse {
                    Text("\"\(r)\"").italic()
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let body = resolvedBody(for: op) {
                    Text(body).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Stetted").font(.caption).foregroundStyle(.secondary)
                }
            case .annotationTriage:
                Text(op.provenance?.triageMark.map { "Triaged · \($0)" } ?? "Triage cleared")
                    .font(.caption).foregroundStyle(.secondary)
            case .externalEdit:
                Text("\(op.changes.count) paragraph\(op.changes.count == 1 ? "" : "s") changed externally")
                    .font(.caption).foregroundStyle(.secondary)
            case .checkpoint, .checkpointRestore, .bootstrap:
                EmptyView()
            case .taskCreate, .taskStatusChange, .taskPriorityChange,
                 .taskParentChange, .taskBodyEdit, .taskArchive:
                if let body = op.provenance?.taskBody {
                    Text(body).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    EmptyView()
                }
            case .figureParked:
                if let path = op.figure?.parkedPath {
                    Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    EmptyView()
                }
            case .figureImageSet:
                if let name = op.figure?.image?.filename {
                    Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    EmptyView()
                }
            case .figureCreate, .figureResumed, .figureCellSet, .figureStructure,
                 .figureSettings, .figurePinSet, .figurePinClear:
                EmptyView()
            case .unknown:
                // An op written by a newer Maugham build (ADR 0015). Show a
                // neutral placeholder rather than crash; a future named kind
                // makes this switch a compile error, forcing a real label.
                Text("Newer-version entry").font(.caption).foregroundStyle(.secondary)
            }
        case .checkpoint(let cp):
            Text("\(cp.manuscriptWordCount) words · \(cp.label)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var expandedDetail: some View {
        switch entry {
        case .op(let op):
            if op.kind == .claudeAccept || op.kind == .claudeSuggestion {
                ForEach(Array(op.changes.enumerated()), id: \.offset) { _, change in
                    VStack(alignment: .leading, spacing: 1) {
                        if let prior = change.prior {
                            Text("− \(prior)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.08))
                        }
                        Text("+ \(change.next)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.08))
                    }
                }
            } else if let body = resolvedBody(for: op) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(body).font(.callout)
                    if let resp = op.provenance?.userResponse {
                        Text("Your reply: \"\(resp)\"")
                            .font(.caption).italic()
                            .foregroundStyle(.secondary)
                    }
                    if op.provenance?.synthesisSource == .paragraphDeleted {
                        Text("Auto-archived: paragraph deleted from manuscript.")
                            .font(.caption2).foregroundStyle(.orange)
                    } else if op.provenance?.synthesisSource == .rewind {
                        Text("Auto-archived: paragraph removed by rewind.")
                            .font(.caption2).foregroundStyle(.orange)
                    } else if op.provenance?.synthesisSource == .rejectConvergence {
                        // RULING-33. The paragraph moved and no gesture of the
                        // writer's moved it, so the history has to say who did
                        // and why — otherwise this reads as a second rejection
                        // they do not remember making.
                        Text("Removed a change accepted on another device, so the "
                             + "rejection and the manuscript agree.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            } else if let resp = op.provenance?.userResponse {
                Text("\"\(resp)\"").italic().font(.callout)
            } else {
                collapsedPreview
            }
        case .checkpoint(let cp):
            Text(cp.label).font(.callout)
        }
    }

    private var kindLabel: String {
        switch entry {
        case .op(let op):
            switch op.kind {
            case .typingBurst: return "Typed"
            case .claudeComment: return "Comment"
            case .claudeSuggestion: return "Suggestion"
            case .claudeAccept: return "Accepted"
            case .claudeAcceptRevert: return "Accept reverted"
            case .claudeReject:
                // The convergence repair is a reject the WRITER did not issue
                // (RULING-33) — same op kind, different actor. Labelling both
                // "Rejected" would put an act of Maugham's in the writer's
                // column, which is the same misattribution the `.rewind` /
                // `.paragraphDeleted` arms above exist to avoid.
                return op.provenance?.synthesisSource == .rejectConvergence
                    ? "Rejection applied" : "Rejected"
            case .claudeArchive: return "Archived"
            case .claudeQuery: return "Query"
            case .claudeCraftNote: return "Craft"
            case .externalEdit: return "External edit"
            case .checkpoint: return "Checkpoint"
            case .checkpointRestore:
                switch op.provenance?.synthesisSource {
                case .rewind: return "Rewound"
                case .undoRewind: return "Rewind undone"
                default: return "Reverted"
                }
            case .bootstrap: return "Initial"
            case .taskCreate: return "Task created"
            case .taskStatusChange: return "Task status"
            case .taskPriorityChange: return "Task reorder"
            case .taskParentChange: return "Task nested"
            case .taskBodyEdit: return "Task edited"
            case .taskArchive: return "Task archived"
            case .annotationEdit: return "Annotation edited"
            case .annotationWithdraw: return "Annotation withdrawn"
            case .annotationReopen: return "Annotation reopened"
            // "Stet" is the one user-facing word for the verb (M3 P2) — the
            // pane's button, the margin card's tooltip, the Edit menu's undo
            // and this row all say it.
            case .annotationStet: return "Annotation stetted"
            case .annotationTriage: return "Annotation triaged"
            case .figureCreate: return "Figure created"
            case .figureCellSet: return "Cell edited"
            case .figureStructure: return "Rows or columns changed"
            case .figureSettings: return "Table settings"
            case .figureImageSet: return "Image replaced"
            case .figurePinSet: return "Research pin set"
            case .figurePinClear: return "Research pin cleared"
            case .figureParked: return "Sent to Research"
            case .figureResumed: return "Back from Research"
            case .unknown: return "Newer version"
            }
        case .checkpoint:
            return "Checkpoint"
        }
    }
    private var kindIcon: String {
        switch entry {
        case .op(let op):
            switch op.kind {
            case .typingBurst: return "pencil"
            case .claudeComment: return "bubble.left"
            case .claudeSuggestion: return "wand.and.stars"
            case .claudeAccept: return "checkmark.circle"
            case .claudeAcceptRevert: return "arrow.uturn.backward.circle"
            case .claudeReject: return "xmark.circle"
            case .claudeArchive: return "archivebox"
            case .claudeQuery: return "questionmark.circle"
            case .claudeCraftNote: return "ruler"
            case .externalEdit: return "arrow.down.doc"
            case .checkpoint, .checkpointRestore: return "flag"
            case .bootstrap: return "circle.dashed"
            case .taskCreate, .taskStatusChange, .taskPriorityChange,
                 .taskParentChange, .taskBodyEdit, .taskArchive:
                return "checklist"
            case .annotationEdit: return "pencil"
            case .annotationWithdraw: return "trash"
            case .annotationReopen: return "arrow.uturn.up"
            case .annotationStet: return "checkmark.seal"
            case .annotationTriage: return "line.3.horizontal.decrease.circle"
            case .figureCreate: return "tablecells"
            case .figureCellSet: return "square.and.pencil"
            case .figureStructure: return "rectangle.split.3x3"
            case .figureSettings: return "slider.horizontal.3"
            case .figureImageSet: return "photo"
            case .figurePinSet: return "pin"
            case .figurePinClear: return "pin.slash"
            case .figureParked: return "tray.and.arrow.up"
            case .figureResumed: return "tray.and.arrow.down"
            case .unknown: return "questionmark.square.dashed"
            }
        case .checkpoint: return "flag"
        }
    }
    private var kindColor: Color {
        switch entry {
        case .op(let op):
            switch op.kind {
            case .typingBurst, .bootstrap: return .blue
            case .claudeComment: return .blue
            case .claudeSuggestion: return .orange
            case .claudeAccept: return .green
            case .claudeAcceptRevert: return .teal
            case .claudeReject: return .red
            case .claudeArchive: return .gray
            case .claudeQuery: return .purple
            case .claudeCraftNote: return .yellow
            case .externalEdit: return .purple
            case .checkpoint, .checkpointRestore: return .green
            case .taskCreate, .taskStatusChange, .taskPriorityChange,
                 .taskParentChange, .taskBodyEdit, .taskArchive:
                return Color(red: 0.38, green: 0.76, blue: 0.45)
            case .annotationEdit, .annotationWithdraw, .annotationReopen,
                 .annotationStet, .annotationTriage: return .orange
            case .figureCreate, .figureCellSet, .figureStructure,
                 .figureSettings, .figureImageSet: return .indigo
            case .figurePinSet, .figurePinClear: return .brown
            case .figureParked, .figureResumed: return .mint
            case .unknown: return .gray
            }
        case .checkpoint: return .green
        }
    }
}
