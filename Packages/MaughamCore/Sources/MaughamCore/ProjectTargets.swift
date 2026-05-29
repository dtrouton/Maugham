import Foundation

/// Optional project-level targets: word count, deadline, and (3a) screenplay
/// page count. Stored under the `targets` key of the manifest.
public struct ProjectTargets: Codable, Equatable, Sendable {
    public var totalWords: Int?
    public var deadline: Date?
    public var pageTarget: Int?

    public init(
        totalWords: Int? = nil,
        deadline: Date? = nil,
        pageTarget: Int? = nil
    ) {
        self.totalWords = totalWords
        self.deadline = deadline
        self.pageTarget = pageTarget
    }
}
