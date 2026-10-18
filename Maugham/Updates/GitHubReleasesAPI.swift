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
    public let draft: Bool
    public let prerelease: Bool

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, assets, draft, prerelease
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try c.decode(String.self, forKey: .tagName)
        name = try c.decode(String.self, forKey: .name)
        body = try c.decode(String.self, forKey: .body)
        assets = try c.decode([Asset].self, forKey: .assets)
        // Older fixtures / minimal payloads omit these; default to a shippable release.
        draft = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        prerelease = try c.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
    }

    /// True only for a stable Mac release: tag parses as a plain `X.Y.Z`
    /// SemanticVersion (which excludes `phone-v*` tags — `Int("phone-v0")`
    /// fails) and it isn't a draft or prerelease.
    public var semanticVersion: SemanticVersion? {
        SemanticVersion(tagName)
    }

    fileprivate var isSelectableMacRelease: Bool {
        !draft && !prerelease && semanticVersion != nil
    }

    public var dmgAsset: Asset? {
        assets.first { $0.name.hasSuffix(".dmg") }
    }

    public var zipAsset: Asset? {
        assets.first { $0.name.hasSuffix(".zip") }
    }

    public static func decode(from data: Data) throws -> GitHubRelease {
        try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    public static func decodeList(from data: Data) throws -> [GitHubRelease] {
        try JSONDecoder().decode([GitHubRelease].self, from: data)
    }
}

public enum GitHubReleasesAPI {
    public enum Error: Swift.Error, LocalizedError {
        case http(status: Int)
        case noInstallableAsset
        case noMacRelease
        case unparseable
        /// The asset's download URL is not this repo's own release URL for
        /// that tag and name (see `isTrustedAssetURL`).
        case untrustedAssetURL

        public var errorDescription: String? {
            switch self {
            case .http(let s): return "GitHub returned HTTP \(s)"
            case .noInstallableAsset: return "Release has no installable asset"
            case .noMacRelease: return "No Mac release found"
            case .unparseable: return "Couldn't parse GitHub's response"
            case .untrustedAssetURL: return "The update's download link isn't Maugham's own release on GitHub"
            }
        }
    }

    /// The repository every release, and every update archive, comes from.
    public static let owner = "dtrouton"
    public static let repo = "Maugham"

    /// The one URL shape an update archive may be requested from:
    /// `https://github.com/<owner>/<repo>/releases/download/<tag>/<asset.name>`,
    /// exactly — https, the host `github.com` with no port, user or password,
    /// no query or fragment, and a path naming this repo, this release's tag
    /// and this asset's own name. Checked on the URL we REQUEST; GitHub then
    /// redirects to its asset CDN, whose host is deliberately not allow-listed
    /// (it changed in 2025, and TLS plus the signature chain gate the bytes) —
    /// `UpdateDownloadSession` refuses only a non-https redirect. For a
    /// zip-less release the `.dmg` is not verified in-app at all, so for it
    /// this check is the only in-app gate.
    public static func isTrustedAssetURL(
        _ url: URL,
        for asset: GitHubRelease.Asset,
        tag: String,
        owner: String = GitHubReleasesAPI.owner,
        repo: String = GitHubReleasesAPI.repo
    ) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com",
              components.port == nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return false }
        return components.path == "/\(owner)/\(repo)/releases/download/\(tag)/\(asset.name)"
    }

    /// The highest stable **Mac** release in a `/releases` list. We must NOT use
    /// GitHub's `/releases/latest`, which returns the most-recently-*published*
    /// release across ALL tags — a `phone-v*` tag cut minutes after the Mac
    /// release wins there, and its tag can't be parsed as a Mac version
    /// (`SemanticVersion("phone-v0.7.0")` is nil). Filter to selectable Mac
    /// releases and take the max by version.
    public static func latestMacRelease(from releases: [GitHubRelease]) -> GitHubRelease? {
        releases
            .filter { $0.isSelectableMacRelease }
            .max { ($0.semanticVersion!) < ($1.semanticVersion!) }
    }

    public static func fetchLatestRelease(
        owner: String = GitHubReleasesAPI.owner,
        repo: String = GitHubReleasesAPI.repo,
        session: URLSession = .shared
    ) async throws -> GitHubRelease {
        // The full list (not `/releases/latest`) — see `latestMacRelease` for why.
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=30")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Always fetch fresh — without this the URLSession URLCache holds
        // the first response for the lifetime of the app session, so
        // "Check for Updates" mid-session returns the stale "you're up
        // to date" answer even though CI has published a newer release.
        // The background 24h poll already throttles request volume; we
        // don't need URLCache piling on. Belt-and-braces: send the HTTP
        // no-cache header AND set the URLRequest cache policy so any
        // intermediate CDN revalidates.
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Error.http(status: http.statusCode)
        }
        let releases: [GitHubRelease]
        do {
            releases = try GitHubRelease.decodeList(from: data)
        } catch {
            throw Error.unparseable
        }
        guard let mac = latestMacRelease(from: releases) else {
            throw Error.noMacRelease
        }
        return mac
    }
}
