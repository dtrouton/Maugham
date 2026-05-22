# Production Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut a stable, installable Maugham that lives in `/Applications` alongside the Xcode-launched dev build, downloads its own updates from GitHub Releases, and ships a tag-triggered CI pipeline that publishes signed-when-we-flip-the-switch `.dmg`s with structured release notes.

**Architecture:** A single `BuildVariant` enum (driven by `-DMAUGHAM_DEV_BUILD` compile flag) gates five runtime values: display name, Application Support folder, MCP socket path, Claude Desktop config key, and updater-enabled toggle. The Tier 1.5 updater is a homebrew `@MainActor @ObservableObject` singleton that polls GitHub's `releases/latest` endpoint, silently downloads new `.dmg`s, and surfaces via a banner + state-reflecting menu item. CI is a single `release.yml` workflow on `macos-14` triggered by `v*.*.*` tags.

**Tech Stack:** Swift 5.10 / SwiftUI / AppKit / XCTest / xcodegen / GitHub Actions (macos-14 runner) / `hdiutil` / `softprops/action-gh-release`. No new framework dependencies.

**Source spec:** [`docs/superpowers/specs/2026-05-22-production-release-design.md`](../specs/2026-05-22-production-release-design.md).

---

## File Structure

### New files

| Path | Responsibility |
|---|---|
| `Maugham/BuildVariant.swift` | Enum + derived properties. Single source of truth for stable/dev differentiation. |
| `Maugham/Updates/SemanticVersion.swift` | Value type for parsing/comparing `X.Y.Z` strings. |
| `Maugham/Updates/UpdateState.swift` | Public `UpdateState` enum (idle / checking / downloading / ready / error / upToDate). |
| `Maugham/Updates/UpdateChecker.swift` | `@MainActor @ObservableObject` singleton. Owns the poll loop, network calls, and download. |
| `Maugham/Updates/GitHubReleasesAPI.swift` | Codable response model + `fetchLatestRelease()` async function. Testable via `URLSession` injection. |
| `Maugham/Updates/UpdateBannerView.swift` | Slim `.safeAreaInset(.top)` banner. Renders only on `.ready`. |
| `Maugham/Updates/UpdateSheet.swift` | Modal sheet opened from the menu item; reflects all `UpdateState` cases. |
| `Maugham/Updates/UpdateMenuCommand.swift` | `Commands` block that adds the state-reflecting menu item. |
| `MaughamTests/SemanticVersionTests.swift` | Parse + compare + reject malformed. |
| `MaughamTests/BuildVariantTests.swift` | Per-variant value derivation. |
| `MaughamTests/Updates/GitHubReleasesAPITests.swift` | Parse the fixture; surface missing-dmg case. |
| `MaughamTests/Updates/UpdateCheckerTests.swift` | State machine transitions; silent-vs-vocal asymmetry. |
| `MaughamTests/Updates/UpdateBannerIntegrationTests.swift` | Banner renders iff state is `.ready`. |
| `MaughamTests/Updates/UpdateSheetIntegrationTests.swift` | Sheet content reflects all states. |
| `MaughamTests/Fixtures/github-releases-latest.json` | Captured GitHub API response (verbatim or trimmed). |
| `.github/workflows/release.yml` | Tag-triggered release pipeline. |
| `scripts/cut-release.sh` | Pre-flight checks + tag creation. |
| `docs/release-notes/_template.md` | Per-release notes template. |
| `docs/release-notes/v0.2.0.md` | Notes for the first cut release (placeholder during dev, filled at release time). |

### Modified files

| Path | Change |
|---|---|
| `project.yml` | Add per-configuration build settings: Debug = dev bundle id + `-DMAUGHAM_DEV_BUILD`; Release = stable. `CFBundleShortVersionString` placeholder `"0.0.0-dev"`. |
| `Maugham/MaughamApp.swift` | Wire `UpdateChecker` lifecycle (stable only); add bundle-id assertion; route `mcpSocketPath` through `BuildVariant`; add `UpdateMenuCommand()`. |
| `Maugham/MCP/MCPInitializeHandler.swift` | `ServerInfo(name:version:)` reads from `BuildVariant.current.mcpServerKey` and `Bundle.main`. |
| `Maugham/MCP/ClaudeDesktopConfig.swift` | API gains optional `serverKey` and `socketPath` parameters; writes `"env": [...]` block; remove uses the key. |
| `Maugham/Views/HelpClaudeDesktopSheet.swift` | JSON snippet uses `BuildVariant.current.mcpServerKey`. |
| `Maugham/Views/WelcomeView.swift` | Display title uses `BuildVariant.current.displayName`. |
| `Maugham/Views/SettingsTabs/AboutSettingsTab.swift` | About text uses `BuildVariant.current.displayName`. |
| `Maugham/Views/ProjectWindow.swift` | Add `.safeAreaInset(edge: .top) { UpdateBannerView() }`. |
| `MaughamTests/MCP/SetupClaudeDesktopConfigTests.swift` | Adjust to thread the new `serverKey` parameter through (verifying it works for both keys). |
| `README.md` | Add "Install" section pointing at GitHub Releases; document right-click → Open. |
| `CLAUDE.md` | New "Releases" section; tripwire #13; three additions to "Questions you do not need to ask". |

---

## Task Sequencing

**Phase 1 — Foundations (Tasks 1–4):** Add `SemanticVersion` and `BuildVariant`. Split `project.yml`. Add startup assertion. No behavior change for stable users.

**Phase 2 — Wire variant through MCP & paths (Tasks 5–9):** Route all hardcoded "maugham"/"Maugham" strings through `BuildVariant`. Stable behavior unchanged byte-for-byte; dev builds gain their own identity.

**Phase 3 — Updater core (Tasks 10–13):** Build the headless updater with mocked network.

**Phase 4 — Updater UI (Tasks 14–17):** Banner, sheet, menu, wire into `MaughamApp`.

**Phase 5 — Release infrastructure (Tasks 18–22):** Release-notes scaffold, helper script, CI workflow, README, CLAUDE.md.

**Phase 6 — Pipeline self-test (Task 23):** Cut `v0.2.0`. End-to-end verification.

---

## Task 1: SemanticVersion type + tests

**Files:**
- Create: `Maugham/Updates/SemanticVersion.swift`
- Create: `MaughamTests/SemanticVersionTests.swift`

Add a `Maugham/Updates/` directory to the project (xcodegen auto-discovers via `project.yml`'s `sources: [Maugham]` — no project.yml change needed for new subdirs).

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/SemanticVersionTests.swift
import XCTest
@testable import Maugham

final class SemanticVersionTests: XCTestCase {
    func test_parseStandardVersion() {
        XCTAssertEqual(SemanticVersion("0.1.0"), SemanticVersion(major: 0, minor: 1, patch: 0))
        XCTAssertEqual(SemanticVersion("1.2.3"), SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemanticVersion("12.34.56"), SemanticVersion(major: 12, minor: 34, patch: 56))
    }

    func test_parseStripsVPrefix() {
        XCTAssertEqual(SemanticVersion("v0.1.0"), SemanticVersion(major: 0, minor: 1, patch: 0))
    }

    func test_parseRejectsMalformed() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("0.1"))
        XCTAssertNil(SemanticVersion("0.1.0.4"))
        XCTAssertNil(SemanticVersion("a.b.c"))
        XCTAssertNil(SemanticVersion("0.1.0-beta"))   // pre-release suffix unsupported in this milestone
    }

    func test_parseDevPlaceholder() {
        // "0.0.0-dev" is our placeholder; parse must reject it so update checks
        // don't compare against a real version.
        XCTAssertNil(SemanticVersion("0.0.0-dev"))
    }

    func test_orderingMajor() {
        XCTAssertLessThan(SemanticVersion("0.9.9")!, SemanticVersion("1.0.0")!)
    }

    func test_orderingMinor() {
        XCTAssertLessThan(SemanticVersion("0.1.9")!, SemanticVersion("0.2.0")!)
    }

    func test_orderingPatch() {
        XCTAssertLessThan(SemanticVersion("0.1.0")!, SemanticVersion("0.1.1")!)
    }

    func test_equalityIgnoresVPrefix() {
        XCTAssertEqual(SemanticVersion("v1.2.3"), SemanticVersion("1.2.3"))
    }

    func test_stringRoundTrip() {
        XCTAssertEqual(SemanticVersion("1.2.3")?.string, "1.2.3")
    }
}
```

- [ ] **Step 2: Run tests, expect them to fail**

Run from the repo root:
```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```
Expected: build fails with "cannot find SemanticVersion in scope".

- [ ] **Step 3: Implement `SemanticVersion`**

```swift
// Maugham/Updates/SemanticVersion.swift
import Foundation

/// Strict semver `X.Y.Z`. Pre-release suffixes (`-beta`, etc.) are intentionally
/// unsupported in this milestone — see the production-release spec §3.4.
public struct SemanticVersion: Equatable, Comparable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ raw: String) {
        let stripped = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let parts = stripped.split(separator: ".")
        guard parts.count == 3,
              let M = Int(parts[0]), let m = Int(parts[1]), let p = Int(parts[2]) else {
            return nil
        }
        self.init(major: M, minor: m, patch: p)
    }

    public var string: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
