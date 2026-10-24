import Foundation

/// **A figure op's undo** (ADR 0023: undo appends a compensating op, never
/// removes one). Pure; the host registers the result on its window's
/// `UndoManager`. Each inverse reads only the payload, which carries what the
/// op replaced (`prior`, `priorAfter`, a setting's prior, `priorImage`).
public enum FigureInverse {

    /// The op that undoes `payload` under `kind`, or nil when there is none:
    /// - a cell set swaps `next` and `prior`;
    /// - an insert becomes a delete of the same id;
    /// - a move becomes a move back to `priorAfter`;
    /// - a setting swaps its value and prior;
    /// - an image set swaps to `priorImage` — nil when there was none, since
    ///   no op clears an image;
    /// - **a delete has none in 6a**: reviving a tombstone needs plan 6b's
    ///   revive, so a surface must not offer undo for a delete until then;
    /// - create, park, resume and pins have none (their undo is plan 6b's call).
    public static func inverse(of payload: FigureOpPayload, kind: OpKind) -> (OpKind, FigureOpPayload)? {
        guard FigureOpPayload.validate(kind: kind, payload: payload) else { return nil }
        switch kind {
        case .figureCellSet:
            return (.figureCellSet, FigureOpPayload(cell: payload.cell, next: payload.prior, prior: payload.next))

        case .figureStructure:
            guard let change = payload.structure else { return nil }
            let back: FigureStructureChange
            switch change {
            case let .insertRow(id, _): back = .deleteRow(id)
            case let .insertColumn(id, _): back = .deleteColumn(id)
            case .deleteRow, .deleteColumn: return nil
            case let .moveRow(id, after, priorAfter): back = .moveRow(id, after: priorAfter, priorAfter: after)
            case let .moveColumn(id, after, priorAfter): back = .moveColumn(id, after: priorAfter, priorAfter: after)
            }
            return (.figureStructure, FigureOpPayload(structure: back))

        case .figureSettings:
            guard let change = payload.settings else { return nil }
            let back: FigureSettingsChange
            switch change {
            case let .headerRows(rows, prior): back = .headerRows(prior, prior: rows)
            case let .totalRow(total, prior): back = .totalRow(prior, prior: total)
            case let .columnWidth(column, width, prior): back = .columnWidth(column, prior, prior: width)
            }
            return (.figureSettings, FigureOpPayload(settings: back))

        case .figureImageSet:
            guard let prior = payload.priorImage else { return nil }
            return (.figureImageSet, FigureOpPayload(image: prior, priorImage: payload.image))

        default:
            return nil
        }
    }

    /// **One undo for a whole visit** (plan 7's one ⌘Z): the inverses of
    /// `visit`, last op first. All or nothing — when any op in the visit has no
    /// inverse the answer is empty, so a surface offers no undo rather than half
    /// of one.
    public static func compensating(visit: [(OpKind, FigureOpPayload)]) -> [(OpKind, FigureOpPayload)] {
        var out: [(OpKind, FigureOpPayload)] = []
        out.reserveCapacity(visit.count)
        for (kind, payload) in visit.reversed() {
            guard let inv = inverse(of: payload, kind: kind) else { return [] }
            out.append(inv)
        }
        return out
    }
}
