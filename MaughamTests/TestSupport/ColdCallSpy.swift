// MaughamTests/TestSupport/ColdCallSpy.swift
import Foundation
@testable import Maugham

/// **The spy every cold-call suite shares** (translation pipeline P4 Task 6).
///
/// It began as `ColdCallTests`' own private runner, on the loop-spy convention
/// that each session loop keeps a spy of its own because each diverges as its
/// loop grows. `ColdCall` is the exception the convention did not anticipate:
/// it is ONE runner with four callers (reader, collator, gloss, Ask the
/// collator), so a suite testing a caller is testing the same seam
/// `ColdCallTests` tests, and a second copy would be two spellings of one
/// contract that could disagree about what a held turn does.
///
/// One briefing in, one event out, the process ended. `nextEvent` nil holds the
/// turn open until `release(_:)`, which is how a caller's "a call is already
/// out" refusal is provoked without a real process.
@MainActor
final class ColdCallSpyRunner: CompilerRunner {
    private(set) var sends: [(message: String, preamble: String?)] = []
    private(set) var shutdowns = 0
    private(set) var cancels = 0
    var isRunning = false
    var sessionEpoch = 1
    var nextEvent: CompilerRunEvent? = .resultText("{\"gloss\":\"the fog came\"}")
    private var held: CheckedContinuation<CompilerRunEvent, Never>?

    func send(message: String, systemPreamble: String?) async -> CompilerRunEvent {
        sends.append((message, systemPreamble))
        if let nextEvent { return nextEvent }
        isRunning = true
        return await withCheckedContinuation { held = $0 }
    }

    func release(_ event: CompilerRunEvent) {
        isRunning = false
        let continuation = held
        held = nil
        continuation?.resume(returning: event)
    }

    func cancelCurrentRun() {
        cancels += 1
        release(.failed(.sessionDied(detail: CompilerRunFailure.Detail.cancelled)))
    }

    func shutdown() {
        shutdowns += 1
        release(.failed(.sessionDied(detail: CompilerRunFailure.Detail.sessionShutDown)))
    }
}

/// A factory that remembers every runner it made and the model it was asked
/// for, so a suite can assert what was sent without holding the runner itself.
@MainActor
final class ColdCallSpyFactory {
    private(set) var made: [ColdCallSpyRunner] = []
    private(set) var models: [String] = []
    var configure: (ColdCallSpyRunner) -> Void = { _ in }

    func make(model: String) -> CompilerRunner {
        let runner = ColdCallSpyRunner()
        configure(runner)
        made.append(runner)
        models.append(model)
        return runner
    }

    /// A wired `ColdCall` and the factory behind it — every caller's setup.
    static func makeColdCall() -> (ColdCall, ColdCallSpyFactory) {
        let factory = ColdCallSpyFactory()
        let coldCall = ColdCall()
        coldCall.configure(makeRunner: { factory.make(model: $0) })
        return (coldCall, factory)
    }
}
