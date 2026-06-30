import Foundation
import MaughamCore
@testable import Maugham

/// ADR 0019 test support.
///
/// Under ADR 0019 the manuscript `.md` is the DERIVED form and the op log is
/// the source of truth: `Document.load` takes content + order ONLY from the op
/// log, never from the `.md`'s anchors. Many older fixtures hand-wrote an
/// ANCHORED `.md` with no op log and relied on load seeding paragraph state
/// from those anchors — a path ADR 0019 removes. (Bootstrap is idempotent on an
/// already-anchored `.md`, so it emits nothing, and the op log stays empty.)
///
/// This helper seeds a doc's op log with a single `.bootstrap` op carrying the
/// caller's exact `paragraphs` + `sequence` — i.e. it does, with caller-chosen
/// ids, what `Bootstrap.run` would have written for an unanchored `.md`. After
/// seeding, `Document.load` finds a non-empty op log (so it does NOT
/// re-bootstrap) and derives the seeded content/order, letting tests keep
/// addressing specific paragraph ids.
@MainActor
func seedOpLogBootstrap(
    projectURL: URL,
    docId: String,
    paragraphs: [String: String],
    sequence: [String],
    device: String = "seed",
    session: String = "seed"
) async throws {
    let op = Op(
        opId: ULID.generate(),
        docId: docId,
        at: Date(),
        device: device,
        session: session,
        kind: .bootstrap,
        changes: sequence.map {
            Op.ParagraphChange(paragraphId: $0, prior: nil, next: paragraphs[$0] ?? "")
        },
        sequence: sequence)
    try await OpLogStore(projectURL: projectURL).append(op)
}
