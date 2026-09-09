# The Reader's Own Session — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A whole-piece check on a 450-paragraph screenplay finishes instead of being killed at 300 s, the spawned session carries the reader's identity rather than a coding agent's, the briefing stops sending the model fetching, and every run records how long it took.

**Architecture:** `ClaudeCLISession` (one class, four owners) gets a silence timer plus a ceiling in place of its per-turn kill, three new spawn arguments, and a per-turn `RunTiming` read off the CLI's `result` event; the `CompilerRunner` seam grows two defaulted members so every spy stays green; `CompilerOrchestrator` copies the timing onto `CompilerRun` and exposes a live start time and thinking-token progress for the two panes; `CompilerPrompt` inlines small pinned notes inside the hashed unit and states its own absences.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, XCTest (Mac scheme), the `claude` CLI 2.1.266 spawned through `Process`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-09-the-readers-own-session-design.md` — read it first; every number below is the spec's.

## Global Constraints

- Build/test flow: `./gen.sh` after ADDING any source or test file (the project is generated from globs; a stale project runs 0 tests for a new file with no error). Fast loop `./scripts/test.sh`; full gate `./scripts/test.sh full` before merge; a Release build before tagging is not required by this plan (no `ProjectWindow.body` change).
- Run a single test class with: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/<ClassName> 2>&1 | tail -30` (after `./gen.sh`).
- Silence budget **180 s**; ceiling **1,200 s**; `translationRunTimeout` (900 s) is **deleted**; `DeclaredWorldDeriver`'s 120 s deadline is untouched.
- Every spawn passes `--setting-sources ""`, `--system-prompt <preamble>`, `--effort high`. **`--append-system-prompt` must not appear in production.** `--bare` is forbidden (logs the writer out of OAuth).
- Effort is `ClaudeCLISession.Effort` with raw values exactly `low`, `medium`, `high`, `xhigh`, `max`; `defaultEffort = .high` for every session kind in this milestone.
- Inline pinned note cap **4,000 chars** per note, **40,000 chars** per briefing; the 40-pin `pinnedListingCap` stays.
- No hardcoded `"maugham"`/socket paths (tripwire 13); no `device:` strings at `Document.load` (tripwire 38); no `NSOpenPanel` in tests; no press-then-wait tests (tripwire 33).
- Commit messages end with the attribution block in the session's system reminder.
- Prose in sentences the pane says goes through `RoundNarrative`, never a second spelling in a view.

---

## File map

| file | change |
|---|---|
| `Maugham/Compiler/ClaudeCLISession.swift` | silence timer + ceiling; `Effort`; new spawn args; `RunTiming`/`RunProgress` capture; `Stall` |
| `Maugham/Compiler/CompilerRunner.swift` | `Stall` on `.timedOut`; `lastTurnTiming` + `setProgressHandler` with defaults |
| `Maugham/Compiler/RunTiming.swift` (new) | `RunTiming`, `RunProgress` |
| `Maugham/Compiler/DeclaredWorldDeriver.swift` | same three spawn args |
| `Maugham/Compiler/TranslatorEnvironment+Project.swift`, `ColdCall.swift` | drop `runTimeout:` |
| `Maugham/Compiler/RoundNarrative.swift` | stall sentences; live checking copy; read-in line; timing detail |
| `Maugham/Compiler/Diagnostic.swift` | `CompilerRun.timing` |
| `Maugham/Compiler/CompilerOrchestrator.swift` | `runStartedAt`, `runProgress`; timing onto the record |
| `Maugham/Compiler/CompilerPrompt.swift` | pinned listing inside the hash; absence sentences; whole-read instruction |
| `Maugham/Compiler/CompilerEnvironment+Project.swift` | pinned bodies, inline lines |
| `Maugham/Views/DiagnosticsPane.swift`, `Maugham/Views/Review/ReviewRoundCockpit.swift`, `Maugham/Views/AnnotationsPane.swift` | elapsed + progress while running; read-in line + tooltip |
| tests | `ClaudeCLISessionTests`, `TripwireGrepTests`, `DeclaredWorldDeriverTests`, `ColdCallTests`, `TranslatorEnvironmentTests`, `RoundNarrativeTests`, `CompilerRunCommandTests`, `DiagnosticsPaneTests`, `ReviewRoundCockpitTests`, `CompilerPromptTests`, `DepartmentRunTests` |
| docs | `Maugham/Compiler/AREA.md`, `CLAUDE.md`, `docs/guide/review-passes.md`, `docs/roadmap.md` |

---

### Task 1: Liveness — a silence timer and a ceiling replace the per-turn kill

**Files:**
- Modify: `Maugham/Compiler/CompilerRunner.swift` (`CompilerRunFailure.timedOut`)
- Modify: `Maugham/Compiler/ClaudeCLISession.swift` (timers, constants)
- Modify: `Maugham/Compiler/TranslatorEnvironment+Project.swift:113-119`, `Maugham/Compiler/ColdCall.swift:118-127`
- Modify: `MaughamTests/ClaudeCLISessionTests.swift`, `MaughamTests/ColdCallTests.swift:158-166`, `MaughamTests/TranslatorEnvironmentTests.swift:972-982`, `MaughamTests/ReviewRoundCockpitTests.swift`, `MaughamTests/DepartmentRunTests.swift`

**Interfaces:**
- Produces: `public struct CompilerRunFailure.Stall { cause: .silence|.ceiling, after: TimeInterval, thinkingTokens: Int? }`; `case timedOut(Stall = .unknown)`; `ClaudeCLISession.defaultSilenceTimeout = 180`, `defaultRunTimeout = 1200`, init parameter `silenceTimeout:`; `translationRunTimeout` GONE.
- Later tasks: Task 3 fills `thinkingTokens` on a stall; Task 2 sets the failure sentences.

- [ ] **Step 1: Add the `Stall` type and the associated value**

In `Maugham/Compiler/CompilerRunner.swift`, replace the bare case:

```swift
    /// The turn outran its budget. The session is torn down; the next send
    /// starts fresh. `Stall` says WHICH budget — the child went quiet, or the
    /// ceiling passed while it was still speaking — because the two mean
    /// different things to the writer (spec §2).
    case timedOut(Stall = .unknown)
```

and add, after the `Detail` enum inside `extension CompilerRunFailure`:

```swift
    /// Why a turn was stopped by a timer, and how far it had got.
    ///
    /// `silence` is what "genuinely hung" means — the CLI wrote nothing for
    /// `silenceTimeout`. `ceiling` is a child still speaking when the run's
    /// hard bound passed. `thinkingTokens` is the CLI's own running estimate
    /// at the moment of the stop (Task 3 fills it; `nil` until then and for
    /// a runner that reports none).
    public struct Stall: Equatable, Sendable {
        public enum Cause: String, Equatable, Sendable {
            case silence, ceiling
        }
        public let cause: Cause
        public let after: TimeInterval
        public let thinkingTokens: Int?

        public init(cause: Cause, after: TimeInterval, thinkingTokens: Int? = nil) {
            self.cause = cause
            self.after = after
            self.thinkingTokens = thinkingTokens
        }

        /// A stop with no account of itself — the default so an `.timedOut()`
        /// built by a test or a legacy site still compiles and still says
        /// "took too long".
        public static let unknown = Stall(cause: .ceiling, after: 0)
    }
```

- [ ] **Step 2: Sweep the test sites that name the bare case**

Every `.timedOut` used as a VALUE becomes `.timedOut()` (pattern matches `case .timedOut:` are unchanged). The sites, from `grep -rn "\.timedOut" MaughamTests`:

- `MaughamTests/ClaudeCLISessionTests.swift:544` — replaced by the new assertion in Step 6 anyway.
- `MaughamTests/ReviewRoundCockpitTests.swift:148` (`[.timedOut, ...]` → `[.timedOut(), ...]`), `:171`, `:199`, `:752`, `:810`, `:813`, `:1142` — `.timedOut` → `.timedOut()` in each value position (line 1210 is a `case .timedOut:` pattern — leave it).
- `MaughamTests/DepartmentRunTests.swift:287`, `:289`, `:362` — `.run(.timedOut)` → `.run(.timedOut())`.

Run: `grep -rn "\.timedOut\b[^(]" MaughamTests Maugham --include='*.swift' | grep -v "case \.timedOut"` — expect no output.

- [ ] **Step 3: Write the failing liveness tests**

In `MaughamTests/ClaudeCLISessionTests.swift`, add a fixture mode to `FakeMode`:

```swift
        /// Keep TALKING for as long as the `slow` flag file exists — one
        /// `system/thinking_tokens` progress line every 100 ms, the line the
        /// real CLI emits while the model thinks (captured 2026-09-09) — and
        /// answer once the flag lifts. A session that measures liveness by
        /// silence must not kill this one; a session that measures it by wall
        /// clock did (spec §2).
        case chatterWhileFlagged
```

and in the script body, immediately after the `slowWhileFlagged` block inside the `while IFS= read` loop:

```bash
          if [ "$MODE" = "chatterWhileFlagged" ]; then
            waited=0
            while [ -e "$FLAG" ] && [ "$waited" -lt \(maxStallSeconds * 10) ]; do
              printf '%s\\n' '{"type":"system","subtype":"thinking_tokens","estimated_tokens":50,"estimated_tokens_delta":50,"session_id":"fake-session","uuid":"00000000-0000-0000-0000-000000000000"}'
              sleep 0.1
              waited=$((waited+1))
            done
          fi
```

Change `makeSession` to take `silenceTimeout: TimeInterval = 20` and pass it to the init (beside `runTimeout:`). Replace `test_runTimeout` with three tests:

```swift
    /// A child that has stopped writing is what "hung" means: the silence
    /// budget ends it, and the stall says so.
    func test_silenceEndsATurnAndSaysSo() async throws {
        let cli = try makeFakeCLI(mode: .slowWhileFlagged)
        try Data().write(to: slowFlagURL)   // never lifted: the turn never lands
        let session = makeSession(cli: cli, silenceTimeout: 0.4, runTimeout: 20)

        let started = Date()
        let event = await session.send(message: "slow", systemPreamble: nil)
        let elapsed = Date().timeIntervalSince(started)

        guard case .failed(.timedOut(let stall)) = event else {
            return XCTFail("expected a stall, got \(event)")
        }
        XCTAssertEqual(stall.cause, .silence)
        XCTAssertGreaterThanOrEqual(stall.after, 0.4)
        XCTAssertLessThan(elapsed, 4, "the silence budget must fire well before the fixture answers")
        XCTAssertFalse(session.isRunning)
        session.shutdown()
    }

    /// A child still WRITING past the old per-turn budget is not hung. The
    /// silence timer resets on every line — thinking-progress lines included,
    /// which the classifier otherwise ignores — so the turn is allowed to
    /// finish (spec §2: liveness, not wall clock).
    func test_aChildStillWritingIsNotKilled() async throws {
        let cli = try makeFakeCLI(mode: .chatterWhileFlagged)
        try Data().write(to: slowFlagURL)
        // A silence budget shorter than the chatter's total, a ceiling far off.
        let session = makeSession(cli: cli, silenceTimeout: 0.5, runTimeout: 20)

        let flag = slowFlagURL!
        Task.detached {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            try? FileManager.default.removeItem(at: flag)
        }
        let event = await session.send(message: "chatty", systemPreamble: nil)

        XCTAssertEqual(event, .resultText("FAKE RESULT"),
            "1.5 s of chatter against a 0.5 s silence budget must not be a stall")
        session.shutdown()
    }

    /// The ceiling still bounds a child that never stops talking.
    func test_theCeilingEndsAChildThatNeverStopsTalking() async throws {
        let cli = try makeFakeCLI(mode: .chatterWhileFlagged)
        try Data().write(to: slowFlagURL)   // never lifted
        let session = makeSession(cli: cli, silenceTimeout: 5, runTimeout: 0.6)

        let event = await session.send(message: "chatty", systemPreamble: nil)

        guard case .failed(.timedOut(let stall)) = event else {
            return XCTFail("expected a stall, got \(event)")
        }
        XCTAssertEqual(stall.cause, .ceiling)
        XCTAssertGreaterThanOrEqual(stall.after, 0.6)
        XCTAssertFalse(session.isRunning)
        session.shutdown()
    }
