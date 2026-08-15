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
/// applied to the whole row: `ViewThatFits` over one line and, under pressure,
/// two. The LAST variant is the one that matters — `ViewThatFits` renders its
/// final child at whatever width it is given, fitting or not, so a fallback that
/// can still overflow is no fallback at all. That is why the fallback here
/// STACKS rather than compressing further: one line cannot hold the kind filter
/// and six controls at 240pt, and a variant that only mostly fits is the same
/// defect with a smaller number.
///
/// Every control's label is an icon, so **nothing a writer can type is on the
/// toolbar's critical path** — a pass they named and a collaborator's display
/// name reach it only through tooltips and menu items, neither of which has a
/// width. The first version of this fix instead truncated those two labels to a
/// ceiling; review found the test covering it was vacuous, and measuring
/// properly showed the ceilings neither worked nor were reachable. See the
/// variants below.
///
/// `AnnotationsQueueToolbarWidthTests` measures both widths, proves the stacked
/// variant is the one being measured rather than assuming it, and holds every
/// declared variant to being reachable inside the column's own range.
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
            oneRow
            twoRows
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    // MARK: - The two variants
    //
    // **There were three, and the third was a worded cluster nothing could
    // ever have drawn.** Measured 2026-08-15 while closing a review finding:
    // the worded variant's ideal width is 668pt with a three-letter author name
    // and 939pt with a long one, while `UIState.detailColumnWidthRange` caps the
    // right column at 480. Nothing the writer can drag to comes within 188pt of
    // affording it, so it was dead in the shipped app — and being dead, the two
    // label ceilings inside it (`passNameCeiling`, `authorNameCeiling`) were
    // both unreachable AND, separately, broken: `.frame(maxWidth:)` bounds what
    // a `Text` is PROPOSED, not the ideal width it reports, and the `.fixedSize()`
    // every one of these menus carries then forces it to that unbounded ideal.
    // Deleting the label 271pt of a long name added is what actually stops a
    // collaborator's display name setting the toolbar's width.
    //
    // So the words live in the tooltips and in each menu's own checked item —
    // the trade `AdaptiveFilterRow` already makes for the kind filter — and
    // `test_everyVariantIsReachableInsideTheColumnsOwnRange` is what stops a
    // fourth unreachable variant arriving the same way this one did.

    /// One line, for the widest column the writer can reach.
    @ViewBuilder
    private var oneRow: some View {
        HStack(spacing: 0) {
            kindRow
            Spacer(minLength: 4)
            cluster
        }
    }

    /// **The floor, and the only variant whose fit is guaranteed rather than
    /// measured by `ViewThatFits`.** The kind filter keeps a line of its own —
    /// it is the control the writer reaches for most, and it degrades to icons
    /// on its own — and the filter cluster takes the line below it.
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
                cluster
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
    private var cluster: some View {
        passMenu
        scopeMenu
        if showsBulkAffordances { selectionModeButton }
        triageFilterMenu
        authorMenu
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
    /// call a pass anything — so it does not appear in the label at all. It is
    /// in the tooltip and in the menu's own checked item, which is where the
    /// other five controls keep their words too.
    @ViewBuilder
    private var passMenu: some View {
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
            menuLabel(symbol: current == nil
                        ? "line.3.horizontal.decrease"
                        : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help((name.map { "Showing the \($0) pass. " } ?? "")
              + "Show only the notes written during one review pass. Notes "
              + "written outside any pass appear under every one.")
    }

    /// **This Piece / All Pieces** (M3 P2 Task 7). A menu rather than a
    /// segmented picker for `triageFilterMenu`'s reason: the toolbar already
    /// carries the kind row, and two more segments would not fit beside it.
    @ViewBuilder
    private var scopeMenu: some View {
        let title = scopeIsProject ? "All Pieces" : "This Piece"
        Menu {
            scopeItem("This Piece", isCurrent: !scopeIsProject, target: .document)
            scopeItem("All Pieces", isCurrent: scopeIsProject,
                      target: .project(focusPiece: nil))
        } label: {
            menuLabel(symbol: scopeIsProject ? "books.vertical" : "doc.text")
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
    /// pay for a control they are not using.
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
    /// filter, and five more segments could not be drawn in a narrow column at
    /// all.
    @ViewBuilder
    private var triageFilterMenu: some View {
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
            menuLabel(symbol: triageFilter == .all ? "flag" : "flag.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("\(title) — filter by what you plan to do about each note")
    }

    @ViewBuilder
    private var authorMenu: some View {
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
                menuLabel(symbol: "person.crop.circle")
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

    /// A menu's label. An icon, in every variant — which is what makes the
    /// toolbar's width independent of anything a writer can type.
    ///
    /// **The word is never lost, and it is never drawn here either.** Each
    /// control's `.help` opens with it and each menu checks its current item, so
    /// what the queue is filtered to is one hover or one click away. That is the
    /// same trade `AdaptiveFilterRow` makes for the kind filter, and at the
    /// widths this column actually has it is the only one available: see the
    /// variants above for why a worded cluster cannot be drawn at all.
    @ViewBuilder
    private func menuLabel(symbol: String) -> some View {
        Image(systemName: symbol).font(.caption)
    }
}
