> Full report for items 2 and 3 of the signed-op-log §7 spike, written by the measuring subagent on 2026-09-07. Digest: `2026-09-07-signed-op-log-spike.md`. The probe sources and raw output files it names lived in the session scratchpad and are not kept; the commands, flags and numbers are reproduced inline.

# Signed op log — spike items 2 and 3

Measured 2026-09-07 for `docs/superpowers/specs/2026-09-05-signed-op-log-design.md` §7.
Nothing in the Maugham repo was modified. All work lives in
`/private/tmp/claude-501/-Users-denver-src-Maugham/92242986-82d7-421d-9f55-8820c1bdd104/scratchpad/spike/`.

## Machine and build flags

| | |
|---|---|
| Hardware | Apple M4, MacBook Air (`Denvers-MacBook-Air.local`) |
| OS | macOS 26.6.2, build 25G83, Darwin 25.6.0 arm64 |
| Toolchain | Apple Swift 6.3.3 (swiftlang-6.3.3.1.3), Xcode 26.6 (17F113) |
| Target | `arm64-apple-macosx26.0` |
| Probe binaries | `swiftc -O src/<name>.swift -o bin/<name>` — ad-hoc, linker-signed, **no entitlements**, no Info.plist, `TeamIdentifier=not set` |
| Benchmark | `swiftc -O -whole-module-optimization src/bench.swift -o bin/bench` |
| One extra binary | `codesign -f -s "Developer ID Application: Denver Trouton (FF3XH4ZJ45)" --timestamp=none bin/kcfresh-devid` |

Timing is `DispatchTime.now().uptimeNanoseconds`. Every figure below is a
**median**; each measurement was repeated 5–7 times inside a run, and the whole
benchmark was run three times (raw output in `data/bench-run{1,2,3}.txt`).

---

# Item 2 — Enclave availability, and the software fallback's ACL

## 2(a) Secure Enclave

Source `src/enclave.swift`, raw output `data/enclave-run.txt`.

```
SecureEnclave.isAvailable = true
```

| probe | result |
|---|---|
| A1 `SecureEnclave.P256.Signing.PrivateKey()`, no access control | **works** — create, sign, verify, all from an ad-hoc binary with no entitlements |
| A1 `dataRepresentation` | 284 bytes; persisted to a file, reloaded, re-signed, same public key, verifies |
| A1 signature | 64 bytes raw / 72 bytes DER |
| A2 `PrivateKey(accessControl:)` with `SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage], …)` | **works** — blob 324 bytes, signs and verifies, no prompt |
| A3 `SecKeyCreateRandomKey` with `kSecAttrTokenIDSecureEnclave` + `kSecAttrIsPermanent: true` | **fails** |
| A4 same, plus `kSecUseDataProtectionKeychain: true` | **fails** |

A3/A4 error text, verbatim:

```
Error Domain=NSOSStatusErrorDomain Code=-34018 "failed to add key to keychain: <SecKeyRef:('com.apple.setoken') 0x1012e1e30>" UserInfo={numberOfErrorsDeep=0, NSDescription=failed to add key to keychain: <SecKeyRef:('com.apple.setoken') 0x1012e1e30>}
The operation couldn’t be completed. (OSStatus error -34018 - failed to add key to keychain: <SecKeyRef:('com.apple.setoken') 0x1012e2490>) code=-34018
```

`-34018` is `errSecMissingEntitlement`. The key itself is created inside the
SEP fine; what fails is *storing it as a permanent keychain item*.

