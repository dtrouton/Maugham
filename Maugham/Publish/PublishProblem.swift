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
public struct PublishProblem: Sendable, Hashable {

    public enum Kind: Sendable, Hashable {
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
        /// A figure path, as written, that is not a file inside the
        /// project's figures folder or a research folder (an image's or a
        /// table figure's alike).
        case figurePathNotLocal(String)
        /// A figure image that can't be used: the payload is
        /// `FigureImageResolver`'s reason, a sentence fragment that names the
        /// path ("there is no file at research/x.png").
        case imageUnreadable(String)
        /// A figure line's path, as written, inside `figures/` naming no
        /// registered figure (one removed, or never made): the editor's
        /// (report plan 7b, R7b-4), and Publish's for a table figure's line
        /// (plan 9a).
        case figureNotFound(String)
        /// Two or more registered figures share a figure line's path, as
        /// written, so the line shows neither: the editor's, and Publish's for
        /// a table figure's line (plan 9a).
        case figureAmbiguous(String)
        /// The editor's only (R7b-3): a table figure's line labelled `fig:`.
        /// Publish numbers it as a figure and reads it through the image
        /// door, which refuses a `.csv`, so a Report will not publish it.
        case tableFigureLabelledFig(ManuscriptLabel)
        /// The editor's only: a line that alone would be a figure line (its
        /// path the payload) shares its paragraph with text, so it is read as
        /// an inline image — no card, and no figure when published.
        case figureLineSharesParagraph(String)
        /// A table figure showing a formula error (report plan 9a, spec §9):
        /// its first error cell's A1 name and the error it shows (`#DIV/0!`),
        /// nil when the printed cell can't be found; once per figure.
        case tableFigureErrorCell(name: String, cell: String, error: String?)
        /// A table figure whose formulas read a Research source that is gone.
        case tableFigureSourceMissing(name: String)
        /// A table figure its line can't print: its state did not read as a
        /// table. The line keeps its number and prints its literal source.
        case tableFigureUnreadable(name: String)
        /// A figure parked in Research, by its name: a reference to it, or a
        /// line still naming it.
        case figureInResearch(name: String)
        /// A note: a legacy table line into a Research folder (spec §4.4),
        /// by its file's name. It keeps working — it publishes its literal
        /// source — until it is moved into Figures.
        case tableInResearchFolder(name: String)
        /// A note: a table figure's formulas read numbers from Research.
        case tableFigureReadsResearch(name: String)
        /// A note: a Research source the table reads, or its own, has
        /// changed since the table last took it.
        case tableFigureResearchChanged(name: String)
        /// A note: an `NPV` whose first flow is negative, which Excel
        /// discounts one period (spec §5); the first such cell's A1 name.
        case tableFigureNPVNote(name: String, cell: String)
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
    /// The language of the body the problem was found in — `BodyPlan.Body.tag`,
    /// nil for the source body — set whatever the body count (`bodyTag` is
    /// nil in a single-body compile, even of an edition). It is what a reveal
    /// opens: a translated body's problem is revealed in that edition (R-S14).
    public let bodyLanguage: String?

    public init(kind: Kind, pieceID: String, paragraphID: String?, bodyTag: String?,
                bodyLanguage: String? = nil) {
        self.kind = kind
        self.pieceID = pieceID
        self.paragraphID = paragraphID
        self.bodyTag = bodyTag
        self.bodyLanguage = bodyLanguage
    }

    /// R-P2-1, the one severity table. In a Report its error kinds (the
    /// `isError(_:profile:)` switch) block a versioned compile; in every other
    /// project nothing does, so a novel that happens to contain `[@sarah]`
    /// still compiles. The editor-only figure-line kinds colour an underline;
    /// Publish never emits them.
    public func isError(profile: ProjectProfile?) -> Bool {
        Self.isError(kind, profile: profile)
    }

    /// The severity table itself, for a caller holding a kind and no piece:
    /// the editor's problem underlines (plan 3b Task 6, R-3b-4) colour by it.
    public static func isError(_ kind: Kind, profile: ProjectProfile?) -> Bool {
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
        // The figure-line checks take the colour of what Publish does with
        // the line. A line naming no figure has nothing to print: a `.csv`
        // has no table (report plan 9a checks it against the registry), and
        // an image path has lost its file with the figure (whole-branch
        // review I3, M3). That last is a premise, not a probe: Publish's image
        // door reads the disk, so an unregistered picture still sitting in
        // `figures/` would publish though the editor says red — accepted,
        // since the editor's checks never touch the disk (R7b-4; re-review
        // N2). A figure line labelled `fig:` goes through the image door,
        // which refuses a `.csv` (`.imageUnreadable`). A line naming two
        // figures still publishes — its literal source, or the image file.
        case .figureNotFound, .tableFigureLabelledFig:
            return true
        case .figureAmbiguous:
            return false
        // Publish prints the line as an inline image in its sentence, and
        // blocks nothing on it: a warning, which the writer fixes with a
        // blank line.
        case .figureLineSharesParagraph:
            return false
        // Spec §9: a table that can't print right, or a figure in Research,
        // is red in a Report; the Research and `NPV` notes are amber
        // everywhere.
        case .tableFigureErrorCell, .tableFigureSourceMissing, .tableFigureUnreadable,
             .figureInResearch:
            return true
        case .tableFigureReadsResearch, .tableFigureResearchChanged, .tableFigureNPVNote,
             .tableInResearchFolder:
            return false
        }
    }

