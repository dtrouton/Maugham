import Foundation

/// Pure-logic helpers for Tab/Shift+Tab cycling through screenplay element
/// types. Used by EditorCoordinator when the active mode is ScreenplayMode.
public enum ScreenplayCycle {

    /// Highland-order cycle. Tab advances through this list; Shift+Tab reverses.
    public static let order: [ScreenplayElement] = [
        .action, .character, .dialogue, .parenthetical, .transition,
    ]

    /// Returns the next element in cycle order, wrapping at the end.
    public static func cycleForward(from element: ScreenplayElement) -> ScreenplayElement {
        guard let idx = order.firstIndex(of: element) else { return .character }
        let next = (idx + 1) % order.count
        return order[next]
    }

    /// Returns the previous element in cycle order, wrapping at the start.
    public static func cycleBackward(from element: ScreenplayElement) -> ScreenplayElement {
        guard let idx = order.firstIndex(of: element) else { return .action }
        let prev = (idx - 1 + order.count) % order.count
        return order[prev]
    }

    /// Smart starting point for the FIRST Tab press on a fresh blank line,
    /// based on the previous line's classified element. Subsequent Tab presses
    /// on the same blank line cycle forward from this starting point.
    public static func startingElement(after prev: ScreenplayElement) -> ScreenplayElement {
        switch prev {
        case .action:                 return .character
        case .sceneHeading:           return .action
        case .character:              return .dialogue
        case .parenthetical:          return .dialogue
        case .dialogue:               return .parenthetical
        case .transition:             return .sceneHeading
        case .centered, .lyric, .section, .synopsis,
             .boneyard, .note, .pageBreak:
            return .action
        }
    }
}
