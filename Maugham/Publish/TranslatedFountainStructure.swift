import Foundation
import MaughamCore

/// Carries a source paragraph's Fountain STRUCTURE across to its translation.
///
/// The translation layer is keyed per source paragraph, and a translation must
/// never change a block's structural role — but the publish path re-tokenizes
/// the translated text, and Fountain's inference is written for Latin script:
/// `ЕКСТ. ТЕРАСА - ДАН` matches none of `INT./EXT./EST./I/E.`, is uppercase,
/// and so re-parses as a character cue. The first Serbian preview of a
/// screenplay emitted every one of its ~45 sluglines as `\character{…}`
/// (2026-08-27). The same inference failure awaits every non-Latin script,
/// every language that translates INT/EXT, an unforced `CUT TO:` rendered in
/// Cyrillic, and any language whose cue casing differs.
///
/// The source element is authoritative. This tokenizes the source paragraph
/// and the translated paragraph side by side and, where the two disagree on a
/// line and the source's element has a forced marker in Fountain's own grammar
/// (`.` heading, `>` transition, `@` cue, `!` action, `~` lyric), prefixes the
/// translated line with that marker. The result is ordinary Fountain: the ONE
/// tokenizer the editor, the phone and the emitter share classifies it as the
/// source, `FountainLine.content` strips the marker, and nothing downstream
/// learns a new rule. The marker is injected here, never asked of a translator
/// — pushing a parser detail onto every translator in every language was
/// considered and rejected.
///
/// Where the two paragraphs do not have the same number of lines the structure
/// cannot be aligned and the translated text is returned untouched; that
/// residual is exactly what `TranslationCoverage`'s drift warning reports,
/// since it reads the same preserved text (`displayText(for:)`) the emitter
/// renders. A warning therefore means the output IS affected, never that it
/// was quietly fixed.
enum TranslatedFountainStructure {

    /// The translated text with the source paragraph's line elements forced
    /// wherever a re-parse would otherwise disagree. Identity when the two
    /// already agree line for line (so an identity translation reproduces the
    /// source AST byte-for-byte — `ASTTranslationSubstitutionTests`).
    static func preserving(source: String, translated: String) -> String {
        let tokenizer = FountainTokenizer()
        let sourceLines = tokenizer.parse(source).lines
        let translatedLines = tokenizer.parse(translated).lines
        guard !sourceLines.isEmpty,
              sourceLines.count == translatedLines.count else { return translated }

        let ns = translated as NSString
        // The tokenizer's line ranges tile the text (each includes its own
        // terminator). Refuse to rebuild from anything that doesn't — a
        // reassembly that dropped a character would lose a writer's words.
        guard translatedLines.reduce(0, { $0 + $1.range.length }) == ns.length
        else { return translated }

        var pieces: [String] = []
        var marked: [Int] = []
        for (i, (src, dst)) in zip(sourceLines, translatedLines).enumerated() {
            let raw = ns.substring(with: dst.range)
            guard src.element != dst.element, !dst.isForced,
                  let marker = forcedMarker(for: src.element)
            else { pieces.append(raw); continue }
            pieces.append(inserting(marker, into: raw))
            marked.append(i)
        }
        guard !marked.isEmpty else { return translated }

        // Prove every marker took before handing the text on: a `.` in front
        // of a line that already begins `..` is not a forced heading in
        // Fountain's grammar (`..` is exempt), it is a stray dot in the
        // translator's words. A marker the re-parse does not honour comes
        // back out, and that line is the drift warning's to report.
        let reparsed = tokenizer.parse(pieces.joined()).lines
        guard reparsed.count == sourceLines.count else { return translated }
        var reverted = false
        for i in marked where reparsed[i].element != sourceLines[i].element {
            pieces[i] = ns.substring(with: translatedLines[i].range)
            reverted = true
        }
        if reverted, marked.allSatisfy({ pieces[$0] == ns.substring(with: translatedLines[$0].range) }) {
            return translated
        }
        return pieces.joined()
    }

    /// Per-entry display text for a fountain piece: the translation with the
    /// source's structure preserved, or the source text where there is no
    /// translation (the `allow_stale` fallback). The emitter
    /// (`ProjectStoreASTSource`) and the drift check (`TranslationCoverage`)
    /// both read THIS, so the warning and the output cannot disagree.
    static func displayText(for entry: TranslatedDocument.Entry) -> String {
        guard let translated = entry.translatedText else { return entry.sourceText }
        return preserving(source: entry.sourceText, translated: translated)
    }

    /// Fountain's forced-marker grammar, from the tokenizer's own dispatch
    /// (`FountainTokenizer.classify`). Dialogue and parentheticals have no
    /// marker — they follow a recognised cue — so forcing the cue is what
    /// carries them. Centered text, sections, synopses and the title page are
    /// content-marked on both sides already and are not forced here.
    private static func forcedMarker(for element: ScreenplayElement) -> String? {
        switch element {
        case .sceneHeading: return "."
        case .transition: return ">"
        case .character: return "@"
        case .action: return "!"
        case .lyric: return "~"
        default: return nil
        }
    }

    /// Insert the marker before the line's first non-whitespace character so
    /// it is the first unit the tokenizer trims to. A whitespace-only line
    /// gets it at the front.
    private static func inserting(_ marker: String, into raw: String) -> String {
        guard let idx = raw.firstIndex(where: { !$0.isWhitespace }) else {
            return marker + raw
        }
        return String(raw[..<idx]) + marker + String(raw[idx...])
    }
}
