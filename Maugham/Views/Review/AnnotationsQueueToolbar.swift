import SwiftUI
import MaughamCore

/// **The queue's toolbar** — extracted from `AnnotationsPane` so the one thing
/// it has to do can be measured: fit inside the column it is drawn in.
///
/// It carries seven controls (the kind filter, then pass / scope / selection
/// mode / triage / author / resolved) into a right column whose default is
/// 280pt and whose floor is 240. Every one of them was `.fixedSize()`, which
/// makes the row's MINIMUM width their sum — so the row could not compress, the
/// pane's layout width inflated to hold it, and SwiftUI centred the overflow.
/// The visible result was Denver's smoke find: annotation bodies clipped at the
/// LEFT edge, the toolbar cut at both ends, and diff cards wrapping at the
/// inflated width rather than the column's.
///
/// Measured before anything was changed (2026-08-15, macOS 26.5): the row asked
/// for **560pt** in both a 240pt and a 280pt column, and **787pt** once a pass
/// carried a 46-character name.
///
/// The fix is the degrade `AdaptiveFilterRow` already does for the kind filter,
/// applied to the whole row: `ViewThatFits` over three variants, widest first.
/// The LAST one is the one that matters — `ViewThatFits` renders its final child
/// at whatever width it is given, fitting or not, so a fallback that can still
/// overflow is no fallback at all. That is why the fallback here STACKS rather
/// than compressing further: one line cannot hold the kind filter and six
/// controls at 240pt however few words they carry, and a variant that only
/// mostly fits is the same defect with a smaller number.
/// `AnnotationsQueueToolbarWidthTests` measures it at both widths, and proves
/// the stacked variant is the one being measured rather than assuming it.
@MainActor
struct AnnotationsQueueToolbar: View {
    @Binding var kindFilter: AnnotationsPane.KindOption
    @Binding var passSelection: AnnotationPassFilter.Selection
    @Binding var triageFilter: AnnotationTriageFilter
    @Binding var authorFilter: String
    @Binding var showResolved: Bool

    /// The project's named passes — the pass menu's contents.
    let reviewPasses: [ReviewPass]
    /// Which pass the queue is currently looking through, already resolved
    /// against the piece's remembered active pass (`AnnotationPassFilter`).
    let resolvedPassId: String?
    let scopeIsProject: Bool
    /// Multiselect is document-scope only — see
    /// `AnnotationScopePolicy.showsBulkAffordances` for why a cross-document
    /// bulk bar would be a lying count.
    let showsBulkAffordances: Bool
    let selectionModeOn: Bool
    /// The distinct contributors in scope. The author menu renders only when
    /// there is more than one.
    let authorLabels: [String]
    let onSetScope: (AnnotationScope) -> Void
    let onToggleSelectionMode: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            oneRow(useIcons: false)
            oneRow(useIcons: true)
            twoRows
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    // MARK: - The three variants

    /// The roomy shapes: everything on one line, the cluster worded or iconic.
    @ViewBuilder
    private func oneRow(useIcons: Bool) -> some View {
        HStack(spacing: 0) {
            kindRow
            Spacer(minLength: 4)
            cluster(useIcons: useIcons)
        }
    }

    /// **The floor, and the only variant whose fit is guaranteed rather than
    /// measured by `ViewThatFits`.** The kind filter keeps a line of its own —
    /// it is the control the writer reaches for most, and it degrades to icons
    /// on its own — and the filter cluster takes the line below it in icon form.
    /// Neither line can want more than a narrow column has, which is what makes
    /// this a fallback and not a third way to overflow.
    @ViewBuilder
    private var twoRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                kindRow
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                cluster(useIcons: true)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var kindRow: some View {
        AdaptiveFilterRow(items: AnnotationsPane.KindOption.allCases,
                          selection: $kindFilter)
            .layoutPriority(1)
    }

    @ViewBuilder
    private func cluster(useIcons: Bool) -> some View {
        passMenu(useIcons: useIcons)
        scopeMenu(useIcons: useIcons)
        if showsBulkAffordances { selectionModeButton }
        triageFilterMenu(useIcons: useIcons)
        authorMenu(useIcons: useIcons)
        resolvedToggle
    }

    // MARK: - The controls

