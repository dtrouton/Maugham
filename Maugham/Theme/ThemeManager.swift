import Foundation
import SwiftUI

/// Reads / writes user-level theme + typography preferences via UserDefaults.
/// Observable so SwiftUI views update automatically.
@MainActor
@Observable
public final class ThemeManager {
    private static let themeKey = "maugham.theme"
    private static let typographyKey = "maugham.typography"

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
    }
}
