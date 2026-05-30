import Foundation
import AVFoundation
import Speech

/// Thin async wrappers around the two authorizations the voice-capture flow
/// needs (microphone + speech recognition), so the sheets don't each reimplement
/// the callback→async bridging. Camera/photo-library permission is handled
/// natively by `PhotosPicker` / `UIImagePickerController`, so they're not here.
enum CapturePermissions {

    /// A flattened authorization result the UI can branch on without importing
    /// the per-framework enums.
    enum Status: Equatable {
        case granted
        case denied
        /// The user hasn't been asked yet (shouldn't persist after a request).
        case undetermined
    }

    /// Request microphone-record permission. Wraps the completion-handler API in
    /// async. A prior denial resolves immediately to `.denied` (iOS won't
    /// re-prompt; the UI must point the user at Settings).
    static func requestMicrophone() async -> Status {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted ? .granted : .denied)
            }
        }
    }

    /// Request speech-recognition authorization. Denial here is non-fatal to the
    /// voice flow — the recording still saves, just with an empty draft — so the
    /// caller treats anything other than `.granted` as "no live transcript."
    static func requestSpeech() async -> Status {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { auth in
                let status: Status
                switch auth {
                case .authorized: status = .granted
                case .denied, .restricted: status = .denied
                case .notDetermined: status = .undetermined
                @unknown default: status = .denied
                }
                continuation.resume(returning: status)
            }
        }
    }
}
