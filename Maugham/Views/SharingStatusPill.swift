import SwiftUI
import MaughamCore

/// A quiet status capsule saying the open project is an iCloud share — an
/// INDICATOR, never a role (signed op log P3c, Task 4). *Shared* over a share
/// this user owns (or one whose owner the OS has not named), *Shared by
/// <owner>* over somebody else's, and nothing at all over an unshared project
/// or while the OS is still resolving: a role-free pill has nothing to check.
///
/// It names no role because the share does not decide one. What this device
/// may write is its permit's, asked through `Posture` and said by the
/// editor's standing line; the WF1 share-role system that used to print
/// *Owner* / *Reviewer* here is retired. The one lock the share still carries
/// is iCloud's own read-only grant, which `ViewOnlyShareNotice` says.
///
/// A PURE presentation view: the one read lives in `ProjectWindow`, which
/// threads the raw `ShareMetadata` snapshot in. The raw OS fields ride the
/// `.help()` tooltip for diagnostics.
@MainActor
struct SharingStatusPill: View {

    /// Raw OS snapshot. `nil` = still resolving.
    let snapshot: ShareMetadata?

    /// **The pill's words, as a pure function of the snapshot.** `nil` draws
    /// nothing: an unshared project, or one the OS has not resolved yet.
    nonisolated static func label(for snapshot: ShareMetadata?) -> String? {
        guard let snapshot, snapshot.isShared else { return nil }
        if snapshot.isOwner != true, let owner = snapshot.ownerName {
            return "Shared by \(owner)"
        }
        return "Shared"
    }

    @ViewBuilder
    var body: some View {
        if let label = Self.label(for: snapshot) {
            HStack(spacing: 5) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous).fill(Color.secondary.opacity(0.12)))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5))
            .help(helpText)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sharing status: \(label)")
        }
    }

    /// Diagnostics on hover: what iCloud says, plus the raw OS fields, so a
    /// real share can still be verified without an on-screen debug box.
    private var helpText: String {
        let access: String
        switch snapshot?.canWrite {
        case .some(false): access = "iCloud grants read-only access."
        case .some(true):  access = "iCloud grants read-write access."
        case .none:        access = "iCloud has not said what access it grants yet."
        }
        return "This project is shared through iCloud. \(access)\n\n\(rawLine)"
    }

    private var rawLine: String {
        guard let m = snapshot else { return "shared=? (no read)" }
        let shared = m.isShared ? "yes" : "no"
        let owned = m.isOwner.map { $0 ? "you" : "other" } ?? "—"
        let write = m.canWrite.map { $0 ? "rw" : "ro" } ?? "—"
        let by = m.ownerName ?? "—"
        return "shared=\(shared) owned-by=\(owned) write=\(write) by=\(by)"
    }
}
