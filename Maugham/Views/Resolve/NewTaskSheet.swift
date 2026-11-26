import SwiftUI
import MaughamCore

/// **New To-do's sheet** — moved from the Tasks pane unchanged, so it outlives
/// that pane. Offers only the scopes `TaskCreationScopes` files in.
@MainActor
struct NewTaskSheet: View {
    @Binding var taskBody: String
    @Binding var scope: ResolveTaskScope
    let canPickDocumentScope: Bool
    /// Whether the project's own stream takes a task from this Mac (P3c Task
    /// 8) — false only for a posture that files no task there.
    var canPickProjectScope: Bool = true
    let onCommit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New to-do")
                .font(.headline)
            TextField("To-do", text: $taskBody)
                .textFieldStyle(.roundedBorder)
            HStack {
                Picker("Scope", selection: $scope) {
                    if canPickDocumentScope {
                        Text("Document")
                            .tag(ResolveTaskScope.document)
                    }
                    if canPickProjectScope {
                        Text("Project").tag(ResolveTaskScope.project)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(!(canPickDocumentScope && canPickProjectScope))
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Add", action: onCommit)
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(taskBody.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
