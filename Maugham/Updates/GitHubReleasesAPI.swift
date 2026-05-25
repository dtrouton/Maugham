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
        do {
            return try GitHubRelease.decode(from: data)
        } catch {
            throw Error.unparseable
        }
    }
}