**Plain-language answer.** The Secure Enclave is available on this Mac and an
ad-hoc-signed command-line binary with no entitlements whatsoever can mint a
P256 signing key in it, sign with it, persist its opaque 284-byte
`dataRepresentation` to an ordinary file, reload that blob in a later process
and sign again with the same key. Both the plain constructor and the
`accessControl:`-carrying one work. What does *not* work without entitlements
is the older `SecKeyCreateRandomKey` + `kSecAttrIsPermanent` route, which tries
to store the enclave key as a keychain item and is refused with
`errSecMissingEntitlement` (-34018) on both the file keychain and the
data-protection keychain. That is not a problem for the spec: CryptoKit's
`SecureEnclave` type is designed around persisting the blob yourself, the blob
is useless off this Mac's SEP, and `.maugham/` or Application Support is a
perfectly good home for it. **The device key in §4.1 is buildable today with no
entitlement work at all**, as long as P1 persists the `dataRepresentation` and
does not try to make the enclave key a keychain item.

## 2(b) The software fallback's Keychain ACL — does it keep the key from a shell process?

**No.** Not in any configuration measured. Every attempt to read the raw
private key from an unrelated process succeeded silently, with no prompt.

Sources `src/kcwriter.swift`, `src/kcreader.swift`, `src/kcacl.swift`,
`src/kcfresh.swift`, `src/kcread2.swift`, `src/kcprompt.swift`. Raw output in
`data/kc*.txt`, `data/security-read*.txt`, `data/foreign-read-devid.txt`.

### Which keychain will even take the item

Writer = `bin/kcwriter`, ad-hoc, no entitlements (`data/kcwriter-run.txt`):

| item shape | `SecItemAdd` status |
|---|---|
| B1 default (legacy file-based login keychain) | `0 (No error.)` |
| B2 `kSecUseDataProtectionKeychain: true` | `-34018 (A required entitlement isn't present.)` |
| B3 data-protection + `kSecAttrSynchronizable: true` | `-34018 (A required entitlement isn't present.)` |
| B4 legacy keychain + `kSecAttrSynchronizable: true` | `-34018 (A required entitlement isn't present.)` |

B4 is worth flagging for spike item 1 (not mine): a **synchronizable** item is
refused to a non-entitled binary on the legacy keychain too, not only on the
data-protection one. So the §4.1 person key needs the entitlement regardless of
which keychain it targets.

### Reading it from another process

Item created by `bin/kcwriter` (CDHash `805021786c41…`). Readers:

| reader | identity | interaction | result |
|---|---|---|---|
| `bin/kcreader` | different ad-hoc binary, CDHash `e5dccc6bb479…` | disallowed via `SecKeychainSetUserInteractionAllowed(false)` | `READ REFUSED: -25293 (The user name or passphrase you entered is not correct.)` |
| `bin/kcreader` | same | allowed (default) | **`READ SUCCEEDED SILENTLY: 32 bytes sgDsaInsQvWfc6AT//JdLVq+EhlaGDNPM7nMkNjN3bA=`** — returned immediately, no dialog |
| `/usr/bin/security find-generic-password -w -s com.maugham.spike.person-key -a spike` | Apple-signed shell tool | allowed | **succeeded silently**, printed `b200ec6889ec42f59f73a013fff25d2d5abe12195a18334f33b9cc90d8cdddb0` (the same 32 bytes in hex) |

An attributes-only query (`kSecReturnAttributes`) succeeds for *any* process
with status `0` and no ACL check at all, returning `acct, cdat, class, labl,
mdat, svce`. Only the secret material is gated. Item metadata leaks freely.

### Why: the partition list, and how it widens

`src/kcacl.swift` and `src/kcfresh.swift` dump the item's real ACL.

A **fresh** item, dumped in the same process that created it before any other
process has touched it, carries exactly one partition:

```
ad-hoc creator:   <string>cdhash:afd51408b9cf1931f0eabd5433b4b12489cdd23f</string>
Developer-ID creator: <string>teamid:FF3XH4ZJ45</string>
```

and a decrypt ACL trusting 1 application with `promptSelector=0`.

After the two foreign reads above, the *same* item's partition list reads:

```
<string>cdhash:805021786c41dc743f88ee369c4d09d59c5c7af1</string>   ← the writer
<string>cdhash:e5dccc6bb47929bea3f16916842bd8ca2c6b2f9e</string>   ← the foreign reader
<string>cdhash:e5dccc6bb47929bea3f16916842bd8ca2c6b2f9e</string>   ← again, second run
<string>apple-tool:</string>                                        ← /usr/bin/security
```

