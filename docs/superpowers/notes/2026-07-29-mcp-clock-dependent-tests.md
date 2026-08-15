# Three MCP tests depend on wall-clock progress, and fail or hang under a loaded suite

*Recorded 2026-07-29, during the 1C-c2/1C-c2a canvas slices. Not a canvas problem; found because a full-suite run was needed before merge and could not be obtained.*

## What happens

On a 3,480-test Mac run (287 s), three failures across two tests — reproducible, and green in isolation:

| Test | Failure | Alone |
|---|---|---|
| `MCPBinaryIntegrationTests.test_binary_exitsCleanly_onStdinClose` | `Asynchronous wait failed: Exceeded timeout of 5 seconds, with unfulfilled expectations: "binary exits"` — the test itself took **9.4 s** | passes; its four siblings each pass in <1 s |
| `MCPColdStartTests.test_firstCallAfterLaunch_pollsUntilServerBinds_noPriorConnection` | two assertions, `:50` and `:52` — got `{"error":{"code":-32001,"message":"Maugham isn't running."}}` where a real response was required | passes |

And a third, which is the same family with a worse symptom:

| `MCPServerLifecycleTests.test_request_dispatchesViaRouter` | **hung indefinitely** — measured at 45 minutes with no output, after 1,523 cases in ~3 minutes | passes alone in 0.003 s (class: 4/4 in 6.9 s) |

Both suites together: **8/8 in 6.9 s** on an idle machine.

## Why

All three are correctness-under-wall-clock tests, and a loaded machine is the input they are not written for.

- **`exitsCleanly_onStdinClose`** launches the real `maugham-mcp` binary, closes stdin, and allows the process **5 s** to exit (`MCPBinaryIntegrationTests.swift:134`). Under contention the subprocess is not scheduled promptly and the expectation lapses. Nothing is wrong with the binary; the test measured the machine.
- **`pollsUntilServerBinds_noPriorConnection`** is a **three-way race by construction** (`MCPColdStartTests.swift:28-54`): a bridge launched against an absent socket with a 10 s reconnect budget, a stub listener scheduled to bind **2.5 s later** via `asyncAfter`, a request fired immediately, and a **9 s** read. It passes only if the `asyncAfter` fires near its deadline, the bridge is still polling when it does, and the reply lands inside the read window. Under load the listener slips, the bridge's budget expires first, and it synthesises the not-running answer the test exists to prove it does *not* give.
- **`dispatchesViaRouter`** had **no deadline at all**. Its `recv` blocked forever when the response did not come, so the same class of failure arrived as a hang rather than an assertion.

## What has been done

`5fe107b` put `SO_RCVTIMEO` (10 s, ~3,000× the passing time) on `MCPServerLifecycleTests`' read, so the third one now **fails with a named assertion** instead of hanging. That is a diagnosis aid, not a fix: it converts an unkillable run into a legible failure.

## What is NOT known

**Why the response never arrives in whole-suite order.** The server writes only after hopping to the main actor for `MCPRouter.dispatch`, so something holding the main actor is the obvious hypothesis — it is a hypothesis. Which other tests participate is unestablished, and the writer's own instinct on seeing this was that other tests are likely involved. Treat the shipped comment in that file as stating the mechanism it can see, not the trigger.

## A wrong diagnosis, recorded so nobody re-derives it

For a while this was attributed to **Claude Desktop's `maugham-mcp` bridges holding the dev `mcp.sock`**, plus a leaked test host. **That is false.** All three tests bind isolated temp paths and never touch the variant socket:

- `MCPServerLifecycleTests` → `/tmp/mcp-<uuid>.sock`
- `MCPColdStartTests` → `/tmp/mcp-cold-<uuid>.sock`
- `MCPBinaryIntegrationTests` → `MAUGHAM_MCP_SOCKET=/tmp/definitely-not-a-real-socket-<uuid>.sock`

