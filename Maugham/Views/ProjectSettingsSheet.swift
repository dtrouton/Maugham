import SwiftUI
import MaughamCore

struct ProjectSettingsSheet: View {
    @Bindable var store: ProjectStore
    @Environment(UserPreferences.self) private var userPreferences
    @Environment(\.dismiss) private var dismiss

    @State private var useDefaults: Bool = true
    @State private var draft: TypographySettings = .defaults
    @State private var reviewPasses: [ReviewPass] = []

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
                reviewPassesSection()
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
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
