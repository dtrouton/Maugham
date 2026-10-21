import Foundation

/// **The one place a project's kind is named** (report plan 4, R-4-8).
/// "Report" for a Report, otherwise the type's own name. New Project, the MCP
/// tools and Project Settings all ask here, so Mac and phone never spell a
/// kind twice (tripwire 19). `TripwireGrepTests.test_kindNamesAreSpelledInProjectKindNameOnly`
/// refuses a kind name, or a type's raw value shown as one, anywhere else.
public enum ProjectKindName {

    /// The kind a project IS: "Report" when its profile is a report (whatever
    /// structure it sits on), otherwise its type's name. A profile this build
    /// does not know names the type.
    public static func of(_ manifest: ProjectManifest) -> String {
        switch manifest.profile {
        case .report?: return "Report"
        case .unknown?, nil: return of(manifest.type)
        }
    }

    /// A type's name. A newer build's type (`.unknown`) is just a project.
    public static func of(_ type: ProjectType) -> String {
        switch type {
        case .shortStory: return "Short Story"
        case .novel: return "Novel"
        case .screenplay: return "Screenplay"
        case .collection: return "Collection"
        case .unknown: return "Project"
        }
    }
}
