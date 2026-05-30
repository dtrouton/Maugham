import SwiftUI
import AVFoundation
import Speech
import Photos
import MaughamCore

/// The Settings tab: projects-folder access, capture permissions, and build
/// identity. The only tab that mutates `ProjectsRoot` (via the folder re-pick),
/// so it owns the document-picker presentation.
@MainActor
struct SettingsView: View {
    let projectsRoot: ProjectsRoot
    /// Shared launch gate (also drives the Annotations tab); the Security toggle
    /// binds to its `requireFaceId`. `@Bindable` so `$authGate.requireFaceId`
    /// works against the `@Observable` class.
    @Bindable var authGate: LaunchAuthGate

    @State private var showFolderPicker = false

    var body: some View {
        NavigationStack {
            Form {
                projectsFolderSection
                permissionsSection
                securitySection
                aboutSection
            }
            .navigationTitle("Settings")
        }
        .sheet(isPresented: $showFolderPicker) {
            DocumentPickerView { url in
                // `pick` mints + persists the bookmark and starts access. A
                // throw here means the OS refused to bookmark the grant; surface
                // it through the picker state so the status row updates.
                do {
                    try projectsRoot.pick(from: url)
                } catch {
                    projectsRoot.picker = .resolveFailed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Projects folder

    private var projectsFolderSection: some View {
        Section("Projects Folder") {
            HStack {
                Text(folderStatusLabel)
                    .foregroundStyle(folderStatusIsProblem ? .red : .primary)
                Spacer()
            }
            if let detail = folderStatusDetail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Choose Projects Folder") {
                showFolderPicker = true
            }
        }
    }

    /// Primary status line: the folder name when we have a working root, else a
    /// short state label.
    private var folderStatusLabel: String {
        if let url = projectsRoot.rootURL {
            return url.lastPathComponent
        }
        switch projectsRoot.picker {
        case .idle:           return "No folder chosen"
        case .needed:         return "No folder chosen"
        case .stale:          return "Folder access expired"
        case .accessDenied:   return "Access denied"
        case .resolveFailed:  return "Couldn't open folder"
        }
    }

    /// Whether the status line should read as an error needing action.
    private var folderStatusIsProblem: Bool {
        if projectsRoot.rootURL != nil { return false }
        switch projectsRoot.picker {
        case .stale, .accessDenied, .resolveFailed: return true
        case .idle, .needed: return false
        }
    }

    /// A re-pick prompt / reason for the problem states; nil when all is well.
    private var folderStatusDetail: String? {
        if projectsRoot.rootURL != nil { return nil }
        switch projectsRoot.picker {
        case .needed:
            return "Choose the iCloud-Drive folder that holds your Maugham projects."
        case .stale:
            return "Your saved folder access expired. Choose the folder again to reconnect."
        case .accessDenied:
            return "The system denied access to that folder. Choose it again."
        case .resolveFailed(let reason):
            return reason
        case .idle:
            return nil
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section {
            permissionRow(title: "Microphone", status: micStatus)
            permissionRow(title: "Speech Recognition", status: speechStatus)
            permissionRow(title: "Camera", status: cameraStatus)
            permissionRow(title: "Photo Library", status: photoStatus)
            Button("Open Settings") {
                // Deep-link to this app's iOS Settings pane so the writer can
                // flip a denied permission (we can't re-prompt once denied).
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Capture needs these. If a permission is denied, enable it in Settings.")
        }
    }

    private func permissionRow(title: String, status: PermissionStatus) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(status.label)
                .foregroundStyle(status.tint)
        }
    }

    /// Coarse tri-state for display. We don't distinguish iOS's finer-grained
    /// cases (restricted, limited, provisional) here — Granted / Denied / Not
    /// determined is all the row needs.
    private enum PermissionStatus {
        case granted, denied, notDetermined

        var label: String {
            switch self {
            case .granted:        return "Granted"
            case .denied:         return "Denied"
            case .notDetermined:  return "Not determined"
            }
        }

        var tint: Color {
            switch self {
            case .granted:        return .green
            case .denied:         return .red
            case .notDetermined:  return .secondary
            }
        }
    }

    private var micStatus: PermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:     return .granted
        case .denied:      return .denied
        case .undetermined: return .notDetermined
        @unknown default:  return .notDetermined
        }
    }

    private var speechStatus: PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:     return .granted
        case .denied, .restricted: return .denied
        case .notDetermined:  return .notDetermined
        @unknown default:     return .notDetermined
        }
    }

    private var cameraStatus: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:     return .granted
        case .denied, .restricted: return .denied
        case .notDetermined:  return .notDetermined
        @unknown default:     return .notDetermined
        }
    }

    private var photoStatus: PermissionStatus {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: return .granted
        case .denied, .restricted:  return .denied
        case .notDetermined:        return .notDetermined
        @unknown default:           return .notDetermined
        }
    }

    // MARK: - Security (spec §3.14)

    /// The opt-in per-launch Face ID gate over the Annotations tab. Disabled with
    /// a hint when the device has no passcode set (biometrics can't be evaluated,
    /// so the gate would fail-open anyway).
    private var securitySection: some View {
        Section {
            Toggle("Require Face ID on launch", isOn: $authGate.requireFaceId)
                .disabled(!authGate.canUseBiometrics)
            if !authGate.canUseBiometrics {
                Text("Set a passcode in iOS Settings to enable this option.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Security")
        } footer: {
            Text("When enabled, \(BuildVariant.current.displayName) asks for Face ID each time you open the app and switch to the Annotations tab. It doesn’t affect capture or reading. Your data is always protected by your iOS device passcode.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Variant", value: BuildVariant.current.displayName)
            LabeledContent("Version", value: appVersion)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}
