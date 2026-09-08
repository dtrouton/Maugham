# Signed op log P1 — handoff

> **STUB.** Task 10 owns this note and writes the rest of it: what landed per
> task, the measured cost, whether the two enclave tests ran here, the
> slug-change consequences in writer-facing words, the review's findings and
> fixes, and the smoke script. The section below is the one part the final fix
> wave was asked to leave behind, because each item is a decision that is
> Denver's to make and nobody else's.

## Decisions owed

1. **The 100 ms budget at 50k lines was not met as stated.** The plan's global
   constraint 3 says "50k ops must add under 100 ms to a cold open". Task 5's
   first measurement of that fixture added roughly **450 ms end to end**; after
   the hex fix the chain's own work is **55–83 ms** on a tail eight times the
   size `segmentSealThreshold` lets a real one reach, and the end-to-end delta
   sits inside the parse's own noise (the load is ~5.8 s of `JSONDecoder`). The
   implementer's reframe — that the budget is really about a realistic
   per-document op count — may well be right, but it is a change to an
   acceptance criterion made by the implementer. **Is the reframe accepted, and
   what is the budget restated against?** ADR 0032 and `Maugham/OpLog/AREA.md`
   now say what was measured and that the budget was not met; neither claims it
   was.

2. **A set-aside notice never clears** (review M6). `HistoryPane`'s set-aside
   line count sums every `.lines` archive for the document, forever, with no
   dismissal path. That is the intended forensic contract — the bytes are kept
   and there is nothing to bring back — but it means one agent write leaves a
   permanent orange line in History for the life of the project. **Should there
   be a way to acknowledge one?** The same question now applies to the Inbox
   pane's own half of that sentence (`InboxPane.setAsideNotice`).

3. **`OpLogDeviceState` rewrites its whole file on every `remember`, and prunes
   nothing** (review M5). Entries for deleted projects stay forever. Fine at
   today's sizes; a slow leak, and the write amplification grows with the number
   of files this device has ever written. **Left alone, pruned on some trigger,
   or moved to an append-and-compact shape?**

4. **The project stream has no size ceiling.** `__project__` now seals like every
   other stream (review I5), but `sealTailIfNeeded` still refuses to rotate it —
   a recorded decision — so its tail grows without limit and the chained
   append's verify cost grows with it. Pre-existing growth, new cost. **Should
   the project stream rotate into segments, and if so what owns the boundary?**

5. **The cost fixture wants one re-run on a quiet machine.** The numbers in
   ADR 0032 and the AREA guide come from a run taken while other work was on the
   box (ledger L56). They should be re-taken once and quoted durably.

6. **The truncation rule is closed at P1 only where a seal exists.**
   `OpLogChain.resolveAbsentHead` quarantines a forged tail back to the last
   seal this device TRUSTS, so an unsigned device (no enclave) is not protected
   at all — deliberately, because quarantining a whole unsigned file over a
   missing head would cost the writer their manuscript to catch nobody. The
   honest close is P2's registry plus a rule that an adopted head must be at or
   descended from the last trusted seal. **Confirm that P2 carries it.**

7. **Four more sentinel device strings turned up while fixing C1, and their
   streams are now unsigned.** The review named `TaskDeriver.rebalanceSentinel`;
   the same shape is reached by every `Document.load` caller that passes a role
   rather than a device — `"wiki-rename"` (`ProjectStore+Structure`),
   `"find-replace"` (`ProjectStore+Search`) and `"mcp"` (`TaskReadTools`,
   `AnnotationToolHelpers`). Under C1 all four write append-only, unchained,
   unsealed files, which is exactly what they did before this milestone — and
   the alternative, chaining them, is the mutually-truncating bug C1 exists to
   remove. But `"mcp"` covers **every annotation Claude writes**, so a real
   share of a project's history is deliberately outside the signature.
   **Should those sites pass `DeviceIdentity.current.deviceId` instead**, so
   Claude's writes are this Mac's own signed history in this Mac's own file?
   That changes which file they land in (nothing is lost — ops merge by opId),
   and it is a scope change rather than a fix, so it was not made here.

8. **A Mac with no Secure Enclave is silently unsigned.** It writes chained
   lines that nothing seals and says nothing about it anywhere. **Should History
   say so once per project?** (Carried from the plan's own list.)