Quitting Claude Desktop, or the dev app, changes nothing. The stale `/tmp/mcp-*.sock` files left behind are residue of killed runs — `server.stop()` never ran — not a cause.

## Options, when this is picked up

1. **Make the deadlines event-driven rather than clock-driven.** The cold-start test could wait on the listener *actually binding* rather than assuming 2.5 s of wall clock, which removes the race instead of widening it. This is the fix that survives a slower machine and CI.
2. **Widen the budgets.** Cheapest, and it only moves the threshold — the tests stay load-sensitive and will bite again on busier hardware.
3. **Find the main-actor trigger for the hang**, which is the one with no deadline and the only one whose mechanism is genuinely unexplained. Bisect by running the lifecycle class after progressively larger slices of the suite.

Note the constraint any fix inherits: the budgets under test model a **real product constant** (`MAUGHAM_MCP_RECONNECT_BUDGET_MS`, default 15 s — `Maugham/MCP/AREA.md:213`), so a test that widens its budget past production's is no longer testing the shipped behaviour.

## Until then

`-skip-testing:MaughamTests/MCPServerLifecycleTests` gives a complete Mac run in ~5 minutes; the other two fail in-suite and pass in isolation, which is the discriminator to apply before believing a red run is about your branch.

## Resolution (2026-08-08): parallelization removed the trigger

The suite now runs test classes across ~7 parallel worker processes
(`parallelizable: true`, project.yml). Each worker hosts a seventh of the
classes, so the condition all three failures needed — one process grinding
3,400 tests through one main actor — no longer exists. This is the "something
holding the main actor" hypothesis above, confirmed by removal.

Evidence, all on 2026-08-08:

- Two full parallel gates with NO skips: green, with margins that are no
  longer close — `dispatchesViaRouter` 0.002s against its 10s receive
  timeout, `exitsCleanly` 0.33s against its 5s window, `pollsUntilServerBinds`
  3.1s against its 9s read.
- A 5-gate no-skip burn-in (results recorded in the retiring commit).
- Two CI runs of the full suite (CI never had the skip) green on slower
  `macos-26` runners.
- `MCPColdStartTests` + `MCPBinaryIntegrationTests` ran in every local
  parallel gate all day (~8 more runs) without a failure.

