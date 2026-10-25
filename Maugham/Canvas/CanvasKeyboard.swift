import AppKit

/// A key the canvas itself acts on, decoded from an event's characters.
enum CanvasKey: Equatable {
    case returnKey, tab, backtab, commandReturn, arrow(CanvasArrow)
}

enum CanvasArrow: Equatable { case up, down, left, right }

/// What a key means inside a scrap's editor.
enum ScrapEditorCommand: Equatable { case finish, makeJoined, makeBelow }

/// Pure keyboard decisions: key tables, clear placement and arrow targets.
/// Holds no Binding, model or view; the editor and the canvas wire it in.
enum CanvasKeyboard {

    static let placementGap: CGFloat = CanvasClaudePlacement.cardGap
    static let placementStepLimit = 200

    // MARK: - Key tables

    private static func stripped(_ m: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        m.subtracting([.numericPad, .function, .capsLock])
            .intersection(.deviceIndependentFlagsMask)
    }

    static func canvasKey(characters: String?, modifiers: NSEvent.ModifierFlags) -> CanvasKey? {
        guard let characters else { return nil }
        let m = stripped(modifiers)
        switch characters {
        case "\r", "\u{3}":
            if m.isEmpty { return .returnKey }
            if characters == "\r", m == .command { return .commandReturn }
            return nil
        case "\t":
            if m.isEmpty { return .tab }
            return m == .shift ? .backtab : nil
        case "\u{19}":
            // AppKit sends ⇧Tab as "\u{19}" with .shift still set.
            return m.isEmpty || m == .shift ? .backtab : nil
        case "\u{F700}": return m.isEmpty ? .arrow(.up) : nil
        case "\u{F701}": return m.isEmpty ? .arrow(.down) : nil
        case "\u{F702}": return m.isEmpty ? .arrow(.left) : nil
        case "\u{F703}": return m.isEmpty ? .arrow(.right) : nil
        default: return nil
        }
    }

