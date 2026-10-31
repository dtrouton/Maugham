import Foundation
import MaughamCore

// MARK: - A note on a figure, written (report plan 9c-1 Task 3)
//
// A figure's notes ride the figure's own stream (`docId` = the figure id),
// built by Core's `FigureAnnotationOps`. This is the Mac's one door that
// appends a note's CREATION there: the open host's store when this window
// holds the figure, so its fold sees the line; otherwise a windowless store.
// Nothing here reads `figures/<name>.csv` (tripwire 20).

/// Why `addFigureAnnotation` wrote nothing (a parked figure throws
/// `FigureParkedRefused` instead, as every figure verb does).
enum FigureAnnotationWriteError: LocalizedError, Equatable {
    /// The op names a figure this book's registry does not list.
    case unknownFigure(String)
    /// The op is not a note's creation: a disposition or a cell write is the
    /// author's, through the figure's host.
    case notANoteCreation(OpKind)

    var errorDescription: String? {
        switch self {
        case .unknownFigure(let id): "There is no figure \(id) in this book."
        case .notANoteCreation(let kind): "A \(kind.rawValue) op is not a note on a figure."
        }
    }
}

extension DocumentStore {

    /// The op kinds a figure note's creation is (`FigureAnnotationOps.creation`).
    static let figureNoteCreationKinds: Set<OpKind> = [
        .claudeComment, .claudeQuery, .claudeSuggestion, .claudeCraftNote,
    ]

    /// **Append a note's creation to its figure's stream** — `op` as
    /// `FigureAnnotationOps.creation` built it, signed by the device it names
    /// (`OpLogStore.append` picks the file and the key from `op.device`, so an
    /// MCP note stamped with the assistant's device lands in the figure's
    /// `.assistant-` stream under the assistant's key).
    ///
    /// - **Through the open host when this window holds the figure**: its own
    ///   store appends, then the host re-reads its stream (`reload`, the path
    ///   another device's lines take), so its streams and frontier include the
    ///   note and its next edit is minted after it. A failed re-read is logged,
    ///   never thrown: the note is already on disk, and a retry would mint a
    ///   duplicate.
    /// - **Otherwise windowless**: a store built as a load's is
    ///   (`Document.makeLoadOpStore`).
    ///
    /// Then the figure's cached line and the window's cards are dropped, and
    /// `maughamAnnotationsChanged` names the figure once. No CSV render: a
    /// note changes no computed value.
    ///
    /// Refuses a figure the registry does not list, an op that is not a note's
    /// creation, and a figure parked in Research (`FigureParkedRefused`), each
    /// before anything is written. Creation is the reviewer's row, so no
    /// posture is asked (as `add_comment` on a manuscript asks none).
    func addFigureAnnotation(_ op: Op) async throws {
        guard Self.figureNoteCreationKinds.contains(op.kind) else {
            throw FigureAnnotationWriteError.notANoteCreation(op.kind)
        }
        let figureId = op.docId
        guard let record = projectStore?.manifest.figures?.first(where: { $0.id == figureId }) else {
            throw FigureAnnotationWriteError.unknownFigure(figureId)
        }
        if let host = openFigure(forId: figureId) {
            guard host.state.parked == nil else {
                throw FigureParkedRefused(site: "addFigureAnnotation", kind: host.state.kind)
            }
            try await host.opStore.append(op)
            do { try await host.reload() } catch {
                documentLog.error(
                    "figure \(figureId, privacy: .public) did not re-read after a note was added: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            guard try await !figureIsParked(figureId) else {
                throw FigureParkedRefused(site: "addFigureAnnotation", kind: record.kind)
            }
            try await Document.makeLoadOpStore(projectURL: projectURL, presenter: presenter).append(op)
        }
        figureCache.invalidate(figureId: figureId)
        invalidateFigureCards()
        MaughamEvent.postAnnotationsChanged(docId: figureId, projectURL: projectURL)
    }
}