    /// The writer's words: the label, key or path, and what is wrong.
    public var message: String {
        let prefix = bodyTag.map { "[\($0)] " } ?? ""
        return prefix + Self.sentence(for: kind)
    }

    /// The sentence for `kind`, with no body tag: what `message` says, and
    /// what the editor's problem underline says on hover (R-3b-4), so the
    /// editor and the publishing desk say the same thing.
    static func sentence(for kind: Kind) -> String {
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
            return "The figure \(path) is not inside this project’s figures folder or a research folder."
        case .imageUnreadable(let reason):
            // The reason may end in a system message's own full stop: one
            // sentence ends once (final review M8).
            return "The figure image can't be used: \(withoutClosingStop(reason))."
        case .figureNotFound(let path):
            return "No figure in this project is at \(path); it may have been removed."
        case .figureAmbiguous(let path):
            return "More than one figure is at \(path), so this line shows neither; rename one."
        case .tableFigureLabelledFig(let label):
            return "This table figure is labelled \(label.reference), so it is numbered as a figure "
                + "and a Report won’t publish it; write {#tbl:\(label.name)} to number it as a table."
        case .figureLineSharesParagraph(let path):
            let what = ManuscriptLabel.Kind.isTableFigurePath(path) ? "table" : "figure"
            return "This \(what) line shares a paragraph with text — it won't show or publish as a \(what). "
                + "Add a blank line above and below it."
        case .tableFigureErrorCell(let name, let cell, let error):
            let shown = error.map { " (\($0))" } ?? ""
            return "Table “\(name)” has an error in \(cell)\(shown). Fix the cell in the table to publish it."
        case .tableFigureSourceMissing(let name):
            return "Table “\(name)” reads numbers from a Research source that is gone. "
                + "Bring the source back, or change the cells that read it."
        case .tableFigureUnreadable(let name):
            return "Table “\(name)” couldn't be read, so its line prints as written. "
                + "Open it in the Figures area to check it."
        case .figureInResearch(let name):
            return "“\(name)” is in Research now, so it won’t publish. "
                + "Bring it back into the Figures area to use it here."
        case .tableInResearchFolder(let name):
            return "Table “\(name)” is read from a Research folder, so it publishes as written. "
                + "Move it into Figures to publish its cells."
        case .tableFigureReadsResearch(let name):
            return "Table “\(name)” uses numbers from Research."
        case .tableFigureResearchChanged(let name):
            return "Research has changed since table “\(name)” took its numbers. Refresh it in the Figures area."
        case .tableFigureNPVNote(let name, let cell):
            return "Table “\(name)” discounts the first cash flow in \(cell): NPV treats it as a year away, "
                + "as Excel does. Add it outside the NPV if it falls today."
        }
    }

    /// `text` without a trailing full stop, so a sentence that wraps it ends
    /// in exactly one.
    static func withoutClosingStop(_ text: String) -> String {
        var out = Substring(text)
        while out.last == "." || out.last == " " { out = out.dropLast() }
        return String(out)
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

// MARK: - the gate (Task 7)

/// What the compile doors do with a book's publish problems (R-P2-1): a
/// versioned compile or republish of a Report refuses on an error before its
/// version is minted; everything else — every other profile, and every
/// preview or sample compile — carries them as warnings. The problems come
/// from the SAME resolution each compiler then emits with: the doors resolve
/// once through `resolve(bodies:imageAllowed:)` and hand the result down, so
/// what the gate judged is what the book shows.
public enum PublishProblemGate {

    /// One body's AST and its resolution over its whole book, built once and
    /// shared by the gate and the compiler that emits it.
    public struct Body {
        public let ast: ProjectAST
        public let resolution: PublishResolution
        /// The pieces `ast` was built from, read once: a Word export's sent
        /// copy records their paragraphs exactly as exported (R-S2). Empty for
        /// a body built from an AST alone.
        public var pieces: [ProjectASTBuilder.PieceRef] = []
    }

    public enum Verdict: Equatable {
        /// A Report's versioned compile with an error among its problems:
        /// every problem as a diagnostic, errors and warnings both.
        case refused(errors: [TectonicLogParser.Diagnostic])
        /// Every problem as a warning; empty when the book has none.
        case passed(warnings: [TectonicLogParser.Diagnostic])

        /// The diagnostics either way: what a compile that failed for another
        /// reason (tectonic, packaging, an occupied destination) still
        /// carries after its own errors, so the writer never loses them.
        public var diagnostics: [TectonicLogParser.Diagnostic] {
            switch self {
            case .refused(let all), .passed(let all): return all
            }
        }
    }

    /// THE ONE place a body is resolved, for every door — compile, republish,
    /// preview and sample: builds each body's AST once (the manuscript is read
    /// once per body) and resolves it over its book — the edition's (R-S15) —
    /// for one output format's images. A multi-body compile tags each body's
    /// problems with its language (R-P2-8); every body's problems carry it as
    /// `bodyLanguage` (R-S14). Each body is resolved in its own element words,
    /// chosen here from its folded config and nowhere else (R-S16), and its
    /// table figures' cells print in that config's language (plan 9a).
    static func resolve(bodies: [BodyPlan.Body],
                        imageAllowed: Set<String>) throws -> [Body] {
        try bodies.map { body in
            let pieces = try body.source.orderedPieces()
            let ast = ProjectASTBuilder.build(pieces: pieces)
            let resolution = try PublishResolution.forCompile(
                source: body.source, built: ast,
                bodyTag: bodies.count > 1 ? body.displayTag : nil,
                imageAllowed: imageAllowed,
                bodyLanguage: body.tag,
                words: ElementWords.forBody(body.config.metadata),
                tableLocale: tableLocale(body.config.metadata.language))
            return Body(ast: ast, resolution: resolution, pieces: pieces)
        }
    }

    /// A body's table-figure cells print in its own language — the editor
    /// card's constructor, a blank language reading as none.
    static func tableLocale(_ language: String) -> TableLocale {
        let tag = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return TableLocale(languageTag: tag.isEmpty ? nil : tag)
    }

    /// The verdict over a compile's problems.
    ///
    /// - Parameters:
    ///   - context: the book's (its resolution scope's) context: the profile
    ///     that decides severity and the piece paths a diagnostic names.
    ///   - refusesOnErrors: true for a versioned compile or a republish; false
    ///     for a preview or a sample compile, which never refuse.
    static func judge(_ problems: [PublishProblem], context: PublishContext,
                      refusesOnErrors: Bool) -> Verdict {
        let refuses = refusesOnErrors
            && problems.contains { $0.isError(profile: context.profile) }
        guard refuses else { return .passed(warnings: warnings(problems, context: context)) }
        // Errors first, each half in book order: a surface that names
        // `errors.first` as the reason must name an error, never a warning.
        let errors = problems.filter { $0.isError(profile: context.profile) }
        let warnings = problems.filter { !$0.isError(profile: context.profile) }
        return .refused(errors:
            errors.map { diagnostic($0, level: .error, piecePaths: context.piecePaths) }
            + warnings.map { diagnostic($0, level: .warning, piecePaths: context.piecePaths) })
    }

    /// Every problem as a warning: a preview's or a sample compile's answer,
    /// which never refuses.
    static func warnings(_ problems: [PublishProblem],
                         context: PublishContext) -> [TectonicLogParser.Diagnostic] {
        problems.map { diagnostic($0, level: .warning, piecePaths: context.piecePaths) }
    }

    /// A problem as the one diagnostic channel carries it: `file` is the
    /// piece's project-relative path, `line` is nil, and the ids ride along.
    static func diagnostic(_ problem: PublishProblem, level: TectonicLogParser.Level,
                           piecePaths: [String: String]) -> TectonicLogParser.Diagnostic {
        TectonicLogParser.Diagnostic(
            level: level, file: piecePaths[problem.pieceID], line: nil,
            message: problem.message,
            contextLines: level == .error
                ? ["A report won't publish with this problem, so nothing was published."]
                : [],
            pieceID: problem.pieceID, paragraphID: problem.paragraphID,
            bodyLanguage: problem.bodyLanguage)
    }

    /// The `logExcerpt` of a refusal: `PublishOrchestrator.publishProblemsLogExcerpt`
    /// and the count of errors, so the desk tells a problem refusal from a fault.
    static func logExcerpt(_ errors: [TectonicLogParser.Diagnostic]) -> String {
        let count = errors.filter { $0.level == .error }.count
        return PublishOrchestrator.publishProblemsLogExcerpt
            + "\(count) error\(count == 1 ? "" : "s")"
    }
}
