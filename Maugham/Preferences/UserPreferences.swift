import Foundation
import MaughamCore
import SwiftUI

/// Reads / writes user-level preferences (theme, typography, focus prefs,
/// goal indicators) via UserDefaults. Observable so SwiftUI views update
/// automatically. Renamed from ThemeManager in 1d as the surface grew
/// beyond just theme management.
@MainActor
@Observable
public final class UserPreferences {
    private static let themeKey = "maugham.theme"
    private static let typographyKey = "maugham.typography"
    private static let typewriterKey = "maugham.typewriterScroll"
    private static let sentenceFocusKey = "maugham.sentenceFocus"
    private static let paragraphFocusKey = "maugham.paragraphFocus"
    private static let goalIndicatorsKey = "maugham.goalIndicatorsVisible"
    private static let mcpEnabledKey = "maugham.mcpEnabled"

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

    public var mcpEnabled: Bool {
        didSet { defaults.set(mcpEnabled, forKey: Self.mcpEnabledKey) }
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
        self.mcpEnabled =
            defaults.object(forKey: Self.mcpEnabledKey) as? Bool ?? true
    }
}
