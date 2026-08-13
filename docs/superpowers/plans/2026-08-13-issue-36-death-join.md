# Issue #36 — The death join: EOF and exit both land before the verdict Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A dead CLI's status and stderr essence always reach the writer's diagnostic — `ClaudeCLISession` resolves a death only after BOTH stdout's EOF and the child's exit have been observed (bounded by a short grace), so the reap lag can no longer collapse "status 1: Invalid API key - Please run /login" into "the CLI closed its output".

**Architecture (research 2026-08-13):** `ClaudeCLISession` has NO `terminationHandler` today — `receiveEOF` polls `isRunning` at EOF-processing time and gives up on the status if the child is not yet reaped. The fix installs the second signal and joins: a `terminationHandler` (installed in `ensureProcess`, generation-captured, hopping to the main actor like every other callback) and the existing EOF path both funnel into one completion; EOF anchors the join (it is ordered behind the last byte — the read must never be truncated by exit-first resolution, per `installReader`'s own doc); a bounded grace (`deathReapGrace`, 2s, injectable like `runTimeout`) falls back to today's exact "closed its output" sentence so the change is strictly monotone. The generation guard does all the concurrency work: any `shutdown()`/cancel/timeout inside the deferral window bumps `generation` via `teardown` and resolves the turn itself, and the late completion bails at `guard gen == generation`. Mirrors `DeclaredWorldDeriver.OneShotOutput`'s join SHAPE without its lock (both signals are main-actor hops here). This is a diagnosability fix only: `CompilerRunFailure.isTheWritersOwnDoing` matches neither detail, so no orchestrator or pane routing moves.

**Tech Stack:** Swift concurrency on a `@MainActor` class; bash fixture harness in the test file.

## Global Constraints

- Branch: `claude/issue-36-death-join` off `main`.
- **The two currently-flaking tests (`test_aSilentDeathSaysOnlyWhatItKnows`, `test_aDeathThatSaidWhyCarriesItsLastWord`) are the pins and MUST NOT be edited** — after the fix they cannot invert under load; before it they pass on an idle machine. The new fixture mode is what makes the race deterministic.
- The shutdown contract (AREA.md's sharp edge) is untouchable: `deinit` stays empty-with-its-comment; every deferral state is a `[weak self]` `Task` or plain main-actor property; the new `terminationHandler` is nilled in `teardown()` alongside the readability handlers (a live closure on a released `Process` is the shape the contract exists to prevent); the grace task is cancelled there too.
- `teardown()` is deferred WITH the resolve, never before it — it nils `process`/`stderrPipe`/`stderrTail`, the three things the deferred completion reads. The `hadRun == false` (idle-death) arm still tears down on the same joined signal.
- The fast path stays fast: when EOF finds the child already reaped (`isRunning == false`), behavior is byte-identical to today — resolve inline, no new latency.
- `receiveEOF`'s "Only for a nonzero exit … safe to read synchronously" comment is REWRITTEN, not deleted: after the join, exit is always observed (or the grace expired) before `stderrEssence()` runs, so the precondition holds by construction — say that.
- Iteration: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/ClaudeCLISessionTests`. Full gate `./scripts/test.sh full` before merge. Never touch `Maugham.xcodeproj/`/`project.yml`; no new files.
- OUT OF SCOPE: `TectonicInvoker`'s terminationHandler-resolves-everything shape (documented as the wrong pattern); `CompilerOrchestrator`/`DiagnosticsPane`/`CompilerRunner` (nothing moves — verify by diff absence, not by edits); the `--resume` fallback (still not built).

---

### Task 1: The join, the grace, the deterministic fixture, and the pins

**Files:**
- Modify: `Maugham/Compiler/ClaudeCLISession.swift` (`ensureProcess` ~254-310, `receiveEOF` ~511-533, `teardown` ~680-695, new members beside the timers)
- Modify: `MaughamTests/ClaudeCLISessionTests.swift` (one new fixture mode, two new tests, `makeSession` gains a `deathReapGrace:` passthrough defaulting to the production constant)

**Interfaces:**
- Produces: `private func processDidExit(generation:)`, `private func tryCompleteDeath(generation:graceExpired:)`, `static let deathReapGrace: TimeInterval = 2` + an init parameter override (the `runTimeout`/`idleTimeout` pattern). All private/internal — nothing outside the file consumes them.

- [ ] **Step 1: Write the failing test with the new fixture mode**

Add mode `.dieAfterClosingStdout` to the fixture script (beside `.dieWithStderr`):

```bash
        if [ "$MODE" = "dieAfterClosingStdout" ]; then
          IFS= read -r _line
          exec 1>&-
          echo "Loading configuration" >&2
          echo "Invalid API key - Please run /login" >&2
          echo "" >&2
          sleep 0.4
          exit 1
        fi
```

(stdout closed FIRST — the session sees EOF while the child demonstrably lives; the why lands on stderr AFTER the close; the exit comes 0.4s later. This is CI's race made deterministic, plus the sharper half: stderr written after the stdout close must still reach the diagnostic.)

The test, beside the two pins:

```swift
    /// Issue #36's race, made deterministic and permanent: stdout's EOF and
    /// the child's exit are independent deliveries, and on a loaded machine
    /// the EOF wins — `receiveEOF` used to poll `isRunning` at that instant,
    /// give up on the status, and collapse the writer's diagnostic to "the
    /// CLI closed its output" (CI runs 31613211133, 31627910133, 31668027497).
    /// The fixture closes stdout, says why on stderr, LINGERS, then exits —
    /// so EOF always arrives with the child alive, and only a session that
    /// waits for the exit can name the status and carry the last word.
    func test_aDeathReapedLateStillCarriesItsStatusAndLastWord() async throws {
        let cli = try makeFakeCLI(mode: .dieAfterClosingStdout)
        let session = makeSession(cli: cli)

        let event = await session.send(message: "hello", systemPreamble: nil)

        guard case .failed(.sessionDied(let detail)) = event else {
            return XCTFail("expected .sessionDied, got \(event)")
        }
        XCTAssertTrue(detail.contains("status 1"), "got: \(detail)")
        XCTAssertTrue(detail.contains("Invalid API key - Please run /login"),
                      "stderr written after the stdout close is still the essence; got: \(detail)")

        session.shutdown()
    }
```

- [ ] **Step 2: Run it — expect FAIL** with `got: the CLI closed its output` — the CI signature, on demand, on any machine.

- [ ] **Step 3: Implement the join**

`ensureProcess`, after the stderr handler wiring and before `proc.run()` (generation-captured like the reader):

```swift
        // The SECOND death signal (issue #36): stdout's EOF and the child's
        // exit are independent deliveries with no ordering, and the EOF used
        // to carry the whole verdict — polling `isRunning` at that instant
        // and giving up on the status when the reap lagged. Now both funnel
        // into one completion. Same hop as every other callback: nothing off
        // the main actor touches session state.
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.processDidExit(generation: gen) }
        }
