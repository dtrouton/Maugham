# Signed op log P2 — people and admission (labels only)

**Date:** 2026-09-09 · **Status:** designed in discussion with Denver; three plans, each written after the one before is built (rule 11). **Parent spec:** `2026-09-05-signed-op-log-design.md` (§3 decisions, §4.2 registry, §4.4–4.7 states/admission/revocation/claim, §5 surfaces, §8 sequencing). **ADR:** [0032](../../adr/0032-the-signed-op-log.md), whose §8 names what P2 adds without a format change. **Built ground:** P1 (chain, seals, quarantine), P1b (four actors, `LocalIdentities`), the performance step (`OpLogDeviceState` records roots and prunes; `__project__` rotates).

## 0. What this milestone is, in one paragraph

P1 made every device's own writes tamper-evident and set aside anything the device did not write. P2 makes *other* devices' writes attributable and admitted: a per-project registry of signed records, a trust table derived from it, a third verification state (**pending**), one admission sheet per new device, People & Devices in Project Settings, revocation, and the claim on a keyless restore. **Labels only** (Denver, 2026-09-07): there is no person key. Every device is its own person; "Denver" is a label the author's key attaches to devices; the record shape carries `personFingerprint` so a synced person key can arrive later without a format change. No keychain item, no entitlement, no provisioning profile.

## 1. Decisions of record (Denver, 2026-09-09)

Three decisions from the P1 handoff, all option B, open the milestone as its first tasks:

- **D0 — an unreadable translation file refuses loudly.** `TranslationStore.loadMerged` throws on a present-but-unreadable device file (RULING-54's shape, the op log's own rule); the desk's status line, `read_translation`/`translation_status`, and the compile coverage gate each surface the file by name. No partial read anywhere.
- **D2 — set-aside notices are acknowledged, per device, per record.** An *Acknowledge* affordance on History's set-aside line and on the Inbox notice records the `.lines` filenames seen in this device's UI state; the sentence hides while every record is acknowledged and returns, counting new ones only, when a new record appears. Records are never touched; the Integrity window lists all of them.
- **D3′ — prune only when the parent directory exists and the root does not.** `OpLogDeviceState.prune` drops a project's heads only when its recorded root is gone *and* the root's parent directory is present, so an unmounted volume keeps its heads and a deleted project loses them.

Three decisions made in this design's brainstorm:

- **B1 — first admission wins, loudly.** A device joins the root that first writes a record naming its fingerprint. Its Settings names that root and shows the short code; History on every device says it joined; a second root's records are listed as *another claimant* and never merged. **A device never switches roots on its own.** This is the honest limit of labels-only — an admission record cannot prove which Mac signed it — and the same principle the restore claim already lives under.
- **B2 — one sheet per device, then silently into every project.** The Mac keeps `{deviceFingerprint: label}` in its own device state. On the first stranger it asks; on every later project it opens with that device's files present it signs the admission record without asking and History says so. A second Mac is a second root and asks once too, correctly.
- **B3 — no chain, no pending.** *Pending* exists only relative to a chain the reading device belongs to. A device with no root — no record naming it anywhere in this project — has no chain to judge by and behaves as P1: everything foreign is unsigned history, applied, with the History line. Once it has joined a root, seals from devices outside that chain are pending. Consequence: the phone never shows an empty chapter on the day P2 ships; the Mac, being its own root from the first open, holds the phone's ops until the sheet is answered, which is the case the spec wants.

## 2. Records and files

All records live per project, under `.maugham/people/` and `.maugham/devices/`, one JSON file each, named by fingerprint, and **every record is signed**: a `sig` over the record's canonical bytes (sorted keys, the store's own date encoding) with the same `{key, pub, sig}` credential shape the seal line and the `.mzseg.sig` sidecar already carry (`OpLogChain.Credentials`). A record whose signature does not verify against its own `pub`, or whose `pub` does not hash to the fingerprint in its name, is not a record; it is listed under Integrity as *a malformed record* and ignored.

### 2.1 Device record — `.maugham/devices/<authorFingerprint>.json`

```
{ "device": <authorFingerprint>, "name": "Denver's MacBook", "kind": "mac"|"phone",
  "actors": { "author": <fp>, "assistant": <fp>?, "translator": <fp>?, "maugham": <fp>? },
  "madeAt": <date>, "retiredAt": <date>?, "sig": {...} }
```

