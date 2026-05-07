import Foundation
import SwiftUI

public enum ProjectStoreError: Error, Equatable {
    case manifestNotFound
    case manifestUnreadable(String)
    case manuscriptUnreadable(String)
    case manuscriptUnwritable(String)
    case manifestUnwritable(String)
    case structureMissing
}

/// Manages an open Maugham project: its manifest plus its manuscript text.
/// Phase 1a supports Short Story projects only (single manuscript file).
@MainActor
@Observable
public final class ProjectStore {
    public let url: URL
    public private(set) var manifest: ProjectManifest
    public var manuscriptText: String

    private static let manifestFilename = "project.maugham.json"

    private init(url: URL, manifest: ProjectManifest, manuscriptText: String) {
        self.url = url
        self.manifest = manifest
        self.manuscriptText = manuscriptText
    }

    /// Load a project from disk by URL.
    public static func load(from url: URL) async throws -> ProjectStore {
        let manifestURL = url.appendingPathComponent(manifestFilename)
        let fm = FileManager.default

        guard fm.fileExists(atPath: manifestURL.path) else {
            throw ProjectStoreError.manifestNotFound
        }

        let manifest: ProjectManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(ProjectManifest.self, from: data)
        } catch {
            throw ProjectStoreError.manifestUnreadable(error.localizedDescription)
        }

        let manuscriptText = try Self.readManuscript(for: manifest, at: url)

        return ProjectStore(url: url, manifest: manifest,
                            manuscriptText: manuscriptText)
    }

    private static func readManuscript(
        for manifest: ProjectManifest, at projectURL: URL
    ) throws -> String {
        guard let docPath = manifest.structure.first(where: { $0.type == .document })?.path else {
            return ""
        }
        let manuscriptURL = projectURL.appendingPathComponent(docPath)
        guard FileManager.default.fileExists(atPath: manuscriptURL.path) else {
            return ""
        }
        do {
            return try String(contentsOf: manuscriptURL, encoding: .utf8)
        } catch {
            throw ProjectStoreError.manuscriptUnreadable(error.localizedDescription)
        }
    }

    /// Persist the current manuscript text and an updated `modified` timestamp.
    /// Manifest write is atomic via temp-file + rename. Manuscript write is
    /// non-atomic in 1a; NSFileCoordinator integration arrives in milestone 1e.
    public func save() async throws {
        // Write manuscript first; if it fails we don't bump the manifest.
        guard let docPath = manifest.structure.first(where: { $0.type == .document })?.path else {
            throw ProjectStoreError.structureMissing
        }
        let manuscriptURL = url.appendingPathComponent(docPath)
        do {
            try manuscriptText.write(to: manuscriptURL, atomically: true, encoding: .utf8)
        } catch {
            throw ProjectStoreError.manuscriptUnwritable(error.localizedDescription)
        }

        // Bump modified and write manifest atomically.
        // Round to whole seconds so the in-memory value matches what ISO-8601
        // (second precision) will round-trip back from disk.
        manifest.modified = Date(timeIntervalSinceReferenceDate:
            (Date().timeIntervalSinceReferenceDate).rounded())
        let manifestURL = url.appendingPathComponent(Self.manifestFilename)
        let tmpURL = url.appendingPathComponent(Self.manifestFilename + ".tmp")

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(to: tmpURL)
            _ = try FileManager.default.replaceItemAt(manifestURL, withItemAt: tmpURL)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw ProjectStoreError.manifestUnwritable(error.localizedDescription)
        }
    }
}
