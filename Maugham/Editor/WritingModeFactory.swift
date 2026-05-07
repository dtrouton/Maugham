import Foundation

/// Selects the appropriate WritingMode and default TypographySettings
/// for a given document path based on its file extension.
public enum WritingModeFactory {

    public static func mode(for path: String) -> any WritingMode {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "fountain": return ScreenplayMode()
        default:         return ProseMode()
        }
    }

    public static func defaultTypography(for path: String) -> TypographySettings {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "fountain": return .screenplayDefaults
        default:         return .defaults
        }
    }
}
