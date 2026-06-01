# Mac Auto-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the "reveal the .dmg in Finder" updater workaround with a signed + notarized build and a real in-place installer that verifies the download and swaps the running app, falling back to Finder-reveal only when `/Applications` is unwritable.

**Architecture:** Three layers. (1) CI signs with Developer ID + hardened runtime, notarizes, staples, and ships a `.zip` next to the `.dmg`. (2) Swift `UpdateInstaller` downloads the zip, verifies signature/Team-ID/notarization, stages it, and swaps the running bundle via a detached shell helper — triggered either by "Restart & Update" (relaunch) or the next ordinary quit (no relaunch). (3) Existing `UpdateChecker`/views are rewired to the new state. Dev builds are untouched (updater stays disabled, ad-hoc signed).

**Tech Stack:** Swift / SwiftUI / AppKit, `Security.framework` (`SecCode*`), `Process`/`ditto`, GitHub Actions, `notarytool`, `stapler`, xcodegen (`project.yml`).

**Spec:** `docs/superpowers/specs/2026-06-01-mac-auto-update-design.md`

**Reference patterns:** the phone signing pipeline (`.github/workflows/phone-release.yml`) and its `docs/release-notes/phone/SETUP.md` are the closest existing analogues — read them before Tasks 9–12.

**TDD note:** Tasks 1–8 are pure Swift logic and follow strict TDD (failing test → impl → pass → commit). Tasks 9–13 are CI/config/docs that **cannot** be unit-tested — they are validated by the dry-run gauntlet (Task 14) on a real Mac, per the `feedback_dry_run_is_integration_test` memory. Those tasks substitute a "build/verify command + expected output" step for the test step.

**Build commands (run from repo root):**
- Regenerate project after `project.yml` edits: `./gen.sh`
- Test: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
- Single test class: append `-only-testing:MaughamTests/<ClassName>`

---

## File Structure

**Create:**
- `Maugham/Updates/UpdateInstaller.swift` — the new core: unzip, verify (codesign + Team-ID + notarization), writability check, helper-script generation, detached launch, Finder fallback.
- `Maugham/Maugham.entitlements` — minimal hardened-runtime entitlements.
- `MaughamTests/Updates/UpdateInstallerTests.swift` — unit tests for installer logic (injected seams).
- `docs/release-notes/SETUP-mac-signing.md` — Developer ID cert → p12 → secrets walkthrough.

**Modify:**
- `Maugham/Updates/UpdateState.swift` — `.ready(...)` → `.readyToInstall(bundleURL:version:notes:)`; add `.installing`.
- `Maugham/Updates/GitHubReleasesAPI.swift` — add `zipAsset`.
- `Maugham/Updates/UpdateChecker.swift` — download zip; stage+verify; publish `.readyToInstall`.
- `Maugham/Updates/UpdateBannerView.swift` — subtler toast; "Restart & Update" / "Dismiss".
- `Maugham/Updates/UpdateSheet.swift` — "Install" calls installer instead of Finder-reveal.
- `Maugham/Updates/UpdateMenuCommand.swift` — menu titles for new states.
- `Maugham/MaughamApp.swift` — wire quit-time install to existing `.maughamAppWillTerminate`.
- `MaughamTests/Updates/UpdateCheckerTests.swift` — update for new state/closure names.
- `MaughamTests/Updates/UpdateBannerIntegrationTests.swift` + `UpdateSheetIntegrationTests.swift` — update for `.readyToInstall`.
- `project.yml` — Release signing/hardened-runtime/entitlements; move `ENABLE_HARDENED_RUNTIME: NO` to Debug; sign `maugham-mcp`.
- `.github/workflows/release.yml` — import cert, sign inside-out, notarize, staple, verify, package `.zip` + `.dmg`.
- `CLAUDE.md` — Releases section: signed/notarized now; retire right-click + Path-B notes.

---

## Task 1: Add `zipAsset` to GitHubReleasesAPI

**Files:**
- Modify: `Maugham/Updates/GitHubReleasesAPI.swift`
- Test: `MaughamTests/Updates/GitHubReleasesAPITests.swift`

- [ ] **Step 1: Write the failing test**

Add to `MaughamTests/Updates/GitHubReleasesAPITests.swift`:

```swift
func test_zipAsset_selectsZipWhenPresent() throws {
    let json = """
    {"tag_name":"v0.5.0","name":"x","body":"n","assets":[
      {"name":"Maugham-0.5.0.dmg","browser_download_url":"https://e/x.dmg","size":1},
      {"name":"Maugham-0.5.0.zip","browser_download_url":"https://e/x.zip","size":2}
    ]}
    """
    let r = try GitHubRelease.decode(from: Data(json.utf8))
    XCTAssertEqual(r.zipAsset?.name, "Maugham-0.5.0.zip")
    XCTAssertEqual(r.dmgAsset?.name, "Maugham-0.5.0.dmg")
}

func test_zipAsset_nilWhenAbsent() throws {
    let json = """
    {"tag_name":"v0.5.0","name":"x","body":"n","assets":[
      {"name":"Maugham-0.5.0.dmg","browser_download_url":"https://e/x.dmg","size":1}
    ]}
    """
    let r = try GitHubRelease.decode(from: Data(json.utf8))
    XCTAssertNil(r.zipAsset)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/GitHubReleasesAPITests`
Expected: FAIL — `value of type 'GitHubRelease' has no member 'zipAsset'`.

- [ ] **Step 3: Add the accessor**

In `Maugham/Updates/GitHubReleasesAPI.swift`, directly after the existing `dmgAsset`:

```swift
    public var zipAsset: Asset? {
        assets.first { $0.name.hasSuffix(".zip") }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Updates/GitHubReleasesAPI.swift MaughamTests/Updates/GitHubReleasesAPITests.swift
git commit -m "feat(updates): add zipAsset accessor for auto-update payload"
```

---

## Task 2: New UpdateState cases

**Files:**
- Modify: `Maugham/Updates/UpdateState.swift`
- Test: `MaughamTests/Updates/UpdateStateTests.swift` (create)

`.ready(version:dmgURL:releaseNotes:)` becomes `.readyToInstall(bundleURL:version:releaseNotes:)` (carries a *verified staged app bundle*, not a dmg) and we add `.installing`.

- [ ] **Step 1: Write the failing test**

Create `MaughamTests/Updates/UpdateStateTests.swift`:

```swift
import XCTest
@testable import Maugham

final class UpdateStateTests: XCTestCase {
    func test_readyToInstall_equatable() {
        let url = URL(fileURLWithPath: "/tmp/Maugham.app")
        let a = UpdateState.readyToInstall(bundleURL: url, version: "0.5.0", releaseNotes: "n")
        let b = UpdateState.readyToInstall(bundleURL: url, version: "0.5.0", releaseNotes: "n")
        XCTAssertEqual(a, b)
    }

    func test_installing_equatable() {
        XCTAssertEqual(UpdateState.installing(version: "0.5.0"),
                       UpdateState.installing(version: "0.5.0"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/UpdateStateTests`
Expected: FAIL — `type 'UpdateState' has no member 'readyToInstall'`.

- [ ] **Step 3: Replace the enum**

Replace the body of `Maugham/Updates/UpdateState.swift`:

```swift
import Foundation

/// State of the auto-updater. See 2026-06-01-mac-auto-update-design.md §"Data flow".
public enum UpdateState: Equatable {
    case idle
    case checking
    case downloading(version: String, progress: Double)
    /// A new version has been downloaded AND verified (signature + Team ID +
    /// notarization). `bundleURL` is the staged `Maugham.app`, ready to swap in.
    case readyToInstall(bundleURL: URL, version: String, releaseNotes: String)
    /// The swap helper is launching / the app is about to quit.
    case installing(version: String)
    case error(String)
    case upToDate(currentVersion: String)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: same as Step 2. Expected: PASS. (Other targets won't compile yet — that's fixed in Tasks 4–7. This step only builds the test target's dependency on the enum.)

> Note: the full scheme won't compile until Tasks 4–7 update the call sites. If the test runner refuses to build, proceed to Task 3 and run Step 4's command again after Task 7. Mark this step done once the enum compiles in isolation.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Updates/UpdateState.swift MaughamTests/Updates/UpdateStateTests.swift
git commit -m "feat(updates): UpdateState gains .readyToInstall and .installing"
```

---

## Task 3: UpdateInstaller — verification decision (pure logic)

**Files:**
- Create: `Maugham/Updates/UpdateInstaller.swift`
- Test: `MaughamTests/Updates/UpdateInstallerTests.swift`

This task builds only the *decision* layer with injected seams, so it's fully unit-testable. Real `codesign`/`spctl`/`ditto` invocation is wired in Task 8 and proven in Task 14.

- [ ] **Step 1: Write the failing test**

Create `MaughamTests/Updates/UpdateInstallerTests.swift`:

```swift
import XCTest
@testable import Maugham

final class UpdateInstallerTests: XCTestCase {
    /// A verification result the installer trusts.
    private func goodVerdict(team: String = "ABC123") -> VerificationVerdict {
        VerificationVerdict(codesignValid: true, notarized: true, teamID: team)
    }

    func test_accepts_whenSignedNotarizedAndTeamMatches() {
        let v = goodVerdict(team: "ABC123")
        XCTAssertEqual(UpdateInstaller.decide(verdict: v, expectedTeamID: "ABC123"),
                       .accept)
    }

    func test_rejects_whenTeamMismatch() {
        let v = goodVerdict(team: "EVIL99")
        XCTAssertEqual(UpdateInstaller.decide(verdict: v, expectedTeamID: "ABC123"),
                       .reject(reason: "Team ID mismatch"))
    }

    func test_rejects_whenNotNotarized() {
        let v = VerificationVerdict(codesignValid: true, notarized: false, teamID: "ABC123")
        XCTAssertEqual(UpdateInstaller.decide(verdict: v, expectedTeamID: "ABC123"),
                       .reject(reason: "Not notarized"))
    }

    func test_rejects_whenCodesignInvalid() {
        let v = VerificationVerdict(codesignValid: false, notarized: true, teamID: "ABC123")
        XCTAssertEqual(UpdateInstaller.decide(verdict: v, expectedTeamID: "ABC123"),
                       .reject(reason: "Invalid code signature"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/UpdateInstallerTests`
Expected: FAIL — `cannot find 'UpdateInstaller' in scope`.

- [ ] **Step 3: Create the file with the decision logic**

Create `Maugham/Updates/UpdateInstaller.swift`:

```swift
// Maugham/Updates/UpdateInstaller.swift
import Foundation

/// The result of inspecting a staged bundle's code signature.
public struct VerificationVerdict: Equatable {
    public let codesignValid: Bool
    public let notarized: Bool
    public let teamID: String?
    public init(codesignValid: Bool, notarized: Bool, teamID: String?) {
        self.codesignValid = codesignValid
        self.notarized = notarized
        self.teamID = teamID
    }
}

/// What to do with a staged bundle after verification.
public enum InstallDecision: Equatable {
    case accept
    case reject(reason: String)
}

public enum UpdateInstaller {
    /// Pure decision: a staged bundle is trustworthy iff its signature is valid,
    /// it is notarized, and its Team ID matches the running app's Team ID.
    /// Checks are ordered most-fundamental-first so the reason is the root cause.
    public static func decide(verdict: VerificationVerdict, expectedTeamID: String) -> InstallDecision {
        guard verdict.codesignValid else { return .reject(reason: "Invalid code signature") }
        guard verdict.notarized else { return .reject(reason: "Not notarized") }
        guard verdict.teamID == expectedTeamID else { return .reject(reason: "Team ID mismatch") }
        return .accept
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: same as Step 2. Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Updates/UpdateInstaller.swift MaughamTests/Updates/UpdateInstallerTests.swift
git commit -m "feat(updates): UpdateInstaller verification decision logic"
```

---

## Task 4: Helper-script generation (pure string builder)

**Files:**
- Modify: `Maugham/Updates/UpdateInstaller.swift`
- Test: `MaughamTests/Updates/UpdateInstallerTests.swift`

The detached helper waits for our PID to die, atomically swaps the bundle, and optionally relaunches.

- [ ] **Step 1: Write the failing test**

Add to `UpdateInstallerTests.swift`:

```swift
func test_helperScript_relaunch_containsWaitSwapAndOpen() {
    let script = UpdateInstaller.helperScript(
        pid: 4242,
        stagedBundle: "/staged/Maugham.app",
        installedBundle: "/Applications/Maugham.app",
        relaunch: true)
    XCTAssertTrue(script.contains("kill -0 4242"), "must poll our pid")
    XCTAssertTrue(script.contains("ditto"), "must copy the bundle")
    XCTAssertTrue(script.contains("/staged/Maugham.app"))
    XCTAssertTrue(script.contains("/Applications/Maugham.app"))
    XCTAssertTrue(script.contains("open \"/Applications/Maugham.app\""), "relaunch")
}

func test_helperScript_noRelaunch_omitsOpen() {
    let script = UpdateInstaller.helperScript(
        pid: 4242,
        stagedBundle: "/staged/Maugham.app",
        installedBundle: "/Applications/Maugham.app",
        relaunch: false)
    XCTAssertFalse(script.contains("open \""), "no relaunch on quit-time install")
    XCTAssertTrue(script.contains("ditto"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/UpdateInstallerTests`
Expected: FAIL — `type 'UpdateInstaller' has no member 'helperScript'`.

- [ ] **Step 3: Add the builder**

Add to `UpdateInstaller` in `Maugham/Updates/UpdateInstaller.swift`:

```swift
    /// Shell script run **detached** after the app quits. Polls until our PID is
    /// gone, then atomically swaps the bundle (ditto to a temp sibling + mv so a
    /// working app is never left half-overwritten), then optionally relaunches.
    public static func helperScript(
        pid: Int32,
        stagedBundle: String,
        installedBundle: String,
        relaunch: Bool
    ) -> String {
        let tmp = "\(installedBundle).inflight"
        var s = """
        #!/bin/bash
        set -e
        # Wait for the running Maugham (pid \(pid)) to fully exit.
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(tmp)"
        ditto "\(stagedBundle)" "\(tmp)"
        rm -rf "\(installedBundle)"
        mv "\(tmp)" "\(installedBundle)"
        """
        if relaunch {
            s += "\nopen \"\(installedBundle)\"\n"
        }
        return s
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Updates/UpdateInstaller.swift MaughamTests/Updates/UpdateInstallerTests.swift
git commit -m "feat(updates): detached swap-and-relaunch helper script builder"
```

---

## Task 5: Writability check → Finder-fallback decision

**Files:**
- Modify: `Maugham/Updates/UpdateInstaller.swift`
- Test: `MaughamTests/Updates/UpdateInstallerTests.swift`

If `/Applications/Maugham.app` isn't writable, the installer must fall back to revealing the `.dmg`. Inject the writability predicate so the decision is testable.

- [ ] **Step 1: Write the failing test**

Add to `UpdateInstallerTests.swift`:

```swift
func test_installMode_inPlaceWhenWritable() {
    let mode = UpdateInstaller.installMode(installedBundlePath: "/Applications/Maugham.app",
                                           isWritable: { _ in true })
    XCTAssertEqual(mode, .inPlace)
}

func test_installMode_finderFallbackWhenNotWritable() {
    let mode = UpdateInstaller.installMode(installedBundlePath: "/Applications/Maugham.app",
                                           isWritable: { _ in false })
    XCTAssertEqual(mode, .finderFallback)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/UpdateInstallerTests`
Expected: FAIL — `type 'UpdateInstaller' has no member 'installMode'`.

- [ ] **Step 3: Add the type + function**

Add to `Maugham/Updates/UpdateInstaller.swift`:

```swift
public enum InstallMode: Equatable {
    case inPlace        // swap /Applications/Maugham.app via the helper
    case finderFallback // reveal the .dmg in Finder (current behavior)
}

extension UpdateInstaller {
    /// Decide how to install based on whether the installed bundle is writable
    /// by the current user. Defaults are injected for testability.
    public static func installMode(
        installedBundlePath: String,
        isWritable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) }
    ) -> InstallMode {
        isWritable(installedBundlePath) ? .inPlace : .finderFallback
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Updates/UpdateInstaller.swift MaughamTests/Updates/UpdateInstallerTests.swift
git commit -m "feat(updates): writability check drives in-place vs Finder-fallback"
```

---

## Task 6: Read the running app's Team ID (Security.framework)

**Files:**
- Modify: `Maugham/Updates/UpdateInstaller.swift`
- Test: `MaughamTests/Updates/UpdateInstallerTests.swift`

The expected Team ID is read from the *running* app's own signature (self-anchoring; no hardcode). Under an ad-hoc-signed test host there is no Team ID, so the test asserts the call is non-crashing and returns `nil`-or-string — the real value is proven in Task 14.

- [ ] **Step 1: Write the failing test**

Add to `UpdateInstallerTests.swift`:

```swift
func test_runningAppTeamID_doesNotCrash() {
    // Test host is ad-hoc signed → nil is acceptable; signed Release build
    // returns the real team id (proven in dry-run). We only assert no crash.
    _ = UpdateInstaller.runningAppTeamID()
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/UpdateInstallerTests`
Expected: FAIL — `type 'UpdateInstaller' has no member 'runningAppTeamID'`.

- [ ] **Step 3: Implement with Security.framework**

At the top of `Maugham/Updates/UpdateInstaller.swift` add `import Security`, then add:

```swift
extension UpdateInstaller {
    /// The Team ID embedded in the *running* app's code signature, or nil if
    /// unsigned/ad-hoc (e.g. the test host). Self-anchoring: the staged update
    /// must be signed by the same team that signed us.
    public static func runningAppTeamID() -> String? {
        var codeRef: SecCode?
        guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let code = codeRef else { return nil }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess,
              let staticCode = staticRef else { return nil }
        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Updates/UpdateInstaller.swift MaughamTests/Updates/UpdateInstallerTests.swift
git commit -m "feat(updates): read running app Team ID from its own signature"
```

---

## Task 7: Rewire UpdateChecker, views, and menu to the new state

**Files:**
- Modify: `Maugham/Updates/UpdateChecker.swift`, `UpdateSheet.swift`, `UpdateBannerView.swift`, `UpdateMenuCommand.swift`
- Modify (fix compile): `MaughamTests/Updates/UpdateCheckerTests.swift`, `UpdateBannerIntegrationTests.swift`, `UpdateSheetIntegrationTests.swift`

This task makes the whole scheme compile against `.readyToInstall`. The checker now downloads the **zip**, stages+verifies it, and publishes `.readyToInstall` with the staged bundle URL. The verify/stage *side-effects* (real codesign/unzip) are injected as a closure so the checker stays unit-testable; the real implementation closure is the one wired in Task 8.

- [ ] **Step 1: Update UpdateChecker download + staging seam**

In `Maugham/Updates/UpdateChecker.swift`:

