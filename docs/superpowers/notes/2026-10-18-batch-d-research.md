# Batch D research — updater + CI hardening (issue #67, audit F12–F16)

Researched 2026-10-18 on `fix/updater-hardening-67` (= main @ `8a8d62ee`). Read-only; nothing built or run
except `codesign`/`spctl`/`zipinfo` against the already-staged 0.42.0 bundle in
`~/Library/Application Support/Maugham/Updates/` and one `curl -I` on a release asset.

**Numbering trap:** the "F16" here is the **2026-09-13** audit's F16 (zip extracted before verify,
`2026-09-13-maintainability-review.md:72`). The **2026-09-20** audit also has an F16 — `sealChain(docId:actor:)`
minting before `fileExists` (now `Packages/MaughamCore/Sources/MaughamCore/OpLogStore.swift:2764`) — which
is NOT part of this batch. Issue #67's body lists only F12–F15; F16 was added to the batch by the caller.

## How the swap works today (context for all five)

- Download → `UpdateChecker.defaultDownload` (`UpdateChecker.swift:110-178`) streams `asset.browserDownloadURL`
  into `~/Library/Application Support/<variant>/Updates/Maugham-<ver>.zip`. **If that file already exists it is
  reused untouched** (`:123-126`).
- Stage → `UpdateInstaller.stageAndVerifySync` (`UpdateInstaller.swift:322-342`): wipe/create `staged-<ver>/`,
  `ditto -x -k` (`:327`), strip quarantine (`:332`), `verify()` (`:291-308`), `decide()` (`:64-69`).
- `verify()` runs three processes: `codesign --verify --deep --strict` (exit 0 ⇒ `codesignValid`),
  `codesign -dv --verbose=4` (parses `TeamIdentifier=`), `spctl -a -t exec -vv` (exit 0 ⇒ `notarized`).
  `decide()` is pure: valid ⇒ notarized ⇒ `teamID == runningAppTeamID()` (`SecCodeCopySelf`, `:251-262`;
  `nil` ⇒ `""` ⇒ mismatch, so an ad-hoc/test host always rejects).
- On accept `UpdateChecker.performCheck` stores `.readyToInstall` and `pendingQuitInstall` (`UpdateChecker.swift:88-97`).
- Two install triggers, **both** end in `UpdateInstaller.launchSwapHelper` (`UpdateInstaller.swift:347-379`):
  1. "Restart & Update" → `installNow` → `UpdateChecker.performInstall` closure (`MaughamApp.swift:103-110`) →
     helper with `relaunch: true` → `NSApp.terminate`.
  2. Ordinary quit → `willTerminate` observer (`MaughamApp.swift:56-70`) → helper with `relaunch: false`;
     a `false` return marks `PendingUpdateReveal` for next launch.
- `launchSwapHelper`: `installMode` (bundle path writable?) → `python3Available()` (spawns `bash -c command -v python3`)
  → `helperScript(...)` string written to `$TMPDIR/maugham-update-<uuid>.sh` → `Process("/bin/bash", [script])`,
  not awaited; the child reparents to launchd.
- The bash helper (`helperScript`, `:89-133`): python3 guard → `while kill -0 <pid>` → `rm -rf "<installed>.inflight"`
  → `ditto "<staged>" "<installed>.inflight"` → writes `pyAtomicSwapSource` to `mktemp /tmp/maugham-swap-XXXXXX.py`
  via a quoted heredoc → `python3 "$PY_TMP" "<inflight>" "<installed>"` (ctypes `renamex_np(RENAME_SWAP)`, rename
  fallback) → `rm -f "$PY_TMP"` → optional `open "<installed>"`. Under `set -e`; **no logging, no status left anywhere**.

Measured on this Mac (warm, online) against `staged-0.42.0/Maugham.app` (89 MB, 82 files):
`codesign --verify --deep --strict` **0.14 s**, `spctl -a -t exec` **0.54 s**. spctl can contact Apple (OCSP/ticket)
and so can stall for seconds offline; the code comment at `:302-303` already treats a timeout as "not notarized".

## F12 — swap re-uses the download-time verdict

