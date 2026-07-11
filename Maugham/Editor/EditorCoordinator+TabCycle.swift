import Foundation
import MaughamCore
import AppKit
import SwiftUI

// EditorCoordinator — screenplay Tab/Shift+Tab element cycling.
// Extracted from EditorCoordinator.swift (mechanical split).
extension EditorCoordinator {
    // MARK: - Tab/Shift+Tab cycle

    func cycleElementForward(in textView: NSTextView) {
        cycle(in: textView, direction: .forward)
    }

    func cycleElementBackward(in textView: NSTextView) {
        cycle(in: textView, direction: .backward)
    }

    /// Returns the gutter abbreviation (e.g. "CHAR", "SCENE", "DLG") for
    /// the line containing the current cursor position, or nil when no
    /// screenplay is parsed (prose mode) or the cursor isn't on a classified
    /// line with a label.
    func currentElementAbbreviation(in textView: NSTextView) -> String? {
        guard let script = lastParsedScript else { return nil }
        let cursor = textView.selectedRange().location
        guard let line = script.lines.first(where: { line in
            line.range.contains(cursor) ||
                cursor == NSMaxRange(line.range)
        }) else {
            return nil
        }
        return ElementGutterView.abbreviation(for: line.element)
    }

    private enum CycleDirection { case forward, backward }

    private func cycle(in textView: NSTextView, direction: CycleDirection) {
        guard let storage = textView.textStorage,
              let script = lastParsedScript else { return }

        // Empty document: no lines in script. Treat as a single blank line
        // at position 0 with .action as the preceding context.
        if script.lines.isEmpty {
            let target: ScreenplayElement
            if let cached = lastCycleTarget {
                target = advance(from: cached, direction: direction)
            } else {
                target = ScreenplayCycle.startingElement(after: .action)
            }
            let neighborhood = LineNeighborhood(prevIsBlank: true, nextIsBlank: true)
            let result = ScreenplayLineMutator.mutate(line: "", to: target, neighborhood: neighborhood)
            let replaceRange = NSRange(location: 0, length: 0)
            guard textView.shouldChangeText(in: replaceRange, replacementString: result.text) else { return }
            isApplyingTabCycle = true
            defer { isApplyingTabCycle = false }
            storage.replaceCharacters(in: replaceRange, with: result.text)
            textView.didChangeText()
            let targetCursor = NSRange(location: result.cursorOffset, length: 0)
            textView.setSelectedRange(targetCursor)
            // Defensive reapply on the next runloop in case something
            // (theme refresh, layout pass) moves the cursor.
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                if textView.selectedRange() != targetCursor {
                    textView.setSelectedRange(targetCursor)
                }
            }
            if result.text.isEmpty {
                lastCycleTarget = target
                lastCycleTargetLineRange = NSRange(location: 0, length: 0)
            } else {
                lastCycleTarget = nil
                lastCycleTargetLineRange = nil
            }
            return
        }

        let cursor = textView.selectedRange().location
        guard let activeLine = lineCovering(cursor: cursor, in: script) else { return }
        guard let lineIndex = script.lines.firstIndex(of: activeLine) else { return }

        let prevElement: ScreenplayElement = (lineIndex > 0)
            ? script.lines[lineIndex - 1].element
            : .action
        let isBlank = activeLine.content.isEmpty

        // Choose target.
        let target: ScreenplayElement = chooseTarget(
            activeLine: activeLine,
            prevElement: prevElement,
            isBlank: isBlank,
            direction: direction)

        // Compute neighborhood from script.
        let prevBlank = (lineIndex <= 0)
            || script.lines[lineIndex - 1].content.isEmpty
        let nextBlank = (lineIndex >= script.lines.count - 1)
            || script.lines[lineIndex + 1].content.isEmpty
        let neighborhood = LineNeighborhood(
            prevIsBlank: prevBlank,
            nextIsBlank: nextBlank)

        // Apply mutator. Note: activeLine.content has forced markers stripped,
        // but the mutator works on raw source content. We need the source text
        // of the line (without trailing newline) to pass to the mutator.
        let nsSource = textView.string as NSString
        let lineRangeLength = activeLine.range.length
        // Determine if the line's range includes a trailing newline.
        let hasTrailingNewline: Bool
        if activeLine.range.location + lineRangeLength <= nsSource.length {
            let lastCharRange = NSRange(
                location: activeLine.range.location + lineRangeLength - 1,
                length: 1)
            if lineRangeLength > 0 {
                let lastChar = nsSource.substring(with: lastCharRange)
                hasTrailingNewline = (lastChar == "\n")
            } else {
                hasTrailingNewline = false
            }
        } else {
            hasTrailingNewline = false
        }
        let sourceContentLength = hasTrailingNewline
            ? lineRangeLength - 1
            : lineRangeLength
        let sourceContent = nsSource.substring(
            with: NSRange(location: activeLine.range.location,
                          length: sourceContentLength))

        let result = ScreenplayLineMutator.mutate(
            line: sourceContent,
            to: target,
            neighborhood: neighborhood)

        // Replace only the line's content portion (not trailing newline).
        let replaceRange = NSRange(
            location: activeLine.range.location,
            length: sourceContentLength)

        // Swift undo + delegate notification dance.
        guard textView.shouldChangeText(in: replaceRange, replacementString: result.text) else { return }
        isApplyingTabCycle = true
        defer { isApplyingTabCycle = false }
        storage.replaceCharacters(in: replaceRange, with: result.text)
        textView.didChangeText()

        let cursorLocation = activeLine.range.location + result.cursorOffset
        let targetCursor = NSRange(location: cursorLocation, length: 0)
        textView.setSelectedRange(targetCursor)
        // Defensive reapply on the next runloop.
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            if textView.selectedRange() != targetCursor {
                textView.setSelectedRange(targetCursor)
            }
        }

        // Update lastCycleTarget lifecycle.
        let newContentLength = (result.text as NSString).length
        let newLineRange = NSRange(
            location: activeLine.range.location,
            length: newContentLength)
        if isBlank && result.text.isEmpty {
            // Line stayed empty — preserve target for subsequent Tab.
            lastCycleTarget = target
            lastCycleTargetLineRange = newLineRange
        } else {
            lastCycleTarget = nil
            lastCycleTargetLineRange = nil
        }
    }

    private func chooseTarget(
        activeLine: FountainLine,
        prevElement: ScreenplayElement,
        isBlank: Bool,
        direction: CycleDirection
    ) -> ScreenplayElement {
        if isBlank, let cached = lastCycleTarget {
            return advance(from: cached, direction: direction)
        }
        if isBlank {
            return ScreenplayCycle.startingElement(after: prevElement)
        }
        return advance(from: activeLine.element, direction: direction)
    }

    private func advance(from element: ScreenplayElement,
                         direction: CycleDirection) -> ScreenplayElement {
        switch direction {
        case .forward:  return ScreenplayCycle.cycleForward(from: element)
        case .backward: return ScreenplayCycle.cycleBackward(from: element)
        }
    }

    private func lineCovering(cursor: Int, in script: FountainScript) -> FountainLine? {
        for line in script.lines {
            let end = line.range.location + line.range.length
            // Match if cursor strictly inside non-zero range, OR exactly at the
            // location of a zero-length line (trailing empty line).
            if line.range.length > 0 && line.range.location <= cursor && cursor < end {
                return line
            }
            if line.range.length == 0 && cursor == line.range.location {
                return line
            }
        }
        return script.lines.last
    }
}