```

- [ ] **Step 4: Re-run xcodegen and tests, expect them to pass**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: "Test Suite 'SemanticVersionTests' passed".

- [ ] **Step 5: Commit**

```bash
git add Maugham/Updates/SemanticVersion.swift MaughamTests/SemanticVersionTests.swift
git commit -m "feat(updates): semantic version value type"
```

---

## Task 2: BuildVariant enum + tests

**Files:**
- Create: `Maugham/BuildVariant.swift`
- Create: `MaughamTests/BuildVariantTests.swift`

- [ ] **Step 1: Write the failing tests**

The tricky bit: `BuildVariant.current` is determined by a compile-time flag, so the test target sees whatever the test build's flag setting is. Test target builds without `-DMAUGHAM_DEV_BUILD` (because tests run against the app's Release-mode code path), so `BuildVariant.current == .stable` in tests. We test per-variant derived properties exhaustively by referencing the variant explicitly.

```swift
// MaughamTests/BuildVariantTests.swift
import XCTest
@testable import Maugham

final class BuildVariantTests: XCTestCase {
    func test_stableDisplayName() {
        XCTAssertEqual(BuildVariant.stable.displayName, "Maugham")
    }

    func test_devDisplayName() {
        XCTAssertEqual(BuildVariant.dev.displayName, "Maugham Dev")
    }

    func test_stableSupportFolderName() {
        XCTAssertEqual(BuildVariant.stable.supportFolderName, "Maugham")
    }

    func test_devSupportFolderName() {
        XCTAssertEqual(BuildVariant.dev.supportFolderName, "Maugham Dev")
    }

    func test_stableMcpServerKey() {
        XCTAssertEqual(BuildVariant.stable.mcpServerKey, "maugham")
    }

    func test_devMcpServerKey() {
        XCTAssertEqual(BuildVariant.dev.mcpServerKey, "maugham-dev")
    }

    func test_stableUpdaterEnabled() {
        XCTAssertTrue(BuildVariant.stable.updaterEnabled)
    }

    func test_devUpdaterDisabled() {
        XCTAssertFalse(BuildVariant.dev.updaterEnabled)
    }

    func test_stableSocketPathUsesStableFolder() {
        XCTAssertTrue(BuildVariant.stable.mcpSocketPath.hasSuffix("Application Support/Maugham/mcp.sock"))
    }

    func test_devSocketPathUsesDevFolder() {
        XCTAssertTrue(BuildVariant.dev.mcpSocketPath.hasSuffix("Application Support/Maugham Dev/mcp.sock"))
    }

    func test_currentIsStableInTestBuild() {
        // Test target builds without -DMAUGHAM_DEV_BUILD; current must resolve to .stable.
        XCTAssertEqual(BuildVariant.current, .stable)
    }
}
```

- [ ] **Step 2: Run tests, expect failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: build fails with "cannot find BuildVariant in scope".

- [ ] **Step 3: Implement `BuildVariant`**

```swift
// Maugham/BuildVariant.swift
import Foundation

/// Stable vs. Dev build differentiation. Drives all variant-aware identity
/// (display name, support folder, MCP socket path, Claude Desktop config key,
/// MCP serverInfo.name, updater enabled).
///
/// See docs/superpowers/specs/2026-05-22-production-release-design.md §3.1.
public enum BuildVariant: Equatable {
    case stable
    case dev

    public static let current: BuildVariant = {
        #if MAUGHAM_DEV_BUILD
        return .dev
        #else
        return .stable
        #endif
    }()

    public var displayName: String       { self == .dev ? "Maugham Dev" : "Maugham" }
    public var supportFolderName: String { self == .dev ? "Maugham Dev" : "Maugham" }
    public var mcpServerKey: String      { self == .dev ? "maugham-dev" : "maugham" }
    public var updaterEnabled: Bool      { self == .stable }

    public var mcpSocketPath: String {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib
            .appendingPathComponent("Application Support")
            .appendingPathComponent(supportFolderName)
            .appendingPathComponent("mcp.sock")
            .path
    }
}
```

- [ ] **Step 4: Run tests, expect them to pass**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: "Test Suite 'BuildVariantTests' passed". The total test count grows by 11.

- [ ] **Step 5: Commit**

```bash
git add Maugham/BuildVariant.swift MaughamTests/BuildVariantTests.swift
git commit -m "feat: BuildVariant enum (stable/dev runtime split)"
```

---

## Task 3: project.yml — split Debug/Release configurations

**Files:**
- Modify: `project.yml`

This adds the compile flag and bundle id split. Nothing reads them yet (no behavior change for stable, dev not yet wired up downstream).

- [ ] **Step 1: Edit `project.yml`**

Replace the existing `targets.Maugham` block with:

```yaml
  Maugham:
    type: application
    platform: macOS
    configFiles: {}
    sources:
      - path: Maugham
        excludes:
          - Info.plist
          - "**/AREA.md"
    info:
      path: Maugham/Info.plist
      properties:
        CFBundleDisplayName: Maugham
        CFBundleShortVersionString: "0.0.0-dev"
        CFBundleVersion: "1"
        LSMinimumSystemVersion: "14.0"
        NSPrincipalClass: NSApplication
        NSSupportsAutomaticTermination: YES
        NSSupportsSuddenTermination: NO
    settings:
      base:
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        COMBINE_HIDPI_IMAGES: YES
      configs:
        Debug:
          PRODUCT_BUNDLE_IDENTIFIER: com.maugham.Maugham.dev
          SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited) MAUGHAM_DEV_BUILD
        Release:
          PRODUCT_BUNDLE_IDENTIFIER: com.maugham.Maugham
    resources:
      - path: Maugham/Resources
        includes:
          - "*.md"
    dependencies:
      - target: maugham-mcp
        copy:
          destination: executables
          codeSign: false
```

Key changes from the current state:
- `CFBundleShortVersionString` becomes `"0.0.0-dev"` (placeholder; CI rewrites it).
- `settings.base` keeps things common to both configs.
- `settings.configs.Debug` adds `PRODUCT_BUNDLE_IDENTIFIER` override and `SWIFT_ACTIVE_COMPILATION_CONDITIONS` (xcodegen-friendly way to pass `-DMAUGHAM_DEV_BUILD` to Swift).
- `settings.configs.Release` keeps the stable bundle id.

- [ ] **Step 2: Regenerate project and verify**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -showBuildSettings -configuration Debug -target Maugham 2>/dev/null | grep -E "PRODUCT_BUNDLE_IDENTIFIER|SWIFT_ACTIVE_COMPILATION_CONDITIONS|CFBundleShortVersionString" | head -5
```
Expected output includes:
```
PRODUCT_BUNDLE_IDENTIFIER = com.maugham.Maugham.dev
SWIFT_ACTIVE_COMPILATION_CONDITIONS = MAUGHAM_DEV_BUILD
```

Then:
```bash
xcodebuild -project Maugham.xcodeproj -showBuildSettings -configuration Release -target Maugham 2>/dev/null | grep -E "PRODUCT_BUNDLE_IDENTIFIER|SWIFT_ACTIVE_COMPILATION_CONDITIONS" | head -3
```
Expected:
```
PRODUCT_BUNDLE_IDENTIFIER = com.maugham.Maugham
SWIFT_ACTIVE_COMPILATION_CONDITIONS =
```

- [ ] **Step 3: Build both configs to confirm they compile**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: both end with `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run tests to confirm no regression**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: all existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add project.yml
git commit -m "build: split Debug/Release with dev bundle id + MAUGHAM_DEV_BUILD flag"
```

---

## Task 4: Bundle-id assertion in MaughamApp

**Files:**
- Modify: `Maugham/MaughamApp.swift`

Fail-fast guardrail: if the compile flag and bundle id ever disagree, the app crashes immediately in Debug. Release is a no-op (the assert compiles out).

- [ ] **Step 1: Add the assertion at the top of `MaughamApp.init`**

Locate `init() {` in `Maugham/MaughamApp.swift` (around line 18). Insert at the very top of the init body, before the `NotificationCenter.default.addObserver` block:

```swift
        // Fail-fast guardrail: if the compile flag and bundle id drift apart
        // (e.g. CI config error), this fires immediately in Debug.
        #if MAUGHAM_DEV_BUILD
        assert(Bundle.main.bundleIdentifier == "com.maugham.Maugham.dev",
               "MAUGHAM_DEV_BUILD set but bundle id is \(Bundle.main.bundleIdentifier ?? "nil")")
        #else
        assert(Bundle.main.bundleIdentifier == "com.maugham.Maugham",
               "MAUGHAM_DEV_BUILD not set but bundle id is \(Bundle.main.bundleIdentifier ?? "nil")")
        #endif
```

- [ ] **Step 2: Build both configs to confirm the assertion is well-formed**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: both succeed.

- [ ] **Step 3: Run tests**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Maugham/MaughamApp.swift
git commit -m "feat: assert bundle id matches compile flag at launch"
```

---

## Task 5: MCPInitializeHandler — variant-aware server info

**Files:**
- Modify: `Maugham/MCP/MCPInitializeHandler.swift:38`

Replace the two hardcoded literals (`"maugham"`, `"0.1.0"`) with runtime-derived values.

- [ ] **Step 1: Edit MCPInitializeHandler.swift line 38 area**

Find the line:
```swift
            serverInfo: ServerInfo(name: "maugham", version: "0.1.0"),
