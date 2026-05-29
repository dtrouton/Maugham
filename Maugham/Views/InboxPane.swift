import SwiftUI
import AVFoundation
import MaughamCore

/// Right-pane triage surface for captures synced from MaughamPhone
/// (`.maugham/inbox/`). Shows `.new` entries newest-first; each row carries a
/// context menu to promote into research, edit a transcript, or trash. Audio
/// rows get an inline play/pause control so the writer can verify a transcript
/// against the recording without leaving the pane.
///
/// Deferred (noted) to a later follow-up: Attach-to-current-document (routes
/// images through ImagePasteHandler and text through the editor-typing path —
/// editor coupling, tripwire 6/7 territory) and a numeric segment-picker badge.
struct InboxPane: View {
    @Bindable var store: InboxStore
    let projectStore: ProjectStore

    @State private var editing: InboxEntry?
    @State private var draftTranscript: String = ""
    @State private var audio = InboxAudioPlayer()
    @State private var promoteError: String?

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
        .onDisappear { audio.stop() }
        .sheet(item: $editing) { entry in editTranscriptSheet(entry) }
        .alert("Couldn’t promote", isPresented: Binding(
            get: { promoteError != nil }, set: { if !$0 { promoteError = nil } })
        ) {
            Button("OK", role: .cancel) { promoteError = nil }
        } message: {
            Text(promoteError ?? "")
        }
    }

    private var header: some View {
        HStack {
            Label("Inbox", systemImage: "tray").font(.headline)
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
            if entry.kind == .audio, let url = store.assetURL(for: entry) {
                Button {
                    audio.toggle(id: entry.id, url: url)
                } label: {
                    Image(systemName: audio.isPlaying(entry.id) ? "pause.circle.fill" : "play.circle")
                }
                .buttonStyle(.borderless)
                .help(audio.isPlaying(entry.id) ? "Pause" : "Play recording")
            } else {
                Image(systemName: icon(for: entry.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: entry)).lineLimit(2)
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
            Button("Promote to Research") { promote(entry) }
            if entry.kind == .audio {
                Button("Edit Transcript…") { beginEditing(entry) }
            }
            Divider()
            Button("Trash", role: .destructive) {
                Task { await store.updateStatus(id: entry.id, to: .trashed) }
            }
        }
    }

    // MARK: - Actions

    private func promote(_ entry: InboxEntry) {
        audio.stop()
        Task {
            do { try await store.promoteToResearch(entry, projectStore: projectStore) }
            catch { promoteError = error.localizedDescription }
        }
    }

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
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { editing = nil }
                Button("Save") {
                    let id = entry.id
                    let text = draftTranscript
                    // Preserve transcription state — a manual edit neither claims
                    // Whisper-quality nor downgrades a draft.
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
        if entry.kind == .audio, entry.transcriptionState == .onDeviceDraft {
            return "Draft · \(relative)"
        }
        return relative
    }
}

/// Minimal single-track player for inbox audio rows: only one row plays at a
/// time; tapping the playing row pauses it. Resets to the start on finish.
@MainActor
@Observable
final class InboxAudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private(set) var playingId: String?

    func isPlaying(_ id: String) -> Bool { playingId == id && player?.isPlaying == true }

    func toggle(id: String, url: URL) {
        if playingId == id { stop(); return }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        p.play()
        player = p
        playingId = id
    }

    func stop() {
        player?.stop()
        player = nil
        playingId = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
