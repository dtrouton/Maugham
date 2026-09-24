import SwiftUI
import MaughamCore

/// **Pieces removed elsewhere, with Restore** (Denver's ruling, 2026-09-24).
///
/// Mounted at the tree's foot beside Trash, and — like Trash — only while
/// there is something in it, so a book with nothing to offer back
/// shows nothing at all. Each row names the piece, says when the removal
/// reached this Mac, and carries a visible **Restore** button (a real
/// `Button`, reachable by VoiceOver and the keyboard; tripwire 9 rules out a
/// tap gesture) as well as the same verb in its context menu.
///
/// The list is `ProjectStore.removedElsewhere`, derived by
/// `RemovedElsewhereRefresh`; this view never computes it.
struct RemovedElsewhereDisclosure: View {
    @Bindable var store: ProjectStore
    /// Where a restore's sentence goes — the window's restore sink, shared with
    /// Trash, because this view unmounts with its last row and an alert hosted
    /// here would never present (`TrashView.onRestoreOutcome`'s reasoning).
    var onRestoreOutcome: (String) -> Void = { _ in }
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.sectionCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(store.removedElsewhere) { piece in
                    row(for: piece)
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Removed Elsewhere", systemImage: "arrow.uturn.backward.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func row(for piece: RemovedElsewherePiece) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(piece.title)
                    .font(.body)
                    .lineLimit(1)
                Text(Self.caption(for: piece.removedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button("Restore") { restore(piece) }
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityLabel("Restore \(piece.title)")
                .help("Put “\(piece.title)” back in the binder")
        }
        .contextMenu {
            Button("Restore") { restore(piece) }
        }
    }

    private func restore(_ piece: RemovedElsewherePiece) {
        // Captured before the `await`: this row can be gone by the time the
        // store answers.
        let report = onRestoreOutcome
        let store = store
        Task { await Self.restore(piece: piece, store: store, report: report) }
    }

    /// **What Restore does**, as a function a test can call without a window
    /// (tripwire 33). Both a refusal and a restore with something to say go to
    /// the same reporter.
    static func restore(
        piece: RemovedElsewherePiece, store: ProjectStore,
        report: @escaping (String) -> Void
    ) async {
        do {
            let outcome = try await store.restoreRemovedElsewhere(id: piece.id)
            if let message = outcome.message { report(message) }
        } catch {
            report(error.localizedDescription)
        }
    }

    /// **What the section says, true of every way a piece gets here** (review
    /// M6). A piece is listed when an archived outline held it and the live one
    /// does not: most often another device's stale outline replaced one here
    /// that held it, but equally a chapter ANOTHER Mac added that lost a
    /// last-writer-wins race before it ever reached this binder. *Removed on
    /// another device* is wrong for the second, and the archive does not record
    /// which it was, so the wording is chosen to be true of both rather than
    /// derived per row: it names what happened to the binder, not who did it.
    static let sectionCaption =
        "Left the binder when two devices\u{2019} outlines crossed. The words are still in this book."

    /// "Left the binder today" / "… yesterday" / "Left the binder 12 Sep 2026".
    static func caption(for date: Date, now: Date = Date(),
                        calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Left the binder today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Left the binder yesterday"
        }
        return "Left the binder \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}

/// **Keeps `ProjectStore.removedElsewhere` derived** for as long as the tree is
/// on screen. Re-derived whenever what it depends on changes — the live
/// structure's ids (an adoption, a restore, a delete) and Trash's entries —
/// so no verb has to remember to ask. The op-log and archive reads run off the
/// main actor (`refreshRemovedElsewhere`).
struct RemovedElsewhereRefresh: ViewModifier {
    let store: ProjectStore

    struct Key: Equatable {
        var structureIds: [String]
        var trashIds: [String]
    }

    static func key(for store: ProjectStore) -> Key {
        Key(structureIds: TreeWalk.collectIds(in: store.manifest.structure),
            trashIds: store.trashEntries.map(\.id))
    }

    func body(content: Content) -> some View {
        content.task(id: Self.key(for: store)) {
            await store.refreshRemovedElsewhere()
        }
    }
}