Signed by the device's **author** key. Written silently by every device the first time it opens a project under P2, and rewritten when an actor key it did not have before is minted (`LocalIdentities` is lazy: the assistant's key exists once MCP first writes). This is what lets a reader verify the assistant's seal on this Mac as *this Mac's assistant* rather than a stranger, and what lets People & Devices show what Claude wrote as Claude's. A retired device signs its own `retiredAt`.

### 2.2 Person record — `.maugham/people/<personFingerprint>.json`

```
{ "person": <personFingerprint>, "label": "Denver", "ownName": "Denver's iPhone",
  "role": "author", "admittedAt": <date>, "admittedBy": <rootFingerprint>,
  "revokedAt": <date>?, "revokedBy": <fp>?, "highestOpIdSeen": <ulid>?, "sig": {...} }
```

Under labels only a person IS a device: `personFingerprint == authorFingerprint` of that device. The **root**'s record is self-signed with `admittedBy == person`. Every other record is signed by the root's author key. `role` is written as `"author"` for everyone and read by nothing until P3, which adds `reviewer` and the per-op-kind check. `label` is the author's word; `ownName` is the device's own name at admission, shown as `<label> (<ownName>)` wherever the two differ (§3 of the parent spec).

### 2.3 Claim record — `.maugham/people/claims/<newRootFingerprint>.json`

```
{ "newRoot": <fp>, "adopted": [<oldRootFingerprint>, ...], "claimedAt": <date>, "sig": {...} }
```

Signed by the new root. It has no cryptographic authority over the old chain and does not pretend to (parent §4.7): it records that a device with folder access adopted history it could not verify, so that history stays attributed and every surviving device can say *a new Mac claimed this book on 9 Sep*.

### 2.4 The cache and the label memory — device-local, beside `op-log-state.json`