**CONFIRMED — and wider than stated.** It is not only the quit path: "Restart & Update" (`installNow`) also swaps
the staged bundle with no re-check, because both triggers share `launchSwapHelper`. The window between verify and
swap is unbounded (background poll every 24 h; the app may stay open for days with `pendingQuitInstall` set).
`staged-<ver>/` is a plain user-owned dir (`drwxr-xr-x denver staff`).

Evidence: `UpdateChecker.swift:88-97` (verdict taken once), `UpdateInstaller.swift:113-127` (helper copies and
swaps whatever is at the staged path), `MaughamApp.swift:60-63` and `:103-105` (both triggers).

Severity note for the plan: the audit's "an attacker who can write that dir already owns the account" undersells it
slightly. On current macOS, *App Management* privacy protection stops an arbitrary user process from modifying a
signed app in `/Applications`, but the updater's helper runs as Maugham's child (Maugham is allowed to update itself),
so it would **launder** a substituted bundle into `/Applications`. Still Low (local attacker), but real. Also,
`Maugham/Updates/AREA.md` actively asserts **"No TOCTOU"** — that paragraph is false and must be rewritten.

**Recommended fix shape — re-verify in the detached helper, on the `.inflight` copy, after the app has exited.**
- Not in `willTerminate`: spctl may block on the network; quit would hang with nothing on screen. In the helper the
  app is already gone, so a second of verification costs the writer nothing.
- Verify the `.inflight` sibling (the exact bytes `renamex_np` will put in place, already on the install volume),
  not the `~/Library` staged copy. This leaves only the `verify → renamex_np` gap (milliseconds, and in the admin-
  writable `/Applications` dir).
- The helper can do it with system tools; one `codesign` call checks validity AND team (verified here: exit 0 with
  `FF3XH4ZJ45`, exit 3 with a wrong team):
  ```bash
  /usr/bin/codesign --verify --deep --strict \
    --test-requirement="=anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\"" "$INFLIGHT"
  /usr/sbin/spctl -a -t exec "$INFLIGHT"
  ```
  On either failing: `rm -rf "$INFLIGHT"`, record the failure (see question below), `exit 1` — before the swap and
  before `open`. Must come after the python3 guard and `kill -0` wait, before the python step.
