# Your devices are you — plan 1 outcome (2026-09-28)

**Plan:** `docs/superpowers/plans/2026-09-27-your-devices-are-you-plan1-the-person-key.md`.
**Spec:** `docs/superpowers/specs/2026-09-27-your-devices-are-you-design.md`.
**Spike:** `docs/superpowers/notes/2026-09-27-person-key-spike.md` (GO).
**Branch:** `claude/your-devices-are-you-p1`, off main `1ca33798`.
**Ledger, rulings and task reports:** `.superpowers/sdd/2026-09-27-your-devices-are-you-plan1-the-person-key/`.
**Decision of record:** [ADR 0032](../../adr/0032-the-signed-op-log.md)'s addendum *your devices are you, plan 1: the person key*.

## What shipped

Plan 1 built the Core and Mac halves. **It ships no entitlements**, so no
production build makes a claim yet. Every build reads the keychain as
unavailable, and admission is exactly what it was. The writer-facing guide
(`docs/guide/people-and-devices.md`) is unchanged for that reason: help
describes what ships. The text Task 7 proposed for it waits for plan 2.

- **The person key** (Task 2): `PersonKey`, `PersonKeyStore`, and the keychain
  and in-memory stores. It is the one production software key, named in
  tripwire 36's allow-list.
- **The claim** (Task 3): `DeviceRecord.personClaim`, signed over a domain-tagged
  canonical form bound to the containing record's device. It is signed by
  `RegistryWriter.personClaim`, verified by `RegistryReader.verifiedPersonClaim`,
  and written through `ensureDeviceRecord`'s explicit `PersonClaimIntent`.
- **Link and Forget** (Task 4, then Task 6's fix round):
  `PersonRecord.personKey` and `forgottenPersonKeys`. Link and Forget are
  root-only and label-wide. Forget is durable, and a partial Forget says what
  it cleared. Each Forget is dated on the records and History draws one row
  for it (`TrustEvent.Kind.personKeyForgotten`, the whole-branch fix wave). Every person-key fact is read from this root's chain only.
- **The recognition decision** (Task 5): `Recognition.recognise`, pure, every
  doubt an ask. Revoked records neither help nor block.
- **The silent admission** (Task 6): `RegistryAdmission.admitRecognised` admits
  with the current timeline permit, carries the governing photograph, and
  writes `silentlyAdmitted` with reason `recognised`.
  `RegistryPresence.admitRecognised` runs the link-recognise-admit pass.
  Recognition runs before the remembered pass, and the remembered pass no
  longer hands a narrowed person the whole book. Both passes are single-flight.
- **The surfaces** (Task 7): the sheet's claim lines and pre-fill (never a
  merge), People & Devices' *Recognised…* line and **Forget This Person Key**,
  Revoke's note about Forget, and History's *recognised by their Apple ID*.
- **The censuses** (Task 8): `PersonKeyCensusTests`, by per-file equality over
  the Mac, Core and the phone, with the phone's allow-list EMPTY. CLAUDE.md
  tripwire 53.
- **Docs** (Task 9): the ADR 0032 addendum; `Maugham/OpLog/AREA.md`,
  `Maugham/Stores/AREA.md` and `Maugham/Views/AREA.md`; this note.

## Rulings

Every ruling, with its cost, is in the ADR addendum's *The rulings, with their
costs*. These are the ones that changed behaviour beyond the plan as written:

- A person is a LABEL, and a label change drops the linked key.
- Revoked records neither help nor block; an all-revoked label asks.
- The recognised admission lives in `RegistryAdmission`, and tripwire 49
  stands.
- Recognised before remembered, and the remembered pass leaves a narrowed
  person's device to the sheet.
- Forget is durable, and there is no re-trust verb in plan 1.
- Person-key facts come from this root's chain only.
- The sheet never pre-fills a merge.
- The censuses scan the phone now, with an empty allow-list.

## Carries into plan 2

- **The phone's claim.** `PhoneDeviceRecord.ensure` embeds a claim, made on the
  phone's first write in a book. It needs the device-name rule (*"<first
  name>'s <model>"* where the system name is generic; a user-assigned name
  wins). **Census registration:** the phone's store construction and signing
  sites go into `PersonKeyCensusTests`' arrays deliberately, since today the
  phone's allow-list is empty and a phone site goes red.
- **The iCloud saved-by hint** on the sheet (spike §4), with the
  disagreement sentence.
- **Entitlements and signing.** Both apps need `keychain-access-groups` naming
  `$(AppIdentifierPrefix)com.maugham.person`. The Mac needs a Developer ID
  provisioning profile embedded before `codesign` in `release.yml`, as a CI
  secret. The phone's App Store profile gains the group. Dry runs on both
  pipelines.
- **The phone's Settings → This device line** (*Recognised as <name> on your
  other devices* / *iCloud Keychain is off, so each book will ask about this
  phone once*).
- **The guide:** apply Task 7's proposed text in the release that turns the
  keychain on.
- **Smoke on Denver's hardware**, per the spec's smoke list: his Mac, his
  iPhone, and the second Apple ID as a collaborator.
- **The paired Mac and phone release.** No schema raise.

## Open notes

- **Mid-session linking waits for arrival.** The link pass runs mid-session
  only when an unadmitted device record is waiting. Otherwise the next open
  links. The open's inline passes run before any window and bypass the
  serialiser.
- **Schema-gate heal order.** At open, recognition runs before the unawaited
  `healTheSchemaGateIfNarrowed`. The order is reasoned safe (the book was
  narrowed before this admission) but not pinned by a test.
- **A forgotten key cannot be re-trusted**, and there is no verb for it.
- **Open-path cost (carried to plan 2).** `admitRecognised` runs inline on the
  main actor at every root open. Resolve it lazily, or measure it in the smoke
  on a real book.
- **A launched app binary is not a test host (carried to plan 2).** An app a
  test LAUNCHES (rather than hosts) constructs `KeychainPersonKeyStore`. Today
  that reads unavailable under ad-hoc signing; revisit it when a team-signed
  Debug build gets the `keychain-access-groups` entitlement, or a launched
  binary could reach the developer's real keychain.
- **The whole-branch fix wave (2026-09-28)**: recognised admissions never write
  `AdmissionMemory`; Forget reaches this root's holders only and reports
  another root's; each Forget is one dated History row; the sheet's
  all-revoked hint; the link pass skips forgotten keys. See the ADR addendum.
- **Minor, deferred:**
  - The claim-name contradiction is case-sensitive.
  - `labelNamesANarrowedPerson` now reads this root's chain explicitly; the
    table already filtered foreign events, so its pin cannot go red alone.
  - An unreachable defensive guard remains in `TrustRecognition`.
  - A stored claim that does not verify lingers until the record's next real
    rewrite; no reader trusts it.
