import SwiftUI
import AppKit

/// **What tells the writer that Claude put something on their canvas, and takes
/// them to it.**
///
/// Everything before this slice's Task 9 required the writer to already be
/// looking: a Claude card is tinted, drawn straight, and announced as
/// `CanvasAccessibility.claudeTerm` — all of it on a surface they may not have
/// open, in a persona they may not be in. `add_canvas_scraps` posts
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
/// one, and its `latestId` is a research id that `handleShowLatestMCPNote` takes
/// to the Research segment. Sharing the model would mean one window state that
/// two banners write and whose sentence is composed by the caller who got there
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
    @Binding var persona: Persona
    @Binding var binderSegment: BinderSegment
    /// Forced open by Show — see `Destination.opensInspector`.
    @Binding var showInspector: Bool
    /// Where the persona lands durably. Nil while the project is still loading,
    /// which is also when no banner can be on screen.
    let documentStore: DocumentStore?

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
    /// **The persona is not optional.** `Persona.binderSegments(for:)` gives
    /// `.canvas` to Plan and to nobody else, so setting the segment alone would
    /// put the binder on a surface its own picker does not offer.
    /// `handleShowLatestMCPNote` is the precedent for the rest of the shape: set
    /// the segment, set the selection, dismiss.
    struct Destination: Equatable {
        let persona: Persona
        let binderSegment: BinderSegment
        let selection: CanvasSelection
        /// **A field rather than a bare `showInspector = true` in `show`**, so a
        /// test pins it. Every other navigation-to-a-pane in `ProjectWindow`
        /// forces the column open — `PersonaModifier` on *every* persona switch,
        /// and the detail-segment command with "ensure pane is visible" — and
        /// without it a writer who has closed the column with ⌘⌥I clicks Show and
        /// gets a camera move and a selection with nothing naming what arrived.
        let opensInspector: Bool
    }

    static func destination(forRegion region: CanvasRegionID) -> Destination {
        Destination(persona: .plan, binderSegment: .canvas,
                    selection: .region(region), opensInspector: true)
    }

    /// **The jump does not go through `PersonaModifier`, and that is deliberate.**
    /// Its handler is a `.keyWindow` command carrying the persona-memory rules,
    /// and reaching it would mean posting `.maughamSetPersona` and then writing
    /// `binderSegment` on top of the segment it restores — a correctness argument
    /// resting on SwiftUI delivery order, which is tripwire 2's shape. The
    /// remembered position is left alone: it records where the writer *chose* to
    /// be, and a jump they took to look at something Claude added is not that
    /// choice. The persona itself is persisted, or the next launch reopens in the
    /// old persona with the binder already on the canvas.
    private func show(_ arrival: Arrival) {
        let to = Self.destination(forRegion: arrival.region)
        persona = to.persona
        binderSegment = to.binderSegment
        model.selection = to.selection
        if to.opensInspector { showInspector = true }
        // **And the camera, or Show shows nothing.**
        // `CanvasClaudePlacement.regionOrigin` is `occupied.maxX + gutter` over
        // the union of every node and region, so on any non-empty canvas Claude's
        // region is BY CONSTRUCTION outside the bounding box of the writer's own
        // work — and therefore outside their viewport unless they happen to be
        // panned hard right. The region id and not a point: this side of the
        // window may be holding a scene written before the batch landed (see
        // `CanvasModel.onRevealRequested`), and the model parks the request until
        // a canvas is mounted to honour it.
        model.reveal(arrival.region)
        documentStore?.updateUIState { $0.persona = to.persona }
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
