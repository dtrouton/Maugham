# Signed op log P2a — records, trust, pending — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the three handoff decisions (D0, D2, D3′) and build P2's substrate: signed registry records, the device-local cache, the trust table, *pending* as a verification state reached only relative to a chain, the device record written at open on Mac and phone, and History's first two P2 lines.

**Architecture:** Everything cryptographic and every trust decision is a pure value in `Packages/MaughamCore` (`RegistryRecord`, `RegistryReader`/`RegistryWriter`, `RegistryCache`, `TrustTable`), tested with the software signer. `OpLogChain.verify` gains a trust-verdict closure; the Bool form remains as the keyless wrapper. `OpLogStore`, `TranslationStore`, `JSONLAppendStore` and the phone's writers build their closure from a `TrustTable` and nowhere else (census). Nothing pending is applied, quarantined or recorded. The Mac writes its device record (and, on an empty registry, its root record) in `DocumentStore.open`'s sweep; the phone writes its device record where it first writes anything. No sheet, no pane, no revocation in this plan — P2b's.

**Tech Stack:** Swift 6, CryptoKit, Foundation, XCTest; `swift test` for the package, `./scripts/test.sh` / `./scripts/test.sh phone` per task, `./scripts/test.sh full` before merge.

**Spec:** `docs/superpowers/specs/2026-09-09-signed-op-log-p2-people-and-admission-design.md` (§1 decisions, §2 records, §3 trust, §4.3 the device's own view, §6 History, §8 P2a's list, §9 testing). Parent: `docs/superpowers/specs/2026-09-05-signed-op-log-design.md`. ADR 0032.

## Global Constraints

- **No wire-format change**: `prev`, seal lines, `.lines` records, the segment container and `.mzseg.sig`, `op-log-state.json`'s shape are untouched. New files only: `.maugham/people/*.json`, `.maugham/devices/*.json`, `.maugham/people/claims/*.json` (claims are P2b's; the reader tolerates the directory), and device-local `registry-cache.json`.
- **Every record is signed** with `OpLogChain.Credentials` (`{key, pub, sig}`, `OpLogChain.swift:270–290`: `key` = fingerprint of `pub`, `pub` = X9.63 base64, `sig` = base64 over the SHA-256 digest); the digest is over the record's canonical bytes — `JSONEncoder` with `.sortedKeys` and `JSONLAppendStore<…>.dateEncoding`, the `sig` field absent. A record whose signature fails, or whose `key` is not the fingerprint in its filename, is *malformed*: never read as a record, listed by Integrity.
- **B3 — no chain, no pending.** A reading device with no record naming any of its keys and no root record of its own classifies every foreign seal as `unsignedHistory`, exactly as P1. Pending exists only once the device has a chain.
- **B1 — a device never switches roots on its own.** The first root whose record names it is remembered in the cache; a later record from another root is a claimant.
- **Pending is held**: not applied, not quarantined, no `.lines` record, counted per device.
- Tripwires 24 (no hand-built slug), 33 (no press-then-wait), 35 (no host-name identity), 36 (no software private key in production — every test signer is `DeviceIdentity.softwareForTesting`), 37 (seal line recognised in `OpLogChain` only), 38 (no `device:` string at a production `Document.load`).
- Tripwire 19: anything both Mac and phone touch lives in MaughamCore; phone twins of every new census in `TripwirePhoneGrepTest`.
- Gates per task: `swift test --parallel --package-path Packages/MaughamCore`, `./scripts/test.sh`, `./scripts/test.sh phone`. `./gen.sh` after adding any source or test file. `./scripts/test.sh full` before merge.
- Branch `claude/signed-op-log-p2a-2026-09-09` off `main` (at or after `ce753a01`). Merge to local `main`; the paired release binds at P2b.
- Stage by explicit path; never `git add` a directory; never amend a reviewed commit.

---

### Task 1: D3′ — prune only when the parent survives

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/OpLogDeviceState.swift` (`prune(_:)`, ~line 258)
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/OpLogDeviceStateTests.swift`

