# A Promotion Carries the Piece's History, Notes and Translations — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promoting a Collection piece to its own project copies the piece's whole record into the new project: every device's op-log stream, its intent statement's stream, its translations and translation rounds, the checkpoints that name it, and the Collection's register those lines are judged by. In the new project the writer sees and rewinds the piece's full history, every note still anchors to its paragraph, and every translation still lines up. The Collection keeps everything it had: the piece's row becomes a reference whose History shows the record up to the promotion, read-only, with **Open the Project** for what came after.

**The size, stated plainly:** eight tasks. No schema bump, no new `OpKind`, no change to any persisted format, and **no paired Mac + phone release**. Task 7 changes the phone and needs a phone release of its own (not paired: an older phone only lists an archived piece's notes twice). The mechanism is a **byte copy under the same document id, carried with the register** (Architecture). A cheaper version leaves out Task 4, the register carry. Its cost: in the new project every line sealed by a device other than this Mac is *held* until that device is admitted there, so a paragraph typed on the writer's other Mac, or by a collaborator, is missing from the promoted piece when it first opens. That is a regression on today, where the `.md` carries those words. **Not recommended.**

**Architecture:** The three candidates, judged against the code:

- **(a) Copy the piece's streams byte for byte, under the same doc id, with the register. CHOSEN.**
  - Every op line carries its `docId` (`Op.swift:7`) and is hash-chained and sealed over its bytes (`OpLog/AREA.md` "Chain, identity and seals"). So a byte copy is only valid if the promoted document keeps the piece's id, and Task 1 makes it keep it.
  - A permit mark and the unsigned snapshot name streams as `<docId>.<slug>` (`PermitMark.stream(of:)`, `PermitMark.swift:140`), so keeping the id also keeps every piece-scoped permit and mark meaning what it meant.
  - The new root path has no remembered head (heads are keyed by project-root path: "a moved project forgets", `OpLog/AREA.md`). `OpLogChain.resolveAbsentHead` (`OpLogChain.swift:1347`) returns at its first guard when nothing is remembered, so the copied files walk exactly as found. Each device's next append chains onto its own copied tail. This is the path an ordinary moved project already takes.
  - Verdicts come from the register. `TrustTable.verdict(forSealKey:)` (`TrustTable.swift:500`) answers `.stranger` for any key the new project's register does not know. That is why the register travels too (Task 4), as already-signed bytes through `RegistryWriter.restore` (`RegistryWriter+Restore.swift:29`), the existing door for bytes signed elsewhere. Nothing is re-signed, so no key material is invented (tripwire 36).
  - Keeps: the op log as the source of truth; append-only; every line's original signer and actor; ¶id identity; one appending device per file after the copy (tripwire 17, see Task 3); Rewind, History and checkpoint restore over the pre-promotion past.
- **(b) Replay the history as new ops by the promoting author. REJECTED.**
  - It re-signs other people's lines with the author's key. A collaborator's note becomes the writer's (`AnnotationOwnership`, Restore standing by key).
  - Worse, a line that is *held* or *set aside* in the Collection becomes `.mine` and applies. That launders a stranger's words past the register, which is the one thing ADR 0032 exists to stop.
  - It also costs one signed append per op.
- **(c) A read-only archive beside a fresh bootstrap. REJECTED.**
  - Bootstrap from a clean `.md` mints new ¶ids, because ADR 0019 keeps anchors off disk. So every note and translation, both keyed by ¶id, would be orphaned in the live document.
  - It fails "notes and translations", and the history could not be rewound.

The one live record then lives in the new project, and the Collection keeps its own copy, frozen as an archive (Task 6). No format changes: the copies are byte-identical, carried checkpoints and rounds are ordinary rows of existing types, and the manifest is unchanged in shape (only the item id's value differs from today's freshly minted one).

**Tech Stack:** Swift, SwiftUI, AppKit; MaughamCore (Tasks 2 and 7); MaughamPhone (Task 7). No new dependency.

**Spec:** the owner's ruling, 2026-11-22, verbatim:

> "I think the history should survive in the original — it would be nice for the promoted version to also have the history, notes and translations."

Recorded in ADR 0038 (`docs/adr/0038-status-editions-and-translation.md`) at :247 ("Also answered on 2026-11-22") and :271 ("the promoted project gets a copy of the piece's op log, notes and translations, the Collection keeping its own"). §10 there (:140–148) is the promotion door this plan builds on (tripwire 59). ADRs 0012 (per-device JSONL), 0016 (segments), 0019 (clean `.md`), 0023 (undo), 0024 (translation layer), 0032 (the signed op log, its addenda on actors, admission, permits, scope and the person key). The gap this closes is the "Pre-existing" section of `.superpowers/sdd/2026-11-21-shell-p4/task-11-review.md`.

Every signature below was read at `7b542fee`. A name marked **new** is created by the task that lists it under Produces.

## Where this belongs

**On its own branch, cut from `main` after the shell milestone merges** (`claude/promotion-carries-history`). Recommended over landing it on `claude/shell-without-personas`, for four reasons:

1. **It depends on the shell branch's promotion.** The hold, the door and `PiecePromotionFailed` exist only on that branch, so the work cannot go on `main` earlier.
2. **It changes MaughamCore and needs a phone release.** Plan 4 states "MaughamCore unchanged", and the shell milestone is not set up to carry a phone release.
3. **It is data-integrity work in the op log.** It deserves its own whole-branch review and its own smoke, not a slot at the end of a window redesign.
4. **It is independent of the window redesign.** Only Task 6 touches the shell's surfaces (History, the reference card), and those are stable after plan 4.

## What a piece's record is, and what happens to each part

Verified by reading the stores at `7b542fee`, except where marked.

| Part | Where it lives | Promotion |
|---|---|---|
| Op-log streams, every device: tail `.jsonl`, sealed `.mzseg`, `.mzseg.sig`, the legacy unsuffixed file | `.maugham/ops/<docId>…` (`OpLogFiles.opLogFileURLs(forDocId:in:)` :72, `segmentSignatureURL(for:)` :118) | **Carried**, byte-identical, same names (Task 3). The legacy file is copied, never sealed or appended to (tripwire 17). |
| Annotations: comments, suggestions, queries, to-dos, compiler, editor and translator notes, and their dispositions | Ops inside the doc's own log | **Carried** with the log. They anchor by ¶id and span anchors inside it. |
| Task anchors and task ops | The doc's own log (`Document+Tasks.swift`) | **Carried** with the log. |
| `.checkpoint` breadcrumbs | The doc's own log (`CheckpointCapture.swift:77`) | **Carried** with the log. |
| Project-scope checkpoints (`docPointers` doc → op) | `.maugham/checkpoints*`, per device, unchained (`CheckpointStore`) | **Carried, narrowed** to rows that name the piece, with `docPointers` cut to the piece and its intent (Task 5). |
| The intent statement and its stream | `intent/<slug>.md` plus `.maugham/ops/<stmtId>…` | **The file moves (as today); its stream is carried**, and it keeps its `stmt-` id (Tasks 1, 3). |
| Translations | `.maugham/translations/<docId>.<lang>.<slug>.jsonl`, chained, keyed by ¶id (`TranslationStore.swift:24`) | **Carried**, byte-identical (Task 3). |
| Translation rounds, with their departures and letters | `.maugham/translations/rounds/<lang>.json`, per-language ledger keyed by `docId` (`TranslationRoundStore.swift:63–68`) | **Carried**: the piece's rounds are appended in number order (Task 5). |
| This device's pending file (a failed flush's words) | `.maugham/pending/<docId>.<slug>.pending.jsonl` (`PendingBuffer.swift:222`, private) | **Carried** when present: this Mac's only, never another device's (Task 3). |
| The register: devices, people, claims, permit events | `.maugham/devices`, `.maugham/people{,/claims,/events}` (`RegistryWriter.swift:38–52`) | **Carried whole**, verified records only, as signed bytes (Task 4). |
| `StructureItem.startedBy`, `passStates`, tags, links, targets | Manifest | **Carried** (as today, `writePromotedManifest` :921). |
| Figures | Manifest and figure streams | **As built**, re-created by `writeCarriedFigureStreams` (plan 6c rulings Q-4 to Q-6). A figure's own history and notes do not travel (`OpLog/AREA.md` Figures). Not this plan. |
| Research, table sidecars, versions, note records | `research/` and `.maugham/research-*` | **As built** (moved by steps 4, 4c, 4c-2, 4c-3). |
| Quarantine records (`.file` and `.lines`) | `.maugham/conflicts/quarantine/` | **Left in the Collection.** `.lines` records are re-derived by the new project's first load (the coordinated reader records them). A `.file` record's bytes are not in `ops/`, so they are not carried. The success notice says so when one is held (Task 3). |
| Conflict backups | `.maugham/conflicts/` | **Left** (forensic; the original keeps them). |
| Compiler diagnostics sidecars | `.maugham/diagnostics/<docId>.<slug>.json` (`DiagnosticsStore.swift:983`) | **Left.** They are derived. The findings themselves are annotations and travel in the log. The next check regenerates them. |
| `__project__` stream (book-level tasks and checkpoints breadcrumbs) | `.maugham/ops/__project__…` | **Left**: the Collection's book, not the piece. |
| Sessions, statistics, the bible, the declared world, canvas, editions and publish config, lessons | `.maugham/sessions.json`, `bible.<slug>.json`, `derived/`, `canvas.json`, `publish/` | **Left**: book-level. Canvas cards bound to the piece still name its id in the Collection, which keeps the same id. |
| Statement proposals | `.maugham/statements/proposals/` | **Left** (staging for a statement, not its record). |
| Device-local memory: remembered heads, `ForeignStreamWatch`, joined root, segment digests | App support, keyed by project-root hash | **Regenerated**: a new root starts empty, as a moved project does. |

