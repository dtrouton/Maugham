import Foundation
import MaughamCore

/// Task 9: blocking translation coverage gate + Fountain element-drift warnings.
///
/// A translated compile (`language != nil`) must not silently ship a book whose
/// translation lags the source. `check` walks the SAME pieces as
/// `ProjectStoreASTSource.orderedPieces()`, derives each piece's translation
/// against the same `(sequence, paragraphs)` source split the substitution path
/// uses, and reports per-piece stale/missing ¶id gaps. Both `CompileOrchestrator
/// .compile` and `Republisher.republish` consume the report through the SAME
/// `applyGate` (round 5 — these had reimplemented it separately and drifted):
/// it refuses an un-`allow_stale` edition with gaps, and under `allow_stale`
/// demotes the gaps to warnings that itemize every paragraph that fell back to
/// source text.
@MainActor
enum TranslationCoverage {

    struct Report {
        struct PieceGap {
            let pieceID: String
            let title: String
            /// ¶ids whose translation is stale relative to the current source.
            let stale: [String]
            /// ¶ids with no translation record at all.
            let missing: [String]
        }

        /// Pieces with at least one stale or missing paragraph.
        let gaps: [PieceGap]

        /// One human-readable warning per fountain piece whose substituted text
        /// tokenizes to a different screenplay-element sequence than its source.
        let fountainDriftWarnings: [String]

        /// Non-nil when NO piece carries any translation record for the language:
        /// the edition would be byte-identical to the source book, which must
        /// never be labeled as an edition. Fails the gate unconditionally (even
        /// under `allow_stale`).
        let zeroLayerError: String?

        var isBlocked: Bool { gaps.contains { !$0.stale.isEmpty || !$0.missing.isEmpty } }
    }