Each reader **added itself to the partition list**, and each read returned the
key material, with no authorization dialog at any point.

### Three attempts to harden it, all defeated

| configuration | foreign reader result |
|---|---|
| C1 explicit `SecAccessCreate(…, [self], …)` passed as `kSecAttrAccess` — the classic "only this app" shape | `/usr/bin/security` read it silently: `86cbd7e5b6e63bec37c201d316ca7deb1db683e9ae385f29dd46ab5c2779000d` |
| Item created by a **Developer-ID-signed** binary (`Authority=Developer ID Application: Denver Trouton (FF3XH4ZJ45)`, `TeamIdentifier=FF3XH4ZJ45`), i.e. the shape the shipped app actually has | `/usr/bin/security` read it silently (`612d3993…`); the foreign ad-hoc `bin/kcread2` read it silently too, and the partition list afterwards was `teamid:FF3XH4ZJ45`, `apple-tool:`, `cdhash:57f5d864…` |
| `SecACLSetContents(acl, apps, desc, SecKeychainPromptSelector.requirePassphase)` on the decrypt ACL — the strongest legacy lever | foreign reader: **`READ SUCCEEDED SILENTLY: 32 bytes bbf1e1c84f1019dbb64e92bbcd553dbed259a66b65d03b5518d2afa6b229a3d8`** |

The only configuration that ever refused was one where the *reader itself*
disabled interaction (`-25293`), which is the reader's own choice and no
protection at all.

**Plain-language answer.** No — on this Mac, running macOS 26.6.2 with the
login keychain unlocked, a software P256 key in the Keychain does not keep
itself from a shell process. A different binary, an Apple-signed tool like
`/usr/bin/security`, and a Developer-ID-signed writer's own item were all read
in full, silently, with no dialog and no keychain password, and each reader
quietly appended itself to the item's partition list on the way through. An
explicit self-only `SecAccess` did not change that, and neither did the
`requirePassphase` prompt selector. The keychain that *would* enforce this —
the data-protection keychain, which has no partition-list widening — refuses a
non-entitled binary outright with `errSecMissingEntitlement` (-34018), so it is
not reachable until the app carries a keychain-access-group entitlement (spike
item 1's territory). The practical consequence for the spec: the §4.1 software
fallback must be described as a *provenance* key, not a *secret* one. Anything
in the design that leans on "an agent with a shell cannot sign as this device"
holds for the Secure Enclave key and does **not** hold for the fallback, on a
Mac where the writer is logged in. §4.4's central scenario — an agent with a
shell appends an op and cannot sign it — is true on enclave-equipped Macs and
false on a fallback Mac, where the same agent can read the key and sign
convincingly.

## 2(c) The T2-less Intel Mac

**Not measured, and not measurable here.** This is an Apple M4 running macOS
26.6.2. There is no Intel hardware in this session, so
`SecureEnclave.isAvailable == false` and the fallback path it selects were
never exercised on the machine the spec is asking about. What the measurements
above *do* establish is that the fallback path itself compiles, runs and stores
on this Mac, and that its ACL provides no confidentiality — a finding that
carries to the Intel case unchanged, since it is a property of the login
keychain rather than of the CPU. Whether `SecureEnclave.isAvailable` returns
false cleanly on a T2-less Intel Mac, rather than throwing, is untested.

---

# Item 3 — Cost

## How the op log is actually appended today — and a correction to §4.3

I read the write path before shaping the benchmark, and it does not match the
spec's premise.

- `OpLogStore.append(_ op: Op)` (`Packages/MaughamCore/Sources/MaughamCore/OpLogStore.swift:217`)
  takes **one `Op`** and hands it to `JSONLAppendStore<Op>.append(_:)`.
- `JSONLAppendStore.append` (`Packages/MaughamCore/Sources/MaughamCore/JSONLAppendStore.swift:91`)
  encodes **that single element**, opens a coordinated `FileHandle`, seeks to
  the end and writes **one line**.
- Every production caller passes a single op — `Document.swift:183`,
  `Document.swift:1099`, `Document+Annotations.swift` (five sites),
  `Document+Rewind.swift`, `Document+RewindUndo.swift`, `Document+Load.swift`,
  `CheckpointCapture.swift:73`, `Document+Tasks.swift:224`,
  `ProjectStore+Tasks.swift:118`.
- `PendingBuffer.flushToDisk` is a different thing entirely: an atomic
  whole-file write of `{basis?, changes, sequence}` to
  `.maugham/pending/<docId>.<slug>.pending.jsonl`, deliberately kept **off**
  the op-log glob. It never appends to `.maugham/ops/`.

**So the real append unit is one op per file write — batch size 1.** §4.3's
"`PendingBuffer`'s flush is already the append unit" is not true of the code as
it stands, and its parenthetical "verification of a 50k-op log is then hundreds
of verifies, not tens of thousands" does not follow from the current write
path. At today's grain it is exactly 50,000 verifies.

For context on how a 50k-op log accumulates: `BurstScheduler` is constructed
with `idle: .seconds(30), max: .seconds(90)` (`Document+Load.swift:83`), so a
typing burst closes into one op every 30–90 seconds of work. 50,000 ops is on
the order of 800+ hours of writing in one document. Signing cost at write time
is therefore irrelevant per-op; the whole question is verify-on-load.

The seal digest is `OpLogSegment`'s existing SHA-256 over the **uncompressed**
JSONL bytes, stored in the 48-byte `MZS1` header.

## The corpus

Modelled on the real file
`/Users/denver/Documents/Maugham/Playlist/.maugham/ops/doc-0e8b0a00.denvers-macbook-air-loca-8a62e7c9.jsonl`
(copied read-only to `data/real-sample.jsonl`; never written to). Op kinds are
sampled at the real file's observed frequencies (89.1% `typing_burst`, 6.7%
`claude_accept`, 1.6% `checkpoint`, the rest `claude_suggestion` /
`claude_archive` / `claude_reject`), 15.5% of lines carry a `sequence` array
because 67 of 432 real lines do, and the encoder uses `JSONLAppendStore`'s own
`.sortedKeys` + custom fractional-second ISO8601 date strategy.