```

Also add a constants pin:

```swift
    /// The two budgets are the spec's numbers (§2), and the translation cast's
    /// separate 900 s constant is gone: one ceiling for every session type.
    func test_theBudgetsAreTheSpecs() {
        XCTAssertEqual(ClaudeCLISession.defaultSilenceTimeout, 180)
        XCTAssertEqual(ClaudeCLISession.defaultRunTimeout, 1_200)
    }
```

- [ ] **Step 4: Run the new tests to see them fail**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ClaudeCLISessionTests 2>&1 | tail -30`
Expected: compile failure on `silenceTimeout:` / `defaultSilenceTimeout` (not defined yet).

- [ ] **Step 5: Implement the two timers in `ClaudeCLISession`**

Replace the `defaultRunTimeout` doc comment + constant and DELETE `translationRunTimeout` (its whole doc block, `nonisolated static let translationRunTimeout: TimeInterval = 900`). New constants:

```swift
    /// **How long the child may be SILENT before the turn is stopped — 180 s.**
    ///
    /// Liveness, not wall clock (spec §2, 2026-09-09). Four whole-piece checks
    /// on a 457-paragraph screenplay died at the old 300 s per-turn budget
    /// while Opus was visibly streaming thinking at ~68 tokens/s — the timer
    /// killed a model that was working and threw away what it had paid for.
    /// Every line the child writes resets this: a text, thinking or signature
    /// delta, a `system/thinking_tokens` progress event, a `rate_limit_event`,
    /// a line that is not JSON. Silence is what "genuinely hung" means. 180 s
    /// covers an overloaded API's retry backoff and the gap between a tool
    /// result and the next request's first byte, with room.
    nonisolated static let defaultSilenceTimeout: TimeInterval = 180

    /// **The ceiling — 1,200 s (20 min) — one constant for every session
    /// type.** A child still speaking at the ceiling is stopped anyway: the
    /// point is that a runaway session cannot bill indefinitely. The
    /// translation cast's separate 900 s budget (2026-09-02) is gone with the
    /// per-turn kill it was a stopgap for. Safe above `idleTimeout` (600 s)
    /// because `idleDidExpire` refuses while a turn is in flight.
    nonisolated static let defaultRunTimeout: TimeInterval = 1_200
```

State: beside `runTimeoutTask`, add

```swift
    private let silenceTimeout: TimeInterval
    private var silenceTask: Task<Void, Never>?
    /// The last moment the child wrote anything on stdout, for the live
    /// generation. Read by the silence watch, written by `receive`.
    private var lastActivityAt = Date()
    /// When the turn in flight was sent — the ceiling's and the stall's clock.
    private var turnStartedAt = Date()
```

Init: add `silenceTimeout: TimeInterval = ClaudeCLISession.defaultSilenceTimeout,` before `runTimeout:` and store it.

In `send`, where `armRunTimeout(token: token)` is called inside the continuation block, replace with:

```swift
                turnStartedAt = Date()
                armRunTimeout(token: token)
                armSilenceWatch(token: token)
```

In `receive(line:generation:)`, as the first statement after the guard:

```swift
        guard gen == generation, inFlight != nil else { return }
        // Liveness, before meaning: whatever this line IS, the child wrote it.
        lastActivityAt = Date()
```

Replace `runDidTimeOut` and add the watch:

```swift
    private func runDidTimeOut(token: Int) {
        guard token == runToken, inFlight != nil else { return }
        stall(token: token, cause: .ceiling, after: Date().timeIntervalSince(turnStartedAt))
    }

    /// One sleep per silence budget rather than a timer re-armed per line: a
    /// thinking model writes several lines a second, and cancelling and
    /// recreating a `Task` for each would be the cost this watch exists to
    /// avoid. It sleeps the remaining budget, checks again, and only stops the
    /// turn when the quiet has really lasted.
    private func armSilenceWatch(token: Int) {
        silenceTask?.cancel()
        lastActivityAt = Date()
        let budget = silenceTimeout
        silenceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let quiet = Date().timeIntervalSince(self.lastActivityAt)
                if quiet >= budget {
                    self.stall(token: token, cause: .silence, after: quiet)
                    return
                }
                let remaining = max(0.05, budget - quiet)
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
    }

    /// The one door out of a turn by timer. The CLI is still working (or has
    /// gone quiet); ending it means ending the process. The next send respawns.
    private func stall(token: Int, cause: CompilerRunFailure.Stall.Cause, after: TimeInterval) {
        guard token == runToken, inFlight != nil else { return }
        let stall = CompilerRunFailure.Stall(cause: cause, after: after, thinkingTokens: nil)
        teardown()
        resolve(.failed(.timedOut(stall)), token: token)
    }
```

In `resolve`, after `runTimeoutTask = nil`, add `silenceTask?.cancel(); silenceTask = nil`. In `teardown`, after the `runTimeoutTask` lines, add the same two lines.

- [ ] **Step 6: Drop the translation budget from the two factories and their tests**

`Maugham/Compiler/TranslatorEnvironment+Project.swift` — delete the line `runTimeout: ClaudeCLISession.translationRunTimeout)` and close the call after `isEnabled:` (`isEnabled: { [weak preferences] in preferences?.mcpEnabled ?? false })`). `Maugham/Compiler/ColdCall.swift` — same (`isEnabled: { preferences?.mcpEnabled ?? false })`).

`MaughamTests/ColdCallTests.swift:164-165` — replace the assertion with:

```swift
        XCTAssertEqual(session?.runTimeout, ClaudeCLISession.defaultRunTimeout,
                       "one ceiling for every session type (spec 2026-09-09 §2)")
```

`MaughamTests/TranslatorEnvironmentTests.swift:980` — replace with `XCTAssertEqual(session.runTimeout, ClaudeCLISession.defaultRunTimeout)` and retitle the test's doc comment: *"The translation cast once carried a 900 s budget of its own; since the liveness milestone every session shares one ceiling, and this pins that the factory passes nothing special."*

Also delete the `runTimeout` doc sentence in `ClaudeCLISession` that says *"the two translation factories hand their sessions `translationRunTimeout`"* — make it: `/// Readable for the two factory tests that pin every session on one ceiling.`

- [ ] **Step 7: Run the session, cold-call, translator, cockpit and department suites**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ClaudeCLISessionTests -only-testing:MaughamTests/ColdCallTests -only-testing:MaughamTests/TranslatorEnvironmentTests -only-testing:MaughamTests/ReviewRoundCockpitTests -only-testing:MaughamTests/DepartmentRunTests 2>&1 | tail -30`
Expected: all PASS, including the three new liveness tests and the constants pin.

- [ ] **Step 8: Fast loop and commit**

Run: `./scripts/test.sh` — expected green.

```bash
git add -A Maugham MaughamTests
git commit -m "feat(compiler): liveness replaces the per-turn kill — a silence timer, one ceiling, and a stall that says which

<attribution block>"
```

---

### Task 2: The stall's sentences

**Files:**
- Modify: `Maugham/Compiler/RoundNarrative.swift:232-247` (`failureCopy`)
- Test: `MaughamTests/RoundNarrativeTests.swift`

**Interfaces:**
- Consumes: `CompilerRunFailure.Stall` (Task 1).
- Produces: `RoundNarrative.failureCopy(.timedOut(stall))` sentences; `RoundNarrative.minutesPhrase(_:)`.

- [ ] **Step 1: Write the failing tests**

Append to `MaughamTests/RoundNarrativeTests.swift`:

```swift
    // MARK: - The stall says which budget (spec 2026-09-09 §2)

    func test_aSilenceStallSaysClaudeWentQuiet() {
        let stall = CompilerRunFailure.Stall(cause: .silence, after: 183, thinkingTokens: nil)
        XCTAssertEqual(
            RoundNarrative.failureCopy(.timedOut(stall)),
            "Claude went quiet for 3 minutes and was stopped.")
    }

    func test_aCeilingStallSaysTheReadPassedTheBound() {
        let stall = CompilerRunFailure.Stall(cause: .ceiling, after: 1_204, thinkingTokens: 31_000)
        XCTAssertEqual(
            RoundNarrative.failureCopy(.timedOut(stall)),
            "The read passed 20 minutes and was stopped \u{2014} 31,000 tokens of thinking so far.")
    }

    func test_aStallWithNoAccountOfItselfStillSaysTookTooLong() {
        XCTAssertEqual(
            RoundNarrative.failureCopy(.timedOut()),
            "The check took too long and was stopped.")
        XCTAssertEqual(
            RoundNarrative.failureCopy(.timedOut(), session: .translation),
            "The translation round took too long and was stopped.")
    }

    func test_theMinutesPhraseRoundsToTheNearestMinuteAndNeverSaysZero() {
        XCTAssertEqual(RoundNarrative.minutesPhrase(20), "under a minute")
        XCTAssertEqual(RoundNarrative.minutesPhrase(59), "under a minute")
        XCTAssertEqual(RoundNarrative.minutesPhrase(60), "1 minute")
        XCTAssertEqual(RoundNarrative.minutesPhrase(183), "3 minutes")
        XCTAssertEqual(RoundNarrative.minutesPhrase(1_204), "20 minutes")
    }
```

- [ ] **Step 2: Run to see them fail**

Run: `xcodebuild ... -only-testing:MaughamTests/RoundNarrativeTests 2>&1 | tail -20` — expected: compile failure on `minutesPhrase`, then assertion failures.

- [ ] **Step 3: Implement**

In `RoundNarrative.failureCopy`, replace the `.timedOut` arm:

```swift
        case .timedOut(let stall):
            return stallCopy(stall, session: session)
