import SwiftUI
import UniformTypeIdentifiers

/// Folder-picking entry point for the security-scoped projects-root bookmark.
///
/// Wraps `UIDocumentPickerViewController` in folder-open mode (`asCopy: false`,
/// so the OS grants security-scoped access to the *original* location rather
/// than copying it into the app sandbox). The picked URL is handed back via
/// `onPick`, where `SettingsView` feeds it to `ProjectsRoot.pick(from:)` to mint
/// + persist the bookmark.
struct DocumentPickerView: UIViewControllerRepresentable {
    /// Called with the chosen folder URL on a successful pick. Not called on
    /// cancel.
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
        // Stateless: nothing to update after presentation.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
