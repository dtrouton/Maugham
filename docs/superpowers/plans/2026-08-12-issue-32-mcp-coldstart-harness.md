# Issue #32 — MCP cold-start harness hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A dead `maugham-mcp` bridge child no longer raises `NSFileHandleOperationException` through the test harness — it restages (where a restage loop exists) or fails with the diagnosis in the message (where one doesn't).

**Architecture:** Harden the private test harness in `MCPColdStartTests.swift` — `send` becomes throwing (`isRunning` guard + Swift's throwing `write(contentsOf:)` instead of ObjC's exception-raising `writeData:`), `terminate`'s unconditional `closeFile()` becomes a `try? close()` so the exception can't just move to the `defer`, and `readLine` stops burning its whole timeout on a dead child. Test 1 wires the new error into its existing bounded restage loop; tests 2 and 3 let it propagate so a dead child arrives as a named failure. `MCPBinaryIntegrationTests` gets the same throwing-write treatment via a mirrored per-file helper (the two files deliberately share no types today; a shared harness is a wider refactor than this hardening warrants).

**Tech Stack:** Swift / XCTest, Mac scheme only. No production code changes.

## Global Constraints

- Branch: `claude/issue-32-coldstart-harness` off `main`.
- Test files only — no production sources, no `project.yml`, no `project.pbxproj` (generated, must never appear in a diff).
- Iteration command (both files are in the Mac scheme):
  `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/MCPColdStartTests -only-testing:MaughamTests/MCPBinaryIntegrationTests`
