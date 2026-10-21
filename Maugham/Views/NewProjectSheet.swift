import SwiftUI
import MaughamCore

struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var selectedType: ProjectType = .shortStory
    @State private var parentURL: URL? = defaultParentURL()
    @State private var isCreating = false
    @State private var errorMessage: String?

    /// Called with the created project URL on success.
    let onCreated: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Project")
                .font(.title2)
                .padding(.bottom, 4)

            Form {
                TextField("Title", text: $name)
                    .textFieldStyle(.roundedBorder)

                Picker("Type", selection: $selectedType) {
                    ForEach(ProjectType.allCases, id: \.self) { type in
                        Text(label(for: type)).tag(type)
                            .help(help(for: type))
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Save in:")
                    Text(parentURL?.path ?? "—")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: pickParent)
                }
            }

            if let err = errorMessage {
                Text(err).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isFormValid || isCreating)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parentURL != nil
    }

    /// The choice's name is the kind's one name (R-4-8), never spelled here.
    private func label(for type: ProjectType) -> String {
        ProjectKindName.of(type)
    }

    private func help(for type: ProjectType) -> String {
        switch type {
        case .shortStory: return "One document of prose."
        case .novel: return "Prose in chapters, arranged in a binder."
        case .screenplay: return "One Fountain screenplay, with a scene navigator."
        case .collection: return "Separate pieces, each in prose or Fountain."
        case .unknown: return ""   // excluded from allCases; never offered here
        }
    }

    private static func defaultParentURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private func pickParent() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK {
            parentURL = panel.url
        }
    }

    @MainActor
    private func create() async {
        guard let parent = parentURL else { return }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        do {
            let url: URL
            switch selectedType {
            case .shortStory:
                url = try await ProjectFactory.createShortStoryProject(
                    named: name, in: parent)
            case .novel:
                url = try await ProjectFactory.createNovelProject(
                    named: name, in: parent)
            case .screenplay:
                url = try await ProjectFactory.createScreenplayProject(
                    named: name, in: parent)
            case .collection:
                url = try await ProjectFactory.createCollectionProject(
                    named: name, in: parent)
            case .unknown:
                // `.unknown` is decode-only (a newer build's project type) and
                // is excluded from `allCases`, so the picker never offers it.
                // Defensive: refuse rather than fabricate a project.
                errorMessage = "Unsupported project type."
                return
            }
            onCreated(url)
            dismiss()
        } catch ProjectFactoryError.projectAlreadyExists(let existing) {
            errorMessage = "A folder named '\(existing.lastPathComponent)' already exists."
        } catch ProjectFactoryError.invalidName {
            errorMessage = "Title cannot be blank."
        } catch ProjectFactoryError.ioError(let msg) {
            errorMessage = "Could not create project: \(msg)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NewProjectSheet(onCreated: { _ in })
}
