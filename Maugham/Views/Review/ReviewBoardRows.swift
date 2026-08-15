import Foundation
import MaughamCore

/// **The Review board's row list** (M3 P1 Task 7) — a pure pre-order flattening
/// of the project's structure into the rows the board draws, in tree order.
///
/// Pure by construction, in `TreeSectionDerivation`'s discipline: it takes the
/// manifest's `structure` value and nothing else — no `ProjectStore`, no disk,
/// no `Document`. That is what lets the board's whole truth table be exercised
/// with no window and no project (tripwire 4: nothing on the body path can read
/// a file), and it is why `ReviewBoardPane` takes values rather than a store.
///
/// **Groups are preserved as rows of their own, which no existing view does.**
/// `ProjectAltitudePane` flattens the tree to its documents
/// (`TreeWalk.collect(where: { $0.type == .document })`) and the corkboard shows
/// no grouping at all; the board must, because a reviewer adjudicating a pass
/// works down a part or an act, and a flat column of forty chapters with no Part
/// One in it is the same list the binder already gives them. Hence a walk of its
/// own rather than a `TreeWalk` call: `TreeWalk` has no depth-carrying variant,
/// and depth is the whole point of a header row.
///
/// **Depth rides on `.group` alone, deliberately.** Piece and reference rows
/// share one left edge whatever they are nested under, because the chip columns
/// to their right must line up down the entire board — a chapter indented under
/// Part Two would carry its Structural chip out of the Structural column, which
/// is the one thing a grid of states cannot afford. The group header is the row
/// that says where the writer is in the tree, and it is the row that indents.
enum ReviewBoardRows {

    /// One row of the board.
    ///
    /// `.piece` and `.reference` are both leaves and could have been one case
    /// with a flag; they are two because the board draws them differently and
    /// the difference is not cosmetic. A Collection's `.reference` piece is
    /// another project on disk — its passes are adjudicated in ITS window, and
    /// a row of chips here would be a control over state this manifest does not
    /// own. So the reference row is thin and chip-less, and the case says so at
    /// the type level rather than leaving every reader of the row list to
    /// re-derive it from `pieceKind`.
    struct Row: Equatable, Identifiable {
        enum Kind: Equatable {
            /// A group header. `depth` is 0 for a root group and increments per
            /// level of nesting.
            case group(depth: Int)
            /// A manuscript document: the row that carries a chip per pass.
            case piece
            /// A Collection piece that references another project (`pieceKind
            /// == .reference`). Chip-less — see the type doc.
            case reference
        }

        let kind: Kind
        let item: StructureItem

        var id: String { item.id }
    }

    /// Flattens `structure` in pre-order (a group before its children), one row
    /// per node.
    ///
    /// Nothing is dropped: an empty group still emits its header (a part the
    /// writer has created but not filled is a fact about the manuscript), and a
    /// document that somehow carries children — malformed, but representable —
    /// still has them walked, so no piece can go missing from the board because
    /// of where it was filed.
    static func derive(structure: [StructureItem]) -> [Row] {
        var rows: [Row] = []
        append(structure, depth: 0, into: &rows)
        return rows
    }

    private static func append(
        _ items: [StructureItem], depth: Int, into rows: inout [Row]
    ) {
        for item in items {
            let isGroup = item.type == .group
            if isGroup {
                rows.append(Row(kind: .group(depth: depth), item: item))
            } else if item.pieceKind == .reference {
                rows.append(Row(kind: .reference, item: item))
            } else {
                rows.append(Row(kind: .piece, item: item))
            }
            if let children = item.children, !children.isEmpty {
                // Depth is a fact about GROUP nesting, so only a group deepens
                // it. A document's children (malformed) are walked at the same
                // depth rather than discarded.
                append(children, depth: isGroup ? depth + 1 : depth, into: &rows)
            }
        }
    }
}