The `test.sh full` / documented `-skip-testing:MaughamTests/MCPServerLifecycleTests`
skip is retired. Two of the three tests were also hardened so a genuinely
overloaded machine (e.g. two sessions' gates overlapping — the third
confounder in CLAUDE.md's build-flow notes) cannot produce a false red:

- `exitsCleanly_onStdinClose`: exit allowance 5s → 60s. The property is
  "stdin closes ⇒ the binary exits"; the expectation fulfills on the exit
  event, so the widening costs nothing when green and models no product
  constant.
- `pollsUntilServerBinds_noPriorConnection`: bridge budget 10s → 15s, which
  is `MAUGHAM_MCP_RECONNECT_BUDGET_MS`'s production default — more faithful,
  not less — and the stub listener records when it ACTUALLY bound; a bind
  that lands outside the budget discards the attempt (bounded retry, the
  mint-and-return pattern) instead of failing on a slipped `asyncAfter`.
- `dispatchesViaRouter` keeps its 10s `SO_RCVTIMEO` unchanged: 5,000× margin,
  and its hang trigger lived in the serial world.

If one of these goes red again: in-suite/in-isolation discriminator first,
`ps ax | grep xcodebuild` for other sessions second, code archaeology last.


## Reopened, 2026-08-15 (M3-P1)

The resolution above did not hold. Two new facts from the M3-P1 branch:

1. **A new failure mode: the indefinite hang.** `MCPServerLifecycleTests`
   parked a full gate in `XCTWaiter` indefinitely (killed at 20 minutes) on
   a QUIET machine — load 1–2, no rival `xcodebuild` — and the disable
   experiment reproduced the hang on the unmodified parent commit
   (`491a0e9d`), so no branch diff is implicated. This is not the 64s
   deadline miss the resolution section explains; it is a park with no
   deadline firing at all.
2. **Load-dependent deadline misses recurred four times** across
   2026-08-14/15 (machine at load 150–190 from concurrent sessions, and
   once at load ~14), each time green in isolation with 16–1000× margins,
   never twice the same test.

Interim gate protocol (recorded in CLAUDE.md): run the suite minus the
three MCP classes, plus those three in isolation; a hang in
`MCPServerLifecycleTests` is the environment until this section is closed
again. The hypothesis space for the hang starts at: something in the
recovery/strict-read merges' MCP test-tool changes (2026-08-12/13), a
socket left held by a crashed sibling process, or an `XCTWaiter`
expectation whose fulfilling path can now early-return without
fulfilling. Nobody has measured yet — this section records sightings, not
a diagnosis.

### Sighting, 2026-08-15 10:01 BST (tectonic-bundle-fetch branch)

Third occurrence of the hang shape, on a **quiet** machine (one gate, no
rival `xcodebuild`, no other session building). `./scripts/test.sh full`
reached 5,746 passing tests, printed `Test suite 'MCPServerLifecycleTests'
started`, and then emitted nothing further for ~9 minutes before being
killed at 11m41s elapsed. No test case line for that suite ever appeared —
the park again, not a deadline miss.

The interim protocol worked and cost one extra run:

| run | result |
|---|---|
| whole Mac suite minus the three MCP classes | 5,767 passed, 0 failed |
| the three MCP classes in isolation | 12 passed, 0 failed |

The branch under test touched only `MaughamTests` publish/tectonic guards
and `.github/workflows/ci.yml` — nothing on any MCP path — which is one
more data point that the hang is independent of the diff. Still no
diagnosis; still recording sightings.

## ROOT-CAUSED, 2026-08-15: the host runs at libdispatch's thread ceiling

The hang is not clock-dependent and has nothing to do with the main actor. It
is not any branch's diff, and it is not a product defect.

### What was measured

A stalled gate was caught live and sampled (`/usr/bin/sample`, pid 15648).
`sample` diagnosed it in its own header:

```
Dispatch Thread Soft Limit: 64 reached in 3490 of 3490 samples
  -- too many dispatch threads blocked in synchronous operations
```

63 of the process's 69 threads were parked identically:

```
_dispatch_worker_thread2  (DispatchQueue_19: com.apple.root.user-interactive-qos)
  _dispatch_call_block_and_release
    -[NSAnimation _runBlocking]
      -[NSRunLoop runMode:beforeDate:]
        __CFRunLoopRun -> mach_msg2_trap
```

The control that matters:

| process | total threads | in `-[NSAnimation _runBlocking]` |
|---|---|---|
| `Maugham.app` launched normally | 10 | 1 |
| any xctest host, during launch, **before a test runs** | 68 | 63–64 |

So **every** Maugham test host sits at the dispatch ceiling from launch. This
was verified against a pure, non-mounting suite (`OpLogStoreTests` alone) —
it is not caused by mounted-view tests, and not by any particular class.

### Why that produced an unkillable park

At the ceiling, whether a `DispatchQueue.global(...).async` block ever gets a
thread is up to the kernel workqueue governor. Usually it gets one in
microseconds. Sometimes it never gets one at all — which is exactly the
observed bimodal signature: `test_request_dispatchesViaRouter` takes **0.006 s
or forever**, never anything between.

And the hardening from `5fe107b` could not save it. The 10 s `SO_RCVTIMEO`
lives *inside* the block that never ran, so when the block was never scheduled
the continuation never resumed and the timeout never fired. A deadline that is
only reachable through the thing that failed is not a deadline.

### Reproduction (deterministic, ~2 minutes)

Run the stuck worker's 31 classes serially in one process:

```
xcodebuild ... -parallel-testing-enabled NO \
  -only-testing:MaughamTests/DiagnosticsPaneTests ... (the 31 from that worker)
```

`test_request_dispatchesViaRouter` parked 1-for-1 this way, versus roughly one
full-suite run in two.

### What shipped

1. **`MCPServerLifecycleTests.sendAndReceive` reads on a dedicated `Thread`.**
   A `Thread` is not drawn from the dispatch pool and cannot be starved by it,
   so the receive timeout can always fire. Verified: in a saturated host the
   test now **fails in 15 s with its own name and message** instead of parking;
   alone it still passes in 0.002 s. `test_theReadDoesNot...Exhausted` is the
   census that keeps the read off a global queue.
2. **`scripts/test.sh` now passes `-test-timeouts-enabled YES
   -default-test-execution-time-allowance 120`**, which CI has always passed
   and local runs never did. That asymmetry is why the three sightings were all
   local: under CI's allowance the same park dies at 120 s carrying its name.

### Wrong turns, recorded so nobody repeats them

- **"`DiagnosticsPaneTests` leaks a window per test and that is the source."**
  Plausible (72 tests, ~63 threads, `mount` calls `orderFront` and nothing ever
  closes the windows) and **wrong**. Closing and ordering out every window in
  `tearDown` moved the peak from 74 to 71. A single test from a *pure* suite
  shows the same 69, because the threads are there before any test runs.
- **"The Welcome window's appearance animation is the source."** Tested by
  suppressing the scene at launch (`.defaultLaunchBehavior(.suppressed)`):
  peak stayed at 69. Falsified.

### Still open

**What starts the animations.** They exist before the first test and the
`_runBlocking` frames carry no enqueuer, so a sample cannot name the creator;
`lldb` could, via a breakpoint on `-[NSAnimation startAnimation]`, but attach
was denied in the environment this was chased from. Whoever picks this up
should start there — it is the true root cause, and removing it would also fix
the remaining consequence below.

*(The second item that stood here — `MCPServer.blockingAccept`/`blockingRecv`
having the same dependency — was closed; see "The production half" below.)*

## The production half: MCPServer no longer blocks dispatch workers

Fixing only the test left the gate red in a different place: with the test's
read on a dedicated thread it proceeded immediately and then waited 10s for a
server that could not get a worker to `accept()` on. Four gates in a row failed
somewhere in this family and never twice the same way — `dispatchesViaRouter`
and `whenDisabled` (server starved), `pollsUntilServerBinds` (staging starved),
`exitsCleanly_onStdinClose` (watcher starved).

So `MCPServer.blockingAccept` / `blockingRecv` now run their blocking syscalls
on dedicated `Thread`s (`onBlockingThread`) instead of
`DispatchQueue.global(qos: .utility)`. This is the documented shape: a blocking
syscall on a dispatch worker holds that worker for the duration, and the global
pool has a hard 64-thread ceiling. **The property being restored is a product
one** — as written, MCP would silently stop answering if anything else in the
process saturated GCD, with no error, no log and no refused connection. The
shipping app has one blocked thread rather than 64, so this was latent rather
than live, but it is not a property worth keeping. Cost: one thread per server
plus one per open connection, 512 KB of stack each; Claude Desktop opens one.

**Result: two consecutive full local gates green — 5,780 passed, 0 failed,
exit 0** — where the four before this change failed 1–3 tests each.

## Still open

**What starts the animations.** They exist before the first test and the
`_runBlocking` frames carry no enqueuer, so a sample cannot name the creator;
`lldb` could, via a breakpoint on `-[NSAnimation startAnimation]`, but attach
was denied in the environment this was chased from. It is the true root cause,
and while nothing now depends on the starved pool, a host sitting at the
ceiling is still a latent trap for the next test that reaches for
`DispatchQueue.global`.

### The 2026-07-29 note's three tests were ONE defect all along

This section's original title — "three MCP tests depend on wall-clock
progress" — was the symptom, not the cause. All three are simply the only
tests in the suite that depend on a **global-queue block actually being
scheduled**, in a process that runs at the dispatch ceiling:

| test | its dependency | outcome when the block is starved |
|---|---|---|
| `MCPServerLifecycleTests.test_request_dispatchesViaRouter` | `DispatchQueue.global(.userInitiated).async { recv }` | park with no deadline (the `SO_RCVTIMEO` is inside it) |
| `MCPColdStartTests.test_firstCallAfterLaunch_pollsUntilServerBinds` | `DispatchQueue.global().asyncAfter(+2.5s)` staging the bind | bind slips, bridge's budget expires, `-32001` — the exact answer the test exists to disprove |
| `MCPBinaryIntegrationTests.test_binary_exitsCleanly_onStdinClose` | `DispatchQueue.global().async { waitUntilExit() }` | the exit event is observed late; survives only because its allowance is 60s |

The first two now use dedicated `Thread`s (`CancellableBringUp` is the
cold-start one) and are green. **The third is unchanged** — its 60s allowance
absorbs the delay today, so it degrades rather than fails, but it is the same
shape and the same fix applies if it ever bites.

None of this is load-dependence in the ordinary sense: a quiet machine hits it
just as readily, because the ceiling is reached at launch and has nothing to do
with how busy the machine is. That is why "it happened on a QUIET machine" was
so confusing in the reopened section above.

## CLOSED, 2026-08-15: it was window state restoration

The last open question — what starts the animations — has an answer, caught by
attaching `lldb` at exec (`process attach --name Maugham --waitfor`, so the
breakpoints exist before the app's launch code runs) with a breakpoint on
`-[NSAnimation startAnimation]`. The receiver is `_NSWindowTransformAnimation`
and the stack names the whole chain:

```
-[NSAnimation startAnimation]
-[_NSWindowTransformAnimation startAnimation]
NSPerformVisuallyAtomicChange
-[NSWindow _doOrderWindow:]
-[NSWindow makeKeyAndOrderFront:]
SwiftUI`closure #1 in AppWindowsController.showInitialWindows()
SwiftUI`AppDelegate.applicationOpenUntitledFile(_:)
AppKit`-[NSApplication _doOpenUntitled]
AppKit`-[NSApplication _reopenWindowsAsNecessaryIncludingRestorableState:...]
AppKit`-[NSDocumentController _autoreopenDocumentsIgnoringExpendable:...]
```

**macOS window restoration.** Every test-host launch went through
`_reopenWindowsAsNecessaryIncludingRestorableState:` into SwiftUI's
`showInitialWindows()`, and each `makeKeyAndOrderFront:` gets a
`_NSWindowTransformAnimation` that AppKit runs BLOCKING on a dispatch worker.
In a test host the window is never really presented, so the animation never
completes and the worker is held for the life of the process — up to the
64-thread ceiling, reached before the first test runs.

This is also why suppressing the Welcome window changed nothing: the windows
being restored are not the Welcome scene, they are whatever the developer had
open.

### The fix

`project.yml`'s Maugham test action now passes `-ApplePersistenceIgnoreState
YES` to the host, so tests never restore windows. Measured on
`DiagnosticsPaneTests` (72 tests, heaviest mounting suite):

| | peak threads | in `_runBlocking` | soft limit | tests |
|---|---|---|---|---|
| before | 74 | 51–63 | **reached** | 75 pass |
| after | 37 | 6 | not reached | 75 pass |

**Second reason to want this independently of the hang:** the test host was
reopening whatever project windows the developer happened to have had open — a
hidden dependency on machine state that no test asks for and none should have.

### What this means for the two earlier fixes

Both stand, and neither is redundant:

- The dedicated `Thread`s in the three MCP test classes are what make a
  starved pool *diagnosable* rather than an unkillable park. Cheap insurance.
- `MCPServer.blockingAccept`/`blockingRecv` on dedicated threads is a product
  property in its own right — MCP must not stop answering because something
  else saturated GCD — and does not depend on this note being true.

The ceiling itself is now gone, so a future test that reaches for
`DispatchQueue.global` is no longer walking into a trap.