```

Add, after `failureCopy`:

```swift
    /// **Which budget stopped the turn, and how far it had got** (spec
    /// 2026-09-09 §2). A stall with no account of itself (`Stall.unknown`,
    /// `after == 0`) keeps the sentence every caller had before this
    /// milestone, so a legacy `.timedOut()` reads exactly as it did.
    static func stallCopy(_ stall: CompilerRunFailure.Stall, session: SessionWork) -> String {
        guard stall.after > 0 else {
            return "\(session.subject) took too long and was stopped."
        }
        let base: String
        switch stall.cause {
        case .silence:
            base = "Claude went quiet for \(minutesPhrase(stall.after)) and was stopped"
        case .ceiling:
            base = "The read passed \(minutesPhrase(stall.after)) and was stopped"
        }
        guard let tokens = stall.thinkingTokens, tokens > 0 else { return base + "." }
        return base + " \u{2014} \(thousands(tokens)) tokens of thinking so far."
    }

    /// Whole minutes, in the writer's English. Under sixty seconds is "under
    /// a minute" rather than "0 minutes".
    static func minutesPhrase(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.down))
        guard minutes >= 1 else { return "under a minute" }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// `31,000`, never `31000`: the pane's numbers are read, not parsed.
    static func thousands(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
```

- [ ] **Step 4: Run RoundNarrativeTests and ReviewRoundCockpitTests; commit**

Run: `xcodebuild ... -only-testing:MaughamTests/RoundNarrativeTests -only-testing:MaughamTests/ReviewRoundCockpitTests -only-testing:MaughamTests/DiagnosticsPaneTests 2>&1 | tail -20` — expected PASS.

```bash
git add Maugham/Compiler/RoundNarrative.swift MaughamTests/RoundNarrativeTests.swift
git commit -m "feat(compiler): the stall says which budget stopped the turn and how far it had got

<attribution block>"
```

---

### Task 3: The session is the reader's own — three spawn arguments and a census

**Files:**
- Modify: `Maugham/Compiler/ClaudeCLISession.swift:452-480` (`arguments`), init (`effort:`)
- Modify: `Maugham/Compiler/DeclaredWorldDeriver.swift:151-153` (`arguments`)
- Test: `MaughamTests/ClaudeCLISessionTests.swift` (`test_spawnArgumentsMatchTheSpike`, `test_argumentsDifferBetweenBridgedAndSealedExactlyWhereTheMembraneSaysTheyDo`), `MaughamTests/DeclaredWorldDeriverTests.swift`, `MaughamTests/TripwireGrepTests.swift`

**Interfaces:**
- Produces: `ClaudeCLISession.Effort` (`String` raw, `CaseIterable`), `ClaudeCLISession.defaultEffort = .high`, init parameter `effort: Effort = ClaudeCLISession.defaultEffort`, `let effort: Effort` readable, `ClaudeCLISession.defaultSystemPrompt`, `static func arguments(model:effort:confinement:preamble:)`, `DeclaredWorldDeriver.derivationSystemPrompt`.
- Task 4 reads `effort.rawValue` into `RunTiming`.

- [ ] **Step 1: Write the failing spawn-argument tests**

In `MaughamTests/ClaudeCLISessionTests.swift`, inside `test_spawnArgumentsMatchTheSpike`, REPLACE the `--append-system-prompt` assertion with:

```swift
        // **The session is the reader's own** (spec 2026-09-09 §3). Verified
        // live on claude 2.1.266: `--setting-sources ""` keeps OAuth and drops
        // every hook, plugin, CLAUDE.md and the writer's global effort;
        // `--system-prompt` REPLACES the coding-agent prompt rather than
        // appending to it; `--effort` is explicit so ignoring the settings
        // files does not fall back to the CLI's own default.
        XCTAssertEqual(value(after: "--setting-sources"), "",
                       "no settings file may reach the reader's session")
        XCTAssertEqual(value(after: "--system-prompt"), "BE TERSE",
                       "the preamble is the WHOLE system prompt")
        XCTAssertFalse(argv.contains("--append-system-prompt"),
                       "appending keeps the coding-agent prompt in front of the reader")
        XCTAssertFalse(argv.contains("--bare"),
                       "--bare never reads OAuth and would log the writer out")
        XCTAssertEqual(value(after: "--effort"), "high",
                       "this milestone pins every session on the effort the writer's runs already inherited")
```

Add two tests:

```swift
    /// The effort levels are the CLI's five, spelled as it accepts them — an
    /// unknown value is ignored by `claude` with a warning, which is a silent
    /// fallback to its default.
    func test_effortLevelsAreTheCLIsFive() {
        XCTAssertEqual(ClaudeCLISession.Effort.allCases.map(\.rawValue),
                       ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(ClaudeCLISession.defaultEffort, .high)
    }

    /// A caller with no preamble still gets a system prompt of Maugham's, so
    /// the coding-agent prompt can never come back through a nil.
    func test_aNilPreambleStillReplacesTheSystemPrompt() async throws {
        let cli = try makeFakeCLI(mode: .normal)
        let session = makeSession(cli: cli)
        _ = await session.send(message: "hello", systemPreamble: nil)
        var argv = try String(contentsOf: argsURL, encoding: .utf8)
            .components(separatedBy: "\n")
        if argv.last?.isEmpty == true { argv.removeLast() }
        guard let i = argv.firstIndex(of: "--system-prompt"), i + 1 < argv.count else {
            return XCTFail("--system-prompt missing from \(argv)")
        }
        XCTAssertEqual(argv[i + 1], ClaudeCLISession.defaultSystemPrompt)
        session.shutdown()
    }
```

In `test_argumentsDifferBetweenBridgedAndSealedExactlyWhereTheMembraneSaysTheyDo`, the two `ClaudeCLISession.arguments(model:confinement:preamble:)` calls gain `effort: .high` after `model:`.

In `MaughamTests/DeclaredWorldDeriverTests.swift`, add:

```swift
    /// The one-shot deriver spawns the same shape as the warm session (spec
    /// 2026-09-09 §3): no settings files, its own system prompt, explicit
    /// effort, no built-in tools, and — as before — no `--mcp-config` at all.
    func test_spawnArgumentsKeepTheWritersSettingsOut() {
        let argv = ClaudeWorldDeriver.arguments(model: "haiku")
        func value(after flag: String) -> String? {
            guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
            return argv[i + 1]
        }
        XCTAssertEqual(value(after: "--setting-sources"), "")
        XCTAssertEqual(value(after: "--system-prompt"), ClaudeWorldDeriver.derivationSystemPrompt)
        XCTAssertEqual(value(after: "--effort"), ClaudeCLISession.defaultEffort.rawValue)
        XCTAssertEqual(value(after: "--tools"), "")
        XCTAssertFalse(argv.contains("--mcp-config"))
        XCTAssertFalse(argv.contains("--append-system-prompt"))
    }
```

- [ ] **Step 2: Write the failing tripwire census and its control**

Append to `MaughamTests/TripwireGrepTests.swift` (inside the class):

```swift
    // MARK: - The spawned session is the reader's own (spec 2026-09-09 §3)

    /// A line that spells the old flag inside prose rather than as an argument.
    private static func appendSystemPromptCommentLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    /// `--append-system-prompt` keeps Claude Code's coding-agent prompt in
    /// front of whatever Maugham says; `--system-prompt` replaces it. No
    /// production spawn may use the former.
    func test_noProductionSpawnAppendsToTheCodingAgentPrompt() throws {
        let offenders = try grepSwift(
            in: sourceDir,
            patterns: ["\"--append-system-prompt\""],
            excludeLine: Self.appendSystemPromptCommentLine)
        XCTAssertTrue(offenders.isEmpty,
            "A production spawn appends to the coding-agent system prompt. Use "
            + "--system-prompt so the preamble IS the prompt (spec 2026-09-09 §3). "
            + "Offenders:\n" + offenders.joined(separator: "\n"))
    }

    /// Every production file that builds a `claude` argv (it names
    /// `--output-format`) must also pass `--setting-sources`, or the writer's
    /// hooks, plugins and global effort ride into the session.
    func test_everyProductionSpawnIgnoresTheWritersSettingsFiles() throws {
        XCTAssertTrue(try spawnSitesMissingSettingSources(in: sourceDir).isEmpty,
            "A production `claude` spawn does not pass --setting-sources \"\". "
            + "Offenders:\n" + (try spawnSitesMissingSettingSources(in: sourceDir)).joined(separator: "\n"))
    }

    /// Files under `dir` whose text builds a claude argv (`--output-format`)
    /// without `--setting-sources`.
    private func spawnSitesMissingSettingSources(in dir: URL) throws -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let spawns = text.contains("\"--output-format\"")
            let ignores = text.contains("\"--setting-sources\"")
            if spawns && !ignores { offenders.append(url.lastPathComponent) }
        }
        return offenders
    }

    /// CONTROL: both censuses fire on planted offenders and pass a clean file.
    func test_theSpawnCensusesFireOnPlantedOffenders() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("tripwire-spawn-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try """
        // A comment may name "--append-system-prompt" — allowed.
        let bad = ["-p", "--output-format", "json", "--append-system-prompt", preamble]
        """.write(to: tmp.appendingPathComponent("BadSpawn.swift"), atomically: true, encoding: .utf8)
        try """
        let good = ["-p", "--output-format", "json", "--setting-sources", "", "--system-prompt", preamble]
        """.write(to: tmp.appendingPathComponent("GoodSpawn.swift"), atomically: true, encoding: .utf8)

        let appended = try grepSwift(
            in: tmp, patterns: ["\"--append-system-prompt\""],
            excludeLine: Self.appendSystemPromptCommentLine)
        XCTAssertEqual(appended.count, 1, "Self-check: one planted append. Caught:\n"
            + appended.joined(separator: "\n"))
        XCTAssertTrue(appended[0].hasPrefix("BadSpawn.swift"))

        let missing = try spawnSitesMissingSettingSources(in: tmp)
        XCTAssertEqual(missing, ["BadSpawn.swift"],
            "Self-check: the spawn without --setting-sources is the one caught")
    }
```

- [ ] **Step 3: Run to see them fail**

Run: `xcodebuild ... -only-testing:MaughamTests/ClaudeCLISessionTests -only-testing:MaughamTests/DeclaredWorldDeriverTests -only-testing:MaughamTests/TripwireGrepTests 2>&1 | tail -30` — expected: compile errors on `Effort`/`defaultSystemPrompt`/`derivationSystemPrompt`.

- [ ] **Step 4: Implement in `ClaudeCLISession`**

Add the type and constants near `Confinement`:

```swift
    /// **How hard the model thinks — the CLI's own dial, spelled as it
    /// accepts it.** An unknown value is ignored by `claude` with a warning
    /// and its default used instead, so the set is pinned by test.
    ///
    /// `--effort` is passed on every spawn because `--setting-sources ""`
    /// drops the `effortLevel` the writer's runs inherited from their user
    /// settings; `defaultEffort` is that inherited value, so this milestone
    /// changes the session's identity, liveness and briefing and NOT how hard
    /// it thinks. The per-kind table is the evals milestone's to decide
    /// (`docs/superpowers/specs/2026-09-09-evals-design.md`).
    enum Effort: String, CaseIterable, Equatable, Sendable {
        case low, medium, high, xhigh, max
    }

    nonisolated static let defaultEffort: Effort = .high

    /// The system prompt a caller that passes no preamble gets. Never the
    /// CLI's own: a nil must not bring the coding-agent prompt back.
    nonisolated static let defaultSystemPrompt =
        "You are reading for the writer of a manuscript-in-progress. Everything "
        + "you need is in the message; answer with what it asks for and nothing else."
```

Add `let effort: Effort` beside `let runTimeout`, an init parameter `effort: Effort = ClaudeCLISession.defaultEffort,` right after `model:`, and `self.effort = effort`. Update the spawn call: `Self.arguments(model: model, effort: effort, confinement: confinement, preamble: lastPreamble)`.

Replace `arguments`:

```swift
    static func arguments(model: String, effort: Effort, confinement: Confinement,
                          preamble: String?) -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--model", model,
            "--effort", effort.rawValue,
            // **No settings file reaches the session** (spec 2026-09-09 §3):
            // no hooks, no plugin's SessionStart injection, no CLAUDE.md, no
            // inherited effort. MCP still arrives through --mcp-config,
            // permissions through --allowedTools, and OAuth still works —
            // verified live on 2.1.266. NOT --bare, whose help says OAuth and
            // the keychain are never read.
            "--setting-sources", "",
        ]
        if case .bridged(let path) = confinement {
            args += ["--mcp-config", path.path]
        }
        args += [
            "--strict-mcp-config",
            "--include-partial-messages",
            "--tools", "",
            // REPLACES the coding-agent prompt rather than appending to it —
            // the preamble is the whole identity the model reads.
            "--system-prompt", preamble?.isEmpty == false ? preamble! : defaultSystemPrompt,
        ]
        if case .bridged = confinement {
            args += CompilerAllowlist.cliArguments()
        }
        return args
    }
```

Rewrite the doc comment above `arguments` so its first paragraph says the preamble rides on `--system-prompt` (replace, not append; verified 2026-09-09) and keep the membrane paragraphs as they are. Also update the `--include-partial-messages` comment block you removed — put its sentence back as a `//` comment above that line (it explains why the stream is asked for).

- [ ] **Step 5: Implement in `DeclaredWorldDeriver`**

```swift
    /// The deriver's whole system prompt — the identity its stdin prompt
    /// already opens with, so nothing of Claude Code's own prompt is in
    /// front of it (spec 2026-09-09 §3).
    static let derivationSystemPrompt =
        "You are the derivation layer of a writing tool. Answer only with the "
        + "structure the message asks for."

    /// `-p --output-format json`: one batch JSON envelope, never
    /// `stream-json`. No `--mcp-config` at all — the flag that grants MCP
    /// tools is simply absent, not merely empty — and `--tools ""` empties
    /// the built-in set (Read/Glob/Grep would otherwise reach any file in
    /// the working directory even under an enumerated allowlist; see
    /// `ClaudeCLISession.arguments`'s doc for the flag's own history). The
    /// three arguments the warm session passes for the writer's sake are
    /// passed here too: the deriver inherits the same hooks otherwise.
    static func arguments(model: String) -> [String] {
        ["-p", "--output-format", "json", "--model", model,
         "--effort", ClaudeCLISession.defaultEffort.rawValue,
         "--setting-sources", "",
         "--system-prompt", derivationSystemPrompt,
         "--tools", ""]
    }
```

- [ ] **Step 6: Run the three suites, then the fast loop; commit**

Run: `xcodebuild ... -only-testing:MaughamTests/ClaudeCLISessionTests -only-testing:MaughamTests/DeclaredWorldDeriverTests -only-testing:MaughamTests/TripwireGrepTests 2>&1 | tail -30` — expected PASS. Then `./scripts/test.sh` — green.

```bash
git add -A Maugham MaughamTests
git commit -m "feat(compiler): the session is the reader's own — no settings files, the preamble as the whole system prompt, explicit effort

<attribution block>"
```

---

### Task 4: `RunTiming` and `RunProgress` — the session measures its turn

**Files:**
- Create: `Maugham/Compiler/RunTiming.swift`
- Modify: `Maugham/Compiler/CompilerRunner.swift` (protocol + defaults)
- Modify: `Maugham/Compiler/ClaudeCLISession.swift` (`StreamLine`, `classify`, `receive`, state)
- Test: `MaughamTests/ClaudeCLISessionTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct RunTiming: Codable, Equatable, Sendable {
      var elapsed: TimeInterval; var firstLineAfter: TimeInterval?; var apiDuration: TimeInterval?
      var turns: Int?; var outputTokens: Int?; var thinkingTokens: Int?; var costUSD: Double?
      var model: String; var effort: String
  }
  struct RunProgress: Equatable, Sendable { var thinkingTokens: Int; var at: Date }
  ```
  `CompilerRunner.lastTurnTiming: RunTiming?` (default `nil`), `CompilerRunner.setProgressHandler(_:)` (default no-op); `ClaudeCLISession.StreamLine.thinkingProgress(estimatedTokens: Int)`; `ClaudeCLISession.resultFacts(fromLine:) -> ResultFacts?`.
- Task 1's `Stall.thinkingTokens` is now filled from the session's latest estimate.

- [ ] **Step 1: Write the failing tests**

Add captured constants beside the 2026-08-08 ones in `ClaudeCLISessionTests`:

```swift
    /// **Captured 2026-09-09 from `claude` 2.1.266** (one `-p --include-partial-
    /// messages --model haiku --effort low` turn; session/uuid fields as they
    /// came). Two lines the 2026-08-08 capture predates: the CLI's own
    /// thinking-token progress event, and a `result` carrying `usage`,
    /// `ttft_ms` and `duration_ms`. The result line is the capture trimmed to
    /// the fields the session reads — `modelUsage`, `subagent_stats` and the
    /// rest are dropped, the key names are verbatim.
    static let capturedThinkingProgress = #"{"type":"system","subtype":"thinking_tokens","estimated_tokens":150,"estimated_tokens_delta":100,"session_id":"3c2e3e65-6fc5-43cb-9509-227661f44a82","uuid":"3dd12b93-b21a-4c94-a2e0-c027c92cf721"}"#
    static let capturedTimedResult = #"{"duration_api_ms":3632,"stop_reason":"end_turn","session_id":"3c2e3e65-6fc5-43cb-9509-227661f44a82","total_cost_usd":0.00253,"usage":{"input_tokens":431,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":227,"output_tokens_details":{"thinking_tokens":185},"service_tier":"standard"},"permission_denials":[],"terminal_reason":"completed","is_error":false,"num_turns":1,"subtype":"success","result":"FAKE RESULT","ttft_ms":2419,"type":"result","duration_ms":2887,"uuid":"6a1d1b2e-0000-4000-8000-000000000001"}"#
```

Add a `FakeMode` case:

```swift
        /// Emit the thinking-progress event and answer with the TIMED result
        /// line — the 2026-09-09 capture — so the session's `RunTiming` is
        /// read off a real shape.
        case timed
```

with, in the script's loop (after the `noisy` block):

```bash
          if [ "$MODE" = "timed" ]; then
            printf '%s\\n' '\(Self.capturedThinkingProgress)'
            printf '%s\\n' '\(Self.capturedTimedResult)'
            continue
          fi
```

Tests:

```swift
    // MARK: - The run knows how long it took (spec 2026-09-09 §5)

    func test_theThinkingProgressEventIsClassifiedAsProgress() {
        XCTAssertEqual(
            ClaudeCLISession.classify(line: Self.capturedThinkingProgress),
            .thinkingProgress(estimatedTokens: 150))
    }

    func test_theResultLineYieldsItsFacts() throws {
        let facts = try XCTUnwrap(ClaudeCLISession.resultFacts(fromLine: Self.capturedTimedResult))
        XCTAssertEqual(facts.apiDuration, 3.632, accuracy: 0.0005)
        XCTAssertEqual(facts.turns, 1)
        XCTAssertEqual(facts.outputTokens, 227)
        XCTAssertEqual(facts.thinkingTokens, 185)
        XCTAssertEqual(facts.costUSD ?? 0, 0.00253, accuracy: 0.000001)
    }

    func test_aTurnRecordsItsTimingAndReportsProgress() async throws {
        let cli = try makeFakeCLI(mode: .timed)
        let session = makeSession(cli: cli, model: "haiku")
        let progress = Box<[RunProgress]>([])
        session.setProgressHandler { progress.value.append($0) }

        XCTAssertNil(session.lastTurnTiming, "nothing has run")
        let event = await session.send(message: "hello", systemPreamble: nil)

        XCTAssertEqual(event, .resultText("FAKE RESULT"))
        let timing = try XCTUnwrap(session.lastTurnTiming)
        XCTAssertGreaterThan(timing.elapsed, 0)
        XCTAssertNotNil(timing.firstLineAfter)
        XCTAssertEqual(timing.thinkingTokens, 185)
        XCTAssertEqual(timing.outputTokens, 227)
        XCTAssertEqual(timing.turns, 1)
        XCTAssertEqual(timing.model, "haiku")
        XCTAssertEqual(timing.effort, "high")
        XCTAssertEqual(progress.value.map(\.thinkingTokens), [150],
            "the CLI's own estimate reaches the handler as it arrives")
        session.shutdown()
    }

    /// A stall carries the last estimate the session saw, so the sentence can
    /// say how far the read had got.
    func test_aStallCarriesTheThinkingEstimate() async throws {
        let cli = try makeFakeCLI(mode: .chatterWhileFlagged)
        try Data().write(to: slowFlagURL)   // never lifted
        let session = makeSession(cli: cli, silenceTimeout: 5, runTimeout: 0.6)
        let event = await session.send(message: "chatty", systemPreamble: nil)
        guard case .failed(.timedOut(let stall)) = event else {
            return XCTFail("expected a stall, got \(event)")
        }
        XCTAssertEqual(stall.thinkingTokens, 50, "the chatter's estimate is 50 on every line")
        session.shutdown()
    }
```

- [ ] **Step 2: Run to see them fail** — `-only-testing:MaughamTests/ClaudeCLISessionTests`; expected compile errors on `RunProgress`, `.thinkingProgress`, `resultFacts`, `lastTurnTiming`.

- [ ] **Step 3: Create `Maugham/Compiler/RunTiming.swift`**

```swift
import Foundation

/// **How long one turn took, and what it cost** (spec 2026-09-09 §5).
///
/// Two clocks: `elapsed` and `firstLineAfter` are Maugham's own (send → result,
/// send → first stdout line); everything else is read off the CLI's `result`
/// event. Stored on `CompilerRun.timing` so a run can be seen for what it
/// cost, and read by the evals milestone beside the effort it was asked for.
struct RunTiming: Codable, Equatable, Sendable {
    var elapsed: TimeInterval
    var firstLineAfter: TimeInterval?
    var apiDuration: TimeInterval?
    var turns: Int?
    var outputTokens: Int?
    var thinkingTokens: Int?
    var costUSD: Double?
    var model: String
    var effort: String

    init(elapsed: TimeInterval, firstLineAfter: TimeInterval? = nil,
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
struct RunProgress: Equatable, Sendable {
    var thinkingTokens: Int
    var at: Date
}
```

Run `./gen.sh` after creating the file.

- [ ] **Step 4: Extend the `CompilerRunner` seam with defaults**

In `CompilerRunner.swift`, add to the protocol after `setPartialHandler`:

```swift
    /// The timing of the LAST turn that resolved with a result — `nil` before
    /// any turn, after a failure, and for a runner that measures nothing.
    @MainActor var lastTurnTiming: RunTiming? { get }
    /// Where a live turn's progress goes, or `nil` to stop listening. A
    /// preview, like the partial text.
    @MainActor func setProgressHandler(_ handler: (@MainActor (RunProgress) -> Void)?)
```

and to the `public extension CompilerRunner`:

```swift
    @MainActor var lastTurnTiming: RunTiming? { nil }
    @MainActor func setProgressHandler(_ handler: (@MainActor (RunProgress) -> Void)?) {}
```

(`RunTiming`/`RunProgress` are internal; if the compiler objects to an internal type in a public protocol requirement, make both `public struct` with `public` members and a `public init` — keep everything else the same.)

- [ ] **Step 5: Implement in `ClaudeCLISession`**

State (beside `partialHandler`):

```swift
    private var progressHandler: (@MainActor (RunProgress) -> Void)?
    /// The CLI's last thinking-token estimate for the turn in flight.
    private var latestThinkingEstimate: Int?
    /// When the first stdout line of the turn in flight arrived.
    private var firstLineAt: Date?
    private(set) var lastTurnTiming: RunTiming?

    func setProgressHandler(_ handler: (@MainActor (RunProgress) -> Void)?) {
        progressHandler = handler
    }
```

In `send`, beside `turnStartedAt = Date()`: `latestThinkingEstimate = nil; firstLineAt = nil; lastTurnTiming = nil`.

`StreamLine` gains `case thinkingProgress(estimatedTokens: Int)`. In `classify`, before the `guard type == "result"`:

```swift
        if type == "system", dict["subtype"] as? String == "thinking_tokens",
           let tokens = dict["estimated_tokens"] as? Int {
            return .thinkingProgress(estimatedTokens: tokens)
        }
```

Add the facts parser:

```swift
    /// What the `result` event says about the turn (captured 2026-09-09;
    /// every field optional because an older CLI omits some).
    struct ResultFacts: Equatable {
        var apiDuration: TimeInterval?
        var turns: Int?
        var outputTokens: Int?
        var thinkingTokens: Int?
        var costUSD: Double?
    }

    static func resultFacts(fromLine line: String) -> ResultFacts? {
        guard let data = line.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              dict["type"] as? String == "result"
        else { return nil }
        let usage = dict["usage"] as? [String: Any]
        let details = usage?["output_tokens_details"] as? [String: Any]
        return ResultFacts(
            apiDuration: (dict["duration_api_ms"] as? Double).map { $0 / 1000 },
            turns: dict["num_turns"] as? Int,
            outputTokens: usage?["output_tokens"] as? Int,
            thinkingTokens: details?["thinking_tokens"] as? Int,
            costUSD: dict["total_cost_usd"] as? Double)
    }
```

In `receive(line:generation:)`, after `lastActivityAt = Date()`: `if firstLineAt == nil { firstLineAt = Date() }`. Add the arm and extend the result arm:

```swift
        case .thinkingProgress(let tokens):
            latestThinkingEstimate = tokens
            progressHandler?(RunProgress(thinkingTokens: tokens, at: Date()))
        case .result(let text):
            let facts = Self.resultFacts(fromLine: line)
            let now = Date()
            lastTurnTiming = RunTiming(
                elapsed: now.timeIntervalSince(turnStartedAt),
                firstLineAfter: firstLineAt.map { $0.timeIntervalSince(turnStartedAt) },
                apiDuration: facts?.apiDuration, turns: facts?.turns,
                outputTokens: facts?.outputTokens,
                thinkingTokens: facts?.thinkingTokens ?? latestThinkingEstimate,
                costUSD: facts?.costUSD, model: model, effort: effort.rawValue)
            resolve(.resultText(text), token: runToken)
```

In `stall(token:cause:after:)` pass `thinkingTokens: latestThinkingEstimate`.

- [ ] **Step 6: Run the suite; fast loop; commit**

`-only-testing:MaughamTests/ClaudeCLISessionTests` PASS; `./scripts/test.sh` green.

```bash
git add Maugham/Compiler/RunTiming.swift Maugham/Compiler/CompilerRunner.swift Maugham/Compiler/ClaudeCLISession.swift MaughamTests/ClaudeCLISessionTests.swift
git commit -m "feat(compiler): RunTiming and RunProgress — the session reads its turn off the result event and the thinking-progress stream

<attribution block>"
```

---

### Task 5: The record carries the timing; the orchestrator exposes the live run

**Files:**
- Modify: `Maugham/Compiler/Diagnostic.swift` (`CompilerRun`), `Maugham/Compiler/CompilerOrchestrator.swift`
- Test: `MaughamTests/CompilerRunCommandTests.swift`

**Interfaces:**
- Consumes: `RunTiming`, `RunProgress`, `CompilerRunner.lastTurnTiming`/`setProgressHandler` (Task 4).
- Produces: `CompilerRun.timing: RunTiming?` (init param `timing:` default nil, decoded if present); `CompilerOrchestrator.runStartedAt: Date?` and `runProgress: RunProgress?` (read-only, set while a run is in flight).

- [ ] **Step 1: Write the failing tests**

In `CompilerRunCommandTests`' `SpyRunner`, add:

```swift
        var lastTurnTiming: RunTiming?
        private(set) var progressHandler: (@MainActor (RunProgress) -> Void)?
        func setProgressHandler(_ handler: (@MainActor (RunProgress) -> Void)?) {
            progressHandler = handler
        }
        func progress(_ p: RunProgress) { progressHandler?(p) }
```

Tests (use the file's existing harness — the way `test_theStageIsStampedBesideTheAskInTheOneRecordSpelling` builds an orchestrator, runs ⌘R with a held `nextEvent = nil`, and reads the sidecar's standing run):

```swift
    /// **The run record carries what the turn cost** (spec 2026-09-09 §5): the
    /// runner's timing is copied onto the record in `finish`, so the pane can
    /// say "read in 4m 12s" over a run that is no longer live.
    func test_theRecordCarriesTheRunnersTiming() async throws {
        let (orchestrator, runner, diagnostics, docId) = try await makeHeldRun()
        runner.lastTurnTiming = RunTiming(
            elapsed: 252, firstLineAfter: 4.1, apiDuration: 250, turns: 6,
            outputTokens: 14_000, thinkingTokens: 12_504, costUSD: 0.31,
            model: "opus", effort: "high")
        runner.release(.resultText(Self.fourEmptySections))
        await orchestrator.settle()   // the harness's existing wait for `.idle`

        let run = try XCTUnwrap(diagnostics.lastCheck(docId: docId))
        XCTAssertEqual(run.timing?.elapsed, 252)
        XCTAssertEqual(run.timing?.thinkingTokens, 12_504)
        XCTAssertEqual(run.timing?.effort, "high")
    }

    /// While a run is live the orchestrator says when it started and what the
    /// CLI has thought so far; both clear when it ends.
    func test_theLiveRunExposesItsStartAndProgress() async throws {
        let (orchestrator, runner, _, _) = try await makeHeldRun()
        XCTAssertNotNil(orchestrator.runStartedAt)
        XCTAssertNil(orchestrator.runProgress)
        runner.progress(RunProgress(thinkingTokens: 12_000, at: Date()))
        XCTAssertEqual(orchestrator.runProgress?.thinkingTokens, 12_000)

        runner.release(.resultText(Self.fourEmptySections))
        await orchestrator.settle()
        XCTAssertNil(orchestrator.runStartedAt)
        XCTAssertNil(orchestrator.runProgress)
    }

    /// A legacy sidecar has no timing; the record decodes without it.
    func test_aRecordWithoutTimingStillDecodes() throws {
        let json = """
        {"id":"r1","at":"2026-09-09T09:00:00Z","model":"sonnet","deltaSummary":"3 new, 0 revised ¶"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let run = try decoder.decode(CompilerRun.self, from: Data(json.utf8))
        XCTAssertNil(run.timing)
    }
```

`makeHeldRun()` / `settle()`: if the file has no such helpers, write them in this task from the file's existing pattern — an orchestrator over a temp project (`makeProjectRoot()`), a `SpyRunner` with `nextEvent = nil`, ⌘R via `orchestrator.runRequested(...)` exactly as the neighbouring tests call it, and a poll until `orchestrator.runState == .idle` bounded at 5 s (`pumpUntil` is the suite's helper; use whatever the neighbouring held-run test uses).

- [ ] **Step 2: Run to see them fail** — compile errors on `timing`, `runStartedAt`, `runProgress`.

- [ ] **Step 3: Implement**

`Diagnostic.swift`: add to `CompilerRun`:

```swift
    /// **How long the run took and what it cost** (spec 2026-09-09 §5).
    /// `nil` on every record written before the milestone and on a runner
    /// that measures nothing (the suites' spies).
    var timing: RunTiming?
```

Init: add `timing: RunTiming? = nil` after `letter:` and `self.timing = timing`; decoder: `timing = try c.decodeIfPresent(RunTiming.self, forKey: .timing)`. (If `CodingKeys` is explicit, add `.timing`.)

`CompilerOrchestrator.swift`:

```swift
    /// When the run in flight was sent, and what the CLI has thought so far —
    /// the two facts the panes draw while "Checking…" is on screen (spec
    /// 2026-09-09 §5). Both `nil` between runs.
    private(set) var runStartedAt: Date?
    private(set) var runProgress: RunProgress?
```

In `beginRun`, right after `runState = .running(...)`: `runStartedAt = Date(); runProgress = nil`. Where `runner.setPartialHandler { ... }` is installed, also:

```swift
            runner.setProgressHandler { [weak self] progress in
                guard let self, self.runGeneration == generation else { return }
                self.runProgress = progress
            }
```

`record(...)` gains `timing: RunTiming?` and passes `timing: timing` into `CompilerRun(...)`. In `finish`'s result arm, the `Self.record(` call gets `timing: runner?.lastTurnTiming,`. In `finish`'s `.failed` arm, and at the end of the result arm beside `runState = .idle`, and in `cancel()` beside `runState = .idle`: `runStartedAt = nil; runProgress = nil`.

- [ ] **Step 4: Run CompilerRunCommandTests and DiagnosticsPaneTests; fast loop; commit**

```bash
git add Maugham/Compiler/Diagnostic.swift Maugham/Compiler/CompilerOrchestrator.swift MaughamTests/CompilerRunCommandTests.swift
git commit -m "feat(compiler): the run record carries its timing and the orchestrator exposes the live run's start and progress

<attribution block>"
```

---

### Task 6: The two homes draw it — elapsed and progress while running, read-in afterwards

**Files:**
- Modify: `Maugham/Compiler/RoundNarrative.swift` (`checkingCopy`, new `readInSuffix`, `timingDetail`)
- Modify: `Maugham/Views/DiagnosticsPane.swift` (`HeaderState.running`, `headerCopy`, `headerState`, the header `Text`)
- Modify: `Maugham/Views/Review/ReviewRoundCockpit.swift` (two `var`s, `statusLine`, `reportLine`), `Maugham/Views/AnnotationsPane.swift:711` (pass them)
- Test: `MaughamTests/RoundNarrativeTests.swift`, `MaughamTests/DiagnosticsPaneTests.swift`, `MaughamTests/ReviewRoundCockpitTests.swift`

**Interfaces:**
- Produces: `RoundNarrative.checkingCopy(_:kind:elapsed:thinkingTokens:)`, `RoundNarrative.readInSuffix(_ timing: RunTiming?) -> String`, `RoundNarrative.timingDetail(_ timing: RunTiming) -> String`; `DiagnosticsPane.HeaderState.running(checking:since:progress:)`; `DiagnosticsPane.headerCopy(for:wetInk:now:)`; `ReviewRoundCockpit.runSince`, `.runProgress`.

- [ ] **Step 1: Write the failing narration tests**

```swift
    // MARK: - The live wait and the read-in line (spec 2026-09-09 §5)

    func test_theCheckingLineCarriesElapsedAndThinkingProgress() {
        XCTAssertEqual(
            RoundNarrative.checkingCopy(counts(new: 457, revised: 0), kind: .check,
                                        elapsed: 130, thinkingTokens: 12_400),
            "Checking 457 new paragraphs\u{2026} 2m 10s \u{00b7} thinking (12k tokens)")
        XCTAssertEqual(
            RoundNarrative.checkingCopy(counts(new: 3, revised: 0), kind: .check, elapsed: 4),
            "Checking 3 new paragraphs\u{2026} 4s")
        XCTAssertEqual(
            RoundNarrative.checkingCopy(counts(new: 40, revised: 2), kind: .round),
            "Reading the whole piece\u{2026}",
            "no clock, no suffix — the sentence every caller had")
    }

    func test_theReadInSuffixAndItsDetail() {
        let timing = RunTiming(elapsed: 252, firstLineAfter: 4.1, apiDuration: 250, turns: 6,
                               outputTokens: 14_000, thinkingTokens: 12_504, costUSD: 0.31,
                               model: "opus", effort: "high")
        XCTAssertEqual(RoundNarrative.readInSuffix(timing), " \u{00b7} read in 4m 12s")
        XCTAssertEqual(RoundNarrative.readInSuffix(nil), "")
        XCTAssertEqual(
            RoundNarrative.timingDetail(timing),
            "First word after 4s \u{00b7} 6 turns \u{00b7} 12,504 tokens of thinking \u{00b7} opus at high \u{00b7} $0.31")
    }

    func test_theClockPhraseSpellsSecondsMinutesAndHours() {
        XCTAssertEqual(RoundNarrative.clockPhrase(4), "4s")
        XCTAssertEqual(RoundNarrative.clockPhrase(130), "2m 10s")
        XCTAssertEqual(RoundNarrative.clockPhrase(3_725), "1h 2m")
    }
```

- [ ] **Step 2: Write the failing pane and cockpit tests**

`DiagnosticsPaneTests`: update `test_headerState_running` to the new shape and add one:

```swift
    func test_headerState_running() {
        let since = Date(timeIntervalSince1970: 1_000)
        let state = DiagnosticsPane.headerState(
            runState: .running(docId: "d1", checking: counts(new: 14, revised: 0)),
            lastRun: nil, noteCount: 0, docId: "d1",
            runStartedAt: since, runProgress: RunProgress(thinkingTokens: 500, at: since))
        XCTAssertEqual(state, .running(checking: counts(new: 14, revised: 0), since: since,
                                       progress: RunProgress(thinkingTokens: 500, at: since)))
    }

    /// The running header ticks: the same state read a minute later says so.
    func test_theRunningHeaderSaysHowLongAndHowFar() {
        let since = Date(timeIntervalSince1970: 1_000)
        let state = DiagnosticsPane.HeaderState.running(
            checking: counts(new: 457, revised: 0), since: since,
            progress: RunProgress(thinkingTokens: 12_400, at: since))
        XCTAssertEqual(
            DiagnosticsPane.headerCopy(for: state, now: since.addingTimeInterval(130)),
            "Checking 457 new paragraphs\u{2026} 2m 10s \u{00b7} thinking (12k tokens)")
    }

    /// A finished run says how long it took; a legacy run without timing says
    /// exactly what it did before.
    func test_theIdleHeaderCarriesReadIn() throws {
        var run = makeRun()   // the file's existing fixture builder
        XCTAssertFalse(DiagnosticsPane.headerCopy(for: .idle(lastRun: run)).contains("read in"))
        run.timing = RunTiming(elapsed: 252, model: "opus", effort: "high")
        XCTAssertTrue(DiagnosticsPane.headerCopy(for: .idle(lastRun: run))
            .hasSuffix(" \u{00b7} read in 4m 12s"))
    }
```

(Every other `.running(checking:)` construction in the file — `test_headerState_runningAnotherDocFallsThroughToLastRun` and the requirement-5 tests — becomes `.running(checking: …, since: nil, progress: nil)`; `headerState(...)` calls gain `runStartedAt: nil, runProgress: nil` where they do not care.)

`ReviewRoundCockpitTests`: add

```swift
    /// The cockpit's running line ticks like the pane's (spec 2026-09-09 §5).
    func test_theRunningStatusLineCarriesElapsedAndProgress() {
        let since = Date(timeIntervalSince1970: 1_000)
        let line = ReviewRoundCockpit.statusLine(
            phase: .running(counts(new: 40, revised: 2)), reportLine: nil,
            runSince: since, runProgress: RunProgress(thinkingTokens: 9_000, at: since),
            now: since.addingTimeInterval(65))
        XCTAssertEqual(line, "Reading the whole piece\u{2026} 1m 5s \u{00b7} thinking (9k tokens)")
    }
```

(`statusLine` becomes a `static func` with those parameters so it is assertable windowlessly; the instance property calls it.)

- [ ] **Step 3: Run to see them fail** — compile errors.

- [ ] **Step 4: Implement `RoundNarrative`**

Replace `checkingCopy`:

```swift
    static func checkingCopy(
        _ counts: CompilerOrchestrator.DeltaCounts, kind: RunKind = .check,
        elapsed: TimeInterval? = nil, thinkingTokens: Int? = nil
    ) -> String {
        let base: String
        switch kind {
        case .round:
            base = "Reading the whole piece\u{2026}"
        case .check:
            if let phrase = paragraphPhrase(counts) {
                base = "Checking \(phrase)\u{2026}"
            } else {
                base = "Checking\u{2026}"
            }
        }
        // **The wait made legible** (spec 2026-09-09 §5): how long, and what
        // the model has done so far, from the CLI's own estimate. No clock
        // means the sentence every caller had.
        guard let elapsed else { return base }
        var line = base + " " + clockPhrase(elapsed)
        if let thinkingTokens, thinkingTokens > 0 {
            line += " \u{00b7} thinking (\(roughThousands(thinkingTokens)) tokens)"
        }
        return line
    }

    /// `4s`, `2m 10s`, `1h 2m` — the strip's clock.
    static func clockPhrase(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// `12k`, never `12,400`, while the number is still moving.
    static func roughThousands(_ n: Int) -> String {
        n >= 1_000 ? "\(n / 1_000)k" : "\(n)"
    }

    /// The suffix the "Last checked" line and the cockpit's report line carry
    /// over a run that recorded its timing; empty otherwise, so a legacy run
    /// reads exactly as it did.
    static func readInSuffix(_ timing: RunTiming?) -> String {
        guard let timing else { return "" }
        return " \u{00b7} read in \(clockPhrase(timing.elapsed))"
    }

    /// The tooltip behind that suffix.
    static func timingDetail(_ timing: RunTiming) -> String {
        var parts: [String] = []
        if let first = timing.firstLineAfter { parts.append("First word after \(clockPhrase(first))") }
        if let turns = timing.turns { parts.append(turns == 1 ? "1 turn" : "\(turns) turns") }
        if let thinking = timing.thinkingTokens { parts.append("\(thousands(thinking)) tokens of thinking") }
        parts.append("\(timing.model) at \(timing.effort)")
        if let cost = timing.costUSD { parts.append(String(format: "$%.2f", cost)) }
        return parts.joined(separator: " \u{00b7} ")
    }
```

- [ ] **Step 5: Implement the pane**

`HeaderState.running` becomes `case running(checking: CompilerOrchestrator.DeltaCounts, since: Date?, progress: RunProgress?)`. `headerState(runState:lastRun:noteCount:docId:)` gains `runStartedAt: Date? = nil, runProgress: RunProgress? = nil` and returns `.running(checking: checking, since: runStartedAt, progress: runProgress)`. `headerCopy(for:wetInk:)` gains `now: Date = Date()`; its arms:

```swift
        case .idle(let run):
            return "Last checked \(relative(run.at)) \u{00b7} \(run.deltaSummary)"
                + RoundNarrative.readInSuffix(run.timing)
        case .running(let checking, let since, let progress):
            return RoundNarrative.checkingCopy(
                checking, kind: .check,
                elapsed: since.map { now.timeIntervalSince($0) },
                thinkingTokens: progress?.thinkingTokens)
```

The call site that derives `state` passes `runStartedAt: orchestrator.runStartedAt, runProgress: orchestrator.runProgress`. Around line 608, replace `Text(headerLine)` with:

```swift
                if case .running = state {
                    // One text at 1 Hz, only while a run is live — the clock
                    // is the whole reason for the timeline (tripwire 30 is
                    // about scene-proportional work; this is one line).
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.headerCopy(for: state, wetInk: wetInk, now: context.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(headerLine)
                        .font(.caption)
                        .foregroundStyle(isFailureState ? Color.red : .secondary)
                        .help(timingHelp)
                }
```

with `private var timingHelp: String { if case .idle(let run) = state, let t = run.timing { return RoundNarrative.timingDetail(t) }; if case .clean(let run) = state, let t = run.timing { return RoundNarrative.timingDetail(t) }; return "" }`. (`.help("")` shows nothing.)

- [ ] **Step 6: Implement the cockpit**

Add to `ReviewRoundCockpit`: `var runSince: Date? = nil` and `var runProgress: RunProgress? = nil` (after `let reportLine`). Make the decision static:

```swift
    static func statusLine(
        phase: RunPhase, reportLine: String?,
        runSince: Date?, runProgress: RunProgress?, now: Date = Date()
    ) -> String? {
        switch phase {
        case .running(let counts):
            return RoundNarrative.checkingCopy(
                counts, kind: .round,
                elapsed: runSince.map { now.timeIntervalSince($0) },
                thinkingTokens: runProgress?.thinkingTokens)
        case .failed(let failure, _): return RoundNarrative.failureCopy(failure)
        case .idle: return reportLine
        }
    }
```

and the instance property delegates: `private var statusLine: String? { Self.statusLine(phase: phase, reportLine: reportLine, runSince: runSince, runProgress: runProgress) }`. Where the status line is drawn, wrap the `.running` case in the same `TimelineView(.periodic(from: .now, by: 1))` pattern as the pane. `reportLine(history:run:annotations:)` appends `RoundNarrative.readInSuffix(run?.timing)` to a non-nil result. In `AnnotationsPane.swift:711`, pass `runSince: orchestrator.runStartedAt, runProgress: orchestrator.runProgress` (the orchestrator is already in scope there — it supplies `phase`).

- [ ] **Step 7: Run the three suites plus the fast loop; commit**

```bash
git add -A Maugham MaughamTests
git commit -m "feat(views): the wait is legible — elapsed and thinking progress while a run is live, read-in and its detail afterwards

<attribution block>"
```

---

### Task 7: The briefing is complete — inline pinned notes inside the hashed unit

**Files:**
- Modify: `Maugham/Compiler/CompilerEnvironment+Project.swift:446-462, 506-575`
- Modify: `Maugham/Compiler/CompilerPrompt.swift` (`briefingHashInput`, `runMessageV2`, `listingSections`)
- Test: `MaughamTests/CompilerPromptTests.swift`

**Interfaces:**
- Produces: `enum PinnedBody { case text(String), link(url: String), unreadable }`; `CompilerOrchestrator.Environment`-side `pinnedBody(for:store:projectRoot:)`; `pinnedListingLines(_ shelf:, body: (PinnedReference) -> PinnedBody?)`; `inlineBodyCap = 4_000`, `inlineBudget = 40_000`; `briefingHashInput(essay:world:bibleFacts:lessons:pinnedListing:)`.

- [ ] **Step 1: Write the failing tests**

In `CompilerPromptTests` (which already tests `pinnedListingLines` — put these beside those tests):

```swift
    // MARK: - Small pinned notes travel inline (spec 2026-09-09 §4)

    private func shelf(_ pins: [PinnedReference]) -> PinnedShelf {
        PinnedShelf(sections: [PinnedSection(title: nil, references: pins)])
    }
    private func researchPin(_ id: String, _ title: String) -> PinnedReference {
        PinnedReference(id: id, kind: .research(itemId: id), title: title)
    }

    func test_aSmallNoteIsInlinedUnderItsTitle() {
        let lines = CompilerEnvironmentProject.pinnedListingLines(
            shelf([researchPin("res-1", "Montage - Grace")]),
            body: { _ in .text("Kelly showing off ring\n\nGrace & Kelly dancing") })
        XCTAssertEqual(lines, [
            "Montage - Grace (res-1):\n  Kelly showing off ring\n  \n  Grace & Kelly dancing"
        ])
    }

    func test_aNoteOverTheCapSaysHowToFetchItAndHowLong() {
        let long = String(repeating: "word ", count: 1_200)   // 6,000 chars
        let lines = CompilerEnvironmentProject.pinnedListingLines(
            shelf([researchPin("res-2", "Dreams Notes 4")]), body: { _ in .text(long) })
        XCTAssertEqual(lines, ["Dreams Notes 4 (res-2) \u{2014} 1,200 words, fetch with read_document"])
    }

    func test_aWebLinkIsNeverAdvertisedForReadDocument() {
        let lines = CompilerEnvironmentProject.pinnedListingLines(
            shelf([researchPin("res-3", "Good Luck Babe Soundtrack")]),
            body: { _ in .link(url: "https://music.apple.com/x") })
        XCTAssertEqual(lines, ["Good Luck Babe Soundtrack (res-3) \u{2014} web link, not readable: https://music.apple.com/x"])
    }

    func test_anUnreadableAssetIsTitleOnly() {
        let lines = CompilerEnvironmentProject.pinnedListingLines(
            shelf([researchPin("res-4", "Cover scan")]), body: { _ in .unreadable })
        XCTAssertEqual(lines, ["Cover scan (res-4) \u{2014} title only"])
    }

    func test_aPinWithNoBodyKeepsTheFetchLine() {
        let lines = CompilerEnvironmentProject.pinnedListingLines(
            shelf([researchPin("res-5", "Unknown")]), body: { _ in nil })
        XCTAssertEqual(lines, ["Unknown (res-5) \u{2014} read_document"])
    }

    func test_theInlineBudgetIsSpentInShelfOrder() {
        let body = String(repeating: "x", count: 3_900)   // under the per-note cap
        let pins = (1...12).map { researchPin("res-\($0)", "Note \($0)") }
        let lines = CompilerEnvironmentProject.pinnedListingLines(
            shelf(pins), body: { _ in .text(body) })
        // 10 × 3,900 = 39,000 fits; the 11th would pass 40,000.
        XCTAssertEqual(lines.filter { $0.contains(":\n") }.count, 10)
        XCTAssertTrue(lines[10].hasSuffix("fetch with read_document"))
        XCTAssertTrue(lines[11].hasSuffix("fetch with read_document"))
    }

    // MARK: - The listing is part of the hashed unit

    func test_thePinnedListingFoldsIntoTheBriefingHash() {
        let (first, firstHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: "Essay.", bibleFacts: [],
            paletteListing: [], pinnedListing: ["Note (res-1):\n  body"],
            previousBriefingHash: nil)
        let (_, sameHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: "Essay.", bibleFacts: [],
            paletteListing: [], pinnedListing: ["Note (res-1):\n  body"],
            previousBriefingHash: firstHash)
        let (_, movedHash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: "Essay.", bibleFacts: [],
            paletteListing: [], pinnedListing: ["Note (res-1):\n  a different body"],
            previousBriefingHash: firstHash)
        XCTAssertTrue(first.contains("Pinned references"))
        XCTAssertEqual(sameHash, firstHash)
        XCTAssertNotEqual(movedHash, firstHash)
    }

    func test_anUnchangedShelfIsNotResent() {
        let (_, hash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: "Essay.", bibleFacts: [],
            paletteListing: [], pinnedListing: ["Note (res-1):\n  body"],
            previousBriefingHash: nil)
        let (second, _) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: "Essay.", bibleFacts: [],
            paletteListing: [], pinnedListing: ["Note (res-1):\n  body"],
            previousBriefingHash: hash)
        XCTAssertFalse(second.contains("Note (res-1)"), "an unchanged shelf is elided with the rest of the unit")
        XCTAssertTrue(second.contains("Declared world, bible and pinned references: unchanged since last run."))
    }

    func test_pinsAloneAreSomethingDeclared() {
        let (_, hash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: nil, bibleFacts: [],
            paletteListing: [], pinnedListing: ["Note (res-1):\n  body"],
            previousBriefingHash: nil)
        XCTAssertNotNil(hash)
    }
```

(`CompilerEnvironmentProject` is a placeholder for whatever type hosts `pinnedListingLines` today — read the `static func pinnedListingLines` declaration's enclosing type in `CompilerEnvironment+Project.swift` and use that name; the existing tests in this file already call it.)

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement the bodies and the lines**

In `CompilerEnvironment+Project.swift`, beside `pinnedListingLine`:

```swift
    /// What a pin's full text is, for the listing (spec 2026-09-09 §4).
    enum PinnedBody: Equatable {
        case text(String)
        case link(url: String)
        /// An image, PDF or audio asset — nothing a briefing can carry.
        case unreadable
    }

    /// A note under this many characters travels in the briefing whole.
    static let inlineBodyCap = 4_000
    /// A briefing inlines at most this many characters of notes, in shelf order.
    static let inlineBudget = 40_000

    /// The body behind a `.research` pin, read off the manifest and the
    /// project root the way `read_document` reads it. `nil` for every other
    /// pin kind and for an item the manifest no longer holds.
    static func pinnedBody(for pin: PinnedReference, store: ProjectStore, projectRoot: URL) -> PinnedBody? {
        guard case .research(let itemId) = pin.kind,
              let item = TreeWalk.find(id: itemId, in: store.manifest.research),
              item.type == .asset
        else { return nil }
        switch item.kind {
        case .document:
            guard let path = item.path,
                  let abs = try? SafeRelativePath.resolve(path, under: projectRoot),
                  let text = try? String(contentsOf: abs, encoding: .utf8) // adr-0018-ok: research-note body for the briefing, not manuscript
            else { return nil }
            return .text(text)
        case .link:
            return .link(url: item.url ?? "")
        case .image, .pdf, .audio:
            return .unreadable
        case .none:
            return nil
        }
    }
```

Change `pinnedListingLines` to take `body: (PinnedReference) -> PinnedBody? = { _ in nil }` and, inside the loop, replace `taken.map(pinnedListingLine)` with a pass that carries a running `spent` counter:

```swift
            for pin in taken {
                out.append(pinnedListingLine(pin, body: body(pin), spent: &spent))
            }
```

with

```swift
    private static func pinnedListingLine(
        _ pin: PinnedReference, body: PinnedBody?, spent: inout Int
    ) -> String {
        let base = "\(pin.title) (\(pin.id))"
        switch (pin.kind, body) {
        case (.research, .text(let text)):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count <= inlineBodyCap, spent + trimmed.count <= inlineBudget {
                spent += trimmed.count
                let indented = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "  \($0)" }.joined(separator: "\n")
                return "\(base):\n\(indented)"
            }
            let words = trimmed.split { $0.isWhitespace || $0.isNewline }.count
            return "\(base) \u{2014} \(RoundNarrative.thousands(words)) words, fetch with read_document"
        case (.research, .link(let url)):
            return "\(base) \u{2014} web link, not readable: \(url)"
        case (.research, .unreadable):
            return "\(base) \u{2014} title only"
        case (.research, nil): return "\(base) \u{2014} read_document"
        case (.palette, _): return "\(base) \u{2014} read_palette_card"
        case (.scrap, _): return "\(base) \u{2014} list_canvas"
        case (.photo, _): return "\(base) \u{2014} no read tool yet, title only"
        }
    }
```

(`var spent = 0` before the section loop.) The production closure at `:446` passes `body: { pin in Self.pinnedBody(for: pin, store: store, projectRoot: projectURL) }`.

- [ ] **Step 4: Fold the listing into the hash**

`CompilerPrompt.briefingHashInput` gains `pinnedListing: [String]`; the guard adds `|| !pinnedListing.isEmpty`; `parts.append("pinned:" + pinnedListing.joined(separator: "\u{1F}"))` last. In `runMessageV2`: pass `pinnedListing: pinnedListing`; the elided line becomes `"Declared world, bible and pinned references: unchanged since last run."`; move the pinned half of `listingSections` INSIDE the `else if hash != nil` block (after the ledger), leaving the palette listing where it is. Split `listingSections` into `pinnedSection(_:)` and `paletteSection(_:)`; the pinned header becomes:

```swift
"Pinned references \u{2014} a short note is given in full under its title; a long one says how to fetch it:\n"
```

Update every existing `briefingHashInput(` call and every test that asserts the old "Declared world and bible: unchanged" line (grep `unchanged since last run` in `MaughamTests`).

- [ ] **Step 5: Run CompilerPromptTests, CompilerRunCommandTests and TripwireGrepTests (the adr-0018 guard); fast loop; commit**

```bash
git add -A Maugham MaughamTests
git commit -m "feat(compiler): small pinned notes travel inline, inside the hashed unit; a web link is never advertised as readable

<attribution block>"
```

---

### Task 8: The briefing states its absences and says it is the whole read

**Files:**
- Modify: `Maugham/Compiler/CompilerPrompt.swift` (`runMessageV2`, `readerSection`, new constants)
- Test: `MaughamTests/CompilerPromptTests.swift`

**Interfaces:**
- Produces: `CompilerPrompt.noIntentDeclared`, `CompilerPrompt.firstReaderNotBriefed`, `CompilerPrompt.wholeReadInstruction` (static `String`s).

- [ ] **Step 1: Write the failing tests**

```swift
    // MARK: - The briefing states its absences (spec 2026-09-09 §4.3)

    func test_aMissingEssayIsSaidRatherThanLeftToBeFetched() {
        let (message, _) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: nil, bibleFacts: [],
            paletteListing: [], pinnedListing: [], previousBriefingHash: nil)
        XCTAssertTrue(message.contains(CompilerPrompt.noIntentDeclared))
        let (withEssay, _) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: "Essay.", bibleFacts: [],
            paletteListing: [], pinnedListing: [], previousBriefingHash: nil)
        XCTAssertFalse(withEssay.contains(CompilerPrompt.noIntentDeclared))
    }

    func test_theAbsenceIsNotRepeatedWhenTheUnitIsElided() {
        let (_, hash) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: nil, bibleFacts: [BibleFact(subject: "Kelly", fact: "is 31")],
            paletteListing: [], pinnedListing: [], previousBriefingHash: nil)
        let (second, _) = CompilerPrompt.runMessageV2(
            delta: makeDelta(), world: nil, essay: nil, bibleFacts: [BibleFact(subject: "Kelly", fact: "is 31")],
            paletteListing: [], pinnedListing: [], previousBriefingHash: hash)
        XCTAssertFalse(second.contains(CompilerPrompt.noIntentDeclared),
            "the absence is part of the unchanged unit")
    }

    func test_aFirstReaderIsToldWhatSheIsNotBriefedOn() throws {
        let person = FirstReader(name: "Ruth", statement: "She reads on the train.")   // the file's existing fixture shape
        let section = try XCTUnwrap(CompilerPrompt.readerSection(.firstReader(person)))
        XCTAssertTrue(section.contains(CompilerPrompt.firstReaderNotBriefed))
    }

    func test_everyBriefingSaysItIsTheWholeRead() {
        for kind in [RunKind.check, .round] {
            let (message, _) = CompilerPrompt.runMessageV2(
                delta: makeDelta(), kind: kind, world: nil, essay: "Essay.", bibleFacts: [],
                paletteListing: [], pinnedListing: [], previousBriefingHash: nil)
            let whole = message.range(of: CompilerPrompt.wholeReadInstruction)
            let schema = message.range(of: "Respond with")
            XCTAssertNotNil(whole)
            XCTAssertNotNil(schema)
            if let whole, let schema {
                XCTAssertLessThan(whole.lowerBound, schema.lowerBound,
                    "said before the output contract, as the last thing about the read")
            }
        }
    }