```

New state beside the timers (plain main-actor properties — the generation guard is the mutual exclusion, see `tryCompleteDeath`'s doc):

```swift
    private var deathEOFSeen = false
    private var deathGraceTask: Task<Void, Never>?
```

`receiveEOF` becomes the EOF entry into the join (token/`hadRun` reads move into the completion so a turn arriving between EOF and exit cannot skew them):

```swift
    private func receiveEOF(generation gen: Int) {
        guard gen == generation else { return }
        deathEOFSeen = true
        tryCompleteDeath(generation: gen, graceExpired: false)
    }

    private func processDidExit(generation gen: Int) {
        guard gen == generation else { return }
        tryCompleteDeath(generation: gen, graceExpired: false)
    }
```

The completion — fast path preserved, grace bounded, teardown deferred with the resolve:

```swift
    /// The death verdict, spoken once, after BOTH halves have landed — EOF on
    /// stdout (every byte read; the anchor, because EOF is ordered behind the
    /// last byte and an exit-first resolve would truncate a CLI that prints
    /// its result and dies) and the child's exit (the status, and the proof
    /// that `stderrEssence`'s synchronous drain cannot block: a reaped writer
    /// holds no fd). `DeclaredWorldDeriver.OneShotOutput` is the same join
    /// one abstraction over; here the lock is unnecessary because both
    /// signals hop to the main actor and the GENERATION guard is the mutual
    /// exclusion — a shutdown, cancel or timeout inside the wait bumps
    /// `generation` via `teardown` and resolves the turn itself, and the late
    /// completion bails above. The grace is the bounded-join door: if the
    /// exit never arrives (a stranger holding the process), fall back to
    /// today's exact sentence rather than hanging into the run timeout.
    private func tryCompleteDeath(generation gen: Int, graceExpired: Bool) {
        guard gen == generation, deathEOFSeen else { return }
        let exited = process.map { !$0.isRunning } ?? true
        if !exited && !graceExpired {
            if deathGraceTask == nil {
                deathGraceTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(Self.resolvedDeathReapGrace * 1_000_000_000))
                    self?.tryCompleteDeath(generation: gen, graceExpired: true)
                }
            }
            return
        }
        deathGraceTask?.cancel()
        deathGraceTask = nil
        let token = runToken
        let hadRun = inFlight != nil
        let status = process.map { $0.isRunning ? nil : $0.terminationStatus } ?? nil
        let essence = (status ?? 0) != 0 ? stderrEssence() : nil
        teardown()
        if hadRun {
            let detail: String
            if let status {
                detail = essence.map { "the CLI exited with status \(status): \($0)" }
                    ?? "the CLI exited with status \(status)"
            } else {
                detail = "the CLI closed its output"
            }
            resolve(.failed(.sessionDied(detail: detail)), token: token)
        }
    }
