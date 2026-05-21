import SwiftUI

/// Anything renderable as a segment in `AdaptiveFilterRow`.
public protocol FilterRowItem: Hashable, Identifiable {
    /// Label shown in full-label mode (≤ ~12 chars works best).
    var label: String { get }
    /// SF Symbol name used in icon-only mode. Required for every item;
    /// short labels (≤ keepShortLabels chars) can keep their text instead.
    var symbolName: String { get }
}

/// Reusable filter row that degrades gracefully under width pressure.
/// Above the natural-fit threshold: full labels. Below: SF Symbol icons
/// with tooltips. The selection pill renders identically in both states.
///
/// Uses `ViewThatFits(in: .horizontal)` so SwiftUI picks the first variant
/// that fits in the available width. The full-label variant is offered
/// first; the icon-only variant is the fallback. The "All" segment (and
/// any other label with `count <= keepShortLabels`) renders as text even
/// in icon mode.
@MainActor
struct AdaptiveFilterRow<Item: FilterRowItem>: View {
    let items: [Item]
    @Binding var selection: Item
    /// Labels with `count <= keepShortLabels` stay as text even in icon
    /// mode (default: 3 — handles "All" naturally).
    var keepShortLabels: Int = 3

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(useIcons: false)
            row(useIcons: true)
        }
    }

    @ViewBuilder
    private func row(useIcons: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                segment(for: item, useIcons: useIcons)
            }
        }
    }

    @ViewBuilder
    private func segment(for item: Item, useIcons: Bool) -> some View {
        let isSelected = item == selection
        let asText = !useIcons || item.label.count <= keepShortLabels
        Button {
            selection = item
        } label: {
            Group {
                if asText {
                    Text(item.label)
                } else {
                    Image(systemName: item.symbolName)
                }
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(isSelected
                ? Color.secondary.opacity(0.3) : Color.clear)
            .clipShape(Capsule())
            .help(item.label)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
    }
}
