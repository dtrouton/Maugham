# Batch F research — #88 (unreadable canvas layout) and #92 (backups keyed by manifest id)

Branch `fix/batch-f-88-92`, off main 4b20d96c. Read-only research; nothing built or run.

---

## #88 — a canvas layout file that exists but can't be read

### How `CanvasStore.load()` reads today (`Maugham/Canvas/CanvasStore.swift`)

- `canvas.md` (CONTENT): `(try? String(contentsOf: scrapsURL, encoding: .utf8)).map(ScrapText.parse) ?? [:]` (~:132). **Any** failure → no words.
- `canvas.json` (derived): `guard let data = try? Data(contentsOf: sidecarURL) else { … .absent }` (~:136). Any failure → `.absent`, `loadRefusal = nil`, so every write is allowed.
- Decoded bytes go through `decode(_:)`, which gives `.newerVersion` (version probe first) / `.damaged` / success.
- `setDamagedSidecarAside` (~:270) re-reads with the same `try?` → an unreadable file throws `.nothingDamaged` (safe: it moves nothing, but the message is wrong — "close and reopen").
- `loadForTransientWrite` (~:306) is `load()` plus throw-the-refusal, so a fix in `load()` covers it, and also covers `CanvasClaudeWrite.readScene`'s sidecar route, `CanvasCapture`, `ProjectStore.repointCanvasMarks` and `CanvasCapture.swift:134`'s probe.

Error cases that collapse to `.absent` today:
1. No file (ENOENT / `CocoaError.fileReadNoSuchFile`). This is the only real absent case.
2. **Old-style iCloud placeholder**: the real `canvas.json` is gone and `.canvas.json.icloud` sits beside it. The read fails with no-such-file, so it is indistinguishable from (1) unless the sibling is checked. The app already knows this shape: `OpLogStore.nameBehindICloudPlaceholder` (MaughamCore ~:1707, internal, so not callable from the app target) and its sweep refuse on it (RULING-54: present-and-unreadable is never silently skipped).
3. **Dataless file under its real name** (the FileProvider shape on modern macOS, macOS 27 included). `Data(contentsOf:)` from an ordinary app normally triggers a **synchronous on-demand download**. Online, it usually *succeeds* after blocking. Offline, or when the fetch fails, it throws, and today that throw becomes `.absent`. `load()` runs on the main actor from `CanvasView.load()` on `.onAppear`, so a big file plus a slow network can also stall the mount. The app already has a non-blocking probe for this, used twice: `RecoveryCause.defaultStubProbe` (`Maugham/OpLog/RecoveryCause.swift:58`) and `OpLogQuarantine.defaultStubProbe` (public, MaughamCore ~:921): `isUbiquitousItem && ubiquitousItemDownloadingStatus != .current`. `DocumentRecoveryPane.defaultStartDownload` (~:151) calls `startDownloadingUbiquitousItem`.
4. Permissions (EACCES): a chmod 000 file, or a sandbox/ACL problem.
5. A directory where the file should be, or another I/O error (EIO, EISDIR).

Nothing watches `canvas.json`. `MaughamSidecarPath` routes it to `.unknownSidecar`, so no `NSFilePresenter` arm reaches the canvas. The only re-reads are `CanvasModel.attach`, which `CanvasView.load()` calls on every `.onAppear` (persona switch back to Plan, window reopen), and `startFreshLayout`'s re-attach.

### A worse sibling the issue doesn't name: an unreadable `canvas.md` loses WORDS

If `canvas.md` exists but can't be read (same five causes) while `canvas.json` decodes, `scraps` is `[:]`. Every card then draws empty, with no orphans and no refusal, and the next edit runs `writeNow`, which writes `ScrapText.render(scraps)` over `canvas.md`. **That destroys every scrap's text**, which breaks constitution must #1 outright. #88's damage is limited to the layout, which is derived and deletable. The same guard must cover `canvas.md`: present-but-unreadable → refused `.unreadable`. Absent `canvas.md` stays legitimate (no scraps yet).

### Fix shape

