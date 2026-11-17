import Foundation
import MaughamCore

/// **Where each paragraph starts in the editor's display text, and which
/// scene it falls in** (shell plan 2) — from a sequence and its paragraphs,
/// so To resolve can place a closed screenplay's notes among its scenes
/// without a `Document`.
///
/// `starts` is `Document.displayRange(forParagraphId:)`'s rule, the same walk
/// `recomputeDisplayText` renders: each paragraph measured STRIPPED of its task
/// anchors (`RenderFilter.stripTaskAnchorsInline` — invisible on screen), in
/// UTF-16 units (`NSString.length`: an emoji is two), joined by a two-unit
/// `"\n\n"`. Scene starts are `FountainScript.sceneSummaries()`'s
/// `line.range.location` over that same display text, so both sides count in
/// one coordinate system (`ParagraphOffsetsTests`).
enum ParagraphOffsets {

    /// paragraph id → its UTF-16 offset in the display text. A sequence id
    /// with no paragraph is skipped, as `displayRange` skips it; a repeated id
    /// keeps its first offset, as `displayRange` returns the first.
    static func starts(sequence: [String], paragraphs: [String: String]) -> [String: Int] {
        var starts: [String: Int] = [:]
        starts.reserveCapacity(sequence.count)
        var offset = 0
        for id in sequence {
            guard let text = paragraphs[id] else { continue }
            if starts[id] == nil { starts[id] = offset }
            offset += (RenderFilter.stripTaskAnchorsInline(text) as NSString).length
            offset += 2  // the "\n\n" separator between paragraphs
        }
        return starts
    }

    /// paragraph id → the index of the scene it falls in: the last scene
    /// whose start is at or before the paragraph's. A paragraph before the
    /// first scene is ABSENT. `sceneStarts` is in document order (ascending),
    /// as `sceneSummaries()` returns it, so its indices are the summaries'.
    ///
    /// A slugline needs a blank line before it, so it always begins a
    /// paragraph: a heading's own paragraph starts exactly at its scene.
    static func sceneIndex(starts: [String: Int], sceneStarts: [Int]) -> [String: Int] {
        guard !sceneStarts.isEmpty else { return [:] }
        var index: [String: Int] = [:]
        index.reserveCapacity(starts.count)
        for (id, start) in starts {
            // Binary search: the count of scene starts <= start, minus one.
            var low = 0, high = sceneStarts.count
            while low < high {
                let mid = (low + high) / 2
                if sceneStarts[mid] <= start { low = mid + 1 } else { high = mid }
            }
            if low > 0 { index[id] = low - 1 }
        }
        return index
    }
}