```

Replace with:
```swift
            serverInfo: ServerInfo(
                name: BuildVariant.current.mcpServerKey,
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"),
```

- [ ] **Step 2: Run tests**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: all tests pass. Existing MCP protocol tests may already assert on serverInfo — if so, they'll need an update. If a test fails with an assertion like `XCTAssertEqual("maugham", "maugham") - PASS` but `"0.1.0", actual "0.0.0-dev"`, update the assertion to read the same dynamic value the production code uses, OR replace the literal `"0.1.0"` expectation with whatever `Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"` evaluates to in the test build. The `BUNDLE_DISPLAY_VERSION` will be the Info.plist value, which in the test target is whatever `GENERATE_INFOPLIST_FILE: YES` produces — likely `"1"` or absent. If tests fail here, run them, read the actual value, and update the assertion to match.

If you don't see any failure, the existing tests don't pin serverInfo's version and you're done.

- [ ] **Step 3: Commit**

```bash
git add Maugham/MCP/MCPInitializeHandler.swift
git commit -m "feat(mcp): serverInfo uses BuildVariant + dynamic bundle version"
```

If you also had to update tests, include them in the same commit.

---

## Task 6: ClaudeDesktopConfig — variant key + env block

**Files:**
- Modify: `Maugham/MCP/ClaudeDesktopConfig.swift`
- Modify: `MaughamTests/MCP/SetupClaudeDesktopConfigTests.swift`

The public API gains an optional `serverKey` parameter (defaulting to `BuildVariant.current.mcpServerKey`) and `merge` gains an optional `socketPath` parameter that, when present, writes an `"env"` block. Default-arg backwards compatibility means tests can be updated incrementally.

- [ ] **Step 1: Modify `ClaudeDesktopConfig.swift`**

Replace the file contents with:

```swift
import Foundation

/// Detects and mutates Claude Desktop's config file. Variant-aware via the
/// optional `serverKey` parameter on each entry point — defaults to the
/// current build variant's MCP server key.
public enum ClaudeDesktopConfig {
    public enum State: Equatable {
        case missing
        case corrupt
        case unconfigured
        case stalePath(currentPath: String)
        case configured(path: String)
    }

    public static let defaultConfigURL: URL = {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("Application Support/Claude/claude_desktop_config.json")
    }()

    public static func detect(
        configURL: URL,
        expectedBinary: String,
        serverKey: String = BuildVariant.current.mcpServerKey
    ) -> State {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: configURL) else { return .corrupt }
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let dict = any as? [String: Any] else { return .corrupt }
        let servers = dict["mcpServers"] as? [String: Any] ?? [:]
        guard let entry = servers[serverKey] as? [String: Any],
              let cmd = entry["command"] as? String else {
            return .unconfigured
        }
        if cmd == expectedBinary { return .configured(path: cmd) }
        return .stalePath(currentPath: cmd)
    }
}

extension ClaudeDesktopConfig {
    public enum MergeError: Error {
        case existingConfigCorrupt
    }

    /// Atomically merge a server entry into the config. Creates the file if
    /// absent. Throws if the existing file is unparseable JSON.
    ///
    /// `socketPath` (if non-nil) is written as `"env": ["MAUGHAM_MCP_SOCKET": <path>]`
    /// so the embedded binary doesn't rely on its hardcoded default.
    public static func merge(
        configURL: URL,
        maughamBinary: String,
        serverKey: String = BuildVariant.current.mcpServerKey,
        socketPath: String? = nil
    ) throws {
        let parent = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var dict: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            if data.isEmpty {
                dict = [:]
            } else if let any = try? JSONSerialization.jsonObject(with: data),
                      let parsed = any as? [String: Any] {
                dict = parsed
            } else {
                throw MergeError.existingConfigCorrupt
            }
        }
        var servers = dict["mcpServers"] as? [String: Any] ?? [:]
        var entry: [String: Any] = ["command": maughamBinary]
        if let socketPath {
            entry["env"] = ["MAUGHAM_MCP_SOCKET": socketPath]
        }
        servers[serverKey] = entry
        dict["mcpServers"] = servers

        let out = try JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        let tmpURL = configURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        try out.write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tmpURL)
    }

    /// Remove this variant's entry from `mcpServers`, preserving other servers.
    public static func removeMaughamEntry(
        configURL: URL,
        serverKey: String = BuildVariant.current.mcpServerKey
    ) throws {
        let data = try Data(contentsOf: configURL)
        guard let any = try? JSONSerialization.jsonObject(with: data),
              var dict = any as? [String: Any] else {
            throw MergeError.existingConfigCorrupt
        }
        var servers = dict["mcpServers"] as? [String: Any] ?? [:]
        servers.removeValue(forKey: serverKey)
        dict["mcpServers"] = servers
        let out = try JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        let tmpURL = configURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        try out.write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tmpURL)
    }
}
```

- [ ] **Step 2: Add new tests for variant + env behavior**

Open `MaughamTests/MCP/SetupClaudeDesktopConfigTests.swift` and append these test cases inside the `final class SetupClaudeDesktopConfigTests` declaration:

```swift
    func test_detect_explicitDevKeyMatchesEntry() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try #"{"mcpServers":{"maugham-dev":{"command":"/dev/path/maugham-mcp"}}}"#.write(
            to: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            ClaudeDesktopConfig.detect(
                configURL: path, expectedBinary: "/dev/path/maugham-mcp", serverKey: "maugham-dev"),
            .configured(path: "/dev/path/maugham-mcp"))
    }

    func test_detect_stableKeyIgnoresDevEntry() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try #"{"mcpServers":{"maugham-dev":{"command":"/dev/x"}}}"#.write(
            to: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            ClaudeDesktopConfig.detect(configURL: path, expectedBinary: "/stable/x", serverKey: "maugham"),
            .unconfigured)
    }

    func test_merge_writesEnvBlockWhenSocketPathProvided() throws {
        let dir = tmp()
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try ClaudeDesktopConfig.merge(
            configURL: path,
            maughamBinary: "/x",
            serverKey: "maugham-dev",
            socketPath: "/tmp/dev.sock")
        let data = try Data(contentsOf: path)
        let dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(dict["mcpServers"] as? [String: Any])
        let devEntry = try XCTUnwrap(servers["maugham-dev"] as? [String: Any])
        XCTAssertEqual(devEntry["command"] as? String, "/x")
        let env = try XCTUnwrap(devEntry["env"] as? [String: String])
        XCTAssertEqual(env["MAUGHAM_MCP_SOCKET"], "/tmp/dev.sock")
    }

    func test_merge_devAndStableCoexist() throws {
        let dir = tmp()
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try ClaudeDesktopConfig.merge(
            configURL: path, maughamBinary: "/stable", serverKey: "maugham", socketPath: "/s.sock")
        try ClaudeDesktopConfig.merge(
            configURL: path, maughamBinary: "/dev", serverKey: "maugham-dev", socketPath: "/d.sock")
        let data = try Data(contentsOf: path)
        let dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(dict["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["maugham"])
        XCTAssertNotNil(servers["maugham-dev"])
    }

    func test_remove_onlyRemovesGivenKey() throws {
        let dir = tmp()
        let path = dir.appendingPathComponent("claude_desktop_config.json")
        try ClaudeDesktopConfig.merge(
            configURL: path, maughamBinary: "/stable", serverKey: "maugham")
        try ClaudeDesktopConfig.merge(
            configURL: path, maughamBinary: "/dev", serverKey: "maugham-dev")
        try ClaudeDesktopConfig.removeMaughamEntry(configURL: path, serverKey: "maugham-dev")
        let data = try Data(contentsOf: path)
        let dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(dict["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["maugham"])
        XCTAssertNil(servers["maugham-dev"])
    }
```

- [ ] **Step 3: Run tests**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: all tests pass including the five new cases.

- [ ] **Step 4: Commit**

```bash
git add Maugham/MCP/ClaudeDesktopConfig.swift MaughamTests/MCP/SetupClaudeDesktopConfigTests.swift
git commit -m "feat(mcp): variant-aware Claude Desktop config + env socket path"
```

---

## Task 7: MaughamApp.mcpSocketPath uses BuildVariant

**Files:**
- Modify: `Maugham/MaughamApp.swift:12-16`

- [ ] **Step 1: Replace the `mcpSocketPath` computed property**

In `Maugham/MaughamApp.swift`, find:

```swift
    private var mcpSocketPath: String {
        let lib = FileManager.default.urls(
            for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("Application Support/Maugham/mcp.sock").path
    }
```

Replace with:

```swift
    private var mcpSocketPath: String {
        BuildVariant.current.mcpSocketPath
    }
```

- [ ] **Step 2: Run tests**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: all tests pass. (Behavior unchanged for stable: socket path is byte-identical to before.)

- [ ] **Step 3: Commit**

```bash
git add Maugham/MaughamApp.swift
git commit -m "refactor(mcp): socket path via BuildVariant"
```

---

## Task 8: HelpClaudeDesktopSheet — variant-aware JSON snippet

**Files:**
- Modify: `Maugham/Views/HelpClaudeDesktopSheet.swift:160-170`

The Help sheet shows the user a JSON snippet of what gets written to Claude Desktop's config. Make it reflect the actual variant so what's shown matches what's written.

- [ ] **Step 1: Update the snippet**

Find `private var snippetText: String` and replace its body:

```swift
    private var snippetText: String {
        let key = BuildVariant.current.mcpServerKey
        let socket = BuildVariant.current.mcpSocketPath
        return """
        {
          "mcpServers": {
            "\(key)": {
              "command": "\(binaryPath)",
              "env": { "MAUGHAM_MCP_SOCKET": "\(socket)" }
            }
          }
        }
        """
    }
```

- [ ] **Step 2: Run tests and build**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: all tests pass. No new tests for this — it's a string template visible in the Help sheet UI; verified manually by opening Help → Set up Claude Desktop after building.

- [ ] **Step 3: Update the merge() callsite to pass socketPath**

In the same file, find the call to `ClaudeDesktopConfig.merge(...)` (look for `runConfigure()` method). Find the existing call which looks like:

```swift
try ClaudeDesktopConfig.merge(configURL: ..., maughamBinary: binaryPath)
```

Update to pass the socket path explicitly:

```swift
try ClaudeDesktopConfig.merge(
    configURL: ...,
    maughamBinary: binaryPath,
    socketPath: BuildVariant.current.mcpSocketPath)
```

(The `serverKey` parameter defaults to `BuildVariant.current.mcpServerKey` so we don't need to pass it.)

If you find more than one `ClaudeDesktopConfig.merge` callsite, update each.

- [ ] **Step 4: Run tests**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/HelpClaudeDesktopSheet.swift
git commit -m "feat(setup): Help sheet shows variant key + writes socket env"
```

---

## Task 9: WelcomeView + AboutSettingsTab — variant-aware display name

**Files:**
- Modify: `Maugham/Views/WelcomeView.swift:23`
- Modify: `Maugham/Views/SettingsTabs/AboutSettingsTab.swift:12`

- [ ] **Step 1: Update WelcomeView.swift**

Find `Text("Maugham")` near line 23 and replace with `Text(BuildVariant.current.displayName)`.

- [ ] **Step 2: Update AboutSettingsTab.swift**

Find `Text("Maugham")` near line 12 and replace with `Text(BuildVariant.current.displayName)`.

- [ ] **Step 3: Build both configs and run tests**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: all builds and tests pass.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Views/WelcomeView.swift Maugham/Views/SettingsTabs/AboutSettingsTab.swift
git commit -m "feat(ui): Welcome + About show variant display name"
```

---

## Task 10: UpdateState enum

**Files:**
- Create: `Maugham/Updates/UpdateState.swift`

Tiny task: extract the state enum so it can be referenced from multiple files without circular imports.

- [ ] **Step 1: Create the file**

```swift
// Maugham/Updates/UpdateState.swift
import Foundation

/// State of the auto-updater. See production-release spec §3.2.
public enum UpdateState: Equatable {
    case idle
    case checking
    case downloading(version: String, progress: Double)
    case ready(version: String, dmgURL: URL, releaseNotes: String)
    case error(String)
    case upToDate(currentVersion: String)
}
```

- [ ] **Step 2: Build to confirm it compiles**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Maugham/Updates/UpdateState.swift
git commit -m "feat(updates): UpdateState enum"
```

---

## Task 11: GitHub Releases API — model + parser + tests

**Files:**
- Create: `Maugham/Updates/GitHubReleasesAPI.swift`
- Create: `MaughamTests/Updates/GitHubReleasesAPITests.swift`
- Create: `MaughamTests/Fixtures/github-releases-latest.json`

The API call is wrapped in a small async function whose body is testable by injecting a `URLSession`. The fixture is captured from a real call (you can use the v0.2.0 release that will eventually exist; for now construct a representative one).

- [ ] **Step 1: Create the fixture file**

```json
{
  "url": "https://api.github.com/repos/dtrouton/Maugham/releases/123",
  "tag_name": "v0.2.0",
  "name": "Maugham 0.2.0",
  "body": "## What's new\n\n- Banner update flow\n- Manual Check for Updates menu\n\n## Fixes\n\n- nothing yet\n",
  "draft": false,
  "prerelease": false,
  "assets": [
    {
      "name": "Maugham-0.2.0.dmg",
      "browser_download_url": "https://github.com/dtrouton/Maugham/releases/download/v0.2.0/Maugham-0.2.0.dmg",
      "size": 12345678,
      "digest": "sha256:abcd1234"
    }
  ]
}
```

Save at `MaughamTests/Fixtures/github-releases-latest.json`.

(Note: the `digest` field above is illustrative — GitHub's actual API may not include it, in which case SHA256 verification falls back to computing it ourselves. Test the parser to not require it.)

- [ ] **Step 2: Write the failing tests**

```swift
// MaughamTests/Updates/GitHubReleasesAPITests.swift
import XCTest
@testable import Maugham

final class GitHubReleasesAPITests: XCTestCase {
    private func fixtureData(name: String) throws -> Data {
        let url = Bundle(for: type(of: self)).url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle(for: type(of: self)).url(forResource: name, withExtension: "json")
        return try Data(contentsOf: try XCTUnwrap(url, "Fixture \(name).json not found"))
    }

    func test_parseValidResponse() throws {
        let data = try fixtureData(name: "github-releases-latest")
        let release = try GitHubRelease.decode(from: data)
        XCTAssertEqual(release.tagName, "v0.2.0")
        XCTAssertEqual(release.semanticVersion, SemanticVersion("0.2.0"))
        XCTAssertEqual(release.dmgAsset?.name, "Maugham-0.2.0.dmg")
        XCTAssertEqual(release.dmgAsset?.size, 12345678)
        XCTAssertTrue(release.body.contains("What's new"))
    }

    func test_parseResponseWithNoDmgAsset() throws {
        let json = """
        {"tag_name":"v0.3.0","name":"x","body":"x","draft":false,"prerelease":false,
         "assets":[{"name":"Maugham-0.3.0-src.zip","browser_download_url":"x","size":1}]}
        """
        let release = try GitHubRelease.decode(from: Data(json.utf8))
        XCTAssertNil(release.dmgAsset, ".dmg asset must be filtered")
    }

    func test_parseRejectsMalformed() {
        let json = "{}"
        XCTAssertThrowsError(try GitHubRelease.decode(from: Data(json.utf8)))
    }
}
```

- [ ] **Step 3: Run tests, expect failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: build fails with "cannot find GitHubRelease in scope".

- [ ] **Step 4: Implement the API module**

```swift
// Maugham/Updates/GitHubReleasesAPI.swift
import Foundation

public struct GitHubRelease: Decodable {
    public struct Asset: Decodable {
        public let name: String
        public let browserDownloadURL: URL
        public let size: Int

        private enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }

    public let tagName: String
    public let name: String
    public let body: String
    public let assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, assets
    }

    public var semanticVersion: SemanticVersion? {
        SemanticVersion(tagName)
    }

    public var dmgAsset: Asset? {
        assets.first { $0.name.hasSuffix(".dmg") }
    }

    public static func decode(from data: Data) throws -> GitHubRelease {
        try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}

public enum GitHubReleasesAPI {
    public enum Error: Swift.Error, LocalizedError {
        case http(status: Int)
        case noDmgAsset
        case unparseable

        public var errorDescription: String? {
            switch self {
            case .http(let s): return "GitHub returned HTTP \(s)"
            case .noDmgAsset: return "Release is missing the .dmg asset"
            case .unparseable: return "Couldn't parse GitHub's response"
            }
        }
    }

    public static func fetchLatestRelease(
        owner: String = "dtrouton",
        repo: String = "Maugham",
        session: URLSession = .shared
    ) async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Error.http(status: http.statusCode)
        }
        do {
            return try GitHubRelease.decode(from: data)
        } catch {
            throw Error.unparseable
        }
    }
}
```

- [ ] **Step 5: Update project.yml to include the test fixture**

Verify `MaughamTests/Fixtures/` is already declared in the test target's `resources` in `project.yml`. It is — `MaughamTests` target already has `resources: [path: MaughamTests/Fixtures]`. No change needed; just regenerate to pick up the new file:

```bash
./gen.sh
```

- [ ] **Step 6: Run tests**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: GitHubReleasesAPITests pass (3 cases).

- [ ] **Step 7: Commit**

```bash
git add Maugham/Updates/GitHubReleasesAPI.swift \
        MaughamTests/Updates/GitHubReleasesAPITests.swift \
        MaughamTests/Fixtures/github-releases-latest.json
