# Production Release — CI, Updater, and Dev/Stable Coexistence

**Status:** Approved 2026-05-22 by user, ready for implementation planning.

**Goal:** Establish the path from local Xcode build to a stable Maugham installed in `/Applications` that updates itself from GitHub Releases. Three deliverables in one milestone: (1) split the build into coexisting **stable** and **dev** variants with separate bundle ids, support folders, and MCP identities; (2) ship a homebrew "Tier 1.5" updater (silent background download, banner nudge, manual menu trigger); (3) wire a tag-triggered GitHub Actions release pipeline that publishes a `.dmg` plus structured release notes.

**Why now:** The codebase has been in milestone-tag-on-`main` discipline for months without ever cutting a user-installable build. The author runs Maugham daily from whatever was last built in Xcode, which means in-progress dev work touches real writing's state. A separate stable install fixes that exposure and makes the project genuinely usable beyond the development laptop's Xcode session. The supporting CI and updater are the smallest set of additional work that makes "stable" a real, self-maintaining artifact rather than a one-shot manual export.

**Working title:** `milestone-production-release`.

**Conformance contract:** must not regress any test currently green (814 tests). No editor binding contract changes, no op-log schema changes, no manuscript-load entry-point changes, no MCP tool surface changes. Existing `BuildVariant`-naive code that hard-codes `"maugham"` or `"Maugham"` gets routed through a new enum — behaviorally identical for stable, differentiated for dev. No bundled dependencies added (no Sparkle, no SwiftPM additions).

---

## 1. Problems addressed

Four distinct problems, addressed together because they share infrastructure.

### P1. No stable install exists
The author's daily-use Maugham is whatever `xcodebuild` last produced in `~/Library/Developer/Xcode/DerivedData/`. There is no installed `.app` in `/Applications`, no concept of "the version I rely on" vs "the version I'm iterating on." Any dev build regression that touches autosave, op log, or Application Support state can corrupt real writing in real projects.

### P2. No mechanism to publish or update a stable build
The repo has no CI. Producing a shareable `.app` today requires hand-running `xcodebuild`, hand-packaging, and hand-distributing. Even if a build existed in `/Applications`, there's no path for newer versions to land on the laptop short of repeating that manual process.

### P3. The single Application Support / MCP identity collides between dev and stable
The hardcoded `"Maugham"` Application Support folder and the hardcoded `"maugham"` MCP server name + Claude Desktop config key mean two coexisting installs cannot have independent state, separate Claude Desktop wiring, or distinguishable identity in Claude's own logs. Without addressing this, a "stable + dev" install pair can't actually coexist cleanly.

### P4. No release-time discipline for version, build number, or release notes
`CFBundleShortVersionString` is pinned at `"0.1.0"` in `project.yml` and has been since the project started. `CFBundleVersion` is `"1"`. No release-notes format, no per-version record. Cutting a release without infrastructure means inventing this each time.

---

## 2. Architecture overview

Three new code areas, one CI workflow, one configuration split, plus supporting docs/scripts. The dependency direction is clear: `BuildVariant` is foundational and underlies everything else; the updater and the MCP/config split both depend on it; the CI workflow depends on the variant split (for Release-config rules) and on a release-notes file structure.

### 2.1 New files

