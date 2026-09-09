# Signed op log P1 — handoff (2026-09-08)

**Branch:** `claude/signed-op-log-p1-2026-09-07`, twenty commits on local `main` at `901b5598`, merged to local `main` UNPUSHED. **P1b (actors) followed on 2026-09-08** (branch `claude/signed-op-log-p1b-actors-2026-09-08`), resolving decision #7 below; Denver smokes P1 and P1b together. **Plan:** `docs/superpowers/plans/2026-09-07-signed-op-log-p1-integrity-and-the-device.md`. **Spec:** `docs/superpowers/specs/2026-09-05-signed-op-log-design.md` §8's first bullet. **ADR:** `docs/adr/0032-the-signed-op-log.md`. Denver smokes before anything is pushed or tagged; P2 and P3 are unwritten (rule 11).

## What landed, per task

1. **`DeviceIdentity` / `DeviceState`** (`5f0dbde4`) — the Secure Enclave key whose `dataRepresentation` the app persists itself under `~/Library/Application Support/<variant>/device/` (`device-key.blob`; never a keychain item, no entitlement), an unsigned twin (`device-token`) where no enclave is, a per-XCTest-process leaf, and the census that keeps `P256.Signing.PrivateKey(` out of production (`DeviceIdentity+Testing.swift` is the one allow-list entry).
2. **The device string is the key** (`ffabef76`) — `MacDeviceID` and `PhoneDeviceID` deleted; every site reads `DeviceIdentity.current.deviceId`/`.slug`; censuses against hostname identity and hand-built ids on both targets.
3. **`OpLogChain`** (`e8ded16d`, `d60fea3a`) — the pure wire format and verifier: `prev` as the first JSON key, seal lines, `genesis` for a fresh file, the per-line classification.
4. **The chained append** (`26a0f255`) — `ChainPolicy` on `JSONLAppendStore`, `OpLogDeviceState` (remembered heads, verified digests), the chain-head check before every write with foreign lines set aside as `.lines` records through `OpLogQuarantine`, seals every `OpLogStore.chainSealInterval` appends.
5. **The verified load** (`f0ce810c`, `63f38702`) — every line classified on both the async and the sync readers, the `.mzseg.sig` sidecar and the verify cache, `OpLogProvenance`, the table-driven `Hex` that took verification from ~450 ms to the chain's real cost.
6. **The Mac** (`4826bce9`) — seals on burst, close and open-time maintenance (before the segment seal), provenance stamped on `Document` at load, History's two sentences.
7. **The inbox** (`52a26e51`) — chained and sealed after every row on the Mac and the phone through one shared read/write path (`JSONLAppendStore.loadVerifiedStrict`).
8. **The phone** (`7cb9f89a`) — `AnnotationWriter` through the chained store with a seal per op, `CoordinatedFileIO.coordinatedAppendLine` deleted, the palette aim removed (`PaletteAimPicker`, the three `aim:` parameters, `paletteSubject`/`sense` no longer written — still decoded; the Mac still reads them for rows on disk).
9. **Docs** (`8baad8b2`) — ADR 0032, the OpLog/Stores/Phone area guides, CLAUDE.md tripwires 35–37, the History guide, roadmap, product, spec status.
10. **The whole-branch review's fix wave** (`105a0575`..`3cb2a239`, eight commits) — see below.

## What was measured

