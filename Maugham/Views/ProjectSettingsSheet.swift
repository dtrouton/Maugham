import SwiftUI
import MaughamCore

struct ProjectSettingsSheet: View {
    @Bindable var store: ProjectStore
    @Environment(UserPreferences.self) private var userPreferences
    @Environment(\.dismiss) private var dismiss

    /// **Where a Describe… press hands the writer on** (two loops P2 Task 6).
    ///
    /// The sheet cannot post the `.firstReader` segment event itself: that
    /// post is scoped `.keyWindow`, and while a sheet is up the
    /// KEY window is the sheet's own — the project window behind it would
    /// filter the command out (`MaughamEvent.shouldDeliver`'s `isWindowKey`),
    /// so the act of closing this sheet is what would swallow it. The
    /// presenter records the request and posts it from the `.sheet`'s
    /// `onDismiss`, which is the framework's own "the sheet is gone" hook.
    var onDescribeFirstReader: () -> Void = {}

    @State private var useDefaults: Bool = true
    @State private var draft: TypographySettings = .defaults
    @State private var reviewPasses: [ReviewPass] = []
    /// The first reader's name as the writer is typing it. A draft rather
    /// than a direct binding because `ProjectStore.setFirstReaderName` writes
    /// `project.json` — a manifest write per keystroke is a file write per
    /// keystroke.
    @State private var firstReaderDraft: String = ""
    @FocusState private var firstReaderNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Project Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Text(store.manifest.title)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)

            Form {
                Section("Typography") {
                    Picker("Source", selection: $useDefaults) {
                        Text("Use my defaults").tag(true)
                        Text("Customize for this project").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: useDefaults) { _, newValue in
                        Task { await applyDefaultsToggle(newValue) }
                    }

                    if !useDefaults {
                        Picker("Font", selection: Binding(
                            get: { draft.fontFamily },
                            set: { draft.fontFamily = $0; saveDraft() })) {
                            ForEach(curatedFonts(), id: \.fontName) { font in
                                Text(font.displayName).tag(font.fontName)
                            }
                        }
                        .pickerStyle(.menu)

                        Stepper("Size: \(draft.fontSize) pt",
                                value: Binding(get: { draft.fontSize },
                                               set: { draft.fontSize = $0; saveDraft() }),
                                in: 12...24)

                        VStack(alignment: .leading) {
                            Text("Line height: \(String(format: "%.2f", draft.lineHeightMultiplier))")
                            Slider(value: Binding(get: { draft.lineHeightMultiplier },
                                                  set: { draft.lineHeightMultiplier = $0; saveDraft() }),
                                   in: 1.4...2.0, step: 0.05)
                        }

                        Stepper("Page width: \(draft.pageWidthCharacters) chars",
                                value: Binding(get: { draft.pageWidthCharacters },
                                               set: { draft.pageWidthCharacters = $0; saveDraft() }),
                                in: 60...90)
                    }
                }

                screenplaySection()
                coachSection()
                firstReaderSection()
                reviewPassesSection()
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                // **Done commits the name first** (fix round 1). A SwiftUI
                // Button click does not resign an `NSTextField`, so the field
                // never loses focus before teardown and the draft would go
                // with the sheet — the one control here that can discard the
                // writer's words (constitution must #1). `.onDisappear` on the
                // section catches Escape and every other teardown.
                //
                // **On Done both run, and both write** (whole-branch review of
                // two loops P2, finding M3). The guard they share reads
                // `store.manifest.firstReaderName`, and the first commit's
                // write is a detached `Task` that has not landed by the time
                // `dismiss()` tears the sheet down — so the second sees the
                // same stale value and saves the same string again. It is
                // idempotent and nothing is lost; it costs one extra manifest
                // save on a control the writer presses once. Not fixed by
                // mirroring the committed name in `@State`, which would be a
                // second source of truth for a value the manifest already
                // holds, for a duplicate write of an identical string.
                Button("Done") {
                    commitFirstReaderName()
                    dismiss()
                }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 540, minHeight: 360)
        .task { initializeDraft() }
    }

    private func curatedFonts() -> [TypographySettings.CuratedFont] {
        store.manifest.type == .screenplay
            ? TypographySettings.curatedScreenplayFonts
            : TypographySettings.curatedFonts
    }

    private func initializeDraft() {
        if let override = store.manifest.typography {
            useDefaults = false
            draft = override
        } else {
            useDefaults = true
            draft = userPreferences.typography
        }
        reviewPasses = store.manifest.effectiveReviewPasses
        firstReaderDraft = store.manifest.firstReaderName ?? ""
    }

    private func applyDefaultsToggle(_ usingDefaults: Bool) async {
        if usingDefaults {
            try? await store.setProjectTypography(nil)
        } else {
            // Seed the override with the user-default snapshot
            draft = userPreferences.typography
            try? await store.setProjectTypography(draft)
        }
    }

    private func saveDraft() {
        guard !useDefaults else { return }
        let d = draft
        Task { try? await store.setProjectTypography(d) }
    }

    @ViewBuilder
    private func screenplaySection() -> some View {
        if store.manifest.type == .screenplay {
            Section("Screenplay") {
                Toggle("Show element gutter", isOn: Binding(
                    get: { store.manifest.showElementGutter ?? true },
                    set: { newValue in
                        Task { await applyGutterToggle(newValue) }
                    }))
            }
        }
    }

    private func applyGutterToggle(_ newValue: Bool) async {
        // Persist as nil when value matches default (show), else explicit.
        try? await store.setShowElementGutter(newValue ? nil : false)
    }

    // MARK: - The coach's seat (editorial letter P1, Task 6)

    /// **One row, above the ladder, and the one off switch for the seat**
    /// (spec §4.1).
    ///
    /// It sits BEFORE the pass list because the coach is not a pass: she is
    /// read by every piece the ladder has nothing to say about, and a row
    /// underneath the list would read as a fifth stage.
    ///
    /// **No draft buffer.** The Review Passes section below batches its edits
    /// behind an explicit Save because it is an array of names a writer types;
    /// this is one Bool, and a Save button over a single switch is a control
    /// whose state the writer has to remember. It writes straight through
    /// `ProjectStore.setCoachVacated` — the one verb, deliberately not
    /// `setReviewPasses`, since the coach is never in that array.
    ///
    /// Nothing is confirmed and nothing is destroyed: her past rounds stay in
    /// the diagnostics sidecar as history, and Restore brings her back where
    /// she left off, which is what the footer says.
    @ViewBuilder
    private func coachSection() -> some View {
        let coach = store.manifest.effectiveCoach
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(coach?.effectiveEditorName
                         ?? ReviewPass.coachPreset.effectiveEditorName)
                        .foregroundStyle(coach == nil ? .secondary : .primary)
                    Text(coach == nil
                         ? "The seat is vacant. An unassigned piece is read by "
                           + "the plain all-altitudes reader, signed \u{201C}Claude\u{201D}."
                         : "Reads any piece you haven\u{2019}t assigned a pass to, "
                           + "and signs what she writes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(coach == nil ? "Restore" : "Vacate") {
                    let vacated = (coach != nil)
                    Task { try? await store.setCoachVacated(vacated) }
                }
                .help(coach == nil
                      ? "Put the coach back in the seat"
                      : "Hand unassigned pieces back to the plain reader. Her "
                        + "past rounds stay in the piece\u{2019}s history.")
            }
        } header: {
            Text("Coach")
        } footer: {
            Text("The coach is not a pass \u{2014} she is never a column on the board and never something a piece is done with. Vacating loses nothing: her rounds stay in each piece\u{2019}s history, and restoring the seat brings her back where she left off.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - The first reader (two loops P2, spec §4)

    /// **One specific person the writer writes toward, named here and
    /// described in her own statement** — directly beneath the coach's seat,
    /// because she is the other answer to the same question and neither of
    /// them is a pass.
    ///
    /// **The name is metadata; the description is prose.** The two are
    /// deliberately different kinds of thing and live in different places:
    /// `ProjectManifest.firstReaderName` travels with the book and is what
    /// every surface renders, while what she knows is markdown the writer
    /// edits in a pane (`Statement.Kind.firstReader`). Clearing the name here
    /// takes nothing away from that file.
    ///
    /// **A draft buffer, unlike the coach's row above.** The seat is one Bool
    /// and writes straight through; this is a name being typed, and
    /// `setFirstReaderName` saves the manifest — so it is committed on submit
    /// and on focus loss, never per keystroke. There is no Save button, for
    /// the coach row's own reason: a control whose state the writer has to
    /// remember, over a single field, is worse than a field that keeps itself.
    @ViewBuilder
    private func firstReaderSection() -> some View {
        let describe = Self.describeButton(
            name: firstReaderDraft,
            statementExists: store.statement(kind: .firstReader, scope: .project) != nil)
        Section {
            TextField("Name", text: $firstReaderDraft)
                .focused($firstReaderNameFocused)
                .onSubmit { commitFirstReaderName() }
                .onChange(of: firstReaderNameFocused) { _, focused in
                    if !focused { commitFirstReaderName() }
                }

            HStack {
                Spacer()
                Button(describe.title) { describeFirstReader() }
                    .disabled(!describe.enabled)
                    .help(describe.enabled
                          ? "Open her statement and write down who she is"
                          : "Name her first \u{2014} her statement is about a person")
            }
        } header: {
            Text("First reader")
        } footer: {
            Text("One specific person you write toward, by name. Describe her: what she reads, what she loves, what she will not sit through.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        // Escape, ⌘W, and any other teardown Done does not run through.
        .onDisappear { commitFirstReaderName() }
    }

    /// **What the Describe button says and whether it can be pressed** — pure,
    /// so the rule is assertable with nothing mounted (tripwire 33).
    ///
    /// **`statementExists` is asked of the MANIFEST, not of `FirstReader`.**
    /// `FirstReader.statement` is nil for a statement whose prose is blank,
    /// which is the state a writer is in the moment after they press this
    /// button — reading it here would offer them "Describe…" again over a file
    /// they have already opened, and a second press would be a second look for
    /// a statement that is already there.
    ///
    /// Disabled while the name is empty because the statement is about a
    /// person: there is nobody to describe until she has been named, and a
    /// live button here would mint `first-reader.md` for a reader who does not
    /// exist.
    static func describeButton(
        name: String, statementExists: Bool
    ) -> (title: String, enabled: Bool) {
        let named = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (statementExists ? "Edit description\u{2026}" : "Describe\u{2026}", named)
    }

    /// **Whether the typed name differs from what the manifest holds** — pure,
    /// so the guard every commit path shares is assertable with no window.
    ///
    /// **Compared TRIMMED, on both sides.** `setFirstReaderName` trims what it
    /// stores, so a draft of `" Ursula "` never equals the stored `"Ursula"`
    /// and a raw comparison re-saves `project.json` on every focus loss over a
    /// field the writer has not touched. Nil and blank are the same state for
    /// the same reason: `setFirstReaderName` maps a blank to nil, so an
    /// emptied field is "no first reader" rather than a reader named "".
    static func nameNeedsCommitting(draft: String, stored: String?) -> Bool {
        func normalized(_ value: String?) -> String {
            (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized(draft) != normalized(stored)
    }

    /// Commit the typed name, or clear it. Called from submit, focus loss,
    /// Done and teardown — all four guarded alike.
    ///
    /// **The guard is against the MANIFEST, so it is not synchronous** (M3).
    /// The write below is a detached `Task`; two calls in one turn — Done, then
    /// `.onDisappear` — both read the pre-write value and both save. The same
    /// string either way, so this is a redundant file write rather than a lost
    /// or reordered one, and it is why the four callers are safe to have.
    private func commitFirstReaderName() {
        guard Self.nameNeedsCommitting(
            draft: firstReaderDraft, stored: store.manifest.firstReaderName) else { return }
        let name = firstReaderDraft
        Task { try? await store.setFirstReaderName(name) }
    }

    /// Save the name, make sure she HAS a statement, then hand the writer to
    /// it. The name is committed first because the button is pressable
    /// straight after typing one, with no submit and no focus change in
    /// between — a Describe over an uncommitted name would open a statement
    /// for a reader the manifest has never heard of.
    private func describeFirstReader() {
        let name = firstReaderDraft
        Task { @MainActor in
            // The same guard every other commit path uses — one Task rather
            // than two, so the name is stored before the statement is minted
            // and neither write can land in the other's order.
            if Self.nameNeedsCommitting(
                draft: name, stored: store.manifest.firstReaderName) {
                try? await store.setFirstReaderName(name)
            }
            if store.statement(kind: .firstReader, scope: .project) == nil {
                _ = try? await store.createStatement(kind: .firstReader, scope: .project)
            }
            onDescribeFirstReader()
            dismiss()
        }
    }

    // MARK: - Review Passes (M3 P1 Task 9)

    /// A list editor over `effectiveReviewPasses` — rename in place, add,
    /// delete, drag-reorder. Nothing here writes to the store per keystroke;
    /// Save writes the whole array at once. Rows use a plain always-editable
    /// `TextField`, matching this sheet's existing style for every other
    /// control — there's no `List(selection:)` here and so no rename-mode
    /// focus race to guard against (tripwire 16 doesn't apply: nothing ever
    /// transitions a row INTO rename mode: it's always in it).
    @ViewBuilder
    private func reviewPassesSection() -> some View {
        Section {
            ForEach(reviewPasses) { pass in
                reviewPassRow(pass)
            }

            HStack {
                Button {
                    addReviewPass()
                } label: {
                    Label("Add Pass", systemImage: "plus")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("Save") {
                    saveReviewPasses()
                }
                // A blank-named pass must not persist as a blank column
                // header / ladder row — see `ReviewPassEditorLogic.isSavable`
                // for why the guard is here and not in `renamed`.
                .disabled(!ReviewPassEditorLogic.isSavable(reviewPasses))
                .help(ReviewPassEditorLogic.isSavable(reviewPasses)
                      ? "Save the pass list"
                      : "Every pass needs a name before saving")
            }
        } header: {
            Text("Review Passes")
        } footer: {
            Text("These are the columns on Review's board and the rows on each piece's pass ladder. Removing every pass restores the four defaults — Structural, Line, Copyedit, Proof — rather than leaving the project with none.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func reviewPassRow(_ pass: ReviewPass) -> some View {
        HStack {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Pass name", text: Binding(
                get: { reviewPasses.first { $0.id == pass.id }?.name ?? pass.name },
                set: { reviewPasses = ReviewPassEditorLogic.renamed(reviewPasses, id: pass.id, to: $0) }))

            Spacer()

            Button {
                reviewPasses = ReviewPassEditorLogic.deleted(reviewPasses, id: pass.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("Delete \(pass.name)")
        }
        .draggable(pass.id) {
            Text(pass.name)
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
        }
        .dropDestination(for: String.self) { draggedIds, _ in
            guard let draggedId = draggedIds.first else { return false }
            reviewPasses = ReviewPassEditorLogic.reordered(
                reviewPasses, draggedId: draggedId, droppedOnId: pass.id)
            return true
        }
    }

    private func addReviewPass() {
        reviewPasses = ReviewPassEditorLogic.added(to: reviewPasses, name: "New Pass")
    }

    private func saveReviewPasses() {
        let passes = reviewPasses
        Task { try? await store.setReviewPasses(passes) }
    }
}
