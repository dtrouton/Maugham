// Packages/MaughamCore/Sources/MaughamCore/SegmentSealer.swift
import CryptoKit
import Foundation

/// One device's signature over a sealed segment's digest, written beside the
/// segment as `<name>.mzseg.sig`.
///
/// **Why beside rather than inside.** A `.mzseg` is immutable bytes whose
/// checksum is part of its own header; signing it in place would mean rewriting
/// it, and a segment that can be rewritten is not sealed. The signature is
/// therefore a sidecar, and losing it costs exactly what losing any derived
/// file costs: the segment reads as unsigned history, which is honest.
///
/// **Why over the digest.** The segment already commits to every one of its
/// bytes through the SHA-256 in its header, so signing those 32 bytes signs the
/// whole segment — one signature per segment instead of one per line, and the
/// verification is a single P256 check however long the history is. It is the
/// same three fields a seal line carries (`OpLogChain.Seal`) over a different
/// digest, and it goes through the same credential helpers so the two shapes
/// cannot drift apart.
public struct SegmentSignature: Codable, Equatable, Sendable {
    /// The segment's own uncompressed-content digest, 64 hex characters.
    public let digest: String
    /// The signing key's fingerprint (`DeviceIdentity.fingerprint(of:)`).
    public let key: String
    /// Base64 of the public key's X9.63 representation.
    public let pub: String
    /// Base64 of the 64-byte raw P256 signature over the digest's 32 bytes.
    public let sig: String
    public let at: Date

    public init(digest: String, key: String, pub: String, sig: String, at: Date) {
        self.digest = digest
        self.key = key
        self.pub = pub
        self.sig = sig
        self.at = at
    }

    /// Sign `digest` with `identity`. Throws `DeviceIdentityError.unsigned` on a
    /// device with no key — a condition, not a failure.
    public static func make(
        digest: String, identity: DeviceIdentity, at: Date = Date()
    ) throws -> SegmentSignature {
        let credentials = try OpLogChain.credentials(signing: digest, identity: identity)
        return SegmentSignature(
            digest: digest, key: credentials.key,
            pub: credentials.pub, sig: credentials.sig, at: at)
    }

    /// Does this signature hold together over the digest it names? Says nothing
    /// about whether the key is TRUSTED — that is the reader's question.
    public func verifies() -> Bool {
        OpLogChain.credentialsVerify(
            .init(key: key, pub: pub, sig: sig), over: digest)
    }

    /// The signature beside a segment, or nil when there is none to read. A
    /// missing or unreadable sidecar is never an error: it means the segment is
    /// unsigned history.
    public static func read(at url: URL) -> SegmentSignature? {
        guard let bytes = try? Data(contentsOf: url) else { return nil }  // adr-0018-ok: derived signature sidecar, never manuscript text
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = JSONLAppendStore<SegmentSignature>.dateDecoding
        return try? decoder.decode(SegmentSignature.self, from: bytes)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = JSONLAppendStore<SegmentSignature>.dateEncoding
        return try encoder.encode(self)
    }
}

/// **The segment seal: a device's own live tail rewritten into an immutable,
/// signed `.mzseg`** (ADR 0016, growth spec §5.2). Split out of `OpLogStore`
/// (foundations plan 6). The store keeps the door — `sealTailIfNeeded`, which
/// passes its project, presenter and identities in — and the CHAIN seal
/// (`sealChain`), which signs lines in place rather than rewriting the file.
/// CLAUDE.md tripwire 17: never the legacy unsuffixed file, never another
/// device's.
public enum SegmentSealer {
    /// Tail size above which a device's live per-doc file is sealed into an
    /// immutable compressed segment (ADR 0016 / growth spec §5.2). Default
    /// confirmed against the M0 baseline (spec §9.1).
    public nonisolated static let threshold = 512 * 1024

