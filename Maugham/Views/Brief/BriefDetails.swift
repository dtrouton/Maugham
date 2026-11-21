import SwiftUI
import AppKit
import MaughamCore

/// **Brief's foot** (Denver, 2026-11-21: "I agree on dropping clutter") —
/// one quiet line at the bottom of a piece's Brief and the Book's: the
/// piece's SET values, then History. "3,000 words · rome, draft · History";
/// "Details · History" while nothing is set. Teaching belongs at the moment of
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

    /// The values the line can show. Tags alone truncate in the middle.
    enum Value: Equatable { case target, tags, links }

    /// One part of the line, in order.
    enum Part: Equatable {
        /// A set value: which, its words, what VoiceOver says, and the
        /// row-menu sheet it opens (nil: text only).
        case value(Value, text: String, spoken: String, opens: PieceRowMenus.Item?)
        /// Nothing is set: "Details", a menu of these sheets.
        case details(offers: [PieceRowMenus.Item])
        /// The History this Brief pulls up.
        case history(PulledUp)
    }

    /// **The foot line**, from what is set and what the row menu offers.
    /// Set values first — the target, the tags, the links — each opening its
    /// sheet where the row menu offers it; "Details" (a menu of the offered
    /// sheets) only when nothing is set and something is offered; then
    /// History. Publishing has no value here (its settings live in the publish
    /// config, which Brief never reads in a body): it is in the menus. Pure.
    static func parts(target: PieceTargetMenu?, tags: [String], links: Int,
                      offered: [PieceRowMenus.Item], history: PulledUp?) -> [Part] {
        func opens(_ item: PieceRowMenus.Item) -> PieceRowMenus.Item? {
            offered.contains(item) ? item : nil
        }
        var parts: [Part] = []
        if let target, let value = target.current, value > 0 {
            parts.append(.value(.target, text: targetText(value, pages: target.measuresPages),
                                spoken: "\(target.fieldLabel): \(targetText(value, pages: target.measuresPages))",
                                opens: opens(.target)))
        }
        if !tags.isEmpty {
            let joined = tags.joined(separator: ", ")
            parts.append(.value(.tags, text: joined, spoken: "Tags: \(joined)", opens: opens(.tags)))
        }
        if links > 0 {
            let text = links == 1 ? "1 link" : "\(links) links"
            parts.append(.value(.links, text: text, spoken: text, opens: opens(.addLink)))
        }
        if parts.isEmpty, !offered.isEmpty {
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
            offered: offered)
    }
}

/// The foot, drawn: one line of secondary ink that never wraps. The tags
/// give way first, truncating in the middle; the target and History keep
/// their words. Each door is a `Button(.plain)` (keyboard navigation reaches
/// it) that brightens under the pointer and dims while pressed; the menus'
/// sheets are also on the line's context menu, so a writer with a target set
/// still reaches Tags… and Publishing… from here.
struct BriefFootView: View {
    let parts: [BriefFoot.Part]
    /// Where a value's sheet opens: the window's one presenter. Nil opens
    /// nothing (the parts then carry no doors anyway).
    let openSheet: ((PieceRowMenus.Item) -> Void)?
    let onPullUp: (PulledUp) -> Void
    /// The row menu's sheets, for the context menu.
    var offered: [PieceRowMenus.Item] = []

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text(BriefFoot.separator)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                draw(part)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if let openSheet {
                ForEach(offered, id: \.title) { item in
                    Button(item.title) { openSheet(item) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("brief.foot")
    }

    @ViewBuilder
    private func draw(_ part: BriefFoot.Part) -> some View {
        switch part {
        case .value(let value, let text, let spoken, let opens):
            let isTags = value == .tags
            if let opens, let openSheet {
                Button { openSheet(opens) } label: { valueText(text, isTags: isTags) }
                    .buttonStyle(BriefFootButtonStyle())
                    .help(opens.title.replacingOccurrences(of: "\u{2026}", with: ""))
                    .accessibilityLabel(spoken)
                    .accessibilityHint("Opens \(opens.title.replacingOccurrences(of: "\u{2026}", with: ""))")
                    .layoutPriority(isTags ? 0 : 1)
            } else {
                valueText(text, isTags: isTags)
                    .accessibilityLabel(spoken)
                    .layoutPriority(isTags ? 0 : 1)
            }
        case .details(let offers):
            Menu {
                ForEach(offers, id: \.title) { item in
                    Button(item.title) { openSheet?(item) }
                }
            } label: {
                Text(BriefFoot.detailsTitle)
            }
            .menuStyle(.button)
            .buttonStyle(BriefFootButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Target, tags and the piece\u{2019}s other details")
            .accessibilityLabel(BriefFoot.detailsTitle)
            .accessibilityHint("A menu: " + offers.map { $0.title.replacingOccurrences(of: "\u{2026}", with: "") }
                .joined(separator: ", "))
            .accessibilityIdentifier("brief.details")
            .layoutPriority(2)
        case .history(let item):
            Button { onPullUp(item) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text(BriefFoot.historyTitle)
                }
            }
            .buttonStyle(BriefFootButtonStyle())
            .fixedSize()
            .help(item.isProjectHistory
                  ? "Pull up the project\u{2019}s History beside the centre"
                  : "Pull up this piece\u{2019}s History beside the centre")
            .accessibilityLabel(BriefFoot.historyTitle)
            .accessibilityHint(item.isProjectHistory ? "Pulls up the project\u{2019}s History"
                                                     : "Pulls up this piece\u{2019}s History")
            .accessibilityIdentifier("brief.history")
            .layoutPriority(2)
        }
    }

    private func valueText(_ text: String, isTags: Bool) -> some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(isTags ? .middle : .tail)
            .fixedSize(horizontal: !isTags, vertical: false)
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
