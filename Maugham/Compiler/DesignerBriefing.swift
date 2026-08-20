import Foundation
import MaughamCore

/// Assembles what one designer run sends to the spawned Claude —
/// `TranslatorBriefing`'s sibling, same purity discipline: a plain `Inputs`
/// value in, one message out. No I/O, no clock, no store lookup —
/// `DesignerOrchestrator`'s `briefRound` closure (Task 6) is the one
/// production caller and owns gathering `Inputs` from the store, the census
/// (`ElementCensus`) and the sample selection (`SamplePageSelection`); this
/// type does not know any of those exist.
enum DesignerBriefing {

    // MARK: - Inputs

    /// Everything one briefing needs, already resolved by the caller.
    struct Inputs: Equatable {

        /// One file currently in `.maugham/publish/` — the designer's own
        /// starting point. `write_publish_file` replaces a file's full
        /// content, so a proposal that revises one of these must be read
        /// whole, not diffed.
        struct TemplateFile: Equatable {
            let path: String
            let content: String

            init(path: String, content: String) {
                self.path = path
                self.content = content
            }
        }

        let designerName: String
        /// `ProductionRole.effectiveBrief` for this designer — `nil` only
        /// when a caller deliberately withholds it (in production the
        /// designer always has at least the preset doctrine, per
        /// `ProductionRole.presetDesigner`); `compose` omits the sentence
        /// rather than inventing a fallback, `TranslatorBriefing`'s posture.
        let roleBrief: String?
        /// The writer's declared look for the book — `read_visual_language`'s
        /// own markdown, verbatim. `nil` (or empty) is a real, deliberate
        /// state: the writer has not declared one yet, and `compose` says so
        /// outright rather than composing a briefing that is silent about it.
        let visualLanguageText: String?
        /// What the compiled book actually contains — every element kind a
        /// design has to account for.
        let census: ElementCensus
        /// Which pieces the sample compile will show, and why — carries
        /// `demonstrates` so the designer knows what the samples prove.
        let selection: SamplePageSelection.Selection
        /// The live `.maugham/publish/` set, as it stands before this round.
        let templateFiles: [TemplateFile]
        /// The project's compile configuration — `compose` reads only the
        /// design-relevant fields off this, never serializes it whole.
        let config: PublishConfig
        /// The language this round's proposal is for, when one is in play —
        /// `nil` for the base (untranslated) edition. Gates whether the
        /// edition-brief section appears at all: an edition brief that exists
        /// for a language nobody asked about this round is not this round's
        /// doctrine.
        let language: String?
        /// The edition brief's markdown for `language`, when the writer has
        /// declared one. Only ever surfaced when `language != nil`.
        let editionBriefText: String?
        /// The writer's own words for this round, when given — a follow-up
        /// nudge, a constraint, a "try something more…". `nil` is the
        /// ordinary case: most rounds run on doctrine alone.
        let direction: String?

        init(
            designerName: String, roleBrief: String? = nil, visualLanguageText: String? = nil,
            census: ElementCensus = ElementCensus(kinds: [], firstPiece: [:]),
            selection: SamplePageSelection.Selection = SamplePageSelection.Selection(
                pieceIds: [], maxPages: SamplePageSelection.maxPages, demonstrates: []),
            templateFiles: [TemplateFile] = [], config: PublishConfig = PublishConfig(),
            language: String? = nil, editionBriefText: String? = nil, direction: String? = nil
        ) {
            self.designerName = designerName
            self.roleBrief = roleBrief
            self.visualLanguageText = visualLanguageText
            self.census = census
            self.selection = selection
            self.templateFiles = templateFiles
            self.config = config
            self.language = language
            self.editionBriefText = editionBriefText
            self.direction = direction
        }
    }

    // MARK: - Cap discipline

    /// How much of one template file's content a briefing embeds —
    /// `TranslatorBriefing`'s cap discipline, applied to files rather than
    /// prose: a live template can run to several KB, and the briefing would
    /// otherwise be mostly template bytes. A designer proposing a change
    /// reads structure from this prefix; `write_publish_file` replaces a
    /// file's FULL content on write regardless, so byte-for-byte fidelity in
    /// the briefing buys nothing a `read_publish_file` call couldn't finish.
    /// Own value — the shape is borrowed, not the constant.
    static let templateFileCharacterCap = 4_000

    // MARK: - Compose