**Identity.** The promoted document keeps the piece's doc id and the intent keeps its `stmt-` id (Task 1). Tripwire 18 is untouched: ids are reused verbatim and never prefixed. A ¶id is unique within its document (`mintUnique(excluding:)`), so a carried log keeps every ¶id unique. The Collection's reference row has always kept that same id (`convertPromotedPieceToReference` :1032–1043 changes only the kind and path). Two projects now hold the same doc id. Nothing in the app resolves a doc id across projects:
- MCP addresses a project by path (`ProjectIdentifier`).
- Device memory is keyed by project root (`RegistryCache.projectKey`, `OpLogDeviceState.scopeHash`).
- The reference row never loads the linked project's documents (`ProjectStore+References.swift`).

Task 1's census is how that claim is checked, not assumed.

## Global Constraints

- The hard invariants in `CLAUDE.md` stand.
  - **The op log is append-only:** nothing is rewritten, re-signed or re-chained. A copied file is byte-identical, and the task verifies that before anything is committed.
  - **The text of the promoted piece derives from the carried log**, never from the `.md` (tripwire 20). The moved `.md` is only the first render.
- Nothing is copied into a live project. Every new file is written into the promotion's staging tree (`ProjectStore+CollectionPieces.swift:452`), so the existing rollback's removal of that tree takes it back. Copies are not moves: nothing is added to `stagedMoves`, and the Collection's originals are never touched.
- No hand-built device slug (tripwire 24): a copied file keeps its own listed name, and a carried checkpoint is routed by `CheckpointStore.append` (`CheckpointStore.swift:100`), which builds the name. Each listed name reaches the disk through `SafeRelativePath` (tripwire 58).
- No new registry writer file. The carry is a call in `RegistryCache.swift`, and `TripwireGrepTests.registryWriterCallers` (:10358) is unchanged in members, with its reason amended (tripwires 40, 41).
- Hide, don't disable; ask `Posture` (tripwires 47, 51). Notices go through `MaughamEvent` with a scope (tripwire 21). The toast holds one sentence (`OpLog/AREA.md`, "The coalescing rule").
- Tests run against real stores on disk under `TestTemp.root` (`TestTemp.workerRoot` for a class fixture). Signed lines use the test identities `DeviceIdentity+Testing.swift` provides, injected as the trust suites do; read `PendingLoadTests` and `RegistryArrivalTests` for the fixture before writing a new one. CI's runner is unsigned, so a seal assertion injects a signer (`OpLog/AREA.md`).
- Tests are pure functions, censuses or real-store round trips read synchronously. **Never press a control and wait for its effect** (tripwire 33).
- `DocBudgetTests` (`Packages/MaughamCore/Tests/MaughamCoreTests/DocBudgetTests.swift`): every AREA.md and CLAUDE.md is at its word ceiling. Every added line is paid for by a cut in the same file. Never raise a ceiling.
- No test-data migration (tripwire 11). One branch. Every task builds final behaviour. No task merges, pushes or tags.
- **Every implementer, every task:**
  - run `./gen.sh` after adding or deleting any file;
  - run `./scripts/test.sh` **in the foreground** with a 600000 ms timeout, never in the background and never raw `xcodebuild test`;
  - when MaughamCore is touched (Tasks 2 and 7), also run `./scripts/test.sh core` and `./scripts/test.sh phone`;
  - commit before reporting.
