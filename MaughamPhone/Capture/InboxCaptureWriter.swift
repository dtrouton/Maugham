import Foundation
import MaughamCore

/// Phone-side writer that lands a capture in a project's `.maugham/inbox/`,
/// producing bytes byte-for-byte compatible with the Mac's `InboxStore` reader.
///
/// The Mac reads the manifest via `JSONLAppendStore<InboxEntry>`, so we encode
/// each row with the SAME date strategy (`JSONLAppendStore.dateEncoding`,
/// ISO8601-with-fractional-seconds) and the SAME snake_case `CodingKeys` the
/// model already defines. The manifest is the per-device stream
/// `inbox/inbox.<deviceSlug>.jsonl` (ADR 0012 partitioning — the phone only ever
/// appends to its own file; the Mac globs siblings and merges last-wins).
///
/// Unlike the Mac (which has an `NSFilePresenter`), the phone registers no
/// presenter, so every write funnels through `CoordinatedFileIO`'s plain
/// coordinate-write primitives — the same `NSFileCoordinator` cooperation that
/// lets the two sides share files through iCloud Drive.
struct InboxCaptureWriter {
    let projectRoot: URL
    let deviceId: String
    var io: CoordinatedFileIO = .live
    /// Injectable clock so tests can pin `createdAt`/`writtenAt` deterministically.
    var now: () -> Date = { Date() }

    init(
        projectRoot: URL,
        deviceId: String,
        io: CoordinatedFileIO = .live,
        now: @escaping () -> Date = { Date() }
    ) {
        self.projectRoot = projectRoot
        self.deviceId = deviceId
        self.io = io
        self.now = now
    }

    // MARK: - Paths

    private var inboxDir: URL {
        projectRoot.appendingPathComponent(".maugham/inbox", isDirectory: true)
    }

    /// This device's own manifest stream. Matches the Mac's `ownManifestURL`.
    private var manifestURL: URL {
        InboxManifest.inboxManifestURL(forDeviceSlug: DeviceSlug.make(from: deviceId),
                                       in: projectRoot)
    }

    /// Resolves via `InboxConvention` (MaughamCore) — the single source of
    /// truth shared with the Mac reader's asset lookup (E5a).
    private var imagesDir: URL {
        InboxConvention.assetDir(for: .image, inboxDir: inboxDir) ?? inboxDir
    }

    private var audioDir: URL {
        InboxConvention.assetDir(for: .audio, inboxDir: inboxDir) ?? inboxDir
    }

    // MARK: - Entry assembly (pure, testable)

    /// Assemble the `InboxEntry` for a capture: mints a fresh ULID id,
    /// `createdAt = now()`, status `.new`, and a monotonic `writtenAt`.
    ///
    /// Tripwire 17: `writtenAt = max(now, createdAt + 1ms)`. For a fresh create
    /// (`createdAt == now`) that lands at `now + 1ms`, strictly after `createdAt`,
    /// which keeps the cross-device last-wins merge stable under clock skew — a
    /// later Mac transition (e.g. a Whisper transcript) can always out-rank the
    /// original create row, and the worker won't re-transcribe forever.
    func buildEntry(
        kind: InboxEntry.Kind,
        sourceFilename: String? = nil,
        inlineText: String? = nil,
        transcript: String? = nil,
        transcriptionState: InboxEntry.TranscriptionState = .none,
        title: String? = nil,
        paletteSubject: String? = nil,
        sense: String? = nil
    ) -> InboxEntry {
        let createdAt = now()
        let writtenAt = max(createdAt, createdAt.addingTimeInterval(0.001))
        return InboxEntry(
            id: ULID.generate(),
            createdAt: createdAt,
            writtenAt: writtenAt,
            deviceId: deviceId,
            kind: kind,
            sourceFilename: sourceFilename,
            inlineText: inlineText,
            transcript: transcript,
            transcriptionState: transcriptionState,
            title: title,
            status: .new,
            resolvedAt: nil,
            paletteSubject: paletteSubject,
            sense: sense
        )
    }

