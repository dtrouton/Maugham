import SwiftUI
import MaughamCore

struct OutlineTable: View {
    let items: [StructureItem]
    @Bindable var store: ProjectStore
    @Binding var selectedSubject: BinderSubject?

    /// **Who writes which piece** (P3b Task 9). One registry read for the
    /// whole table, held here — a cell asks it a dictionary question, and the
    /// read never happens in `body` or per row (tripwire 4, which this table
    /// is one of the recurrence-trippers for).
    @State private var writers: PieceWriters = .none

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
    /// letting `ProjectAltitudePane` hand a `String?` down — the pane chain
    /// stays uniformly typed and the exception is visible where it is forced,
    /// which is `DeviceSlug`'s rule about interpolating `.raw` at the
    /// filename point.
    ///
    /// `nil` on the way out for a project subject is the honest answer: this
    /// table lists documents, and the project is not one of its rows. The
    /// setter is deliberately trivial — tripwire 3.
    ///
    /// **Already research-safe, unchanged by stage-2a Task 1.** The getter
    /// reads `.itemID`, which is `nil` for `.research` exactly as it is for
    /// `.project`, so a research subject shows no row selected here — no
    /// row IS one. The setter only ever writes `.item`, so this table cannot
    /// itself produce a research subject.
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
                // Dot AND text read the same projection (M3 P1 Task 4). The
                // text used to print the raw legacy `status` string beside a
                // derived dot, which was already two answers to one question —
                // and once the ladder is the only writer, the string would
                // have sat at "draft" (or "—") under a green dot for ever.
                let status = ReviewStatus.derived(
                    passStates: item.passStates,
                    passes: store.manifest.effectiveReviewPasses,
                    legacyStatus: item.status)
                HStack(spacing: 4) {
                    Circle()
                        .fill(StatusSwatch.color(for: status))
                        .frame(width: 6, height: 6)
                    Text(StatusSwatch.label(for: status))
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
            // **The Writer column exists only in a book that has one.** Asked
            // of the BOOK rather than of the row: a book where one chapter in
            // forty has a scoped author gets the column with thirty-nine
            // blanks in it, because the blanks are the answer for those
            // chapters. A book with one writer in it — or one whose
            // co-authors may each write the whole of it — gets no column at
            // all, which is `PieceWriters`' own judgement and its reasons.
            if !writers.isEmpty {
                TableColumn(PieceWriters.columnTitle) { item in
                    Text(writers.sentence(for: item.id) ?? "—")
                        .foregroundStyle(
                            writers.sentence(for: item.id) == nil
                                ? AnyShapeStyle(.tertiary)
                                : AnyShapeStyle(.secondary))
                }
            }
        }
        .task(id: store.url) { await loadWriters() }
    }

    /// The one registry read this table makes — one per project, off the main
    /// actor, through the door both inspectors use.
    func loadWriters() async {
        writers = await PieceWriters.read(
            projectURL: store.url,
            pieces: PermitControl.pieces(in: store.manifest.structure))
    }
}
