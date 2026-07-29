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
