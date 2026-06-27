import SwiftUI
import MaughamCore

/// A quiet role/provenance indicator for the phone's per-project read view.
///
/// The phone is read-only review consumption — it never authors — so there is no
/// editor membrane to wire. This is purely informational: it tells a participant
/// whether they're looking at a project shared with them ("Shared by X") or their
/// own copy, using the SAME `FileURLShareMetadataReader` + `ShareIdentityMapper`
/// the Mac uses (no divergent reader — cross-surface contract).
///
/// Resolution runs once in `.task` off the resolved `Collaborator`; the OS
/// resource read is wrapped in a detached task so it never blocks the UI. The
/// reader is injected (defaulting to the shared impl) so the view stays testable.
struct SharingRoleBanner: View {
    let projectURL: URL
    var reader: ShareMetadataReading = FileURLShareMetadataReader()

    @State private var collaborator: Collaborator?

    var body: some View {
        Group {
            if shouldShow, let label = label {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.caption)
                    Text(label)
                        .font(.caption)
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(0.1))
            }
        }
        .task(id: projectURL) { await resolve() }
    }

    private func resolve() async {
        let target = projectURL
        let r = reader
        let meta = await Task.detached(priority: .utility) {
            r.read(for: target)
        }.value
        collaborator = ShareIdentityMapper.resolve(meta)
    }

    /// Hide the chip for the plain unshared own-copy case — a chip there is noise.
    /// Reviewer (shared with you) and owner-of-a-share both show; still-resolving
    /// shows nothing (avoid a flash before the first read lands).
    private var shouldShow: Bool {
        guard let c = collaborator else { return false }
        if c.role == .author && !c.isShared { return false }
        return true
    }

    private var label: String? {
        guard let c = collaborator else { return nil }
        switch c.role {
        case .author:
            return c.isShared ? "You own this shared project" : nil
        case .reviewer:
            if let owner = c.ownerName { return "Shared by \(owner)" }
            return "Shared with you"
        case .unknown:
            return nil
        }
    }

    private var symbol: String {
        guard let c = collaborator else { return "ellipsis.circle" }
        switch c.role {
        case .author:   return "person.crop.circle.badge.checkmark"
        case .reviewer: return "person.2.fill"
        case .unknown:  return "ellipsis.circle"
        }
    }

    private var tint: Color {
        guard let c = collaborator else { return .secondary }
        switch c.role {
        case .author:   return .blue
        case .reviewer: return .orange
        case .unknown:  return .secondary
        }
    }
}