git commit -m "feat(updates): GitHub Releases API client + fixture"
```

---

## Task 12: UpdateChecker — state machine, no network yet

**Files:**
- Create: `Maugham/Updates/UpdateChecker.swift`
- Create: `MaughamTests/Updates/UpdateCheckerTests.swift`

Build the checker with the network call injected. Two ways to call: `performCheck(trigger:)` where trigger is `.background` or `.manual`. The trigger drives the silent-vs-vocal asymmetry. Tests substitute the fetch closure to control responses.

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/Updates/UpdateCheckerTests.swift
import XCTest
@testable import Maugham

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private func makeChecker(
        currentVersion: String = "0.1.0",
        fetch: @escaping () async throws -> GitHubRelease,
        download: @escaping (URL, String) async throws -> URL = { _, _ in
            URL(fileURLWithPath: "/tmp/fake.dmg")
        }
    ) -> UpdateChecker {
        UpdateChecker(
            currentVersionString: currentVersion,
            fetchLatest: fetch,
            downloadDMG: download)
    }

    private func release(version: String, body: String = "notes") -> GitHubRelease {
        let json = """
        {"tag_name":"v\(version)","name":"x","body":"\(body)","draft":false,"prerelease":false,
         "assets":[{"name":"Maugham-\(version).dmg",
                    "browser_download_url":"https://example/Maugham-\(version).dmg",
                    "size":100}]}
        """
        return try! GitHubRelease.decode(from: Data(json.utf8))
    }

    func test_idleToUpToDate_whenNoNewerVersion() async {
        let checker = makeChecker(currentVersion: "0.2.0", fetch: { self.release(version: "0.2.0") })
        await checker.performCheck(trigger: .manual)
        XCTAssertEqual(checker.state, .upToDate(currentVersion: "0.2.0"))
    }

    func test_idleToReady_whenNewerVersionAvailable() async {
        let checker = makeChecker(
            currentVersion: "0.1.0",
            fetch: { self.release(version: "0.2.0") },
            download: { url, _ in URL(fileURLWithPath: "/tmp/Maugham-0.2.0.dmg") })
        await checker.performCheck(trigger: .manual)
        if case .ready(let v, _, _) = checker.state {
            XCTAssertEqual(v, "0.2.0")
        } else {
            XCTFail("Expected .ready, got \(checker.state)")
        }
    }

    func test_backgroundFailureRevertsToIdle() async {
        struct E: Error {}
        let checker = makeChecker(fetch: { throw E() })
        await checker.performCheck(trigger: .background)
        XCTAssertEqual(checker.state, .idle)
    }

    func test_manualFailureSurfacesError() async {
        struct E: Error, LocalizedError {
            var errorDescription: String? { "synthetic" }
        }
        let checker = makeChecker(fetch: { throw E() })
        await checker.performCheck(trigger: .manual)
        if case .error(let msg) = checker.state {
            XCTAssertEqual(msg, "synthetic")
        } else {
            XCTFail("Expected .error, got \(checker.state)")
        }
    }

    func test_skipsDownloadIfDevPlaceholderVersion() async {
        // 0.0.0-dev means we're running a local dev build; checker shouldn't
        // claim "you're up to date" with a fake version. Instead surface idle.
        let checker = makeChecker(
            currentVersion: "0.0.0-dev",
            fetch: { self.release(version: "0.2.0") })
        await checker.performCheck(trigger: .background)
        XCTAssertEqual(checker.state, .idle)
    }
}
```

