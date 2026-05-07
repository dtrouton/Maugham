import Foundation

/// One of the four first-class writing forms supported by Maugham.
/// Raw values are stable snake_case strings used as the `type` field
/// in `project.maugham.json`. Never rename these.
public enum ProjectType: String, Codable, CaseIterable, Equatable, Sendable {
    case shortStory = "short_story"
    case novel = "novel"
    case screenplay = "screenplay"
    case collection = "collection"
}