- **Enclave tests ran, not skipped, on this Mac** — in `DeviceIdentityTests` (package), and in the iPhone 17 simulator (`PhoneDeviceIdentityTests`, twice). CI's macOS VM runner and the Intel-era phone image take the unsigned-token path; the skips there are by measurement (`SecureEnclave.isAvailable`), never by platform guess.
- **Cost** (release, task 5's fixture, 50,000 chained lines in seven signed segments plus a 6,250-line tail; machine at load average 4.5): chain walk over the tail 55–83 ms; seven sidecar reads and signature checks ~3 ms; a real tail rotates at 512 KB (~600 lines) so a real open walks about an eighth of that. Before the hex fix the same walk cost ~450 ms — 107 of `lineHash`'s 109 ms was per-byte `String(format: "%02x")`. The end-to-end cold/warm/control readings (~6 s each) are `JSONDecoder` and are not a budget measurement. See Decisions owed #1 and #5.
- **Gates at merge:** `swift test` 839 (2 env-gated skips) / `./scripts/test.sh full` 8,312 passed, no skips beyond the standard env-gated and lock-state ones / `./scripts/test.sh phone` 245 / Release build green / warning census on branch files: zero from this branch (the one hit, `EditorHost.swift:724`, is from 2026-07-11).

## What Denver will see on first launch (writer-facing)

- **This Mac is a new device to its own history.** Its id was its hostname; it is now the key's fingerprint, so the slug changes and the app starts a fresh `<doc>.<16hex>-<8hex>.jsonl` beside the old hostname-slug file on the first keystroke. The old file is read as another device's — every word applies, as *unsigned history* — and is never appended to or sealed again. History shows *Part of this document's history was written before this book was signed.* once per document. The same is true of the phone's old `phone:<uuid>` file after its update.
- The one edge: a crash-recovery `pending` file partitioned under the OLD slug is not read after the upgrade. An updater relaunch follows a clean quit, which clears it.
- The dev and stable variants now hold different keys (separate Application Support folders), so they write different files. They shared one hostname slug before.

## The whole-branch review — the streak holds

The review (opus, over the twelve-commit diff plus the ledger) returned one Critical and seven Importants no per-task review could see:

- **C1** — `TaskDeriver`'s rebalance ops carry `device: "rebalance"`, so every Mac chained into ONE shared `<doc>.rebalance-<fnv>.jsonl` and the chained append's tail rewrite would truncate the other Mac's lines and accuse it of not being Maugham. Fixed: a device chains only its own file (`OpLogStore.append` attaches the `ChainPolicy` only when `op.device == identity.deviceId`; a sentinel op appends plain and unsealed, as before the milestone). The fix surfaced FOUR more sentinels — see Decisions owed #7.
- **I2** — truncate-to-the-last-seal-then-append was adoptable. Fixed by the crash-window rule: `OpLogDeviceState` remembers `previousHead` too; a remembered head absent from the file adopts only when nothing was remembered or the file's head is the previous one; otherwise lines after the last TRUSTED seal are set aside and the state stays put. Applied on the write path as well (a load-only rule would lose the writer's new ops on the next open) and a no-op where no trusted seal exists (an unsigned device's file is unsigned history, not a forgery) — both pinned, both in ADR 0032 §3.
- **I3** — a migrated or re-keyed Mac kept stale heads and would quarantine its twin's live ops. Fixed: `op-log-state.json` carries the identity fingerprint; a mismatch starts empty.
- **I4** — Tasks 7 and 8 had made both phone writers `@MainActor`, dragging multi-megabyte asset writes onto the main thread. Fixed: writers nonisolated, one main-actor hop for append+seal, asset writes pinned off-main.
- **I5** — `__project__` was chained but never sealed (a fresh `OpLogStore` per append). Fixed: `ProjectStore` holds one store; `sealChain` accepts the project stream; `sealTailIfNeeded` still refuses it (Decisions owed #4 — since answered: it refuses nothing as of 2026-09-09, and the project stream rotates at the open sweep).
- **I6** — tripwire 37 had no census. Fixed: `test_sealLinesAreRecognisedInOpLogChainOnly` on both targets, with planted offenders.
- **I8 + the torn-tail seam** — a torn LAST line in a foreign mid-sync file read as a break and its `.lines` record was surfaced nowhere for the inbox. Fixed: a torn last line is `tornTail` (skipped to `diagnostics.skipped` as before, never a `.lines` record); `InboxPane.setAsideNotice` says what the inbox held back.
- **M1/M2** — a restored Mac re-mints on the enclave rather than dropping to the token; dead-pid test leaves are swept. **M3/M4/M7/I7** — prose corrections in ADR 0032 and the area guide (a signed segment settles legacy lines as verified; the `.sig` sidecar contributes nothing to `BackupSignature`; an integrity check classifies keylessly and can pass opIds the load will not apply; the budget was not met as stated).

The scoped re-review of the wave (sonnet) returned **all findings addressed, no new Critical or Important breakage**; it accepted both I2 departures on inspection of the write-path code and the crash-window logic, and confirmed the three new lock-guarded test seams are justified.

## Rulings made during execution (Denver can undo any of them)

- Segment signatures live in a `.mzseg.sig` sidecar, not a new container version — additive, no reader of MZS1 breaks, no paired release forced.
- `prev` is a wire key inserted textually as the first JSON key, never an `Op`/`InboxEntry` field.
- CI runners are assumed enclave-less; every verified-path test injects the software signer.
- A fresh file's chain starts at `OpLogChain.genesis`, so its first line is sealed too.
- Nil-default callers of `loadFileDiagnosed` (`ProjectIntegrity.check`) classify but never write a `.lines` record.
- Tripwire 37 was given its census in the fix wave rather than deferred.
- C1, I2, I3, I4, I5, I8 as described above; M1/M2 taken in the wave; M5/M6/I7 recorded here rather than coded.

## Smoke (Denver)

1. Launch the dev app → open a real project → type one sentence → `.maugham/ops/` gains `<doc>.author-<16hex>-<8hex>.jsonl` beside the hostname-slug file (the `author-` prefix is P1b's; a P1 build wrote the same file without it); the old file's byte count no longer changes.
2. Wait a burst (30–90 s) → the new tail's last line begins `{"seal":`.
3. ⌘Q, relaunch, reopen → the words are intact; History (⌘⌥H) shows *Part of this document's history was written before this book was signed.* and nothing else new.
4. With the app open, append any JSON line to the new tail from a shell (`echo '{"op_id":"x"}' >> .maugham/ops/<doc>.author-<16hex>-<8hex>.jsonl`) → reopen the document (or wait for the presenter) → History shows *1 change was written to this document by something that is not Maugham; kept in backup, not applied.*; the editor shows nothing new; `.maugham/conflicts/quarantined-ops/` holds a `.lines` file and its `.quarantine.json`.
5. Type one more sentence → the tail no longer contains the foreign line; the archive still does.
6. Open a second Mac or the Statistics/Integrity check: nothing red; the check writes no record.
7. Phone: update, capture a text note → the Mac's Inbox shows it; the phone's manifest has a seal line after the row. Open Annotations, accept one → the Mac applies it; History counts it as unsigned history from another device. **Allow iCloud a few minutes** — on the 2026-09-08 run the accept took ~10 min to reach the Mac and the note under one; both arrived as `<doc>.author-<phone hex>-…jsonl` / `inbox.author-<phone hex>-…jsonl`, chained from genesis and sealed under the phone's key (verified 2026-09-08 23:55).
8. Publish → Compile still works (segments with `.sig` sidecars beside them).
9. **(P1b) The assistant is its own writer — and that call is when its key comes
   into being.** `LocalIdentities` is lazy (P1b's whole-branch review, C1): a key
   exists once a WRITER has named its actor, so before this step
   `~/Library/Application Support/<supportFolderName>/device/` holds
   `device-key.blob` (the author's) and nothing else. Look, then act. With the
   document open, ask Claude Desktop for a comment on it (`add_comment`) →
   `device-key.assistant.blob` appears in that folder, and `.maugham/ops/` gains
   `<doc>.assistant-<hex>-<8hex>.jsonl` beside the author's — a shorter hex run than
   the author's, because `DeviceSlug.make` caps its prefix at 24 characters and
   `assistant-` is ten of them — and its last line
   begins `{"seal":`. Reopen the document → History (⌘⌥H) says **nothing** about
   another device: the assistant's key is this Mac's own, so Claude's note is
   this Mac's signed history rather than somebody else's unsigned history.
   **And this holds whether the document is open in the editor or not — the
   open-document path is the one the smoke caught** (2026-09-08): the closed-doc
   arm transient-loads as the assistant, but the open one writes through the
   `Document` the editor loaded as the author, so Claude's note used to land in
   the author's file under the author's key. `Document.addAnnotation` now stamps
   the actor off the note's own author, so ask for the comment with the chapter
   OPEN and check the assistant's file gains it — then accept or reject it from
   the margin and check THAT op is in the author's file, because disposing of
   Claude's note is the writer's act.
10. **(P1b) The translator is its own writer.** On a project with a translated
   edition, run `write_translation` (or a pipeline round from the Publish desk)
   → `.maugham/translations/`'s op files gain
   `<doc>.<lang>.translator-<hex>-<8hex>.jsonl`, its last line a seal. Then
   purge a paragraph from the Translation Review pane → that edit lands in the
   **author's** file for the same `(doc, language)`, because the writer's
   decision is the writer's; both files merge and the pane reads what it read
   before.

## Decisions owed

0. **An unreadable translator file reads as absent, and P1b sharpened what that
   costs** (P1b's whole-branch review, M5). `TranslationStore.loadMerged` warns
   and `continue`s over a device file it cannot read — RULING-54's forbidden
   shape, pre-existing and deliberately documented. With two actors' files per
   `(doc, language)` since P1b, an unreadable TRANSLATOR file now shows a
   *partly* translated document rather than an untranslated one, because the
   author's own file for the same pair still reads. Not a branch defect, and
   named here rather than left unremarked. **Should a device file that is
   present and unreadable refuse the read loudly, as the op log's own strict
   reader does?**

1. **The 100 ms budget at 50k lines was not met as stated.** The plan's global
   constraint 3 says "50k ops must add under 100 ms to a cold open". Task 5's
   first measurement of that fixture added roughly **450 ms end to end**; after
   the hex fix the chain's own work is **55–83 ms** on a tail eight times the
   size `segmentSealThreshold` lets a real one reach, and the end-to-end delta
   sits inside the parse's own noise (the load is ~5.8 s of `JSONDecoder`). The
   implementer's reframe — that the budget is really about a realistic
   per-document op count — may well be right, but it is a change to an
   acceptance criterion made by the implementer. **Is the reframe accepted, and
   what is the budget restated against?** As this was written, ADR 0032 and
   `Maugham/OpLog/AREA.md` said what was measured and that the budget was not
   met; neither claimed it was.

   **Decided 2026-09-09:** the reframe is accepted, and the budget is restated
   as the chain's own cost read directly by the fixture, never an end-to-end
   subtraction — under **20 ms** on a realistic tail (≤ 512 KB, ~600 lines) and
   under **100 ms** on the fixture's 8×-oversized 6,250-line tail. Both hold: the
   walk measures **33.9 ms** on the fixture, and the realistic figure is DERIVED
   from it at ≈ 3.4 ms and labelled derived wherever it appears. Landed in
   ADR 0032's Consequences (the verification-cost bullet) and
   `Maugham/OpLog/AREA.md`'s "Where the time goes"; full tables in
   `docs/superpowers/notes/2026-09-09-perf-step-measurements.md`. Neither
   document says "not met" any more.

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

   **Decided 2026-09-09: prune-only, at load.** `OpLogDeviceState` now records
   the project ROOT beside each head (the key hashes that path and cannot be read
   backwards) and drops, at load, every entry whose recorded root no longer has a
   `.maugham` child; an entry with no recorded root is kept until its next
   `remember` records one. The whole-file rewrite shape is unchanged, and the
   persists were deliberately NOT coalesced: the head is written before the batch
   by design (ADR 0032 §3's crash window), so deferring it would turn a crash
   into a set-aside of the writer's own words — and it is already one persist per
   BATCH, not one per line, now pinned by a lock-guarded `persistCountForTesting`.
   Commit `296ada6c`; ADR 0032 §3.

   **Still open for Denver:** an UNREACHABLE root is pruned like a deleted one.
   A project on a detached external drive loses its remembered heads at launch,
   and the next load adopts the file's own head — the safe direction, and the same
   thing a moved project already gets — but *unreachable ≠ deleted* is a
   distinction Denver may want drawn.

4. **The project stream has no size ceiling.** `__project__` now seals like every
   other stream (review I5), but `sealTailIfNeeded` still refuses to rotate it —
   a recorded decision — so its tail grows without limit and the chained
   append's verify cost grows with it. Pre-existing growth, new cost. **Should
   the project stream rotate into segments, and if so what owns the boundary?**

   **Decided 2026-09-09: it rotates, at the same 512 KB** — one constant,
   `OpLogStore.segmentSealThreshold`, not two — **and the project-open sweep owns
   the boundary alone.** A document rotates at close and the project stream has
   no close, so open is its moment: the sweep in `DocumentStore.open` names
   `__project__` by hand and takes it last, because the manuscript-id reader
   `docIds(inOpsDirectoryFilenames:)` excludes it by contract and still does.
   `sealTailIfNeeded`'s `guard docId != "__project__"` is gone, so neither verb
   refuses the project stream now. The accepted residue: in-session growth past
   512 KB (some 2,500 task ops) waits for the next open. Commit `4543b1a4`;
   ADR 0032 §4 and its Consequences. This decision's heading is now false — the
   project stream has a ceiling.

5. **The cost fixture wants one re-run on a quiet machine.** The numbers in
   ADR 0032 and the AREA guide come from a run taken while other work was on the
   box (ledger L56). They should be re-taken once and quoted durably.

   **Decided 2026-09-09: done, twice over.** Three quiet-machine runs before the
   step (`8e9aabf7`) and three after (`4543b1a4`), with no `xcodebuild` running
   and the load averages recorded for each, all five printed quantities per run,
   a min row and a delta table. They live in
   `docs/superpowers/notes/2026-09-09-perf-step-measurements.md`, and the min rows
   are quoted in ADR 0032's Consequences and `Maugham/OpLog/AREA.md`. Headline:
   the cold verified load went 5934.2 → 514.6 ms and the chain walk 48.9 →
   33.9 ms.

6. **The truncation rule is closed at P1 only where a seal exists.**
   `OpLogChain.resolveAbsentHead` quarantines a forged tail back to the last
   seal this device TRUSTS, so an unsigned device (no enclave) is not protected
   at all — deliberately, because quarantining a whole unsigned file over a
   missing head would cost the writer their manuscript to catch nobody. The
   honest close is P2's registry plus a rule that an adopted head must be at or
   descended from the last trusted seal. **Confirm that P2 carries it.**

7. **RESOLVED 2026-09-08 — the four sentinel device strings are gone, and a
   device is four writers.** The question was whether `"wiki-rename"`,
   `"find-replace"`, `"mcp"` (twice) and `"rebalance"` should pass this Mac's
   own device id so their streams are signed. Denver ruled wider than the
   question: *"lets use the terminology 'assistant' for anything through the
   mcp … translations get a special role of 'translator' … optimisations should
   be signed as Maugham itself … search and replace is an automation of the
   writer."* So the answer is not one key but four — `DeviceActor`'s `author`,
   `assistant`, `translator` and `maugham`, each holding its own enclave key
   under the same `device/` folder and writing its own per-doc file — and a
   production `Document.load` names an ACTOR rather than a device string
   (tripwire 38). The two MCP sites load `.assistant`, the two automations of
   the writer's hand load `.author`, `write_translation` and the pipeline load
   `.translator`, and the rebalance signs as `maugham` with
   `TaskDeriver.rebalanceSentinel` surviving as the SESSION marker alone. Which
   file an op lands in did change; nothing is lost, because ops merge by opId.
   Built as the P1b slice (branch `claude/signed-op-log-p1b-actors-2026-09-08`);
   see [ADR 0032](../../adr/0032-the-signed-op-log.md)'s Actors addendum and the
   spec's §4.1.

8. **A Mac with no Secure Enclave is silently unsigned.** It writes chained
   lines that nothing seals and says nothing about it anywhere. **Should History
   say so once per project?** (Carried from the plan's own list.)