- `registry-cache.json`: the last registry this device verified, per project (keyed by `OpLogDeviceState`'s project-root hash, pruned with it). A record present in the cache and missing from the folder reads as *removed by someone*, loudly (a History line and an Integrity row), and is restored from the cache — safe because records are signed. Existence is the folder's and the backup's; signing protects authorship only.
- `admission-memory.json`: `{ deviceFingerprint: { label, ownName, labelledAt } }` — decision B2's memory. Pruned only by the writer (People & Devices → Forget this device); it is a fact about the writer's decision, not about a project.

### 2.5 What does not change

The wire format: `prev`, seal lines, `.lines` records, the segment container and its sidecar, `op-log-state.json`'s shape. `OpLogChain.verify` takes the same `trusted` closure it took in P1; P2 supplies a better closure. `DeviceSlug`, filenames, `DeviceActor`, `LocalIdentities`: untouched.

## 3. Trust resolution — one pure function

```
TrustTable.resolve(registry: Registry, mine: LocalIdentities) -> TrustTable
TrustTable.classify(sealFingerprint) -> .mine | .admitted(person) | .stranger(device?) | .revoked(person, highestOpIdSeen) | .otherRoot(root) | .noChain
```

- **`.noChain`** — decision B3: this device holds no key that any record in this project names, and it is not itself a root here (it has never written its own root record). Every foreign seal is `unsignedHistory`, as P1. The device becomes a root the first time it *admits* (a Mac answering the sheet) or joins one the first time a record names it.
- **`.mine`** — one of this device's four actor keys, as today.
- **`.admitted`** — the seal's key is an actor key listed in a device record whose person record is admitted under *this device's* root, transitively (the root's own record, then everyone it admitted). Verified.
- **`.stranger`** — a valid seal from a device with a device record (or none) but no person record under this root. **Pending**: held, not applied, not quarantined, no `.lines` record; counted per device so the sheet can say *N notes waiting*.
- **`.revoked`** — a person record under this root carrying `revokedAt`. Seals from it whose opIds exceed `highestOpIdSeen` are quarantined with the reason *after revocation*; seals with earlier opIds arriving later are quarantined with *may be late sync or may be backdated* and the History line offers Apply (parent §4.6).
- **`.otherRoot`** — a self-signed person record that is not this device's root and did not admit it: another claimant. Its seals, and the seals of everyone admitted under it, are quarantined with the reason *another claimant's*; People & Devices lists the claimant; nothing merges.

Which root is *mine*: the root whose chain first named this device (B1), remembered in the cache; absent that, this device itself once it has admitted anyone or written its own root record. A device that finds itself named under two roots keeps the first and lists the second as a claimant. A root cannot be revoked, only claimed over (§5). **Who writes the first root record:** a Mac opening a project that has no registry at all writes its own self-signed root record at that open — it created the book or owns the folder, and there is nobody else to ask. A Mac opening a project that already has a root it is not under, and no record naming it, is offered the claim (§5) or reads as `.noChain` (B3); it never writes a second root silently.

`OpLogStore` builds the closure from the table and classifies a new `OpLogChain.Line.State.pending(device:)`; `OpLogProvenance`/`FileProvenance` gain a `pending` count and a per-device breakdown; `Document.load` applies nothing pending and stamps the counts on the document as it stamps unsigned history today. Admission re-reads; nothing is rewritten and no `.lines` record is ever made for a pending line.

**Censuses (tripwire shape):** no `trusted:` closure is built anywhere in production except from a `TrustTable` (`OpLogStore` today has two: the load's and the integrity check's keyless one — the second stays keyless by design and is allow-listed by name); no record under `.maugham/people/` or `.maugham/devices/` is written except through `RegistryWriter`, which signs.

## 4. Admission

### 4.1 The sheet (root device, Mac only)

Trigger: at project open, and when the sidecar presenter reports a new stranger's file, the Mac finds pending lines from a device with no person record. One sheet, non-modal to the project window, one per stranger:

> **iPhone (Denver's iPhone) wants to write in *Playlist*** — 14 notes waiting.
> Label: [Denver ▾] (proposes `ownName`; the picker lists known labels for *this is also…*)
> Code **4F2K** is shown on the phone's Settings too.
> [Not now] [Admit]

Admit writes the person record signed by this Mac's author key with the chosen label, records `{fingerprint: label}` in admission memory, and the held ops apply on the next load (immediate: the store re-resolves and re-reads the affected files). *Not now* dismisses until the next open; the notes stay pending and the pending count stays visible in History. The code is the first four characters of the device's fingerprint in the same alphabet the slug uses; it is **shown, never demanded**. A typed label matching an existing one merges the device under that label; nobody can be admitted *as* a new "Denver" by asking.

### 4.2 Silent admission (decision B2)

At every project open, for every stranger whose fingerprint is in admission memory, the Mac writes the person record with the remembered label without asking, and History says *iPhone (Denver's iPhone) admitted as Denver, remembered from Playlist*. The memory is device-local, so a second Mac asks once; that is correct, it is a different root.

### 4.3 The device's own view

A device that finds a record naming its author fingerprint adopts that root (B1), remembers it in the cache, and from then on classifies against that chain. The phone's Settings shows *This phone is Denver on Denver's MacBook's chain since 9 Sep (code 4F2K)*; a Mac's shows the same in People & Devices. Before any record names it: *Not yet admitted — the Mac will ask*, and it reads as P1 (B3).

### 4.4 Actors under admission

Admitting a device admits every actor key its device record lists, because they are that device's. A device record that later gains an actor (the assistant's key minted on first MCP write) is re-signed by the device; a reader already trusting the device trusts the new actor from the re-signed record — no second sheet. People & Devices shows the actors under the device (*author, assistant, translator*), which is how Claude's notes on this Mac read as Claude's in the byline (`list_annotations`' `author` is unchanged; it already carries the resolved name).

## 5. Revocation, retirement, the claim

- **Revoke** (People & Devices, a person or one device): the root writes `revokedAt`, `revokedBy` and `highestOpIdSeen` (the highest opId this Mac has applied from that device) into the person record and re-signs it. Later seals classify per §3. The one sentence beside the button: *This stops Maugham applying what this device writes. To stop it writing at all, remove it from the iCloud share.*
- **Retire** (a device retires itself, or a person retires their own devices): the device writes `retiredAt` into its own device record and re-signs. Its future seals are quarantined as *after retirement* on every reader; its past stays verified.
- **The claim** (parent §4.7): a Mac that can write the folder, holds no key any record names, and finds a registry with a root it is not under, is offered one sheet — *This book's history was written by devices this Mac doesn't know (Denver's MacBook, iPhone). Is it yours?* Claim writes this Mac's self-signed root record plus a claim record adopting the old root(s); the old chain's devices are listed as *adopted* with their history verified against the old root and attributed; every device still on the old chain shows the claimant line and keeps its own root (B1). *Not mine* leaves everything as B3's `.noChain`: applied as unsigned history, with the line.

## 6. Surfaces (every new data type gets one)

- **Project Settings → People & Devices** (a new section of `ProjectSettingsSheet`): pending requests at the top with Admit; one row per label — label, `(ownName)` when different, role (read-only in P2), admitted date, Revoke — with devices nested: name, kind, its actors, added, Retire; the root marked *this Mac*; claimants and claims listed; *removed by someone* records restored from the cache flagged; the share sentence. A **Forget this device** on a remembered-but-absent device clears admission memory.
- **History** carries the audit lines, each a pure static like the two that exist: admitted (with label), joined a chain, silently admitted, revoked, retired, claimed, another claimant, a record restored from cache; the pending count (*14 notes from iPhone are waiting for admission*) with Admit… as the one History line that carries a control, because the writer can act on it.
- **Inbox** rows from a pending device show *from iPhone (not yet admitted)*; from an admitted one, the label.
- **Phone → Settings**: this device's code, its chain and label, or *not yet admitted*. No control (admission is a Mac act in this milestone). The Annotations tab is unchanged in P2; posture by role is P3.
- **Integrity** (Statistics window): malformed records, cache restorations, claimants.
- Nothing in the tree, the footer or a badge (constitution must #2).

## 7. What Claude sees

Nothing new is written through MCP. `list_annotations` already resolves `author`. A `list_people` read is a widening for a later milestone if a use appears.

## 8. Plans (rule 11: build each before writing the next)

- **P2a — records, trust, pending.** D0, D2, D3′ as three small tasks; `RegistryRecord` types and canonical signing (`RegistryWriter`/`RegistryReader` in MaughamCore, software signers in tests); the cache; `TrustTable.resolve`/`classify` with every arm pinned windowlessly; `Line.State.pending`, the provenance counts, `OpLogStore` building its closure from the table (B3's `.noChain` arm first, so nothing regresses); the device record written at open on Mac and phone; History's pending line and the two audit lines that need no sheet (joined a chain, silently admitted — the second lands in P2b when memory exists, so P2a ships the first). Paired schema: the phone reads records through MaughamCore.
- **P2b — the sheet, the memory, the pane.** The admission sheet and its windowless decision model; admission memory and silent admission; People & Devices; the phone's Settings row; the Inbox byline.
- **P2c — revocation, retirement, the claim, the docs.** The three record mutations and their classifications; the claim sheet; Integrity's rows; ADR 0032's P2 section, the OpLog/Stores/Phone area guides, the History and Settings guides, the roadmap; tripwire rows for the two censuses.

Release binds at the end of P2c as a paired Mac + phone release: the phone learns to read records in P2a and would otherwise be reading a registry it cannot verify.

## 9. Testing

- Every trust decision is a pure function over records: one test per arm of `classify`, plus the transitions (stranger → admitted applies the held ops; admitted → revoked quarantines by opId; two roots → claimant; no chain → unsigned history). Falsified by planting: a `trusted` closure built from `LocalIdentities.fingerprints` outside the table (the census), a record written without a signature (the census).
- Round-trip integration: Mac root admits a software-signed "phone" identity in a temp project; the phone's reader then verifies the Mac's seals and its own; a second software root's records classify as a claimant on both.
- The sheet: its decision (label chosen, merge-into-existing, code shown) pinned on a plain value; the control is asserted drawn, never pressed-and-awaited (tripwire 33).
- The phone: `TripwirePhoneGrepTest` twin for the two censuses; the Settings row reads the same `TrustTable` the Mac does (tripwire 19).

## 10. Out of scope

The synced person key and its provisioning pipeline (its own milestone, on one of the three conditions in the parent spec §8); roles and the per-op-kind check (P3); admission from the phone; any server; re-signing legacy history; encryption.
