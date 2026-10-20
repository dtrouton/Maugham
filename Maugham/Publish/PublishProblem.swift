import Foundation
import MaughamCore

/// One thing wrong with a book's report elements, found by
/// `PublishResolution.resolve` (report foundations plan 2): a reference that
/// points nowhere, an unknown citation key, a duplicate label, a footnote
/// that is missing or unused, a figure image that can't be used.
///
/// Each problem names its piece and the `¶id` of the paragraph it came from,
/// so the writer can jump there. Whether it blocks a compile is
/// `isError(profile:)`, the ONE severity table (R-P2-1).
public struct PublishProblem: Sendable, Equatable {

    public enum Kind: Sendable, Equatable {
        /// `@fig:x` (or `tbl:`/`sec:`) with no element carrying that label.
        case unresolvedCrossRef(ManuscriptLabel)
        /// `[@key]` with no live research source carrying that key.
        case unknownCitationKey(String)
        /// A second element carrying a label; the first one keeps it.
        case duplicateLabel(ManuscriptLabel)
        /// `[^n]` with no `[^n]:` definition in the same piece.
        case missingFootnoteDefinition(String)
        /// A second `[^n]:` definition in a piece; the first one counts.
        case duplicateFootnoteDefinition(String)
        /// A `[^n]:` definition nothing in the piece refers to.
        case unusedFootnoteDefinition(String)
        /// A valid label of the wrong kind for its element (`{#fig:x}` on a
        /// table or a heading); the label is ignored.
        case labelOnWrongElement(ManuscriptLabel)
        /// A trailing `{#…}` on a heading or a table caption that is not a
        /// valid `kind:name`; the payload is what was written between `{#`
        /// and `}`.
        case malformedLabel(String)
        /// A figure path, as written, that is not a file inside a research
        /// folder of the project.
        case figurePathNotLocal(String)
        /// A figure image that can't be used: the payload is
        /// `FigureImageResolver`'s reason, a sentence fragment that names the
        /// path ("there is no file at research/x.png").
        case imageUnreadable(String)
    }

    public let kind: Kind
    public let pieceID: String
    /// From `Section.nodeParagraphs` (or `footnoteParagraphs` for a problem
    /// inside a footnote definition); nil only when the piece's paragraphs
    /// didn't reconcile.
    public let paragraphID: String?
    /// The body's language tag (R-P2-8): its problems' messages are prefixed
    /// `[tag]`, as `TranslationCoverage` does. Nil for a single-body compile.
    public let bodyTag: String?

    public init(kind: Kind, pieceID: String, paragraphID: String?, bodyTag: String?) {
        self.kind = kind
        self.pieceID = pieceID
        self.paragraphID = paragraphID
        self.bodyTag = bodyTag
    }

    /// R-P2-1, the one severity table. In a Report the six error kinds block a
    /// versioned compile; in every other project nothing does, so a novel that
    /// happens to contain `[@sarah]` still compiles.
    public func isError(profile: ProjectProfile?) -> Bool {
        let isReport: Bool
        switch profile {
        case .report: isReport = true
        case .unknown, nil: isReport = false
        }
        guard isReport else { return false }
        switch kind {
        case .unresolvedCrossRef, .unknownCitationKey, .duplicateLabel,
             .missingFootnoteDefinition, .figurePathNotLocal, .imageUnreadable:
            return true
        case .unusedFootnoteDefinition, .duplicateFootnoteDefinition,
             .labelOnWrongElement, .malformedLabel:
            return false
        }
    }

    /// The writer's words: the label, key or path, and what is wrong.
    public var message: String {
        let prefix = bodyTag.map { "[\($0)] " } ?? ""
        return prefix + Self.sentence(for: kind)
    }

    private static func sentence(for kind: Kind) -> String {
        switch kind {
        case .unresolvedCrossRef(let label):
            return "No \(element(label.kind)) is labelled \(label.reference)."
        case .unknownCitationKey(let key):
            return "No research source has the citation key \(key)."
        case .duplicateLabel(let label):
            return "The label \(label.reference) is used more than once; the first one counts."
        case .missingFootnoteDefinition(let label):
            return "Footnote [^\(label)] has no definition in this piece."
        case .duplicateFootnoteDefinition(let label):
            return "Footnote [^\(label)] is defined more than once; the first definition counts."
        case .unusedFootnoteDefinition(let label):
            return "Footnote [^\(label)] is defined but never used."
        case .labelOnWrongElement(let label):
            return "The label \(label.reference) can only name a \(element(label.kind)), "
                + "so it is ignored here."
        case .malformedLabel(let raw):
            return "{#\(raw)} is not a valid label; write {#fig:name}, {#tbl:name} or {#sec:name}."
        case .figurePathNotLocal(let path):
            return "The figure image \(path) is not inside a research folder of this project."
        case .imageUnreadable(let reason):
            return "The figure image can't be used: \(reason)."
        }
    }

    /// What a label of `kind` names.
    static func element(_ kind: ManuscriptLabel.Kind) -> String {
        switch kind {
        case .fig: return "figure"
        case .tbl: return "table"
        case .sec: return "section"
        }
    }
}
