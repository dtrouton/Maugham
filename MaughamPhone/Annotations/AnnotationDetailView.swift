import SwiftUI
import MaughamCore

/// Annotation triage detail + write surface (Task F.5). The screen the writer
/// lands on after tapping a row in `AnnotationsListView`: it shows the
/// paragraph context + Claude's note, then offers the three lifecycle actions
/// (Accept / Reject… / Archive) wired to `AnnotationWriter`.
///
/// # The cross-device race-collapse (spec §3.9 / §5.3)
/// The annotation arrives as it was loaded by the list, which may be seconds
/// stale — the writer could have resolved it on the Mac in the meantime. So on
/// appear we RE-DERIVE from the doc's current op log: reload ops, re-run the
/// annotation projection, and look the annotation up by `id`. If it's no longer
/// `.open`, we hide the action buttons and show "Already resolved on another
/// device." rather than letting the writer append a second, conflicting
/// resolution op. (The writer is append-only and the Mac's deriver is
/// last-resolution-wins, so a double-resolve isn't catastrophic — but surfacing
/// the truth beats a phantom second action.)
///
/// # Uniform three-action model (Query included)
/// Per spec §3.9 the lifecycle is exactly accept / reject / archive. We don't
/// special-case `.query` with a separate "reply" op — there is no reply op. A
/// Query's answer is just the reject-reason text, which `AnnotationWriter`
/// already routes into `provenance.userResponse`. So all kinds get the same
/// three actions; the only `.query` nicety is labelling Accept as "Mark
/// answered" and the reason sheet as "Reply" (both feed `userResponse`). This
/// keeps the surface honest about what actually persists.
@MainActor
struct AnnotationDetailView: View {
    /// The annotation as the list loaded it — possibly stale, possibly already
    /// resolved elsewhere. We re-derive `current` from disk on appear.
    let annotation: Annotation
    let projectId: ProjectId
    let projectURL: URL
    let docId: String
    let recents: RecentsTracker
    var io: CoordinatedFileIO = .live
    /// Called after THIS view resolves the annotation (accept/reject/archive), so
    /// the list can reload and drop the now-resolved item from the open set —
    /// the visible "handled" signal. Default no-op for previews/tests.
    var onResolved: () -> Void = {}

    /// The freshest copy we have. Starts as the loaded `annotation`; replaced by
    /// the re-derived value (or left as-is if the reload fails / can't find it).
    @State private var current: Annotation
    /// The reloaded paragraph map, for best-effort "current paragraph text" on
    /// non-suggestion kinds. Empty until the appear re-derive runs.
    @State private var paragraphs: [String: String] = [:]

    /// True once the appear re-derive establishes the annotation is no longer
    /// `.open` on disk (resolved on another device). Hides the action buttons.
    @State private var resolvedElsewhere = false
    /// Drives the action buttons' disabled + spinner state while a write is in
    /// flight, so a double-tap can't append two ops.
    @State private var resolving = false
    /// True after THIS view's action succeeds, so we can show a confirmation +
    /// pop back to the list (which re-derives on next appearance).
    @State private var didResolveHere = false

