import SwiftUI
import MaughamCore

/// Read-only diagnostic pill showing the resolved iCloud collaboration role for
/// the currently-open project. This is the spike's verification surface: it lets
/// the user confirm — on a real iCloud Collaborate share — that the OS resource
/// keys resolve to the expected posture before the role is wired into the editor
/// membrane (a later task).
///
/// It reads the share metadata exactly ONCE per project (on appear, and again if
/// the project URL changes) and caches the result. Resource reads can lag or
/// block on a freshly-mounted ubiquitous item, so it deliberately does NOT poll
/// or read per-render.
///
/// Placement mirrors `PublishStatusPill` (top-trailing overlay of the editor
/// pane). Tasteful and quiet; it can become the permanent sharing-status UI.
@MainActor
struct SharingStatusPill: View {

    let projectURL: URL

    /// Injected so tests / the phone can substitute a reader. Defaults to the
    /// real OS-backed Mac reader.
    var reader: ShareMetadataReading = ICloudShareMetadataReader()

    @State private var collaborator: Collaborator?

    var body: some View {
        Group {
            if let collaborator {
                pill(for: collaborator)
            }
        }
        .task(id: projectURL) {
            // Read once per project URL, off the main actor's critical path.
            let url = projectURL
            let r = reader
            let resolved = await Task.detached(priority: .utility) {
                ShareIdentityMapper.resolve(r.read(for: url))
            }.value
            collaborator = resolved
        }
    }

    @ViewBuilder
    private func pill(for c: Collaborator) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol(for: c.role))
                .font(.caption)
            Text(label(for: c))
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sharing status: \(label(for: c))")
        .help(helpText(for: c))
    }

    private func symbol(for role: CollaborationRole) -> String {
        switch role {
        case .author:   return "person.fill"
        case .reviewer: return "person.2.fill"
        case .unknown:  return "ellipsis.circle"
        }
    }

    private func label(for c: Collaborator) -> String {
        switch c.role {
        case .unknown:
            return "Checking…"
        case .author:
            // Author covers both "owner of a share" and "own unshared copy".
            return c.ownerName == nil ? "Not shared" : "Owner"
        case .reviewer:
            if let owner = c.ownerName {
                return "Reviewer · shared by \(owner)"
            }
            return "Reviewer"
        }
    }

    private func helpText(for c: Collaborator) -> String {
        switch c.role {
        case .unknown:
            return "Resolving the iCloud sharing status of this project…"
        case .author where c.ownerName == nil:
            return "This project is your own copy and is not shared via iCloud."
        case .author:
            return "You own this shared project; collaborators can review it."
        case .reviewer:
            let by = c.ownerName.map { " by \($0)" } ?? ""
            let perm = c.canWrite ? "read-write" : "read-only"
            return "This project was shared with you\(by) (iCloud: \(perm)). You are a reviewer."
        }
    }
}