Rename the injected `downloadDMG` to `downloadAsset` and add an injected `stageAndVerify: (URL, String) async throws -> URL` that takes the downloaded zip + version and returns the verified staged bundle URL (throws on verify failure). Update `shared`:

```swift
    public static let shared: UpdateChecker = UpdateChecker(
        currentVersionString: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev",
        fetchLatest: { try await GitHubReleasesAPI.fetchLatestRelease() },
        downloadAsset: UpdateChecker.defaultDownload,
        stageAndVerify: UpdateChecker.defaultStageAndVerify)
```

Add stored properties + init params `downloadAsset` and `stageAndVerify` (replace `downloadDMG`). In `performCheck`, prefer the zip asset and route through staging:

```swift
            guard let asset = release.zipAsset ?? release.dmgAsset else {
                state = trigger == .manual
                    ? .error(GitHubReleasesAPI.Error.noDmgAsset.localizedDescription)
                    : .idle
                return
            }
            state = .downloading(version: newVersion.string, progress: 0)
            let downloaded = try await downloadAsset(asset.browserDownloadURL, newVersion.string)
            let stagedBundle = try await stageAndVerify(downloaded, newVersion.string)
            state = .readyToInstall(bundleURL: stagedBundle,
                                    version: newVersion.string,
                                    releaseNotes: release.body)
```

Rename `defaultDownload` → keep its body but name it `defaultDownload` still (the param is `downloadAsset`); the file extension can be `.zip` or `.dmg` — keep the `Maugham-<version>` naming but preserve the source extension:

```swift
    private static func defaultDownload(from url: URL, version: String) async throws -> URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let stagingDir = lib
            .appendingPathComponent("Application Support")
            .appendingPathComponent(BuildVariant.current.supportFolderName)
            .appendingPathComponent("Updates")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "zip" : url.pathExtension
        let target = stagingDir.appendingPathComponent("Maugham-\(version).\(ext)")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let (tmpURL, _) = try await URLSession.shared.download(from: url)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: tmpURL, to: target)
        return target
    }

    /// Placeholder real staging (filled in Task 8). For now, unzips nothing —
    /// Task 8 replaces this body with real unzip + verify.
    private static func defaultStageAndVerify(_ downloaded: URL, _ version: String) async throws -> URL {
        // Replaced in Task 8.
        return downloaded
    }
```

- [ ] **Step 2: Update the views**

In `UpdateSheet.swift`, the `.ready` arms become `.readyToInstall`; the Install button calls the installer instead of revealing Finder. Replace the `.ready(_, let dmg, _)` button arm:

```swift
        case .readyToInstall(let bundle, let version, _):
            Button("Later", action: dismiss)
            Button("Restart & Update") {
                Task { await UpdateChecker.shared.installNow(bundleURL: bundle, version: version) }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        case .installing:
            Button("Close", action: dismiss)
```

Update the `content` and `title` switches to handle `.readyToInstall` (show `releaseNotes`) and `.installing` (show a progress row "Installing…"). In the `.task` gate, add `.installing` to the "already doing something" branch.

In `UpdateBannerView.swift`, change the pattern match and button:

```swift
        if case .readyToInstall(let bundle, let v, _) = checker.state,
           Self.shouldShow(state: checker.state, dismissed: dismissedSet) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").foregroundColor(.accentColor)
                Text("Maugham \(v) is ready").font(.callout)
                Spacer()
                Button("Dismiss") { dismiss(version: v) }.buttonStyle(.borderless)
                Button("Restart & Update") {
                    Task { await UpdateChecker.shared.installNow(bundleURL: bundle, version: v) }
                }
                .keyboardShortcut(.defaultAction)
            }
            // ...existing padding/background/overlay unchanged...
        }
```

And update `shouldShow` to match `.readyToInstall`:

```swift
    public static func shouldShow(state: UpdateState, dismissed: Set<String>) -> Bool {
        if case .readyToInstall(_, let v, _) = state, !dismissed.contains(v) { return true }
        return false
    }
```

In `UpdateMenuCommand.swift`, update `menuTitle`:

```swift
        case .idle, .upToDate, .error: return "Check for Updates…"
        case .checking: return "Checking for Updates…"
        case .downloading: return "Downloading Update…"
        case .readyToInstall: return "Install Update…"
        case .installing: return "Installing…"
```

- [ ] **Step 3: Add `installNow` to UpdateChecker**

Add to `UpdateChecker` (the real swap is finished in Task 8; this sets state + delegates):

```swift
    /// Apply a verified staged update: flush autosave, set state, launch the
    /// detached helper, then quit. `relaunch` defaults true (explicit install).
    public func installNow(bundleURL: URL, version: String, relaunch: Bool = true) async {
        state = .installing(version: version)
        await UpdateChecker.performInstall?(bundleURL, relaunch)
    }

    /// Injected real installer side-effect (set in Task 8). Nil in tests.
    public static var performInstall: ((URL, Bool) async -> Void)?
```

- [ ] **Step 4: Fix the existing tests to compile**

In `UpdateCheckerTests.swift`: rename the `download:` param to `downloadAsset:`, add a `stageAndVerify:` default that returns its input, and change the `.ready` assertion in `test_idleToReady_whenNewerVersionAvailable` (rename the test to `..._readyToInstall`) to match `.readyToInstall`:

```swift
    private func makeChecker(
        currentVersion: String = "0.1.0",
        fetch: @escaping () async throws -> GitHubRelease,
        downloadAsset: @escaping (URL, String) async throws -> URL = { _, _ in
            URL(fileURLWithPath: "/tmp/fake.zip")
        },
        stageAndVerify: @escaping (URL, String) async throws -> URL = { u, _ in u }
    ) -> UpdateChecker {
        UpdateChecker(currentVersionString: currentVersion,
                      fetchLatest: fetch,
                      downloadAsset: downloadAsset,
                      stageAndVerify: stageAndVerify)
    }
```

And the asset JSON in `release(...)` should include a `.zip` asset so the zip path is exercised:

```swift
         "assets":[{"name":"Maugham-\(version).zip",
                    "browser_download_url":"https://example/Maugham-\(version).zip",
                    "size":100}]}
```

Update the ready assertion:

```swift
    func test_idleToReadyToInstall_whenNewerVersionAvailable() async {
        let checker = makeChecker(
            currentVersion: "0.1.0",
            fetch: { self.release(version: "0.2.0") },
            stageAndVerify: { _, _ in URL(fileURLWithPath: "/tmp/Maugham.app") })
        await checker.performCheck(trigger: .manual)
        if case .readyToInstall(_, let v, _) = checker.state {
            XCTAssertEqual(v, "0.2.0")
        } else {
            XCTFail("Expected .readyToInstall, got \(checker.state)")
        }
    }
```

In `UpdateBannerIntegrationTests.swift` and `UpdateSheetIntegrationTests.swift`: replace every `.ready(version:dmgURL:releaseNotes:)` literal with `.readyToInstall(bundleURL: URL(fileURLWithPath: "/tmp/Maugham.app"), version: ..., releaseNotes: ...)`.

- [ ] **Step 4b: Run the full update test suite**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/UpdateCheckerTests -only-testing:MaughamTests/UpdateBannerIntegrationTests -only-testing:MaughamTests/UpdateSheetIntegrationTests -only-testing:MaughamTests/UpdateStateTests -only-testing:MaughamTests/UpdateInstallerTests`
Expected: PASS (whole updates suite green; full scheme now compiles).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Updates/ MaughamTests/Updates/
git commit -m "feat(updates): rewire checker/views/menu to .readyToInstall + zip download"
```

---

## Task 8: Real stage-and-verify + install side-effects

**Files:**
- Modify: `Maugham/Updates/UpdateInstaller.swift`, `Maugham/Updates/UpdateChecker.swift`
- Modify: `Maugham/MaughamApp.swift`

Now wire the real `Process`-based unzip, codesign/spctl verification, helper launch, and the quit-time install hook. These shell out, so they are validated in Task 14, not by unit tests; we keep the pure pieces (Tasks 3–6) as the tested core.

- [ ] **Step 1: Add real verification + staging to UpdateInstaller**

Add to `Maugham/Updates/UpdateInstaller.swift`:

```swift
extension UpdateInstaller {
    enum InstallError: LocalizedError {
        case unzipFailed, verifyFailed(String), helperLaunchFailed
        var errorDescription: String? {
            switch self {
            case .unzipFailed: return "Couldn't unpack the update"
            case .verifyFailed(let r): return "Update failed verification: \(r)"
            case .helperLaunchFailed: return "Couldn't start the installer"
            }
        }
    }

    /// Run a tool, return (exitCode, stdout). Synchronous; callers are off the
    /// main actor's hot path (invoked from the updater's async flow).
    private static func run(_ launchPath: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Inspect a staged bundle's signature via codesign + spctl.
    static func verify(bundlePath: String) -> VerificationVerdict {
        let (csCode, _) = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundlePath])
        let (_, dvOut) = run("/usr/bin/codesign", ["-dv", "--verbose=4", bundlePath])
        let teamID = dvOut.split(separator: "\n")
            .first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
            .flatMap { $0 == "not set" ? nil : $0 }
        // spctl assess: exit 0 == accepted (notarized & signed for exec).
        let (spctlCode, _) = run("/usr/sbin/spctl", ["-a", "-t", "exec", "-vv", bundlePath])
        return VerificationVerdict(codesignValid: csCode == 0,
                                   notarized: spctlCode == 0,
                                   teamID: teamID)
    }

    /// Unzip `zip` into a staging dir and return the contained Maugham.app URL,
    /// verifying it against the running app's Team ID. Throws on any failure.
    static func stageAndVerify(zip: URL, version: String) throws -> URL {
        let stageDir = zip.deletingLastPathComponent()
            .appendingPathComponent("staged-\(version)", isDirectory: true)
        try? FileManager.default.removeItem(at: stageDir)
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        let (code, _) = run("/usr/bin/ditto",
                            ["-x", "-k", zip.path, stageDir.path])
        guard code == 0 else { throw InstallError.unzipFailed }
        let bundle = stageDir.appendingPathComponent("Maugham.app")
        guard FileManager.default.fileExists(atPath: bundle.path) else { throw InstallError.unzipFailed }
        // Strip quarantine so the swapped-in copy launches clean.
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", bundle.path])
        let verdict = verify(bundlePath: bundle.path)
        let expected = runningAppTeamID() ?? ""
        switch decide(verdict: verdict, expectedTeamID: expected) {
        case .accept: return bundle
        case .reject(let reason): throw InstallError.verifyFailed(reason)
        }
    }

    /// Launch the detached swap helper for a verified bundle. `relaunch` true
    /// reopens the app afterward. Returns false if it couldn't be launched.
    @discardableResult
    static func launchSwapHelper(stagedBundle: URL, relaunch: Bool) -> Bool {
        let installed = "/Applications/Maugham.app"
        guard installMode(installedBundlePath: installed) == .inPlace else {
            // Not writable → caller handles Finder fallback.
            return false
        }
        let script = helperScript(pid: ProcessInfo.processInfo.processIdentifier,
                                  stagedBundle: stagedBundle.path,
                                  installedBundle: installed,
                                  relaunch: relaunch)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("maugham-update-\(UUID().uuidString).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch { return false }
        let p = Process()
        // setsid detaches the helper into its own session so it outlives us.
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["setsid", "/bin/bash", scriptURL.path]
        do { try p.run() } catch { return false }
        return true
    }
}
```

> Note: if `/usr/bin/env setsid` is unavailable on macOS (it is *not* a standard macOS binary), use the `nohup` form instead: `p.arguments = ["nohup", "/bin/bash", scriptURL.path]` with `p.executableURL = URL(fileURLWithPath: "/usr/bin/env")`. Prove which detaches correctly in Task 14, Step "relaunch race".

- [ ] **Step 2: Wire the real closures into UpdateChecker + Finder fallback**

In `UpdateChecker.swift`, replace `defaultStageAndVerify`:

```swift
    private static func defaultStageAndVerify(_ downloaded: URL, _ version: String) async throws -> URL {
        // .dmg fallback (zip-less release): we can't swap a dmg in place, so
        // surface it as a Finder reveal by returning the dmg unchanged; the
        // installer's Finder fallback handles non-.app bundles.
        if downloaded.pathExtension == "dmg" { return downloaded }
        return try UpdateInstaller.stageAndVerify(zip: downloaded, version: version)
    }
```

Wire `performInstall` once at app start. In `UpdateChecker.installNow`, before quitting, flush autosave and either launch the helper or fall back to Finder:

