import Foundation
import SwiftUI

/// Reads / writes user-level theme + typography + focus preferences via
/// UserDefaults. Observable so SwiftUI views update automatically.
///
/// NOTE: name is becoming a misnomer as it now also manages focus prefs.
/// Rename to `WritingPreferences` is deferred to milestone 1d when more
/// prefs accumulate.
@MainActor
@Observable
public final class ThemeManager {
    private static let themeKey = "maugham.theme"
    private static let typographyKey = "maugham.typography"
    private static let typewriterKey = "maugham.typewriterScroll"
    private static let sentenceFocusKey = "maugham.sentenceFocus"
    private static let paragraphFocusKey = "maugham.paragraphFocus"
    private static let goalIndicatorsKey = "maugham.goalIndicatorsVisible"

    private let defaults: UserDefaults

    public var theme: Theme {
        didSet { defaults.set(theme.rawValue, forKey: Self.themeKey) }
    }

    public var typography: TypographySettings {
        didSet {
            if let data = try? JSONEncoder().encode(typography) {
                defaults.set(data, forKey: Self.typographyKey)
            }
        }
    }

    public var typewriterScroll: Bool {
        didSet { defaults.set(typewriterScroll, forKey: Self.typewriterKey) }
    }

    public var sentenceFocus: Bool {
        didSet { defaults.set(sentenceFocus, forKey: Self.sentenceFocusKey) }
    }

    public var paragraphFocus: Bool {
        didSet { defaults.set(paragraphFocus, forKey: Self.paragraphFocusKey) }
    }

    public var goalIndicatorsVisible: Bool {
        didSet {
            defaults.set(goalIndicatorsVisible, forKey: Self.goalIndicatorsKey)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let raw = defaults.string(forKey: Self.themeKey),
           let t = Theme(rawValue: raw) {
            self.theme = t
        } else {
            self.theme = .followSystem
        }

        if let data = defaults.data(forKey: Self.typographyKey),
           let t = try? JSONDecoder().decode(TypographySettings.self, from: data) {
            self.typography = t
        } else {
            self.typography = .defaults
        }

        // Bool defaults: UserDefaults.bool returns false for missing keys, so
        // we use object(forKey:) to distinguish "absent" from "explicitly false".
        self.typewriterScroll =
            defaults.object(forKey: Self.typewriterKey) as? Bool ?? false
        self.sentenceFocus =
            defaults.object(forKey: Self.sentenceFocusKey) as? Bool ?? false
        self.paragraphFocus =
            defaults.object(forKey: Self.paragraphFocusKey) as? Bool ?? false
        self.goalIndicatorsVisible =
            defaults.object(forKey: Self.goalIndicatorsKey) as? Bool ?? true
    }
}