- **`SidecarRefused.Reason.unreadable`**, a third case. The `sentence` switch has no default, so the compiler forces each surface to decide.
  - Sentence (Denver to confirm wording): *"Maugham couldn't read this canvas's layout file right now, so only its words are shown. It may still be downloading from iCloud — try again in a moment."* If `canvas.md` is the unreadable one, the scene is decoded but the words are missing, so a second sentence may be needed (*"couldn't read this canvas's words…"*). Simplest: one reason, with a sentence that says "this canvas's files" rather than "layout file". **Product question below.**
  - `CanvasReadOnlyNotice.offersStartFresh` already returns `reason == .damaged`, so `.unreadable` offers no Start a Fresh Layout with **no change to the notice**.
  - `CanvasTools.unreadableHint` gets a `.unreadable` arm (forced by the compiler): *"The canvas's files couldn't be read right now (often iCloud still downloading). Try again later; don't ask the writer to start a fresh layout."* `list_canvas` already carries `errorDescription` in `layout_unreadable_reason` and `layout_readable: false`, so nothing else changes there. The InboxPane alert also reads `errorDescription`, so it is automatic.
  - `setDamagedSidecarAside`: re-read through the same classifier. `.unreadable` throws the `SidecarRefused(.unreadable)` value, not `.nothingDamaged`, and moves nothing (it is never offered, but the verb must refuse correctly).
