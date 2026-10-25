import Foundation

/// **A figure op's undo** (ADR 0023: undo appends a compensating op, never
/// removes one). Pure; the host registers the result on its window's
/// `UndoManager`. Each inverse reads only the payload, which carries what the
/// op replaced (`prior`, `priorAfter`, a setting's prior, `priorImage`, a
/// delete's `removed` slice — ruling P-2, a pin's `priorPin` — ruling P-8).
public enum FigureInverse {

    /// The op that undoes `payload` under `kind`, or nil when there is none:
    /// - a cell set swaps `next` and `prior`;
    /// - an insert becomes a delete of the same id with an empty `removed`
    ///   slice, so undoing that delete revives it empty — an insert's redo;
    /// - a delete becomes a revive of the same id carrying its `removed`
    ///   slice (ruling P-1/P-2) — nil for a delete that carries no slice,
    ///   since what it took is not known and a revive would bring back an
    ///   empty row or column as if it had held nothing;
    /// - a revive becomes a delete carrying the same slice;
    /// - a move becomes a move back to `priorAfter`;
    /// - a setting swaps its value and prior;
    /// - an image set swaps to `priorImage` — nil when there was none, since
    ///   no op clears an image;
    /// - a pin set swaps to `priorPin`, or — for a cell that held no pin from
    ///   that source — clears the pin it set (ruling P-8);
    /// - create, park, resume and a pin clear have none.
    public static func inverse(of payload: FigureOpPayload, kind: OpKind) -> (OpKind, FigureOpPayload)? {
        guard FigureOpPayload.validate(kind: kind, payload: payload) else { return nil }
        switch kind {
        case .figureCellSet:
            return (.figureCellSet, FigureOpPayload(cell: payload.cell, next: payload.prior, prior: payload.next))

        case .figureStructure:
            guard let change = payload.structure else { return nil }
            let back: FigureStructureChange
            var removed: FigureRemovedSlice?
            switch change {
            case let .insertRow(id, _): back = .deleteRow(id); removed = FigureRemovedSlice()
            case let .insertColumn(id, _): back = .deleteColumn(id); removed = FigureRemovedSlice()
            case let .deleteRow(id):
                guard let slice = payload.removed else { return nil }
                back = .reviveRow(id); removed = slice
            case let .deleteColumn(id):
                guard let slice = payload.removed else { return nil }
                back = .reviveColumn(id); removed = slice
            case let .reviveRow(id): back = .deleteRow(id); removed = payload.removed
            case let .reviveColumn(id): back = .deleteColumn(id); removed = payload.removed
            case let .moveRow(id, after, priorAfter): back = .moveRow(id, after: priorAfter, priorAfter: after)
            case let .moveColumn(id, after, priorAfter): back = .moveColumn(id, after: priorAfter, priorAfter: after)
            }
            return (.figureStructure, FigureOpPayload(structure: back, removed: removed))

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

        case .figurePinSet:
            guard let prior = payload.priorPin else {
                return (.figurePinClear, FigureOpPayload(cell: payload.cell, pin: payload.pin))
            }
            return (.figurePinSet, FigureOpPayload(cell: payload.cell, pin: prior, priorPin: payload.pin))

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
