# Your devices are you — plan 2 outcome (2026-09-28)

**Plan:** `docs/superpowers/plans/2026-09-28-your-devices-are-you-plan2-phone-signing-release.md`.
**Spec:** `docs/superpowers/specs/2026-09-27-your-devices-are-you-design.md`.
**Plan 1 outcome:** `docs/superpowers/notes/2026-09-28-your-devices-plan1-outcome.md`.
**Branch:** `claude/your-devices-are-you-p2`, off main `95aa098d`.
**Ledger, rulings and task reports:** `.superpowers/sdd/2026-09-28-your-devices-are-you-plan2-phone-signing-release/`.
**Decision of record:** [ADR 0032](../../adr/0032-the-signed-op-log.md)'s addendum *your devices are you, plan 2*.
**Release notes (drafts, dated at the cut):** `docs/release-notes/v0.42.0.md`, `docs/release-notes/phone/v0.15.0.md`.

## What shipped

Plan 2 turns plan 1 on. Plan 1 and plan 2 ship together as Maugham 0.42.0 and
MaughamPhone 0.15.0, a paired release with no schema raise.

- **The phone claims** (Task 1 and its fix round). The claim rule is Core's
  and both surfaces ask it: `RegistryPresence.claimIntent` (the one
  `RegistryWriter.personClaim` site) and `RegistryPresence.declareDevice`
  (which re-writes with `.keep` when the record refuses the claim). The store
  arm is Core's `PersonKeyStoreChoice`; each surface builds its store in its
  own file (`PersonKeyAccess`, `PhonePersonKeyAccess`), each with a test-host
  arm that never reaches a keychain. The phone FINDS the key
  (`PersonKey.find`/`finding`) and never mints one, and claims on its first
  write in a book. The name rule makes a generic "iPhone" into *"<first
  name>'s iPhone"* and never overwrites a name the writer gave. A phone
  capture is read and recognised as `.ownDevice` by the Mac's reader, in
  process on the simulator and from checked-in simulator bytes in the Core
  suite.
- **The phone's Settings line** (Task 2): one row under *This device*,
  `PersonKeyLine`, read through the same `findPersonKey` the claim uses. Its
  sentences are in the ADR addendum and the guide.
- **The saved-by hint** (Task 3, then the wording follow-up in `9e57beb2`):
  Core's `SavedByReader`, `AdmissionRequest.savedBy`, and the sheet's
  *iCloud says this device's record was last saved by <name>.* plus *That
  isn't the name the device gives.* where they differ. Census:
  `TripwireGrepTests.test_theSavedByKeyIsReadBySavedByReaderOnly`.
- **Entitlements** (Task 5): `keychain-access-groups` for
  `FF3XH4ZJ45.com.maugham.person` on both Release configurations — literal on
  the Mac, `$(AppIdentifierPrefix)` on the phone. Debug stays unentitled on
  both.
- **`release.yml`** (Task 6 and its fix round): installs, embeds and verifies
  the Mac's Developer ID profile (`MAC_PROVISIONING_PROFILE`), re-signs with
  Xcode's entitlements, and refuses a signature carrying `get-task-allow`
  before notarization (`scripts/verify-mac-signing.sh`, pinned locally by
  `scripts/tests/verify-mac-signing.test.sh`).
- **Docs** (Tasks 4 and 8): the guide (`docs/guide/people-and-devices.md`:
  *Recognised devices*, the panel's two new paragraphs, Forget, the phone's
  Settings line); `SETUP.md` §1, `SETUP-mac-signing.md` §4, `RELEASING.md`;
  the Stores, Views, OpLog and phone AREA files; the ADR addendum; the
  release-notes drafts; this note.

## Rulings

Every ruling, with its cost, is in the ADR addendum's *The rulings, with their
costs*. The plan's own are P2-1 (claim on first write), P2-2 (first name from
the key's name), P2-3 (saved-by from the device-record file, non-nil only)
and P2-4 (Release-only entitlements; literal on the Mac). These changed
behaviour beyond the plan as written:

- One claim rule in Core, and the store choice and team id with it.
- The phone finds the key and never mints one.
- The Settings line's sentences are the truthful ones, with two added states.
- The saved-by line says "was last saved by".
- The phone's Debug build stays unentitled.
- The outer re-sign keeps Xcode's entitlements rather than the raw file,
  minus the `get-task-allow` Xcode's Release `build` injects (whole-branch
  review's Critical: `verify-mac-signing.sh resign-entitlements`).
