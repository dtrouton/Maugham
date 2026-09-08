import Foundation
import MaughamCore

/// Phone-side writer that lands a capture in a project's `.maugham/inbox/`,
/// producing bytes byte-for-byte compatible with the Mac's `InboxStore` reader.
///
/// The Mac reads the manifest via `JSONLAppendStore<InboxEntry>` and the phone
/// now WRITES it through the same store, so the date strategy
/// (ISO8601-with-fractional-seconds), the snake_case `CodingKeys` and the
/// chaining are one implementation rather than two that agree today. The
/// manifest is the per-device stream
/// `inbox/inbox.<deviceSlug>.jsonl` (ADR 0012 partitioning — the phone only ever
/// appends to its own file; the Mac globs siblings and merges last-wins).
///
/// The ASSET writes are the phone's own: no presenter, so they funnel through
/// `CoordinatedFileIO`'s plain coordinate-write primitives — the same
/// `NSFileCoordinator` cooperation that lets the two sides share files through
/// iCloud Drive. The MANIFEST goes through `JSONLAppendStore` instead, because
/// a manifest row is chained history (spec §4): it links to the head this
/// phone verified, a run of lines the phone did not write is set aside before
/// anything is appended after them, and a seal signs each capture on the spot.
/// One store, one chain, both surfaces — the Mac's `InboxStore` writes the same
/// bytes into its own stream (tripwire 19).
///
/// **Nonisolated, and deliberately.** `JSONLAppendStore` is `@MainActor`, and
/// making the whole writer `@MainActor` to reach it took the ASSET writes with
/// it — `writeImage`'s and `writeAudio`'s coordinated `Data.write` of a whole
/// photograph or a whole `.m4a`, inside an `NSFileCoordinator` claim against an
/// iCloud Drive path, on the phone's one interaction that must never hitch (the
/// whole-branch review's I4). Only the MANIFEST hops, and it hops ONCE for the
/// row and its seal together, so an accept and the signature over it cannot be
/// interleaved by anything else on the main actor.
struct InboxCaptureWriter: Sendable {
    let projectRoot: URL
    /// This phone, as the chain names it: the key that signs a capture's seal,
    /// and the id every row and the manifest's own filename are derived from.
    /// Injectable so a test can hold a signing key on a simulator, which has no
    /// enclave of its own.
    let identity: DeviceIdentity
    var io: CoordinatedFileIO = .live
    /// Injectable clock so tests can pin `createdAt`/`writtenAt` deterministically.
    var now: @Sendable () -> Date = { Date() }

    /// The row's `device_id`, and the slug its manifest is named for. Derived
    /// from the identity rather than passed beside it: two spellings of this
    /// phone's name is one rename away from a row filed under a device whose
    /// key never signed it.
    var deviceId: String { identity.deviceId }

    init(
        projectRoot: URL,
        identity: DeviceIdentity = .author,
        io: CoordinatedFileIO = .live,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.projectRoot = projectRoot
        self.identity = identity
        self.io = io
        self.now = now
    }

    // MARK: - Paths

    private var inboxDir: URL {
        projectRoot.appendingPathComponent(".maugham/inbox", isDirectory: true)
    }

    /// This device's own manifest stream. Matches the Mac's `ownManifestURL`.
    private var manifestURL: URL {
        InboxManifest.inboxManifestURL(forDeviceSlug: identity.slug, in: projectRoot)
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
        title: String? = nil
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
            resolvedAt: nil
            // No palette aim. It went with the phone's aim picker (signed op
            // log P1), and the two fields are not named here at all — both
            // default to nil, so a capture this writer lands carries none, and
            // `TripwirePhoneGrepTest.test_noPaletteAimWriterOnThePhone` can say
            // there is NO writer on the phone rather than one that happens to
            // pass nil. The fields stay on `InboxEntry` for rows already on
            // disk, which the Mac's Inbox pane still reads.
        )
    }

    // MARK: - Writes

    /// Text capture: inline only, no asset file. Appends one manifest row.
    @discardableResult
    func writeText(
        _ text: String,
        title: String? = nil
    ) async throws -> InboxEntry {
        let entry = buildEntry(kind: .text, inlineText: text, title: title)
        try await appendManifest(entry)
        return entry
    }

    /// Image capture: writes the bytes to `inbox/images/<id>.<ext>`, then appends
    /// a manifest row whose `sourceFilename` is exactly `<id>.<ext>` — the asset
    /// filename and `entry.id` share the one ULID so the Mac can locate the asset.
    @discardableResult
    func writeImage(
        _ data: Data,
        ext: String,
        title: String? = nil
    ) async throws -> InboxEntry {
        let entry = buildEntry(kind: .image, title: title)
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
        try await appendManifest(withAsset)
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
        title: String? = nil
    ) async throws -> InboxEntry {
        let entry = buildEntry(
            kind: .audio,
            transcript: transcriptDraft,
            transcriptionState: transcriptDraft == nil ? .none : .onDeviceDraft,
            title: title
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
        try await appendManifest(withAsset)
        return withAsset
    }

    // MARK: - Append

    /// Append one entry as a chained JSONL row to this device's manifest, then
    /// seal it. The store creates intermediate directories and the file itself
    /// on first use, and it — not this writer — owns the encoding, so the bytes
    /// the phone writes are by construction the bytes the Mac reads.
    ///
    /// The seal is per capture. Captures are rare, so one signature each is a
    /// cost nobody feels, and no capture ever sits in the tail merely chained.
    /// A phone with no key writes no seal, appends its row anyway, and reports
    /// nothing wrong — being unsigned is a state, not a failure (spec §4.1).
    private func appendManifest(_ entry: InboxEntry) async throws {
        try await Self.appendChained(
            entry, to: manifestURL, identity: identity, projectRoot: projectRoot)
    }

    /// The one main-actor hop, doing the row and its seal inside it. Two hops
    /// would let anything else on the main actor land between a capture and the
    /// signature over it.
    @MainActor
    private static func appendChained(
        _ entry: InboxEntry, to url: URL,
        identity: DeviceIdentity, projectRoot: URL
    ) async throws {
        let store = JSONLAppendStore<InboxEntry>(
            fileURL: url,
            chain: ChainPolicy(
                identity: identity, state: .shared,
                docId: InboxManifest.chainDocId, projectURL: projectRoot))
        try await store.append(entry)
        try await store.appendSeal()
    }
}