- [ ] **Step 2: Run tests, expect failure**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: build fails with "cannot find UpdateChecker in scope".

- [ ] **Step 3: Implement UpdateChecker**

```swift
// Maugham/Updates/UpdateChecker.swift
import Foundation
import SwiftUI

/// Tier 1.5 updater. Polls GitHub Releases; downloads newer `.dmg` silently;
/// surfaces via @Published state. See spec §3.2.
@MainActor
public final class UpdateChecker: ObservableObject {
    public enum Trigger {
        case background
        case manual
    }

    @Published public private(set) var state: UpdateState = .idle

    public static let shared: UpdateChecker = UpdateChecker(
        currentVersionString: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev",
        fetchLatest: { try await GitHubReleasesAPI.fetchLatestRelease() },
        downloadDMG: UpdateChecker.defaultDownload)

    private let currentVersionString: String
    private let fetchLatest: () async throws -> GitHubRelease
    private let downloadDMG: (URL, String) async throws -> URL

    public init(
        currentVersionString: String,
        fetchLatest: @escaping () async throws -> GitHubRelease,
        downloadDMG: @escaping (URL, String) async throws -> URL
    ) {
        self.currentVersionString = currentVersionString
        self.fetchLatest = fetchLatest
        self.downloadDMG = downloadDMG
    }

    /// Single check + (if needed) download. Trigger drives error visibility.
    public func performCheck(trigger: Trigger) async {
        // Dev placeholder: don't try to "update" a local build to anything.
        guard SemanticVersion(currentVersionString) != nil else {
            state = .idle
            return
        }
        state = .checking
        do {
            let release = try await fetchLatest()
            guard let newVersion = release.semanticVersion,
                  let currentVersion = SemanticVersion(currentVersionString) else {
                state = trigger == .manual
                    ? .error("Couldn't parse version from release")
                    : .idle
                return
            }
            guard newVersion > currentVersion else {
                state = .upToDate(currentVersion: currentVersionString)
                return
            }
            guard let asset = release.dmgAsset else {
                state = trigger == .manual
                    ? .error(GitHubReleasesAPI.Error.noDmgAsset.localizedDescription)
                    : .idle
                return
            }
            state = .downloading(version: newVersion.string, progress: 0)
            let dmgURL = try await downloadDMG(asset.browserDownloadURL, newVersion.string)
            state = .ready(version: newVersion.string, dmgURL: dmgURL, releaseNotes: release.body)
        } catch {
            state = trigger == .manual
                ? .error(error.localizedDescription)
                : .idle
        }
    }

    /// Default download implementation: URLSession download task into the
    /// updates staging directory under Application Support.
    private static func defaultDownload(from url: URL, version: String) async throws -> URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let stagingDir = lib
            .appendingPathComponent("Application Support")
            .appendingPathComponent(BuildVariant.current.supportFolderName)
            .appendingPathComponent("Updates")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let target = stagingDir.appendingPathComponent("Maugham-\(version).dmg")
        if FileManager.default.fileExists(atPath: target.path) { return target }

        let (tmpURL, _) = try await URLSession.shared.download(from: url)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: tmpURL, to: target)
        return target
    }
}
```

- [ ] **Step 4: Run tests**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: UpdateCheckerTests pass (5 cases).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Updates/UpdateChecker.swift MaughamTests/Updates/UpdateCheckerTests.swift
git commit -m "feat(updates): UpdateChecker state machine"
```

---

## Task 13: Background poll lifecycle

**Files:**
- Modify: `Maugham/Updates/UpdateChecker.swift`

Add the actual scheduler — start one Task that does the initial 60s-delayed check, then 24h intervals. Persist last-check timestamp via `@AppStorage`.

- [ ] **Step 1: Extend `UpdateChecker` with the background loop**

Append these properties and methods to `UpdateChecker`:

```swift
    private var backgroundTask: Task<Void, Never>?
    private static let initialDelaySeconds: UInt64 = 60
    private static let intervalSeconds: UInt64 = 24 * 60 * 60

    /// Start the background poll loop. Idempotent — calling more than once
    /// is a no-op. Only starts when the current build variant has updater
    /// enabled.
    public func startBackgroundLoop() {
        guard BuildVariant.current.updaterEnabled else { return }
        guard backgroundTask == nil else { return }
        backgroundTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.initialDelaySeconds * 1_000_000_000)
            while !Task.isCancelled {
                await self?.performCheck(trigger: .background)
                try? await Task.sleep(nanoseconds: Self.intervalSeconds * 1_000_000_000)
            }
        }
    }

    /// Force a check now (e.g. from the menu item). Bypasses the 24h gate.
    public func checkNow() async {
        await performCheck(trigger: .manual)
    }
```

- [ ] **Step 2: Build to confirm it compiles**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: build succeeds.

- [ ] **Step 3: Run tests**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: all existing tests pass. We're not adding new tests for the scheduler — the 60-second initial delay would make tests slow, and the test value of "verifying Task.sleep behaves" is low. The behavior is exercised by Task 23 (cutting v0.2.0).

- [ ] **Step 4: Commit**

```bash
git add Maugham/Updates/UpdateChecker.swift
git commit -m "feat(updates): background poll loop (60s + 24h cadence)"
```

---

## Task 14: UpdateSheet view

**Files:**
- Create: `Maugham/Updates/UpdateSheet.swift`
- Create: `MaughamTests/Updates/UpdateSheetIntegrationTests.swift`

The sheet observes `UpdateChecker.state` and renders one of six states.

- [ ] **Step 1: Write the failing integration tests**

```swift
// MaughamTests/Updates/UpdateSheetIntegrationTests.swift
import XCTest
import SwiftUI
@testable import Maugham

@MainActor
final class UpdateSheetIntegrationTests: XCTestCase {
    func test_titleForIdle() {
        XCTAssertEqual(UpdateSheet.title(for: .idle), "Check for Updates")
    }

    func test_titleForChecking() {
        XCTAssertEqual(UpdateSheet.title(for: .checking), "Checking for Updates…")
    }

    func test_titleForDownloading() {
        XCTAssertEqual(
            UpdateSheet.title(for: .downloading(version: "0.2.0", progress: 0.5)),
            "Downloading Maugham 0.2.0…")
    }

    func test_titleForReady() {
        XCTAssertEqual(
            UpdateSheet.title(for: .ready(
                version: "0.2.0",
                dmgURL: URL(fileURLWithPath: "/x"),
                releaseNotes: "notes")),
            "Maugham 0.2.0 is Ready to Install")
    }

    func test_titleForError() {
        XCTAssertEqual(
            UpdateSheet.title(for: .error("boom")),
            "Couldn't Check for Updates")
    }

    func test_titleForUpToDate() {
        XCTAssertEqual(
            UpdateSheet.title(for: .upToDate(currentVersion: "0.1.0")),
            "Maugham 0.1.0 is Up to Date")
    }
}
```

- [ ] **Step 2: Run tests, expect failure**

Expected: "cannot find UpdateSheet in scope".

- [ ] **Step 3: Implement UpdateSheet**

```swift
// Maugham/Updates/UpdateSheet.swift
import SwiftUI
import AppKit

public struct UpdateSheet: View {
    @ObservedObject var checker: UpdateChecker
    let dismiss: () -> Void

    public init(checker: UpdateChecker = .shared, dismiss: @escaping () -> Void) {
        self.checker = checker
        self.dismiss = dismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Self.title(for: checker.state))
                .font(.headline)

            content
                .frame(minWidth: 380)

