import SwiftUI
import MaughamCore

struct OutlineTable: View {
    let items: [StructureItem]
    @Bindable var store: ProjectStore
    @Binding var selectedSubject: BinderSubject?

    /// **`Table` cannot carry a `BinderSubject`, and this is where that is
    /// paid for.** `List(selection:)` takes any `Hashable` and matches it
    /// against each row's `.tag`, so the binder and the pieces pane hold a
    /// `Binding<BinderSubject?>` directly. `Table` has no `.tag` at all: its
    /// selection is hard-bound to the row type's own `ID` —
    ///
    ///     init<Data>(_ data: Data, selection: Binding<Value.ID?>, …)
    ///     init<Data>(_ data: Data, selection: Binding<Set<Value.ID>>, …)
    ///
    /// — and `StructureItem.ID` is `String`, so a typed binding is *"no exact
    /// matches in call to initializer"* (measured, macOS 26.5 SDK). Nothing in
    /// the type's design can fix that; the projection is the framework's price.
    ///
    /// Kept HERE, at the one view the framework constrains, rather than by
    /// letting `OutlinePane` hand a `String?` down — the pane chain stays
    /// uniformly typed and the exception is visible where it is forced, which
    /// is `DeviceSlug`'s rule about interpolating `.raw` at the filename point.
    ///
    /// `nil` on the way out for a project subject is the honest answer: this
    /// table lists documents, and the project is not one of its rows. The
    /// setter is deliberately trivial — tripwire 3.
    private var rowSelection: Binding<String?> {
        Binding(
            get: { selectedSubject?.itemID },
            set: { selectedSubject = $0.map(BinderSubject.item) })
    }

    var body: some View {
        Table(items, selection: rowSelection) {
            TableColumn("Title") { item in
                Text(item.title)
            }
            TableColumn("Status") { item in
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor(item.status))
                        .frame(width: 6, height: 6)
                    Text(item.status ?? "—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            TableColumn("Synopsis") { item in
                Text(item.synopsis ?? "")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
            TableColumn("Words") { item in
                if let count = store.cachedWordCount(for: item.id) {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func statusColor(_ status: String?) -> Color {
        switch status {
        case "revising": return .orange
        case "final":    return .green
        default:         return .secondary
        }
    }
}
