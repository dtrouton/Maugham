import Foundation

/// Snapshot of everything the goal indicator capsule renders.
public struct GoalIndicatorState: Equatable, Sendable {
    public var docWordCount: Int
    public var docWordTarget: Int?
    public var projectWordCount: Int
    public var projectWordTarget: Int?
    public var wordsToday: Int
    public var readingMinutes: Int

    public init(
        docWordCount: Int = 0,
        docWordTarget: Int? = nil,
        projectWordCount: Int = 0,
        projectWordTarget: Int? = nil,
        wordsToday: Int = 0,
        readingMinutes: Int = 0
    ) {
        self.docWordCount = docWordCount
        self.docWordTarget = docWordTarget
        self.projectWordCount = projectWordCount
        self.projectWordTarget = projectWordTarget
        self.wordsToday = wordsToday
        self.readingMinutes = readingMinutes
    }

    public static let empty = GoalIndicatorState()
}
