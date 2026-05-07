import Foundation

/// Optional project-level word and deadline goals.
/// Stored under the `targets` key of the manifest.
public struct ProjectTargets: Codable, Equatable, Sendable {
    public var totalWords: Int?
    public var deadline: Date?

    public init(totalWords: Int? = nil, deadline: Date? = nil) {
        self.totalWords = totalWords
        self.deadline = deadline
    }
}
