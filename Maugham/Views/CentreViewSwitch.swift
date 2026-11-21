import SwiftUI
import MaughamCore

/// **The centre's view switch** (shell p4 Task 4; the design's "The
/// toolbar"): Cards, Outline and Status for the Book or a Part, Book and
/// Status for an edition, and nothing anywhere else. It lives in the window
/// toolbar (`ProjectWindow.TopChromeModifier`) and in the View menu
/// (⌃⌘1/⌃⌘2/⌃⌘3), never in a pane's header.
///
/// The pure half answers what is offered; the window's `chooseCentreView`
/// is the one writer of `bookView`/`editionView` and their `UIState` keys.
enum CentreViewSwitch {

    /// What the switch offers, carrying the view now shown. `.none` hides
    /// the switch: the centre has no views there.
    enum Offer: Hashable {
        case book(BookView)
        case edition(EditionView)
        case none
    }

    /// **The switch shows exactly where `altitudeView` answers non-nil** —
    /// the Book, a Part, an edition — and is asked of it, never restated.
    static func offer(subject: WindowSubject, bookView: BookView, editionView: EditionView,
                      structure: [StructureItem]) -> Offer {
        guard ProjectWindow.altitudeView(subject: subject, bookView: bookView,
                                         editionView: editionView,
                                         structure: structure) != nil else { return .none }
        if case .edition = subject.open { return .edition(editionView) }
        return .book(bookView)
    }

    /// The views `offer` lists, in order, each spelled as the offer it would
    /// make current. Empty for `.none`.
    static func choices(for offer: Offer) -> [Offer] {
        switch offer {
        case .book: return BookView.allCases.map(Offer.book)
        case .edition: return EditionView.allCases.map(Offer.edition)
        case .none: return []
        }
    }

    /// The view's name: the segment's help, its spoken label, and its menu
    /// item's title (`menuTitle`).
    static func title(of choice: Offer) -> String {
        switch choice {
        case .book(.cards): return "Cards"
        case .book(.outline): return "Outline"
        case .book(.status), .edition(.status): return "Status"
        case .edition(.book): return "Book"
        case .none: return ""
        }
    }

    static func symbol(of choice: Offer) -> String {
        switch choice {
        case .book(.cards): return "rectangle.grid.2x2"
        case .book(.outline): return "list.bullet"
        case .book(.status), .edition(.status): return "checklist"
        case .edition(.book): return "book"
        case .none: return ""
        }
    }

    /// "View as Cards" — distinct from View ▸ Outline (⌘⌥O), which selects
    /// the Book's row.
    static func menuTitle(of choice: Offer) -> String { "View as \(title(of: choice))" }

    /// The menu key's digit, with ⌃⌘: the first view 1, Outline 2, Status
    /// always 3, so Status is one key whatever the subject.
    static func keyDigit(of choice: Offer) -> Character? {
        switch choice {
        case .book(.cards), .edition(.book): return "1"
        case .book(.outline): return "2"
        case .book(.status), .edition(.status): return "3"
        case .none: return nil
        }
    }

    /// The menu event's payload: the chosen view as a string
    /// (`MaughamEvent.centreViewKey`), read back by `choice(from:)`.
    static func token(of choice: Offer) -> String? {
        switch choice {
        case .book(let view): return "book.\(view.rawValue)"
        case .edition(let view): return "edition.\(view.rawValue)"
        case .none: return nil
        }
    }

    static func choice(from token: String?) -> Offer? {
        guard let token, let dot = token.firstIndex(of: ".") else { return nil }
        let kind = token[..<dot], raw = String(token[token.index(after: dot)...])
        switch kind {
        case "book": return BookView(rawValue: raw).map(Offer.book)
        case "edition": return EditionView(rawValue: raw).map(Offer.edition)
        default: return nil
        }
    }

    /// **Whether a chosen view may land**: only one the current offer lists.
    /// A menu post that raced a subject change (an edition's Book while the
    /// Book is open) does nothing.
    static func accepts(_ choice: Offer, under offer: Offer) -> Bool {
        choices(for: offer).contains(choice)
    }
}

/// **The toolbar's segmented switch** — icons, each named in `.help`
/// (AREA: no writer-typed text on a toolbar). Drawn only where the offer is
/// not `.none`; the window hides the item otherwise.
struct CentreViewSwitchControl: View {
    let offer: CentreViewSwitch.Offer
    let choose: (CentreViewSwitch.Offer) -> Void

    var body: some View {
        Picker("View", selection: Binding(get: { offer }, set: { choose($0) })) {
            // A `Label`, icon only: the segmented control takes its title as
            // the segment's VoiceOver name and tooltip, which a bare `Image`'s
            // `.help` does not reliably reach.
            ForEach(CentreViewSwitch.choices(for: offer), id: \.self) { choice in
                Label(CentreViewSwitch.title(of: choice),
                      systemImage: CentreViewSwitch.symbol(of: choice))
                    .labelStyle(.iconOnly)
                    .help(CentreViewSwitch.title(of: choice))
                    .tag(choice)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("The centre\u{2019}s view")
    }
}

// MARK: - The View menu's items

struct FocusedCentreViewOfferKey: FocusedValueKey { typealias Value = CentreViewSwitch.Offer }
extension FocusedValues {
    /// The key window's switch offer, for View ▸ View as ….
    var centreViewOffer: CentreViewSwitch.Offer? {
        get { self[FocusedCentreViewOfferKey.self] }
        set { self[FocusedCentreViewOfferKey.self] = newValue }
    }
}

/// View ▸ View as Cards / Outline / Status (⌃⌘1/2/3), or View as Book /
/// Status for an edition: the switch from the keyboard. Checked on the view
/// shown; disabled (the menu bar's convention) where the centre has none.
struct FocusedCentreViewItems: View {
    @FocusedValue(\.centreViewOffer) private var offer

    var body: some View {
        let shown = offer ?? .none
        // With no views, the Book's three stand disabled so the keys stay
        // discoverable.
        let listed = shown == .none
            ? CentreViewSwitch.choices(for: .book(.outline)) : CentreViewSwitch.choices(for: shown)
        ForEach(listed, id: \.self) { choice in
            Toggle(CentreViewSwitch.menuTitle(of: choice), isOn: Binding(
                get: { choice == shown },
                set: { _ in
                    MaughamEvent.post(.maughamChooseCentreView, to: .keyWindow,
                                      payload: [MaughamEvent.centreViewKey:
                                                    CentreViewSwitch.token(of: choice) ?? ""])
                }))
            .keyboardShortcut(KeyEquivalent(CentreViewSwitch.keyDigit(of: choice) ?? "1"),
                              modifiers: [.command, .control])
            .disabled(shown == .none)
        }
    }
}
