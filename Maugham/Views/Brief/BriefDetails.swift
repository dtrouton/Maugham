import SwiftUI
import AppKit
import MaughamCore

/// **Brief's foot** (Denver, 2026-11-21: "I agree on dropping clutter") —
/// one quiet line at the bottom of a piece's Brief and the Book's: the
/// piece's SET values, then the Details menu, then History. "3,000 words ·
/// rome, draft · Details · History"; "Details · History" while nothing is
/// set. Details is always there where the row menu offers anything, so the
/// sheets not shown as values always have a visible door. Teaching belongs at the moment of
/// action, not as permanent text on every new chapter, so nothing here
/// explains itself: no how-to line for an unset value, no empty-fold sentence.
///
/// **No second editor, no second writer.** A value opens the sheet the row
/// menu opens (`PieceRowMenus.Item` → `BinderTreeSectionsState.pieceRowSheet`,
/// presented by the window, `TreeWindowWiring`, so it opens with the tree
/// hidden or under find); "Details" is a menu of the row menu's own sheets;
/// both are offered by the row menu's own answer (`PieceRowMenus.items`, from
/// `TreeStructureVerbs` and `PieceTargetMenu.decide`): hidden, never disabled
/// (tripwires 47, 51). A value the writer may not change reads as plain text.
enum BriefFoot {

    static let detailsTitle = "Details"
    static let historyTitle = "History"
    static let separator = "\u{00B7}"

    /// A sheet's name as VoiceOver says it: its title without the ellipsis.
    static func spokenName(_ item: PieceRowMenus.Item, noun: PieceNoun = .piece) -> String {
        item.title(noun).replacingOccurrences(of: "\u{2026}", with: "")
    }

    /// **What VoiceOver reads as the Details menu's value** (shell p5 Task
    /// 5): its offers, never a pop-up's empty selection.
    static func detailsValue(_ offers: [PieceRowMenus.Item], noun: PieceNoun = .piece) -> String {
        offers.map { spokenName($0, noun: noun) }.joined(separator: ", ")
    }

    /// The values the line can show. Tags alone give way: they truncate in
    /// the middle, then collapse to their count.
    enum Value: Equatable { case target, tags, links }

    /// One part of the line, in order.
    enum Part: Equatable {
        /// A set value: which, its words, its words when the column is too
        /// narrow for them ("2 tags"; nil: never shortened), what VoiceOver
        /// says, and the row-menu sheet it opens (nil: text only).
        case value(Value, text: String, short: String?, spoken: String, opens: PieceRowMenus.Item?)
        /// "Details", a menu of these sheets — every one the row menu
        /// offers, in its order, none marked out.
        case details(offers: [PieceRowMenus.Item])
        /// The History this Brief pulls up.
        case history(PulledUp)
    }

    /// **The foot line**, from what is set and what the row menu offers.
    /// Set values first — the target, the tags, the links — each opening its
    /// sheet where the row menu offers it; then "Details" (a menu of the
    /// offered sheets) wherever something is offered; then History. Publishing has no value here (its settings live in the publish
    /// config, which Brief never reads in a body): it is in the menus. Pure.
    static func parts(target: PieceTargetMenu?, tags: [String], links: Int,
                      offered: [PieceRowMenus.Item], history: PulledUp?) -> [Part] {
        func opens(_ item: PieceRowMenus.Item) -> PieceRowMenus.Item? {
            offered.contains(item) ? item : nil
        }
        var parts: [Part] = []
        if let target, let value = target.current, value > 0 {
            parts.append(.value(.target, text: targetText(value, pages: target.measuresPages), short: nil,
                                spoken: "\(target.fieldLabel): \(targetText(value, pages: target.measuresPages))",
                                opens: opens(.target)))
        }
        if !tags.isEmpty {
            let joined = tags.joined(separator: ", ")
            parts.append(.value(.tags, text: joined, short: tags.count == 1 ? "1 tag" : "\(tags.count) tags",
                                spoken: "Tags: \(joined)", opens: opens(.tags)))
        }
        if links > 0 {
            let text = links == 1 ? "1 link" : "\(links) links"
            parts.append(.value(.links, text: text, short: nil, spoken: text, opens: opens(.addLink)))
        }
        if !offered.isEmpty {
            parts.append(.details(offers: offered))
        }
        if let history { parts.append(.history(history)) }
        return parts
    }

