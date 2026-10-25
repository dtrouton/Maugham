// Packages/MaughamCore/Sources/MaughamCore/OpLogFiles.swift
import Foundation

/// The op log's file NAMES and globs: the one place a doc id and a device slug
/// become a filename, and a filename becomes a doc id again. Split out of
/// `OpLogStore` (foundations plan 6); `OpLogStore` keeps forwarders so callers
/// are unchanged. Tripwire 24 holds: `DeviceSlug` is interpolated via `.raw`
/// only at the filename point, here.
public enum OpLogFiles {
    /// The op-log file URL a writer for `docId` on device `deviceSlug` appends to:
    /// `<projectURL>/.maugham/ops/<docId>.<deviceSlug>.jsonl`. SINGLE SOURCE OF TRUTH
    /// for op-log filename CONSTRUCTION — the producer-side twin of
    /// `docId(fromOpLogFilename:)`. Surfaces (phone `AnnotationWriter`, Mac
    /// `OpLogStore.store`) MUST call this, never hand-roll the `"\(docId).\(slug).jsonl"`
    /// template. See docs/superpowers/notes/cross-surface-contracts.md.
    /// Throws `SafeRelativePath.PathError.notADocId` for a doc id that could
    /// climb out of `.maugham/ops/` (`SafeRelativePath.requireDocId`): the id
    /// comes from synced data.
    public nonisolated static func opLogFileURL(
        forDocId docId: String, deviceSlug: DeviceSlug, in projectURL: URL
    ) throws -> URL {
        let fileId = try SafeRelativePath.requireDocId(docId)
        return projectURL
            .appendingPathComponent(".maugham/ops", isDirectory: true)
            .appendingPathComponent("\(fileId).\(deviceSlug.raw).jsonl")
    }

    /// The doc id encoded in an op-log filename, or nil if `name` is not a
    /// manuscript doc op-log file. Filenames are `<docId>(.<slug>)?.jsonl`; the
    /// doc id is the component before the first `.` (doc ids contain no dot) and is
    /// `doc-<hex>` / `scene-<hex>` (ADR 0008). Not checked against a shape — this
    /// store is id-agnostic by contract; the only excluded stream is the
    /// synthetic `__project__` (tasks/checkpoints — no manuscript content). The
    /// one rule an id must meet is where it BECOMES a file name:
    /// `opLogFileURL` and `segmentFileURL` refuse an id that fails
    /// `SafeRelativePath.requireDocId` (no `/`, `\`, NUL, not dot-leading).
    ///
    /// SINGLE SOURCE OF TRUTH for filename→docId. Surfaces (phone + Mac) MUST call
    /// this, never hand-roll a predicate (a stricter local copy is what shipped the
    /// phone-v0.1.1 "No open annotations" bug). Enforced by the reach-around
    /// tripwires; see docs/superpowers/notes/cross-surface-contracts.md.
    public nonisolated static func docId(fromOpLogFilename name: String) -> String? {
        let stem: String
        if name.hasSuffix(".jsonl") {
            stem = String(name.dropLast(".jsonl".count))
        } else if name.hasSuffix(".\(OpLogSegment.fileExtension)") {
            // Sealed segment `<docId>.<slug>.seg<NNNN>.mzseg` (ADR 0016).
            stem = String(name.dropLast(".\(OpLogSegment.fileExtension)".count))
        } else {
            return nil
        }
        let head = String(stem.split(separator: ".", maxSplits: 1,
                                     omittingEmptySubsequences: false)[0])
        guard !head.isEmpty, head != "__project__" else { return nil }
        return head
    }

    /// Distinct doc ids among a set of `.maugham/ops/` filenames (per-device +
    /// legacy files for one doc collapse to one id).
    public nonisolated static func docIds(inOpsDirectoryFilenames filenames: [String]) -> Set<String> {
        Set(filenames.compactMap(docId(fromOpLogFilename:)))
    }