    /// **Which pass the queue is looking through** (M3 P2 Task 8). A menu, for
    /// `triageFilterMenu`'s reason — the toolbar is a narrow column and a
    /// project may name any number of passes, so a segmented row is not an
    /// option here at all.
    ///
    /// The label carries the pass's own name when one is selected, so what the
    /// queue is showing is readable without opening the menu; "All Passes"
    /// leads, because widening back out is the escape hatch from a filter that
    /// was chosen FOR the writer by the board's chip click.
    ///
    /// **The name is the one label here with no upper bound** — a writer may
    /// call a pass anything — so even in the worded variant it truncates rather
    /// than pushing the row wider than the column. In the compact variants the
    /// name moves into the tooltip, where the menu's own checkmark already
    /// says the same thing.
    @ViewBuilder
    private func passMenu(useIcons: Bool) -> some View {
        let current = resolvedPassId
        let name = reviewPasses.first { $0.id == current }?.name
        Menu {
            Button {
                passSelection = .allPasses
            } label: {
                if current == nil {
                    Label("All Passes", systemImage: "checkmark")
                } else {
                    Text("All Passes")
                }
            }
            Divider()
            ForEach(reviewPasses) { pass in
                Button {
                    passSelection = .pass(pass.id)
                } label: {
                    if current == pass.id {
                        Label(pass.name, systemImage: "checkmark")
                    } else {
                        Text(pass.name)
                    }
                }
            }
        } label: {
            menuLabel(name ?? "Pass",
                      symbol: current == nil
                        ? "line.3.horizontal.decrease"
                        : "line.3.horizontal.decrease.circle.fill",
                      useIcons: useIcons,
                      maxTextWidth: Self.passNameCeiling)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help((name.map { "Showing the \($0) pass. " } ?? "")
              + "Show only the notes written during one review pass. Notes "
              + "written outside any pass appear under every one.")
    }

    /// **This Piece / All Pieces** (M3 P2 Task 7). A menu rather than a
    /// segmented picker for `triageFilterMenu`'s reason: the toolbar already
    /// carries the kind row, and two more segments would push it into icon-only
    /// mode in a narrow column.
    @ViewBuilder
    private func scopeMenu(useIcons: Bool) -> some View {
        let title = scopeIsProject ? "All Pieces" : "This Piece"
        Menu {
            scopeItem("This Piece", isCurrent: !scopeIsProject, target: .document)
            scopeItem("All Pieces", isCurrent: scopeIsProject,
                      target: .project(focusPiece: nil))
        } label: {
            menuLabel(title,
                      symbol: scopeIsProject ? "books.vertical" : "doc.text",
                      useIcons: useIcons)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("\(title) — show this piece's notes, or every piece's, grouped "
              + "by piece")
    }

    @ViewBuilder
    private func scopeItem(
        _ title: String, isCurrent: Bool, target: AnnotationScope
    ) -> some View {
        Button {
            onSetScope(target)
        } label: {
            if isCurrent {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    /// Selection mode's door. A mode rather than always-on checkboxes: the
    /// column is narrow and a writer answering notes one at a time should not
    /// pay for a control they are not using. Icon-only in every variant — it has
    /// no word to lose.
    @ViewBuilder
    private var selectionModeButton: some View {
        Button(action: onToggleSelectionMode) {
            Image(systemName: "checklist")
                .font(.caption)
                .foregroundStyle(selectionModeOn ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help(selectionModeOn
            ? "Leave selection mode"
            : "Select several notes and answer them together")
    }

    /// The queue's own filter (M3 P2): show only what you said you'd do, only
    /// what you said you'd decline, only what you haven't looked at yet. A menu
    /// rather than another segmented row — the toolbar already carries the kind
    /// filter, and five more segments would push both into icon-only mode in a
    /// narrow column.
    @ViewBuilder
    private func triageFilterMenu(useIcons: Bool) -> some View {
        let title = triageFilter == .all ? "Triage" : triageFilter.label
        Menu {
            ForEach(AnnotationTriageFilter.allCases) { option in
                Button {
                    triageFilter = option
                } label: {
                    if option == triageFilter {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            menuLabel(title,
                      symbol: triageFilter == .all ? "flag" : "flag.fill",
                      useIcons: useIcons)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("\(title) — filter by what you plan to do about each note")
    }

    @ViewBuilder
    private func authorMenu(useIcons: Bool) -> some View {
        // Only worth showing when more than one contributor is present.
        if authorLabels.count > 1 {
            let title = authorFilter == AnnotationAuthorFilter.all
                ? "Author" : authorFilter
            Menu {
                Button(AnnotationAuthorFilter.all) {
                    authorFilter = AnnotationAuthorFilter.all
                }
                Divider()
                ForEach(authorLabels, id: \.self) { name in
                    Button(name) { authorFilter = name }
                }
            } label: {
                menuLabel(title, symbol: "person.crop.circle",
                          useIcons: useIcons,
                          maxTextWidth: Self.authorNameCeiling)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("\(title) — filter annotations by who wrote them")
        }
    }

    @ViewBuilder
    private var resolvedToggle: some View {
        Button {
            showResolved.toggle()
        } label: {
            Image(systemName: showResolved ? "tray.full" : "tray")
                .font(.caption)
                .foregroundStyle(showResolved ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help(showResolved
            ? "Showing all statuses · click to show only open"
            : "Showing open only · click to include resolved")
    }

    // MARK: - Labels

    /// A menu's label in whichever form the variant calls for. The word is never
    /// lost: in icon form it is in the `.help` and in the menu's own checked
    /// item, which is the same trade `AdaptiveFilterRow` makes.
    ///
    /// `maxTextWidth` caps the two labels a writer can make arbitrarily long —
    /// a pass name and a collaborator's display name. Everything else here is a
    /// fixed word this file owns.
    @ViewBuilder
    private func menuLabel(
        _ title: String, symbol: String, useIcons: Bool,
        maxTextWidth: CGFloat? = nil
    ) -> some View {
        if useIcons {
            Image(systemName: symbol).font(.caption)
        } else if let maxTextWidth {
            Label {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: maxTextWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: symbol)
            }
            .font(.caption)
        } else {
            Label(title, systemImage: symbol)
                .font(.caption)
                .lineLimit(1)
        }
    }

    /// How much of a pass's name the worded variant will show before
    /// truncating. Enough for every preset (`Structural` is the longest) plus
    /// room to see that a longer custom name has been cut.
    static let passNameCeiling: CGFloat = 84
    /// The same, for a collaborator's display name.
    static let authorNameCeiling: CGFloat = 72
}
