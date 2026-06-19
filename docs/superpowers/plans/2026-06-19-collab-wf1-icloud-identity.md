# Collaboration WF1 — iCloud Identity Increment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`). This wires real multi-person identity onto the review membrane shipped in Phase 2 (merge `db5feb1`).

**Goal:** Turn "review your own draft" into real multi-person review: derive each user's role from iCloud Drive's collaboration metadata (`.owner` → author, `.participant` → reviewer) and drive the existing review membrane + provenance from it. A participant opening a project shared *to* them is automatically annotate-only; the owner edits freely.

**Architecture:** A `ShareMetadataReading` seam (Mac/phone inject the platform `URLResourceKey` read; the role mapping + caching live in MaughamCore). The resolved `CollaborationRole` drives the Phase-2 membrane (`isReviewMode`/`EditorEditPolicy`) and the annotation author provenance. iCloud collaboration (CKShare-backed) is the transport; no accounts, no server — the user's existing Apple ID is the identity.

**Tech Stack:** Swift, MaughamCore (shared), Mac + phone targets. Tests: XCTest. Builds per CLAUDE.md. `-only-testing` uses module/class.

Specs: [`2026-06-17-wf1-human-reviewers-design.md`](../specs/2026-06-17-wf1-human-reviewers-design.md) Components A (identity) + H (transport); overview [`2026-06-17-collaboration-overview-design.md`](../specs/2026-06-17-collaboration-overview-design.md). Confirmed 2026-06-19: user can test iCloud Collaborate with a 2nd Apple ID; role→posture = participant auto-annotate-only / owner author.

## The iCloud resource keys (the load-bearing dependency)
On a shared (Collaborate / CKShare) item, macOS + iOS expose, as `URLResourceKey`s (and matching `NSMetadataItem` attrs):
- `.ubiquitousItemIsSharedKey` — is it shared at all
- `.ubiquitousSharedItemCurrentUserRoleKey` — `.owner` / `.participant`
- `.ubiquitousSharedItemCurrentUserPermissionsKey` — `.readOnly` / `.readWrite`
- `.ubiquitousSharedItemOwnerNameComponentsKey` — owner's name (`PersonNameComponents`)
- `.ubiquitousSharedItemMostRecentEditorNameComponentsKey` — last editor

**The whole increment leans on these behaving as documented — Task 1 verifies that against a real share before anything else is built.**

---

## Task 1 — SPIKE + resolver (gating; USER verifies against a real share)

**Files:**
- Create (MaughamCore): `Packages/MaughamCore/Sources/MaughamCore/CollaborationRole.swift` — `CollaborationRole { author, reviewer, unknown }`, `Collaborator { role, currentUserName: String?, ownerName: String?, canWrite: Bool }`, `ShareMetadata { isShared: Bool, isOwner: Bool?, canWrite: Bool?, ownerName: String?, currentUserName: String? }`, and `ShareIdentityMapper.resolve(_ meta: ShareMetadata?) -> Collaborator`.
- Create (MaughamCore): protocol `ShareMetadataReading { func read(for url: URL) -> ShareMetadata? }`.
- Create (Mac): `Maugham/Stores/ICloudShareMetadataReader.swift` — concrete `ShareMetadataReading` reading the `URLResourceKey`s above (resourceValues), mapping role/perms, formatting names via `PersonNameComponentsFormatter`.
- Create (Mac): a small **diagnostic surface** so the user can verify — a read-only status line in `GeneralSettingsTab` (or a labeled row) for the currently-open project: e.g. "Sharing: Reviewer · shared by Jane Doe" / "Owner" / "Not shared" / "Checking…". (This becomes the real status UI later — keep it tasteful.)
- Tests: `Packages/MaughamCore/Tests/MaughamCoreTests/ShareIdentityMapperTests.swift`.

