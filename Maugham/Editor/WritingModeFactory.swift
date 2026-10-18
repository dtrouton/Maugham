import Foundation
import MaughamCore

/// Selects the appropriate WritingMode and default TypographySettings
/// for a given document path, by its `DocumentFormat.ofManuscript(path:)`.
public enum WritingModeFactory {

    public static func mode(for path: String) -> any WritingMode {
        switch DocumentFormat.ofManuscript(path: path) {
        case .markdown: return ProseMode()
        case .fountain: return ScreenplayMode()
        }
    }

    public static func defaultTypography(for path: String) -> TypographySettings {
        switch DocumentFormat.ofManuscript(path: path) {
        case .markdown: return .defaults
        case .fountain: return .screenplayDefaults
        }
    }
}
