import SwiftUI
import MaughamCore

/// **What New Project offers** (report plan 4, R-4-6): the four project
/// types, then Report — a profile over the short-story or novel structure,
/// whose shape (`ProjectFactory.ReportShape`) the sheet asks for separately.
/// Every choice is named by `ProjectKindName`, never spelled here.
enum NewProjectChoice: Hashable {
    case kind(ProjectType)
    case report

    /// The choices in order: the types `ProjectType.allCases` offers, then Report.
    static var all: [NewProjectChoice] {
        ProjectType.allCases.map(NewProjectChoice.kind) + [.report]
    }

    var name: String {
        switch self {
        case .kind(let type): return ProjectKindName.of(type)
        case .report: return ProjectKindName.of(ProjectProfile.report) ?? ""
        }
    }

    /// Only a Report asks "Single document or sections?".
    var asksForAShape: Bool {
        switch self {
        case .kind: return false
        case .report: return true
        }
    }

    var help: String {
        switch self {
        case .kind(.shortStory): return "One document of prose."
        case .kind(.novel): return "Prose in chapters, arranged in a binder."
        case .kind(.screenplay): return "One Fountain screenplay, with a scene navigator."
        case .kind(.collection): return "Separate pieces, each in prose or Fountain."
        case .kind(.unknown): return ""   // excluded from allCases; never offered here
        case .report:
            return "A business or technical report: numbered sections, figures, tables "
                + "and citations, published to PDF and Word."
        }
    }

    /// Creates the project this choice names. `shape` is read for a Report
    /// only.
    func create(named name: String, in parent: URL,
                shape: ProjectFactory.ReportShape) async throws -> URL {
        switch self {
        case .kind(.shortStory):
            return try await ProjectFactory.createShortStoryProject(named: name, in: parent)
        case .kind(.novel):
            return try await ProjectFactory.createNovelProject(named: name, in: parent)
        case .kind(.screenplay):
            return try await ProjectFactory.createScreenplayProject(named: name, in: parent)
        case .kind(.collection):
            return try await ProjectFactory.createCollectionProject(named: name, in: parent)
        case .kind(.unknown):
            // `.unknown` is decode-only (a newer build's project type) and
            // is excluded from `allCases`, so the sheet never offers it.
            // Defensive: refuse rather than fabricate a project.
            throw ProjectFactoryError.ioError("Unsupported project type.")
        case .report:
            return try await ProjectFactory.createReportProject(named: name, in: parent, shape: shape)
        }
    }
}

extension ProjectFactory.ReportShape {
    /// The shape's label in New Project's segmented control.
    var label: String {
        switch self {
        case .singleDocument: return "Single document"
        case .sections: return "Sections"
        }
    }

    var help: String {
        switch self {
        case .singleDocument: return "One document, report.md, with numbered headings inside it."
        case .sections: return "Sections in a binder, starting with an Introduction."
        }
    }
}

struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var choice: NewProjectChoice = .kind(.shortStory)
    @State private var reportShape: ProjectFactory.ReportShape = .singleDocument
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

                Picker("Type", selection: $choice) {
                    ForEach(NewProjectChoice.all, id: \.self) { choice in
                        Text(choice.name).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                Text(choice.help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if choice.asksForAShape {
                    Picker("Shape", selection: $reportShape) {
                        ForEach(ProjectFactory.ReportShape.allCases, id: \.self) { shape in
                            Text(shape.label).tag(shape)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(reportShape.help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
            let url = try await choice.create(named: name, in: parent, shape: reportShape)
            onCreated(url)
            dismiss()
        } catch ProjectFactoryError.projectAlreadyExists(let existing) {
            errorMessage = "A folder named '\(existing.lastPathComponent)' already exists."
        } catch ProjectFactoryError.invalidName {
            errorMessage = "Title cannot be blank."
        } catch ProjectFactoryError.profileNotOffered {
            errorMessage = "This kind of project cannot be made as a \(choice.name)."
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
