import Foundation
import MaughamCore

/// Selects the appropriate WritingMode and default TypographySettings
/// for a given document path, by its `DocumentFormat.ofManuscript(path:)`.
public enum WritingModeFactory {

    /// - Parameter figureThumbnails: whether a Markdown piece reserves the
    ///   space under each figure line that the manuscript editor draws its
    ///   thumbnail in (`ProseMode.reservesFigureThumbnails`). Only the
    ///   manuscript editor's surface says true; a screenplay ignores it.
    public static func mode(for path: String, figureThumbnails: Bool = false) -> any WritingMode {
        switch DocumentFormat.ofManuscript(path: path) {
        case .markdown: return ProseMode(reservesFigureThumbnails: figureThumbnails)
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
