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
/// editor coupling, tripwire 6/7 territory). The unread-count badge ships on the
/// DetailPaneToggle picker (the discoverability signal for the async capture loop).
struct InboxPane: View {
    @Bindable var store: InboxStore
    let projectStore: ProjectStore
    /// Active manuscript document — target of the fast "Promote to Research
    /// for [title]" path. Nil (or an invalid target) hides that menu item.
    let activeDocumentId: String?
    /// True when local transcription is available (Apple Silicon). Gates the
    /// "Transcribe Again" affordance — there's no transcriber on Intel.
    let canTranscribe: Bool
    /// Re-arm + kick transcription for an entry (DocumentStore.retranscribe).
    let retranscribe: (InboxEntry) -> Void

    @State private var editing: InboxEntry?
    @State private var audio = InboxAudioPlayer()
    @State private var promoteError: String?
    /// What the last **Send to Canvas** did, shown in the pane until it ages out.
    ///
    /// **The command's landing place is off-screen by construction**, so §8A.4's
    /// amendment rules that it may not be silent: *"a capture that leaves the
    /// inbox and appears nowhere the writer is looking is the failure this route
    /// exists to remove."* The other half of telling them is
    /// `CanvasCapture.show`, which moves the camera to the card — now if the
    /// canvas is on screen, on its next appearance otherwise.
    ///
    /// **In the pane and NOT a fourth transient banner.** Three
    /// `.overlay(alignment: .top)` banners already share this window and two on
    /// screen at once draw over each other; Task 11 declined to add a fourth and
    /// used an `.alert`, and the one-banner-host fix is its own slice. A window
    /// overlay would also be the wrong place for this one: the writer's eyes are
    /// on the row they just acted on, which is here.
    @State private var sentToCanvas: String?
    @State private var showingTrash = false
    @State private var promotePicking: InboxEntry?
    @State private var palettePicking: InboxEntry?

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let sentToCanvas {
                sentStrip(sentToCanvas)
                Divider()
            }
            if showingTrash {
                trashList
            } else if store.entries.isEmpty {
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
        // Six seconds, as `CanvasPromotionModifier`'s confirmation gives the
        // promotion sentence — and restarted by every send, because the value
        // changes on each one.
        .animation(.easeInOut(duration: 0.2), value: sentToCanvas)
        .task(id: sentToCanvas) {
            guard sentToCanvas != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            sentToCanvas = nil
        }
        .onDisappear { audio.stop() }
        .sheet(item: $editing) { entry in
            // Seed the editor from the entry at sheet-init time (a self-contained
            // subview) so it always opens with the existing transcript — a single
            // imperative @State set just before presenting `.sheet(item:)` doesn't
            // reliably propagate before the sheet's first render.
            EditTranscriptSheet(initialText: entry.transcript ?? "",
                                errorNote: entry.transcriptionError) { newText in
                // A manual edit makes the writer the owner: mark .userEdited so the
                // transcription worker never overwrites it with a later Whisper result.
                Task { await store.updateTranscript(id: entry.id, text: newText, state: .userEdited) }
            }
        }
        .alert("Couldn’t promote", isPresented: Binding(
            get: { promoteError != nil }, set: { if !$0 { promoteError = nil } })
        ) {
            Button("OK", role: .cancel) { promoteError = nil }
        } message: {
            Text(promoteError ?? "")
        }
        .sheet(item: $promotePicking) { entry in
            PromoteTargetPickerSheet(store: projectStore) { docId in
                promote(entry, scope: .document(docId))
            }
        }
        .sheet(item: $palettePicking) { entry in
            PalettePickerSheet(store: projectStore, subject: entry.paletteSubject) { cardId in
                promoteToPalette(entry, cardId: cardId)
            } onCreateCard: { title in
                promoteToPaletteNewCard(entry, title: title)
            }
        }
    }

