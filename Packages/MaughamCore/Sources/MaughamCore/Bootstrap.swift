import Foundation

/// First-open migration of a legacy .md to the op-log format. Idempotent.
@MainActor
public enum Bootstrap {
    public struct Result: Sendable {
        public let bootstrapped: Bool
        public let paragraphIds: [String]
    }

    public static func run(
        projectURL: URL, docId: String, mdURL: URL,
        device: String, session: String
    ) async throws -> Result {
        let original = (try? String(contentsOf: mdURL, encoding: .utf8)) ?? ""  // adr-0018-ok: sanctioned import read — mints ids for a new/imported plain file; not read as truth for an existing doc (ADR 0018)
        // A Fountain manuscript's two-space "held blank" (Task 13 dialogue pause)
        // is legitimate content that must stay inside its paragraph, not split it
        // (E1). Prose keeps whitespace-only = blank. The extension decides.
        let isFountain = mdURL.pathExtension.lowercased() == "fountain"
        let parsed = ParagraphParser.parse(
            original, preservesHeldBlankLines: isFountain)
        let allHaveIds = !parsed.isEmpty && parsed.allSatisfy { $0.id != nil }
        if allHaveIds {
            // The file is already anchored. Whether there's work to do depends
            // on the op log. An EXISTING log is authoritative (the anchors were
            // minted long ago; the log carries every edit since) — no-op. But an
            // EMPTY op log against an anchored file is a torn state: a crash
            // between the `.md` write below and the op append, a deleted
            // `.maugham/`, or a backup restore that missed the hidden dir. Left
            // un-seeded the doc would open EMPTY (zero ops derive nothing) and
            // the first autosave would clobber the manuscript with the empty
            // render (spec F2). Seed the op log from the file's EXISTING ids —
            // mint nothing, do NOT rewrite the `.md` — so content is recovered
            // and identity stays stable for any synced annotation state.
            let logExists = !OpLogStore
                .opLogFileURLs(forDocId: docId, in: projectURL).isEmpty
            if logExists {
                return Result(bootstrapped: false,
                    paragraphIds: parsed.compactMap(\.id))
            }
            var sequence: [String] = []
            var paragraphMap: [String: String] = [:]
            var changes: [Op.ParagraphChange] = []
            for p in parsed {
                guard let id = p.id else { continue }
                sequence.append(id)
                paragraphMap[id] = p.text
                changes.append(.init(paragraphId: id, prior: nil, next: p.text))
            }
            try await emitBootstrap(
                projectURL: projectURL, docId: docId, device: device,
                session: session, changes: changes, sequence: sequence,
                paragraphMap: paragraphMap)
            return Result(bootstrapped: true, paragraphIds: sequence)
        }

        // Empty .md: nothing to bootstrap. Earlier builds emitted a
        // junk bootstrap op with empty `changes` and empty `sequence`
        // here, which then clobbered downstream state when folded by
        // the deriver. The empty .md case happens transiently when a
        // new doc is created (before first autosave) or when the
        // user has just deleted everything. In both cases there's no
        // useful work for bootstrap to do — return without emitting.
        if parsed.isEmpty {
            return Result(bootstrapped: false, paragraphIds: [])
        }

        // Mint new ids for any missing — UNIQUE against both the doc's
        // existing anchored ids and the other mints in this pass. A whole-doc
        // bootstrap can mint hundreds-to-thousands of ids at once; with plain
        // mint() over the ~1.05M id space a same-pass birthday collision is
        // probable at that scale (≈55% at 1,300 paragraphs) and would
        // silently merge two paragraphs under one identity in the op log.
        var usedIds = Set(parsed.compactMap(\.id))
        var sequence: [String] = []
        var paragraphMap: [String: String] = [:]
        var changes: [Op.ParagraphChange] = []
        for p in parsed {
            let id: String
            if let existing = p.id {
                id = existing
            } else {
                id = ParagraphID.mintUnique(excluding: usedIds)
                usedIds.insert(id)
            }
            sequence.append(id)
            paragraphMap[id] = p.text
            changes.append(.init(paragraphId: id, prior: nil, next: p.text))
        }

        // Write .md back with IDs.
        let newMd = Materializer.materialize(
            paragraphs: paragraphMap, sequence: sequence)
        try newMd.data(using: .utf8)?.write(to: mdURL, options: .atomic)

        try await emitBootstrap(
            projectURL: projectURL, docId: docId, device: device,
            session: session, changes: changes, sequence: sequence,
            paragraphMap: paragraphMap)
        return Result(bootstrapped: true, paragraphIds: sequence)
    }

    /// Append the `.bootstrap` op + the initial auto-labeled checkpoint. Shared
    /// by the mint path (unanchored `.md`) and the seed path (anchored `.md` +
    /// empty op log). The caller has already decided the ids/order and — for
    /// the mint path only — rewritten the `.md`.
    private static func emitBootstrap(
        projectURL: URL, docId: String, device: String, session: String,
        changes: [Op.ParagraphChange], sequence: [String],
        paragraphMap: [String: String]
    ) async throws {
        let op = Op(
            opId: ULID.generate(), docId: docId, at: Date(),
            device: device, session: session, kind: .bootstrap,
            changes: changes, sequence: sequence, provenance: nil)
        let opStore = OpLogStore(projectURL: projectURL)
        try await opStore.append(op)

        let wordCount = paragraphMap.values
            .map { $0.split { $0.isWhitespace || $0.isNewline }.count }
            .reduce(0, +)
        let cp = Checkpoint(
            checkpointId: ULID.generate(),
            label: "Initial — pre-tracking content",
            labelSource: .auto,
            at: Date(),
            device: device,
            activeDoc: docId,
            docPointers: [docId: op.opId],
            manuscriptWordCount: wordCount)
        try await CheckpointStore(projectURL: projectURL).append(cp)
    }
}
