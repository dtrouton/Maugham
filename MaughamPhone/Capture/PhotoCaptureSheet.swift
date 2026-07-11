import SwiftUI
import PhotosUI
import UIKit
import MaughamCore

/// Photo capture: pick from the library (`PhotosPicker`) or take a new shot
/// (`UIImagePickerController`, camera source). Either path yields image `Data`
/// plus a sensible extension, which lands as a `.image` inbox entry.
///
/// The camera option only appears when a camera is actually available
/// (`isSourceTypeAvailable(.camera)` is false on the simulator), so the sheet
/// still RUNS in the simulator with library-only.
struct PhotoCaptureSheet: View {
    let writer: InboxCaptureWriter
    /// The current palette aim (nil = plain inbox), threaded into the write.
    var aim: PaletteAim?
    let onCommit: () -> Void

    @State private var libraryItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if cameraAvailable {
                    Button {
                        showCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                            .font(.title3)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                }

                PhotosPicker(selection: $libraryItem, matching: .images) {
                    Label("Choose from Library", systemImage: "photo.on.rectangle")
                        .font(.title3)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.bordered)
                .disabled(isSaving)

                if isSaving {
                    ProgressView("Saving…")
                }

                Spacer()
            }
            .padding()
            // Top-anchored so the buttons sit under the nav bar rather than
            // floating centre (mirrors tripwire-15's framing intent).
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: libraryItem) { _, newItem in
                guard let newItem else { return }
                Task { await saveLibraryItem(newItem) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                // Camera picker returns JPEG-encoded data; ext is fixed "jpg".
                CameraPicker { data in
                    showCamera = false
                    guard let data else { return }
                    Task { await save(data: data, ext: "jpg") }
                }
                .ignoresSafeArea()
            }
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

    /// Load the picked library asset's bytes and pick an extension from its
    /// declared content type (png stays png; everything else → jpg).
    private func saveLibraryItem(_ item: PhotosPickerItem) async {
        isSaving = true
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = "That photo couldn't be loaded."
                isSaving = false
                return
            }
            let ext = item.supportedContentTypes.contains(.png) ? "png" : "jpg"
            await save(data: data, ext: ext)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            isSaving = false
        }
    }

    private func save(data: Data, ext: String) async {
        isSaving = true
        do {
            try await writer.writeImage(data, ext: ext, paletteSubject: aim?.subject, sense: aim?.sense)
            onCommit()
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            isSaving = false
        }
    }
}

/// Minimal `UIImagePickerController` bridge for the camera source. Library
/// picking uses SwiftUI's `PhotosPicker` instead; this exists only because
/// `PhotosPicker` can't open the live camera.
private struct CameraPicker: UIViewControllerRepresentable {
    /// Called with JPEG data on capture, or nil on cancel.
    let onPicked: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPicked: (Data?) -> Void
        init(onPicked: @escaping (Data?) -> Void) { self.onPicked = onPicked }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.originalImage] as? UIImage
            // 0.9 keeps reference-photo legibility without bloating the inbox.
            onPicked(image?.jpegData(compressionQuality: 0.9))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onPicked(nil)
        }
    }
}