    /// Assemble one briefing message. Section order: role frame, the
    /// writer's visual doctrine, the edition brief (only when a language is
    /// in play), what the book contains and what the samples will show, the
    /// live templates, the compile config summary, the writer's own
    /// direction for this round, the report contract —
    /// `TranslatorBriefing.compose`'s own ordering rule: the frame everything
    /// else is read through comes first, the output-shape instruction comes
    /// last.
    static func compose(inputs: Inputs) -> String {
        var sections: [String] = [roleFrame(inputs)]

        sections.append(visualLanguageSection(inputs))
        if let editionBrief = editionBriefSection(inputs) {
            sections.append(editionBrief)
        }
        sections.append(censusSection(inputs))
        if let templates = templateFilesSection(inputs.templateFiles) {
            sections.append(templates)
        }
        sections.append(configSummarySection(inputs.config))
        if let direction = inputs.direction, !direction.isEmpty {
            sections.append("Direction from the writer for this round:\n" + cleaned(direction))
        }

        sections.append(DesignerReport.schemaDescription)

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Role frame

    /// Who is reading, and what they are for — `TranslatorBriefing.roleFrame`'s
    /// shape.
    private static func roleFrame(_ inputs: Inputs) -> String {
        var lines = [
            "You are \(inputs.designerName), the designer for this book. You "
                + "propose page templates and stylesheets — spec plus files — for "
                + "the writer to review on sample pages; you never write to the "
                + "live template set yourself."
        ]
        if let brief = inputs.roleBrief, !brief.isEmpty {
            lines.append(cleaned(brief))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Visual language

    /// The writer's declared look, or an honest statement that none exists
    /// yet. Unlike `TranslatorBriefing`'s declared-intent section, this is
    /// never silently omitted: a designer working from nothing needs to be
    /// told that outright rather than left to infer it from an absent
    /// section.
    private static func visualLanguageSection(_ inputs: Inputs) -> String {
        guard let text = inputs.visualLanguageText, !text.isEmpty else {
            return "Visual language: no visual language declared; ask before assuming."
        }
        return "Visual language — the writer's declared look for this book. This "
            + "is the brief, not a starting point to improve on:\n" + cleaned(text)
    }

    // MARK: - Edition brief

    /// Only ever appears when `inputs.language` is set — an edition brief for
    /// a language nobody asked this round about is not this round's
    /// doctrine.
    private static func editionBriefSection(_ inputs: Inputs) -> String? {
        guard let language = inputs.language else { return nil }
        var lines = ["This round's proposal is for the \(language) edition."]
        if let brief = inputs.editionBriefText, !brief.isEmpty {
            lines.append(cleaned(brief))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Census + sample demonstration

    /// What the book contains, and what the sample pages will prove of it —
    /// the census names every kind so a design cannot silently skip one that
    /// happens not to lead a `demonstrates` line of its own (a piece can
    /// newly cover several kinds at once, but `SamplePageSelection` only
    /// attributes one line per selected piece).
    private static func censusSection(_ inputs: Inputs) -> String {
        var lines = ["What the book contains — every element kind your design must account for:"]
        let present = ElementCensus.Kind.allCases.filter { inputs.census.kinds.contains($0) }
        if present.isEmpty {
            lines.append("(nothing yet)")
        } else {
            lines.append(contentsOf: present.map { "- \(ElementCensus.label(for: $0))" })
        }
        lines.append("")
        if inputs.selection.demonstrates.isEmpty {
            lines.append("Sample pages will demonstrate: nothing yet.")
        } else {
            lines.append("Sample pages will demonstrate:")
            lines.append(contentsOf: inputs.selection.demonstrates.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Current templates

    private static func templateFilesSection(_ files: [Inputs.TemplateFile]) -> String? {
        guard !files.isEmpty else { return nil }
        var lines = [
            "Current templates — read these before proposing a change. "
                + "write_publish_file replaces a file's full content, so a "
                + "proposal that touches one of these revises it whole, not as a "
                + "diff:"
        ]
        for file in files {
            lines.append("--- \(file.path) ---")
            lines.append(cappedFileContent(file.content))
        }
        return lines.joined(separator: "\n")
    }

    /// Caps one file's embedded content at `templateFileCharacterCap`
    /// characters, with an elision note naming how much was cut — never a
    /// silent truncation.
    private static func cappedFileContent(_ content: String) -> String {
        guard content.count > templateFileCharacterCap else { return content }
        let prefix = content.prefix(templateFileCharacterCap)
        let elided = content.count - templateFileCharacterCap
        return "\(prefix)\n\u{2026} (truncated; \(elided) more characters not shown — "
            + "read_publish_file for the rest)"
    }

    // MARK: - Config summary

    /// The design-relevant slice of `PublishConfig` — never the whole
    /// object. Trim size and page geometry are deliberately absent: they
    /// live in the template itself (`PublishConfig`'s own type doc — config
    /// can't drive the engine into generic output), so there is nothing
    /// there for this summary to state. What IS design-relevant: which
    /// output formats this book actually renders to (an EPUB-only book has
    /// no fixed page to design around), whether a cover exists, and which
    /// pieces already carry a per-piece style override a new design has to
    /// account for or fold in. The config.json refusal is stated here
    /// explicitly, on top of `DesignerReport.schemaDescription`'s own
    /// mention of it — this is compile configuration, not a design file.
    private static func configSummarySection(_ config: PublishConfig) -> String {
        var lines = [
            "Compile configuration summary — this is compile config "
                + "(.maugham/publish/config.json), not yours to write; propose "
                + "template/style/partial files only:",
            "- Formats: \(config.outputs.formatsEnabled.map(\.rawValue).joined(separator: ", "))",
            "- Cover: \(config.cover.path.map { "\"\($0)\"" } ?? "none set")",
        ]
        let stylized = config.sections
            .filter { $0.value.styleFile != nil }
            .map(\.key)
            .sorted()
        if !stylized.isEmpty {
            lines.append(
                "- Pieces with an existing per-piece style override: "
                    + stylized.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Anchor hygiene

    /// Defense in depth, `TranslatorBriefing.cleaned`'s own reasoning:
    /// nothing embedded in a prompt should ever leak a `¶id` anchor, even
    /// though the caller's inputs are expected to already be clean display
    /// text.
    private static func cleaned(_ text: String) -> String {
        MarkdownDisplayFilter.stripAnchors(text)
    }
}