    private var header: some View {
        HStack {
            if showingTrash {
                Button { showingTrash = false } label: {
                    Label("Inbox", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back to the inbox")
                Text("Trash").font(.headline)
                Spacer()
                if !store.trashedEntries.isEmpty {
                    Text("\(store.trashedEntries.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("Inbox", systemImage: "tray").font(.headline)
                Spacer()
                if !store.entries.isEmpty {
                    Text("\(store.entries.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !store.trashedEntries.isEmpty {
                    Button { showingTrash = true } label: {
                        Label("\(store.trashedEntries.count)", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("View trashed captures (restore from here)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// **Told, and told where.** The sentence names the capture and the persona
    /// the canvas lives in, because the card itself lands clear of the writer's
    /// work — which on any non-empty canvas is outside their viewport.
    private func sentStrip(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark.circle")
            Text(message).font(.caption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .transition(.opacity)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Nothing in the inbox",
            systemImage: "tray",
            description: Text("Capture from MaughamPhone — text, photo, or voice — appears here."))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var trashList: some View {
        if store.trashedEntries.isEmpty {
            ContentUnavailableView(
                "Trash is empty",
                systemImage: "trash",
                description: Text("Trashed captures can be restored from here."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(store.trashedEntries) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: entry.kind))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(title(for: entry)).lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Restore") { Task { await store.restore(id: entry.id) } }
                        .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Restore") { Task { await store.restore(id: entry.id) } }
                }
            }
            .listStyle(.inset)
        }
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
                        .foregroundStyle(entry.transcriptionState == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        // **An inbox row is draggable onto the canvas** (spec §8A.4's amendment):
        // `.inbox` is one of the Plan persona's panes, so the pane can sit in the
        // right-hand column with the canvas in the centre — the two surfaces on
        // screen together is what makes a drag the obvious act, and the capture
        // lands where it is dropped.
        //
        // **PREFIXED, unlike every other `.draggable` in the app.** `ResearchRow`
        // sends `item.id` bare and each existing drop target reads one id space;
        // the canvas is the first that reads two, and an inbox ULID is not
        // tellable apart from a research id. Built through `CanvasDrop`, so the
        // sender and the router cannot disagree about the spelling.
        //
        // **`.contentShape` first, which is `ResearchRow`'s shape and not a
        // flourish**: without it the draggable area is the drawn glyphs only, so
        // a row whose title is short would refuse to start a drag from most of
        // its own width — the row is a `Spacer`-padded `HStack`.
        .contentShape(Rectangle())
        .draggable(CanvasDrop.inboxPayload(for: entry.id)) {
            Text(title(for: entry))
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
        }
        .contextMenu {
            Button("Promote to Research") { promote(entry, scope: .shared) }
            if let target = activePromoteTarget {
                Button("Promote to Research for “\(target.title)”") {
                    promote(entry, scope: .document(target.id))
                }
            }
            Button("Promote to Research for…") { promotePicking = entry }
            Divider()
            if let card = matchingPaletteCard(for: entry) {
                Button("Promote to Palette: “\(card.title)”") {
                    promoteToPalette(entry, cardId: card.id)
                }
            }
            Button("Promote to Palette Card…") { palettePicking = entry }
            // **Beside Promote to Palette, and not redundant with the drag**
            // (spec §8A.4's amendment): a drag is unreachable from the keyboard,
            // unreachable to VoiceOver, and unavailable when the writer has the
            // pane in another persona with no canvas on screen to drop onto.
            Button("Send to Canvas") { sendToCanvas(entry) }
            if entry.kind == .audio {
                Button("Edit Transcript…") { editing = entry }
                // Offer manual (re)transcription for any audio capture except one
                // the writer has hand-edited (we don't clobber `.userEdited`). This
                // covers entries stuck at `.none`/`.onDeviceDraft` that the worker
                // never finished — not just `.failed`/`.whisperFinal` — so a blank
                // capture always has an escape hatch. Re-running picks up the
                // current Settings model.
                if canTranscribe, entry.transcriptionState != .userEdited {
                    Button(transcribeActionLabel(for: entry)) {
                        audio.stop()
                        retranscribe(entry)
                    }
                }
            }
            Divider()
            Button("Trash", role: .destructive) {
                Task { await store.updateStatus(id: entry.id, to: .trashed) }
            }
        }
    }

    // MARK: - Actions

    private func promote(_ entry: InboxEntry, scope: ResearchScope) {
        audio.stop()
        Task {
            do {
                try await store.promoteToResearch(
                    entry, projectStore: projectStore, scope: scope)
            } catch { promoteError = error.localizedDescription }
        }
    }

    private func promoteToPalette(_ entry: InboxEntry, cardId: String) {
        audio.stop()
        Task {
            do {
                try await store.promoteToPaletteCard(
                    entry, projectStore: projectStore, cardId: cardId)
            } catch { promoteError = error.localizedDescription }
        }
    }

    /// **Send to Canvas** (spec §8A.4). `.loose` and never `.dropped`: the command
    /// has no drop point, so it takes the one stated fallback — clear of the
    /// writer's existing work, and **never in a region**. Adding a `joinTarget`
    /// here for symmetry with the drag is that ruling broken, not a tidy-up.
    ///
    /// The `Task { do … catch { promoteError = … } }` shape is this file's, and
    /// the alert it feeds says "Couldn't promote" — which is the right sentence
    /// for the two refusals this can produce (a capture with nothing in it, and an
    /// asset that has gone missing), both of them shared with the palette sibling.
    private func sendToCanvas(_ entry: InboxEntry) {
        audio.stop()
        Task {
            do {
                let node = try await store.sendToCanvas(
                    entry, projectStore: projectStore, placement: .loose)
                // The other half of "told, and told WHERE": select it and move the
                // camera to it — now if the canvas is on screen, on its next
                // appearance otherwise.
                CanvasCapture.show(node, in: projectStore)
                sentToCanvas = "Sent “\(title(for: entry))” to the canvas. "
                    + "Open Plan (⌘1) to see it."
            } catch { promoteError = error.localizedDescription }
        }
    }

    private func promoteToPaletteNewCard(_ entry: InboxEntry, title: String) {
        audio.stop()
        Task {
            do {
                let card = try await projectStore.addPaletteCard(title: title, kind: .other)
                try await store.promoteToPaletteCard(
                    entry, projectStore: projectStore, cardId: card.id)
            } catch { promoteError = error.localizedDescription }
        }
    }

    /// The palette card whose title case-insensitively equals the entry's aimed
    /// `paletteSubject`, if one exists — backs the direct "Promote to Palette:
    /// <title>" menu item.
    private func matchingPaletteCard(for entry: InboxEntry) -> ResearchItem? {
        guard let subject = entry.paletteSubject, !subject.isEmpty else { return nil }
        return projectStore.paletteCardItems().first {
            $0.title.caseInsensitiveCompare(subject) == .orderedSame
        }
    }

    private var activePromoteTarget: StructureItem? {
        guard let id = activeDocumentId,
              projectStore.isResearchScopeTarget(id) else { return nil }
        return TreeWalk.collect(
            in: projectStore.manifest.structure, where: { $0.id == id }).first
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
        if entry.transcriptionState == .failed {
            if let err = entry.transcriptionError, !err.isEmpty {
                return "Failed · \(err)"
            }
            return "Failed · \(relative)"
        }
        if entry.kind == .audio, entry.transcriptionState == .onDeviceDraft {
            return "Draft · \(relative)"
        }
        return relative
    }

    /// "Transcribe" for a capture that has never produced a transcript (`.none`),
    /// "Transcribe Again" once there's a draft/result/failure to replace.
    private func transcribeActionLabel(for entry: InboxEntry) -> String {
        entry.transcriptionState == .none ? "Transcribe" : "Transcribe Again"
    }
}

/// Self-contained transcript editor. Seeds its TextEditor from `initialText` at
/// construction (via `State(initialValue:)`), so the sheet always opens with the
/// existing transcript regardless of `.sheet(item:)` presentation timing.
private struct EditTranscriptSheet: View {
    @State private var text: String
    let errorNote: String?
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(initialText: String, errorNote: String? = nil, onSave: @escaping (String) -> Void) {
        _text = State(initialValue: initialText)
        self.errorNote = errorNote
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Transcript").font(.headline)
            if let errorNote, !errorNote.isEmpty {
                Label(errorNote, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            TextEditor(text: $text)
                .font(.body)
                .frame(minWidth: 360, minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { onSave(text); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
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
