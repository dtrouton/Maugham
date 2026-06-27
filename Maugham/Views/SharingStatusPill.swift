import SwiftUI
import MaughamCore

/// A quiet, tasteful status capsule showing the resolved iCloud collaboration
/// role for the open project — the production counterpart to the spike's loud
/// debug readout. A small icon + short label ("Owner" / "Reviewer · shared by
/// X" / "Checking…"), subtly role-tinted, with the raw OS fields tucked into the
/// `.help()` hover tooltip for diagnostics rather than shouting on screen.
///
/// It is a PURE presentation view: the resolution (one read, cached) lives in
/// `ProjectWindow`, which threads the resolved `Collaborator` + raw
/// `ShareMetadata` snapshot in. Nothing is read back.
///
/// Hide-when-not-shared: the plain "your own unshared copy" case renders nothing
/// — a status chip there would be noise. Owner / Reviewer / still-resolving all
/// show. (`collaborator == nil` means "still resolving" → "Checking…".)
@MainActor
struct SharingStatusPill: View {

    /// Resolved identity for the open project. `nil` = still resolving.
    let collaborator: Collaborator?
    /// Raw OS snapshot, surfaced only in the hover tooltip for diagnostics.
    let snapshot: ShareMetadata?

    @ViewBuilder
    var body: some View {
        if shouldShow {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous).fill(tint.opacity(0.12)))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
            .help(helpText)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sharing status: \(label)")
        }
    }

    private var role: CollaborationRole { collaborator?.role ?? .unknown }

    /// Owner = an iCloud share the current user OWNS, distinguished by
    /// `Collaborator.isShared` (NOT `ownerName`, which is nil for the owner).
    private var ownsAShare: Bool { collaborator?.isShared == true }

    /// Hide the chip entirely for the plain unshared own-copy case (resolved
    /// author, not a share). Owner / Reviewer / still-resolving all show.
    private var shouldShow: Bool {
        guard let c = collaborator else { return true } // still resolving
        if c.role == .author && !c.isShared { return false }
        return true
    }

    private var symbol: String {
        switch role {
        case .author:   return "person.crop.circle.badge.checkmark"
        case .reviewer: return "person.2.fill"
        case .unknown:  return "ellipsis.circle"
        }
    }

    private var tint: Color {
        switch role {
        case .author:   return .blue
        case .reviewer: return .orange
        case .unknown:  return .secondary
        }
    }

    private var label: String {
        switch role {
        case .unknown:  return "Checking…"
        case .author:   return "Owner"
        case .reviewer:
            if let owner = collaborator?.ownerName { return "Reviewer · shared by \(owner)" }
            return "Reviewer"
        }
    }

    /// Diagnostics on hover: the resolved posture plus the raw OS fields, so a
    /// real share can still be verified without the on-screen debug box.
    private var helpText: String {
        guard let c = collaborator else {
            return "Resolving the iCloud sharing status of this project…"
        }
        let posture: String
        switch c.role {
        case .author:
            posture = ownsAShare
                ? "You own this shared project; collaborators can review it."
                : "Not shared via iCloud Collaborate (your own copy)."
        case .reviewer:
            let by = c.ownerName.map { " by \($0)" } ?? ""
            let perm = c.canWrite ? "read-write" : "read-only"
            posture = "Shared with you\(by) (iCloud: \(perm)). You are a reviewer."
        case .unknown:
            posture = "This project reports as shared but its per-user role hasn't populated yet."
        }
        return "\(posture)\n\n\(rawLine)"
    }

    private var rawLine: String {
        guard let m = snapshot else { return "shared=? (no read)" }
        let shared = m.isShared ? "yes" : "no"
        let owner = m.isOwner.map { $0 ? "owner" : "participant" } ?? "—"
        let write = m.canWrite.map { $0 ? "rw" : "ro" } ?? "—"
        let by = m.ownerName ?? "—"
        return "shared=\(shared) role=\(owner) write=\(write) by=\(by)"
    }
}