    /// Seal THIS device's live tail for `docId` into the next-numbered
    /// `.mzseg` segment, iff the tail exceeds `threshold` bytes. Returns the
    /// segment URL, or nil when nothing was sealed (missing/small/torn tail).
    /// Reached only through `OpLogStore.sealTailIfNeeded`; `@MainActor` is
    /// what keeps it on the same actor as every append (the NOTE below).
    ///
    /// Scope rules (enforced by tests T13/T14): only ever a tail belonging to
    /// one of THIS device's own actors — sealing is a rewrite of a
    /// single-writer file, the exact case ADR 0012 makes conflict-twin-free.
    /// NEVER the legacy unsuffixed `<docId>.jsonl` (no unambiguous owner;
    /// frozen since ADR 0012), and never another device's file. The synthetic
    /// `__project__` stream is not an exception: it rotates at this same
    /// threshold (Denver, 2026-09-09 — one constant, not two).
    ///
    /// **Its two callers, and why each is inside that rule** (the whole-branch
    /// review's I3). `Document.close()` rotates the tail of the actor that
    /// Document was LOADED as, and no other: an MCP call is a Document loaded
    /// as the assistant, and a close that swept all four would delete the file
    /// the writer's own open Document is appending to. The project-open sweep
    /// in `DocumentStore.open` is the one place every local actor rotates, and
    /// it is safe there for two reasons that do not hold at close — all four
    /// slugs name this device's own actors, and the sweep is awaited before the
    /// first `Document.load`, so no live appender exists to race the
    /// read→delete gap the note below reasons about. That sweep is also the
    /// project stream's ONLY boundary: `__project__` has no close to rotate at,
    /// so open is its moment.
    ///
    /// Crash safety is by construction, not by care: dying between the
    /// segment write and the tail delete leaves the same ops in both files —
    /// `mergeSortedDedup` collapses them by opId, and the next seal converges
    /// (the still-oversized tail becomes the next segment). A half-written
    /// temp file is ignored forever (wrong extension, never renamed).
    ///
    /// Coordinator policy: a fresh `NSFileCoordinator` for the read and another
    /// for the delete, matching `JSONLAppendStore` (one coordinator per file
    /// operation, never reused across operations). The unprotected gap between
    /// them is exactly the crash window the dedupe/converge contract already
    /// covers, so a single long-held coordinator would buy nothing.
    ///
    /// NOTE the dedupe/converge contract covers the CRASH case (same ops in
    /// both files). A concurrent APPEND into this same tail landing inside the
    /// read→delete gap would be deleted without being in the segment — that
    /// case is excluded by ADR 0012's single-writer-per-(device, project)
    /// guarantee: only this device's editor process writes this tail, and the
    /// seal runs on the same MainActor as every append, so the interleaving
    /// requires two same-variant app instances on one Mac, which the app's
    /// single-instance model rules out. If that model ever changes, this gap
    /// needs a single coordinated read+rewrite instead.
    @MainActor
    static func sealTail(
        docId: String, deviceSlug: DeviceSlug, threshold: Int,
        projectURL: URL, presenter: NSFilePresenter?, identities: LocalIdentities
    ) throws -> URL? {
        let fm = FileManager.default
        let tailURL = try OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: deviceSlug, in: projectURL)
        let size = ((try? fm.attributesOfItem(atPath: tailURL.path))?[.size] as? Int) ?? 0
        guard size > threshold else { return nil }