    @State private var showRejectSheet = false
    @State private var rejectText = ""

    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    init(
        annotation: Annotation,
        projectId: ProjectId,
        projectURL: URL,
        docId: String,
        recents: RecentsTracker,
        io: CoordinatedFileIO = .live,
        onResolved: @escaping () -> Void = {}
    ) {
        self.annotation = annotation
        self.projectId = projectId
        self.projectURL = projectURL
        self.docId = docId
        self.recents = recents
        self.io = io
        self.onResolved = onResolved
        _current = State(initialValue: annotation)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                contextSection
                noteSection
                if resolvedElsewhere || didResolveHere {
                    resolvedNotice
                } else if current.status == .open {
                    actionButtons
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(kindTitle)
        .navigationBarTitleDisplayMode(.inline)
        // Record the project in recents (so the list sections it under "Recent"
        // next time), then collapse the cross-device race by re-deriving status.
        .task {
            recents.recordOpen(projectId)
            await rederive()
        }
        .sheet(isPresented: $showRejectSheet) {
            rejectSheet
        }
        .alert(
            "Couldn't apply",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: AnnotationsIcons.kindSymbol(current.kind))
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(kindTitle)
                .font(.headline)
            if current.isStale {
                Text("stale")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.yellow.opacity(0.25), in: Capsule())
            }
        }
    }

    /// Human label for the annotation kind, also the nav title.
    private var kindTitle: String {
        switch current.kind {
        case .comment:         return "Comment"
        case .suggestedChange: return "Suggested change"
        case .query:           return "Query"
        case .craftNote:       return "Craft note"
        }
    }

    // MARK: - Paragraph context

    /// For a `.suggestedChange` show a clear before/after (priorText "Current" →
    /// suggestedText "Suggested"). For other kinds, show the current paragraph
    /// text if we can find it in the reloaded map (best-effort; absent for
    /// `.craftNote`, which has no paragraphId).
    @ViewBuilder
    private var contextSection: some View {
        if current.kind == .suggestedChange {
            VStack(alignment: .leading, spacing: 12) {
                if let prior = current.priorText, !prior.isEmpty {
                    labeledBlock("Current", text: prior, tint: .secondary)
                }
                if let next = current.suggestedText {
                    labeledBlock("Suggested", text: next, tint: .green)
                }
            }
        } else if let context = paragraphContext, !context.isEmpty {
            labeledBlock("Paragraph", text: context, tint: .secondary)
        }
    }

    /// Best-effort paragraph text for a non-suggestion annotation, from the
    /// reloaded paragraph map keyed by `paragraphId`.
    private var paragraphContext: String? {
        guard let pid = current.paragraphId else { return nil }
        return paragraphs[pid]
    }

    private func labeledBlock(_ label: String, text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Claude's note

    @ViewBuilder
    private var noteSection: some View {
        if !current.body.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("CLAUDE’S NOTE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(current.body)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Actions

    /// Accept / Reject… / Archive, disabled while a write is in flight. For a
    /// Query the affirmative reads "Mark answered" and the reject sheet reads
    /// "Reply" — both still feed `userResponse`, no extra op kinds (see header).
    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                Task { await performAccept() }
            } label: {
                Label(acceptLabel, systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                rejectText = ""
                showRejectSheet = true
            } label: {
                Label(rejectLabel, systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                Task { await performArchive() }
            } label: {
                Label("Archive", systemImage: "archivebox")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if resolving {
                ProgressView().padding(.top, 4)
            }
        }
        .disabled(resolving)
        .padding(.top, 8)
    }

    private var acceptLabel: String { current.kind == .query ? "Mark answered" : "Accept" }
    private var rejectLabel: String { current.kind == .query ? "Reply…" : "Reject…" }

    @ViewBuilder
    private var resolvedNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(.secondary)
            Text(didResolveHere ? "Done." : "Already resolved on another device.")
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    // MARK: - Reject / Reply sheet

    private var rejectSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        current.kind == .query ? "Your reply" : "Reason (optional)",
                        text: $rejectText,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                } footer: {
                    Text(current.kind == .query
                        ? "Your reply is recorded with the annotation for Claude to read."
                        : "An optional note recorded with the rejection.")
                }
            }
            .navigationTitle(current.kind == .query ? "Reply" : "Reject")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showRejectSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(current.kind == .query ? "Send" : "Reject") {
                        showRejectSheet = false
                        Task { await performReject() }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Write actions

    private func makeWriter() -> AnnotationWriter {
        AnnotationWriter(
            projectRoot: projectURL,
            docId: docId,
            deviceId: PhoneDeviceID.current(),
            io: io,
            appVersion: appVersion,
            osVersion: "iOS " + UIDevice.current.systemVersion
        )
    }

    private func performAccept() async {
        await runWrite { writer in
            // A malformed `.suggestedChange` throws here rather than appending an
            // empty accept (which would mark it accepted while materializing
            // nothing — silent data loss). Surface it as an alert.
            do {
                try await writer.accept(current)
            } catch AnnotationWriter.WriteError.malformedSuggestion {
                errorMessage = "This suggestion is malformed and can’t be applied."
                throw CancelledWrite()
            }
        }
    }

    private func performReject() async {
        let reason = rejectText.trimmingCharacters(in: .whitespacesAndNewlines)
        await runWrite { writer in
            try await writer.reject(current, reason: reason.isEmpty ? nil : reason)
        }
    }

    private func performArchive() async {
        await runWrite { writer in
            try await writer.archive(current)
        }
    }

    /// Shared write driver: guards against re-entrancy, runs `body`, and on
    /// success marks the annotation resolved-here and dismisses back to the list.
    /// `CancelledWrite` is the internal "already surfaced an error, stop" signal;
    /// any other thrown error becomes a generic alert.
    private func runWrite(_ body: (AnnotationWriter) async throws -> Void) async {
        guard !resolving else { return }
        resolving = true
        defer { resolving = false }
        do {
            try await body(makeWriter())
            didResolveHere = true
            onResolved()   // tell the list to reload so this item leaves the open set
            dismiss()
        } catch is CancelledWrite {
            // errorMessage already set by the caller.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sentinel so `performAccept`'s malformed-branch can stop `runWrite` without
    /// double-reporting (the alert is already set).
    private struct CancelledWrite: Error {}

    // MARK: - Re-derive (race collapse)

    /// Reload the doc's ops and re-derive this annotation's current status. If it
    /// is no longer open, flag `resolvedElsewhere`; otherwise refresh `current`
    /// (and the paragraph map for context). Best-effort: a failed reload leaves
    /// the loaded values in place and the actions available.
    private func rederive() async {
        guard let ops = try? await OpLogStore(projectURL: projectURL).load(docId: docId) else {
            return
        }
        paragraphs = Deriver.derive(ops: ops).paragraphs
        let derived = AnnotationDeriver.derive(ops: ops, paragraphs: paragraphs)
        guard let fresh = derived.first(where: { $0.id == current.id }) else {
            // Disappeared entirely (e.g. its creation op never landed locally) —
            // treat as resolved-elsewhere; nothing actionable here.
            resolvedElsewhere = true
            onResolved()   // also let the list drop this now-stale item
            return
        }
        if fresh.status == .open {
            current = fresh
        } else {
            // Resolved on another device since the list loaded. Hide the actions
            // (race collapse) AND tell the list to reload so it doesn't keep
            // showing this as open after the writer backs out.
            resolvedElsewhere = true
            current = fresh
            onResolved()
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}
