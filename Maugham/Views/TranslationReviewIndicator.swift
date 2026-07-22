import SwiftUI

/// The pill shown at the top of the editor content column while translation
/// review is engaged (Task 13). It sits alongside `ReviewModeIndicator` (they
/// stack via separate top `safeAreaInset`s) and is the visible feedback that
/// the surface has swapped to the read-only DERIVED translation for a chosen
/// language. It names the language, reports how many paragraphs are stale
/// (their source changed after the translation was captured), and offers a
/// one-click exit back to the source manuscript.
///
/// Pure, one-way SwiftUI: reads its inputs, writes nothing back. The exit
/// button posts `.maughamExitTranslationReview` (`.keyWindow`, ADR 0021); the
/// owning `TranslationReviewModifier` clears the language from there. A cool
/// slate/blue tint distinguishes it from the warm terracotta review pill.
struct TranslationReviewIndicator: View {
    /// The BCP-47 language tag being reviewed (e.g. "es", "zh-Hant").
    let languageTag: String
    /// Paragraphs whose translation is stale relative to the current source.
    let staleCount: Int
    /// Posts the exit event.
    let onExit: () -> Void

    /// Human label for a language tag: the current locale's localized name plus
    /// the raw tag in parentheses ("Spanish (es)"), or the raw tag alone when no
    /// localized name is available (Task 13).
    static func displayLabel(forLanguageTag tag: String) -> String {
        if let name = Locale.current.localizedString(forLanguageCode: tag), !name.isEmpty {
            return "\(name) (\(tag))"
        }
        return tag
    }

    /// Number of stale paragraphs among the translation-freshness entries.
    static func staleCount(in entries: [TranslationBadgeLayout.Entry]) -> Int {
        entries.lazy.filter { $0.status == .stale }.count
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 11, weight: .semibold))
            Text("Reviewing · \(Self.displayLabel(forLanguageTag: languageTag))")
                .font(.system(size: 11, weight: .medium))
                .textCase(.uppercase)
                .tracking(0.5)
            if staleCount > 0 {
                Text("· \(staleCount) stale")
                    .font(.system(size: 11, weight: .medium))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .opacity(0.85)
            }
            Button(action: onExit) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Show the source manuscript")
            .accessibilityLabel("Exit translation review")
        }
        .foregroundStyle(Self.foreground)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Self.background)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Self.border, lineWidth: 0.5)
        )
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Reviewing translation \(Self.displayLabel(forLanguageTag: languageTag))"
            + (staleCount > 0 ? ", \(staleCount) stale" : ""))
    }

    // Cool slate/blue, resolved adaptively so it re-resolves per effective
    // appearance (mirrors ReviewModeIndicator's adaptive-NSColor idiom).
    private static let background = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.18, green: 0.27, blue: 0.42, alpha: 1.0)   // muted slate, dark
            : NSColor(srgbRed: 0.85, green: 0.90, blue: 0.98, alpha: 1.0)   // cool wash, light
    })

    private static let foreground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.80, green: 0.88, blue: 0.99, alpha: 1.0)
            : NSColor(srgbRed: 0.14, green: 0.30, blue: 0.55, alpha: 1.0)
    })

    private static let border = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.35, green: 0.50, blue: 0.72, alpha: 0.6)
            : NSColor(srgbRed: 0.40, green: 0.55, blue: 0.80, alpha: 0.6)
    })
}

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