```swift
    public func installNow(bundleURL: URL, version: String, relaunch: Bool = true) async {
        state = .installing(version: version)
        // Flush any debounced autosave before we quit (tripwire #14).
        NotificationCenter.default.post(name: .maughamFlushBeforeUpdate, object: nil)
        if bundleURL.pathExtension == "app",
           UpdateInstaller.launchSwapHelper(stagedBundle: bundleURL, relaunch: relaunch) {
            await NSApplication.shared.terminate(nil)  // helper swaps + relaunches
        } else {
            // Finder fallback: reveal whatever we downloaded.
            NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
            state = .readyToInstall(bundleURL: bundleURL, version: version, releaseNotes: "")
        }
    }
```

Add the notification name in the Updates folder (e.g. top of `UpdateChecker.swift`):

```swift
public extension Notification.Name {
    static let maughamFlushBeforeUpdate = Notification.Name("maughamFlushBeforeUpdate")
}
```

- [ ] **Step 3: Quit-time install hook in MaughamApp**

In `Maugham/MaughamApp.swift`, the app already observes `NSApplication.willTerminateNotification`. Add: if a verified update is staged and the user dismissed (did not click Restart & Update), fire a *no-relaunch* swap on terminate. Track staged state on the checker:

In `UpdateChecker`, add:

```swift
    /// Set when a verified update is staged but the user dismissed the toast.
    /// On ordinary quit we apply it silently (no relaunch).
    public var pendingQuitInstall: (bundleURL: URL, version: String)?
```

Set `pendingQuitInstall` when entering `.readyToInstall`, clear it on `installNow`. In `MaughamApp`'s `willTerminate` observer, add:

```swift
            if let pending = UpdateChecker.shared.pendingQuitInstall,
               pending.bundleURL.pathExtension == "app" {
                UpdateInstaller.launchSwapHelper(stagedBundle: pending.bundleURL, relaunch: false)
            }
```

- [ ] **Step 4: Build the whole scheme (no test — shell-outs proven in Task 14)**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED. Then run the full updates suite to confirm no regressions:
`xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/UpdateInstallerTests -only-testing:MaughamTests/UpdateCheckerTests`
Expected: PASS (pure logic still green; shell-out paths exercised in Task 14).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Updates/ Maugham/MaughamApp.swift
git commit -m "feat(updates): real unzip+verify, detached swap helper, quit-time install"
```

---

## Task 9: Hardened-runtime entitlements + Release signing in project.yml

**Files:**
- Create: `Maugham/Maugham.entitlements`
- Modify: `project.yml`

**Not unit-testable** — validated by `./gen.sh` + a signed CI build (Task 14). The step replacing "run test" is "regenerate + confirm settings."

- [ ] **Step 1: Create minimal entitlements**

Create `Maugham/Maugham.entitlements` (start minimal; add WhisperKit-required keys only if Task 14 proves they're needed):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
```

- [ ] **Step 2: Move hardened-runtime to Debug-only + add Release signing**

In `project.yml`, remove `ENABLE_HARDENED_RUNTIME: NO` from `settings.base` (line ~15). In the `Maugham` target's `settings.configs`:

```yaml
        Debug:
          PRODUCT_BUNDLE_IDENTIFIER: com.maugham.Maugham.dev
          SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited) MAUGHAM_DEV_BUILD
          MAUGHAM_DISPLAY_NAME: Maugham Dev
          ASSETCATALOG_COMPILER_APPICON_NAME: AppIconDev
          ENABLE_HARDENED_RUNTIME: NO
          CODE_SIGN_IDENTITY: "-"
        Release:
          PRODUCT_BUNDLE_IDENTIFIER: com.maugham.Maugham
          MAUGHAM_DISPLAY_NAME: Maugham
          ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
          ENABLE_HARDENED_RUNTIME: YES
          CODE_SIGN_STYLE: Manual
          CODE_SIGN_IDENTITY: "Developer ID Application"
          CODE_SIGN_ENTITLEMENTS: Maugham/Maugham.entitlements
```

Keep the top-level `settings.base` `CODE_SIGN_IDENTITY: "-"` and `CODE_SIGN_STYLE: Automatic` (they remain the default for the other targets; the Release config above overrides for the app). Add the entitlements file to the target's excludes so it isn't treated as a source/resource:

```yaml
    sources:
      - path: Maugham
        excludes:
          - Info.plist
          - Maugham.entitlements
          - "**/AREA.md"
          - "Resources/PublishStarter/**"
          - "Resources/bin/**"
```

- [ ] **Step 3: Regenerate + confirm**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham -showBuildSettings -configuration Debug 2>/dev/null | grep -E "ENABLE_HARDENED_RUNTIME|CODE_SIGN_IDENTITY"`
Expected: Debug shows `ENABLE_HARDENED_RUNTIME = NO` and `CODE_SIGN_IDENTITY = -`.
Run the same with `-configuration Release`. Expected: `ENABLE_HARDENED_RUNTIME = YES`, `CODE_SIGN_IDENTITY = Developer ID Application`.

Confirm the Debug build still compiles + tests pass (dev path unaffected):
`xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: TEST SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add project.yml Maugham/Maugham.entitlements
git commit -m "build: Release signs with Developer ID + hardened runtime; dev stays ad-hoc"
```

---

## Task 10: Sign the embedded maugham-mcp tool

**Files:**
- Modify: `project.yml`

The bundled `maugham-mcp` currently copies with `codeSign: false`. Under hardened runtime + notarization, all embedded executables must be signed. Let Xcode re-sign it on copy in Release.

- [ ] **Step 1: Flip codeSign on the copy dependency**

In `project.yml`, the `Maugham` target's dependency:

```yaml
    dependencies:
      - package: MaughamCore
      - package: WhisperKit
      - target: maugham-mcp
        copy:
          destination: executables
          codeSign: true
```

And give `maugham-mcp` hardened runtime in Release (add to its `settings`):

```yaml
  maugham-mcp:
    type: tool
    platform: macOS
    sources:
      - path: maugham-mcp
    settings:
      base:
        PRODUCT_NAME: maugham-mcp
        MACOSX_DEPLOYMENT_TARGET: "14.0"
        SWIFT_VERSION: "5.10"
        CODE_SIGN_STYLE: Automatic
        CODE_SIGN_IDENTITY: "-"
      configs:
        Release:
          ENABLE_HARDENED_RUNTIME: YES
