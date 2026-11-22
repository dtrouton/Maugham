import Foundation
import Observation
import MaughamCore
import os

private let _readThroughLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "ReadThrough")

/// **The pieces in read-through on this Mac** — one set of piece ids, each with
/// the moment it started, held on `ProjectSession` so every window on the
/// project shares it.
///
/// **Per device, never synced** (tripwires 17, 24): the file is
/// `.maugham/read-through.<deviceSlug>.json`, and nothing reads another
/// device's. Another Mac or the phone does not know a piece is in read-through;
/// the checkpoint taken at the start protects the version everywhere.
///
/// **Every change is written at once** — atomic, no debounce — so a ⌘Q right
/// after Start still remembers. A failed write says so once, as a notice. A
/// missing file reads as empty; an unreadable one reads as empty, is logged,
/// and is left as it is until the next change rewrites it (tripwire 11: no
/// migration, and no repair nobody asked for).
@MainActor @Observable
final class ReadThroughStore {
    /// Piece id → when its read-through started.
    private(set) var pieces: [String: Date] = [:]

    /// The ids alone — what `ReadThrough.isOn` and the gate ask.
    var pieceIds: Set<String> { Set(pieces.keys) }

    @ObservationIgnored private let projectRoot: URL
    @ObservationIgnored private let device: DeviceSlug

    init(projectRoot: URL, device: DeviceSlug) {
        self.projectRoot = projectRoot
        self.device = device
        pieces = Self.read(Self.fileURL(projectRoot: projectRoot, device: device))
    }

    /// `.maugham/read-through.<slug>.json`. `.raw` is interpolated only here
    /// (tripwire 24).
    static func fileURL(projectRoot: URL, device: DeviceSlug) -> URL {
        projectRoot.appendingPathComponent(".maugham/read-through.\(device.raw).json") // local-path: this device's own slug
    }

    /// Puts `pieceId` into read-through, started `at`. A piece already in
    /// read-through keeps its first start and writes nothing.
    func begin(_ pieceId: String, at: Date) {
        guard pieces[pieceId] == nil else { return }
        pieces[pieceId] = at
        persist()
    }

    /// Takes `pieceId` out of read-through. A piece not in it writes nothing.
    func end(_ pieceId: String) {
        guard pieces.removeValue(forKey: pieceId) != nil else { return }
        persist()
    }

    /// Forgets every piece not in `eligible` — a deleted, trashed or promoted
    /// piece has left the structure; a renamed or moved one keeps its id.
    func prune(keeping eligible: Set<String>) {
        let gone = pieces.keys.filter { !eligible.contains($0) }
        guard !gone.isEmpty else { return }
        for id in gone { pieces.removeValue(forKey: id) }
        persist()
    }

    // MARK: - The file

    private struct File: Codable {
        let pieces: [String: Date]
    }

    private static func read(_ url: URL) -> [String: Date] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url) // adr-0018-ok: read-through sidecar, derived, not manuscript
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(File.self, from: data).pieces
        } catch {
            _readThroughLog.error(
                "read-through file unreadable, read as empty: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    private func persist() {
        let url = Self.fileURL(projectRoot: projectRoot, device: device)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(File(pieces: pieces)).write(to: url, options: .atomic)
        } catch {
            MaughamEvent.postNotice(
                "Couldn’t remember the read-through on this Mac — \(error.localizedDescription)",
                projectURL: projectRoot)
        }
    }
}