- Every commit message ends with exactly these two lines:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01JEo1ZYgKJdJbx2qYrUfkzw
  ```

## Review Focus

1. **A collaborator's and a second Mac's lines in the promoted project.** Each must settle exactly as it does in the Collection: applied, held or set aside, never widened (Task 4). A held line in the Collection must still be held, never applied because it moved.
2. **The first append after the copy, per device.** This Mac's next burst chains onto its copied tail with no set-aside. A second Mac opening the synced project chains onto its own copied file. Nobody appends to a file another device seeds after that device has it (Task 3).
3. **Failure at every step.** The Collection's files are byte-identical before and after, and the staging tree holds only copies (Tasks 3–5).
4. **The Collection's archive.** Nothing can write a reference's log: Rewind, Restore, the editor, Replace, MCP and the phone. The archive's History still reads the piece's record (Task 6, Task 7).
5. **A stale `.md` in a closed piece.** The promoted text is the log's, a peer's synced ops included (Task 8).

---

### Task 1: The promoted document and its intent keep their ids

Today the promotion mints `newDocId` (`ProjectStore+CollectionPieces.swift:371`), and `writePromotedManifest` mints a fresh `stmt-` id for the intent (:959–962). With fresh ids no carried line can join, so both keep the piece's own.

**Files:**
- Modify: `Maugham/Stores/ProjectStore+CollectionPieces.swift`:
  - :368–371: the new document's id is `pieceId`; `newDocId` goes.
  - `writePromotedManifest` (:921): the carried statement keeps `carriedIntent.id`, re-scoped `.document(pieceId)` (it already is the piece's).
  - `repointedForPromotion(_:newDocId:)` (:870): called with `pieceId`. Rename the label to `docId:`, a pure rename.
  - The doc comments at :954–957 and :749–753 are rewritten.
- Modify: `Maugham/Stores/AREA.md` :251 ("re-scopes it with a fresh `stmt-` id"), paid for in the same file.
- Create: `MaughamTests/Collection/PromotionKeepsIdsTests.swift`.

**Consumes:** `promotePieceToProject(pieceId:destination:afterStaging:)` (:329), `writePromotedManifest(...)` (:921), `Statement(id:kind:scope:path:)` (as called at :960), `resolveDocId(for:)` (`Document+Load.swift:771`: the load finds the id by path in the manifest).

**Produces:** a promoted manifest whose one structure item has `id == pieceId`, and whose statement (if any) has `id == carriedIntent.id`.

**Contract:**
- `test_thePromotedDocumentKeepsThePiecesId`: promote a piece with an intent and a figure; the promoted manifest's item id is the piece's id, its statement id is the Collection's, and a carried figure's `piece` names that id.
- `test_theReferenceRowAndThePromotedDocumentShareTheId`: after success, the Collection's reference row id equals the promoted item id.
- **The census of cross-project doc-id state** (step 1): before changing a line, grep `Maugham/` and `Packages/MaughamCore/Sources/` for app-scoped stores keyed by a doc id:
  - `static var` / `static let` dictionaries keyed by `String`;
  - `UserDefaults` keys built from an id;
  - `RegistryCache` and `OpLogDeviceState` entries.

  The report lists each one found and why it is per-project, or a fix. Already read and per-project: `RegistryCache.projectKey`, `OpLogDeviceState.scopeHash`, `ProjectIdentifier`, `.maugham/ui-state`. If one is not per-project, stop and report; do not widen the task.

- [ ] **Step 1:** The census above, written up in the report.
- [ ] **Step 2:** Write the two tests; expect red.
- [ ] **Step 3:** Make the change. The promoted project still bootstraps from its `.md` until Task 3, under the old id, with no log in the new root, so behaviour is unchanged for the writer.
- [ ] **Step 4: Disable experiment.** Put `Self.newId(prefix: "doc")` back at :371; both tests go red. Restore.
- [ ] **Step 5:** `./gen.sh`; `./scripts/test.sh` (foreground, 600000 ms). Commit `promotion carries history task 1: the promoted piece and its intent keep their ids`.

---

### Task 2 (MaughamCore): The one list of a document's history files

What counts as a document's history on disk is decided in Core (`OpLogFiles`, single source of truth for the filenames). The copy must ask that list, not restate it. The test for an iCloud placeholder is also Core's, and it is internal (`StreamPositions.nameBehindICloudPlaceholder`, `StreamPositions.swift:647`; `OpLogStore`'s forwarder at :1101 is `nonisolated static`, not public).

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/HistoryCarry.swift`, **new** `public enum HistoryCarry`.
- Modify: `Packages/MaughamCore/Sources/MaughamCore/AREA.md` (one Map line, paid for).
- Create: `Packages/MaughamCore/Tests/MaughamCoreTests/HistoryCarryTests.swift`.

**Consumes:**
- `OpLogFiles.opsDirectoryListing(in:)` (:81) and `opLogFileURLs(forDocId:among:)` (:90);
- `OpLogFiles.segmentSignatureURL(for:)` (:118);
- `TranslationStore.directoryURL(in:)` (:15) and `parseFileName(_:)` (:44, internal, same module);
- `StreamPositions.nameBehindICloudPlaceholder(_:)` (:647).

**Produces:**
- **new** `HistoryCarry.files(forDocIds: [String], in projectURL: URL) throws -> [String]`. It returns project-relative paths (`.maugham/ops/<name>`, `.maugham/translations/<name>`) for:
  - every op-log file of each id;
  - each segment's `.sig` where present;
  - every translation file whose parsed doc id equals one of the ids.

  The result is sorted and has no duplicates.