- `Maugham/BuildVariant.swift` — single enum that drives all stable-vs-dev differentiated behavior at runtime. Five derived properties: `displayName`, `supportFolderName`, `mcpServerKey` (used as both the Claude Desktop config key and the MCP `serverInfo.name`), `mcpSocketPath`, `updaterEnabled`. Bundle id itself varies via `project.yml`'s per-configuration `PRODUCT_BUNDLE_IDENTIFIER` (not via the enum), but the bundle id is verified at startup against the compile flag — see §5.2.
- `Maugham/Updates/UpdateChecker.swift` — `@MainActor @ObservableObject` singleton owning the version-check poll, silent background download, and publishable state. Lifecycle: started by `MaughamApp` at launch when `BuildVariant.current.updaterEnabled == true`; otherwise inert.
- `Maugham/Updates/UpdateBannerView.swift` — slim banner mounted via `.safeAreaInset(edge: .top)` on `ProjectWindow`, visible only when `UpdateChecker.shared.state == .ready(...)`.
- `Maugham/Updates/UpdateSheet.swift` — modal sheet opened from the menu item; reflects current `UpdateChecker.state` (idle / checking / downloading / ready / error / up-to-date).
- `Maugham/Updates/UpdateMenuCommand.swift` — `Commands` block adding "Check for Updates…" (or state-derived title) to the app menu via `CommandGroup(replacing: .appInfo)`.
- `Maugham/Updates/SemanticVersion.swift` — small value type for parsing and comparing `0.X.Y` strings. No dependency on Foundation's `OperatingSystemVersion`.
- `.github/workflows/release.yml` — tag-triggered macOS-runner workflow: checkout → setup Xcode → install xcodegen → sync version from tag → `./gen.sh` → build Release → test → package `.dmg` → create GitHub Release.
- `scripts/cut-release.sh` — local pre-flight helper. Verifies release-notes file exists, working tree is clean, on `main`, tests pass; creates the tag and prints the `git push --tags` command.
- `docs/release-notes/_template.md` — template the author copies for each release.
- `docs/release-notes/v0.2.0.md` — placeholder for the first release that exercises the pipeline. (Filled in at release time, not now; only mentioned here so the spec is honest that v0.2.0 will be the first cut release.)

### 2.2 Modified files

- `project.yml` — split `Maugham` target into Debug and Release configurations: Debug sets `OTHER_SWIFT_FLAGS = -DMAUGHAM_DEV_BUILD` and `PRODUCT_BUNDLE_IDENTIFIER = com.maugham.Maugham.dev`; Release keeps `com.maugham.Maugham` and no flag. `CFBundleShortVersionString` placeholder becomes `"0.0.0-dev"` (CI rewrites in Release builds). `CFBundleDisplayName` becomes a variable that resolves per-variant in the build script.
- `Maugham/MaughamApp.swift` — own `UpdateChecker.shared` lifecycle; include `UpdateMenuCommand()` in the `Commands` modifier.
- `Maugham/Views/ProjectWindow.swift` — mount `UpdateBannerView()` via `.safeAreaInset(edge: .top)` on the window's root view (only renders content when state is `.ready`, so cost is zero when no update is pending).
- `Maugham/MCP/MCPInitializeHandler.swift` — `ServerInfo(name: BuildVariant.current.mcpServerKey, version: Bundle.main.shortVersionString)`. The current `"maugham"` and `"0.1.0"` literals both go.
- `Maugham/MCP/ClaudeDesktopConfig.swift` — three sites (read, write, remove) currently keyed by `"maugham"` use `BuildVariant.current.mcpServerKey`. The write path also adds `"env": ["MAUGHAM_MCP_SOCKET": <variant-specific path>]` so the embedded `maugham-mcp` binary doesn't rely on its built-in default.
- `maugham-mcp/main.swift` — no logic change required; the binary already reads `MAUGHAM_MCP_SOCKET` from env. The hard-coded fallback path stays as a last-resort default but should no longer be relied on (the Set Up sheet always writes the env var explicitly).
- Any `ProjectStore` / `DocumentStore` / autosave / session-tracking code that constructs paths under `~/Library/Application Support/Maugham/` uses `BuildVariant.current.supportFolderName` instead of the literal `"Maugham"`. **Exact site list is enumerated during implementation** — the audit grep is `grep -rn '"Maugham"' Maugham/Stores/ Maugham/Models/` ; the spec does not pre-list all sites because exhaustiveness here is a code-search task, not a design question.
- `CLAUDE.md` — new "Releases" section, three additions to "Questions you do not need to ask", new tripwire #13. Full text in §6 below.
- `README.md` — small "Install" section pointing at the latest GitHub Release `.dmg` and noting the "right-click → Open on first launch" Gatekeeper step until signing flips.

### 2.3 Files not changed (explicit non-scope)

- The op log, reconciler, render filter, bootstrap, document-load path. The variant split is upstream of all manuscript handling. Op log files under `.maugham/ops/` are not variant-scoped; both stable and dev open the same project folders and read/write the same op logs. This is intentional: the manuscript and its log belong to the project folder on disk, not to either app.
- The MCP tool surface. The 20 existing tools work identically in both variants. Only the *server name* differs.
- The Sparkle framework. We are explicitly not adopting Sparkle. See §3.1.

---

## 3. Detailed design

### 3.1 The BuildVariant split

