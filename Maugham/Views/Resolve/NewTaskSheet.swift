import SwiftUI
import MaughamCore

/// **New To-Do's sheet** — moved from the Tasks pane unchanged, so it outlives
/// that pane. Offers only the scopes `TaskCreationScopes` files in.
@MainActor
struct NewTaskSheet: View {
    @Binding var taskBody: String
    @Binding var scope: ResolveTaskScope
    let canPickDocumentScope: Bool
    /// Whether the project's own stream takes a task from this Mac (P3c Task
    /// 8) — false only for a posture that files no task there.
    var canPickProjectScope: Bool = true
    /// What the project calls the open piece (`PieceNoun`): the scope reads
    /// "This Chapter / The Book", the window's own words.
    let noun: PieceNoun
    let onCommit: () -> Void
    let onCancel: () -> Void

    /// The one spelling of the verb: the sheet's title, the + button's help
    /// and its VoiceOver label.
    static let title = "New To-Do"
    static func pieceScopeTitle(_ noun: PieceNoun) -> String { "This \(noun.capitalised)" }
    static let bookScopeTitle = "The Book"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.title)
                .font(.headline)
            TextField("To-do", text: $taskBody)
                .textFieldStyle(.roundedBorder)
            HStack {
                Picker("Scope", selection: $scope) {
                    if canPickDocumentScope {
                        Text(Self.pieceScopeTitle(noun))
                            .tag(ResolveTaskScope.document)
                    }
                    if canPickProjectScope {
                        Text(Self.bookScopeTitle).tag(ResolveTaskScope.project)
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