- **new** `HistoryCarry.NotDownloaded: LocalizedError` (`names: [String]`). Thrown when a `.<name>.icloud` placeholder stands for any of those files. Its sentence reads: "Some of this piece's history hasn't finished downloading from iCloud. Try again in a moment."

**Contract:**
- Pure listing; reads no file contents. `__project__`, the pending files, other doc ids, and a doc id that is a dotted prefix of another (`doc.a` vs `doc.a.b`) are excluded. The last is pinned against `parseFileName`'s reconstructed-id rule.
- `test_listsEveryStreamSegmentSignatureAndTranslation`, `test_excludesProjectStreamAndOtherDocs`, `test_aPlaceholderRefusesWithItsName`, `test_aLegacyFileIsListed`.

- [ ] **Step 1:** Tests; red.
- [ ] **Step 2:** Implement.
- [ ] **Step 3: Disable experiment.** Drop the `.sig` arm; `test_listsEveryStreamSegmentSignatureAndTranslation` goes red. Restore.
- [ ] **Step 4:** `./gen.sh`; `./scripts/test.sh core`, `./scripts/test.sh`, `./scripts/test.sh phone` (each foreground, 600000 ms). Commit `promotion carries history task 2: Core's one list of a document's history files`.

---

### Task 3: The piece's streams, its intent's stream, its translations and this Mac's pending file are copied into the staging tree

**Files:**
- Create: `Maugham/Stores/ProjectStore+PromotionCarry.swift`, **new**. The carry steps, a nonisolated copier, and the failure seam.
- Modify: `Maugham/Stores/ProjectStore+CollectionPieces.swift`:
  - a pre-flight before step 1;
  - a new step 4e after 4d (:524) and before `afterStaging?()` (:528);
  - the success notice's sentence.
- Modify: `Maugham/OpLog/PendingBuffer.swift`: **new** `static func fileURL(docId: String, deviceSlug: DeviceSlug, in projectURL: URL) throws -> URL`, which `file()` (:222) then calls. One spelling of the name.
- Modify: `Maugham/Views/ProjectWindow.swift` (:1334–1360): one notice before the call ("Promoting “X” and its history…") and the success notice's wording.
- Create: `MaughamTests/Collection/PromotionCarriesHistoryTests.swift`.

**Consumes:**
- `HistoryCarry.files(forDocIds:in:)` (Task 2);
- `withdrawForPromotion(path:)` (`DocumentStore.swift:1890`). It closes and flushes the piece (`closeFlushAndUnregister`), and the close seals this Mac's chain (`OpLog/AREA.md`, "At close and open the chain seal runs BEFORE `sealTailIfNeeded`");
- `loadManuscript(...)` (:1960), the door that refuses MCP, Replace and the sweep while the path is held, so no local append lands in the piece's log mid-copy;
- `Self.resolvedProjectPathToChange(_:under:)` (as called at :760);
- `SafeRelativePath.resolve(_:under:)` (:74);
- `OpLogQuarantine.records(forDocId:in:)` (:512);
- `LocalIdentities` / `DeviceIdentity.author.deviceId` → `DeviceSlug.make(from:)` for this Mac's pending name;
- `beforeSidecarStagingForTesting` (:849) as the precedent for a throwing static seam.

**Produces:**
- **new** `ProjectStore.carryHistory(docIds: [String], into staging: URL) async throws`. It copies every listed file to the same relative path under `staging`, then this Mac's pending file for the piece if present. It runs off the main actor: a detached task over a `nonisolated static` copier that coordinates each read and write (`NSFileCoordinator`, presenter `nil`; the window's presenter classifies staging paths as `.otherProjectFile`, per the Task 11 review). Then it verifies each copy's bytes equal its source (SHA-256 through `ContentHash` if it fits; read it first) and throws **new** `HistoryCarryMismatch(name:)` on a difference.
- **new** `static var beforeHistoryCopyForTesting: ((String) throws -> Void)?`, nil in production, run before each file with its relative path.
- `PiecePromotion` gains **new** `historyLeftBehind: Bool`: a `.file` quarantine record was held for the piece or its intent. The window's success sentence then adds "History Maugham couldn't read stays in the Collection."

**Order inside the promotion:**
1. **Pre-flight**, before `withdrawForPromotion`, so a refusal moves nothing: `HistoryCarry.files(forDocIds: [pieceId] + [carriedIntent?.id])` throws `NotDownloaded`. That error is thrown as itself: nothing moved, so it is not a `PiecePromotionFailed`.
2. **Step 4e** runs inside the `do` (:487), so any throw reaches `rollbackPromotionStaging` (:612). That removes the staging tree when every move-back succeeded; the copies were only in staging. On `.keptIn` the copies stay with the tree; they are duplicates, and nothing is lost.

**Why one copier, and why a seeded file keeps tripwire 17:**
- A copied file keeps its name, so `<docId>.<slugB>.jsonl` stays Mac B's.
- This Mac writes it once, into a tree no device can see until step 7. From then on only B appends to it, chaining from its copied tail: B has no remembered head for the new root, so `resolveAbsentHead` returns unchanged.
- No file has two appending devices, and this Mac never seals another device's file or the legacy one.

**Stated limits, said in the report and in Task 8's register entries:**
- Lines a peer wrote that had not reached this Mac at the copy, and lines appended to the Collection's log after the copy (a peer typing in the piece before the manifest change syncs to it), are in the Collection only. Its archive shows them (Task 6).
- A torn last line in another device's file is copied as is; the reader already excludes it (`tornTail`).

