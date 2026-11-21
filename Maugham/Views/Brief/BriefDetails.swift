import SwiftUI
import AppKit
import MaughamCore

/// **Details** — a piece's word target, tags, links and publishing, at the
/// foot of its Brief (appraisal 7): what the old Inspector showed, now set
/// from the tree's row menu, shown where a writer looks for it.
///
/// **No second editor, no second writer.** Each line opens the sheet the row
/// menu opens (`PieceRowMenus.Item` → `BinderTreeSectionsState.pieceRowSheet`,
/// presented by the tree's sections), and each is offered by the row menu's
/// own answer (`PieceRowMenus.items`, from `TreeStructureVerbs` and
/// `PieceTargetMenu.decide`): hidden, never disabled (tripwires 47, 51). A
/// value the writer may not change reads as plain text.
enum BriefDetails {

    static let heading = "Details"
    static let setTargetTitle = "Set a target"
    static let addTagsTitle = "Add tags"
    static let publishingTitle = "Publishing settings"

    /// One line: its words, and the row-menu sheet it opens (nil: text only).
    struct Line: Equatable, Identifiable {
        let text: String
        let opens: PieceRowMenus.Item?
        var id: String { opens?.title ?? text }
    }

    /// **What Details draws**, in the row menu's order: the target, the tags,
    /// the links, publishing. A value is shown whether or not it may be
    /// changed; an unset target or no tags shows a quiet "Set a target" / "Add
    /// tags" only where the row menu offers it; links and publishing show
    /// only where the piece has them (links) or the menu offers them
    /// (publishing — its settings live in the publish config, which a Brief
    /// never reads in a body). Pure.
    static func lines(piece: StructureItem, projectType: ProjectType, projectPageTarget: Int?,
                      offered: [PieceRowMenus.Item]) -> [Line] {
        func opens(_ item: PieceRowMenus.Item) -> PieceRowMenus.Item? {
            offered.contains(item) ? item : nil
        }
        var lines: [Line] = []
        if let target = PieceTargetMenu.target(of: piece, projectType: projectType,
                                               projectPageTarget: projectPageTarget) {
            if let value = target.current, value > 0 {
                lines.append(Line(text: "\(target.fieldLabel): \(value.formatted())", opens: opens(.target)))
            } else if offered.contains(.target) {
                lines.append(Line(text: setTargetTitle, opens: .target))
            }
        }
        let tags = piece.tags ?? []
        if !tags.isEmpty {
            lines.append(Line(text: "Tags: " + tags.joined(separator: ", "), opens: opens(.tags)))
        } else if offered.contains(.tags) {
            lines.append(Line(text: addTagsTitle, opens: .tags))
        }
        let links = (piece.links ?? []).count
        if links > 0 {
            lines.append(Line(text: links == 1 ? "1 link" : "\(links) links", opens: opens(.addLink)))
        }
        if offered.contains(.publishing) {
            lines.append(Line(text: publishingTitle, opens: .publishing))
        }
        return lines
    }

    /// Whether the row menu offers Add Link… for a piece in `projectType`:
    /// not a screenplay's one script, which has no other document (the
    /// navigator's own `offersLinks: false`).
    static func offersLinks(projectType: ProjectType) -> Bool {
        projectType.holdsPieces || !projectType.primaryFormat.isScreenplay
    }
}

/// Details, drawn. Reads the piece and the row menu's answer once per body —
/// one piece, never a list (tripwire 4).
struct BriefDetailsView: View {
    let store: ProjectStore
    let docId: String
    /// The window's tree: its cached `publishingIsSetUp`, and the sheet slot
    /// the row menu sets. Nil (a test host) offers nothing to open.
    let tree: BinderTreeSectionsState?