```

> Note: the CI signing step (Task 11) re-signs the whole bundle inside-out with the Developer ID identity anyway; this `codeSign: true` ensures the local Release build is self-consistent and the copy isn't left ad-hoc-signed inside a Developer-ID app.

- [ ] **Step 2: Regenerate + confirm Release build links the tool**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham build -configuration Release CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: BUILD SUCCEEDED. (`CODE_SIGNING_ALLOWED=NO` lets it build locally without a real identity; CI does the real signing.)

- [ ] **Step 3: Commit**

```bash
git add project.yml
git commit -m "build: sign embedded maugham-mcp under hardened runtime"
```

---

## Task 11: CI — sign, notarize, staple, ship .zip + .dmg

**Files:**
- Modify: `.github/workflows/release.yml`

**Not unit-testable** — validated by a throwaway tag in Task 14. Read `.github/workflows/phone-release.yml` first for the `import-codesign-certs` + ASC-API-key patterns.

- [ ] **Step 1: Add cert import + ASC key decode (after "Install xcodegen")**

```yaml
      - name: Import Developer ID certificate
        uses: apple-actions/import-codesign-certs@v7
        with:
          p12-file-base64: ${{ secrets.DEVELOPER_ID_CERT }}
          p12-password: ${{ secrets.DEVELOPER_ID_CERT_PASSWORD }}

      - name: Decode App Store Connect API key (for notarytool)
        env:
          ASC_API_KEY: ${{ secrets.APP_STORE_CONNECT_API_KEY }}
          ASC_KEY_ID: ${{ secrets.APP_STORE_CONNECT_KEY_ID }}
        run: |
          set -euo pipefail
          mkdir -p /tmp/asc
          printf '%s' "$ASC_API_KEY" | base64 --decode > "/tmp/asc/AuthKey_${ASC_KEY_ID}.p8"
```

- [ ] **Step 2: Build Release WITH signing (replace the existing Build step)**

Replace the `CODE_SIGNING_ALLOWED=NO` Release build with a signed one. The DEVELOPMENT_TEAM comes from the imported cert; read it from the keychain:

```yaml
      - name: Derive Team ID from imported cert
        id: team
        run: |
          set -euo pipefail
          TEAM=$(security find-identity -v -p codesigning | \
            grep "Developer ID Application" | head -1 | \
            sed -E 's/.*\(([A-Z0-9]+)\)"?$/\1/')
          echo "team_id=$TEAM" >> "$GITHUB_OUTPUT"
          echo "Team: $TEAM"

      - name: Build (Release, signed + hardened)
        run: |
          xcodebuild -project Maugham.xcodeproj -scheme Maugham \
            -configuration Release build \
            DEVELOPMENT_TEAM="${{ steps.team.outputs.team_id }}"
