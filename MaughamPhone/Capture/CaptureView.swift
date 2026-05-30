import SwiftUI
import MaughamCore

/// The Capture tab root: choose a target project, then land a text / photo /
/// voice capture in its inbox.
///
/// Dependencies are injected via `init` (D.6 constructs this with the app's
/// shared `ProjectsBrowser` + `RecentsTracker`). The selected capture target is
/// persisted in `@AppStorage("currentProjectId")`, keyed by `ProjectManifest.id`
/// so the choice survives folder rename/move just like recents do.
struct CaptureView: View {
    let projectsBrowser: ProjectsBrowser
    let recents: RecentsTracker

    @AppStorage("currentProjectId") private var currentProjectId: String = ""

    @State private var showPicker = false
    @State private var activeSheet: CaptureKind?

    private enum CaptureKind: String, Identifiable {
        case text, photo, voice
        var id: String { rawValue }
    }

    /// The resolved target project, or nil if unset / no longer present (e.g.
    /// the project was removed from the synced folder).
    private var selectedProject: BrowsedProject? {
        guard !currentProjectId.isEmpty else { return nil }
        return projectsBrowser.project(id: currentProjectId)
    }

    /// A writer bound to the selected project's folder. nil when no project is
    /// resolved — the action buttons are disabled in that case.
    private var writer: InboxCaptureWriter? {
        guard let url = selectedProject?.url else { return nil }
        return InboxCaptureWriter(projectRoot: url, deviceId: PhoneDeviceID.current())
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                projectPill

                if selectedProject == nil {
                    Text("Tap above to choose a project")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 16) {
                    actionButton(.text, title: "Text", systemImage: "text.alignleft")
                    actionButton(.photo, title: "Photo", systemImage: "camera")
                    actionButton(.voice, title: "Voice", systemImage: "mic")
                }

                Spacer()
            }
            .padding()
            // Top-anchored: the pill + buttons live under the nav bar, not
            // floated to the vertical centre.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Capture")
        }
        .sheet(isPresented: $showPicker) {
            ProjectPickerSheet(projectsBrowser: projectsBrowser, recents: recents)
        }
        .sheet(item: $activeSheet) { kind in
            // Guard: `writer` is non-nil whenever a sheet can be opened (the
            // buttons are disabled otherwise), but resolve defensively.
            if let writer {
                switch kind {
                case .text:
                    TextCaptureSheet(writer: writer, onCommit: recordCapture)
                case .photo:
                    PhotoCaptureSheet(writer: writer, onCommit: recordCapture)
                case .voice:
                    VoiceCaptureSheet(writer: writer, onCommit: recordCapture)
                }
            }
        }
    }

    // MARK: - Pieces

    private var projectPill: some View {
        Button {
            showPicker = true
        } label: {
            HStack {
                Image(systemName: "folder")
                Text(selectedProject?.manifest.title ?? "Choose project…")
                    .fontWeight(.medium)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func actionButton(_ kind: CaptureKind, title: String, systemImage: String) -> some View {
        Button {
            activeSheet = kind
        } label: {
            Label(title, systemImage: systemImage)
                .font(.title3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        }
        .buttonStyle(.borderedProminent)
        .disabled(writer == nil)
    }

    /// Called by each sheet on a successful commit, recording the capture into
    /// recents (so this project floats to the top of the picker next time).
    private func recordCapture() {
        guard let id = selectedProject?.id else { return }
        recents.recordCapture(into: id)
    }
}