- **Classifier** (one private function both `load` and `setDamagedSidecarAside` use; it returns `absent | bytes(Data) | unreadable`):
  1. `stubProbe(url)` (injectable, default = the existing probe shape) → `.unreadable` **without reading**. That avoids the main-thread download stall. Fire `startDownloadingUbiquitousItem` once so a later retry finds the file.
     - Decision: mirror `!= .current` (the app's existing rule; a stale-but-local copy also waits) or only `.notDownloaded`. Recommend **mirroring the existing probe**: writing over a stale local copy would fork an iCloud conflict.
  2. `do { try Data(contentsOf:) } catch`. `CocoaError.fileReadNoSuchFile` / `POSIXError.ENOENT` → check for a `.<name>.icloud` sibling (inline the 3-line rule; the Core helper is internal) → `.unreadable` if one exists, `.absent` if not. **Every other error → `.unreadable`.**
  - `.unreadable` sets `loadRefusal` and cancels pending saves, exactly like `.refused`. `SidecarState` stays three cases (`.refused` with a reason), so `acceptsARepairWrite` is unchanged.
- **Retry / re-attach.** The fact is transient, unlike `.damaged`/`.newerVersion`, so the canvas should recover without a reopen.
  - **"Try Again" button: BLOCKED.** `CanvasReadOnlyNotice` is built in `ProjectWindow.swift:2489-2491` with exactly one closure (`startFreshLayout`). A second closure, or handing the notice the model, edits that call site.
  - **Unblocked alternative (recommended now):** an automatic retry owned by the canvas.
    - Add `CanvasModel.retryUnreadableLayout()`. It runs only when `sidecarRefusal?.reason == .unreadable`, re-`attach`es, and if the refusal changed calls `onSceneChangedExternally?()` + `bumpSceneRevision()`, the same tail as `startFreshLayout`. It is safe because a read-only model has no pending writes or undo steps to lose.
    - `CanvasView` (not blocked) drives it with a `.task(id: model.sidecarRefusal?.reason)` loop: every ~3 s while `.unreadable`, plus on `NSApplication.didBecomeActiveNotification`.
    - The sentence's *"try again in a moment"* then becomes *"…it will appear once it has downloaded"*, or stays as is if a button follows later.
  - The Try Again button can then be a one-line follow-up after the ProjectWindow split lands.
  - A presenter arm for `canvas.json` was considered and **not recommended**: the canvas model lives in the window, and routing a `MaughamSidecarPath` case to it touches DocumentStore and the window.
- **Docs:** `docs/guide/getting-started.md` "When the canvas is read-only" (~:160) needs the third case. `Maugham/Canvas/AREA.md` Persistence (~:692) currently says "Not covered, filed separately (#88)". **Both AREA.md files are being rewritten by the other session**, so edit AREA.md after it lands, or keep the edit to that one sentence and expect a rebase.

### Tests (windowless; all under `TestTemp.root`)

- `canvas.json` **is a directory** → `.refused` / `.unreadable`. This is the simplest and most reliable case: no chmod, and it works under root.
- chmod 000 `canvas.json` (precedent: `MaughamTests/InboxRecoveredWordsTests.swift` and others use `posixPermissions`; restore 0644 in `tearDown`, since `TestTemp` cleanup needs it).
- `.canvas.json.icloud` placeholder with no real file → `.unreadable`. No real file plus no placeholder → `.absent` (the control).
- Injected `stubProbe` returning true over a perfectly good file → `.unreadable`, and the bytes are never read (assert via a probe-only path).
- `canvas.md` unreadable (directory / chmod) with a decoding sidecar → refused, and **an edit does not rewrite canvas.md** (the words-safe test).
- Every write verb is a no-op after an `.unreadable` load (extend `test_aStoreWhoseLoadWasRefusedWritesNothingThroughAnyVerb` over all three reasons).
- `setDamagedSidecarAside` over unreadable → throws `.unreadable` and moves nothing.
- `CanvasModel.retryUnreadableLayout`: unreadable → make the file readable → retry clears the refusal and the scene appears. Retry over `.damaged` does nothing.
- `CanvasReadOnlyNotice.offersStartFresh(.unreadable) == false`. `CanvasTools.unreadableHint(.unreadable)` must not mention Start a Fresh Layout.
- Existing pins to update: `test_eachReasonSaysItsOwnRulingSentence`, `test_theRefusalAndTheRepairPredicateAgreeOnEveryCase`, CanvasToolsTests' per-reason hint test.

---

## #92.1 — Restore from Backup finds nothing when the manifest is unreadable

### Layout on disk

- `<destination>/<projectKey>/<generationULID>/` is a full copy of the project folder, plus `.maugham-backup-manifest.json` (Merkle) and the signature file. `BackupCoordinator.projectDestinations` appends the key, and `BackupWriter.write` writes the generation.
- `projectKey` (`Maugham/Backup/BackupCoordinator.swift:107-114`) = the decoded `project.maugham.json` `id`, else `projectURL.lastPathComponent`.
- **Each generation contains the project's own `project.maugham.json` (with `id` and `title`) and `.maugham/manifest.shadow.json`.** The source folder's path or name is recorded nowhere in a generation.

### Why it fails

- `ProjectStore.load` (`Maugham/Stores/ProjectStore.swift:460-492`) already self-heals a **corrupt** manifest from `ManifestShadow.recover` (ADR 0014 §7). So the "Couldn't open project" window only appears when (a) the manifest is **missing** (`manifestNotFound`, thrown *before* the shadow is consulted) or (b) the manifest and the shadow are both bad.
- In both cases `projectKey` falls back to the folder name, which never matches the ULID folder, so the window shows *No backups found*.

### Fix shape (none of it needs ProjectWindow)

1. **`projectKey` ladder**: manifest id → **shadow manifest id** (`ManifestShadow.recover(in:)` → decode → `id`) → folder name. This one change rescues case (a) and most of (b): the shadow is written on every manifest save, so it nearly always exists. It touches only `BackupCoordinator.swift` and is testable in `BackupCoordinatorTests` (delete the manifest, keep the shadow, assert `generations(forProject:)` finds the generation).
2. **Last-resort browse**, for when no id can be found anywhere.
   - `BackupCoordinator.allBackedUpProjects()` scans each destination's key folders and reads the newest generation's `project.maugham.json` → `(key, title, newest date, count)`.
   - When `generations(forProject:)` is empty, `RestoreWindow` offers *"Show all backups in your backup folders"* and lists them by title.
   - Matching by title or folder name automatically is not recommended: titles collide and a wrong match restores somebody else's book. Let the writer pick.
   - Touches `RestoreWindow.swift` and `BackupCoordinator.swift`.
3. Optional, related: `ProjectStore.load` could also recover from the shadow when the manifest is **missing**, not just corrupt. That is consistent with ADR 0014 §7 and would make most of these projects simply open. **Product question below.** It touches `ProjectStore.swift` only.

- **Reachability:** the menu item `FocusedRestoreButton` (MaughamApp.swift ~:610) reads `FocusedValues.projectURL`. ProjectWindow publishes that at ~:917 inside `TopChromeModifier`, which wraps the whole window body, the "Couldn't open project" arm (~:423-434) included. So **File → Restore from Backup… already works from that window; fixing #92.1 does not need ProjectWindow.** An in-window "Restore from Backup…" button on the error arm would be nice, but it edits ProjectWindow and is BLOCKED.

---

## #92.2 — a restored copy keeps the original's manifest id

### What keys off `ProjectManifest.id` (checked)

- **Mac:**
  - `BackupCoordinator.projectKey`: the backup folder **and Keep-N retention** (`BackupWriter.prune` runs per `<dest>/<key>`). Confirmed: the original and the restored copy share one folder and prune each other's generations. Skip-unchanged (`latestSignature`) also compares against whichever book backed up last.
  - Nothing else on the Mac reads `manifest.id`, apart from the backfill in `ProjectStore.load:502`.
  - MCP's project id is `ProjectIdentifier.id(for: url)`, a hash of the path. `PublishingStores.sharedFor(projectID:)` gets that path-hash id.
  - Op-log device state (`OpLogDeviceState`) keys by `DeviceState.fileKey`/`scopeHash(ofRoot:)`, also path-based.
- **Signed op log / register / permits:** no registry record, permit event, seal or chain line names the manifest id. (`TrustTable`'s "id is a CLAIM written into an unsigned manifest" is a piece's `startedBy` *device* id, not the book id.) `AdmissionMemory` deliberately has no project key. **Minting a new manifest id orphans nothing in the register.** The restored copy carries the original's `.maugham/devices`/`people` records verbatim, signatures intact. Two books sharing one register is a pre-existing property of restore-beside and is unaffected by the id.
- **Phone:** `ProjectsBrowser`/`RecentsTracker`/`CaptureView`'s `@AppStorage("currentProjectId")`/Settings standings all key on `manifest.id`. With two folders carrying one id, `projectsBrowser.project(id:)` returns `projects.first { $0.id == id }`, so **a phone capture can land in the wrong book**, and SwiftUI lists over `ProjectId` get duplicate ids. Minting a new id fixes this too.

### Fix shape (recommended)

- Mint a new ULID in the restored copy's manifest **and its shadow**, inside `BackupRestore.restoreBeside` (MaughamCore; `BackupRestoreTests` exists).
  - Decode with `ProjectManifest.decodeGuardingSchema`, set `id = ULID.generate()`, encode with `ProjectManifest.makeEncoder()` (the same round trip as the id backfill and every save), write atomically, then `ManifestShadow.write(data, in: target)`.
  - The shadow matters: left alone, it would hand the old id back to a later shadow recovery and to the #92.1 ladder.
  - If the copy's manifest can't be decoded (too new, or corrupt in the generation), leave it untouched and still restore. Never fail a restore over identity; the old `ProjectStore.load` backfill only handles a nil id, so mention it in the result. Alternatively, remove the `id` key so the first open backfills one — that also works.
  - Not recommended: keying backups by id+path (a move or rename would orphan history, which is exactly what ADR 0014 §5 chose the id to avoid).
- **Trade-off:** a writer who restores in order to *replace* the original (delete the original, rename the copy) starts a fresh backup history. The original's generations stay in the old folder, reachable only through the #92.1 "show all backups" browse. **Product question below.**
- Not investigated: restore-beside places a chained op log at a new path that this device's `OpLogDeviceState` has no head for. That predates this issue and doesn't depend on the id; flag it to the planner as an unknown, not a finding.

---

## #92.3 — the save panel offers Replace, then the restore refuses

- `RestoreWindow.restore()` uses a bare `NSSavePanel`. Picking a taken name shows the system *Replace?* sheet first; then `RestoreTarget.clearPlaceholder` throws `Occupied`.
- **`panel(_:validate:)` probably comes too late.** Unverified: for an NSSavePanel the overwrite confirmation is believed to run before the delegate's validate, so it would not stop the *Replace?* sheet. `panel(_:userEnteredFilename:confirmed:)` is the other hook, with the same uncertainty. This needs a manual spike; it can't be unit-tested (CLAUDE.md: never allocate a panel in a test, and pin configuration as a pure value, as in `AddFilePanelConfiguration`).
- **Alternative that avoids the problem:**
  - Ask with an `NSOpenPanel` for the **folder** to restore into (`canChooseDirectories`, `canChooseFiles = false`, prompt "Restore Here").
  - Name the copy automatically with a pure, tested function: `<project> (restored)`, then `(restored 2)`, … skipping taken names.
  - Then no name can be taken and no Replace is ever offered.
  - The guide sentence (`docs/guide/backups-and-history.md:102`) changes. `RestoreTarget.clearPlaceholder` becomes unnecessary for this path; keep it as a backstop.
- Touches `RestoreWindow.swift` only. Low priority; the issue marks it optional.

---

## Coordination (the ProjectWindow split / AREA.md / TripwireGrepTests refactor)

| Fix | Files | Blocked? |
|---|---|---|
| #88 `.unreadable` reason + classifier + canvas.md guard | `CanvasStore.swift`, `CanvasTools.swift` (hint arm), tests | **No** |
| #88 auto-retry | `CanvasModel.swift`, `CanvasView.swift` | **No** |
| #88 "Try Again" button | `ProjectWindow.swift:2489-2491` (notice call site) | **BLOCKED**; follow-up after the split |
| #88 AREA.md sentence | `Maugham/Canvas/AREA.md` | Being rewritten; do it after the refactor lands (or accept a rebase) |
| #92.1 shadow-id ladder | `BackupCoordinator.swift` | **No** |
| #92.1 "show all backups" browse | `BackupCoordinator.swift`, `RestoreWindow.swift` | **No** |
| #92.1 in-window Restore button on "Couldn't open project" | `ProjectWindow.swift` ~:423 | **BLOCKED**, and not needed (the menu already works there) |
| #92.1 optional: open from shadow when manifest missing | `ProjectStore.swift` | **No** |
| #92.2 new id on restore | `BackupRestore.swift` (Core), `BackupRestoreTests` | **No** |
| #92.3 folder-pick + auto-name | `RestoreWindow.swift` | **No** |

- None of the recommended tasks needs `TripwireGrepTests.swift`. The `// adr-0018-ok:` annotation guard is per line: keep the comment on every new raw read line in `CanvasStore` and `BackupCoordinator` (the shadow read goes through `ManifestShadow.recover`, already annotated).
- Guide docs (`docs/guide/*.md`) are not part of the refactor.

---

## Product questions for Denver (plain words)

1. **Canvas still downloading:** when the canvas's files are still arriving from iCloud (or can't be read for another reason), the canvas would show your words read-only with this line: *"Maugham couldn't read this canvas's files right now, so only its words are shown. It may still be downloading from iCloud — it will appear by itself once it has."* Is that wording right? Should the line also tell you to check your connection?
2. **A restored copy is a new book:** when you restore a backup, should the copy count as a *separate book*, with its own backups and not shared with the original? Recommended: yes. The catch is that if you later delete the original and keep the copy, the copy starts a fresh backup history. The old backups are still there and can be found through "show all backups".
3. **Missing project file:** if a project's main file (`project.maugham.json`) is deleted but Maugham's hidden spare copy is still there, should Maugham quietly put it back and open the project? (It already does this when the file is *damaged*.)
4. **(Optional) Restore placement:** instead of typing a name for the restored copy (which can collide), would you rather just choose a folder and have Maugham name it *"<project> (restored)"*, adding a number if that name is taken?