- Each test opens with `XCTSkip` when `maugham-mcp` isn't built — if the targeted run reports skips instead of passes, build the full scheme once first (`xcodebuild -project Maugham.xcodeproj -scheme Maugham build-for-testing CODE_SIGNING_ALLOWED=NO`).
- Pre-merge gate: `./scripts/test.sh` during iteration, `./scripts/test.sh full` before merge (house rule; the machine-global lock means don't run raw full-suite xcodebuild alongside it).
- Match the file's documented style: substantial doc comments with bolded ISO dates for disciplines (`**Dead-bridge discipline (2026-08-12).**`), CAPS on the load-bearing word, failure messages that end with the observed value, staging failures that say whose problem it is ("machine pathology worth a human look, not a bridge defect").
- Out of scope, do not touch: the unsynchronized `boundAt`/`listener` vars in test 1 (pre-existing, noted in the audit); `DeclaredWorldDeriver.swift:261`'s production pipe write (same latent shape, different issue); any shared-harness extraction between the two files.

---

### Task 1: Throwing harness in `MCPColdStartTests.swift` + all three call-site treatments

**Files:**
- Modify: `MaughamTests/MCP/MCPColdStartTests.swift` (harness at lines 161–222; call sites at 70, 120, 133, 154)

**Interfaces:**
- Produces: `private struct BridgeDied: Error, CustomStringConvertible` and `private static func send(_ p: Process, _ json: String) throws` — Task 2 mirrors both shapes in the other file. Task 3's CLAUDE.md sentence describes this task's behavior.

- [ ] **Step 1: Reproduce the exception shape (RED analog) with a planted offender**

The defect is a harness behavior, so the "failing test" is a plant: in `test_absentApp_synthesizesAfterBoundedBudget` (line 145), immediately after `Self.drainInitialConnect()`, insert:

```swift
        // PLANT (issue #32 verification — remove before commit): simulate the
        // loaded-VM child death from run 31299861454.
        proc.terminate()
        Thread.sleep(forTimeInterval: 0.2)
```

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/MCPColdStartTests/test_absentApp_synthesizesAfterBoundedBudget`
Expected: FAIL with `NSFileHandleOperationException` / "Bad file descriptor" raised from `send` — the same signature as the CI failure. Keep the plant in place for Step 3's GREEN check.

- [ ] **Step 2: Replace the harness trio**

Replace `send` (lines 195–198) and `terminate` (lines 216–221) with, and add `BridgeDied` above them in the `// MARK: - Harness` section:

```swift
    /// **Dead-bridge discipline (2026-08-12, issue #32).** A child that died on
    /// a loaded machine must not RAISE through the harness: NSFileHandle's ObjC
    /// `writeData:` raises NSFileHandleOperationException on a dead fd, and
    /// XCTest converts that to an instant failure BEFORE the read — bypassing
    /// the staged-scenario restage discipline entirely (2026-08-09, CI run
    /// 31299861454: 0.344s = launch + 0.3s drain + first write). `send` now
    /// throws this instead; test 1 restages it through its bounded loop, and
    /// tests 2–3 let it propagate so the failure message IS the diagnosis.
    private struct BridgeDied: Error, CustomStringConvertible {
        let phase: String
        let underlying: String
        var description: String {
            "bridge child died (\(phase)): \(underlying) — on a loaded machine "
                + "this is machine pathology worth a human look, not a bridge defect"
        }
    }

    private static func send(_ p: Process, _ json: String) throws {
        guard p.isRunning else {
            throw BridgeDied(phase: "before the write",
                underlying: "exit status \(p.terminationStatus)")
        }
        let handle = (p.standardInput as! Pipe).fileHandleForWriting
        do {
            try handle.write(contentsOf: Data((json + "\n").utf8))
        } catch {
            throw BridgeDied(phase: "during the write", underlying: "\(error)")
        }
    }
```

```swift
    private static func terminate(_ p: Process) {
        if let pipe = p.standardInput as? Pipe {
            // Throwing Swift API, not `closeFile()` — this runs from a `defer`
            // in every test, and a dead child's fd must not raise there either
            // (hardening `send` alone would just move the exception here).
            try? pipe.fileHandleForWriting.close()
        }
        if p.isRunning { p.terminate() }
    }
```

In `readLine` (lines 200–214), replace the bare `else` branch with a dead-child early exit so a dead bridge doesn't burn the full timeout in 50ms sleeps:

```swift
            } else if !p.isRunning {
                break   // EOF from a dead child; nothing more is coming
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
```

(`availableData` drains any buffered output before returning empty, so this cannot drop a response the child wrote before exiting.)

Now the call sites. **Test 1** — replace line 70 (`Self.send(proc, …)`) with a restage branch that joins the existing discipline:

```swift
            do {
                try Self.send(proc, #"{"jsonrpc":"2.0","id":1,"method":"list_projects"}"#)
            } catch {
                // The child died inside the launch/drain window — the 2026-08-09
                // CI failure arrived exactly here. Same verdict as a late bind:
                // the scenario wasn't staged, so discard and restage, bounded.
                bringUp.cancel()   // don't let the +2.5s bind fire into a discarded attempt
                if attempt < attempts { continue }
                return XCTFail("could not stage the cold-start scenario in "
                    + "\(attempts) attempts — \(error)")
            }
```

**Tests 2 and 3** — mechanical: lines 120, 133, 154 each gain `try` (`try Self.send(proc, …)`). All three test funcs are already `throws`; a thrown `BridgeDied` fails the test with its `description` — the named-failure treatment. No loop is added to tests 2–3: neither has ever flaked this way, test 2's two-send structure makes the restage point ambiguous (a child dying AFTER a successful request 1 could be a real bridge crash), and a `BridgeDied` message is a diagnosis a human can act on if it ever fires.

- [ ] **Step 3: Verify the plant now fails with the diagnosis, not the exception (GREEN analog)**

Re-run the Step 1 command (plant still in place).
Expected: FAIL — but now with `bridge child died (before the write): exit status …` in the failure message, and NO `NSFileHandleOperationException` anywhere in the log.

- [ ] **Step 4: Verify test 1 restages a dead child**

Move the plant into test 1: in `test_firstCallAfterLaunch_pollsUntilServerBinds_noPriorConnection`, after `Self.drainInitialConnect()` (line 55), insert:

```swift
            // PLANT (issue #32 verification — remove before commit): kill the
            // child on attempt 1 only; the restage must absorb it.
            if attempt == 1 {
                proc.terminate()
                Thread.sleep(forTimeInterval: 0.2)
            }
```

Remove the Step 1 plant from test 3. Run:
`xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/MCPColdStartTests/test_firstCallAfterLaunch_pollsUntilServerBinds_noPriorConnection`
Expected: PASS — attempt 1 is discarded, attempt 2 stages and asserts normally.

- [ ] **Step 5: Remove the plant, run the whole file clean**

Delete the Task-1 plant. Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/MCPColdStartTests`
Expected: 3 tests, all PASS, no plants left (grep the file for `PLANT` to be sure).

- [ ] **Step 6: Commit**

```bash
git add MaughamTests/MCP/MCPColdStartTests.swift
git commit -m "fix(tests): dead bridge restages instead of raising through send() (#32)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Same guard in `MCPBinaryIntegrationTests.swift`

**Files:**
- Modify: `MaughamTests/MCP/MCPBinaryIntegrationTests.swift` (writes at lines 45, 89, 124, 190, 195, 237, 242; `closeFile()` at 49, 99, 126, 199, 247)

**Interfaces:**
- Consumes: the `BridgeDied` + throwing-send SHAPE from Task 1 (mirrored, not shared — this file has its own harness by design).

- [ ] **Step 1: Add the mirrored helper**

Add to the class (near its `binaryURL()` helper):

```swift
    /// Mirror of MCPColdStartTests' dead-bridge discipline (2026-08-12, issue
    /// #32) — see that file's `BridgeDied` doc for the CI history. Kept
    /// per-file because the two harnesses share no types today. Exposure here
    /// is lower (no staged race, so nothing to restage): the point is only
    /// that a dead child arrives as this diagnosis, never as
    /// NSFileHandleOperationException.
    private struct BridgeDied: Error, CustomStringConvertible {
        let phase: String
        let underlying: String
        var description: String {
            "bridge child died (\(phase)): \(underlying) — on a loaded machine "
                + "this is machine pathology worth a human look, not a bridge defect"
        }
    }

    /// Writes exactly the bytes given (call sites already embed their own
    /// newlines) through the throwing Swift API, guarded on liveness.
    private func send(_ p: Process, raw text: String) throws {
        guard p.isRunning else {
            throw BridgeDied(phase: "before the write",
                underlying: "exit status \(p.terminationStatus)")
        }
        let handle = (p.standardInput as! Pipe).fileHandleForWriting
        do {
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            throw BridgeDied(phase: "during the write", underlying: "\(error)")
        }
    }
```

- [ ] **Step 2: Convert the eight write sites and five closes**

Each `inPipe.fileHandleForWriting.write(Data(X.utf8))` becomes `try send(proc, raw: X)` — the local `Process` variable's name varies per test; use whichever is in scope at that site. Each `….fileHandleForWriting.closeFile()` becomes `try? ….fileHandleForWriting.close()`. Every test in the file is (or becomes) `throws`; add the keyword where a signature lacks it. Do NOT change `collectResponseLine`, the per-test launch blocks, or the copy-pasted environment comments — collapsing that duplication is a refactor this issue doesn't own.

- [ ] **Step 3: Run the file**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/MCPBinaryIntegrationTests`
Expected: 5 tests, all PASS. Then grep the file for `writeData\|closeFile` — expected: no hits.

- [ ] **Step 4: Commit**

```bash
git add MaughamTests/MCP/MCPBinaryIntegrationTests.swift
git commit -m "fix(tests): mirror the dead-bridge guard in the binary integration harness (#32)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: CLAUDE.md sentence + full gate

**Files:**
- Modify: `CLAUDE.md` — "Outstanding correctness concerns", the RESOLVED 2026-08-08 MCP-tests bullet.

- [ ] **Step 1: Record the second failure mode in the resolved note**

At the end of that bullet (after "…come before any code archaeology."), append:

```
A SECOND, distinct failure mode existed and is closed (2026-08-12, issue #32): the child dying on a loaded VM and `send()` raising `NSFileHandleOperationException` before the read — the harness write now throws, test 1 restages a dead child through its bounded loop, and tests 2–3 fail with the diagnosis in the message.
```

- [ ] **Step 2: Full gate**

Run: `./scripts/test.sh full`
Expected: green, no skips. (This is the pre-merge gate; the machine-global lock queues it behind any concurrent gate.)

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: record the #32 exception-path closure in the MCP-tests note

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-review notes

- Issue fix-shape coverage: (1) throwing API + `isRunning` check → Task 1 Step 2; (2) restageable staging failure through the existing bounded loop, final attempt loud → Task 1 Step 2 (test 1 branch); (3) same guard considered in `MCPBinaryIntegrationTests` → Task 2 (adopted, minimal form). Bonus raise-site (`terminate`'s `closeFile()` from `defer`s) found in research and closed in Task 1.
- Deliberate non-goals restated: no shared harness extraction, no restage loops in tests 2–3 (rationale in Task 1 Step 2), no touch on `MCPServerLifecycleTests` (raw BSD sockets, cannot raise this exception), no production-code changes.
