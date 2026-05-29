import SwiftUI
import MaughamCore

/// Right-pane triage surface for captures synced from MaughamPhone
/// (`.maugham/inbox/`). Shows `.new` entries newest-first; each row carries a
/// context menu to edit a transcript or trash the capture.
///
/// Phase B scope: display + Edit transcript + Trash. Deferred (noted) to a
/// Phase B follow-up: inline audio playback (AVAudioPlayer), Promote-to-research
/// (ProjectStore.addResearchAsset + coordinated asset move), and Attach-to-doc.
struct InboxPane: View {
    @Bindable var store: InboxStore

    @State private var editing: InboxEntry?
    @State private var draftTranscript: String = ""

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.entries.isEmpty {
                emptyState
            } else {
                List(store.entries) { entry in
                    row(entry)
                }
                .listStyle(.inset)
            }
        }
        // Tripwire #15: empty-state panes need BOTH the inner ContentUnavailableView
        // frame and this outer frame, or the toolbar floats to vertical center.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await store.refresh() }
        .sheet(item: $editing) { entry in
            editTranscriptSheet(entry)
        }
    }

    private var header: some View {
        HStack {
            Label("Inbox", systemImage: "tray")
                .font(.headline)
            Spacer()
            if !store.entries.isEmpty {
                Text("\(store.entries.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Nothing in the inbox",
            systemImage: "tray",
            description: Text("Capture from MaughamPhone — text, photo, or voice — appears here."))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(_ entry: InboxEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: entry.kind))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: entry))
                    .lineLimit(2)
                if let subtitle = subtitle(for: entry) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contextMenu {
            if entry.kind == .audio {
                Button("Edit Transcript…") { beginEditing(entry) }
            }
            Button("Trash", role: .destructive) {
                Task { await store.updateStatus(id: entry.id, to: .trashed) }
            }
        }
    }

    // MARK: - Edit transcript

    private func beginEditing(_ entry: InboxEntry) {
        draftTranscript = entry.transcript ?? ""
        editing = entry
    }

    private func editTranscriptSheet(_ entry: InboxEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Transcript").font(.headline)
            TextEditor(text: $draftTranscript)
                .font(.body)
                .frame(minWidth: 360, minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { editing = nil }
                Button("Save") {
                    let id = entry.id
                    let text = draftTranscript
                    // Preserve the entry's transcription state — a manual edit
                    // neither claims Whisper-quality nor downgrades a draft.
                    let state = entry.transcriptionState
                    Task { await store.updateTranscript(id: id, text: text, state: state) }
                    editing = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    // MARK: - Row presentation

    private func icon(for kind: InboxEntry.Kind) -> String {
        switch kind {
        case .text:  return "square.and.pencil"
        case .image: return "photo"
        case .audio: return "mic"
        }
    }

    private func title(for entry: InboxEntry) -> String {
        if let t = entry.title, !t.isEmpty { return t }
        let body = entry.inlineText ?? entry.transcript ?? ""
        if !body.isEmpty { return String(body.prefix(60)) }
        switch entry.kind {
        case .image: return "Photo capture"
        case .audio: return "Voice capture"
        case .text:  return "Text capture"
        }
    }

    private func subtitle(for entry: InboxEntry) -> String? {
        let relative = Self.relativeFormatter.localizedString(
            for: entry.createdAt, relativeTo: Date())
        // For audio with a transcript already shown in the title, just the time.
        if entry.kind == .audio, entry.transcriptionState == .onDeviceDraft {
            return "Draft · \(relative)"
        }
        return relative
    }
}