```

(`resolvedDeathReapGrace` = the injectable: `static let deathReapGrace: TimeInterval = 2` as the default of an init parameter stored like `runTimeout` — adapt the exact spelling to the init's existing shape. The grace `Task` inherits main-actor isolation like `armRunTimeout`'s.)

`teardown()` gains, beside the readability-handler nils:

```swift
        process?.terminationHandler = nil
        deathGraceTask?.cancel()
        deathGraceTask = nil
        deathEOFSeen = false
```

- [ ] **Step 4: Run the new test (PASS) and the two pins** — then the whole suite (`… -only-testing:MaughamTests/ClaudeCLISessionTests`, 25 tests + 2 new). `test_aRetiredProcessCannotResolveTheLiveTurn` is the generation guard's standing proof and must pass untouched; `test_sessionDeathSelfHeals` and `test_cliResolutionIsCachedAcrossRespawns` are detail-agnostic and must not notice the change; `test_toggleGovernsSpawnAndLifetime`'s shutdown path exercises the new teardown lines.

- [ ] **Step 5: Pin the fallback door**

Second new test — grace shorter than the linger, so the bounded join's OTHER exit is deterministic too:

```swift
    /// The bounded join's other door: if the exit never arrives inside the
    /// grace, the session says today's honest sentence rather than hanging
    /// toward the run timeout. Grace 0.2s against a 0.4s linger makes the
    /// fallback the certain outcome; nothing here asserts a status, because
    /// the whole point is that none was learnable in time.
    func test_aDeathWhoseReapOutlivesTheGraceFallsBackToTheHonestSentence() async throws {
        let cli = try makeFakeCLI(mode: .dieAfterClosingStdout)
        let session = makeSession(cli: cli, deathReapGrace: 0.2)

        let event = await session.send(message: "hello", systemPreamble: nil)

        XCTAssertEqual(event, .failed(.sessionDied(detail: "the CLI closed its output")))
        session.shutdown()
    }
```

Run both new tests + the pins again.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Compiler/ClaudeCLISession.swift MaughamTests/ClaudeCLISessionTests.swift
git commit -m "fix(compiler): the death verdict waits for EOF and exit both (#36)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: AREA.md + full gate

**Files:**
- Modify: `Maugham/Compiler/AREA.md` — a short paragraph beside "Generations, not booleans" (same "two independent deliveries" family): the death verdict is a JOIN of stdout's EOF and the child's exit, bounded by `deathReapGrace`, because either alone can precede the other and an EOF-only verdict collapsed the writer's diagnostic to a sentence with nothing actionable in it (issue #36); the generation guard is what makes the wait safe.

- [ ] **Step 1:** Add the paragraph in AREA.md's voice.
- [ ] **Step 2:** Run `./scripts/test.sh full` (timeout 600000) — green, no skips beyond the documented pre-existing ones. If it fails: capture and report BLOCKED; do not commit.
- [ ] **Step 3:** Commit:

```bash
git add Maugham/Compiler/AREA.md
git commit -m "docs(compiler): record the death join (#36)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-review notes

- Issue #36's fix shape ("join the two events … then read status + essence and resolve once") is implemented with the research's four design notes: fast path preserved, wait bounded with fallback-to-today, teardown deferred with the resolve (idle-death arm included), generation guard as the whole concurrency story.
- The two flaky pins are untouched by name in the constraints; the new mode makes the race deterministic in BOTH directions (join completes → status carried; grace expires → honest sentence).
- Non-goals verified by absence: no orchestrator/pane/runner edits; `isTheWritersOwnDoing` matches neither detail so routing is provably unchanged.
