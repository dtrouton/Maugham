import SwiftUI

struct EditorSettingsTab: View {
    @Bindable var themeManager: ThemeManager

    var body: some View {
        Form {
            Section("Typography") {
                Picker("Font", selection: Binding(
                    get: { themeManager.typography.fontFamily },
                    set: { themeManager.typography.fontFamily = $0 }
                )) {
                    ForEach(TypographySettings.curatedFonts, id: \.fontName) { font in
                        Text(font.displayName).tag(font.fontName)
                    }
                }
                .pickerStyle(.menu)

                Stepper(
                    "Size: \(themeManager.typography.fontSize) pt",
                    value: Binding(
                        get: { themeManager.typography.fontSize },
                        set: { themeManager.typography.fontSize = $0 }
                    ),
                    in: 12...24
                )

                VStack(alignment: .leading) {
                    Text("Line height: \(String(format: "%.2f", themeManager.typography.lineHeightMultiplier))")
                    Slider(value: Binding(
                        get: { themeManager.typography.lineHeightMultiplier },
                        set: { themeManager.typography.lineHeightMultiplier = $0 }
                    ), in: 1.4...2.0, step: 0.05)
                }

                Stepper(
                    "Page width: \(themeManager.typography.pageWidthCharacters) chars",
                    value: Binding(
                        get: { themeManager.typography.pageWidthCharacters },
                        set: { themeManager.typography.pageWidthCharacters = $0 }
                    ),
                    in: 60...90
                )

                VStack(alignment: .leading) {
                    Text("Paragraph spacing: \(String(format: "%.1f", themeManager.typography.paragraphSpacingMultiplier))×")
                    Slider(value: Binding(
                        get: { themeManager.typography.paragraphSpacingMultiplier },
                        set: { themeManager.typography.paragraphSpacingMultiplier = $0 }
                    ), in: 0.0...2.0, step: 0.1)
                }
            }

            Section("Focus") {
                Toggle("Typewriter scrolling",
                       isOn: $themeManager.typewriterScroll)
                Toggle("Sentence focus",
                       isOn: $themeManager.sentenceFocus)
                Toggle("Paragraph focus",
                       isOn: $themeManager.paragraphFocus)
                Text("Sentence focus, when on, takes precedence over paragraph focus.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show goal indicators",
                       isOn: $themeManager.goalIndicatorsVisible)
            }
        }
        .formStyle(.grouped)
    }
}