- Swift changes (pair with F13 — same function):
  - `helperScript()` becomes **parameter-free static text** (or takes only `HelperTools`, below), reading
    `$1`=pid `$2`=staged `$3`=installed `$4`=expected team ID `$5`=relaunch(`1`/`0`).
  - New `static func helperArguments(scriptPath: String, pid: Int32, stagedBundle: String, installedBundle: String,
    expectedTeamID: String, relaunch: Bool) -> [String]`.
  - `launchSwapHelper(... expectedTeamID: String? = UpdateInstaller.runningAppTeamID())` returns `false` when the
    team is nil or not `^[A-Z0-9]{10}$` (Finder fallback, same as today's unwritable path).
  - Optional extra (cheap, in-process): a Swift pre-check in `installNow`'s path is unnecessary once the helper does
    it; don't add a second verifier.
- `HelperTools` seam: `struct HelperTools { codesign, spctl, ditto: String; static let system }` with literal absolute
  paths, interpolated into the script (constants, not user data — keep a precondition that each matches
  `^[A-Za-z0-9/._-]+$`). Tests pass stub paths.

**Testing without network or a signed app:**
- Pure: `helperArguments` order/content; script text contains the verify step between `kill -0` and `python3 "`
  (extend `test_helperScript_python3GuardPrecedesFirstDestructiveStep`'s ordering style), and contains no `$`-free
  interpolated path (assert the script is byte-identical across two different argument sets).
- **New end-to-end helper test (now possible):** under `TestTemp.root`, make `staged/Maugham.app` and
  `installed/Maugham.app` dirs with marker files; write stub `codesign`/`spctl` scripts that `exit 0` or `exit 1`;
  write `helperScript(tools: stubs)` to a file; run `/bin/bash script <pid-of-an-exited-/usr/bin/true> staged installed
  ABCDE12345 0` synchronously. Assert: stubs exit 0 ⇒ installed now holds the staged marker; stub exits 1 ⇒ installed
  unchanged and no `.inflight` left. Needs `python3` (present on dev Mac + the xcode-27 runner — `python3Available`
  already assumes it; skip with `XCTSkip` if absent). Write the script under `TestTemp`, not via `launchSwapHelper`
  (which writes to the production `temporaryDirectory` — fine in prod, banned spelling in tests by
  `test_noTestNamesTheTempDirectoryButTestTemp`). The `PYEOF` heredoc writes to `/tmp` via `mktemp` — that is the
  script's own behaviour, not the test naming a temp dir, so the census is not tripped.
- Existing tests that will need rewriting: `test_helperScript_relaunch_containsWaitDittoAndOpen` and
  `test_helperScript_noRelaunch_omitsOpen` (they assert interpolated paths / `open "/Applications/…"`), and
  `test_helperScript_usesAtomicSwap_notRmMv` (its `rm -rf "<installed>"` check becomes `rm -rf "$3"` etc.).

**Gotchas:** spctl offline ⇒ the quit-time install silently doesn't happen (the app already quit). Real-device smoke
still required (AREA.md checklist) — the end-to-end test proves the script, not launchd reparenting.

**Needs a product decision (plain question for Denver):** *If the update fails its safety check at the moment you
quit, should Maugham say so the next time you open it (e.g. "The update to 0.43 didn't pass its safety check and
wasn't installed"), or just quietly try again later?* Implementation either way: the helper writes a small status file
under `Updates/` that the next launch reads (also gives every other silent helper failure a voice — see New-4).

## F13 — `helperScript` interpolates paths into bash

**CONFIRMED.** `UpdateInstaller.swift:116,117,127,130` interpolate `tmp`/`stagedBundle`/`installedBundle` inside
`"…"`. Inside bash double quotes `$(…)`, backticks and `"` are live, so an app renamed to e.g.
``Maugham "$(touch ~/x)".app`` (or any path containing them) executes code / breaks quoting. `installedBundle` is
`Bundle.main.bundlePath` (`:349`), user-renamable; `stagedBundle` is under the user's home (safe in practice). `pid`
(`:114`) is an `Int32` — safe. The Python step already takes argv (`:127`, `pyAtomicSwapSource` `sys.argv`), so the
"pass via argv" shape is already half there.

**Fix shape:** as in F12 — the script references only `"$1"`…`"$5"` (assigned to named vars at the top:
`PID="$1"; STAGED="$2"; INSTALLED="$3"; TEAM="$4"; RELAUNCH="$5"; INFLIGHT="$INSTALLED.inflight"`), every use
double-quoted, `open "$INSTALLED"` gated on `[ "$RELAUNCH" = 1 ]`; `launchSwapHelper` sets
`p.arguments = helperArguments(...)`. Optionally guard `case "$INSTALLED" in *.app) ;; *) exit 1;; esac`.

**Tests:** (a) pure — `helperScript(tools: .system)` is identical regardless of inputs and contains none of the
argument strings; (b) the F12 end-to-end test run once with hostile directory names
(`Mau"g$(touch PWNED)ham`/backtick) under `TestTemp.root`, asserting the swap happened and `PWNED` does not exist.

## F14 — `browser_download_url` not host-validated

**CONFIRMED, but the cited lines are wrong.** `GitHubReleasesAPI.swift:85-95` is `latestMacRelease` (selection).
The URL is used unvalidated at `UpdateChecker.swift:77` (asset choice) → `:85` (`downloadAsset(asset.browserDownloadURL…)`)
→ `defaultDownload` `:121` (extension taken from the URL path, not the asset name) and `:128`
(`URLSession.shared.bytes(from: url)`). Impact is low: the zip still faces codesign/notarization/team — but the
**`.dmg` fallback is not in-app verified at all** (`UpdateChecker.swift:184`; RELEASING.md says so deliberately), so for
a zip-less release the host check is the only in-app gate.

What GitHub actually serves (checked 2026-10-18): `browser_download_url` is
`https://github.com/dtrouton/Maugham/releases/download/v<ver>/<asset>` (fixture
`MaughamTests/Fixtures/github-releases-latest.json:11`); a GET answers **302 →
`https://release-assets.githubusercontent.com/github-production-release-asset/…`** (GitHub moved from
`objects.githubusercontent.com` in 2025). `URLSession.bytes(from:)` follows redirects silently.

**Recommended fix shape:** validate the URL we *request*, strictly; do not allow-list redirect hosts.
- New pure `GitHubReleasesAPI.isTrustedAssetURL(_ url: URL, for asset: GitHubRelease.Asset, tag: String,
  owner: String = "dtrouton", repo: String = "Maugham") -> Bool`: `scheme == "https"`, `host == "github.com"`
  (case-insensitive, no port/user), `path == "/\(owner)/\(repo)/releases/download/\(tag)/\(asset.name)"`.
  Hoist `owner`/`repo` from `fetchLatestRelease`'s default params to `static let`.
- Call it in `UpdateChecker.performCheck` right after the asset guard (`:77-82`), mapping a failure to a new
  `GitHubReleasesAPI.Error.untrustedAssetURL` (error on manual, idle on background — same as `noInstallableAsset`).
  Putting it in `performCheck` rather than `defaultDownload` means the existing injected-closure tests cover it.
- Redirects: optionally a `URLSessionTaskDelegate.willPerformHTTPRedirection` that refuses non-`https` targets. A host
  allow-list on the redirect target would have broken in 2025 when GitHub changed CDN hosts, for no security gain
  (TLS + signature gate). Recommend https-only or nothing.

**Tests:** pure table tests for `isTrustedAssetURL` (http, other host, `github.com.evil.com`, other repo, other tag,
name mismatch, good). `UpdateCheckerTests`: an `https://example/…` asset ⇒ `.error` on manual and download closure
never called. **Fixture churn:** `UpdateCheckerTests.swift:40` and `UpdateProgressTests.swift:25` build assets with
`https://example/Maugham-<v>.zip` and expect a download — change both to the real github.com shape (tag `v<version>`).
`GitHubReleasesAPITests` fixtures (`https://e/x.zip`) only test selection and are unaffected if the check stays out
of `zipAsset`/`latestMacRelease`.

## F15 — action-pin verification only at release-cut

**CONFIRMED (gap), but the extraction already exists.** The logic is already a shared, sourced library —
`scripts/lib/verify-action-pins.sh` (`scan_and_verify_pins`, `:67-120`), used by `cut-release.sh:13-14,78-91` and
`cut-phone-release.sh:19-20,81-86`, with an **offline** unit test `scripts/tests/verify-action-pins.test.sh` (stubs
`gh` via `GH_BIN`). `.github/workflows/ci.yml` (jobs: `mac-tests`, `phone-tests`, `core-tests`, `behavioural-claims`,
`concurrency-warnings`) runs **neither** the check **nor** its unit test. No `paths:` filters anywhere in ci.yml.

How it works: greps `uses: owner/repo@ref # tag` from `.github/workflows/*.yml` (cwd-relative default), fails on a
non-40-hex ref or a missing `# tag` comment, then per unique pin calls `gh api repos/<r>/git/ref/tags/<tag>` (and
`git/tags/<sha>` for annotated tags) and compares. Needs: bash, `gh`, network, and a token (`gh` on Actions reads
`GH_TOKEN`; `${{ github.token }}` with `contents: read` is enough for public-repo reads; ~8 unique pins ⇒ ≤16 calls,
far under the GITHUB_TOKEN rate limit). Local `.github/actions` composites: none exist.

**Recommended fix shape:** one new job in `ci.yml`, e.g.
```yaml
  action-pins:
    name: Action pins (SHA ↔ tag)
    runs-on: ubuntu-latest        # gh preinstalled; bash only; seconds
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1   (already pinned; verifies itself)
      - run: bash scripts/tests/verify-action-pins.test.sh
      - run: source scripts/lib/verify-action-pins.sh && scan_and_verify_pins
        shell: bash
        env: { GH_TOKEN: "${{ github.token }}" }
```
- Run it on **every** push/PR rather than path-filtering: ci.yml has no filters today, a job-level paths filter needs
  a third-party action (`dorny/paths-filter`) — itself a pin to verify — and the job costs seconds.
- A thin `scripts/verify-action-pins.sh` entry-point wrapper is optional; the `source … && scan_and_verify_pins` line
  works as-is. Keep `--skip-pin-check` on the cut scripts (offline cuts) — the CI job makes it safe to skip there.
- `ubuntu-latest` breaks the "every job is macOS" pattern but the lib is plain bash (`[[ =~ ]]`, process substitution;
  bash 5 on Ubuntu is fine). If the project prefers no Linux runner, `macos-15` works (slower queue).
- Dependabot (`.github/dependabot.yml`) PRs get a read-only token — still enough for these public reads.

**Gotcha (be honest in the PR):** a PR's CI runs the PR's own `ci.yml`, so a PR that fabricates a pin can also delete
this job; and without `needs:` the fabricated action runs in parallel with the check. The job catches careless or
copy-pasted pins and makes a deleted check visible in review; it is only a *gate* if (a) it is a required status check
in branch protection and (b) other jobs `needs: action-pins` (adds ~20–40 s before the Mac jobs start).

**Testing:** the existing offline bash test covers the logic; the CI job runs it. Nothing in the Xcode suites.

**Needs a product decision:** *Should every other CI check wait for the pin check to pass before starting (safer,
roughly half a minute slower per run), or run alongside it?* — and, separately, whether Denver wants it marked
"required" in GitHub's branch settings (a click in repo settings, not code).

## F16 — zip extracted before verification (2026-09-13 audit)

**CONFIRMED.** `UpdateInstaller.swift:327` (`ditto -x -k`) precedes `verify()` at `:333`. Nothing checks the archive's
declared size, the free space, or even the download size: `defaultDownload` ignores `asset.size` and
`expectedContentLength` except for progress (`UpdateChecker.swift:129,153-158`) — so the **download itself** is the
same disk-fill class and should be capped in the same fix. Requires a compromised release; availability-only.

Real numbers: 0.42.0 zip 29 MB compressed, `zipinfo -t` ⇒ `82 files, 92981635 bytes uncompressed, 30647535 bytes
compressed: 67.0%`. `/usr/bin/zipinfo` (Info-ZIP) ships with macOS.

**Recommended fix shape:**
- Download cap: in `performCheck`, refuse an asset whose `asset.size` exceeds `UpdateLimits.maxDownloadBytes`
  (e.g. 512 MB) before calling `downloadAsset`; in `defaultDownload`, abort once `bytesWritten` exceeds
  `max(asset.size, …)`/the cap (needs the expected size passed in — either widen the `downloadAsset` closure signature
  with a `maxBytes: Int64` parameter, or enforce only the cap constant inside `defaultDownload`).
- Pre-extract gate in `stageAndVerifySync`, before `:327`:
  - `static func archiveTotals(zip: URL) -> (files: Int, uncompressedBytes: Int64)?` — runs `/usr/bin/zipinfo -t`,
    parsed by a **pure** `static func parseZipinfoTotals(_ output: String) -> (files: Int, uncompressedBytes: Int64)?`.
    (Alternative: a pure-Swift End-of-Central-Directory reader over `Data`; more code, needs ZIP64 handling — not worth it.)
  - Pure `static func extractionDecision(files: Int, uncompressedBytes: Int64, availableBytes: Int64,
    limits: UpdateLimits = .standard) -> InstallDecision` — reject over `maxUncompressedBytes` (e.g. 1 GB),
    `maxFiles` (e.g. 20 000), or when `availableBytes < uncompressedBytes * 2 + margin` (×2: the helper later
    `ditto`s another full copy into `/Applications`).
  - Free space from `URLResourceValues.volumeAvailableCapacityForImportantUsage` on the stage dir.
  - New `InstallError.archiveTooLarge(String)`; delete the zip and stage dir on rejection.
- **Limit to state:** the totals are what the central directory *declares*; a crafted archive can lie. A hard
  guarantee needs a byte-counting extractor (not worth it at Low). The declared-size gate + download cap + free-space
  floor bounds the honest-but-huge and the lazy bomb.

**Testing:** pure tests for `parseZipinfoTotals` (real `zipinfo -t` line above, singular "1 file", garbage ⇒ nil)
and `extractionDecision` (each refusal arm + accept). One real-process test: build a tiny zip under `TestTemp.root`
with `/usr/bin/ditto -c -k` and assert `archiveTotals` reads it (no network, no signing; tests already spawn
`hdiutil`/`bash`). `UpdateCheckerTests`: asset with `size` above the cap ⇒ download closure never called.

## New

1. **[New, Medium-ish in practice] The Updates folder is never cleaned — 5.2 GB on Denver's Mac right now.**
   `~/Library/Application Support/Maugham/Updates/` holds **44 zips + 44 `staged-*` dirs** (0.6.0 … 0.42.0), 5.2 GB,
   on a disk that is at 95% (25 GB free). Nothing ever deletes an old version's zip or staged bundle: the only
   `removeItem`s are the current version's stage dir (`UpdateInstaller.swift:325,339`) and the `.download` temp
   (`UpdateChecker.swift:132,171,175`). Fix: pure `static func staleUpdateArtifacts(in names: [String], keeping version:
   String?) -> [String]` (matches `Maugham-<semver>.(zip|dmg)` and `staged-<semver>` only, never anything else) plus a
   sweep at launch (keep nothing ≤ running version) and after a successful stage (keep only the new version). Test with
   a temp dir listing. This also undercuts F16's free-space check if left alone. **Plain question for Denver:** *OK to
   have Maugham delete its old downloaded updates automatically (it would free about 5 GB on your Mac today)?*
2. **[New, Low] A bad cached zip blocks updating for that version forever.** `defaultDownload` reuses an existing
   `Maugham-<ver>.zip` (`UpdateChecker.swift:123-126`); if staging rejects it (unzip fail / verify fail — including a
   transient spctl offline failure is fine, but a corrupted or substituted zip is not), the zip stays, and every later
   check re-stages the same bad file — silently, on the background trigger. Fix: on `unzipFailed`/`verifyFailed`
   remove the zip as well as the stage dir (or have `stageAndVerify` return/throw a typed error the checker uses to
   delete it). Do NOT delete on an spctl network failure only if you want to save bandwidth — simplest is always delete.
3. **[New, Low] `defaultDownload` takes the file extension from the URL path, not the asset name** (`:121`), and the
   `.zip`-vs-`.dmg` routing in `defaultStageAndVerify` (`:184`) keys on that extension. With F14's exact-path check
   (path ends in `asset.name`) this becomes moot; mention it in F14's commit.
4. **[New, Low] Helper failures are invisible.** After quit the helper can fail at `ditto` (e.g. the `.app` is writable
   but `/Applications` itself is not — `installMode` checks only the bundle path, `:239-244`, while `.inflight` is
   created in the parent) or the python step; `set -e` exits, nobody is told, and the update is simply not there next
   launch while `pendingQuitInstall` is gone. Cheap fixes: `installMode` also checks the parent directory is writable;
   the helper writes a one-line status file in `Updates/` that the next launch reads (the same channel as F12's question).
5. **[New, doc] `AREA.md` says "CI marks patch ≥ 90 as a pre-release; `/releases/latest` excludes pre-releases"** —
   the code no longer uses `/releases/latest` (`GitHubReleasesAPI.swift:85-103` filters the list itself). Still true in
   effect; wording stale.
6. Not a gap, noted: `UpdateInstaller.atomicSwap(staged:installed:)` (`:195-218`) has no production caller — the helper
   uses the Python twin. Fine; don't let the plan "re-use" it in the helper (the app is gone by then).

## Docs to sweep

- `Maugham/Updates/AREA.md` — **"No TOCTOU" paragraph is false today and must be rewritten** to describe the
  helper-side re-verify of `.inflight`; "Verification chain" table (add the quit-time re-check + requirement string);
  "Detached helper relaunch model" step list (argv, verify step, status file if built); "What is and is not
  unit-testable" table (the new end-to-end helper test, host check, size gate, cleanup sweep); the stale
  `/releases/latest` line; key-files table if a new file (e.g. `UpdateLimits`) is added.
- `docs/RELEASING.md` ~`:100-109` ("Auto-update is in-place…": mention re-verification at install time, host check,
  size cap, cleanup) and ~`:158-166` ("Action pins are verified at cut time" → also on every CI run; `--skip-pin-check`
  rationale).
- `CLAUDE.md` — no updater internals described; nothing to sweep unless a tripwire row is added. The "Releases"
  section is unaffected.
- `docs/product.md:51`, `docs/roadmap.md:333-334` — high-level, still true; optionally note the hardening on the
  roadmap if a ✓ line is wanted.
- `docs/superpowers/specs/2026-06-01-mac-auto-update-design.md` — historical; AREA.md already supersedes it. Leave.
- The two audit notes (`2026-09-13`, `2026-09-20`) and the 2026-10-11 sweep note record F12–F16 as open — the next
  sweep updates them; no edit needed in this branch.