- [ ] **Step 1: Failing test for the pure mapper:**
```swift
func test_mapper_resolvesRoles() {
    XCTAssertEqual(ShareIdentityMapper.resolve(nil).role, .unknown)
    XCTAssertEqual(ShareIdentityMapper.resolve(ShareMetadata(isShared: false, isOwner: nil, canWrite: nil, ownerName: nil, currentUserName: nil)).role, .author)   // not shared = own copy = author
    XCTAssertEqual(ShareIdentityMapper.resolve(ShareMetadata(isShared: true, isOwner: true, canWrite: true, ownerName: "Me", currentUserName: "Me")).role, .author)
    let p = ShareIdentityMapper.resolve(ShareMetadata(isShared: true, isOwner: false, canWrite: true, ownerName: "Jane", currentUserName: "Bob"))
    XCTAssertEqual(p.role, .reviewer); XCTAssertEqual(p.ownerName, "Jane"); XCTAssertEqual(p.currentUserName, "Bob")
}
```
- [ ] **Step 2:** Run, fail.
- [ ] **Step 3:** Implement the types + mapper (not-shared→author; owner→author; participant→reviewer; nil meta→unknown), the `ShareMetadataReading` protocol, the Mac `ICloudShareMetadataReader` (read `URLResourceKey`s; tolerate missing keys → not-shared), and the Settings diagnostic line (reads the current project's folder URL through the reader; cache the result, read once on open + on a `.NSMetadataQueryDidUpdate`/file-presenter share-change, **never poll, never per-render**; show "Checking…" for `.unknown`).
- [ ] **Step 4:** Run mapper tests (PASS) + Mac build SUCCEEDS.
- [ ] **Step 5:** Commit `feat(collab): iCloud share identity resolver + role mapper + Settings diagnostic`.
- [ ] **Step 6 — USER VERIFICATION (the spike's point):** the user shares a Maugham project via Finder → Share → **Collaborate** (read-write), opens it on a **second Apple ID**, and checks the Settings diagnostic shows **Reviewer · shared by <owner>** on the participant side and **Owner** on the owner side; an unshared project shows **Not shared**. **STOP and report the observed values** before building Tasks 2+. Contingency: if a key doesn't populate / lags badly, capture exactly what's `nil` and we adjust (fallback to a Settings-declared identity + explicit Author/Reviewer prompt).

---

## Task 2 — Role drives the review membrane (after spike verifies)

Wire the resolved role into the Phase-2 membrane. The "am I author of this doc?" predicate becomes role-based (static WF1 version): `.author`/`unknown-treated-cautiously` vs `.reviewer`.

**Files:** `Maugham/Views/ProjectWindow.swift` (+ EditorHost) — derive review posture from the resolved role; `Maugham/Editor/EditorCoordinator.swift` (membrane already keys off `isReviewMode`).

- [ ] A `.participant` project forces review posture ON (annotate-only) and the manual ⌘⌥R **cannot turn editing on** (you can't author someone else's manuscript). The REVIEWING pill shows their role ("Reviewing · <name>").
- [ ] An `.owner` is the author: edits freely; ⌘⌥R still toggles review-to-read-notes (Phase-2 behavior).
- [ ] `.unknown` (resolving) → cautious read-only until resolved (don't flash author affordances then yank them).
- [ ] **Read-only trap:** a participant needs iCloud **read-write** to append annotation ops; if the share is read-only, surface a clear "this share is view-only — ask the owner for edit access to leave comments" message (don't silently fail). The membrane stays app-enforced regardless.
- [ ] Tests: role→posture predicate (pure, testable); membrane still blocks for a participant.
- [ ] Commit. **USER SMOKE:** participant can't edit text, can annotate; owner edits normally.

---

## Task 3 — Provenance from the Apple-ID name

- [ ] A participant's annotations are stamped with their **resolved iCloud name** (`Collaborator.currentUserName`) instead of the manual `collaboratorDisplayName`, falling back to the Settings name when unshared/unknown. `AnnotationOwnership.isOwn` keys off the same resolved identity so Edit/Delete gate correctly across accounts.
- [ ] The Settings reviewer-name field becomes the *fallback/override* (note this in its help text).
- [ ] Tests: provenance stamping uses resolved name; ownership matches across the resolved identity. Commit.

## Task 4 — Setup flow + fallback + unknown-state polish

- [ ] A guided **"Share for review…"** affordance (File menu / project menu) that opens the macOS share sheet (or walks the user to Finder → Share → Collaborate) for the project folder. Sane fallback + copy when a project isn't an iCloud-shared item ("move to iCloud Drive and Collaborate to review with others").
- [ ] Unknown-state UX (the "Checking…" → resolved transition) is smooth. Commit. **USER SMOKE.**

## Task 5 — Phone role-awareness

- [ ] Phone injects its own `ShareMetadataReading` (same MaughamCore mapper); a participant on phone is read-only consumption with correct provenance display. Phone scheme green. Commit.

## Task 6 — Verification + user smoke

- [ ] Mac + phone suites green; Release build. Final review. **USER SMOKE** the full multi-account flow (owner shares → participant reviews → owner sees the participant's named annotations sync back via the op log).

---

## Notes / deferred
- This is the **static** WF1 role model (owner=author, participant=reviewer). WF2's per-doc baton (dynamic authorship) comes later.
- Skew-aware LWW + same-paragraph conflict surfacing is WF2 (the participant-and-owner-edit-the-same-paragraph case); WF1 reviewers can't edit manuscript text, so it's near-zero risk here.
- Real verification of the resource keys is inherently a USER smoke (needs the 2nd Apple ID); unit tests cover the mapper over injected fixtures only.
