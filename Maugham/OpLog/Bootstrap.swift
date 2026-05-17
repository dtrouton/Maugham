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

        // Mint new ids for any missing.
        var sequence: [String] = []
        var paragraphMap: [String: String] = [:]
        var changes: [Op.ParagraphChange] = []
        for p in parsed {
            let id = p.id ?? ParagraphID.mint()
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