---

## Recommended tasks (≤6)

1. **#88 core: three-state classifier + `.unreadable` reason** in `CanvasStore`, covering `canvas.json` **and** `canvas.md` (the words-safe half). Includes the stub probe (no main-thread download), the `.icloud`-sibling check, `startDownloadingUbiquitousItem`, `setDamagedSidecarAside` refusing with `.unreadable`, the `CanvasTools.unreadableHint` arm, and windowless tests (directory, chmod, placeholder, injected probe, words not rewritten). Opus: this is words-safety.
2. **#88 recovery: `CanvasModel.retryUnreadableLayout()` + `CanvasView` retry loop** (timer while `.unreadable`, plus app-activation). Then the guide section. The AREA.md sentence and the Try Again button wait for the refactor.
3. **#92.1: shadow-id ladder in `BackupCoordinator.projectKey`**, plus tests (missing manifest + shadow → generations found; corrupt manifest + shadow; neither → folder name as today).
4. **#92.1 last resort: "Show all backups" in `RestoreWindow`** over a new `BackupCoordinator` scan (title from each key's newest generation manifest; a pure scan function tested in Core or the coordinator tests). Guide `backups-and-history.md` update.
5. **#92.2: mint a new id in `BackupRestore.restoreBeside`**, rewriting manifest and shadow and leaving an undecodable manifest alone. Core tests: new id ≠ old; shadow agrees; other fields round-trip; a too-new manifest is untouched and the restore still succeeds. Gated on product question 2. Guide sentence.
6. **(Optional) #92.3: folder-pick + auto-unique name** in `RestoreWindow` (pure name function tested; panel configuration as a value). Optionally fold in question 3's shadow-on-missing-manifest open (`ProjectStore.load`) if Denver says yes.
