import Foundation

/// **How long one turn took, and what it cost** (spec 2026-09-09 §5).
///
/// Two clocks: `elapsed` and `firstLineAfter` are Maugham's own (send → result,
/// send → first stdout line); everything else is read off the CLI's `result`
/// event. Stored on `CompilerRun.timing` so a run can be seen for what it
/// cost, and read by the evals milestone beside the effort it was asked for.
///
/// `public` because it is a requirement of the `public protocol CompilerRunner`
/// — Swift refuses an internal type there — not because anything outside this
/// module needs it.
public struct RunTiming: Codable, Equatable, Sendable {
    public var elapsed: TimeInterval
    public var firstLineAfter: TimeInterval?
    public var apiDuration: TimeInterval?
    public var turns: Int?
    public var outputTokens: Int?
    public var thinkingTokens: Int?
    public var costUSD: Double?
    public var model: String
    public var effort: String

    public init(elapsed: TimeInterval, firstLineAfter: TimeInterval? = nil,
                apiDuration: TimeInterval? = nil, turns: Int? = nil,
                outputTokens: Int? = nil, thinkingTokens: Int? = nil,
                costUSD: Double? = nil, model: String, effort: String) {
        self.elapsed = elapsed
        self.firstLineAfter = firstLineAfter
        self.apiDuration = apiDuration
        self.turns = turns
        self.outputTokens = outputTokens
        self.thinkingTokens = thinkingTokens
        self.costUSD = costUSD
        self.model = model
        self.effort = effort
    }
}

/// **What a live turn has done so far** — the CLI's running thinking-token
/// estimate, as it arrives. A preview like the partial text: nothing may be
/// concluded from it that outlives the turn.
public struct RunProgress: Equatable, Sendable {
    public var thinkingTokens: Int
    public var at: Date

    public init(thinkingTokens: Int, at: Date) {
        self.thinkingTokens = thinkingTokens
        self.at = at
    }
}