    /// "3,000 words", "1 page". Pure.
    static func targetText(_ value: Int, pages: Bool) -> String {
        let unit = pages ? (value == 1 ? "page" : "pages") : (value == 1 ? "word" : "words")
        return "\(value.formatted()) \(unit)"
    }

    /// Whether the row menu offers Add Link… for a piece in `projectType`:
    /// not a screenplay's one script, which has no other document (the
    /// navigator's own `offersLinks: false`).
    static func offersLinks(projectType: ProjectType) -> Bool {
        projectType.holdsPieces || !projectType.primaryFormat.isScreenplay
    }

    /// A foot: its parts, and the row menu's sheets (the line's context menu).
    struct Line: Equatable {
        let parts: [Part]
        let offered: [PieceRowMenus.Item]
        /// The piece's word, for the sheets' titles (row 71: as row 60).
        var noun: PieceNoun = .piece
    }

    /// A piece's foot, from the window's own values. Nil `tree` (a test
    /// host) offers nothing to open. Main actor: reads the store's manifest
    /// and posture door, once per body — one piece, never a list (tripwire 4).
    @MainActor
    static func line(docId: String, store: ProjectStore,
                     tree: BinderTreeSectionsState?) -> Line {
        let manifest = store.manifest
        guard let piece = TreeWalk.find(id: docId, in: manifest.structure) else {
            return Line(parts: [.history(.history(docId: docId))], offered: [])
        }
        let offered = tree == nil ? [] : PieceRowMenus.items(
            for: piece, verbs: TreeStructureVerbs.decide(for: piece, in: store),
            publishingIsSetUp: tree?.publishingIsSetUp ?? false,
            offersTarget: PieceRowMenus.target(for: piece, store: store) != nil,
            offersLinks: offersLinks(projectType: manifest.type))
        return Line(
            parts: parts(target: PieceTargetMenu.target(of: piece, projectType: manifest.type,
                                                        projectPageTarget: manifest.targets?.pageTarget),
                         tags: piece.tags ?? [], links: (piece.links ?? []).count,
                         offered: offered, history: .history(docId: docId)),
            offered: offered,
            noun: PieceNoun.of(piece, in: manifest))
    }
}

