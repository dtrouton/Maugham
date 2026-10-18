// Maugham/Updates/UpdateChecker.swift
import Foundation
import MaughamCore
import SwiftUI

/// Tier 1.5 updater. Polls GitHub Releases; downloads a newer `.zip` (or `.dmg`) silently;
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
        downloadAsset: UpdateChecker.defaultDownload,
        stageAndVerify: UpdateChecker.defaultStageAndVerify)

    private let currentVersionString: String
    private let fetchLatest: () async throws -> GitHubRelease
    private let downloadAsset: (GitHubRelease.Asset, String, @escaping @MainActor (Double) -> Void) async throws -> URL
    private let stageAndVerify: (URL, String) async throws -> URL
    private let systemVersion: MinimumSystemVersion

    public init(
        currentVersionString: String,
        fetchLatest: @escaping () async throws -> GitHubRelease,
        downloadAsset: @escaping (GitHubRelease.Asset, String, @escaping @MainActor (Double) -> Void) async throws -> URL,
        stageAndVerify: @escaping (URL, String) async throws -> URL,
        systemVersion: MinimumSystemVersion = .runningSystem
    ) {
        self.currentVersionString = currentVersionString
        self.fetchLatest = fetchLatest
        self.downloadAsset = downloadAsset
        self.stageAndVerify = stageAndVerify
        self.systemVersion = systemVersion
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
            // A newer Maugham this Mac cannot launch is not an update. Decided
            // BEFORE the asset guard and before any byte is fetched: the whole
            // point is that nothing is downloaded. A release carrying no
            // minimum-macOS fact (everything before 0.40.0) is offered as
            // before — absence is not a refusal.
            if let required = MinimumSystemVersion.parse(releaseBody: release.body),
               !required.isSatisfied(by: systemVersion) {
                state = .newerBuildNeedsNewerSystem(
                    currentVersion: currentVersionString,
                    newerVersion: newVersion.string,
                    requiredSystem: required.displayString)
                return
            }
            guard let asset = release.zipAsset ?? release.dmgAsset else {
                state = trigger == .manual
                    ? .error(GitHubReleasesAPI.Error.noInstallableAsset.localizedDescription)
                    : .idle
                return
            }
            // Only this repo's own release URL for this tag and asset is ever
            // requested — refused like a release with no asset.
            guard GitHubReleasesAPI.isTrustedAssetURL(
                asset.browserDownloadURL, for: asset, tag: release.tagName) else {
                state = trigger == .manual
                    ? .error(GitHubReleasesAPI.Error.untrustedAssetURL.localizedDescription)
                    : .idle
                return
            }
            // A release declaring more than the cap is refused before a byte
            // is fetched (the download also counts what actually arrives).
            guard !UpdateDownload.exceedsCap(receivedBytes: 0, expectedBytes: Int64(asset.size)) else {
                state = trigger == .manual
                    ? .error(UpdateDownloadError.tooLarge(
                        bytes: Int64(asset.size),
                        limit: UpdateLimits.standard.maxDownloadBytes).localizedDescription)
                    : .idle
                return
            }
            let versionString = newVersion.string
            state = .downloading(version: versionString, progress: 0)
            let downloaded = try await downloadAsset(asset, versionString) { [weak self] progress in
                self?.state = .downloading(version: versionString, progress: progress)
            }
            let stagedBundle = try await stageAndVerify(downloaded, newVersion.string)
            state = .readyToInstall(
                bundleURL: stagedBundle,
                version: newVersion.string,
                // The sheet renders these as plain Text — the machine line
                // release.yml appends must not show as literal markup.
                releaseNotes: MinimumSystemVersion.strippingMarker(from: release.body))
            if stagedBundle.pathExtension == "app" {
                pendingQuitInstall = (stagedBundle, newVersion.string)
            }
        } catch {
            state = trigger == .manual
                ? .error(error.localizedDescription)
                : .idle
        }
    }

    /// `~/Library/Application Support/<variant>/Updates`: downloads, staged
    /// bundles, and the swap helper's `install-status` line all live here.
    nonisolated static var updatesDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Application Support")
            .appendingPathComponent(BuildVariant.current.supportFolderName)
            .appendingPathComponent("Updates")
    }

    /// Default download implementation: `UpdateDownload` (a download task,
    /// one retry on a transient network error, capped at
    /// `UpdateLimits.maxDownloadBytes`) into a `.download` temp file in the
    /// updates folder under Application Support, then moved into place as
    /// `Maugham-<ver>.<ext>` — so a failure never leaves a partial file at the
    /// final path. A complete file already at that path is reused. Progress is
    /// a fraction (0...1) as bytes arrive, or -1 once when the server omits
    /// Content-Length (UpdateSheet draws an indeterminate spinner), and 1.0
    /// when the file is complete.
    private static func defaultDownload(
        asset: GitHubRelease.Asset,
        version: String,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let stagingDir = updatesDirectory
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let ext = UpdateDownload.fileExtension(forAssetNamed: asset.name)
        let target = stagingDir.appendingPathComponent("Maugham-\(version).\(ext)")
        if FileManager.default.fileExists(atPath: target.path) {
            progress(1.0)
            return target
        }

        let tmpURL = stagingDir.appendingPathComponent("Maugham-\(version).\(ext).download")
        try? FileManager.default.removeItem(at: tmpURL)
        do {
            // The delegate reports off the main thread; the main queue is FIFO,
            // so the fractions arrive in the order they were measured.
            try await UpdateDownload.download(from: asset.browserDownloadURL, to: tmpURL) { fraction in
                DispatchQueue.main.async { progress(fraction) }
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw error
        }

        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: tmpURL, to: target)
        progress(1.0)
        return target
    }

    /// Real staging: unzip + verify a `.zip` payload; a `.dmg` (zip-less fallback
    /// release) passes through unchanged (it can't be swapped in place — the
    /// installer's Finder fallback handles it).
    private static func defaultStageAndVerify(_ downloaded: URL, _ version: String) async throws -> URL {
        if downloaded.pathExtension == "dmg" { return downloaded }
        return try await UpdateInstaller.stageAndVerify(zip: downloaded, version: version)
    }

    /// Read and remove the swap helper's `install-status` line from the last
    /// install (#67 Task 5), and put its sentence in the banner. Called once
    /// at launch, before the background poll starts.
    ///
    /// - `refused`: the staged copy failed the install-time check, so this
    ///   version's `Maugham-<v>.zip` and `staged-<v>` are deleted —
    ///   `defaultDownload` reuses a zip already at that path, and "Maugham
    ///   will download it again" must be true. Nothing else in the folder is
    ///   touched. (`pendingQuitInstall` is in-memory and starts nil at launch,
    ///   so nothing else would reuse the refused bundle.)
    /// - `failed`: the staged files are KEPT. The step that broke (`ditto`,
    ///   `swap`, or `python3`) is about this Mac at that moment, not the
    ///   bytes, so the next check re-stages them without a download and the
    ///   next install tries again. Without python3, `launchSwapHelper` refuses
    ///   up front and the install takes the Finder fallback instead.
    ///
    /// A line naming a version this app already is (or is newer than) is stale
    /// — that update arrived after all — and says nothing; it is removed all
    /// the same, as is a line that does not parse.
    @discardableResult
    func reportInstallStatus(in updatesDirectory: URL) -> InstallStatus? {
        guard let status = InstallStatus.consume(in: updatesDirectory) else { return nil }
        if case .refused(let version) = status {
            UpdateInstaller.discardRefusedArchive(
                zip: updatesDirectory.appendingPathComponent("Maugham-\(version).zip"),
                stageDir: updatesDirectory.appendingPathComponent("staged-\(version)", isDirectory: true))
        }
        guard let reported = SemanticVersion(status.version),
              let current = SemanticVersion(currentVersionString),
              reported > current else { return nil }
        state = .installDidNotComplete(status)
        return status
    }

    /// The banner's Dismiss for an install notice: back to idle. A no-op in
    /// any other state, so a check that already replaced the notice stands.
    public func dismissInstallNotice() {
        if case .installDidNotComplete = state { state = .idle }
    }

    /// Set when a verified .app update is staged but the user dismissed the
    /// toast. On ordinary quit we apply it silently (no relaunch). See MaughamApp.
    public var pendingQuitInstall: (bundleURL: URL, version: String)?

    /// Apply a verified staged update: set state, then run the injected installer
    /// side-effect (set in Task 8). `relaunch` defaults true (explicit install).
    public func installNow(bundleURL: URL, version: String, relaunch: Bool = true) async {
        pendingQuitInstall = nil
        state = .installing(version: version)
        await UpdateChecker.performInstall?(bundleURL, version, relaunch)
    }

    /// Injected real installer side-effect (set in Task 8). Nil in tests.
    /// Set once at app startup (MaughamApp's Window .task runs once per window
    /// appearance). Production-only; unit tests reset it to nil in setUp/tearDown.
    /// Arguments: the staged bundle, its version, and whether to relaunch.
    @MainActor public static var performInstall: ((URL, String, Bool) async -> Void)?

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
}