    var body: some View {
        let lines = self.lines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                BriefPane.sectionHeading(BriefDetails.heading)
                ForEach(lines) { line in
                    if let item = line.opens, let tree {
                        Button {
                            tree.pieceRowSheet = PieceRowSheet(item, pieceId: docId)
                        } label: {
                            text(line.text)
                        }
                        .buttonStyle(.plain)
                        .help(item.title.replacingOccurrences(of: "\u{2026}", with: ""))
                    } else {
                        text(line.text)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("brief.details")
        }
    }

    private func text(_ words: String) -> some View {
        Text(words)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private var lines: [BriefDetails.Line] {
        let manifest = store.manifest
        guard let piece = TreeWalk.find(id: docId, in: manifest.structure) else { return [] }
        let offered = tree == nil ? [] : PieceRowMenus.items(
            for: piece, verbs: TreeStructureVerbs.decide(for: piece, in: store),
            publishingIsSetUp: tree?.publishingIsSetUp ?? false,
            offersTarget: PieceRowMenus.target(for: piece, store: store) != nil,
            offersLinks: BriefDetails.offersLinks(projectType: manifest.type))
        return BriefDetails.lines(piece: piece, projectType: manifest.type,
                                  projectPageTarget: manifest.targets?.pageTarget,
                                  offered: offered)
    }
}

/// **How to attach material to a piece whose fold is empty** (appraisal,
/// the empty fold): one quiet line at the foot of its Brief. Whether the fold
/// is empty is asked of the tree's own index (`PieceFoldIndex`, built once
/// per key in the tree's `.task`), never worked out here; nothing is said
/// before the index has been built, or for a piece with no fold (a
/// Collection's reference piece; a screenplay, whose navigator draws none).
///
/// The ways named are the ones this build has (the deleted References
/// pane's empty state named two as well — research, and a region's cards):
/// a research note dragged onto the piece's row (`TreeDropIntent`: linked to
/// a novel's chapter, moved into a Collection piece's folder), and a canvas
/// region whose Piece is set to it (`RegionInspector`; its cards come into
/// the fold, an empty region adds no row). Where the project keeps all its
/// research shared (a short story) the piece's fold IS the research, so a
/// drag onto the row is refused and the line says adding research instead.
enum BriefFoldHint {

    static func line(noun: String, routing: ProjectStore.ResearchRouting) -> String {
        switch routing {
        case .sharedOnly:
            return "Nothing is attached to this \(noun) yet. Research you add in the tree "
                + "is attached to it, and so are the cards in a canvas region whose Piece is set to it."
        case .sharedPlusLink, .pieceFolder:
            return "Nothing is attached to this \(noun) yet. Drag a research note onto it "
                + "in the tree, or set a canvas region\u{2019}s Piece to it to attach the cards inside."
        }
    }

    /// The line for `docId`, or nil where none is drawn. Pure.
    static func line(docId: String, index: PieceFoldIndex, indexIsBuilt: Bool,
                     structure: [StructureItem], projectType: ProjectType) -> String? {
        guard indexIsBuilt, index.entries[docId]?.isEmpty ?? true,
              let piece = TreeWalk.find(id: docId, in: structure),
              let routing = try? ProjectStore.researchRouting(for: piece, projectType: projectType)
        else { return nil }
        return line(noun: FiledUnder.pieceNoun(piece, projectType: projectType), routing: routing)
    }
}

/// **History, at the foot of a Brief** (appraisal 6): a quiet link that
/// pulls up a piece's History, or the project's on the Book's, by the act
/// Brief's other pull-up links use (`onPullUp` → `ProjectWindow.pullUpItem`).
struct BriefHistoryLink: View {
    let item: PulledUp
    let onPullUp: (PulledUp) -> Void

    static let title = "History"

    var body: some View {
        Button { onPullUp(item) } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption2)
                Text(Self.title)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(item.isProjectHistory
              ? "Pull up the project\u{2019}s History beside the centre"
              : "Pull up this piece\u{2019}s History beside the centre")
        .accessibilityIdentifier("brief.history")
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
