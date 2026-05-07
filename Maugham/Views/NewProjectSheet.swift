import SwiftUI

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
                if selectedType != .shortStory {
                    Text("\(label(for: selectedType)) projects arrive in milestone 1d. Pick Short Story for now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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
            && selectedType == .shortStory
    }

    private func label(for type: ProjectType) -> String {
        switch type {
        case .shortStory: return "Short Story"
        case .novel: return "Novel"
        case .screenplay: return "Screenplay"
        case .collection: return "Collection"
        }
    }

    private func help(for type: ProjectType) -> String {
        switch type {
        case .shortStory: return "A single-document prose project."
        case .novel: return "A multi-file novel with binder. Available in milestone 1d."
        case .screenplay: return "A Fountain-format screenplay. Available in milestone 1d."
        case .collection: return "A collection of stories. Available in milestone 1d."
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
            let url = try await ProjectFactory.createShortStoryProject(
                named: name, in: parent)
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