| | real sample (432 lines) | generated (50,000 lines) |
|---|---|---|
| mean line | 769 B | 719 B |
| p10 | 286 | 231 |
| p25 | 314 | 250 |
| p50 | 363 | 325 |
| p75 | 783 | 564 |
| p90 | 2377 | 2345 |
| max | 4229 | 4509 |
| total | 332 KB | 35.9 MB |

## Baseline cold load

`data/bench-run2.txt` / `run3`. Read the file, split on `0x0A`, `JSONDecoder`
each line into the `Op` shape with the production date strategy.

| step | run 2 | run 3 |
|---|---|---|
| read file (35.9 MB) | 2.50 ms | 2.44 ms |
| split lines | 120.26 ms | 122.1 ms |
| JSONDecoder decode 50,000 lines | 1735.82 ms | 1889 ms |
| **baseline total** | **1859.80 ms** | **2014.35 ms** |

Attribution of the decode, same corpus, same run:

| decoder configuration | median |
|---|---|
| production custom ISO8601 strategy | 1735.82 ms |
| built-in `.iso8601` strategy | 650.20 ms |
| date field not decoded at all | 267.45 ms |

Not what the spike was asked for, but load-bearing for the verdict: **a 50k-op
cold open already costs ~1.9 s today, and about 1.09 s of that is
`JSONLAppendStore`'s custom `ISO8601DateFormatter` date strategy** — one
formatter call per line. There is far more headroom available there than any
signature scheme will consume.

## Hash chain

SHA-256 per line, chained with the previous line's hash (`prev`), 50,000 lines,
35.9 MB.