/// The foot, drawn: one line of secondary ink that never wraps. When the
/// column is too narrow, the tags give way first — truncating in the middle,
/// then collapsing to their count ("5 tags") — and the doors (the values
/// that open a sheet, Details and History) never truncate
/// (`BriefFoot.Fit`, tried widest first). Each door is a `Button` or a
/// `Menu`: in the key-view loop when Keyboard navigation is on, activated
/// by Space; each brightens under the pointer and dims while pressed. The
/// same sheets are on the line's context menu.
struct BriefFootView: View {
    let parts: [BriefFoot.Part]
    /// Where a value's sheet opens: the window's one presenter. Nil opens
    /// nothing (the parts then carry no doors anyway).
    let openSheet: ((PieceRowMenus.Item) -> Void)?
    let onPullUp: (PulledUp) -> Void
    /// The row menu's sheets, for the context menu.
    var offered: [PieceRowMenus.Item] = []
    /// The piece's word, for the sheets' titles.
    var noun: PieceNoun = .piece

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(BriefFoot.Fit.allCases, id: \.self) { fit in
                row(fit)
            }
        }
        // A size under Brief's callout: the quietest line on the pane.
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if let openSheet {
                ForEach(offered, id: \.self) { item in
                    Button(item.title(noun)) { openSheet(item) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("brief.foot")
    }

    private func row(_ fit: BriefFoot.Fit) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(fit.shown(parts).enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text(BriefFoot.separator)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                draw(part, fit: fit)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func draw(_ part: BriefFoot.Part, fit: BriefFoot.Fit) -> some View {
        switch part {
        case .value(let value, let text, let short, let spoken, let opens):
            let shown = value == .tags ? fit.tagsText(text, short: short) : text
            let maxWidth = value == .tags ? fit.tagsMaxWidth : nil
            if let opens, let openSheet {
                Button { openSheet(opens) } label: { valueText(shown, maxWidth: maxWidth) }
                    .buttonStyle(BriefFootButtonStyle())
                    .help(BriefFoot.spokenName(opens, noun: noun))
                    .accessibilityLabel(spoken)
                    .accessibilityHint("Opens \(BriefFoot.spokenName(opens, noun: noun))")
                    .accessibilityIdentifier("brief.value.\(value).\(fit)")
            } else {
                valueText(shown, maxWidth: maxWidth)
                    .accessibilityLabel(spoken)
                    .accessibilityIdentifier("brief.value.\(value).\(fit)")
            }
        case .details(let offers):
            Menu {
                ForEach(offers, id: \.self) { item in
                    Button(item.title(noun)) { openSheet?(item) }
                }
            } label: {
                Text(BriefFoot.detailsTitle)
            }
            .menuStyle(.button)
            .buttonStyle(BriefFootButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Target, tags, links and publishing")
            .accessibilityLabel(BriefFoot.detailsTitle)
            // A pop-up's value is its selection, empty here: say the offers.
            .accessibilityValue(BriefFoot.detailsValue(offers, noun: noun))
            .accessibilityHint("A menu")
            .accessibilityIdentifier("brief.details")
        case .history(let item):
            Button { onPullUp(item) } label: { Text(BriefFoot.historyTitle) }
            .buttonStyle(BriefFootButtonStyle())
            .fixedSize()
            .help(item.isProjectHistory
                  ? "Pull up the project\u{2019}s History beside the centre"
                  : "Pull up its History beside the centre")
            .accessibilityLabel(BriefFoot.historyTitle)
            .accessibilityHint(item.isProjectHistory ? "Pulls up the project\u{2019}s History"
                                                     : "Pulls up its History")
            .accessibilityIdentifier("brief.history")
        }
    }

    /// A value's words: whole, or (tags) capped and truncated in the middle.
    /// Its ideal width is the capped one, so `ViewThatFits` measures the cap.
    @ViewBuilder
    private func valueText(_ text: String, maxWidth: CGFloat?) -> some View {
        if let maxWidth {
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: maxWidth, alignment: .leading)
        } else {
            Text(text).lineLimit(1).fixedSize()
        }
    }
}

extension BriefFoot {
    /// **How far the values give way**, widest first; the foot draws the
    /// first that fits the column. The tags go first: whole, then capped (and
    /// truncated in the middle) at two widths, then their count. Past that,
    /// in the narrowest columns, the links' count leaves the line, then the
    /// tags' — each still reached by its sheet in Details. The target, Details
    /// and History keep their words at every step: the doors never truncate.
    /// Pure.
    enum Fit: CaseIterable, Hashable {
        case whole, shortened, shorter, counted, withoutLinks, targetOnly

        /// The parts this step draws.
        func shown(_ parts: [Part]) -> [Part] {
            parts.filter { part in
                guard case .value(let value, _, _, _, _) = part else { return true }
                switch (self, value) {
                case (.withoutLinks, .links), (.targetOnly, .links), (.targetOnly, .tags): return false
                default: return true
                }
            }
        }

        /// The cap on the tags' width; nil draws them whole or counted.
        var tagsMaxWidth: CGFloat? {
            switch self {
            case .whole, .counted, .withoutLinks, .targetOnly: return nil
            case .shortened: return 140
            case .shorter: return 72
            }
        }

        /// The tags' words at this step.
        func tagsText(_ text: String, short: String?) -> String {
            switch self {
            case .whole, .shortened, .shorter: return text
            case .counted, .withoutLinks, .targetOnly: return short ?? text
            }
        }
    }
}

/// The foot's doors: secondary ink that turns primary under the pointer and
/// dims while pressed — the quietest thing on the pane, still a control.
struct BriefFootButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hovering(configuration: configuration)
    }

    private struct Hovering: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .opacity(configuration.isPressed ? 0.55 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// **The proposal Brief's dot stands for, said in Brief** (appraisal 10):
/// while Claude's visual-language proposal waits, one line at the top of
/// every Brief, with a link that pulls Visual Language up. The wording is
/// the Book's Visual Language line's (`BriefPullUpLines.proposedHelp`), the
/// source the segment's dot reads (`VisualLanguageProposalModifier`).
struct BriefProposalNotice: View {
    let onPullUp: (PulledUp) -> Void

    static let line = "Claude proposed a visual language."
    static let linkTitle = "Pull it up to adopt or discard"

    static let linkScheme = "maugham-pull-up"

    /// The sentence and its link as one flowing line, so a narrow column
    /// wraps it as prose.
    static var sentence: AttributedString {
        var text = AttributedString(line + " ")
        var link = AttributedString(linkTitle)
        link.link = URL(string: "\(linkScheme):visual-language")
        text.append(link)
        text.append(AttributedString("."))
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                UnreadDot()
                    .accessibilityHidden(true)
                Text(Self.sentence)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == Self.linkScheme { onPullUp(.visualLanguage) }
                return .handled
            })
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("brief.proposal")
    }
}
