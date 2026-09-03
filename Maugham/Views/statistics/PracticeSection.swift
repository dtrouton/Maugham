import SwiftUI

/// **The writer's own process, on the one surface that asked for it**
/// (editorial letter P3 Task 7, spec `2026-08-29-the-editorial-letter-design.md`
/// §5 surface 1).
///
/// Three things, in the order a writer wants them: where the frontier is and
/// how long since it moved, and the book's three churniest paragraphs. Every
/// row is a jump.
///
/// **Two surfaces, and this is one of them** (global constraint 29,
/// constitution must #2). Nothing about these numbers reaches the footer, the
/// tree, the editor or a badge: they are read in the window the writer opened
/// and the letter the writer asked for. A `TripwireGrepTests` census holds the
/// line.
///
/// **The jump opens the CHAPTER and the copy says so** (global constraint 31).
/// The Statistics window is its own scene, so it navigates by a project-scoped
/// `.maughamNavigateToDocument` whose receiver ignores `paragraph_id` today.
/// The row therefore quotes the paragraph rather than promising a scroll it
/// cannot make — the excerpt is what tells the writer which paragraph is meant,
/// and `.help` says only that the chapter opens.
///
/// **Copy is the writer's register, never the schema's** (global constraint
/// 12). Nothing on screen says `ProcessSignals`, "hotspot", "session index" or
/// "op": what it says is where they are working and what they keep going back
/// to.
///
/// **It decides nothing and reads nothing.** The whole input is a
/// `ProjectPractice` the window derived, and the only verb is the window's own
/// `onSelectChapter`. `nil` is "still walking the op logs", which is a
/// different thing from "nothing to show" and says so differently.
@MainActor
struct PracticeSection: View {

    /// `nil` while the window is still deriving.
    let practice: ProjectPractice?
    /// The window's own jump — a project-scoped `.maughamNavigateToDocument`,
    /// the same closure `WordsByChapterSection` presses.
    let onSelectChapter: (String) -> Void

    // MARK: - Copy
    //
    // Named constants rather than literals in the body, so the tests assert the
    // words the writer reads rather than a paraphrase of them.

    static let title = "Practice"

    /// Nothing has ever been typed new in this project. Not a zero and not a
    /// blank: a book that was imported and only ever revised legitimately has
    /// no frontier, and this is the honest sentence for it.
    static let noFrontierLine = "No new paragraphs typed yet"

    /// A book with a frontier but no churn at all. A quiet line rather than an
    /// empty gap under the frontier row.
    static let noHotspotsLine = "Nothing rewritten more than once yet."

    static let derivingTitle = "Reading your history\u{2026}"
    static let derivingMessage =
        "Maugham is walking this project\u{2019}s edits."

    static let nothingYetTitle = "No practice yet"
    static let nothingYetMessage =
        "Type a paragraph and Maugham starts noticing where you\u{2019}re working."

    /// What a row promises, and the whole of what it promises. Never a scroll
    /// and never a paragraph (global constraint 31).
    static let opensTheChapter = "Opens the chapter"
    static let opensTheScene = "Opens the scene\u{2019}s file"

    /// A document whose op log could not be read is skipped and NAMED
    /// (`ProjectPractice.unreadableDocIds`, RULING-54 lenient). The writer is
    /// told the numbers are SHORT rather than wrong, because that is what a
    /// missing log makes them.
    ///
    /// A closure constant rather than a screenplay-aware function on purpose:
    /// it counts files, and "file" is the one word that is true of a chapter
    /// and of a screenplay's single `.fountain` alike.
    static let unreadableNotice: (Int) -> String = { count in
        let subject = count == 1
            ? "One file\u{2019}s history"
            : "\(count) files\u{2019} history"
        return subject + " couldn\u{2019}t be read, so these numbers are short."
    }

    // MARK: - The lines

    /// Where the writing stands: the place, the paragraph's own words, and how
    /// long ago it moved.
    ///
    /// The forward-motion clause is appended here rather than drawn on a line
    /// of its own because the two facts are one sentence — the frontier without
    /// "moved 2 sessions ago" is a location, and the point of the section is
    /// the motion.
    static func frontierLine(_ practice: ProjectPractice) -> String {
        guard let found = practice.frontier else { return noFrontierLine }
        var line = "Frontier: " + place(of: found.frontier.paragraphId, in: found.row)
        if let words = quoted(found.row.excerpts[found.frontier.paragraphId]) {
            line += " \u{2014} " + words
        }
        // The clause off the frontier already in hand, rather than through
        // `forwardMotionLine`, which would walk every row for the frontier a
        // second time inside one line.
        if let motion = forwardMotion(found.row.signals.sessionsSinceFrontierMoved) {
            line += " \u{00b7} " + motion
        }
        return line
    }

    /// The clause `frontierLine` ends with, and the spec's "forward motion"
    /// (§5) in the writer's words. `nil` with no frontier — "moved 0 sessions
    /// ago" would claim a desk the writer has never sat at.
    static func forwardMotionLine(_ practice: ProjectPractice) -> String? {
        forwardMotion(practice.frontier?.row.signals.sessionsSinceFrontierMoved)
    }

