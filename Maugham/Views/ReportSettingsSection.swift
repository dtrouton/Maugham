import SwiftUI
import MaughamCore

/// **What Project Settings' Report section shows** (report plan 4, R-4-7) —
/// pure, built from the manifest alone, so every rule is pinned with nothing
/// mounted (tripwire 33).
///
/// Nil for a screenplay: the section is not there at all. A Collection, or a
/// book carrying a profile a newer Maugham wrote, keeps the section (its kind
/// and its switches still apply) with the Report toggle disabled and the
/// reason in its help.
struct ReportSettingsModel: Equatable {

    /// One switch's row: its effective value, whether the writer has
    /// overridden it (the "Default" button shows only then), and what Default
    /// would put back.
    struct SwitchRow: Equatable, Identifiable {
        let key: ProjectSwitchKey
        let title: String
        let isOn: Bool
        let isOverridden: Bool
        let defaultValue: Bool
        var id: ProjectSwitchKey { key }
    }

    /// The project's kind, from `ProjectKindName` — the read-only Kind row.
    let kindName: String
    /// The profile's name, the Report toggle's label.
    let reportTitle: String
    let isReport: Bool
    let reportToggleEnabled: Bool
    /// Why the Report toggle is disabled; nil when it is not.
    let reportToggleRefusal: String?
    /// Number sections, List of figures, List of tables, in that order.
    let switches: [SwitchRow]
    /// Shown, never pressable: nothing reads it yet.
    let webAccess: SwitchRow

    static let webAccessNote = "Used by the fact-checker (coming)"

    static let caption = "Turning this on or off doesn\u{2019}t change the publish template, "
        + "which was chosen when the project was made. Re-initialise the publish template "
        + "to get the Report layout."

    static func title(of key: ProjectSwitchKey) -> String {
        switch key {
        case .numberSections: return "Number sections"
        case .listOfFigures: return "List of figures"
        case .listOfTables: return "List of tables"
        case .webAccess: return "Web access"
        }
    }

    static func make(_ manifest: ProjectManifest) -> ReportSettingsModel? {
        guard !manifest.type.primaryFormat.isScreenplay else { return nil }
        let refusal: String?
        if case .unknown = manifest.profile {
            refusal = "This project\u{2019}s profile was set by a newer version of Maugham."
        } else if (try? ProjectFactory.refuseUnofferedProfile(.report, on: manifest.type)) == nil {
            refusal = "A \(ProjectKindName.of(manifest.type)) can\u{2019}t carry the Report profile."
        } else {
            refusal = nil
        }
        func row(_ key: ProjectSwitchKey) -> SwitchRow {
            var unset = manifest
            unset.switches?[key] = nil
            return SwitchRow(
                key: key, title: title(of: key),
                isOn: manifest.effectiveSwitch(key),
                isOverridden: manifest.switches?[key] != nil,
                defaultValue: unset.effectiveSwitch(key))
        }
        return ReportSettingsModel(
            kindName: ProjectKindName.of(manifest),
            reportTitle: ProjectKindName.of(ProjectProfile.report) ?? "",
            isReport: manifest.profile == .report,
            reportToggleEnabled: refusal == nil,
            reportToggleRefusal: refusal,
            switches: [row(.numberSections), row(.listOfFigures), row(.listOfTables)],
            webAccess: row(.webAccess))
    }
}

/// **Project Settings' Report section** (R-4-7): the Kind row, the Report
/// toggle (the profile), the three switches each with a Default reset, and
/// Web access shown disabled.
///
/// **Nothing here writes until the writer acts.** Every control is a
/// `Binding` whose setter calls the store door (`setProfile`, `setSwitch`);
/// there is no `onChange`, `onAppear` or `task`, so opening and closing
/// Settings never writes the manifest and a Novel left alone stays at schema 9
/// (review focus 3; `ReportSettingsSectionTests` pins the absence).
struct ReportSettingsSection: View {
    @Bindable var store: ProjectStore
    /// What the last press said when the door refused it.
    @State private var refusal: String?

    var body: some View {
        if let model = ReportSettingsModel.make(store.manifest) {
            Section {
                LabeledContent("Kind", value: model.kindName)

                Toggle(model.reportTitle, isOn: Binding(
                    get: { model.isReport },
                    set: { on in setProfile(on ? .report : nil) }))
                    .disabled(!model.reportToggleEnabled)
                    .help(model.reportToggleRefusal
                          ?? "Numbers sections and lists figures and tables by default")

                ForEach(model.switches) { row in
                    switchRow(row)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Toggle(model.webAccess.title, isOn: .constant(model.webAccess.isOn))
                        .disabled(true)
                    Text(ReportSettingsModel.webAccessNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let refusal {
                    Text(refusal)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text(model.reportTitle)
            } footer: {
                Text(ReportSettingsModel.caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func switchRow(_ row: ReportSettingsModel.SwitchRow) -> some View {
        HStack {
            Toggle(row.title, isOn: Binding(
                get: { row.isOn },
                set: { value in setSwitch(row.key, value) }))
            if row.isOverridden {
                Button("Default") { setSwitch(row.key, nil) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Use the default (\(row.defaultValue ? "on" : "off"))")
            }
        }
    }

    private func setProfile(_ profile: ProjectProfile?) {
        refusal = nil
        Task { @MainActor in
            do { try await store.setProfile(profile) } catch { refusal = Self.sentence(error) }
        }
    }

    private func setSwitch(_ key: ProjectSwitchKey, _ value: Bool?) {
        refusal = nil
        Task { @MainActor in
            do { try await store.setSwitch(key, value) } catch { refusal = Self.sentence(error) }
        }
    }

    /// A refusal in words, never swallowed (RULING-7).
    static func sentence(_ error: Error) -> String {
        if case ProjectFactoryError.profileNotOffered(_, let type) = error {
            return "A \(ProjectKindName.of(type)) can\u{2019}t carry the Report profile."
        }
        return "The project\u{2019}s settings couldn\u{2019}t be saved: \(error.localizedDescription)"
    }
}
