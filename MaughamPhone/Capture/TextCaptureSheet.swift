import SwiftUI
import MaughamCore

/// Text capture: a full-height editor that lands its contents in the project
/// inbox as a `.text` entry. On success it dismisses and signals the parent
/// (`onCommit`) so the capture is recorded in recents.
struct TextCaptureSheet: View {
    /// The writer bound to the selected project's folder, built by the parent.
    let writer: InboxCaptureWriter
    /// Called after a successful inbox write so `CaptureView` can record the
    /// capture into recents.
    let onCommit: () -> Void

    @State private var text: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var editorFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($editorFocused)
                .padding(.horizontal)
                .navigationTitle("Text Note")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save to Inbox") { save() }
                            .disabled(!canSave)
                    }
                }
                .onAppear { editorFocused = true }
                .alert(
                    "Couldn't Save",
                    isPresented: Binding(
                        get: { errorMessage != nil },
                        set: { if !$0 { errorMessage = nil } })
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "")
                }
        }
    }

    private func save() {
        isSaving = true
        Task {
            do {
                try await writer.writeText(text)
                onCommit()
                dismiss()
            } catch {
                // Stay on the sheet so the writer's text isn't lost on failure.
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                isSaving = false
            }
        }
    }
}
