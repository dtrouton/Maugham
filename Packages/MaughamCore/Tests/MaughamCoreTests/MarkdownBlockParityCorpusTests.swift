import XCTest
@testable import MaughamCore

/// Permanent regression corpus for `MarkdownBlockParser`, sourced from
/// `docs/superpowers/notes/2026-07-06-commonmark-fountain-compliance-audit.md`
/// section E (the cross-surface inconsistency table) plus the block-level
/// divergences cataloged in section B5. Each case pins ONE audit-table row
/// (or B5 bullet) to the block-parser's actual output, so a future change
/// that regresses one of the documented behaviors fails here first. Only
/// block-segmentation rows are covered — the audit's inline-emphasis rows
/// (`***x***`, `_x_`, `\*x\*`) are a different layer (`InlineEmphasisScanner`)
/// and are pinned by that scanner's own tests.
final class MarkdownBlockParityCorpusTests: XCTestCase {

    // MARK: Section E, row "Soft line break in paragraph"
    // Audit: Editor/phone/publish/guide/research-preview all disagree on how
    // a soft-wrapped line renders (as-is / space-join / hard-break /
    // separate-blocks). The shared block parser is the common upstream stage
    // for all of them: it must preserve the raw, un-joined lines and let each
    // consumer apply its own soft-break policy downstream.
    func test_auditE_softLineBreak_rawLinesPreserved() {
        XCTAssertEqual(MarkdownBlockParser.parse("first line\nsecond line"),
            [.paragraph(lines: ["first line", "second line"])])
    }

    // MARK: Section E, row "#foo (no space)"
    // Audit: every surface except the in-app Help renderer (A3, a bug) treats
    // `#foo` as plain text, not a heading — CommonMark requires whitespace
    // after the `#` run. This parser is the correct-behavior side of that row.
    func test_auditE_hashFooNoSpace_isParagraphNotHeading() {
        XCTAssertEqual(MarkdownBlockParser.parse("#foo"),
                       [.paragraph(lines: ["#foo"])])
    }

    // MARK: Section E, row "Fenced code" (mangle risk cataloged in B6)
    // Audit: publish/phone/research-preview silently mangle fence contents
    // (stray `*`/backtick get reinterpreted). The shared parser's job is to
    // hand fence interiors back completely verbatim — no inline re-scan —
    // so a consumer choosing to render monospace (Guide) gets clean text.
    func test_auditE_fencedCode_emphasisInsideStaysVerbatim() {
        XCTAssertEqual(MarkdownBlockParser.parse("```\ntext *not emphasis* here\n```"),
            [.fence(lines: ["text *not emphasis* here"], info: nil)])
    }

    // MARK: Section E / A3, row "Ordered list" (Help-corpus row)
    // Audit: publish coalesces list lines into one reflowed paragraph and
    // Help reflows onto a single line — both bugs. The parser must keep each
    // item distinct, for either delimiter form.
    func test_auditE_orderedList_dotDelimiter() {
        XCTAssertEqual(MarkdownBlockParser.parse("1. install\n2. open\n3. connect"),
            [.list(ordered: true, items: [["install"], ["open"], ["connect"]])])
    }
    func test_auditE_orderedList_parenDelimiter() {
        XCTAssertEqual(MarkdownBlockParser.parse("1) install\n2) open"),
            [.list(ordered: true, items: [["install"], ["open"]])])
    }
    func test_auditE_unorderedList_dashDelimiter() {
        XCTAssertEqual(MarkdownBlockParser.parse("- alpha\n- beta"),
            [.list(ordered: false, items: [["alpha"], ["beta"]])])
    }