```

(Check `FirstReader`'s real initialiser in `Maugham/Models/AuthorReader.swift` and use it; the existing `readerSection` tests in this file already construct one.)

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement**

Constants in `CompilerPrompt`:

```swift
    /// **Absences are stated** (spec 2026-09-09 §4.3): a model told nothing
    /// about the craft intent spent calls discovering there was none.
    static let noIntentDeclared =
        "No craft intent has been declared for this piece or its project."

    static let firstReaderNotBriefed =
        "You are deliberately not briefed on the writer's lessons ledger or "
        + "their process; neither exists for you to fetch."

    /// Said once, before the output contract, for every kind: the message is
    /// the read. `search_text` and `find_references` stay for checking a
    /// specific continuity question — the sentence forbids exploring, not
    /// checking.
    static let wholeReadInstruction =
        "Everything this read is judged against is in this message. A pinned "
        + "note listed without its text can be fetched with the tool named on "
        + "its line; a statement or ledger that is not listed here does not "
        + "exist \u{2014} do not go looking for it, and do not read the outline "
        + "or other documents. search_text and find_references are for a "
        + "specific continuity question, not for exploring."
```

In `runMessageV2`: inside the `else if hash != nil` block, where the essay is appended, add an `else { sections.append(noIntentDeclared) }` to the `if let essay, !essay.isEmpty`; and when `hash == nil` (nothing declared at all) append `noIntentDeclared` after the gate. Before `sections.append(sectionSchema(...))`: `sections.append(wholeReadInstruction)`. In `readerSection`'s `.firstReader` arm, append `firstReaderNotBriefed` as a block before `firstReaderInstruction`.

- [ ] **Step 4: Run CompilerPromptTests; fast loop; commit**

```bash
git add Maugham/Compiler/CompilerPrompt.swift MaughamTests/CompilerPromptTests.swift
git commit -m "feat(compiler): the briefing states its absences and says it is the whole read

