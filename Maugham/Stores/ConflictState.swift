import Foundation

/// Snapshot of a document conflict: local unsaved version vs. external version
/// that arrived through NSFilePresenter. Banner reads from this.
public struct ConflictState: Equatable, Sendable {
    public let path: String
    public let localText: String
    public let externalText: String
    public let externalModifiedAt: Date

    public init(
        path: String,
        localText: String,
        externalText: String,
        externalModifiedAt: Date
    ) {
        self.path = path
        self.localText = localText
        self.externalText = externalText
        self.externalModifiedAt = externalModifiedAt
    }

    /// Word-count delta: positive = local is ahead, negative = external is ahead.
    public var localAheadByWords: Int {
        wordCount(localText) - wordCount(externalText)
    }

    /// Headline phrasing for the banner. Adapts to whichever side has more words.
    public var phrasing: String {
        let delta = localAheadByWords
        if delta > 0 {
            return "Your version (\(delta) words ahead) and the cloud version are different."
        }
        if delta < 0 {
            return "The cloud version (\(-delta) words ahead) and your version are different."
        }
        return "Your version and the cloud version are different."
    }

    private func wordCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return trimmed.split(whereSeparator: \.isWhitespace).count
    }
}