    private static func forwardMotion(_ sessions: Int?) -> String? {
        guard let sessions else { return nil }
        switch sessions {
        case 0: return "moved in this session"
        case 1: return "moved 1 session ago"
        default: return "moved \(sessions) sessions ago"
        }
    }

    /// One churn row: the place, the words, the count.
    static func hotspotLine(
        _ row: ProjectPractice.DocumentRow, _ hotspot: ProcessSignals.Hotspot
    ) -> String {
        var parts = [place(of: hotspot.paragraphId, in: row)]
        if let words = quoted(row.excerpts[hotspot.paragraphId]) { parts.append(words) }
        parts.append(hotspot.rewrites == 1
            ? "rewritten once"
            : "rewritten \(hotspot.rewrites) times")
        return parts.joined(separator: " \u{00b7} ")
    }

    /// Where a paragraph is, in the terms the project is written in.
    ///
    /// A screenplay says the SCENE, because a slugline is how a screenwriter
    /// navigates and the file's title names one thing for the whole script. The
    /// discriminator is the row's own caption map rather than a flag:
    /// `ProjectPractice` fills it only for a screenplay, and leaves out a
    /// paragraph that lives above the first slugline and so belongs to no
    /// scene — which falls back to the title, the only place left to name.
    private static func place(
        of paragraphId: String, in row: ProjectPractice.DocumentRow
    ) -> String {
        row.sceneCaptions[paragraphId] ?? row.title
    }

    /// The paragraph's words in quotation marks, with an ellipsis when the
    /// excerpt was CUT — `ProjectPractice.excerpt` caps without marking it, and
    /// a quotation that stops mid-sentence with no ellipsis reads as the whole
    /// paragraph. `nil` when there are no words to quote, so the line simply
    /// leaves the clause out rather than drawing empty quotes.
    private static func quoted(_ excerpt: String?) -> String? {
        guard let excerpt, !excerpt.isEmpty else { return nil }
        let cut = excerpt.count >= ProjectPractice.excerptCharacterLimit
        return "\u{201C}" + excerpt + (cut ? "\u{2026}" : "") + "\u{201D}"
    }

    // MARK: - The surface

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(Self.title)
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let practice {
            // **Read once per body pass and passed down.** Both are computed
            // properties over the whole book — `frontier` walks every row and
            // `hotspots` merges and sorts every row's own list — and SwiftUI
            // re-reads `body` on any state change in the window. Tripwire 4's
            // rule, one level up from a list row.
            let frontier = practice.frontier
            let hotspots = practice.hotspots
            VStack(alignment: .leading, spacing: 4) {
                if frontier == nil && hotspots.isEmpty {
                    // A `nil` practice is still reading; this one has read and
                    // found nothing. Two states, two sentences.
                    unavailable(Self.nothingYetTitle, Self.nothingYetMessage)
                } else {
                    frontierRow(practice, frontier: frontier)
                    hotspotRows(hotspots, isScreenplay: practice.isScreenplay)
                }
                if !practice.unreadableDocIds.isEmpty {
                    Text(Self.unreadableNotice(practice.unreadableDocIds.count))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            unavailable(Self.derivingTitle, Self.derivingMessage)
        }
    }

    @ViewBuilder
    private func frontierRow(
        _ practice: ProjectPractice,
        frontier: (row: ProjectPractice.DocumentRow, frontier: ProcessSignals.Frontier)?
    ) -> some View {
        if let frontier {
            row(Self.frontierLine(practice),
                docId: frontier.row.id, isScreenplay: practice.isScreenplay)
        } else {
            quietLine(Self.noFrontierLine)
        }
    }

    @ViewBuilder
    private func hotspotRows(
        _ hotspots: [(row: ProjectPractice.DocumentRow, hotspot: ProcessSignals.Hotspot)],
        isScreenplay: Bool
    ) -> some View {
        if hotspots.isEmpty {
            quietLine(Self.noHotspotsLine)
        } else {
            // By offset: a paragraph id is minted per document and two
            // documents can hold the same one, so the id alone is not unique
            // across the book's merged list.
            ForEach(Array(hotspots.enumerated()), id: \.offset) { _, entry in
                // Each row's OWN document — the book's churn is merged across
                // documents, so the third row routinely belongs to a different
                // file than the first.
                row(Self.hotspotLine(entry.row, entry.hotspot),
                    docId: entry.row.id, isScreenplay: isScreenplay)
            }
        }
    }

    /// One pressable line. `Button(.plain)` rather than a tap gesture, the
    /// house rule, and the whole line is the label so what a writer reads and
    /// what VoiceOver announces are the same sentence.
    private func row(_ line: String, docId: String, isScreenplay: Bool) -> some View {
        Button {
            onSelectChapter(docId)
        } label: {
            Text(line)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isScreenplay ? Self.opensTheScene : Self.opensTheChapter)
        .padding(.vertical, 2)
    }

    private func quietLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
    }

    /// Tripwire 15: a `ContentUnavailableView` chains the full frame. SwiftUI
    /// sizes it to its intrinsic content, and an unframed one lets its host's
    /// layout collapse around it.
    private func unavailable(_ title: String, _ message: String) -> some View {
        ContentUnavailableView {
            Text(title)
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