<attribution block>"
```

---

### Task 9: Docs and the full gate

**Files:**
- Modify: `Maugham/Compiler/AREA.md` (row at line ~696; file table row for `RunTiming.swift`; the spawn-arguments prose wherever it names `--append-system-prompt`), `CLAUDE.md` (the Compiler cell's timeout sentence and the `--allowedTools`/`--tools ""` paragraph gets one clause: settings files are ignored and the preamble is the whole system prompt), `docs/guide/review-passes.md:104-106`, `docs/roadmap.md` (a ✓ entry for this milestone, under the two-loops entry), the spec's Status line.

- [ ] **Step 1: AREA.md**

Replace the `It dies quietly after ~10 min idle` row's budget sentence with: *"the per-turn budget is a SILENCE budget, `ClaudeCLISession.defaultSilenceTimeout` (180 s, reset by every line the child writes — thinking deltas and the CLI's `system/thinking_tokens` progress events included) behind a ceiling, `defaultRunTimeout` (1,200 s), one constant for every session type since 2026-09-09 (the reader's-own-session spec §2); `translationRunTimeout` is gone. A stall carries `CompilerRunFailure.Stall` — which budget, after how long, how many thinking tokens — and `RoundNarrative.stallCopy` says it."* Add a file-table row: `| \`RunTiming.swift\` | \`RunTiming\` (elapsed, first line, API duration, turns, output and thinking tokens, cost, model, effort — read off the CLI's \`result\` event plus Maugham's own clock; stored on \`CompilerRun.timing\`) and \`RunProgress\` (the live thinking-token estimate the panes draw) |`. Where the spawn arguments are described, replace every `--append-system-prompt` with `--system-prompt` and add: *"`--setting-sources ""` keeps the writer's hooks, plugins, CLAUDE.md and global effort out; `--effort` is explicit (`Effort`, `defaultEffort = .high` for every kind until the evals milestone decides otherwise); `--bare` is forbidden — it never reads OAuth."*

