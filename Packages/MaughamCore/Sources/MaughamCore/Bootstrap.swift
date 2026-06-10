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
        let original = (try? String(contentsOf: mdURL, encoding: .utf8)) ?? ""
        let parsed = ParagraphParser.parse(original)
        let allHaveIds = !parsed.isEmpty && parsed.allSatisfy { $0.id != nil }
        if allHaveIds {
            return Result(bootstrapped: false,
                paragraphIds: parsed.compactMap(\.id))
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

        // Emit bootstrap op.
        let op = Op(
            opId: ULID.generate(), docId: docId, at: Date(),
            device: device, session: session, kind: .bootstrap,
            changes: changes, sequence: sequence, provenance: nil)
        let opStore = OpLogStore(projectURL: projectURL)
        try await opStore.append(op)

        // Emit initial checkpoint.
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

        return Result(bootstrapped: true, paragraphIds: sequence)
    }
}
