import SwiftUI
import MaughamCore

/// Read-only diagnostic showing the resolved iCloud collaboration role for the
/// currently-open project. This is the spike's verification surface: it lets the
/// user confirm — on a real iCloud Collaborate share — that the OS resource keys
/// resolve to the expected posture before the role is wired into the editor
/// membrane (a later task).
///
/// SPIKE-LOUD: during verification this renders a prominent, role-tinted readout
/// with the RAW resolved fields (shared / role / write / owner) spelled out, so
/// there's no ambiguity about what the OS returned. It will be slimmed to a quiet
/// status pill once the resolver is validated and wired in.
///
/// It reads the share metadata exactly ONCE per project (on appear, and again if
/// the project URL changes) and caches the result. Resource reads can lag or
/// block on a freshly-mounted ubiquitous item, so it deliberately does NOT poll
/// or read per-render.
@MainActor
struct SharingStatusPill: View {

    let projectURL: URL

    /// Injected so tests / the phone can substitute a reader. Defaults to the
    /// real OS-backed Mac reader.
    var reader: ShareMetadataReading = ICloudShareMetadataReader()

    @State private var collaborator: Collaborator?
    @State private var metaSnapshot: ShareMetadata?
    @State private var didResolve = false

    var body: some View {
        readout
            .task(id: projectURL) {
                // Read once per project URL, off the main actor's critical path.
                let url = projectURL
                let r = reader
                let meta = await Task.detached(priority: .utility) {
                    r.read(for: url)
                }.value
                metaSnapshot = meta
                collaborator = ShareIdentityMapper.resolve(meta)
                didResolve = true
            }
    }

    @ViewBuilder
    private var readout: some View {
        VStack(alignment: .trailing, spacing: 2) {
            // Headline role line — always visible, role-tinted, unmissable.
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(headline)
                    .fontWeight(.semibold)
            }
            .font(.caption)
            // Raw fields, so verification is unambiguous pre/post share.
            Text(rawLine)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(0.6), lineWidth: 1))
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sharing status: \(headline)")
    }

    private var role: CollaborationRole { collaborator?.role ?? .unknown }

    /// True when this is a share the current user OWNS (vs. an unshared own copy).
    /// Distinguished by `isShared`, NOT `ownerName` — the OS leaves the owner-name
    /// key nil for the owner of a share as well as for an unshared item.
    private var ownsAShare: Bool { metaSnapshot?.isShared == true }

    private var symbol: String {
        guard didResolve else { return "ellipsis.circle" }
        switch role {
        case .author:   return ownsAShare ? "person.crop.circle.badge.checkmark" : "person.fill"
        case .reviewer: return "person.2.fill"
        case .unknown:  return "questionmark.circle"
        }
    }

    private var tint: Color {
        guard didResolve else { return .gray }
        switch role {
        case .author:   return ownsAShare ? .blue : .gray
        case .reviewer: return .orange
        case .unknown:  return .yellow
        }
    }

    private var headline: String {
        guard didResolve else { return "Checking…" }
        switch role {
        case .unknown:  return "Checking…"
        case .author:   return ownsAShare ? "Owner" : "Not shared"
        case .reviewer:
            if let owner = collaborator?.ownerName { return "Reviewer · shared by \(owner)" }
            return "Reviewer"
        }
    }

    /// The raw OS fields, so the user can verify exactly what populated.
    private var rawLine: String {
        guard let m = metaSnapshot else { return "shared=? (no read)" }
        let shared = m.isShared ? "yes" : "no"
        let owner = m.isOwner.map { $0 ? "owner" : "participant" } ?? "—"
        let write = m.canWrite.map { $0 ? "rw" : "ro" } ?? "—"
        let by = m.ownerName ?? "—"
        return "shared=\(shared) role=\(owner) write=\(write) by=\(by)"
    }

    private var helpText: String {
        guard didResolve else { return "Resolving the iCloud sharing status of this project…" }
        switch role {
        case .unknown:
            return "This project reports as shared but its per-user role hasn't populated yet."
        case .author where !ownsAShare:
            return "This project is not shared via iCloud Collaborate (your own copy). Share it via Finder → Share → Collaborate to review with others."
        case .author:
            return "You own this shared project; collaborators can review it."
        case .reviewer:
            let by = collaborator?.ownerName.map { " by \($0)" } ?? ""
            let perm = (collaborator?.canWrite ?? true) ? "read-write" : "read-only"
            return "This project was shared with you\(by) (iCloud: \(perm)). You are a reviewer."
        }
    }
}