        // 1. Coordinated read of the tail's exact bytes; abort on any torn
        //    line — never bake unparseable bytes into a checksummed segment
        //    (the existing quarantine path owns torn tails).
        let coord = NSFileCoordinator(filePresenter: presenter)
        var coordErr: NSError?
        var tailBytes: Data?
        coord.coordinate(readingItemAt: tailURL, options: [], error: &coordErr) { ru in
            tailBytes = try? Data(contentsOf: ru)  // adr-0018-ok: op-log segment tail bytes — the op log IS the source of truth (ADR 0018)
        }
        if let coordErr { throw coordErr }
        // RULING-54 lenient, reason recorded: an unreadable tail SKIPS the
        // seal rather than surfacing. Sealing is maintenance, not truth — the
        // ops stay in the tail, the skip is retried on every autosave/close,
        // and a tail that is genuinely unreadable meets the strict refusal at
        // the next document load (M9-OL-001), so the state cannot persist
        // silently across sessions. The torn-line skip below is likewise
        // deliberate: the quarantine path owns torn tails, and a checksummed
        // segment must never bake in unparseable bytes.
        guard let bytes = tailBytes, !bytes.isEmpty else { return nil }
        let parsed = JSONLAppendStore<Op>.parse(bytes: bytes)
        guard parsed.diagnostics.skipped.isEmpty else { return nil }

        // 2. Next index = max existing + 1 for this (docId, slug); write the
        //    container to a temp name, then atomic-rename. Never overwrite.
        let existing = OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL)
            .compactMap {
                OpLogStore.segmentIndex(fromFilename: $0.lastPathComponent,
                                        docId: docId, deviceSlug: deviceSlug)
            }
        let index = (existing.max() ?? 0) + 1
        let segURL = try OpLogStore.segmentFileURL(
            forDocId: docId, deviceSlug: deviceSlug, index: index, in: projectURL)
        guard !fm.fileExists(atPath: segURL.path) else { return nil }
        let container = try OpLogSegment.encode(jsonl: bytes)
        let tmpURL = segURL.deletingLastPathComponent()
            .appendingPathComponent(".seal-tmp-\(UUID().uuidString)")
        try container.write(to: tmpURL, options: .atomic)
        try fm.moveItem(at: tmpURL, to: segURL)

        // 2b. Sign the segment's digest, beside the segment. Best-effort for
        //     the same reason the seal itself is maintenance rather than truth:
        //     a device with no key signs nothing, a failed write leaves a
        //     segment that reads as unsigned history, and neither may cost the
        //     writer the rotation their tail needs.
        // The sidecar carries the key of the actor whose slug this segment
        // is named for — the same key that sealed the lines inside it. A slug
        // naming no local actor gets no signature at all: nothing on this
        // device may vouch for another device's bytes.
        if let signer = identities.all.first(where: { $0.slug == deviceSlug }),
           signer.canSign {
            do { try Self.writeSegmentSignature(
                    for: segURL, jsonl: bytes, identity: signer) }
            catch {
                opLogLoadLog.error("""
                    Could not sign segment \
                    \(segURL.lastPathComponent, privacy: .public): \
                    \(String(describing: error), privacy: .public). \
                    It will read as unsigned history.
                    """)
            }
        }

        // 3. Coordinated delete of the tail; the next append recreates it via
        //    JSONLAppendStore.append's create branch.
        let delCoord = NSFileCoordinator(filePresenter: presenter)
        var delErr: NSError?
        var removeErr: Error?
        delCoord.coordinate(writingItemAt: tailURL, options: .forDeleting,
                            error: &delErr) { wu in
            do { try fm.removeItem(at: wu) } catch { removeErr = error }
        }
        if let delErr { throw delErr }
        if let removeErr { throw removeErr }
        return segURL
    }

    /// Sign a freshly minted segment's digest and write the sidecar beside it.
    ///
    /// Throws on a device with no key and on a failed write. Both are conditions
    /// the SEAL is required to survive — the caller logs and carries on, and a
    /// segment with no signature is unsigned history rather than a refusal.
    @discardableResult
    nonisolated static func writeSegmentSignature(
        for segmentURL: URL, jsonl: Data, identity: DeviceIdentity, at: Date = Date()
    ) throws -> URL {
        let digest = OpLogSegment.hex(Data(SHA256.hash(data: jsonl)))
        let signature = try SegmentSignature.make(
            digest: digest, identity: identity, at: at)
        let url = OpLogStore.segmentSignatureURL(for: segmentURL)
        try signature.encoded().write(to: url, options: .atomic)
        return url
    }
}
