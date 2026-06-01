// Maugham/Updates/UpdateChecker.swift
import Foundation
import MaughamCore
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
        downloadAsset: UpdateChecker.defaultDownload,
        stageAndVerify: UpdateChecker.defaultStageAndVerify)

    private let currentVersionString: String
    private let fetchLatest: () async throws -> GitHubRelease
    private let downloadAsset: (URL, String) async throws -> URL
    private let stageAndVerify: (URL, String) async throws -> URL

    public init(
        currentVersionString: String,
        fetchLatest: @escaping () async throws -> GitHubRelease,
        downloadAsset: @escaping (URL, String) async throws -> URL,
        stageAndVerify: @escaping (URL, String) async throws -> URL
    ) {
        self.currentVersionString = currentVersionString
        self.fetchLatest = fetchLatest
        self.downloadAsset = downloadAsset
        self.stageAndVerify = stageAndVerify
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
            guard let asset = release.zipAsset ?? release.dmgAsset else {
                state = trigger == .manual
                    ? .error(GitHubReleasesAPI.Error.noInstallableAsset.localizedDescription)
                    : .idle
                return
            }
            state = .downloading(version: newVersion.string, progress: 0)
            let downloaded = try await downloadAsset(asset.browserDownloadURL, newVersion.string)
            let stagedBundle = try await stageAndVerify(downloaded, newVersion.string)
            state = .readyToInstall(bundleURL: stagedBundle,
                                    version: newVersion.string,
                                    releaseNotes: release.body)
            if stagedBundle.pathExtension == "app" {
                pendingQuitInstall = (stagedBundle, newVersion.string)
            }
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
        let ext = url.pathExtension.isEmpty ? "zip" : url.pathExtension
        let target = stagingDir.appendingPathComponent("Maugham-\(version).\(ext)")
        if FileManager.default.fileExists(atPath: target.path) { return target }

        let (tmpURL, _) = try await URLSession.shared.download(from: url)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: tmpURL, to: target)
        return target
    }

    /// Real staging: unzip + verify a `.zip` payload; a `.dmg` (zip-less fallback
    /// release) passes through unchanged (it can't be swapped in place — the
    /// installer's Finder fallback handles it).
    private static func defaultStageAndVerify(_ downloaded: URL, _ version: String) async throws -> URL {
        if downloaded.pathExtension == "dmg" { return downloaded }
        return try await UpdateInstaller.stageAndVerify(zip: downloaded, version: version)
    }

    /// Set when a verified .app update is staged but the user dismissed the
    /// toast. On ordinary quit we apply it silently (no relaunch). See MaughamApp.
    public var pendingQuitInstall: (bundleURL: URL, version: String)?

    /// Apply a verified staged update: set state, then run the injected installer
    /// side-effect (set in Task 8). `relaunch` defaults true (explicit install).
    public func installNow(bundleURL: URL, version: String, relaunch: Bool = true) async {
        pendingQuitInstall = nil
        state = .installing(version: version)
        await UpdateChecker.performInstall?(bundleURL, relaunch)
    }

    /// Injected real installer side-effect (set in Task 8). Nil in tests.
    /// Set once at app startup (MaughamApp's Window .task runs once per window
    /// appearance). Production-only; unit tests reset it to nil in setUp/tearDown.
    @MainActor public static var performInstall: ((URL, Bool) async -> Void)?

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
