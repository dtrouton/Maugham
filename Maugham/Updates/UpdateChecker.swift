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