- [ ] **Step 2: CLAUDE.md** — in the Compiler cell, after the confinement sentence, add: *"**And the session is the reader's own (2026-09-09)**: spawned with `--setting-sources ""` (no hooks, plugins, CLAUDE.md or global effort), `--system-prompt` (the preamble IS the prompt; `--append-system-prompt` is census-forbidden in `TripwireGrepTests`), and an explicit `--effort`; the per-turn kill is a 180 s SILENCE budget behind a 20-minute ceiling, and every run records a `RunTiming`."*

- [ ] **Step 3: docs/guide/review-passes.md** — after the `"The check took too long and was stopped"` sentence, add: *"A round that Claude stopped talking to for three minutes says *Claude went quiet for 3 minutes and was stopped*; one that ran twenty minutes says the read passed its bound, with how much thinking it had done. While a round runs, the line counts the minutes and shows what Claude has thought so far; afterwards it says how long the read took, and hovering it shows the detail."*

- [ ] **Step 4: roadmap + spec status** — add a ✓ entry: *"**The reader's own session — liveness, identity, and a complete briefing (2026-09-09, branch `claude/readers-own-session-2026-09-09`)**"* with one sentence per spec section and a pointer to the evals spec for the effort table. Set the spec's Status to *built 2026-09-09; effort table deferred to the evals spec*.