```swift
// Maugham/BuildVariant.swift
enum BuildVariant {
    case stable
    case dev

    static let current: BuildVariant = {
        #if MAUGHAM_DEV_BUILD
        return .dev
        #else
        return .stable
        #endif
    }()

    var displayName: String          { self == .dev ? "Maugham Dev" : "Maugham" }
    var supportFolderName: String    { self == .dev ? "Maugham Dev" : "Maugham" }
    var mcpServerKey: String         { self == .dev ? "maugham-dev" : "maugham" }
    var updaterEnabled: Bool         { self == .stable }
    var mcpSocketPath: String {
        let base = ("~/Library/Application Support" as NSString).expandingTildeInPath
        return "\(base)/\(supportFolderName)/mcp.sock"
    }
}
```

The `current` resolution happens once at process start via the compile-time flag. There is no runtime override; `Bundle.main.bundleIdentifier` is *not* used as the discriminator because it would create a runtime dependency that's harder to test and that fails open if Info.plist drifts.

Why an enum rather than two static `let`s or a struct: enums force `switch` exhaustiveness at every call site, which means adding a third variant in the future (e.g. a beta channel) becomes a compiler-enforced refactor rather than a grep-for-missed-sites refactor. This pattern matches ADR 0010 (typed cross-area seams).

### 3.2 The Tier 1.5 updater

#### State machine

```swift
enum UpdateState: Equatable {
    case idle                                           // never checked, or last check stale > 24h
    case checking                                       // GitHub API call in flight
    case downloading(version: String, progress: Double) // 0.0 ... 1.0
    case ready(version: String, dmgURL: URL, releaseNotes: String)
    case error(String)
    case upToDate(currentVersion: String)               // transient, used after manual check
}
```

`UpdateChecker.shared` is the single source of truth. `state` is `@Published`; `UpdateBannerView` observes it (renders only on `.ready`); `UpdateSheet` observes it (renders all states); the `UpdateMenuCommand` derives its menu-item title from it.

#### Poll lifecycle

1. **On stable app launch:** if `updaterEnabled`, schedule the first check 60 seconds after launch (give the app time to settle). Skip if a check has succeeded within the last 24h (persist last-check timestamp in `@AppStorage`).
2. **Every 24h after that:** repeat. Implemented as a single `Task` with a `try await Task.sleep` loop, not a `Timer` (Timer is more annoying to test).
3. **On manual trigger (menu click):** ignore the 24h gate, force `state = .checking`, run a check.

#### Single check

```swift
func performCheck() async {
    state = .checking
    do {
        let latest = try await fetchLatestRelease()  // GET api.github.com/repos/.../releases/latest
        let current = SemanticVersion.fromBundleString(Bundle.main.shortVersionString)
        if latest.version <= current {
            state = .upToDate(currentVersion: Bundle.main.shortVersionString)
            return
        }
        if let existing = stagedDMG(for: latest.version) {
            state = .ready(version: latest.version.string, dmgURL: existing, releaseNotes: latest.notes)
            return
        }
        await download(latest)  // updates state to .downloading then .ready
    } catch {
        // Manual-triggered: surface in state. Background-triggered: log + idle.
        if isManualTrigger { state = .error(error.localizedDescription) }
        else { state = .idle }
    }
}
```

#### Download