    /// Every op-log file URL for `docId` (legacy + per-device). Pure listing,
    /// no read coordination — for readers that need the file set without the
    /// async coordinated load (mtime-change heuristics; the synchronous
    /// local-log readers in ProjectStore+Tasks). Returns [] if the ops dir or
    /// matching files don't exist. docIds contain no dots (delimiter between id
    /// and device slug), so the `<docId>.` boundary is unambiguous and can't
    /// prefix-collide with another doc. Format is `doc-<hex>` / `scene-<hex>`
    /// (ADR 0008) or the synthetic `__project__`.
    public nonisolated static func opLogFileURLs(
        forDocId docId: String, in projectURL: URL
    ) -> [URL] {
        opLogFileURLs(forDocId: docId, among: opsDirectoryListing(in: projectURL))
    }

    /// Every URL in `.maugham/ops` (unfiltered), or [] when the directory is
    /// absent: one listing a caller asking about MANY docs filters with
    /// `opLogFileURLs(forDocId:among:)`, rather than listing once per doc.
    public nonisolated static func opsDirectoryListing(in projectURL: URL) -> [URL] {
        let dir = projectURL.appendingPathComponent(".maugham/ops")
        return (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
    }

    /// `docId`'s op-log files among a listing of `.maugham/ops`
    /// (`opsDirectoryListing`). The one spelling of which filenames are a
    /// doc's history: legacy `.jsonl`, per-device `.jsonl`, sealed segments.
    public nonisolated static func opLogFileURLs(forDocId docId: String, among listing: [URL]) -> [URL] {
        listing.filter { url in
            let n = url.lastPathComponent
            return n == "\(docId).jsonl"
                || (n.hasPrefix("\(docId).") && n.hasSuffix(".jsonl"))
                || (n.hasPrefix("\(docId).") && n.hasSuffix(".\(OpLogSegment.fileExtension)"))
        }
    }

    /// Sealed-segment URL: `.maugham/ops/<docId>.<deviceSlug>.seg<NNNN>.mzseg`
    /// (ADR 0016 / growth spec §5.1). SINGLE SOURCE OF TRUTH for segment
    /// filename construction — never hand-roll the template (grep tripwires
    /// on both targets enforce; see cross-surface-contracts.md).
    /// Throws for a doc id that fails `SafeRelativePath.requireDocId`.
    public nonisolated static func segmentFileURL(
        forDocId docId: String, deviceSlug: DeviceSlug, index: Int, in projectURL: URL
    ) throws -> URL {
        let fileId = try SafeRelativePath.requireDocId(docId)
        return projectURL
            .appendingPathComponent(".maugham/ops", isDirectory: true)
            .appendingPathComponent(
                "\(fileId).\(deviceSlug.raw).seg\(String(format: "%04d", index)).\(OpLogSegment.fileExtension)")
    }

    /// The signature beside a sealed segment: the segment's own name with
    /// `.sig` appended, so it sorts next to it and `opLogFileURLs` — which
    /// matches on `.jsonl` and `.mzseg` endings — can never list it as history.
    /// SINGLE SOURCE OF TRUTH for the sidecar's name.
    public nonisolated static func segmentSignatureURL(for segmentURL: URL) -> URL {
        segmentURL.deletingLastPathComponent()
            .appendingPathComponent(segmentURL.lastPathComponent + ".sig")
    }

    /// Parse `<docId>.<deviceSlug>.seg<NNNN>.mzseg` → NNNN, or nil if `name`
    /// is not a segment of this (docId, deviceSlug) pair.
    nonisolated static func segmentIndex(
        fromFilename name: String, docId: String, deviceSlug: DeviceSlug
    ) -> Int? {
        let prefix = "\(docId).\(deviceSlug.raw).seg"
        let suffix = ".\(OpLogSegment.fileExtension)"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let digits = name.dropFirst(prefix.count).dropLast(suffix.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }
}
