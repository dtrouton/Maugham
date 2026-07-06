import Foundation
import MaughamCore

/// Maps a tokenizer-produced `FountainScript` into publish-layer
/// `ProjectAST.FountainNode`s. This is the single bridge from the real Fountain
/// tokenizer (the same one the editor uses) into the emitter vocabulary, so
/// published PDF/EPUB output classifies exactly as the on-screen editor does.
///
/// A single forward pass over `script.lines` drives a small state machine:
///
/// - **Author-only / organizational elements emit nothing** — `.boneyard`,
///   `.note` (block form), `.synopsis`, `.section`, and `.titlePage` lines are
///   skipped. The title page instead comes from `script.titlePage`, mapped once
///   as a leading `.titlePage` node.
/// - **Action coalesces**: consecutive `.action` lines join with a space into
///   one `.action`; a blank/zero-length action line flushes the buffer and
///   emits nothing itself (blank lines only delimit).
/// - **Character blocks**: a `.character` cue starts a block; following
///   `.dialogue` lines coalesce into one `.dialogue`, a `.parenthetical` flushes
///   the buffered dialogue and stands alone. The block ends at a blank line or a
///   new structural element.
/// - **Dual dialogue**: when a cue line is `isDualSecond`, its block pairs with
///   the immediately preceding character block into one `.dualDialogue`.
/// - **Inline `[[notes]]`** are stripped from action/dialogue/parenthetical text
///   before inline parsing (see `stripInlineNotes`).
public enum FountainNodeMapper {

    public static func map(_ script: FountainScript) -> [ProjectAST.FountainNode] {
        var out: [ProjectAST.FountainNode] = []

        // Title page comes from the tokenizer's dedicated pre-pass, not the
        // `.titlePage` body lines (which we skip below).
        if let fields = script.titlePage, !fields.isEmpty {
            out.append(.titlePage(fields.map {
                ProjectAST.TitleField(key: $0.key, value: $0.value)
            }))
        }

        // Buffered run of consecutive action lines awaiting a flush.
        var actionBuffer: [String] = []
        // The most recently appended character block (already in `out`), tracked
        // so a following dual-second cue can lift it into a `.dualDialogue`. Only
        // survives across blank lines — any emitted non-dual node clears it.
        var lastCharacterBlock: [ProjectAST.FountainNode]?

        func flushAction() {
            guard !actionBuffer.isEmpty else { return }
            let joined = actionBuffer.joined(separator: " ")
            out.append(.action(FountainInline.parse(joined)))
            actionBuffer = []
            lastCharacterBlock = nil
        }

        let lines = script.lines
        var i = 0
        while i < lines.count {
            let line = lines[i]
            switch line.element {
            case .titlePage, .boneyard, .note, .synopsis, .section:
                // Author-only / organizational / title-page-body — emit nothing.
                // These never interrupt an action run mid-paragraph in practice
                // (a blank line precedes them), but if one does appear it simply
                // doesn't extend the buffer.
                i += 1

            case .action:
                let content = stripInlineNotes(line)
                if content.isEmpty {
                    flushAction()   // blank line: delimiter only
                } else {
                    actionBuffer.append(content)
                }
                i += 1

            case .sceneHeading:
                flushAction()
                out.append(.sceneHeading(line.content, sceneNumber: line.sceneNumber))
                lastCharacterBlock = nil
                i += 1

            case .transition:
                flushAction()
                out.append(.transition(line.content))
                lastCharacterBlock = nil
                i += 1

            case .centered:
                flushAction()
                out.append(.centered(FountainInline.parse(line.content)))
                lastCharacterBlock = nil
                i += 1

            case .lyric:
                flushAction()
                out.append(.lyric(FountainInline.parse(line.content)))
                lastCharacterBlock = nil
                i += 1

            case .pageBreak:
                flushAction()
                out.append(.pageBreak)
                lastCharacterBlock = nil
                i += 1

            case .character:
                flushAction()
                let isDual = line.isDualSecond
                let (block, next) = consumeCharacterBlock(lines, from: i)
                i = next
                if isDual, let left = lastCharacterBlock {
                    // Lift the preceding block (its nodes are the tail of `out`)
                    // and replace both with a dual-dialogue pair.
                    out.removeLast(left.count)
                    out.append(.dualDialogue(left: left, right: block))
                    lastCharacterBlock = nil
                } else {
                    out.append(contentsOf: block)
                    lastCharacterBlock = block
                }

            case .dialogue, .parenthetical:
                // Orphan dialogue/parenthetical with no preceding cue — treat as
                // action text so nothing is silently dropped.
                let content = stripInlineNotes(line)
                if !content.isEmpty { actionBuffer.append(content) }
                i += 1
            }
        }

        flushAction()
        return out
    }