    // MARK: Section E / A3, row "Pipe table" (Help-corpus row: reference.md's
    // keyboard-shortcut table). Audit: publish/phone/research-preview render
    // literal pipes and Help renders literal pipes too (A3) — all bugs from
    // never recognizing the GFM delimiter row. The parser recognizes it.
    func test_auditE_pipeTable_withDelimiterRow() {
        let src = "| Shortcut | Action |\n|---|---|\n| ⌘N | New project |"
        XCTAssertEqual(MarkdownBlockParser.parse(src),
            [.table(header: ["Shortcut", "Action"],
                    rows: [["⌘N", "New project"]],
                    rawLines: ["| Shortcut | Action |", "|---|---|", "| ⌘N | New project |"])])
    }
    // Companion case: a pipe line with no delimiter row underneath is NOT a
    // table on any surface, including this parser — it degrades to plain text.
    func test_auditE_pipeLine_withoutDelimiterRow_isParagraph() {
        XCTAssertEqual(MarkdownBlockParser.parse("a | b, either way"),
            [.paragraph(lines: ["a | b, either way"])])
    }

    // MARK: Section E, row "Blockquote `>`"
    // Audit: editor requires a space after `>` (a documented divergence, B5);
    // the parser (matching publish/CommonMark) accepts both forms and
    // produces identical quoted content either way.
    func test_auditE_blockquote_withSpace() {
        XCTAssertEqual(MarkdownBlockParser.parse("> quoted text"),
            [.blockquote(blocks: [.paragraph(lines: ["quoted text"])])])
    }
    func test_auditE_blockquote_withoutSpace() {
        XCTAssertEqual(MarkdownBlockParser.parse(">quoted text"),
            [.blockquote(blocks: [.paragraph(lines: ["quoted text"])])])
    }

    // MARK: Section B5, "scene-break detection accepts only exactly-3
    // `***`/`###`/`---`... `----` or `_____` mangles instead" — the shared
    // parser's break-form set: dash runs of ANY length >= 3 are a break
    // (broader than the "-3-only" bug this fixes), bare `***`/`###` are
    // breaks, but `****` is neither (not a pure dash run, not exactly `***`
    // or `###`) and degrades to a paragraph, matching the editor's rule.
    func test_auditB5_breakForms_dashRunAnyLength() {
        XCTAssertEqual(MarkdownBlockParser.parse("----"), [.thematicBreak])
        XCTAssertEqual(MarkdownBlockParser.parse("---------"), [.thematicBreak])
    }
    func test_auditB5_breakForms_bareStarsAndHashes() {
        XCTAssertEqual(MarkdownBlockParser.parse("***"), [.thematicBreak])
        XCTAssertEqual(MarkdownBlockParser.parse("###"), [.thematicBreak])
    }
    func test_auditB5_breakForms_fourStarsIsParagraphNotBreak() {
        XCTAssertEqual(MarkdownBlockParser.parse("****"),
                       [.paragraph(lines: ["****"])])
    }

    // MARK: Section E, row "Images"
    // Audit: only the research preview renders a solo relative image; every
    // other surface either styles the tail as a link (A5, editor) or shows
    // literal text. The parser's `soloImage` case is gated to `./`-relative
    // whole-line references ONLY — a remote URL on its own line is not a
    // solo image and falls through to a plain paragraph.
    func test_auditE_images_soloRelative_isSoloImage() {
        XCTAssertEqual(MarkdownBlockParser.parse("![cover art](./assets/cover.png)"),
            [.soloImage(altText: "cover art", path: "./assets/cover.png",
                        rawLine: "![cover art](./assets/cover.png)")])
    }
    func test_auditE_images_soloRemote_isParagraphNotSoloImage() {
        XCTAssertEqual(MarkdownBlockParser.parse("![cover art](https://example.com/cover.png)"),
            [.paragraph(lines: ["![cover art](https://example.com/cover.png)"])])
    }

    // MARK: B4/B6 "publish rule" — companion to the already-pinned
    // text-then-table case (`MarkdownBlockParserTests.test_tableWithoutBlankLine_staysInParagraph`).
    // List markers likewise do NOT interrupt paragraph accumulation without a
    // preceding blank line — verbatim port of `ProjectASTBuilder`'s paragraph
    // loop, which only breaks on blank/heading/break/quote.
    func test_auditB4_textThenBullet_noBlankLine_staysOneParagraph() {
        XCTAssertEqual(MarkdownBlockParser.parse("text\n- item"),
            [.paragraph(lines: ["text", "- item"])])
    }
}