    static func editorCommand(selector: Selector, modifiers: NSEvent.ModifierFlags,
                              hasMarkedText: Bool) -> ScrapEditorCommand? {
        guard !hasMarkedText else { return nil }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            return stripped(modifiers).contains(.shift) ? nil : .finish
        case #selector(NSResponder.cancelOperation(_:)):
            return .finish
        case #selector(NSResponder.insertTab(_:)):
            return .makeJoined
        default:
            return nil
        }
    }

    static func editorKeyEquivalent(characters: String?,
                                    modifiers: NSEvent.ModifierFlags) -> ScrapEditorCommand? {
        characters == "\r" && stripped(modifiers) == .command ? .makeBelow : nil
    }

    // MARK: - Placement

    static func newCardSize() -> CGSize {
        let width = CanvasInteraction.defaultScrapWidth
        return CGSize(width: width,
                      height: CanvasScrapMeasure.height(text: "", cardWidth: width))
    }

    /// The first spot at or after `startingAt`, stepping along `stepping`, whose
    /// card (plus a gap on every side) touches no visible measured card and
    /// none of `regions` (`foreignRegions`). After `placementStepLimit` steps
    /// the last candidate is returned. Only `.down` and `.right` are supported
    /// (Tab, ⌘Return and Return all step down).
    static func clearOrigin(startingAt: CGPoint, stepping: CanvasArrow, size: CGSize,
                            in scene: CanvasScene, avoiding regions: [CGRect]) -> CGPoint {
        let frames = scene.unorderedNodes
            .filter { !scene.isHidden($0.id) }
            .compactMap(\.frame) + regions
        precondition(stepping == .down || stepping == .right, "clearOrigin steps down or right only")
        var candidate = startingAt
        for _ in 0..<placementStepLimit {
            let probe = CGRect(origin: candidate, size: size)
                .insetBy(dx: -placementGap, dy: -placementGap)
            let hits = frames.filter { $0.intersects(probe) }
            guard !hits.isEmpty else { return candidate }
            switch stepping {
            case .down, .up:
                candidate.y = hits.map(\.maxY).max()! + placementGap
            case .right, .left:
                candidate.x = hits.map(\.maxX).max()! + placementGap
            }
        }
        return candidate
    }

    /// The regions a key-placed scrap must keep out of under `subject`:
    /// with a chapter selected, every open region bound to ANOTHER chapter.
    /// A scrap landing in one follows that region and is born dimmed.
    static func foreignRegions(for subject: CanvasSubject, in scene: CanvasScene) -> [CGRect] {
        guard case .piece(let piece) = subject else { return [] }
        return scene.unorderedRegions
            .filter { !$0.isCollapsed && $0.boundPieceID != nil && $0.boundPieceID != piece }
            .map(\.frame)
    }

    /// Where Tab's joined scrap (to the right) or ⌘Return's (below) goes,
    /// beside `source`, stepping down until clear.
    ///
    /// **Wholly inside the source's home region or wholly outside it.** The
    /// card gap (12) is narrower than a drop wrap's padding (16), so the first
    /// candidate can hang 4pt over the region's edge without being its member.
    /// Kept inside where it fits; otherwise it starts again one gap past the
    /// region's far edge (right for Tab, below for ⌘Return), from where
    /// stepping down never re-enters it.
    static func nextScrapOrigin(beside source: CanvasNodeID, joined: Bool,
                                in scene: CanvasScene, avoiding regions: [CGRect]) -> CGPoint? {
        guard let frame = scene.node(source)?.frame else { return nil }
        let size = newCardSize()
        let start = joined
            ? CGPoint(x: frame.maxX + placementGap, y: frame.minY)
            : CGPoint(x: frame.minX, y: frame.maxY + placementGap)
        let origin = clearOrigin(startingAt: start, stepping: .down, size: size,
                                 in: scene, avoiding: regions)
        guard let home = CanvasMembership.homeRegion(of: source, in: scene),
              let edge = scene.region(home)?.frame else { return origin }
        let placed = CGRect(origin: origin, size: size)
        guard placed.intersects(edge), !edge.contains(placed) else { return origin }
        let beyond = joined
            ? CGPoint(x: edge.maxX + placementGap, y: start.y)
            : CGPoint(x: start.x, y: edge.maxY + placementGap)
        return clearOrigin(startingAt: beyond, stepping: .down, size: size,
                           in: scene, avoiding: regions)
    }

    // MARK: - Arrow targets

    static func nearest(from: CGPoint, toward: CanvasArrow, in scene: CanvasScene,
                        excluding: CanvasNodeID?) -> CanvasNodeID? {
        var best: (id: CanvasNodeID, d: CGFloat)?
        for node in scene.unorderedNodes {
            guard node.id != excluding, !scene.isHidden(node.id), let f = node.frame else { continue }
            let dx = f.midX - from.x, dy = f.midY - from.y
            let (along, across): (CGFloat, CGFloat)
            switch toward {
            case .right: (along, across) = (dx, dy)
            case .left: (along, across) = (-dx, dy)
            case .down: (along, across) = (dy, dx)
            case .up: (along, across) = (-dy, dx)
            }
            guard along > 0, abs(across) <= along else { continue }
            let d = (dx * dx + dy * dy).squareRoot()
            if let b = best, !(d < b.d || (d == b.d && node.id.raw < b.id.raw)) { continue }
            best = (node.id, d)
        }
        return best?.id
    }

    static func centre(of selection: CanvasSelection, in scene: CanvasScene) -> CGPoint? {
        switch selection {
        case .node(let id):
            guard let f = scene.node(id)?.frame else { return nil }
            return CGPoint(x: f.midX, y: f.midY)
        case .region(let id):
            guard let f = scene.region(id)?.frame else { return nil }
            return CGPoint(x: f.midX, y: f.midY)
        case .line(let id):
            guard let line = scene.line(id), let (a, b) = scene.endpoints(of: line) else { return nil }
            return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
    }
}
