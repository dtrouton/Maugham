import SwiftUI

/// Thin status row at the bottom of the editor pane. Supersedes
/// `GoalIndicatorView`'s floating capsule. Visibility is governed by the
/// caller (gated on the `goalIndicatorsVisible` preference + no-chrome
/// state at the `ProjectWindow` mounting site).
@MainActor
struct EditorStatusFooter: View {
    let goalState: GoalIndicatorState
    let sessionWords: Int
    let sessionStart: Date?
    let paragraphId: String?
    let elementLabel: String?
    /// **The open piece's target, settable here** (shell p3 Task 8 — the old
    /// Inspector's steppers). Nil draws the right label as plain text, exactly
    /// as before; a value makes the label a menu (`PieceTargetMenu`).
    var target: PieceTargetMenu? = nil
    /// The store the target is written to; nil offers no menu.
    var store: ProjectStore? = nil

    @State private var editingTarget = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(Self.leftLabel(
                sessionWords: sessionWords,
                sessionStart: sessionStart))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.centerLabel(
                paragraphId: paragraphId,
                elementLabel: elementLabel))
                .frame(maxWidth: .infinity, alignment: .center)
            rightLabelView
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .regular, design: .default))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.thinMaterial)
    }

    /// The right label: plain text, or — where a target may be set — the same
    /// text as a menu's label, borderless and unmarked, so the line reads as
    /// it always did (`PieceTargetMenu.decide`).
    @ViewBuilder
    private var rightLabelView: some View {
        if let target, let store {
            Menu {
                Button(target.setTitle) { editingTarget = true }
                if target.offersClear {
                    Button(PieceTargetMenu.clearTitle) {
                        Task { try? await PieceTargetMenu.perform(target.write, value: 0, store: store) }
                    }
                }
            } label: {
                Text(Self.rightLabel(for: goalState))
                    .lineLimit(1)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help(target.setTitle)
            .popover(isPresented: $editingTarget, arrowEdge: .top) {
                PieceTargetField(
                    menu: target,
                    onSet: { value in
                        Task { try? await PieceTargetMenu.perform(target.write, value: value, store: store) }
                    },
                    onDone: { editingTarget = false })
                    // One field per target: an edit in progress is never
                    // carried onto another piece's.
                    .id(target.write)
            }
            // The open piece changed under an open popover (a key, MCP's
            // navigate): it closes, so what was typed for one piece is never
            // set on another.
            .onChange(of: target.write) { _, _ in editingTarget = false }
        } else {
            Text(Self.rightLabel(for: goalState))
        }
    }

    // MARK: - Pure formatters (testable)

    nonisolated static let hhmmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    nonisolated static func leftLabel(sessionWords: Int, sessionStart: Date?) -> String {
        let nowStr = hhmmFormatter.string(from: Date())
        if let start = sessionStart {
            let startStr = hhmmFormatter.string(from: start)
            return "\(sessionWords) words · session \(startStr)–\(nowStr)"
        }
        return "\(sessionWords) words this session"
    }

    nonisolated static func centerLabel(
        paragraphId: String?, elementLabel: String?
    ) -> String {
        guard let pid = paragraphId, !pid.isEmpty else { return "" }
        if let el = elementLabel, !el.isEmpty {
            return "¶ \(pid) · \(el)"
        }
        return "¶ \(pid)"
    }

    nonisolated static func rightLabel(for state: GoalIndicatorState) -> String {
        // Reuse the existing GoalIndicatorView format strings verbatim by
        // re-deriving them here — both views render the same human strings.
        if state.isScreenplay {
            let pages = state.pageCount ?? 0
            let pagesStr: String = String(format: "%.1f", pages)
            if let target = state.pageTarget, target > 0 {
                let targetStr: String = String(target)
                let pct: Int = Int((pages / Double(target) * 100).rounded())
                return pagesStr + " / " + targetStr + " pages (" + String(pct) + "%)"
            }
            return pagesStr + " pages"
        }
        let words: String = state.docWordCount.formatted(.number)
        let today: String = state.wordsToday.formatted(.number)
        if let target = state.docWordTarget {
            let pct = percent(state.docWordCount, of: target)
            let targetStr: String = target.formatted(.number)
            return words + " / " + targetStr + " words (" + String(pct)
                + "%) · today: " + today
        }
        if let projectTarget = state.projectWordTarget {
            let pct = percent(state.projectWordCount, of: projectTarget)
            return words + " words · today: " + today
                + " · project " + String(pct) + "%"
        }
        if state.readingMinutes == 0 {
            return words + " words · today: " + today
        }
        return words + " words · " + String(state.readingMinutes)
            + " min read · today: " + today
    }

    private nonisolated static func percent(_ value: Int, of total: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(value) / Double(total)) * 100)
    }
}
