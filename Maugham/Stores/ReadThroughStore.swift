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
/// **Per device; no other device reads it** (tripwires 17, 24): the file is
/// `.maugham/read-through.<deviceSlug>.json`. In an iCloud project the file
/// travels with the folder, but its name carries this device's slug and
/// nothing reads another device's, so another Mac or the phone does not know a
/// piece is in read-through. The checkpoint taken at the start protects the
/// version everywhere.
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

    /// The ids alone — what `ReadThrough.isOn` and the gate ask. Stored, and
    /// kept equal to `pieces.keys` by every writer, so a body pass reads it
    /// without building a set.
    private(set) var pieceIds: Set<String> = []

    /// Piece id → the id of the checkpoint its read-through took. A piece in
    /// read-through with no entry here has no checkpoint yet (a refused or
    /// failed capture, or a ⌘Q before it landed), and Start takes it.
    private(set) var checkpoints: [String: String] = [:]

    /// The pieces whose Start is capturing right now, so a second Start in the
    /// same moment does not take a second checkpoint. Never persisted.
    /// Observed, so the line over the text says "no checkpoint was saved" only
    /// once a capture has ended without one.
    private var capturing: Set<String> = []

    /// **The pieces in read-through whose checkpoint was not saved** — a
    /// refused or failed capture, or a ⌘Q before it landed — and none is being
    /// taken now. The line over the text offers Save one for these.
    var piecesLackingCheckpoint: Set<String> {
        Set(pieces.keys.filter { checkpoints[$0] == nil && !capturing.contains($0) })
    }

    /// **Who hears each change of the set** (`begin`, `end`, `prune`): the
    /// session's figure windows, which ask their gates again. A list, so a
    /// second subscriber never silently replaces the first.
    @ObservationIgnored private var changeObservers: [@MainActor () -> Void] = []

    /// Adds `observer` to those told after each change of the set.
    func addChangeObserver(_ observer: @escaping @MainActor () -> Void) {
        changeObservers.append(observer)
    }

    private func changed() {
        for observer in changeObservers { observer() }
    }

    @ObservationIgnored private let projectRoot: URL
    @ObservationIgnored private let device: DeviceSlug

    init(projectRoot: URL, device: DeviceSlug) {
        self.projectRoot = projectRoot
        self.device = device
        let file = Self.read(Self.fileURL(projectRoot: projectRoot, device: device))
        pieces = file.pieces
        pieceIds = Set(file.pieces.keys)
        checkpoints = (file.checkpoints ?? [:]).filter { file.pieces[$0.key] != nil }
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
        pieceIds.insert(pieceId)
        persist()
        changed()
    }

    /// Takes `pieceId` out of read-through. A piece not in it writes nothing.
    func end(_ pieceId: String) {
        guard pieces.removeValue(forKey: pieceId) != nil else { return }
        pieceIds.remove(pieceId)
        checkpoints.removeValue(forKey: pieceId)
        persist()
        changed()
    }

    /// Records the checkpoint `pieceId`'s read-through took. Nothing for a
    /// piece no longer in read-through (Resume landed first).
    func recordCheckpoint(_ checkpointId: String, for pieceId: String) {
        guard pieces[pieceId] != nil, checkpoints[pieceId] != checkpointId else { return }
        checkpoints[pieceId] = checkpointId
        persist()
    }

    /// Whether `pieceId`'s read-through has its checkpoint.
    func hasCheckpoint(_ pieceId: String) -> Bool { checkpoints[pieceId] != nil }

    /// Marks a Start's capture as running; false when one already is.
    func beginCapturing(_ pieceId: String) -> Bool {
        capturing.insert(pieceId).inserted
    }

    func endCapturing(_ pieceId: String) { capturing.remove(pieceId) }

    /// Forgets every piece not in `eligible` — a deleted, trashed or promoted
    /// piece has left the structure; a renamed or moved one keeps its id.
    func prune(keeping eligible: Set<String>) {
        let gone = pieces.keys.filter { !eligible.contains($0) }
        guard !gone.isEmpty else { return }
        for id in gone {
            pieces.removeValue(forKey: id)
            pieceIds.remove(id)
            checkpoints.removeValue(forKey: id)
        }
        persist()
        changed()
    }

    // MARK: - The file

    private struct File: Codable {
        let pieces: [String: Date]
        /// Optional, so a file written before it existed still reads.
        let checkpoints: [String: String]?
    }

    private static func read(_ url: URL) -> File {
        let empty = File(pieces: [:], checkpoints: nil)
        guard FileManager.default.fileExists(atPath: url.path) else { return empty }
        do {
            let data = try Data(contentsOf: url) // adr-0018-ok: read-through sidecar, derived, not manuscript
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(File.self, from: data)
        } catch {
            _readThroughLog.error(
                "read-through file unreadable, read as empty: \(error.localizedDescription, privacy: .public)")
            return empty
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
            try encoder.encode(File(pieces: pieces, checkpoints: checkpoints))
                .write(to: url, options: .atomic)
        } catch {
            MaughamEvent.postNotice(
                "Couldn’t remember the read-through on this Mac — \(error.localizedDescription)",
                projectURL: projectRoot)
        }
    }
}