```

(The existing "Test" step stays as-is with `CODE_SIGNING_ALLOWED=NO` — tests run in Debug.)

- [ ] **Step 3: Notarize + staple (after "Locate built app")**

```yaml
      - name: Notarize + staple
        env:
          ASC_KEY_ID: ${{ secrets.APP_STORE_CONNECT_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}
        run: |
          set -euo pipefail
          APP="${{ steps.locate.outputs.app_path }}"
          # notarytool needs a zip of the app.
          ditto -c -k --keepParent "$APP" /tmp/notarize.zip
          xcrun notarytool submit /tmp/notarize.zip \
            --key "/tmp/asc/AuthKey_${ASC_KEY_ID}.p8" \
            --key-id "$ASC_KEY_ID" \
            --issuer "$ASC_ISSUER_ID" \
            --wait
          xcrun stapler staple "$APP"
          # Gate: assessment must pass or we don't ship.
          spctl -a -t exec -vv "$APP"
          codesign --verify --deep --strict --verbose=2 "$APP"
```

- [ ] **Step 4: Package both .dmg and .zip (replace the Package step)**

```yaml
      - name: Package .dmg and .zip
        run: |
          set -euo pipefail
          VERSION="${{ steps.ver.outputs.version }}"
          APP="${{ steps.locate.outputs.app_path }}"
          # DMG (manual / website download)
          mkdir -p /tmp/dmg-root
          ditto "$APP" "/tmp/dmg-root/Maugham.app"
          ln -s /Applications /tmp/dmg-root/Applications
          hdiutil create -volname Maugham -srcfolder /tmp/dmg-root -ov -format UDZO \
            "Maugham-${VERSION}.dmg"
          # ZIP (in-app auto-update payload; staple ticket travels inside the bundle)
          ditto -c -k --keepParent "$APP" "Maugham-${VERSION}.zip"
          ls -lh "Maugham-${VERSION}.dmg" "Maugham-${VERSION}.zip"
```

- [ ] **Step 5: Upload both assets (update the Release step's `files`)**

```yaml
        with:
          files: |
            Maugham-${{ steps.ver.outputs.version }}.dmg
            Maugham-${{ steps.ver.outputs.version }}.zip
          body_path: docs/release-notes/v${{ steps.ver.outputs.version }}.md
          name: Maugham ${{ steps.ver.outputs.version }}
          tag_name: ${{ github.ref_name }}
          draft: false
          prerelease: false
```

- [ ] **Step 6: Validate workflow YAML locally**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml')); print('YAML OK')"`
Expected: `YAML OK`.

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci(release): sign + notarize + staple; ship .zip alongside .dmg"
```

---

## Task 12: SETUP doc for Mac signing secrets

**Files:**
- Create: `docs/release-notes/SETUP-mac-signing.md`

- [ ] **Step 1: Write the setup doc**

Create `docs/release-notes/SETUP-mac-signing.md`:

```markdown
# Mac Signing & Notarization — One-Time Setup

The release workflow (`.github/workflows/release.yml`) signs with a **Developer ID
Application** certificate and notarizes with an App Store Connect API key. The ASC
key is the **same one the phone pipeline already uses** — only the cert is new.

## 1. Create the Developer ID Application certificate

This is NOT the iOS "Apple Distribution" cert the phone uses — that type cannot
notarize Mac apps. You need a separate **Developer ID Application** cert.

- Apple Developer portal → Certificates → **+** → **Developer ID Application**.
- Follow the CSR flow (Keychain Access → Certificate Assistant → Request a
  Certificate from a Certificate Authority).
- Download the `.cer`, open it (imports into the login keychain alongside its
  private key).

## 2. Export as .p12 and base64-encode

- Keychain Access → find "Developer ID Application: <your name> (TEAMID)" →
  right-click → Export → `.p12` (set a password).
- `base64 -i DeveloperID.p12 | pbcopy`

## 3. Add GitHub secrets

Repo → Settings → Secrets and variables → Actions → New repository secret:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_CERT` | the base64 string from step 2 |
| `DEVELOPER_ID_CERT_PASSWORD` | the .p12 password |

**Reused (already set for the phone pipeline — do not recreate):**
`APP_STORE_CONNECT_API_KEY`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`.

## 4. Dry run

Per the dry-run-is-the-integration-test rule, prove it on a throwaway tag before a
real release:

    cp docs/release-notes/_template.md docs/release-notes/v0.0.1-test.md   # placeholder notes won't match v pattern; use a real X.Y.Z you'll delete
    # actually: cut a real throwaway X.Y.Z, e.g. 0.4.99
    ./scripts/cut-release.sh 0.4.99
    git push origin v0.4.99

Then download the `.dmg` from the GitHub Release on a real Mac and confirm it
launches with NO right-click → Open. Delete the throwaway tag + release after.
```

- [ ] **Step 2: Commit**

```bash
git add docs/release-notes/SETUP-mac-signing.md
git commit -m "docs: Mac signing/notarization one-time setup"
```

---

## Task 13: Update CLAUDE.md Releases section

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the Releases + signing notes**

In `CLAUDE.md`, in the Releases section, replace the "**Builds are currently unsigned**" paragraph with:

```markdown
**Builds are signed + notarized.** Release config uses a Developer ID Application
cert + hardened runtime; CI notarizes and staples, so downloaded `.dmg`/`.zip`
launch Gatekeeper-clean (no right-click → Open). Dev builds stay ad-hoc
(`com.maugham.Maugham.dev`, updater disabled). One-time secret setup:
`docs/release-notes/SETUP-mac-signing.md`. New secrets: `DEVELOPER_ID_CERT`,
`DEVELOPER_ID_CERT_PASSWORD`; notarytool reuses the phone's ASC API key.

**Auto-update is in-place.** The updater downloads the notarized `.zip`, verifies
it (codesign + our Team ID + notarization), and swaps the running app via a
detached helper — "Restart & Update" relaunches; dismissing applies on next quit.
Falls back to revealing the `.dmg` in Finder if `/Applications` is unwritable.
See `docs/superpowers/specs/2026-06-01-mac-auto-update-design.md`.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(CLAUDE): record signed/notarized builds + in-place auto-update"
```

---

## Task 14: Dry-run gauntlet (real Mac, throwaway tags)

**Not code — the integration test.** Per `feedback_dry_run_is_integration_test`,
these can only be proven by a signed CI build on a real machine. Do this BEFORE
the real release tag. Cut throwaway `v0.4.9x` tags; delete after.

- [ ] **Step 1: One-time secret setup** — follow `docs/release-notes/SETUP-mac-signing.md` (Developer ID cert → p12 → 2 GitHub secrets).

- [ ] **Step 2: Cut a throwaway tag**

```bash
cp docs/release-notes/_template.md docs/release-notes/v0.4.91.md  # fill minimal notes
git add docs/release-notes/v0.4.91.md && git commit -m "chore: dry-run notes v0.4.91"
./scripts/cut-release.sh 0.4.91 && git push origin v0.4.91
```

- [ ] **Step 3: Watch CI** — `gh run watch` (or the Actions tab). The build must:
  sign without error, **notarytool accept** the hardened-runtime build embedding
  WhisperKit + tectonic + maugham-mcp, staple, and pass the `spctl`/`codesign` gate.
  **If notarytool rejects**, read the log (`xcrun notarytool log <id>`); the usual
  cause is a missing hardened-runtime entitlement for WhisperKit's Metal/JIT use —
  add the minimal required key to `Maugham/Maugham.entitlements`, re-cut.

- [ ] **Step 4: Download + first-launch test** — on a real Mac, download the `.dmg`
  from the Release, install, launch. Expected: **opens with NO right-click → Open.**

- [ ] **Step 5: Transcription under hardened runtime** — record a voice capture
  (the WhisperKit path). Expected: transcribes successfully (no entitlement crash).

- [ ] **Step 6: In-place update test** — install the throwaway build into
  `/Applications`, then cut a *second* throwaway (`0.4.92`). With the app running,
  open Check for Updates → "Restart & Update." Expected: app quits, swaps, relaunches
  as 0.4.92. Then repeat but **Dismiss** and quit normally; reopen → now 0.4.92.

- [ ] **Step 7: Relaunch-race check** — confirm the helper waits for true process
  death (not just window close). If the swap happens before exit, switch the detach
  mechanism per the Task 8 Step 1 note (`setsid` vs `nohup`).

- [ ] **Step 8: Clean up** — delete throwaway tags + releases:

```bash
gh release delete v0.4.91 --yes; git push --delete origin v0.4.91; git tag -d v0.4.91
gh release delete v0.4.92 --yes; git push --delete origin v0.4.92; git tag -d v0.4.92
git rm docs/release-notes/v0.4.91.md docs/release-notes/v0.4.92.md
git commit -m "chore: remove dry-run release notes"
```

- [ ] **Step 9: Manual smoke (the single post-B smoke, per the plan)** — full smoke
  from CLAUDE.md: launch → New Novel → type → ⌘Q → relaunch → reopen → text intact,
  AND confirm Check for Updates shows the real latest. Only after this passes do we
  cut the real release tag.

---

## Self-Review notes

- **Spec coverage:** Layer 1 → Tasks 9–11; Layer 2 (zip) → Tasks 1, 11; Layer 3
  (verify/stage/swap/two-triggers/fallback) → Tasks 3–8; SETUP.md → Task 12;
  CLAUDE.md → Task 13; dry-run gauntlet (incl. WhisperKit entitlement risk) → Task 14.
- **Type consistency:** `VerificationVerdict`, `InstallDecision`, `InstallMode`,
  `UpdateState.readyToInstall(bundleURL:version:releaseNotes:)`,
  `UpdateInstaller.{decide,helperScript,installMode,runningAppTeamID,verify,stageAndVerify,launchSwapHelper}`,
  `UpdateChecker.{downloadAsset,stageAndVerify,installNow,performInstall,pendingQuitInstall}`,
  `Notification.Name.maughamFlushBeforeUpdate` — names used consistently across tasks.
- **Known non-TDD tasks:** 9–14 are config/CI/manual by nature; each substitutes a
  build/verify command or on-device check for the unit-test step, as the spec's
  dry-run section requires.
```