**Contract:** a recorded root is *dead* only when `FileManager.default.fileExists(atPath: root)` is false AND `fileExists(atPath: root's parent)` is true. Everything else is kept.

- [ ] Tests: (a) `test_aRootWhoseParentIsGoneIsKept` — record under `<tmp>/Volumes-like/Archive/Novel`, delete `Archive` (so `Novel`'s parent is gone), reload: the head survives; (b) the existing `test_pruningDropsAHeadWhoseRootIsGone` still passes (parent present, root gone → dropped); (c) `test_aRootThatExistsWithoutAMaughamChildKeepsItsHeads` still passes.
- [ ] Run (a) red, implement the two-clause predicate, run green. Update the doc comment above `prune` to state the rule and why (spec §1 D3′).
- [ ] Package tests; commit `fix(oplog): a project is pruned only when its parent survives and it does not — an unmounted volume keeps its heads`.

---

### Task 2: D2 — acknowledged set-aside records

**Files:**
- Modify: `Maugham/Stores/UIState.swift` (new field), `Maugham/Stores/DocumentStore.swift` (a named verb beside `setAuthorReaderChoice`, ~line 295–303), `Maugham/Views/HistoryPane.swift` (`setAsideLinesNotice`/`setAsideLineCount`, ~lines 297–312, 391, 566), `Maugham/Views/InboxPane.swift` (`setAsideNotice`, ~lines 57–93), `Maugham/Stores/InboxStore.swift` (`setAsideLineCount`, ~lines 52, 124)
- Create: `Maugham/OpLog/SetAsideAcknowledgement.swift` (one pure predicate both panes call)
- Test: `MaughamTests/OpLog/SetAsideAcknowledgementTests.swift` (new; `./gen.sh`)

**Contract:** `UIState.acknowledgedSetAsideRecords: Set<String>` (record FILENAMES, tolerant decode, default empty). `SetAsideAcknowledgement.unacknowledged(records: [URL], acknowledged: Set<String>) -> [URL]` is the one predicate; both panes count only its result. An **Acknowledge** button beside each notice calls `DocumentStore.acknowledgeSetAsideRecords(_ names: Set<String>)` (through `updateUIState`), which unions. A new record reappears with its own count. Records on disk are never touched. `OpLogQuarantine.setAsideLineCount(records:in:)` (`OpLogQuarantine.swift:361`) is unchanged; the panes filter before calling it.

- [ ] Tests (windowless, tripwire 33): the predicate over three records with one acknowledged returns two; a name not on disk in the acknowledged set is harmless; `UIState` decodes a file without the field to an empty set; `acknowledgeSetAsideRecords` unions and persists (via the store's existing UIState round-trip test shape). The panes' notice statics are asserted on the filtered count; the button is asserted DRAWN only.
- [ ] Implement; both panes read the same predicate; the History pane's disclosure that lists every record regardless is the existing set-aside list if one exists, else a `DisclosureGroup("Set-aside records")` naming each file — check what the pane already draws before adding a second list.
- [ ] Package + Mac gates; commit `feat(history): set-aside notices are acknowledged per device per record; the records stay`.

---

### Task 3: D0 — an unreadable translation file refuses loudly

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/TranslationStore.swift` (`loadMerged(forDocId:language:in:identities:state:)`, line 199; the `guard let bytes = try? … else { warning; continue }` at ~206–213)
- Modify: the eleven callers — `Maugham/MCP/Tools/TranslationTools.swift:214`, `Maugham/Publish/TranslationCoverage.swift:66`, `Maugham/Publish/ProjectStoreASTSource.swift:150`, `Maugham/Publish/EditionStatus.swift:304`, `Maugham/Views/EditorHost.swift:830`, `Maugham/Compiler/TranslationPreflight.swift:47`, `Maugham/Compiler/TranslatorEnvironment+Project.swift:177,533,557`, `Maugham/Compiler/TranslationPipelineEnvironment+Project.swift:97,130` (line numbers as of `ce753a01`; re-grep `loadMerged(`)
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/TranslationStoreTests.swift`; the Mac tests of the three surfaces named below

**Contract:** `loadMerged` becomes `throws`, throwing `OpLogStore.ReadError.unreadableFile(name:underlying:)` (the op log's own error, `OpLogStore.swift` ~line 300) for a present-but-unreadable file. Callers: the Publish desk's status line and `EditionStatus` surface the error's file-naming sentence in the degrade banner the unreadable catalog already uses (RULING-7); `read_translation` and `translation_status` return an MCP error naming the file; `TranslationCoverage` (the compile gate) refuses the edition with the same sentence; the compiler/pipeline environments and `EditorHost`'s review pane propagate through their existing error paths (a run refuses; the pane shows the sentence where it shows a missing translation today). No caller may catch and substitute an empty array — census below.

- [ ] Tests: MaughamCore — a file with mode 000 (skip when running as root) throws the named error; a missing file still reads as absent. Mac — `TranslationCoverage` refuses with the file name; `translation_status` reports the error; the desk's status line composes the sentence (pure composition, no window).
- [ ] Implement; census in `TripwireGrepTests`: `test_translationLoadMergedIsNeverSwallowed` — no `try? TranslationStore.loadMerged` or `(try? …) ?? []` in production; planted-offender control.
- [ ] All three gates; commit `fix(translation): a present-but-unreadable translation file refuses the read, by name, at the desk, the MCP readers and the compile gate`.

---

### Task 4: Registry records — types, canonical signing, reader and writer

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/RegistryRecord.swift` (`DeviceRecord`, `PersonRecord`, `ClaimRecord` — the shapes in spec §2.1–2.3 exactly; `Codable`, `Sendable`, `Equatable`), `RegistryCanonical.swift` (canonical bytes + digest), `RegistryWriter.swift`, `RegistryReader.swift` (+ `Registry` value: roots, people, devices, claims, malformed)
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/RegistryRecordTests.swift`, `RegistryReaderWriterTests.swift`

**Interfaces (produced):**
- `RegistryCanonical.digest(of record: some Encodable) -> Data` — SHA-256 over sorted-keys JSON with the store's date encoding, `sig` excluded (records hold `sig` as an optional the encoder skips when nil; the writer signs the nil-sig encoding).
- `RegistryWriter.write(_ record: DeviceRecord | PersonRecord | ClaimRecord, signedBy: DeviceIdentity, in projectURL: URL) throws -> URL` — the ONLY production writer of the three directories; refuses (`DeviceIdentityError.unsigned`) for an identity that cannot sign; coordinated atomic write; filename = the record's own fingerprint field.
- `RegistryReader.load(projectURL:) -> Registry` — reads all three directories, verifies each signature against its `pub`, checks `key == filename fingerprint`, and for a person record that is not self-signed checks `admittedBy`'s key is the root's (the signer of a non-root record must be a root whose own record verifies). Unverifiable → `Registry.malformed: [MalformedRecord(url, reason)]`. Never throws for a malformed file; throws `ReadError.unreadableFile` for a present-but-unreadable one (RULING-54).
- `Registry.roots: [PersonRecord]` (self-signed, `admittedBy == person`), `.people`, `.devices`, `.claims`, `.malformed`; `Registry.chain(under root:) -> Set<fingerprint>` (transitive admitted persons), `Registry.actorFingerprints(ofDevice:) -> Set<fingerprint>`.

- [ ] Tests: round-trip each record through write → read with `softwareForTesting`; a byte flipped in the file → malformed with the reason; a record renamed to another fingerprint → malformed; a non-root person record signed by a non-root → malformed; an unreadable file throws; canonical bytes are stable across field order (encode two dictionaries).
- [ ] Implement; census: `TripwireGrepTests.test_registryRecordsAreWrittenThroughRegistryWriterOnly` — no `.maugham/people` / `.maugham/devices` path construction outside `RegistryWriter`/`RegistryReader` (Mac, Core, Phone) + planted offender; phone twin.
- [ ] Package + both gates (gen.sh first); commit `feat(registry): signed device, person and claim records — one writer, one reader, malformed listed never read`.

---

### Task 5: The registry cache — device-local, restores loudly

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/RegistryCache.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/RegistryCacheTests.swift`

**Contract:** `RegistryCache(fileURL: DeviceState.directory/registry-cache.json)`, keyed per project by the same root hash `OpLogDeviceState.fileKey` uses (reuse `OpLogDeviceState.projectRoot(of:)`/the hash; do not invent a second key), holding the last verified `Registry` (records as read, signatures included) plus `joinedRoot: fingerprint?` (B1's memory of the root that first named this device). `RegistryCache.reconcile(folder: Registry, cached: Registry?) -> (registry: Registry, restored: [URL], removedBySomeone: [RecordRef])`: a record in the cache and absent from the folder is **restored to the folder** through `RegistryWriter`'s raw re-write (the bytes are already signed) and reported; a record in both with different bytes keeps the FOLDER's if it verifies (it may be a legitimate re-sign, e.g. a device gaining an actor), else the cache's. Pruned with `OpLogDeviceState`'s roots (same parent-survives rule from Task 1).

- [ ] Tests: cache round-trip; a deleted person record is restored byte-identical and reported; a re-signed device record (new actor) from the folder replaces the cached one; a tampered folder record is replaced by the cached one and listed as malformed; `joinedRoot` survives reload and is never overwritten once set (B1) — attempting to set a second root records it under `claimants` instead.
- [ ] Implement; package gate; commit `feat(registry): the device remembers the registry it verified and restores a record someone removed`.

---

### Task 6: `TrustTable` — one pure function, six arms

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/TrustTable.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/TrustTableTests.swift`

**Interfaces (produced):**
```
public enum TrustVerdict: Equatable, Sendable {
  case mine, admitted(person: String), stranger(device: String?),
       revoked(person: String, highestOpIdSeen: String?), otherRoot(root: String), noChain
}
public struct TrustTable: Sendable {
  public static func resolve(registry: Registry, mine: LocalIdentities, joinedRoot: String?) -> TrustTable
  public func verdict(forSealKey fingerprint: String) -> TrustVerdict
  public var myRoot: String?        // nil == noChain
}
// Counting pending lines per device is the WALK's job (Task 7); the table answers verdicts only.
```
Rules (spec §3): `myRoot` = `joinedRoot` if set; else the root whose chain names any of `mine.fingerprints` (record it — the caller persists `joinedRoot`); else my own author fingerprint if a self-signed root record for it exists; else nil (`noChain`). With `myRoot == nil`, every non-mine key → `.noChain`. Otherwise: mine → `.mine`; an actor key of a device whose person is in `registry.chain(under: myRoot)` and not revoked → `.admitted`; revoked → `.revoked`; a key belonging to a self-signed root ≠ myRoot, or to anyone in that root's chain → `.otherRoot`; anything else with a verifiable seal → `.stranger(device: the device record naming it, if any)`.

- [ ] Tests: one per arm; the transitions — admit turns `.stranger` into `.admitted` on re-resolve; revoke turns `.admitted` into `.revoked`; a second root → `.otherRoot` for it and its admittees; `joinedRoot` set beats a self-signed record of my own (B1: joined once, stays); noChain when the registry is empty; noChain when a registry exists but names none of mine and I have no root record (the claim case, P2b). Every test is a pure value; no I/O.
- [ ] Implement; package gate; commit `feat(registry): TrustTable — who a seal's key is to this device, in six words`.

---

### Task 7: Pending — the walk takes a verdict; the stores build it from the table

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/OpLogChain.swift` (`verify(bytes:trusted:rememberedHead:)`; `Line.State` gains `case pending`; the walk assigns it), `OpLogProvenance.swift` (`FileProvenance.pending: Int`, `pendingByDevice: [String: Int]`; `OpLogProvenance.pendingLines`), `OpLogStore.swift` (`classifyTail` ~412 and `classifySegment` ~456 build the closure from a `TrustTable`; `loadFileDiagnosed`/`loadSyncMerged`/`ProjectIntegrity.check` gain a `trust: TrustTable?` parameter defaulting to a resolve over the project — the integrity check keeps its keyless Bool form), `TranslationStore.swift` (`loadMerged` builds from the table), `JSONLAppendStore.swift` (`ChainPolicy.trustedFingerprints: Set<String>` becomes `trust: TrustTable`; sites at ~102 and ~320), `InboxStore` readers on Mac and phone through `loadVerifiedStrict`
- Test: `OpLogChainTests`, `OpLogVerifiedLoadTests`, `OpLogStoreDiagnosedTests`, `TranslationChainTests`, `ChainedAppendTests`, plus a new `PendingLoadTests.swift`

**Contract:**
- `OpLogChain.verify(bytes:trust:(String) -> TrustVerdict, rememberedHead:)` is the walk; the existing `trusted: (String) -> Bool` overload maps `true → .mine`, `false → .noChain` and is used ONLY by the keyless integrity path and tests (census allow-list). A sealed span whose seal verifies cryptographically and whose key's verdict is `.stranger` → every line in the span is `.pending`; `.revoked`/`.otherRoot` → `.quarantined` with a new reason each (`afterRevocation` / `anotherClaimants`) — reasons are derived in the walk, never passed in (ADR 0032 §6's rule); `.noChain` → `.unsignedHistory` (P1); `.mine`/`.admitted` → `.verified`.
- `OpLogStore.applied(…)` excludes pending lines and writes NO `.lines` record for them; `FileProvenance` counts them per device; `Document.load` stamps `provenance` as today, so `doc.provenance.pendingLines` is readable.
- The chained WRITE path (`JSONLAppendStore.append`) is single-writer over this device's own file: a stranger's line in MY file is still a quarantine (unchanged); the table matters there only for which keys are mine (all four actors, as today).
- Census: `TripwireGrepTests.test_trustClosuresAreBuiltFromTheTrustTableOnly` — no `trusted: {` / `identities.fingerprints` / `trustedFingerprints.contains` in production outside `TrustTable` and the allow-listed keyless integrity site; planted offender; phone twin.

- [ ] Tests first: `PendingLoadTests` — a temp project with a root (software signer A) and a stranger (software signer B) writing a sealed file: reader A resolves → B's lines are `pending`, not in `ops`, no `.lines` record, `provenance.pendingByDevice[B] == n`; after A writes B's person record (Task 4's writer) → B's lines apply. Reader with NO chain (a third signer C with no records) → B's and A's lines both `unsignedHistory`, all applied (B3). A revoked B → quarantined with the revocation reason. Existing suites green unchanged (the P1 behaviour is the `.noChain` arm).
- [ ] Implement; all three gates; commit `feat(oplog): pending — a stranger's sealed span is held, not applied, not quarantined; the walk takes a verdict and the stores build it from one table`.

---

### Task 8: The device record at open — Mac and phone; the root; joining a chain

**Files:**
- Modify: `Maugham/Stores/DocumentStore.swift` (`open`'s sweep, ~185–240: before the seal/rotate loop), `MaughamPhone/Annotations/AnnotationWriter.swift` and `MaughamPhone/Capture/InboxCaptureWriter.swift` (the phone writes its device record beside its first write into a project — one shared MaughamCore helper, tripwire 19), `Packages/MaughamCore/Sources/MaughamCore/RegistryPresence.swift` (new: `ensureDeviceRecord(in:identities:name:kind:)` and `ensureRootIfEmpty(in:identities:)`)
- Test: `MaughamTests/Stores/RegistryPresenceTests.swift` (new), `MaughamPhoneTests/…RegistryPresenceTests.swift` (new), `Packages/MaughamCore/Tests/MaughamCoreTests/RegistryPresenceTests.swift`

**Contract (spec §2.1, §3 "who writes the first root record", §4.3):**
- `ensureDeviceRecord`: write or re-sign this device's `DeviceRecord` when absent or when its `actors` differ from `LocalIdentities.existingActors` (lazy keys: the assistant's appears after MCP's first write). Idempotent; never writes when identical.
- `ensureRootIfEmpty`: when the project has NO registry at all (no person records, malformed excluded), write this device's self-signed root `PersonRecord` with `label = ownName = device name`, `role: "author"`. When a registry exists and names none of mine → write nothing (the claim is P2b's; B3 governs reading).
- Joining (B1): when a person record naming my author fingerprint exists under a root and `RegistryCache.joinedRoot` is nil → set it; a second root naming me later → claimant, never a switch.
- Mac: in `DocumentStore.open` before the seal sweep, using `Document.loadIdentities` and the host name as `name` (the NAME, never the identity — tripwire 35 is about ids). Phone: at the first write into a project (both writers), with `UIDevice.current.name`. Unsigned device (no enclave): writes nothing and logs once (spec §4.1's loud unsigned).

- [ ] Tests: Mac — opening a fresh project writes a device record and a root record; a second open writes nothing (mtimes unchanged); minting the assistant's key then reopening re-signs the device record with two actors; a project already carrying another root's registry gets a device record and NO root. Phone — the writer's first append writes the device record; software signer throughout.
- [ ] Implement; all three gates; commit `feat(registry): every device declares itself at open — its record, its actors; the first Mac in an empty book is its root`.

---

### Task 9: History says it — the pending line and *joined a chain*

**Files:**
- Modify: `Maugham/Views/HistoryPane.swift` (beside `unsignedHistoryNotice`/`setAsideLinesNotice`, ~271–312, 382–391), `Maugham/OpLog/Document.swift` (`provenance` already stamped — nothing new unless the pane needs a per-device breakdown getter)
- Test: `MaughamTests/OpLog/HistoryNoticesTests.swift` (existing tests of the two statics — extend)

**Contract (spec §6):** `HistoryPane.pendingNotice(provenance:) -> String?` — *14 notes from iPhone are waiting for admission* (one device) / *N notes from 2 devices are waiting for admission* (several); the device's name comes from its device record where one exists, else the first four code characters. It carries an **Admit…** button — the one History line with a control — which in P2a posts nothing but is DRAWN disabled with the tooltip *Admission arrives with the next update*; P2b wires it. `HistoryPane.joinedChainNotice(cache:) -> String?` — *This Mac joined Denver's MacBook's chain on 9 Sep* (root's label from its person record; date from the cache's join stamp). Both pure statics; coalescing follows the pane's existing rule.

- [ ] Tests: the statics over provenance fixtures (one device, several, none); the notice absent when `myRoot == nil` (B3 — nothing is pending); the button asserted drawn and disabled, never pressed (tripwire 33).
- [ ] Implement; Mac gate; commit `feat(history): what is waiting for admission, and whose chain this Mac joined`.

---

### Task 10: Censuses and the notes

**Files:**
- Modify: `MaughamTests/TripwireGrepTests.swift`, `MaughamPhoneTests/TripwirePhoneGrepTest.swift` (the two censuses from Tasks 4 and 7 if not already landed there; planted offenders and controls), `Maugham/OpLog/AREA.md` (a "People and admission (P2a)" section: records, the cache, the table, pending, the two censuses as tripwires 10 and 11 of the area), `docs/adr/0032-the-signed-op-log.md` §6 (pending now exists; the third state's rule; B3) and §8 (what P2a built, what P2b adds), `CLAUDE.md` tripwires table (two rows: trust closures from the table only; registry records through the writer only), `docs/roadmap.md` (signed op log: P2a merged-unreleased)
- Test: the censuses themselves

- [ ] Both censuses present with planted-offender controls on Mac and phone.
- [ ] Docs as listed; count nothing in prose (name members).
- [ ] `./scripts/test.sh full`; commit `docs(oplog): P2a — records, trust and pending recorded; two tripwires`.

---

## Whole-branch review

Seams to name for the reviewer: B3's arm must make every P1 test pass unchanged (the P1 behaviour IS `.noChain`); the write path must not have learned pending (a stranger's line in my own file is still quarantine); `RegistryReader`'s signer check for non-root person records (a forged admission signed by a non-root must be malformed, not admitted); the cache's restore must never resurrect a record the folder holds a newer valid version of; `ensureRootIfEmpty` must never write a second root; Task 3's eleven callers — none swallows; the phone writes its device record through MaughamCore and nowhere else. Then `./scripts/test.sh full`, merge to local `main`, unpushed; P2b's plan is written against this code.