    // MARK: - Writes

    /// Text capture: inline only, no asset file. Appends one manifest row.
    @discardableResult
    func writeText(
        _ text: String,
        title: String? = nil,
        paletteSubject: String? = nil,
        sense: String? = nil
    ) async throws -> InboxEntry {
        let entry = buildEntry(kind: .text, inlineText: text, title: title, paletteSubject: paletteSubject, sense: sense)
        try appendManifest(entry)
        return entry
    }

    /// Image capture: writes the bytes to `inbox/images/<id>.<ext>`, then appends
    /// a manifest row whose `sourceFilename` is exactly `<id>.<ext>` — the asset
    /// filename and `entry.id` share the one ULID so the Mac can locate the asset.
    @discardableResult
    func writeImage(
        _ data: Data,
        ext: String,
        title: String? = nil,
        paletteSubject: String? = nil,
        sense: String? = nil
    ) async throws -> InboxEntry {
        let entry = buildEntry(kind: .image, title: title, paletteSubject: paletteSubject, sense: sense)
        let assetName = "\(entry.id).\(ext)"
        try io.ensureDirectory(at: imagesDir)
        let assetURL = imagesDir.appendingPathComponent(assetName)
        try io.coordinatedWrite(at: assetURL) { url in
            try data.write(to: url)
        }
        // Re-stamp sourceFilename now that the asset is on disk; everything else
        // (id, timestamps) is fixed from buildEntry.
        var withAsset = entry
        withAsset.sourceFilename = assetName
        try appendManifest(withAsset)
        return withAsset
    }

    /// Audio capture: COPIES the recorded `.m4a` at `tempURL` into
    /// `inbox/audio/<id>.m4a`, then appends a manifest row. A non-nil
    /// `transcriptDraft` marks the entry `.onDeviceDraft` (a phone-side draft the
    /// Mac's worker may refine); nil leaves it `.none`.
    ///
    /// The writer does NOT delete `tempURL` — it can't own the recorder's
    /// scratch. The caller is responsible for cleaning up the temp recording
    /// after a successful (or discarded) capture.
    @discardableResult
    func writeAudio(
        from tempURL: URL,
        transcriptDraft: String?,
        title: String? = nil,
        paletteSubject: String? = nil,
        sense: String? = nil
    ) async throws -> InboxEntry {
        let entry = buildEntry(
            kind: .audio,
            transcript: transcriptDraft,
            transcriptionState: transcriptDraft == nil ? .none : .onDeviceDraft,
            title: title,
            paletteSubject: paletteSubject,
            sense: sense
        )
        let assetName = "\(entry.id).m4a"
        try io.ensureDirectory(at: audioDir)
        let destURL = audioDir.appendingPathComponent(assetName)
        // Read the temp recording and write it into the coordinated destination.
        // Reading first (outside coordination) is fine: the temp file is the
        // phone's own scratch, not a shared iCloud path.
        let bytes = try Data(contentsOf: tempURL)  // adr-0018-ok: phone's own temp recording (scratch), not manuscript
        try io.coordinatedWrite(at: destURL) { url in
            try bytes.write(to: url)
        }
        var withAsset = entry
        withAsset.sourceFilename = assetName
        try appendManifest(withAsset)
        return withAsset
    }

    // MARK: - Encoding / append

    /// Append one entry as a JSONL row to this device's manifest, coordinated.
    /// `coordinatedAppendLine` creates intermediate dirs + the file on first use.
    private func appendManifest(_ entry: InboxEntry) throws {
        let line = try encode(entry)
        try io.coordinatedAppendLine(line, to: manifestURL)
    }

    /// Encode a row with the Mac reader's exact date strategy so the bytes decode
    /// losslessly through `JSONLAppendStore<InboxEntry>` on the Mac.
    private func encode(_ entry: InboxEntry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = JSONLAppendStore<InboxEntry>.dateEncoding
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(entry)
    }
}