    static func check(
        projectStore: ProjectStore,
        language: String,
        excludedSectionIDs: Set<String> = []
    ) -> Report {
        let docs = ProjectStore.collectDocuments(in: projectStore.manifest.structure)
        var gaps: [Report.PieceGap] = []
        var driftWarnings: [String] = []
        var anyRecords = false
        var anyTranslatable = false

        for item in docs {
            if item.pieceKind == .reference { continue }
            // F1: an excluded piece isn't in this edition, so its untranslated
            // paragraphs must neither raise gaps NOR count toward the zero-layer
            // guard's denominator — an all-excluded-but-translated book passes.
            if excludedSectionIDs.contains(item.id) { continue }
            guard let path = item.path else { continue }

            let (sequence, paragraphs) = sourceSplit(
                projectStore: projectStore, docId: item.id, path: path)
            let records = TranslationStore.loadMerged(
                forDocId: item.id, language: language, in: projectStore.url)
            if !records.isEmpty { anyRecords = true }

            let derived = TranslationDeriver.derive(
                records: records, sequence: sequence,
                paragraphs: paragraphs, language: language)
            // A blank paragraph (whitespace-only source) has nothing to
            // translate, so it is neither "missing" nor "stale" and does not
            // demand a translation layer — count only non-empty paragraphs.
            // Deliberately broader than Task 7's zero-paragraph fixtures
            // require: those fixtures are wholly-empty docs, but a REAL
            // manuscript can mix genuine untranslated paragraphs with
            // incidental blank ones, and only the former should gate.
            let translatable = derived.entries.filter {
                !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if !translatable.isEmpty { anyTranslatable = true }
            let stale = translatable.filter { $0.status == .stale }.map(\.paragraphId)
            let missing = translatable.filter { $0.status == .missing }.map(\.paragraphId)
            if !stale.isEmpty || !missing.isEmpty {
                gaps.append(.init(pieceID: item.id, title: item.title,
                                  stale: stale, missing: missing))
            }

            // Fountain element drift is only meaningful for a fully-covered
            // fountain piece: with no source-text fallbacks the two texts differ
            // ONLY by translation, so an element flip is a real screenplay-
            // structure regression the translator should see.
            let isFountain = path.lowercased().hasSuffix(".fountain")
            if isFountain, stale.isEmpty, missing.isEmpty,
               let warning = fountainDrift(title: item.title, entries: derived.entries) {
                driftWarnings.append(warning)
            }
        }

        // Zero-layer guard fires only when there IS something to translate but no
        // records exist — an empty manuscript needs no translation layer.
        let zeroLayer = (!anyRecords && anyTranslatable)
            ? "no translation layer for '\(language)' — run write_translation first"
            : nil
        return Report(gaps: gaps, fountainDriftWarnings: driftWarnings,
                      zeroLayerError: zeroLayer)
    }

    /// Outcome of `applyGate`: either the gate refuses (with the errors and
    /// `logExcerpt` the caller should hand to `jobManager.fail`/`.failed`),
    /// or it passes (with the warnings — allow_stale fallbacks + fountain
    /// drift — the caller should merge into its success-path warnings).
    enum GateResult {
        case blocked(errors: [TectonicLogParser.Diagnostic], logExcerpt: String)
        case passed(warnings: [TectonicLogParser.Diagnostic])
    }

    /// The ONE gate-application block for a translated compile — zero-layer
    /// check, then the isBlocked/allowStale block-vs-warn branch, then
    /// fountain-drift warnings — shared verbatim by `CompileOrchestrator
    /// .compile` and `Republisher.republish` (Task 9 F1 round 5: these had
    /// drifted apart, and `Republisher` silently dropped
    /// `fountainDriftWarnings` because it never read that field). Neither
    /// caller may reimplement any part of this switch.
    nonisolated static func applyGate(
        report: Report, language: String, allowStale: Bool
    ) -> GateResult {
        // Zero-layer guard: no records anywhere for the language → refuse
        // unconditionally, even under allow_stale (the "edition" would just
        // be the source book relabeled).
        if let zeroErr = report.zeroLayerError {
            let diag = TectonicLogParser.Diagnostic(
                level: .error, file: nil, line: nil,
                message: zeroErr, contextLines: [])
            return .blocked(
                errors: [diag], logExcerpt: "no_translation_layer: \(language)")
        }

        if report.isBlocked && !allowStale {
            let diags = report.gaps.map { gap in
                TectonicLogParser.Diagnostic(
                    level: .error, file: nil, line: nil,
                    message: describe(gap),
                    contextLines: [
                        "Translate the listed paragraphs with write_translation, or",
                        "re-compile with allow_stale for a source-text fallback edition."
                    ])
            }
            return .blocked(
                errors: diags, logExcerpt: "translation_stale: \(language)")
        }

        // allow_stale (or no gaps): demote gaps to warnings itemizing every
        // fallback paragraph. Fountain element-drift warnings always attach.
        var warnings: [TectonicLogParser.Diagnostic] = []
        if allowStale {
            warnings += report.gaps.map { gap in
                TectonicLogParser.Diagnostic(
                    level: .warning, file: nil, line: nil,
                    message: describe(gap) + " — compiled with source-text fallback",
                    contextLines: [])
            }
        }
        warnings += report.fountainDriftWarnings.map { message in
            TectonicLogParser.Diagnostic(
                level: .warning, file: nil, line: nil,
                message: message, contextLines: [])
        }
        return .passed(warnings: warnings)
    }

    /// `"<title>: N stale (¶a, ¶b), M missing (¶c)"`. Empty lists drop their
    /// parenthetical. Shared by the orchestrator's fail (error) and allow_stale
    /// (warning) paths so the two surfaces itemize identically.
    nonisolated static func describe(_ gap: Report.PieceGap) -> String {
        func idList(_ ids: [String]) -> String {
            ids.isEmpty ? "" : " (" + ids.map { "¶\($0)" }.joined(separator: ", ") + ")"
        }
        return "\(gap.title): \(gap.stale.count) stale\(idList(gap.stale)), "
            + "\(gap.missing.count) missing\(idList(gap.missing))"
    }

    /// The SAME `(sequence, paragraphs)` split `ProjectStoreASTSource` uses: an
    /// OPEN doc reads its live `Document`; a closed doc reads
    /// `derivedCache.state`. Never the raw `.md` (tripwire 20).
    private static func sourceSplit(
        projectStore: ProjectStore, docId: String, path: String
    ) -> (sequence: [String], paragraphs: [String: String]) {
        if let ds = projectStore.documentStore, let doc = ds.document(for: path) {
            return (doc.sequence, doc.paragraphs)
        }
        let state = projectStore.derivedCache.state(forDocId: docId, in: projectStore.url)
        return (state.sequence, state.paragraphs)
    }

    /// Tokenize source vs substituted display text (anchors stripped, matching
    /// what the emitter renders) and return a warning naming the piece + first
    /// divergent line index + both element names, or nil if the element
    /// sequences match. Entries are assumed fully covered, so
    /// `translatedText ?? sourceText` is the translated text.
    private static func fountainDrift(
        title: String, entries: [TranslatedDocument.Entry]
    ) -> String? {
        let sourceText = MarkdownDisplayFilter.stripAnchors(
            entries.map(\.sourceText).joined(separator: "\n\n"))
        let subText = MarkdownDisplayFilter.stripAnchors(
            entries.map { $0.translatedText ?? $0.sourceText }.joined(separator: "\n\n"))
        // Two uncached FountainTokenizer parses per fully-covered fountain
        // piece, on every gated compile. Accepted: tectonic dominates compile
        // cost by orders of magnitude, so re-parsing here isn't worth a cache.
        let sourceLines = FountainTokenizer().parse(sourceText).lines.map(\.element)
        let subLines = FountainTokenizer().parse(subText).lines.map(\.element)
        if sourceLines == subLines { return nil }

        let n = min(sourceLines.count, subLines.count)
        for i in 0..<n where sourceLines[i] != subLines[i] {
            return "\(title): fountain element drift at line \(i) — "
                + "source \(elementName(sourceLines[i])), "
                + "translated \(elementName(subLines[i]))"
        }
        // Same prefix, differing length.
        let i = n
        let src = i < sourceLines.count ? elementName(sourceLines[i]) : "none"
        let sub = i < subLines.count ? elementName(subLines[i]) : "none"
        return "\(title): fountain element drift at line \(i) — "
            + "source \(src), translated \(sub)"
    }

    private static func elementName(_ e: ScreenplayElement) -> String {
        switch e {
        case .action: return "action"
        case .sceneHeading: return "scene heading"
        case .character: return "character"
        case .dialogue: return "dialogue"
        case .parenthetical: return "parenthetical"
        case .transition: return "transition"
        case .centered: return "centered"
        case .lyric: return "lyric"
        case .section(let level): return "section(\(level))"
        case .synopsis: return "synopsis"
        case .pageBreak: return "page break"
        case .boneyard: return "boneyard"
        case .note: return "note"
        case .titlePage: return "title page"
        }
    }
}
