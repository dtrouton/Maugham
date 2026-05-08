import SwiftUI

struct ConflictDiffSheet: View {
    let conflict: ConflictState
    let onKeepMine: () -> Void
    let onUseCloud: () -> Void
    let onClose: () -> Void

    private var diff: LineDiff {
        LineDiff(mine: conflict.localText, cloud: conflict.externalText)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                pane(side: .mine)
                Divider()
                pane(side: .cloud)
            }
            .background(Color(NSColor.textBackgroundColor))
        }
        .frame(width: 920, height: 600)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text((conflict.path as NSString).lastPathComponent)
                    .font(.headline)
                Text("cloud saved \(conflict.externalModifiedAt, style: .relative) ago — \(diff.hunks.count) hunk\(diff.hunks.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .imageScale(.medium)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    enum Side { case mine, cloud }

    @ViewBuilder
    private func pane(side: Side) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(side == .mine ? "Mine" : "Cloud")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<diff.hunks.count, id: \.self) { hi in
                        hunkView(diff.hunks[hi], side: side)
                            .padding(.bottom, hi < diff.hunks.count - 1 ? 8 : 0)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Color(NSColor.textBackgroundColor))
            Divider()
            HStack {
                Spacer()
                if side == .mine {
                    Button("Keep mine", action: onKeepMine)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Use cloud", action: onUseCloud)
                        .buttonStyle(.bordered)
                }
                Spacer()
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }

    @ViewBuilder
    private func hunkView(_ hunk: LineDiff.Hunk, side: Side) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<hunk.lines.count, id: \.self) { i in
                line(hunk.lines[i], side: side)
            }
        }
    }

    @ViewBuilder
    private func line(_ diffLine: LineDiff.DiffLine, side: Side) -> some View {
        if shouldRender(diffLine.kind, side: side) {
            HStack(spacing: 0) {
                Text(lineNumberText(diffLine, side: side))
                    .frame(width: 36, alignment: .trailing)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 8)
                Text(diffLine.text.isEmpty ? " " : diffLine.text)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
            .background(background(for: diffLine.kind))
        } else {
            // Render an empty placeholder so heights align between panes.
            HStack(spacing: 0) {
                Text(" ")
                    .frame(width: 36)
                Text(" ")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(.body, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
        }
    }

    private func shouldRender(_ kind: LineDiff.LineKind, side: Side) -> Bool {
        switch (kind, side) {
        case (.context, _):     return true
        case (.removed, .mine): return true
        case (.added, .cloud):  return true
        default:                return false
        }
    }

    private func background(for kind: LineDiff.LineKind) -> Color {
        switch kind {
        case .removed: return Color.red.opacity(0.16)
        case .added:   return Color.green.opacity(0.16)
        case .context: return Color.clear
        }
    }

    private func lineNumberText(_ diffLine: LineDiff.DiffLine, side: Side) -> String {
        switch side {
        case .mine:
            if let n = diffLine.mineLineNumber { return String(n) }
            return ""
        case .cloud:
            if let n = diffLine.cloudLineNumber { return String(n) }
            return ""
        }
    }
}
