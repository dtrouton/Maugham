import SwiftUI
import AppKit

/// **What tells the writer that Claude put something on their canvas, and takes
/// them to it.**
///
/// Everything before this slice's Task 9 required the writer to already be
/// looking: a Claude card is tinted, drawn straight, and announced as
/// `CanvasAccessibility.claudeTerm` — all of it on a surface they may not have
/// open. `add_canvas_scraps` posts
/// `.maughamCanvasNodesAdded` when a batch lands; this is the receiver.
///
/// **Extracted, and mounted on `ProjectWindow.body` in one line.** That body is at
/// SwiftUI's type-checker ceiling and has shipped a Release-only build failure
/// before, so window-level behaviour lives in a `ViewModifier` (the file's
/// established pattern — `CanvasPromotionModifier` is the neighbour this is shaped
/// after). The mount line is censused, because deleting it leaves every token in
/// this file present and every test green while nothing reaches the writer.
///
/// **The banner is `MCPNoteBanner`** — the house pattern, reused as the promotion
/// confirmation reuses it, rather than a second transient-banner look.
///
/// **`MCPBannerModel` is deliberately NOT reused, and that is a judgement rather
/// than an oversight.** It is the right *shape* — a title, an accumulating count,
/// an 8-second dismiss — and every noun is wrong: its `bump(title:latestId:)`
/// increments the count by one per call, so a batch of six cards would announce
/// one, and its `latestId` is a research id that `handleShowLatestMCPNote` makes
/// the window's subject. Sharing the model would mean one window state that two
/// banners write and whose sentence is composed by the caller who got there
/// last. What IS shared is the view and the timing.
struct CanvasClaudeArrivalModifier: ViewModifier {

    /// The project this window is on — the delivery scope, not a payload field
    /// the receiver compares. A window on another project must not announce cards
    /// it did not receive (ADR 0021).
    let url: URL
    let window: NSWindow?
    /// The window's live scene, which is what can name the region. Read only from
    /// action closures, never from `body`: `CanvasModel` is `@Observable` with the
    /// whole scene in one stored property that every drag and coast frame writes,
    /// so a `model.scene` read on the body path puts this window on the drag loop
    /// (tripwire 30's shape, and `RegionInspectorPane`'s whole reason for
    /// existing).
    let model: CanvasModel
    /// The window's subject: Show opens the canvas in the centre
    /// (`Destination.subject(from:)`). The window persists it.
    @Binding var subject: WindowSubject
    /// Forced open by Show — see `Destination.opensInspector`.
    @Binding var showInspector: Bool
    /// **Written beside `showInspector`, and the column is wrong without it**:
    /// forcing the column open leaves whatever pane it was on, and with the
    /// canvas as the centre the Inspector is the region inspector Show exists
    /// to reach.
    @Binding var detailSegment: DetailSegment

    /// What is currently being announced, or nil. Held here rather than on
    /// `ProjectWindow` for `CanvasPromotionModifier.confirmation`'s reason: it is
    /// this modifier's own presentation state and nothing else reads it.
    @State private var arrival: Arrival?

    // MARK: - What arrived

    /// One batch, as a value — so the banner's sentence is assertable without
    /// hosting SwiftUI. `_ConditionalContent` is branch-invariant and a rendered
    /// `Text` is not inspectable, which is why every decision on this surface is a
    /// value on the model rather than an expression inside a `body`.
    struct Arrival: Equatable {
        /// How many cards. Never zero — see `arrival(from:in:)`.
        let count: Int
        let region: CanvasRegionID
        /// What the canvas calls the region, when this window's scene still holds
        /// it. Nil rather than a placeholder: the count is the fact the writer
        /// needs, and a banner that appears only when a label resolves is one that
        /// vanishes in exactly the confusing case.
        let regionLabel: String?

        /// **"Added to the canvas", and never "saved".** `CanvasStore.writeNow`
        /// swallows every I/O error with `try?` — area-wide and pre-existing — so
        /// nothing on this path can promise the disk. `AddCanvasScrapsTool` says
        /// the same thing about its own response, in the same words.
        var message: String {
            let cards = count == 1 ? "1 card" : "\(count) cards"
            guard let regionLabel else {
                return "Claude added \(cards) to the canvas."
            }
            return "Claude added \(cards) to “\(regionLabel)” on the canvas."
        }
    }

    /// The payload, read through the shared key constants — a rename on either
    /// side is then a compile error rather than a silent nil.
    ///
    /// Static and taking the scene by value so a test drives exactly what the
    /// receiver does. The scene read is legitimate here: this runs from an action
    /// closure, on a post, not inside a view update.
    static func arrival(from note: Notification, in scene: CanvasScene) -> Arrival? {
        guard let count = note.userInfo?[MaughamEvent.canvasScrapCountKey] as? Int,
              count > 0,
              let raw = note.userInfo?[MaughamEvent.canvasRegionIDKey] as? String
        else { return nil }
        let region = CanvasRegionID(raw)
        // `displayLabel`, so a region left on the writer's untitled default is
        // named the way the canvas names it rather than as an empty pair of
        // quotes.
        return Arrival(count: count, region: region,
                       regionLabel: scene.region(region)?.displayLabel)
    }