`URLSession.shared.downloadTask` with a `URLSessionDownloadDelegate` for progress callbacks. On completion, `FileManager.moveItem` atomically into `~/Library/Application Support/Maugham/Updates/Maugham-<version>.dmg`. No resume support — partial downloads are discarded on app restart and re-fetched. (Reason: download is ~10–30MB and re-fetch is cheap; resume logic is complexity for a problem that doesn't exist at this scale.)

On state transition to `.ready`, the SHA256 of the downloaded `.dmg` is computed and compared against the value GitHub returns in the API response. Mismatch logs an error and reverts to `.idle` — defense in depth while we're unsigned. This is a 10-line addition; not blocking the milestone if it slips.

#### Banner UI

Rendered via:

```swift
ProjectWindow_body.safeAreaInset(edge: .top) {
    if case .ready(let v, let url, let notes) = UpdateChecker.shared.state,
       !dismissedVersions.contains(v) {
        UpdateBannerView(version: v, dmgURL: url, notes: notes)
    }
}
```

The banner is ~36pt tall, dim background, "Maugham 0.2.0 is ready to install" text on the left, "Install" + "Later" buttons on the right, and a disclosure triangle that expands to show release notes (markdown-rendered into an `AttributedString`).

- **Install:** `NSWorkspace.shared.activateFileViewerSelecting(dmgURL)` — opens Finder with the `.dmg` selected. (User then double-clicks the `.dmg`, drags the new app to Applications, replaces the old one, relaunches.)
- **Later:** appends the version to `dismissedVersions: Set<String>` in `@AppStorage`. Banner stays hidden for that version until a newer one shows up.

`dismissedVersions` is keyed by version string, not a single boolean, so "dismiss 0.2.0" doesn't suppress 0.2.1's banner.

#### Menu item

Title derives from state:

| State | Menu item title |
|---|---|
| `.idle`, `.upToDate`, `.error` | "Check for Updates…" |
| `.checking` | "Checking for Updates…" |
| `.downloading(_, _)` | "Downloading Update…" |
| `.ready(_, _, _)` | "Install Update…" |

Clicking always opens `UpdateSheet`, which reflects the same state with full detail — progress bar during `.downloading`, release notes + Install button during `.ready`, "You're up to date" auto-dismiss for `.upToDate`, error message + Retry for `.error`. On `.idle`, opening the sheet immediately calls `checkNow()` so the user sees "Checking…" without a dead click.

### 3.3 Variant-aware MCP wiring

Three line-level changes:

```swift
// MCPInitializeHandler.swift:38 — was
serverInfo: ServerInfo(name: "maugham", version: "0.1.0"),
// becomes
serverInfo: ServerInfo(name: BuildVariant.current.mcpServerKey,
                       version: Bundle.main.shortVersionString),

// ClaudeDesktopConfig.swift:24,59,77 — was
servers["maugham"] = ["command": maughamBinary]
// becomes
let key = BuildVariant.current.mcpServerKey
servers[key] = [
    "command": maughamBinary,
    "env": ["MAUGHAM_MCP_SOCKET": BuildVariant.current.mcpSocketPath]
]
```

Stable and dev each have their own entry in Claude Desktop's `claude_desktop_config.json`. Both can be present simultaneously without overwriting each other. Claude Desktop presents them as two separate MCP servers. The user can ask Claude to read from either by name.

The `maugham-mcp` binary embedded in each `.app` is identical bytes-wise; the variant identity is conveyed entirely through the `env` block written by the variant-specific Set Up sheet.

### 3.4 The CI release pipeline

```yaml
# .github/workflows/release.yml
name: Release
on:
  push:
    tags: ['v[0-9]+.[0-9]+.[0-9]+']

jobs:
  release:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - uses: maxim-lobanov/setup-xcode@v1
        with: { xcode-version: '15.4' }
      - name: Install xcodegen
        run: brew install xcodegen
      - name: Extract version from tag
        id: ver
        run: echo "version=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"
      - name: Verify release notes exist
        run: |
          NOTES="docs/release-notes/v${{ steps.ver.outputs.version }}.md"
          test -f "$NOTES" || { echo "::error::Missing $NOTES"; exit 1; }
      - name: Sync version into project.yml
        run: |
          # Rewrite CFBundleShortVersionString and CFBundleVersion using yq or sed.
          # Implementation detail; spec doesn't fix the exact tool.
      - name: Generate project
        run: ./gen.sh
      - name: Build Release
        run: |
          xcodebuild -project Maugham.xcodeproj -scheme Maugham \
            -configuration Release build CODE_SIGNING_ALLOWED=NO
      - name: Test
        run: |
          xcodebuild -project Maugham.xcodeproj -scheme Maugham \
            -configuration Release test CODE_SIGNING_ALLOWED=NO
      - name: Package .dmg
        run: |
          APP_PATH=$(xcodebuild -showBuildSettings -scheme Maugham -configuration Release \
            | awk '/BUILT_PRODUCTS_DIR/ { print $3 }')/Maugham.app
          mkdir -p /tmp/dmg-root
          cp -R "$APP_PATH" /tmp/dmg-root/
          ln -s /Applications /tmp/dmg-root/Applications
          hdiutil create -volname Maugham -srcfolder /tmp/dmg-root -ov -format UDZO \
            "Maugham-${{ steps.ver.outputs.version }}.dmg"
      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          files: Maugham-${{ steps.ver.outputs.version }}.dmg
          body_path: docs/release-notes/v${{ steps.ver.outputs.version }}.md
          name: Maugham ${{ steps.ver.outputs.version }}
          draft: false
          prerelease: false
```

Key contract:
- **Tag is the version source of truth.** `project.yml`'s `CFBundleShortVersionString` stays at `"0.0.0-dev"` for local builds; CI rewrites it to the tag's version.
- **Release notes file is mandatory.** Workflow fails before any build if `docs/release-notes/v${VERSION}.md` is missing — forces the author to write notes before tagging.
- **Tests must pass.** Tagged commits with failing tests produce no release. The dev build's test pass before tagging is informational; CI's pass is the gate.
- **CFBundleVersion** is `${{ github.run_number }}` — strictly monotonic across the workflow's history.
- **DMG layout** includes a symlink to `/Applications` so the standard "drag the app to the Applications folder" mount-window UX works.

### 3.5 Path-A flip checklist (not implemented now)

For when Developer ID enrollment happens later:

1. Add Apple Developer ID Application cert as a base64-encoded GitHub Actions secret (`APPLE_DEVELOPER_ID_CERT_P12`, `APPLE_DEVELOPER_ID_CERT_PASSWORD`).
2. Add notary credentials as secrets (`APPLE_NOTARY_APPLE_ID`, `APPLE_NOTARY_TEAM_ID`, `APPLE_NOTARY_PASSWORD`).
3. In `release.yml`, add an "Import certs" step (use `apple-actions/import-codesign-certs@v3`) before Build.
4. After Build, add: `codesign --deep --force --options runtime --timestamp --sign "Developer ID Application: …" <app path>`.
5. After Package, add: `xcrun notarytool submit <dmg> --apple-id … --team-id … --password … --wait` then `xcrun stapler staple <dmg>`.
6. In `project.yml`, flip `CODE_SIGN_STYLE: Manual`, `CODE_SIGN_IDENTITY: "Developer ID Application: …"`, `ENABLE_HARDENED_RUNTIME: YES`.
7. Update `README.md` and CLAUDE.md to remove the right-click-to-open note.

The updater code is untouched. End-user-visible difference: no Gatekeeper warning on first open of a downloaded `.dmg`.

### 3.6 The cut-release.sh helper

```bash
#!/usr/bin/env bash
# Pre-flight checks for cutting a stable release.
set -euo pipefail

VERSION="${1:?Usage: $0 <version> [--skip-tests]}"
SKIP_TESTS="${2:-}"

# 1. Release notes must exist.
NOTES="docs/release-notes/v${VERSION}.md"
[[ -f "$NOTES" ]] || { echo "ERROR: $NOTES does not exist"; exit 1; }

# 2. Working tree clean and on main.
[[ -z "$(git status --porcelain)" ]] || { echo "ERROR: working tree dirty"; exit 1; }
[[ "$(git symbolic-ref --short HEAD)" == "main" ]] || { echo "ERROR: not on main"; exit 1; }

# 3. Tests pass (unless explicitly skipped).
if [[ "$SKIP_TESTS" != "--skip-tests" ]]; then
    ./gen.sh
    xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO
fi

# 4. Tag exists?
git rev-parse "v${VERSION}" >/dev/null 2>&1 && { echo "ERROR: tag v${VERSION} already exists"; exit 1; }

# 5. Create tag locally; print push command for user confirmation.
git tag -a "v${VERSION}" -m "Maugham ${VERSION}"
echo
echo "Tag v${VERSION} created locally. To trigger the release:"
echo "    git push origin v${VERSION}"
```

---

## 4. Data flow

### 4.1 Background update check (happy path)

```
T+60s after launch:    UpdateChecker.performCheck()
                       ↓
                       GET https://api.github.com/repos/dtrouton/Maugham/releases/latest
                       ↓
                       Response: tag_name="v0.2.0", assets[0]={name: "Maugham-0.2.0.dmg", browser_download_url: "https://…", size: 12345678}
                       ↓
                       SemanticVersion.parse("0.2.0") > SemanticVersion.parse("0.1.0")
                       ↓
                       state = .downloading(version: "0.2.0", progress: 0.0)
                       ↓
                       URLSession.downloadTask(from: dmgURL)
                       ↓ (progress callbacks update state.progress)
                       ↓
                       FileManager.moveItem(tmp → ~/Library/Application Support/Maugham/Updates/Maugham-0.2.0.dmg)
                       ↓
                       state = .ready(version: "0.2.0", dmgURL: <staged path>, releaseNotes: <body>)
                       ↓
                       UpdateBannerView (observing state) renders the "ready to install" bar
                       ↓
                       User clicks Install → NSWorkspace reveals the .dmg in Finder
```

### 4.2 Manual update check

Same as 4.1 except the entry point is the menu item, the 24h gate is bypassed, and `UpdateSheet` is opened on click. The sheet observes `state` and re-renders as state advances — user sees "Checking…" then "Downloading 47%" then "Ready to install" within the same modal.

### 4.3 Two-MCP-servers data flow (Claude Desktop)

```
User runs Set Up sheet from stable Maugham:
  ClaudeDesktopConfig writes:
    "mcpServers": {
      "maugham": {
        "command": "/Applications/Maugham.app/Contents/MacOS/maugham-mcp",
        "env": { "MAUGHAM_MCP_SOCKET": "~/Library/Application Support/Maugham/mcp.sock" }
      }
    }

User runs Set Up sheet from dev Maugham:
  ClaudeDesktopConfig writes (additive):
    "mcpServers": {
      "maugham": { …unchanged… },
      "maugham-dev": {
        "command": "<DerivedData path>/Maugham Dev.app/Contents/MacOS/maugham-mcp",
        "env": { "MAUGHAM_MCP_SOCKET": "~/Library/Application Support/Maugham Dev/mcp.sock" }
      }
    }

Claude Desktop sees two MCP servers:
  - maugham      → bridges to stable's socket  → stable's open projects
  - maugham-dev  → bridges to dev's socket     → dev's open projects (typically test fixtures)
```

---

## 5. Error handling

### 5.1 Update check

| Failure | Background-triggered | Manual-triggered |
|---|---|---|
| Network unreachable | Silent, log only, `state = .idle` | `state = .error("Couldn't reach GitHub")` |
| GitHub API rate-limited (unauthenticated: 60 req/hr per IP) | Silent, log only, defer to next 24h tick | `state = .error("Rate-limited by GitHub — try again later")` |
| API returns malformed JSON | Silent, log, `state = .idle` | `state = .error("Couldn't parse GitHub response")` |
| Release has no `.dmg` asset | Silent, log, `state = .idle` | `state = .error("Release v0.X.Y is missing the .dmg asset")` |
| Download fails mid-way | Discard partial, log, `state = .idle` | `state = .error("Download failed")` with Retry |
| SHA256 mismatch after download | Delete file, `state = .error(…)` regardless of trigger source | Same |

The asymmetric "silent in background, vocal on manual" pattern matches the principle: the user only sees error noise when they asked a question.

### 5.2 Variant misconfiguration

If `BuildVariant.current.mcpServerKey` is somehow used for both stable and dev (e.g. a compile flag misconfiguration that produces a dev-flagged binary at the stable bundle id), Claude Desktop's config could end up with a `maugham-dev` entry pointing at the stable install. Symptom: Claude sees one server, not two; the dev app's MCP traffic never reaches it.

Mitigation: a launch-time assertion in `MaughamApp.init`:

```swift
#if MAUGHAM_DEV_BUILD
assert(Bundle.main.bundleIdentifier == "com.maugham.Maugham.dev",
       "MAUGHAM_DEV_BUILD set but bundle id is \(Bundle.main.bundleIdentifier ?? "nil")")
#else
assert(Bundle.main.bundleIdentifier == "com.maugham.Maugham",
       "MAUGHAM_DEV_BUILD not set but bundle id is \(Bundle.main.bundleIdentifier ?? "nil")")
#endif
```

Fails fast in Debug builds; no-op in Release.

### 5.3 CI workflow

| Failure | Workflow outcome | Effect on existing stable installs |
|---|---|---|
| Release notes file missing | Workflow fails at step 5 (verify), no release published | None — checks pass before any build artifact exists |
| Tests fail | Workflow fails at test step, no release published | None |
| Build fails | Workflow fails, no release published | None |
| GitHub Release API call fails (rare) | Workflow fails at publish step, `.dmg` exists in artifacts but no release | Stable installs don't see the new version; author re-runs the workflow manually |
| Successful build but the `.dmg` is corrupt | Stable installs detect via SHA256 mismatch and refuse to install | Author re-cuts the release with a new patch version |

The "no partial releases" guarantee comes from the workflow only calling the publish action as its last step. Earlier failures leave no public artifact.

---

## 6. CLAUDE.md additions

Inserted between the existing "Build flow" section and "Architectural tripwires":

```markdown
## Releases

Stable releases are tag-triggered via GitHub Actions. The recipe:

1. Write release notes: `docs/release-notes/v0.X.Y.md` (template at `docs/release-notes/_template.md`).
2. Commit them on `main`.
3. `./scripts/cut-release.sh 0.X.Y` — verifies notes exist, tree is clean, tests pass, then
   creates `v0.X.Y` tag and prints the push command. Pass `--skip-tests` only if you know why.
4. `git push --tags`. Workflow at `.github/workflows/release.yml` builds Release config,
   runs tests, packages the `.dmg`, and creates the GitHub Release with the notes file as body.
5. ~10 minutes later, the stable app's next check picks it up. Menu title goes to
   "Install Update…"; clicking reveals the `.dmg` in Finder.

**Version is tag-derived.** `project.yml`'s `CFBundleShortVersionString` stays at the placeholder
`"0.0.0-dev"` for local builds; CI rewrites it from the tag at build time. Don't bump it in
`project.yml` — bump it via the tag.

**Workflow fails before publish if `docs/release-notes/v0.X.Y.md` is missing.** Tag pattern
`v[0-9]+.[0-9]+.[0-9]+` triggers the release workflow; milestone tags (`milestone-*`) don't.

**Dev builds don't auto-update.** `BuildVariant.dev` (set by `-DMAUGHAM_DEV_BUILD` in Debug config)
disables the updater. Stable lives at bundle id `com.maugham.Maugham` in `/Applications`; dev at
`com.maugham.Maugham.dev` from Xcode. They have separate MCP socket paths and separate Claude
Desktop config entries (`maugham` vs `maugham-dev`) — see `Maugham/BuildVariant.swift`.

**Builds are currently unsigned** (ad-hoc, `CODE_SIGN_IDENTITY: "-"`). Each downloaded `.dmg`
requires a one-time right-click → Open on first launch — Gatekeeper's standard "unidentified
developer" treatment. Switching to Developer ID + notarization is a ~30-min CI change (add cert
+ notarize/staple steps to the release workflow, flip `CODE_SIGN_IDENTITY` and
`ENABLE_HARDENED_RUNTIME` in `project.yml`). The updater code doesn't change. See
`docs/superpowers/specs/2026-05-22-production-release-design.md` for the full sequence.
```

Additions to the "Questions you do not need to ask" section:

- "How do I cut a release?" → see the Releases section.
- "Should I bump version in `project.yml`?" → No. The git tag is the source of truth; CI writes the version into the bundle at build time.
- "Should dev or stable do X?" → see `Maugham/BuildVariant.swift` — there's one enum, all the seams hang off it.

New tripwire (#13) appended to the Architectural Tripwires list:

```markdown
13. **Don't hardcode "maugham", "Maugham", or socket paths.** Six values vary by `BuildVariant`:
    bundle id, display name, support folder name, MCP socket path, Claude Desktop config key,
    and MCP `serverInfo.name`. If you add a seventh, route it through `BuildVariant.current`
    instead. Compile-time check: `grep -n '"maugham"\|"Maugham"' Maugham/` should return zero
    matches outside `Maugham/BuildVariant.swift` and tests.
```

---

## 7. Testing

### 7.1 New unit tests

- `BuildVariantTests` — variant resolution from compile flag (one test per `#if` branch via conditional compilation); per-variant value derivation (six derived properties × 2 variants = 12 assertions).
- `SemanticVersionTests` — parse "0.1.0", "0.2.0", "0.0.0-dev"; ordering across major/minor/patch; rejection of malformed strings.
- `UpdateCheckerTests` — state-machine transitions: `.idle → .checking → .upToDate`; `.idle → .checking → .downloading → .ready`; `.idle → .checking → .error` (manual); `.idle → .checking → .idle` (background failure). Mock URLSession via a `URLProtocol` subclass. Asserts the silent-vs-vocal asymmetry.
- `GitHubReleasesResponseTests` — parse a real captured response fixture (`MaughamTests/Fixtures/github-releases-latest.json`). Tolerates missing optional fields. Surfaces "no .dmg asset" as a distinct error.
- `ClaudeDesktopConfigVariantTests` — writing under stable produces `"maugham"` entry; writing under dev produces `"maugham-dev"` entry; both can coexist; remove only removes the variant's own entry.
- `MCPInitializeVariantTests` — `ServerInfo.name` reflects current variant; `version` reflects `Bundle.main.shortVersionString`, not a hardcoded literal.

### 7.2 New integration tests

- `UpdateBannerIntegrationTest` — `UpdateChecker.state = .ready(...)` causes `UpdateBannerView` to render; `state = .idle` causes it not to render.
- `UpdateSheetIntegrationTest` — same for the sheet across all six `UpdateState` cases.

### 7.3 CI workflow self-test

The first time the workflow runs end-to-end is the implicit integration test. The spec's plan should include cutting a `v0.2.0` release as the last task — that release is the artifact that proves the pipeline works. If anything is wrong (notes file missing, build break, packaging issue), it surfaces there rather than in a later release.

### 7.4 Manual smoke

After the milestone ships and `v0.2.0` is cut:

1. Install Maugham from the GitHub Release `.dmg`. Right-click → Open. Confirm it opens.
2. Quit. Build dev from Xcode. Confirm it opens as a separate app, with title "Maugham Dev".
3. Run Set Up sheet in stable; verify `claude_desktop_config.json` has the `maugham` entry only.
4. Run Set Up sheet in dev; verify the file now has both `maugham` and `maugham-dev` entries.
5. Open both Maughams. Open Claude Desktop. Ask "list MCP servers" — both should appear.
6. Cut a `v0.2.1` release (with a no-op change). Wait 10 minutes. In stable, click "Check for Updates…" — confirm sheet shows "Downloading…" then "Install Update…". Confirm dev's menu does *not* show this option (updater disabled).
7. Click Install. Drag the new app to /Applications. Replace. Relaunch. Confirm version reads 0.2.1.

---

## 8. What's deliberately out of scope

- **Sparkle adoption.** Considered and rejected in favor of the homebrew Tier 1.5 updater. Rationale: Maugham's "files as truth, one clear way, no over-engineering" ethos prefers ~150 lines of fully-owned code over a 5MB framework dependency. Sparkle remains the right answer if we ever want true in-app bundle swap (no manual drag step); that decision can be revisited additively without throwing away anything built here.
- **In-app bundle swap and relaunch.** The user explicitly accepts the "open the dmg, drag the app" final step. The "swap-running-app" code path is the highest-risk-per-line code that could be added to Maugham and is precisely the part Sparkle has spent 15 years getting right.
- **Beta channel.** No `v0.2.0-beta.1` tag handling, no in-app channel switcher, no Settings toggle. Additive feature if needed later.
- **Delta updates.** Full `.dmg` re-download every version. At ~10–30MB per release, this is fine.
- **Crash reporting / telemetry.** Not introduced as part of this milestone.
- **Auto-updater for the embedded `maugham-mcp` binary independently.** The binary ships inside each `.app` and is replaced wholesale when the app is replaced.
- **Path A (Developer ID + notarization) implementation.** Path remains B (ad-hoc) for now. Path A flip is documented in §3.5 as a future ~30-min change.
- **Migrating existing on-disk Application Support state from `~/Library/Application Support/Maugham/` to a variant-specific path.** The stable variant continues to use the existing path (so the author's currently-running Maugham state is preserved untouched). Only the dev variant lives under a new `Maugham Dev/` folder, which is created fresh — no migration logic.

---

## 9. Open questions for the implementation plan

None blocking. Items to confirm during planning:

- Exact GitHub Actions runner image lifetime / Xcode-version compatibility window. (Likely fine with `macos-14` + Xcode 15.4 for the foreseeable future.)
- The mechanism for rewriting `project.yml`'s version field in CI — `yq`, `sed`, or a small Swift script. All work; choose during implementation.
- Whether `UpdateChecker` should re-check immediately when the app becomes active after sleep, or only on the 24h schedule. Default: 24h schedule only. Reconsider if the cadence feels wrong in practice.
