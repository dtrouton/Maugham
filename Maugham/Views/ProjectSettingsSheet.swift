import SwiftUI

struct ProjectSettingsSheet: View {
    @Bindable var store: ProjectStore
    @Environment(UserPreferences.self) private var userPreferences
    @Environment(\.dismiss) private var dismiss

    @State private var useDefaults: Bool = true
    @State private var draft: TypographySettings = .defaults

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
}