**Contract (real stores, `TestTemp`):**
- `test_everyStreamOfThePieceAndItsIntentIsCopiedByteForByte`. Fixture: three device streams, one with two sealed segments and their `.sig`s, a legacy file, an intent stream, two languages of translations. Each file in the new project equals its source; the Collection's files are unchanged (bytes and mtimes).
- `test_thePromotedPieceOpensFromItsCarriedLog`. Open the new project through `DocumentStore.loadManuscript(..., actor: .author, ...)`: the text equals `DerivedManuscript.materialize(forDocId:in:)` of the Collection taken before the promotion. `ops.count` matches, and no `.bootstrap` op was emitted by the load.
- `test_thisMacsFirstBurstChainsOntoItsCopiedTail`. Type one burst in the promoted piece; a strict reload classifies every line of this Mac's file `.verified`/`.unsealed`, with no set-aside record.
- `test_aPendingFileIsCarriedAndFolds`. Leave a pending file for this Mac (the shape `PendingBuffer` writes, basis = the log's newest opId); after promotion the promoted piece's first load folds it. Another device's pending file is not copied.
- `test_aFailedCopyLeavesTheCollectionAsItWas`. `beforeHistoryCopyForTesting` throws on the third file. The error is `PiecePromotionFailed(.putBack)`, the Collection's ops, translations, `.md`, research and manifest are byte-identical to before, and no staging tree remains.
- `test_aPlaceholderRefusesBeforeAnythingMoves`. Plant `.<name>.icloud` for one stream: `HistoryCarry.NotDownloaded` is thrown, and the piece is still loose and open-able.
- `test_aHeldFileRecordIsSaid`. A `.file` quarantine record for the piece sets `historyLeftBehind`.
- **Measured, not asserted:** promote a piece with 20 segments and 5,000 ops across three devices. Record the wall time of step 4e on the dev machine in the report. If it exceeds 2 s, say so and stop; do not add a progress UI in this task. (`copyItem` clones on APFS; the cost is expected to be coordination, not bytes. Unmeasured.)

- [ ] **Step 1:** Tests; red.
- [ ] **Step 2:** `PendingBuffer.fileURL`; the copier; the pre-flight; step 4e; the notices.
- [ ] **Step 3: Disable experiments.**
  - (a) Skip the byte verification: add a test that truncates one copy inside the seam's next call and sees `HistoryCarryMismatch`; it goes red. Restore.
  - (b) Move step 4e out of the `do`: `test_aFailedCopyLeavesTheCollectionAsItWas` goes red (the tree remains). Restore.
- [ ] **Step 4:** Censuses this trips, each amended with its reason, never widened silently:
  - the `// internal-move:` / raw-file-op census (`TripwireGrepTests.test_noRawMoveOfUserContentOutsideTypedMover`, tripwire 14). A copy into staging is not a move; if the census flags `copyItem`, add the site with the marker `// internal-copy: promotion staging` and its reason;
  - `test_syncedPathsReachTheDiskOnlyThroughSafeRelativePath` (58);
  - `test_everyManuscriptLoadPassesThePromotionDoor` (59). The tests load through the door; production adds no `Document.load(`.
- [ ] **Step 5:** `./gen.sh`; `./scripts/test.sh` (foreground, 600000 ms). Commit `promotion carries history task 3: the piece's streams, translations and pending words are copied into the staging tree`.

---

### Task 4: The Collection's register travels with the history

Without it, every key but this Mac's is a stranger in the new project (`TrustTable.verdict`, :500–520). With it, the new project's `TrustTable` is resolved from the same verified records, so each carried line settles exactly as it did in the Collection.

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/RegistryCache.swift`: **new** `public func carry(_ registry: Registry, into projectURL: URL, presenter: NSFilePresenter? = nil) throws -> [URL]`. It writes each `registry.sourceBytes` entry (`RegistryReader.swift:215`, `[RecordRef: Data]`) through `RegistryWriter.restore(rawBytes:to:fingerprint:in:presenter:)`, in `RegistryDirectory.allCases` order. It records nothing in the cache's memory: the new root's first resolve remembers it through `reconcile` (`cached == nil` → `remember`).
- Modify: `MaughamTests/TripwireGrepTests.swift` :10343–10360, the reason text of `registryWriterCallers` only ("`RegistryCache.swift` — `restore` alone, in three senses: … and a promotion carrying a verified register's own bytes into the new book"). The members are unchanged.
- Modify: `Maugham/Stores/ProjectStore+PromotionCarry.swift` (Task 3's file): the pre-flight resolves the Collection's verified register; **new** step 4f writes it into staging.
- Modify: `Maugham/OpLog/AREA.md`, "The register and trust" (one line, paid for).
- Create: `MaughamTests/Collection/PromotionCarriesTheRegisterTests.swift`.

**Consumes:**
- `TrustResolution.resolveVerified(projectURL:identities:presenter:cache:)` (`TrustResolution.swift:80`), run off the main actor as its doc asks (:58–60). It is the reconciled register, the only one a decision may be made from (`OpLog/AREA.md`). It throws on a present-but-unreadable record (RULING-54);
- `RegistryWriter.restore(...)` (`RegistryWriter+Restore.swift:29`);
- `LocalIdentities.current`.

**Produces:** the staged project's register equals the Collection's verified records, byte for byte. Malformed records are not carried: they contribute nothing in either book.

**Behaviour:**
- **Pre-flight:** an unreadable record refuses the promotion before anything moves. The refusal is **new** `PromotionCannotReadTheRegister`, saying: "“X” can't be promoted right now: this Collection's list of people and devices couldn't be read. Try again in a moment."
- A Collection with no register (`TrustResolution.hasRegistry` false and nothing remembered) carries nothing. Its keyless verdicts are the same in both books.
- **Root and join:**
  - `ensureRootIfEmpty` refuses once anyone is named, so the new project's root is the Collection's root.
  - This Mac's `myRoot` is reached by arm 2 (its own root record) or arm 3 (a foreign root whose chain names its key) (`OpLog/AREA.md`).
  - **Stated limit:** where the Collection's answer came from arm 1, a join this Mac remembers for the Collection's path, and the register holds more than one admitting root, the new project's first resolve joins the first admitting root it reads. That could be a different one. Not seeded: `RegistryCache.join` has one caller (`TrustResolution.swift:109`), and a second is a new opinion about who this device follows.
- The schema gate needs nothing: the promoted manifest is written at `currentSchemaVersion` (10, `ProjectManifest.swift:203`), which is above the narrowing gate's 9.
- `StructureItem.startedBy` is already carried (:950), so §4.5's starter questions read the same records.

**Contract (signed test identities, real stores):**
- `test_aSecondMacsLinesApplyInThePromotedPiece`. Mac B is admitted in the Collection, and B's paragraph is in the piece. After promotion, loaded as this Mac: B's paragraph is in the text and its lines are `.verified`.
- `test_aStrangersHeldLineIsStillHeld`. A stranger's line held in the Collection is held in the promoted project with the same `HeldLines` holder; it is not applied.
- `test_aRevokedPersonsLaterLinesStaySetAside`. A revocation with `highestOpIdSeen`: the same split in both books.
- `test_aPieceScopedPermitStillScopesThePiece`. A reviewer narrowed to this piece in the Collection: their note applies and their prose is refused for scope, identically.
- `test_theUnsignedSnapshotStillGovernsTheCarriedStreams`. An unsigned stream before the first narrowing applies; after it, pending, in both books.
- `test_anUnreadableRecordRefusesBeforeAnythingMoves`. Plant an unreadable record file; `PromotionCannotReadTheRegister`; the Collection is byte-identical.
- `test_theCarryWritesThroughRestoreOnly`. Census: `RegistryCache.carry` is the only new caller, and `test_theRegistrysWritersAreThreeFiles` and `test_registryRecordsAreWrittenThroughRegistryWriterOnly` stay green.

- [ ] **Step 1:** Tests; red.
- [ ] **Step 2:** Implement.
- [ ] **Step 3: Disable experiment.** Make step 4f write nothing: `test_aSecondMacsLinesApplyInThePromotedPiece` goes red (B's paragraph held, missing from the text). Restore.
- [ ] **Step 4:** `./gen.sh`; `./scripts/test.sh core`, `./scripts/test.sh`, `./scripts/test.sh phone` (foreground, 600000 ms). Commit `promotion carries history task 4: the Collection's register travels with the history`.

---

### Task 5: The checkpoints and translation rounds that name the piece

**Files:**
- Modify: `Maugham/Stores/ProjectStore+PromotionCarry.swift`: **new** step 4g.
- Create: `MaughamTests/Collection/PromotionCarriesCheckpointsTests.swift`.

**Consumes:**
- `CheckpointStore(projectURL:presenter:).load()` (:72) and `.append(_:)` (:100). The append routes each row to its own device's file through `DeviceSlug.make(from: cp.device)`, the one spelling, written into staging;
- `Checkpoint` (`Checkpoint.swift:3–29`): `docPointers`, `activeDoc`, `manuscriptWordCount`;
- `Deriver.derive(ops:upTo:)` (`Deriver+Rewind.swift`, the timeline-prefix state; read its signature first);
- `TranslationRoundStore(projectURL:)`, `.pieceRounds(language:docId:)` (:127), `.append(_:)` (:178), which keeps numbers and advances `nextNumber` (:196–204).

**Produces:**
- **Checkpoints.** Every Collection checkpoint whose `docPointers` names the piece (or its intent) is re-written into staging with:
  - the same `checkpointId`, `label`, `labelSource`, `at` and `device`;
  - `docPointers` cut to the piece and the intent;
  - `activeDoc` kept only if it was the piece, else nil;
  - `manuscriptWordCount` recomputed as the piece's words at its pointer, by deriving the carried ops up to that op.

  Checkpoints are unchained, so a narrowed row is an ordinary row, not a rewrite of history. The Collection's rows are untouched.
- **Rounds.** For each language holding the piece's rounds, those rounds are appended into staging in number order, departures and letters inside them.

**Contract:**
- `test_aCheckpointNamingThePieceRestoresItInThePromotedProject`. A ⌘S in the Collection, then more typing, then promotion. In the promoted project, History lists the checkpoint; restoring it gives the text as of then.
- `test_aCheckpointNamingOnlyOtherPiecesIsNotCarried`.
- `test_aCarriedCheckpointCountsOnlyThePiecesWords`.
- `test_thePiecesLatestRoundAndItsLetterAreInThePromotedProject`. Two rounds for the piece and one for another piece in Serbian: the promoted ledger holds the piece's two with their numbers, and `latestFinished(language:docId:)` answers the newest.
- A failure in 4g (via the Task 3 seam keyed on `.maugham/checkpoints`) rolls back like 4e.

- [ ] **Step 1:** Tests; red.
- [ ] **Step 2:** Implement.
- [ ] **Step 3: Disable experiment.** Leave `docPointers` whole: `test_aCheckpointNamingThePieceRestoresItInThePromotedProject` must stay green while a new assertion, that the carried row names no doc absent from the manifest, goes red. Restore.
- [ ] **Step 4:** `./gen.sh`; `./scripts/test.sh` (foreground, 600000 ms). Commit `promotion carries history task 5: the checkpoints and translation rounds that name the piece`.

---

### Task 6: The Collection keeps the record, read-only, and the writer can reach it

After a successful promotion the Collection's log for the piece's id stays where it is (`.maugham/ops/` is never staged, :606–611), so the history survives. Nothing must write it, and the writer must be able to see it (CLAUDE.md workflow rule 8).

**Unverified by reading, and so this task's first step:** what a load of a reference's `.maugham-link.json` does today.
- The door refuses a reference only for a load that a promotion's return overtook (`DocumentStore.swift:1980–1985`). A load that starts later is not refused.
- `ProjectWindow.documentIds(in:)` (:2283) includes references, and `PartialRestorePicker.offeredDocIds` (:178) filters only by `mayWrite`, so a project-wide restore may name the reference.
- If `Document.load` resolves the link file's path to the piece's id (`resolveDocId(for:)` finds it by path) and finds its log, the divergence check would back up the JSON and render the piece's prose over the link file.

The failing test establishes which happens.

**Files:**
- Modify: `Maugham/Stores/DocumentStore.swift`: **new** `func pathNamesAReference(_ path: String) -> Bool` beside `pathNamesAManuscript` (:1941). `loadManuscript` (:1960) refuses such a path up front, always, with **new** `ManuscriptIsAReference: LocalizedError` ("“X” is now its own project; its history here is read-only"). Not `pathNamesAManuscript`: statements pass through the door and name no structure path.
- Modify: `Maugham/Views/PartialRestorePicker.swift` (:126–195): offered and whole-project ids leave out references; the call site passes the ids of `EditorHost.loadsAsAManuscript` items (`EditorHost.swift:1338`).
- Modify: `Maugham/Views/HistoryPane.swift` (:95):
  - **new** `var archive: HistoryArchive? = nil`, where **new** `struct HistoryArchive { let promotedAt: Date; let projectURL: URL? }` is built from the reference row and its `CollectionLinkFile` (`Maugham/Models/CollectionLinkFile.swift:10`, `linkedAt`).
  - With an archive, the pane draws one head line: "Before “X” became its own project on 22 Nov. What came after is in the project." with **Open the Project** (the reference card's own open action).
  - It draws no Rewind (already `.none`: `HistoryPaneStatics.pieceNoun` :693 answers nil for a reference), no checkpoint Restore, and no Send to Inbox.
  - Where ops are dated after `promotedAt` (`Op.at` is display-only; a sentence is display), it adds "N changes here are dated after the promotion and aren't in the project."
- Modify: `Maugham/Views/CentreItemCover.swift` (:135) and `Maugham/Views/PulledUpView.swift` (:560), the two `HistoryPane(` mounts: pass `archive` when the item is a reference.
- Modify: `Maugham/Views/ReferencePlaceholderCard.swift`: when the Collection holds a log for the row's id (`HistoryCarry.files(forDocIds:in:)` non-empty, read once in a `.task`), a second line "Its history up to the promotion stays here" with a **History** button that pulls up `.history(docId:)`. That route already exists: `ClickRule.isPiece` (:115) is true for a reference.
- Create: `MaughamTests/Collection/PromotionArchiveTests.swift`.

**Consumes:** `loadManuscript(...)` (:1960), `pathNamesAManuscript` (:1941), `HistoryPaneVerbs.reload()` (:46; it already reads a closed doc's ops through `OpLogStore.load(docId:)`), `RightColumnContent.pulledUp(for:subject:structure:piece:)` (:165), `CollectionLinkFile`.

**Contract:**
- `test_aLoadOfAReferencesPathIsRefusedAtTheDoor`. Red first, and it records what happened before the fix. After the fix: `ManuscriptIsAReference`, and the link file's bytes are unchanged.
- `test_aWholeProjectRestoreNeverNamesAReference`.
- `test_theArchiveListsThePiecesHistoryAfterPromotion`. Real stores: after promotion, the Collection's `OpLogStore.load(docId:)` for the id returns every op it had. The `HistoryArchive` built for the row carries the link file's date. `rewindSlot` is `.none`.
- `test_changesDatedAfterThePromotionAreCounted`. Pure.
- Census: tripwire 59's door test and claim M9-OL-020 are extended to name the reference refusal.

- [ ] **Step 1:** The unverified-behaviour test, red; record the observed behaviour in the report.
- [ ] **Step 2:** The door, the picker, the archive line, the card.
- [ ] **Step 3: Disable experiment.** Remove the up-front refusal: `test_aLoadOfAReferencesPathIsRefusedAtTheDoor` goes red. Restore.
- [ ] **Step 4:** `./gen.sh`; `./scripts/test.sh` (foreground, 600000 ms). Commit `promotion carries history task 6: the Collection keeps the piece's record, read-only, and History reaches it`.

**Hand check:** 3.

---

### Task 7 (MaughamCore + phone): An archived piece's notes are not listed twice

The phone lists notes for every doc id in `.maugham/ops/` (`MaughamPhone/Annotations/AnnotationsStore.swift:107–128`) and never asks the manifest. Today the Collection's copy of a promoted piece's notes is already listed there. After this plan the promoted project's copy is listed too, and a disposition pressed on the Collection's copy would append to an archive. The rule is "a reference row's log is an archive", and both apps use it, so it lives in Core (tripwire 19).

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/ProjectManifest.swift`: **new** `public var archivedDocIds: Set<String>`, the ids of structure items with `pieceKind == .reference` (`StructureItem.swift:32`). Computed, not stored; **no format change**. (Another agent is editing this file on the shell branch at the time of writing; this plan runs after that merges.)
- Modify: `MaughamPhone/Annotations/AnnotationsStore.swift`: `loadedAnnotations(for:)` decodes the project's manifest (read the phone's existing manifest reader first; do not add a second) and skips `archivedDocIds`.
- Modify: `Maugham/Stores/ProjectStore+Annotations.swift`: if `rebuildAnnotationsCache` walks a reference's id (unverified: read it), it skips `archivedDocIds` too.
- Modify: `MaughamPhone/AREA.md` (one line, paid for).
- Create: `Packages/MaughamCore/Tests/MaughamCoreTests/ArchivedDocIdsTests.swift`, `MaughamPhoneTests/ArchivedPieceNotesTests.swift` (match the phone test target's folder at HEAD).

**Consumes:** `AnnotationLoading.docIds(inOpsDirectoryFilenames:)` (phone, :55), `listAnnotationsAcrossProject()` (`ProjectStore+Annotations.swift:102`).

**Contract:**
- `test_aReferenceIsArchived_aLoosePieceIsNot`, pure (Core).
- `test_thePhoneListsNoNoteOfAReference`, against a real project folder under `TestTemp`.
- `test_theMacsAcrossProjectListSkipsAReference`.

- [ ] **Step 1:** Tests; red.
- [ ] **Step 2:** Implement.
- [ ] **Step 3: Disable experiment.** Make `archivedDocIds` return `[]`: the phone test goes red. Restore.
- [ ] **Step 4:** `./gen.sh`; `./scripts/test.sh core`, `./scripts/test.sh`, `./scripts/test.sh phone` (foreground, 600000 ms). Commit `promotion carries history task 7: an archived piece's notes are not listed twice`.

---

### Task 8: The round trip, and the record

**Files:**
- Create: `MaughamTests/Collection/PromotionRoundTripTests.swift`.
- Modify: `Maugham/Stores/AREA.md` (:32, :165–166, :251, :345: what travels and what stays), `Maugham/OpLog/AREA.md` ("Source of truth", one line), paid for in each file.
- Modify: `docs/adr/0038-status-editions-and-translation.md`: §10's **Cost** (:146) and its owed list (:271) are updated, and an addendum records the mechanism, the rejected candidates and the stated limits.
- Modify: `register/reconciliation/OpLog.claims.json`: **new** claims M9-OL-022 to M9-OL-025 (below), plus the matching filings in `OpLog.filings.json` per `register/reconciliation/PROTOCOL.md`.
- Modify: `docs/tripwires.md` row 59 (the reference refusal), if Task 6's census text changed.

**The round trip (`PromotionRoundTripTests`, real stores, signed test identities):**
- `test_promoteThenRewindThenEveryNoteAndTranslationStillAnchors`. The Collection piece has:
  - three checkpoints;
  - an open comment and a suggestion by this Mac;
  - a note by the assistant actor;
  - Mac B's paragraph and B's query;
  - a Serbian translation of four paragraphs and its round.

  Promote. In the new project:
  - History shows every pre-promotion op and the three checkpoints;
  - `restoreToOpUndoable` to the second checkpoint gives that text, and ⌘Z undoes the rewind;
  - every open note's ¶id is in `sequence`, and B's query is B's (`AnnotationOwnership`);
  - `TranslationStore.loadMerged` for `sr` keys every record to a live ¶id;
  - accepting the suggestion splices it.
- `test_theCollectionStillShowsItsHistory`. After the above, the Collection's archive for the id lists every op it had, its checkpoints are untouched, and a load of the reference is refused.
- `test_aClosedPiecesPeersUnrenderedOpsAreCarried`. The review's second gap.
  - The piece is closed.
  - Mac B's ops are written into its stream, but B's render is not: the `.md` is stale.
  - Promote. The promoted text contains B's paragraph.
  - **Stated:** the first load may file one `diverged` backup of the stale `.md` under the new project's `.maugham/conflicts/`, as any closed document with a stale render does (RULING-64 covers only the pending-fold case). The test asserts the words, and names the backup only to pin that it is the stale render.
- `test_aSecondMacOpeningThePromotedProjectChainsOntoItsOwnFile`. As Mac B's identities: load and append. B's file verifies, and A's view after a re-read applies B's new line.

**Register claims (to file):**
- **M9-OL-022** — A promotion carries the piece's and its intent's op-log streams, translations and this device's pending file byte for byte under the same ids, and refuses before anything moves when one is an iCloud placeholder (Tasks 1–3).
- **M9-OL-023** — A promotion carries the Collection's verified register as signed bytes through `RegistryWriter.restore`, so every carried line settles as it did, and refuses before anything moves when the register cannot be read (Task 4).
- **M9-OL-024** — Checkpoints naming the piece and its translation rounds travel narrowed to it (Task 5).
- **M9-OL-025** — A Collection reference's log is an archive: no load of a reference path, no restore naming one, no note of one listed on the phone or across the Mac's project. Its History shows the record up to the promotion (Tasks 6, 7).

The intent of each is **Denver's ruling of 2026-11-22**. Calls 1–5 below are the controller's and are filed as such.

- [ ] **Step 1:** The round trip; it should pass on Tasks 1–7. Any red is a defect in a task, fixed there, never here.
- [ ] **Step 2: Disable experiment.** Revert Task 1's id change only: the round trip goes red at the first note's anchor. Restore.
- [ ] **Step 3:** Docs and register.
- [ ] **Step 4:** `./gen.sh`; `./scripts/test.sh full` (foreground, 600000 ms); `./scripts/test.sh core`; `./scripts/test.sh phone`. Commit `promotion carries history task 8: the round trip, and the record`.

**Then:** a whole-branch review with the task ledger. Name these seams for it:
- the door and the archive (Task 6) against Task 3's copy and the hold;
- the register carry against the first open's `ensureDeviceRecord` and the silent admission;
- Task 7's skip against the board's open-note counts.

---

## Hand checks for the owner

1. In a Collection, give a piece a few paragraphs, a comment, a ⌘S, and a Spanish translation of two paragraphs. Close it. Promote it. The new project opens with the text. History lists every change since the piece began, and the ⌘S. The comment sits on its paragraph. Read the piece in Spanish: the two paragraphs are there.
2. In the new project, Rewind to before the comment, then ⌘Z: the text and the comment come back.
3. Back in the Collection, select the piece's row: the card reads "Linked project" and "Its history up to the promotion stays here", with **History**. Click it: the history is there, with "Before “X” became its own project on …" and **Open the Project**. There is no Rewind and no Restore.
4. With a second Mac on the same iCloud folder: after sync, open the promoted project there. Type a sentence. Back on the first Mac the sentence arrives. Neither Mac shows a held or set-aside line.
5. On the phone, the Annotations tab lists the comment once, under the new project.
6. Promote a piece while its iCloud history is still downloading (or simulate by evicting the folder): the promotion refuses with the "hasn't finished downloading" sentence, and the piece is untouched.
7. Smoke: launch → New project → Novel → "Smoke" → type a sentence → ⌘Q → relaunch → open from Recents → sentence intact.

---

## Calls made in this plan, for Denver to check

1. **Same document id in both books.** The promoted piece keeps its id (the only way a byte copy stays valid). The Collection's reference row already had it. Cost if wrong: Task 1, and the whole mechanism.
2. **The register travels whole**, not filtered to the devices that touched the piece. Signed permit events cannot be filtered without changing what they mean. Cost: People & Devices in the new book lists everyone in the Collection's.
3. **The promoted history is live, not an archive.** It can be rewound, and notes can be answered. Only the Collection's copy is read-only.
4. **What stays in the Collection:**
   - conflict backups, quarantined files, compiler diagnostics (they are regenerated);
   - sessions and statistics, the bible, the canvas, editions, `__project__` tasks;
   - lines that arrive in the Collection after the copy. The archive counts those in a sentence.
5. **Refuse, don't half-carry.** A promotion refuses before anything moves when history is still downloading or the register can't be read.

## Questions for Denver

1. **The people come along.** The new book's list of people and devices is the Collection's, so a collaborator admitted to the Collection, or narrowed to this piece, has the same standing in the new book. If someone other than you promotes, the new book's root is still the Collection's root. *Recommendation: yes, as built.* It is the only way their past lines read as they did; you can revoke anyone in the new book afterwards.
2. **What "survives in the original" looks like.** The plan keeps the piece's row as a reference whose card offers **History**: the record up to the promotion, read-only, with **Open the Project** for what came after. Do you want more than that, such as the old notes readable in the Collection's To resolve? *Recommendation: History only.* Answering a note in two places would split it.
