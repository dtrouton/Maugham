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
    /// The projects this phone has manifests for — where the per-book standing
    /// rows come from. Read-only here: Settings browses nothing and refreshes
    /// nothing; the launch sequence and the Read tab own the browser's state.
    let projectsBrowser: ProjectsBrowser
    /// Which books this phone has actually been in. A standing is per PROJECT
    /// (a chain is a project's, not a device's), and listing every folder under
    /// the root would be a wall of *not yet admitted* for books this phone has
    /// never opened.
    let recents: RecentsTracker
    /// Shared launch gate (also drives the Annotations tab); the Security toggle
    /// binds to its `requireFaceId`. `@Bindable` so `$authGate.requireFaceId`
    /// works against the `@Observable` class.
    @Bindable var authGate: LaunchAuthGate

    @State private var showFolderPicker = false

    /// This phone's standing in each recent book, by project id, and its own
    /// code. Resolved off the main actor in `.task`: a registry read is a
    /// directory walk plus a signature check per record.
    @State private var standings: [ProjectId: DeviceStanding] = [:]
    @State private var code: String = ""
    @State private var resolvedStandings = false

    var body: some View {
        NavigationStack {
            Form {
                thisDeviceSection
                projectsFolderSection
                permissionsSection
                securitySection
                aboutSection
            }
            .navigationTitle("Settings")
            .task { await resolveStandings() }
            // The standing changes on the MAC — the writer admits this phone
            // there and comes back here to check. A pull re-reads rather than
            // making them relaunch; it is a refresh, not a control over
            // admission (§4.11).
            .refreshable { await resolveStandings() }
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

    // MARK: - This device (spec §4.3, §4.11)

    /// **What this phone is, in each book it has been in.** Facts and no
    /// control: admission is a Mac act in this milestone, and a button here
    /// would promise the writer something this device cannot do.
    ///
    /// The code is first and on its own, because its whole job is to be
    /// compared with the code on the Mac's admission sheet — one screen read
    /// against another. The per-book lines are the same sentence People &
    /// Devices draws for the Mac itself (`DeviceStanding`, MaughamCore), so
    /// the two surfaces cannot describe one state in two ways.
    private var thisDeviceSection: some View {
        Section {
            LabeledContent("Code", value: code.isEmpty ? "—" : code)
            ForEach(standingRows, id: \.project.id) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.project.manifest.title)
                    Text(row.standing.sentence)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("This Device")
        } footer: {
            Text(standingFooter)
        }
    }

    /// One row per book this phone has opened or captured into, by title.
    private var standingRows: [(project: BrowsedProject, standing: DeviceStanding)] {
        let recent = recents.recents
        return projectsBrowser.projects
            .filter { recent.contains($0.id) }
            .compactMap { project in
                standings[project.id].map { (project, $0) }
            }
            .sorted { $0.project.manifest.title.localizedCaseInsensitiveCompare(
                $1.project.manifest.title) == .orderedAscending }
    }

    private var standingFooter: String {
        if !standingRows.isEmpty {
            return "Admission happens on your Mac. Until it does, what you write "
                 + "here waits rather than being lost."
        }
        if !resolvedStandings { return "Reading this phone\u{2019}s standing\u{2026}" }
        return "Open a book on this phone to see whether it is on that book\u{2019}s chain."
    }

    /// Resolve this phone's standing in each recent book. A registry that will
    /// not READ is never answered *not yet admitted* (RULING-54) — the standing
    /// carries the read's own sentence instead, so a permissions error cannot
    /// read as a Mac that has not got round to it.
    private func resolveStandings() async {
        let recent = recents.recents
        let projects = projectsBrowser.projects
            .filter { recent.contains($0.id) }
            .map { (id: $0.id, url: $0.url) }

        let resolved = await Task.detached(priority: .userInitiated) {
            () -> (code: String, standings: [ProjectId: DeviceStanding]) in
            let mine = LocalIdentities.current
            var answers: [ProjectId: DeviceStanding] = [:]
            for project in projects {
                do {
                    let registry = try RegistryReader.load(projectURL: project.url)
                    answers[project.id] = DeviceStanding.resolve(
                        registry: registry, cache: .shared, mine: mine, for: project.url)
                } catch {
                    answers[project.id] = DeviceStanding.refused(mine: mine, error: error)
                }
            }
            return (DeviceCode.short(mine.author.fingerprint), answers)
        }.value

        code = resolved.code
        standings = resolved.standings
        resolvedStandings = true
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