            HStack {
                Spacer()
                buttons
            }
        }
        .padding(24)
        .frame(maxWidth: 480)
        .task {
            if case .idle = checker.state {
                await checker.checkNow()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch checker.state {
        case .idle, .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Contacting GitHub…")
            }
        case .downloading(_, let progress):
            ProgressView(value: progress).progressViewStyle(.linear)
        case .ready(_, _, let notes):
            ScrollView {
                Text(notes)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
        case .error(let msg):
            Text(msg).foregroundColor(.secondary)
        case .upToDate:
            Text("You're running the latest version.")
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch checker.state {
        case .idle, .checking, .downloading:
            Button("Close", action: dismiss)
        case .ready(_, let dmg, _):
            Button("Later", action: dismiss)
            Button("Install") {
                NSWorkspace.shared.activateFileViewerSelecting([dmg])
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        case .error:
            Button("Close", action: dismiss)
            Button("Retry") {
                Task { await checker.checkNow() }
            }
            .keyboardShortcut(.defaultAction)
        case .upToDate:
            Button("Done", action: dismiss)
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Title for a given state. Exposed as a static for testability.
    public static func title(for state: UpdateState) -> String {
        switch state {
        case .idle: return "Check for Updates"
        case .checking: return "Checking for Updates…"
        case .downloading(let v, _): return "Downloading Maugham \(v)…"
        case .ready(let v, _, _): return "Maugham \(v) is Ready to Install"
        case .error: return "Couldn't Check for Updates"
        case .upToDate(let v): return "Maugham \(v) is Up to Date"
        }
    }
}
```

- [ ] **Step 4: Run tests**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: UpdateSheetIntegrationTests pass (6 cases).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Updates/UpdateSheet.swift MaughamTests/Updates/UpdateSheetIntegrationTests.swift
git commit -m "feat(updates): UpdateSheet view"
```

---

## Task 15: UpdateBannerView

**Files:**
- Create: `Maugham/Updates/UpdateBannerView.swift`
- Create: `MaughamTests/Updates/UpdateBannerIntegrationTests.swift`

A thin banner with Install + Later. The "Later" action persists the version into `@AppStorage` so dismissed versions stay dismissed.

- [ ] **Step 1: Write the failing tests**

```swift
// MaughamTests/Updates/UpdateBannerIntegrationTests.swift
import XCTest
@testable import Maugham

@MainActor
final class UpdateBannerIntegrationTests: XCTestCase {
    func test_shouldShowReturnsFalseForIdle() {
        XCTAssertFalse(UpdateBannerView.shouldShow(state: .idle, dismissed: []))
    }

    func test_shouldShowReturnsFalseForDownloading() {
        XCTAssertFalse(UpdateBannerView.shouldShow(
            state: .downloading(version: "0.2.0", progress: 0.3), dismissed: []))
    }

    func test_shouldShowReturnsTrueForReadyNotDismissed() {
        XCTAssertTrue(UpdateBannerView.shouldShow(
            state: .ready(version: "0.2.0", dmgURL: URL(fileURLWithPath: "/x"), releaseNotes: ""),
            dismissed: []))
    }

    func test_shouldShowReturnsFalseForReadyDismissed() {
        XCTAssertFalse(UpdateBannerView.shouldShow(
            state: .ready(version: "0.2.0", dmgURL: URL(fileURLWithPath: "/x"), releaseNotes: ""),
            dismissed: ["0.2.0"]))
    }

    func test_shouldShowReturnsTrueForReadyNewerThanDismissed() {
        XCTAssertTrue(UpdateBannerView.shouldShow(
            state: .ready(version: "0.2.1", dmgURL: URL(fileURLWithPath: "/x"), releaseNotes: ""),
            dismissed: ["0.2.0"]))
    }
}
```

- [ ] **Step 2: Run tests, expect failure**

Expected: "cannot find UpdateBannerView in scope".

- [ ] **Step 3: Implement UpdateBannerView**

```swift
// Maugham/Updates/UpdateBannerView.swift
import SwiftUI
import AppKit

public struct UpdateBannerView: View {
    @ObservedObject var checker: UpdateChecker
    @AppStorage("UpdateBanner.dismissedVersions") private var dismissedCSV: String = ""

    public init(checker: UpdateChecker = .shared) {
        self.checker = checker
    }

    public var body: some View {
        if case .ready(let v, let dmg, _) = checker.state,
           Self.shouldShow(state: checker.state, dismissed: dismissedSet) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.accentColor)
                Text("Maugham \(v) is ready to install")
                    .font(.callout)
                Spacer()
                Button("Later") { dismiss(version: v) }
                    .buttonStyle(.borderless)
                Button("Install") {
                    NSWorkspace.shared.activateFileViewerSelecting([dmg])
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
            .overlay(Divider(), alignment: .bottom)
        }
    }

    private var dismissedSet: Set<String> {
        Set(dismissedCSV.split(separator: ",").map(String.init))
    }

    private func dismiss(version: String) {
        var s = dismissedSet
        s.insert(version)
        dismissedCSV = s.sorted().joined(separator: ",")
    }

    /// Pure decision function for testability. Banner shows iff state is
    /// `.ready` and the version hasn't been dismissed.
    public static func shouldShow(state: UpdateState, dismissed: Set<String>) -> Bool {
        if case .ready(let v, _, _) = state, !dismissed.contains(v) { return true }
        return false
    }
}
```

- [ ] **Step 4: Run tests**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: UpdateBannerIntegrationTests pass (5 cases).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Updates/UpdateBannerView.swift MaughamTests/Updates/UpdateBannerIntegrationTests.swift
git commit -m "feat(updates): banner view with per-version dismiss"
```

---

## Task 16: UpdateMenuCommand — state-derived title

**Files:**
- Create: `Maugham/Updates/UpdateMenuCommand.swift`

- [ ] **Step 1: Implement the command**

```swift
// Maugham/Updates/UpdateMenuCommand.swift
import SwiftUI

public struct UpdateMenuCommand: Commands {
    @ObservedObject var checker: UpdateChecker
    @State private var sheetPresented = false

    public init(checker: UpdateChecker = .shared) {
        self.checker = checker
    }

    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            if BuildVariant.current.updaterEnabled {
                Button(Self.menuTitle(for: checker.state)) {
                    sheetPresented = true
                }
                .sheet(isPresented: $sheetPresented) {
                    UpdateSheet(checker: checker, dismiss: { sheetPresented = false })
                }
            }
        }
    }

    /// Menu item title for a given state. Exposed as static for reuse + testing.
    public static func menuTitle(for state: UpdateState) -> String {
        switch state {
        case .idle, .upToDate, .error: return "Check for Updates…"
        case .checking: return "Checking for Updates…"
        case .downloading: return "Downloading Update…"
        case .ready: return "Install Update…"
        }
    }
}
```

- [ ] **Step 2: Add tests for `menuTitle`**

Append to `MaughamTests/Updates/UpdateSheetIntegrationTests.swift` (or create `UpdateMenuCommandTests.swift` if you prefer one-file-per-source):

```swift
@MainActor
final class UpdateMenuCommandTests: XCTestCase {
    func test_menuTitle_idle()        { XCTAssertEqual(UpdateMenuCommand.menuTitle(for: .idle), "Check for Updates…") }
    func test_menuTitle_checking()    { XCTAssertEqual(UpdateMenuCommand.menuTitle(for: .checking), "Checking for Updates…") }
    func test_menuTitle_downloading() {
        XCTAssertEqual(
            UpdateMenuCommand.menuTitle(for: .downloading(version: "0.2.0", progress: 0.5)),
            "Downloading Update…")
    }
    func test_menuTitle_ready() {
        XCTAssertEqual(
            UpdateMenuCommand.menuTitle(for: .ready(version: "0.2.0",
                                                    dmgURL: URL(fileURLWithPath: "/x"),
                                                    releaseNotes: "")),
            "Install Update…")
    }
    func test_menuTitle_error() {
        XCTAssertEqual(UpdateMenuCommand.menuTitle(for: .error("x")), "Check for Updates…")
    }
    func test_menuTitle_upToDate() {
        XCTAssertEqual(UpdateMenuCommand.menuTitle(for: .upToDate(currentVersion: "0.1.0")),
                       "Check for Updates…")
    }
}
```

- [ ] **Step 3: Run tests**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Maugham/Updates/UpdateMenuCommand.swift MaughamTests/Updates/UpdateSheetIntegrationTests.swift
git commit -m "feat(updates): state-derived menu command"
```

---

## Task 17: Wire updater into MaughamApp + ProjectWindow

**Files:**
- Modify: `Maugham/MaughamApp.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`

- [ ] **Step 1: Start the background loop and add the menu command**

In `Maugham/MaughamApp.swift`:

Add to `body: some Scene`'s top-level `Window` (the welcome window) `.task { ... }` block, right after the MCPServer.start() call:

```swift
                    UpdateChecker.shared.startBackgroundLoop()
```

Then find the existing `.commands { ... }` modifier (or add one to the welcome `Window`). Add:

```swift
        .commands {
            UpdateMenuCommand()
            // ... existing commands ...
        }
```

If a `.commands` modifier doesn't yet exist on the welcome `Window`, add one. Place it after the `Window("Maugham — Welcome", id: "welcome") { ... }` closing brace's modifiers.

- [ ] **Step 2: Mount the banner on ProjectWindow**

In `Maugham/Views/ProjectWindow.swift`, find the root view body (top-level container — typically an `HSplitView` or `NavigationSplitView`). Wrap with `.safeAreaInset(edge: .top)`:

```swift
        // Existing body...
        .safeAreaInset(edge: .top, spacing: 0) {
            UpdateBannerView()
        }
```

Note: `.safeAreaInset` only renders the content when its body emits non-empty content. Since `UpdateBannerView.body` returns nothing when state is not `.ready`, the inset is a no-op in the common case.

- [ ] **Step 3: Build both configs and run tests**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: builds succeed, all tests pass.

- [ ] **Step 4: Manual smoke check**

Open `Maugham.xcodeproj`, ⌘R to launch (Debug). Confirm:
- App launches with title "Maugham Dev" in WelcomeView.
- About → settings shows "Maugham Dev".
- App menu does **not** contain "Check for Updates…" (because dev's updater is disabled).
- (Optional, harder to verify): build a Release version and confirm the menu item *does* appear.

- [ ] **Step 5: Commit**

```bash
git add Maugham/MaughamApp.swift Maugham/Views/ProjectWindow.swift
git commit -m "feat(updates): wire UpdateChecker, banner, and menu command"
```

---

## Task 18: Release notes scaffolding

**Files:**
- Create: `docs/release-notes/_template.md`
- Create: `docs/release-notes/v0.2.0.md`

- [ ] **Step 1: Create the template**

```markdown
# Maugham 0.X.Y

_Released YYYY-MM-DD_

## What's new
-

## Fixes
-

## Known issues
-
```

Save at `docs/release-notes/_template.md`.

- [ ] **Step 2: Create v0.2.0 notes (will exercise the pipeline)**

```markdown
# Maugham 0.2.0

_Released 2026-05-XX_

## What's new

- **First installable release.** Maugham now ships as a downloadable `.dmg`. Drag to `/Applications`, right-click → Open the first time to get past Gatekeeper.
- **Auto-update from the menu bar.** Maugham → Check for Updates… polls GitHub Releases and silently downloads new versions in the background. When one is ready, a banner appears across the top of any open project window. Click Install to reveal the `.dmg` in Finder.
- **Dev/stable side-by-side.** A separate "Maugham Dev" app built from Xcode lives at `com.maugham.Maugham.dev` and shares no state with stable. Each has its own Claude Desktop MCP entry (`maugham` vs `maugham-dev`) so they coexist without stepping on each other.

## Fixes

- Nothing — this is the foundation release.

## Known issues

- First open of each downloaded `.dmg` requires right-click → Open in Privacy & Security. Will go away when we flip to signed + notarized builds.
```

Save at `docs/release-notes/v0.2.0.md`.

- [ ] **Step 3: Commit**

```bash
git add docs/release-notes/_template.md docs/release-notes/v0.2.0.md
git commit -m "docs: release-notes template + v0.2.0 notes"
```

---

## Task 19: cut-release.sh helper

**Files:**
- Create: `scripts/cut-release.sh`

- [ ] **Step 1: Create scripts dir and the helper**

```bash
mkdir -p scripts
```

Save the following to `scripts/cut-release.sh`:

```bash
#!/usr/bin/env bash
# Pre-flight checks for cutting a stable Maugham release.
#
# Usage:
#   ./scripts/cut-release.sh 0.X.Y                 # full pre-flight + tag
#   ./scripts/cut-release.sh 0.X.Y --skip-tests    # skip the test run
#
# Creates the tag locally on success and prints the push command.
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <version> [--skip-tests]"
    exit 1
fi

VERSION="$1"
SKIP_TESTS="${2:-}"

# Validate version shape.
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: version must be X.Y.Z (got: $VERSION)"
    exit 1
fi

NOTES="docs/release-notes/v${VERSION}.md"

# 1. Release notes must exist.
if [[ ! -f "$NOTES" ]]; then
    echo "ERROR: release notes missing at $NOTES"
    echo "       (cp docs/release-notes/_template.md $NOTES, then edit it)"
    exit 1
fi

# 2. Must be on main.
BRANCH=$(git symbolic-ref --short HEAD)
if [[ "$BRANCH" != "main" ]]; then
    echo "ERROR: not on main (current branch: $BRANCH)"
    exit 1
fi

# 3. Working tree clean.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: working tree dirty"
    git status --short
    exit 1
fi

# 4. Tag must not already exist.
if git rev-parse "v${VERSION}" >/dev/null 2>&1; then
    echo "ERROR: tag v${VERSION} already exists"
    exit 1
fi

# 5. Tests pass.
if [[ "$SKIP_TESTS" != "--skip-tests" ]]; then
    echo "Running tests…"
    ./gen.sh
    xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
        2>&1 | tail -20
    echo "Tests passed."
fi

# 6. Create tag (annotated).
git tag -a "v${VERSION}" -m "Maugham ${VERSION}"

cat <<EOF

Tag v${VERSION} created locally. To trigger the release workflow:

    git push origin v${VERSION}

EOF
```

Make it executable:

```bash
chmod +x scripts/cut-release.sh
```

- [ ] **Step 2: Smoke-test the script's failure modes**

Run the script with no arguments to confirm it prints the usage message and exits with a non-zero status:

```bash
./scripts/cut-release.sh && echo "should not print" || echo "exit code: $?"
```
Expected: prints the usage message, then "exit code: 1".

Run with a malformed version:

```bash
./scripts/cut-release.sh banana && echo "should not print" || echo "exit code: $?"
```
Expected: prints "ERROR: version must be X.Y.Z", then "exit code: 1".

Run with a version whose notes file doesn't exist (e.g. 9.9.9):

```bash
./scripts/cut-release.sh 9.9.9 && echo "should not print" || echo "exit code: $?"
```
Expected: prints "ERROR: release notes missing at docs/release-notes/v9.9.9.md", then "exit code: 1".

Do NOT actually run it with `0.2.0` yet — we want to defer the real tag until Task 23 (after CI is in place).

- [ ] **Step 3: Commit**

```bash
git add scripts/cut-release.sh
git commit -m "scripts: cut-release.sh helper with pre-flight checks"
```

---

## Task 20: GitHub Actions release workflow

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Create the workflows directory and file**

```bash
mkdir -p .github/workflows
```

Save to `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags:
      - 'v[0-9]+.[0-9]+.[0-9]+'

permissions:
  contents: write

jobs:
  release:
    runs-on: macos-14
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Xcode
        uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: '15.4'

      - name: Install xcodegen
        run: brew install xcodegen

      - name: Extract version from tag
        id: ver
        run: echo "version=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"

      - name: Verify release notes exist
        run: |
          NOTES="docs/release-notes/v${{ steps.ver.outputs.version }}.md"
          if [[ ! -f "$NOTES" ]]; then
            echo "::error::Missing $NOTES"
            exit 1
          fi
          echo "Release notes: $NOTES"

      - name: Sync version into project.yml
        run: |
          VERSION="${{ steps.ver.outputs.version }}"
          BUILD="${{ github.run_number }}"
          # Use sed for the two version fields. macOS sed needs -i ''.
          sed -i '' \
            "s/CFBundleShortVersionString: \"0.0.0-dev\"/CFBundleShortVersionString: \"${VERSION}\"/" \
            project.yml
          sed -i '' \
            "s/CFBundleVersion: \"1\"/CFBundleVersion: \"${BUILD}\"/" \
            project.yml
          grep -E "CFBundleShortVersionString|CFBundleVersion" project.yml

      - name: Generate project
        run: ./gen.sh

      - name: Build (Release)
        run: |
          xcodebuild -project Maugham.xcodeproj -scheme Maugham \
            -configuration Release build CODE_SIGNING_ALLOWED=NO \
            | xcbeautify || true
          # xcbeautify is optional; if not present the raw output is fine.

      - name: Test
        run: |
          xcodebuild -project Maugham.xcodeproj -scheme Maugham \
            -configuration Release test CODE_SIGNING_ALLOWED=NO \
            -resultBundlePath TestResults.xcresult

      - name: Locate built app
        id: locate
        run: |
          APP_PATH=$(xcodebuild -project Maugham.xcodeproj -scheme Maugham \
            -configuration Release -showBuildSettings 2>/dev/null \
            | awk -F'= ' '/^[[:space:]]*BUILT_PRODUCTS_DIR/ { print $2 }' \
            | head -1)/Maugham.app
          echo "Located: $APP_PATH"
          test -d "$APP_PATH" || { echo "::error::App not found at $APP_PATH"; exit 1; }
          echo "app_path=$APP_PATH" >> "$GITHUB_OUTPUT"

      - name: Package .dmg
        run: |
          VERSION="${{ steps.ver.outputs.version }}"
          mkdir -p /tmp/dmg-root
          cp -R "${{ steps.locate.outputs.app_path }}" /tmp/dmg-root/
          ln -s /Applications /tmp/dmg-root/Applications
          hdiutil create -volname Maugham -srcfolder /tmp/dmg-root -ov -format UDZO \
            "Maugham-${VERSION}.dmg"
          ls -lh "Maugham-${VERSION}.dmg"

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          files: Maugham-${{ steps.ver.outputs.version }}.dmg
          body_path: docs/release-notes/v${{ steps.ver.outputs.version }}.md
          name: Maugham ${{ steps.ver.outputs.version }}
          tag_name: ${{ github.ref_name }}
          draft: false
          prerelease: false
```

- [ ] **Step 2: Validate YAML locally if possible**

GitHub Actions doesn't have an official local validator. If you have `actionlint` installed:

```bash
actionlint .github/workflows/release.yml
```

If you don't have actionlint, skip — the first push to a tag will surface any errors.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: tag-triggered release workflow (.dmg + GitHub Release)"
```

---

## Task 21: README install section

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Insert an "Install" section above "Build"**

Find the line `## Build` in `README.md` and insert this block above it:

```markdown
## Install

Latest release: <https://github.com/dtrouton/Maugham/releases/latest>

Download the `.dmg`, drag `Maugham.app` to `/Applications`, then **right-click → Open** the first time you launch — Maugham is currently unsigned, so Gatekeeper warns about an unidentified developer. After the first open, subsequent launches work normally.

Maugham checks for updates daily in the background and shows a banner across the top of any project window when one is ready. Force a check from the **Maugham → Check for Updates…** menu.

Dev builds from Xcode coexist with the installed stable copy under the name **Maugham Dev** (bundle id `com.maugham.Maugham.dev`); they don't share state or update settings.

```

- [ ] **Step 2: Build/test sanity check (no behavior change)**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: tests pass.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(readme): add install section"
```

---

## Task 22: CLAUDE.md — Releases section + tripwire #13

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Insert the Releases section**

Find the existing `## Architectural tripwires` heading in `CLAUDE.md`. Immediately *above* that heading, insert the following block:

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

- [ ] **Step 2: Append tripwire #13 to the Architectural Tripwires list**

Find the existing tripwire list (numbered 1–12). After tripwire #12, append:

```markdown
13. **Don't hardcode "maugham", "Maugham", or socket paths.** Six values vary by `BuildVariant`: bundle id, display name, support folder name, MCP socket path, Claude Desktop config key, and MCP `serverInfo.name`. If you add a seventh, route it through `BuildVariant.current` instead. Compile-time check: `grep -n '"maugham"\|"Maugham"' Maugham/` should return zero matches outside `Maugham/BuildVariant.swift` and tests.
```

- [ ] **Step 3: Add three entries to "Questions you do not need to ask"**

Find the existing `## Questions you do not need to ask` section. Append these three bullets to the list:

```markdown
- "How do I cut a release?" → see the Releases section above.
- "Should I bump version in `project.yml`?" → No. The git tag is the source of truth; CI writes the version into the bundle at build time.
- "Should dev or stable do X?" → see `Maugham/BuildVariant.swift` — one enum, all the seams hang off it.
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude.md): Releases section + tripwire #13 + no-need-to-ask additions"
```

---

## Task 23: Cut v0.2.0 — pipeline self-test

This is the moment-of-truth task. It does the first real end-to-end exercise of the pipeline. Treat it as a smoke test of everything built in Tasks 1–22.

**Files:**
- No new files created. Confirms the existing system works end-to-end.

- [ ] **Step 1: Confirm pre-flight state**

```bash
git status                           # clean
git log --oneline -5                 # all 22 prior tasks committed
git symbolic-ref --short HEAD        # main
ls docs/release-notes/v0.2.0.md      # exists
ls scripts/cut-release.sh            # exists, executable
ls .github/workflows/release.yml     # exists
```

- [ ] **Step 2: Update the release notes date**

Edit `docs/release-notes/v0.2.0.md` and replace `_Released 2026-05-XX_` with today's actual date (e.g. `_Released 2026-05-22_`).

```bash
git add docs/release-notes/v0.2.0.md
git commit -m "docs: set v0.2.0 release date"
```

- [ ] **Step 3: Run the cut-release script**

```bash
./scripts/cut-release.sh 0.2.0
```
Expected: pre-flight checks pass, tests pass, tag `v0.2.0` created locally. Script prints the `git push origin v0.2.0` line.

- [ ] **Step 4: Push the tag**

```bash
git push origin v0.2.0
```
Expected: tag pushed; the release workflow starts on GitHub.

- [ ] **Step 5: Watch the workflow**

```bash
gh run watch  # if gh CLI is installed and authenticated
# or visit https://github.com/dtrouton/Maugham/actions
```
Expected: every step succeeds. Total time ~10 minutes.

- [ ] **Step 6: Verify the GitHub Release**

```bash
gh release view v0.2.0  # if gh available
# or visit https://github.com/dtrouton/Maugham/releases/tag/v0.2.0
```
Expected:
- Release exists titled "Maugham 0.2.0".
- Body matches `docs/release-notes/v0.2.0.md`.
- Attached asset: `Maugham-0.2.0.dmg` (~10–30 MB).

- [ ] **Step 7: Manual install smoke test**

1. Download the `.dmg` from the release page.
2. Double-click to mount.
3. Drag `Maugham.app` to `/Applications`.
4. Right-click `/Applications/Maugham.app` → Open. Click "Open" in the Gatekeeper dialog.
5. Confirm the app launches, shows "Maugham" (not "Maugham Dev") in WelcomeView.
6. Open Maugham menu in the menu bar — confirm "Check for Updates…" appears.
7. Click it. The sheet should open, briefly show "Checking for Updates…", then transition to "Maugham 0.2.0 is Up to Date" (since you just installed the latest).

- [ ] **Step 8: Confirm dev/stable coexistence**

1. Keep the just-installed `/Applications/Maugham.app` open.
2. In Xcode, ⌘R to launch the Debug (dev) build.
3. The dev build should open as a separate app titled "Maugham Dev".
4. In the dev build's Maugham menu, confirm "Check for Updates…" is **absent** (`BuildVariant.dev.updaterEnabled` is false).
5. Both apps run side-by-side with separate Recents, settings, etc.

- [ ] **Step 9: Confirm Claude Desktop coexistence**

1. In stable Maugham: Help → Set up Claude Desktop… → Configure. Restart Claude Desktop.
2. In dev Maugham: Help → Set up Claude Desktop… → Configure. Restart Claude Desktop.
3. `cat "$HOME/Library/Application Support/Claude/claude_desktop_config.json"` and confirm both `maugham` and `maugham-dev` entries exist with their respective `env.MAUGHAM_MCP_SOCKET` paths.
4. Ask Claude Desktop: "List MCP servers." Both should appear.

- [ ] **Step 10: If any step failed**

Identify what went wrong:
- **Workflow failed:** look at the failed step's output in the Actions UI. Common failure modes:
  - sed syntax (macOS vs GNU sed differs — the script uses `-i ''` for macOS).
  - `BUILT_PRODUCTS_DIR` parsing — adjust the awk pattern if needed.
  - Test failure — fix locally, commit, re-tag with a new patch version `0.2.1` (don't try to re-push the same tag).
- **GitHub Release missing body:** confirm `body_path` references the correct file.
- **`.dmg` missing or empty:** confirm `hdiutil` succeeded and `Maugham.app` was found.
- **Stable app shows wrong version:** the `sed` rewrite of `project.yml` didn't take. Check the script's output.

After fixing, cut `v0.2.1` (write notes, re-run the script).

- [ ] **Step 11: Commit and tag the milestone**

```bash
git tag milestone-production-release
git push origin milestone-production-release
```

---

## Self-Review

After completing the plan above, run these checks against the spec at `docs/superpowers/specs/2026-05-22-production-release-design.md`:

**1. Spec coverage:**
- §1 problems (no install, no publish, MCP collision, no version discipline) — Tasks 17 (install path), 20 (publish), 5/6/7/8 (MCP), 3+20 (version) ✓
- §2.1 new files — all created in Tasks 1, 2, 10, 11, 12, 14, 15, 16, 18, 19, 20 ✓
- §2.2 modified files — addressed in Tasks 3, 5, 6, 7, 8, 9, 17, 21, 22 ✓
- §3.1 BuildVariant — Task 2 ✓
- §3.2 updater state machine — Tasks 10, 12, 13 ✓
- §3.2 banner — Task 15 ✓
- §3.2 menu — Task 16 ✓
- §3.3 variant-aware MCP — Tasks 5, 6 ✓
- §3.4 CI workflow — Task 20 ✓
- §3.5 Path-A flip (NOT implemented now, but documented in CLAUDE.md per Task 22) ✓
- §3.6 cut-release.sh — Task 19 ✓
- §4 data flow — exercised by Task 23 ✓
- §5 error handling — covered by tests in Tasks 12, 14 + bundle-id assertion in Task 4 ✓
- §6 CLAUDE.md additions — Task 22 ✓
- §7 testing — distributed across Tasks 1, 2, 6, 11, 12, 14, 15, 16; manual smoke in Task 23 ✓

**2. Placeholder scan:** No "TBD", "TODO", "implement later", "add appropriate error handling", or similar present. All code blocks are concrete.

**3. Type consistency:**
- `UpdateState` shape (Task 10) is referenced consistently in Tasks 12, 14, 15, 16. ✓
- `BuildVariant` properties (Task 2: displayName, supportFolderName, mcpServerKey, updaterEnabled, mcpSocketPath) match references in Tasks 5, 6, 7, 8, 9, 12, 16, 17. ✓
- `UpdateChecker` API (Task 12: `performCheck(trigger:)`, `state`; Task 13: `startBackgroundLoop()`, `checkNow()`) — used consistently in Tasks 14, 16, 17. ✓
- `ClaudeDesktopConfig` API additions (Task 6: `serverKey`, `socketPath` parameters) — referenced in Task 8. ✓
- `GitHubRelease` (Task 11: `tagName`, `body`, `semanticVersion`, `dmgAsset`, `dmgAsset.browserDownloadURL`) — used in Task 12. ✓
- `SemanticVersion` (Task 1: `init?(_:)`, `<`, `string`) — used in Tasks 11, 12. ✓

No issues found in self-review.

---

## Plan complete.

Saved to `docs/superpowers/plans/2026-05-22-production-release.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
