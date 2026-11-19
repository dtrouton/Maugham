import SwiftUI
import MaughamCore

/// **Decided** — the writer's dated decisions about one statement, newest
/// first, the newest `BriefDecisions.showing` showing and the rest under an
/// "N earlier" disclosure (spec "Brief" §3).
///
/// Drawn by `RulingsStratumView`, so Edit, Revoke and an orphan's Remove
/// behave as they do under the old Intent pane. The stratum is handed the
/// statement's rulings IN FILE ORDER (its verbs address a ruling by its index
/// there) and the rows to draw in Brief's order (`displayed`).
///
/// **Nothing at all when there are no decisions** — no heading over nothing.
struct BriefDecidedSection: View {
    /// The statement's rulings in file order (the verbs' index space).
    let fileOrder: [Ruling]
    /// The decisions to draw, newest first.
    let decisions: [Ruling]
    let kind: Statement.Kind
    let scope: Statement.Scope
    @Bindable var store: ProjectStore
    let world: DeclaredWorldStore?
    let posture: Posture
    let liveParagraphIds: Set<String>?
    /// Draw the "Decided" heading (a Part draws its pieces' titles instead).
    var showsHeading: Bool = true
    /// Where these decisions were made, named under each (the Book's Brief).
    var origin: RulingOrigin? = nil

    @State private var showsEarlier = false

    static let heading = "Decided"

    /// What Decided draws: nothing when empty; else the newest few, the rest
    /// folded under a title naming how many. Pure.
    struct Layout: Equatable {
        let showing: [Ruling]
        let folded: [Ruling]
        /// "N earlier", or nil when nothing folds.
        let earlierTitle: String?
        var isEmpty: Bool { showing.isEmpty }
    }

    static func layout(_ newestFirst: [Ruling]) -> Layout {
        let split = BriefDecisions.split(newestFirst)
        return Layout(showing: split.showing, folded: split.folded,
                      earlierTitle: split.folded.isEmpty ? nil : "\(split.folded.count) earlier")
    }

    var body: some View {
        let layout = Self.layout(decisions)
        if !layout.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if showsHeading { BriefPane.sectionHeading(Self.heading) }
                stratum(layout.showing)
                if let title = layout.earlierTitle {
                    BriefPane.disclosure(title, isOpen: $showsEarlier)
                    if showsEarlier { stratum(layout.folded) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("brief.decided")
        }
    }

    private func stratum(_ rows: [Ruling]) -> some View {
        RulingsStratumView(
            rulings: fileOrder, kind: kind, scope: scope, store: store, world: world,
            posture: posture, liveParagraphIds: liveParagraphIds,
            displayed: rows, showsTitle: false, origin: origin)
    }
}