    /// A second batch while the banner is still up.
    ///
    /// Into the SAME region it adds up — `MCPBannerModel.bump`'s behaviour, for
    /// its reason: the writer wants to know how much is waiting, not how much the
    /// last call brought. Into a DIFFERENT region it replaces, because the banner
    /// names one region and **Show** goes to one region, so a total across two
    /// would be a count the writer cannot reach.
    static func accumulating(_ next: Arrival, onto current: Arrival?) -> Arrival {
        guard let current, current.region == next.region else { return next }
        return Arrival(count: current.count + next.count,
                       region: next.region,
                       regionLabel: next.regionLabel)
    }

    // MARK: - Show

    /// Where the window has to be for the writer to see what arrived — a value,
    /// so the jump is assertable without hosting SwiftUI.
    ///
    /// **The canvas in the centre is the whole of the jump** (shell p1 Task 4;
    /// it was a window mode while a mode decided the centre).
    struct Destination: Equatable {
        /// What the centre opens: always the canvas.
        let open: BinderSubject
        let selection: CanvasSelection
        /// **A field rather than a bare `showInspector = true` in `show`**, so a
        /// test pins it. Every other navigation-to-a-pane in `ProjectWindow`
        /// forces the column open — the detail-segment command with "ensure
        /// pane is visible" — and
        /// without it a writer who has closed the column with ⌘⌥I clicks Show and
        /// gets a camera move and a selection with nothing naming what arrived.
        ///
        /// **It names the pane as well as the column** (2026-08-26): forcing the
        /// column open while leaving `detailSegment` alone had never actually
        /// meant the Inspector — Plan's coercion landed the writer on `.inbox` —
        /// and once the study column can be what is mounted, it landed them on an
        /// inert References shelf. `show` writes `.inspector` beside the reveal.
        let opensInspector: Bool

        /// The window's subject after Show: the canvas opened in the centre
        /// as a double-click on the tree's Canvas row opens it (`open` and
        /// `faces` on the canvas), and whatever was beside put away (shell p1
        /// final fix, M2): the right column asks what is beside first, so a
        /// note left there would hide the region inspector Show opens.
        func subject(from current: WindowSubject) -> WindowSubject {
            var next = current
            next.open = open
            next.faces = open
            next.beside = nil
            return next
        }
    }

    /// **A writer already looking at the canvas is not moved off it** (slice 2):
    /// the canvas already open is written the value it already holds, and its
    /// one mount stays (tripwires 27, 30).
    static func destination(forRegion region: CanvasRegionID) -> Destination {
        Destination(open: .canvas, selection: .region(region),
                    opensInspector: true)
    }

    /// The jump writes the window's subject directly — one value, no event
    /// hop whose delivery order a correctness argument would rest on
    /// (tripwire 2's shape). The window persists the subject.
    private func show(_ arrival: Arrival) {
        let to = Self.destination(forRegion: arrival.region)
        let next = to.subject(from: subject)
        if next != subject { subject = next }
        model.selection = to.selection
        if to.opensInspector {
            showInspector = true
            detailSegment = .inspector
        }
        // **And the camera, or Show shows nothing.**
        // `CanvasClaudePlacement.looseOrigin` is `occupied.maxX + gutter` over
        // the union of every node and region, so on any non-empty canvas Claude's
        // region is BY CONSTRUCTION outside the bounding box of the writer's own
        // work — and therefore outside their viewport unless they happen to be
        // panned hard right. The region id and not a point: this side of the
        // window may be holding a scene written before the batch landed (see
        // `CanvasModel.onRevealRequested`), and the model parks the request until
        // a canvas is mounted to honour it.
        model.reveal(.region(arrival.region))
        self.arrival = nil
    }

    func body(content: Content) -> some View {
        content
            .onProjectEvent(.maughamCanvasNodesAdded, url: url, window: window) { note in
                guard let next = Self.arrival(from: note, in: model.scene) else { return }
                arrival = Self.accumulating(next, onto: arrival)
            }
            .overlay(alignment: .top) {
                if let arrival {
                    MCPNoteBanner(message: arrival.message,
                                  actionTitle: "Show",
                                  onShow: { show(arrival) },
                                  onDismiss: { self.arrival = nil })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: arrival)
            // Eight seconds, as `MCPBannerModel` gives the research sentence — and
            // restarted by every arrival, because the value changes on each one
            // (an accumulated count differs; a different region differs).
            .task(id: arrival) {
                guard arrival != nil else { return }
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                arrival = nil
            }
    }
}