| | run 2 | run 3 |
|---|---|---|
| whole chain | 31.59 ms | 33.36 ms |
| per line | 0.632 µs | 0.667 µs |

## Signing

| operation | median |
|---|---|
| one **Secure Enclave** P256 signature | **4489.7 µs** (4.49 ms) |
| one **software** P256 signature | **83.5 µs** |
| one verify of an enclave-made signature (CPU) | 75.8 µs |
| one verify of a software signature (CPU) | 77.6 µs |

**Confirmed as asked:** verify is pure CPU and identical for both key types.
`P256.Signing.PublicKey(rawRepresentation: seKey.publicKey.rawRepresentation)`
round-trips, and that plain public key verifies an enclave-made signature
(`true` in every run). The 2.3% gap between the two verify figures is noise.

The enclave is **54× slower per signature** than software P256 — it is a
round-trip to the SEP, not a CPU operation. Enclave totals below are
extrapolated from a bounded sample of 250–300 real enclave signatures per batch
size (signing 50,000 times takes ~3.7 minutes); software totals are measured in
full.

Total signing cost for all 50,000 ops, at each grain:

| batch | signatures | enclave total | software total | enclave per op | software per op |
|---|---|---|---|---|---|
| **1** (today's real unit) | 50,000 | 225,427 ms (3 min 45 s) | 4184.4 ms | 4.49 ms | 83.5 µs |
| 10 | 5,000 | 22,352.6 ms | 418.2 ms | 0.45 ms | 8.4 µs |
| 50 | 1,000 | 4,449.6 ms | 83.3 ms | 89.9 µs | 1.7 µs |
| 58 | 863 | 3,847.5 ms | 72.0 ms | 77.5 µs | 1.4 µs |
| 100 | 500 | 2,235.9 ms | 41.5 ms | 44.8 µs | 0.8 µs |
| 200 | 250 | 1,114.0 ms | 20.8 ms | 22.4 µs | 0.4 µs |

Read the totals as *lifetime* cost, not per-open. At the live cadence — one op
per 30–90 s — a 4.49 ms enclave signature per append is invisible.

## Verify on load

50,000 / batch verifies. Both runs shown; the run-to-run spread is ~1–3%.

| batch | verifies | run 2 | run 3 | µs per verify |
|---|---|---|---|---|
| 1 | 50,000 | 3910.00 ms | 3959.47 ms | 78.2 / 79.2 |
| 10 | 5,000 | 387.50 ms | 396.28 ms | 77.5 / 79.3 |
| 50 | 1,000 | 77.22 ms | 78.96 ms | 77.2 / 79.0 |
| 58 | 863 | 66.99 ms | 69.90 ms | 77.6 / 81.0 |
| 100 | 500 | 38.39 ms | 40.15 ms | 76.8 / 80.3 |
| 200 | 250 | 19.26 ms | 20.41 ms | 77.1 / 81.6 |

## Segment-level (the seal shape)

| operation | median |
|---|---|
| SHA-256 over the whole 35.9 MB file | 10.92 ms |
| one enclave signature over that digest | 4.60 ms |
| one software signature over that digest | 0.092 ms |
| one verify of that signature | 0.071 ms |
| **whole sealed-segment verify path (digest + 1 verify)** | **10.99 ms** |

## Combined added cost to a cold open, at 50k ops

Added cost = hash chain over every line + one signature verify per batch.
Baseline for reference: 1859.80 ms (run 2) / 2014.35 ms (run 3).

| batch | signatures | chain | verify | **added** | % of baseline | under 100 ms? |
|---|---|---|---|---|---|---|
| **1** (today's grain) | 50,000 | 31.59 ms | 3910.00 ms | **3941.59 ms** | 211.9% | **NO** — 39× over |
| 10 | 5,000 | 31.59 ms | 387.50 ms | **419.09 ms** | 22.5% | **NO** — 4.2× over |
| 50 | 1,000 | 31.59 ms | 77.22 ms | **108.81 ms** | 5.9% | **NO** (103–112 ms across runs) |
| 58 | 863 | 31.59 ms | 66.99 ms | **98.58 ms** | 5.3% | borderline — 98.6 ms run 2, 103.3 ms run 3 |
| 100 | 500 | 31.59 ms | 38.39 ms | **69.98 ms** | 3.8% | **YES** (70–74 ms) |
| 200 | 250 | 31.59 ms | 19.26 ms | **50.85 ms** | 2.7% | **YES** (51–54 ms) |

The chain alone is 31.6 ms — a third of the budget spent before the first
verify. That leaves ~68 ms for signatures, i.e. ~870 verifies, i.e. a break-even
grain of ~58 ops per signature, which lands exactly on the noise floor: batch 58
came in at 98.6 ms in one run and 103.3 ms in the next. **The first grain with
real margin is 100 ops per signature.**

**Plain-language answer.** At the grain the code actually appends at today —
one op, one line, one signature — verifying a 50,000-op log on open costs about
3.9 seconds, roughly 39 times the 100 ms budget, and that is before the hash
chain. Batching helps linearly, but the budget is not met until roughly 100 ops
share a signature, where the total added cost is about 70 ms (31.6 ms of hash
chain plus 38.4 ms of signature verification); at 58 ops per signature it
straddles the line and cannot be relied on. Since the append path writes one op
per file write and the burst scheduler closes a burst every 30 to 90 seconds,
there is no natural 100-op batch to sign at write time, so the spec cannot get
to a safe grain by batching appends. **Segment-level caching has to move earlier
in P1, and it comfortably can**: verifying a sealed segment costs 11 ms — one
SHA-256 over the whole 36 MB plus a single 71 µs verify — and the spec already
says a verified segment is cached by content hash and never re-verified, so on a
warm open even that 11 ms disappears and only the unsealed tail carries per-batch
verification. With the seal threshold at 512 KB, a tail is at most ~700 ops, so
the live tail is 700 verifies at batch 1, about 55 ms, which fits. Two other
things are worth carrying into the plan: enclave signing costs 4.49 ms per
signature against software P256's 83.5 µs — a 54× gap that is harmless at one
signature per 30–90 s burst but rules out signing anything in a loop — and
verification is pure CPU and identical for both key types, so an enclave-signed
log verifies no more slowly than a software-signed one. Finally, the budget is
being measured against a cold open that already takes about 1.9 seconds, of
which roughly 1.09 seconds is `JSONLAppendStore`'s custom `ISO8601DateFormatter`
date strategy calling a formatter once per line. If the 100 ms budget ever
proves too tight, that is where the headroom is, not in the crypto.

---

## Files

| path | what |
|---|---|
| `src/enclave.swift` | item 2(a): `SecureEnclave.isAvailable`, in-memory key, access-control key, both `SecKeyCreateRandomKey` routes |
| `src/kcwriter.swift` | item 2(b): stores a software P256 key four ways (legacy, data-protection, both synchronizable) |
| `src/kcreader.swift` | second binary, distinct CDHash — reads with and without interaction |
| `src/kcacl.swift` | dumps the item's real `SecAccess` ACL list and partition plist; adds a self-only `SecAccess` item |
| `src/kcfresh.swift` | creates an item and dumps its partition list before any other process touches it (also signed Developer ID as `bin/kcfresh-devid`) |
| `src/kcread2.swift` | third binary — foreign reader taking a service name, dumps the partition list afterwards |
| `src/kcprompt.swift` | creates an item whose decrypt ACL carries `SecKeychainPromptSelector.requirePassphase` |
| `src/bench.swift` | item 3: generator, baseline load, chain, sign, verify, segment, combined |
| `data/bench-run{1,2,3}.txt` | full benchmark output; run 1 used an untuned generator (mean 871 B) and is kept for comparison |
| `data/real-sample.jsonl` | read-only copy of the real Playlist op-log file |

Every keychain item this spike created was deleted afterwards
(`security delete-generic-password` on all six services; a subsequent
`security dump-keychain | grep -c maugham.spike` returns 0).