- [ ] **Step 5: Full gate and commit**

Run: `./scripts/test.sh full` — must be green, no skips beyond the standing list.

```bash
git add -A docs CLAUDE.md Maugham/Compiler/AREA.md
git commit -m "docs: the reader's own session — AREA, CLAUDE.md, the guide and the roadmap

<attribution block>"
```

---

## Self-review against the spec

- §2 liveness → Task 1 (timers, `Stall`, one ceiling, translation constant deleted), Task 2 (sentences).
- §3 identity → Task 3 (`--setting-sources ""`, `--system-prompt`, `--effort high`, deriver, census).
- §4 briefing → Task 7 (inline, caps, link line, hash), Task 8 (absences, whole read).
- §5 timing → Task 4 (session), Task 5 (record, live run), Task 6 (both homes).
- §7 tests → each task's tests; the smoke is Denver's and is named in Task 9's roadmap entry.
- Type consistency: `RunTiming(elapsed:firstLineAfter:apiDuration:turns:outputTokens:thinkingTokens:costUSD:model:effort:)` is used identically in Tasks 4, 5, 6; `RunProgress(thinkingTokens:at:)` in 4, 5, 6; `Stall(cause:after:thinkingTokens:)` in 1, 2, 4; `checkingCopy(_:kind:elapsed:thinkingTokens:)` in 6 only.