- The verify step refuses `get-task-allow`.

## Task 7 — portal steps and dry runs (Denver + controller)

Not yet run at the time of writing. Record the results here:

- [ ] Developer ID profile for `com.maugham.Maugham` created with the keychain
      group, checked with `scripts/verify-mac-signing.sh profile`, stored as
      `MAC_PROVISIONING_PROFILE` (`docs/release-notes/SETUP-mac-signing.md` §4).
- [ ] The generated Mac profile's `ExpirationDate` recorded here: ______.
      After it, an installed build's keychain query reads `.unavailable` →
      the claim is `.keep` → new devices get the sheet as before plan 2
      (ADR 0032 plan-2 limits). Renew per SETUP-mac-signing §4 before then.
- [ ] Phone App Store profile shows `keychain-access-groups: FF3XH4ZJ45.*`
      (it did locally in Task 5).
- [ ] Mac dry run `v0.41.9x`: the install/embed/verify steps print their `ok:`
      lines; the re-sign step's printed entitlements carry no
      `get-task-allow`; notarized; the app launches; the embedded
      profile is there; a scratch book's `devices/<fp>.json` carries
      `personClaim`.
- [ ] Phone dry run `phone-v0.0.x` on TestFlight: its first capture in a
      scratch book writes a claim.
- [ ] Throwaway tags and releases deleted.

## Smoke checklist (Task 9, on the dry-run builds or release candidates)

On Denver's Mac and iPhone, plus the second Apple ID:

1. His iPhone writes in his book and is filed under him silently, with the
   History line. The phone's Settings line says *Recognised as Denver Trouton
   on your other devices.*
2. Playlist's `0ECB` becomes his *"Denver's iPhone"* under Denver Trouton after
   the phone's first write. **Precondition:** `0ECB`'s label in Playlist must
   already be the root's label, *Denver Trouton*. Otherwise `linkPersonKey`
   refuses, and the only trace is a `.debug` log line. **Recovery:** rename
   `0ECB` in People & Devices so the labels match, then reopen the book.
3. A second-Apple-ID device's first write: the sheet shows its claimed name and
   *iCloud says this device's record was last saved by …*.
4. That person's second device joins silently as them.
5. Forget, then their next device gets the sheet again, with a dated History
   line.
6. iCloud Keychain off on a device: the sheet as today, and the phone's line
   says iCloud Keychain isn't reachable.
7. Measure the open-path time with recognition on a book with several devices.

Also worth watching in the same session (they rest on reports, not hardware):
a locked phone reads as *isn't reachable*; a partial Forget finishes on a
second press; the owner-side saved-by line is absent for the owner's own saves.

**Then the release:** push main, wait for CI green, cut `v0.42.0` and
`phone-v0.15.0`, push each tag by name, watch both runs.

## Open notes

- **The Mac's signed Release build needs the profile to build at all**, so no
  Mac release can be cut until the secret exists. Do not merge to main before
  the Task 7 dry run is green: main's `release.yml` would be red.
- **An app binary a test launches is not a test host.** No test launches the
  Maugham app today, and it is moot while Debug is unentitled. Revisit if a
  team-signed Debug build ever carries the group.
- **The open-path cost** (plan 1's inline recognition pass, the phone's
  per-write key look) is measured in smoke item 7, not before.
- **The saved-by hint** is measured on the owner's Mac only; on a
  participant's Mac its meaning is inferred. Absence is its failure mode, it
  names the last saver of the file rather than the device, and name forms can
  disagree falsely.
- **Minor, deferred** (from the task reviews):
  - The phone line's *isn't reachable* also covers an undecodable item
    (Core's `PersonKeyLookup.unavailable` is ambiguous there).
  - The phone's `ensure` spins a detached task even when it cannot sign.
  - One owner-nil assertion in `AdmissionSavedByTests` is near-tautological.
  - `verify-mac-signing.test.sh` skips without the probe profile, so CI does
    not run it.
  - Where Xcode reads profiles from on the `xcode-27` runner is not measured;
    the step installs to both locations.
- **The phone gate has one standing opt-in skip:** `PhoneClaimFixtureDump`
  (MaughamPhoneTests). It skips unless `MAUGHAM_PHONE_CLAIM_FIXTURE_DIR` is
  set, because it writes outside `TestTemp`. It regenerates the bytes
  `PhoneClaimRoundTripTests` reads. A phone gate's skip list reads one skip
  from it; that skip is expected, not a regression.
