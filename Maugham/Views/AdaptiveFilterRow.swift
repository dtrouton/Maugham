import SwiftUI

/// Anything renderable as a segment in `AdaptiveFilterRow`.
public protocol FilterRowItem: Hashable, Identifiable {
    /// Label shown in full-label mode (≤ ~12 chars works best).
    var label: String { get }
    /// SF Symbol name used in icon-only mode. Required for every item;
    /// short labels (≤ keepShortLabels chars) can keep their text instead.
    var symbolName: String { get }
}

/// Pure, testable width-fit decision. Extracted so the logic lives outside
/// SwiftUI's body / PreferenceKey plumbing and can be exercised with XCTest.
public enum AdaptiveFilterRowFit {
    /// Returns true when the full-label row would not fit in the available
    /// width and the row should fall back to icon-only mode.
    /// Returns false if available width is non-positive (defensive: a
    /// not-yet-measured layout pass should default to labels).
    public static func shouldShowIcons(
        naturalLabelWidth: CGFloat, availableWidth: CGFloat
    ) -> Bool {
        guard availableWidth > 0 else { return false }
        return naturalLabelWidth > availableWidth
    }
}

/// Reusable filter row that degrades gracefully under width pressure.
/// Above the natural-fit threshold: full labels. Below: SF Symbol icons
/// with tooltips. The selection pill renders identically in both states.
@MainActor
struct AdaptiveFilterRow<Item: FilterRowItem>: View {
    let items: [Item]
    @Binding var selection: Item
    /// Labels with `count <= keepShortLabels` stay as text even in icon
    /// mode (default: 3 — handles "All" naturally).
    var keepShortLabels: Int = 3

    @State private var naturalWidth: CGFloat = 0
    @State private var measuredWidth: CGFloat = 0

    private var useIcons: Bool {
        AdaptiveFilterRowFit.shouldShowIcons(
            naturalLabelWidth: naturalWidth,
            availableWidth: measuredWidth)
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                segment(for: item)
            }
        }
        .background(measureAvailable)
        .background(measureNatural)
    }

    @ViewBuilder
    private func segment(for item: Item) -> some View {
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
        }
        .buttonStyle(.plain)
    }

    /// Measures the width the container actually gets in layout.
    private var measureAvailable: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: AdaptiveAvailableWidthKey.self,
                            value: proxy.size.width)
        }
        .onPreferenceChange(AdaptiveAvailableWidthKey.self) { width in
            measuredWidth = width
        }
    }

    /// Measures the natural width of the full-labels row by rendering it
    /// once off-screen at .fixedSize() and reading its size.
    private var measureNatural: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                Text(item.label)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .fixedSize()
            }
        }
        .hidden()
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: AdaptiveNaturalWidthKey.self,
                                value: proxy.size.width)
            }
        )
        .onPreferenceChange(AdaptiveNaturalWidthKey.self) { width in
            naturalWidth = width
        }
    }
}

private struct AdaptiveAvailableWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct AdaptiveNaturalWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