    // MARK: - Character block

    /// Consumes a `.character` cue at `start` and its following
    /// `.dialogue`/`.parenthetical` lines into one block. Consecutive dialogue
    /// lines coalesce (joined with a space); a parenthetical flushes the buffered
    /// dialogue and stands alone. Returns the block and the index just past it.
    private static func consumeCharacterBlock(
        _ lines: [FountainLine], from start: Int
    ) -> (block: [ProjectAST.FountainNode], next: Int) {
        var block: [ProjectAST.FountainNode] = [.character(lines[start].content)]
        // Consecutive stretches of dialogue text awaiting a flush, separated
        // by held-blank markers (`nil`) so the break survives into the
        // parsed inline output as `.lineBreak` instead of being lost to a
        // joining space. A held blank (a `.dialogue` line with empty content
        // — the tokenizer only emits that shape for a two-space held line;
        // a real blank line is `.action` and hits `default: break loop`
        // below) pauses the block rather than ending it.
        var dialogueBuffer: [String?] = []

        func flushDialogue() {
            guard !dialogueBuffer.isEmpty else { return }
            var inlines: [ProjectAST.Inline] = []
            var stretch: [String] = []
            func flushStretch() {
                guard !stretch.isEmpty else { return }
                inlines += FountainInline.parse(stretch.joined(separator: " "))
                stretch = []
            }
            for entry in dialogueBuffer {
                if let text = entry {
                    stretch.append(text)
                } else {
                    flushStretch()
                    inlines.append(.lineBreak)
                }
            }
            flushStretch()
            block.append(.dialogue(inlines))
            dialogueBuffer = []
        }

        var i = start + 1
        loop: while i < lines.count {
            let line = lines[i]
            switch line.element {
            case .dialogue:
                let content = stripInlineNotes(line)
                if content.isEmpty {
                    dialogueBuffer.append(nil)   // held blank: pause, don't end
                } else {
                    dialogueBuffer.append(content)
                }
            case .parenthetical:
                flushDialogue()
                block.append(.parenthetical(FountainInline.parse(stripInlineNotes(line))))
            default:
                break loop
            }
            i += 1
        }
        flushDialogue()
        return (block, i)
    }

    // MARK: - Inline note exclusion

    /// Removes inline `[[…]]` note substrings from a line's visible content
    /// before inline parsing so author notes never reach published text.
    ///
    /// The tokenizer records inline notes as `.note` `inlineSpans` with
    /// *document*-relative ranges, whereas `line.content` is marker-stripped
    /// line text — so the two coordinate spaces don't align without fragile
    /// offset bookkeeping. We instead strip `[[…]]` textually from `content`:
    /// it's coordinate-free, and whole-line notes are already their own omitted
    /// `.note` element, so only genuinely inline notes remain to remove here.
    /// The result is trimmed and internal double-spaces (left by a mid-line
    /// removal) collapse to single spaces.
    static func stripInlineNotes(_ line: FountainLine) -> String {
        let content = line.content
        guard content.contains("[[") else {
            return content.trimmingCharacters(in: .whitespaces)
        }
        var result = ""
        var scanIndex = content.startIndex
        while let open = content.range(of: "[[", range: scanIndex..<content.endIndex) {
            result += content[scanIndex..<open.lowerBound]
            if let close = content.range(of: "]]", range: open.upperBound..<content.endIndex) {
                scanIndex = close.upperBound
            } else {
                // Unterminated — keep the rest verbatim (shouldn't happen: the
                // tokenizer routes unterminated notes to the block `.note` state).
                result += content[open.lowerBound..<content.endIndex]
                scanIndex = content.endIndex
            }
        }
        result += content[scanIndex..<content.endIndex]

        // Collapse whitespace left where an inline note was excised.
        let collapsed = result
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }
}
