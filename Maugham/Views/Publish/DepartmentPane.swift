import SwiftUI
import MaughamCore

/// **The department desk** (publish-department P4 Task 1) — Publish's own
/// working pane, and `ReviewBoardPane`'s sibling one persona over.
///
/// Review got a board saying where every piece stands on every pass; Publish
/// gets a desk saying where the book's DESIGN stands and where each language
/// EDITION stands. Two sections, and the milestone fills them in order: the
/// language rows and their edition briefs (Task 2), a translation run (Task 3),
/// and the designer's own row with a direction and a run (Task 4). This task is
/// the seat and the skeleton — the pane reads, and nothing here acts yet.
///
/// **It takes values, never a store** (tripwire 4, and the sibling's rule for
/// the sibling's reason). Every input below is a plain value assembled by the
/// mount in `DetailPaneToggle`, so a desk of twenty languages costs twenty rows
/// of layout and no I/O, and the whole surface is mountable in a test with no
/// project on disk — which is what `DepartmentPaneTests` does. The derivations
/// those values come from are expensive on purpose: the language union walks
/// every manuscript document's translation store, and the proposal list reads
/// `.maugham/design/proposals/`. Neither may ever happen on this body path.
///
/// **The empty state is honest about which of the two is missing.** A project
/// with no translations and no design round has nothing for a department to do,
/// and says so rather than drawing two headings over nothing. What it must not
/// do is read as broken: `DepartmentDesk.emptiness` owns that sentence, so the
/// truth table is assertable without mounting anything and the pane cannot
/// disagree with itself about what it is showing.
struct DepartmentPane: View {
    /// The project's title, as the sibling board takes it — the desk is a
    /// project-level surface and names the book it is the department for.
    let title: String
    /// The languages this book has editions in, as BCP-47 tags. **Task 2's
    /// union**, computed by the mount off the body path: it is the same one
    /// `translation_status` reports, and this pane derives no second version of
    /// it.
    let languages: [String]
    /// How many design proposals the designer has staged. **Task 4 replaces
    /// this count with the proposals themselves** (the newest pending one's
    /// badge, the round's age, its status); a count is what the skeleton can
    /// honestly draw with no verbs behind it.
    let designProposalCount: Int

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let emptiness = DepartmentDesk.emptiness(
                languageCount: languages.count,
                proposalCount: designProposalCount) {
                ContentUnavailableView {
                    Label(emptiness.title, systemImage: "person.2")
                } description: {
                    Text(emptiness.description)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                desk
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
        }
        .padding(8)
    }

    /// The two sections. A `ScrollView` because a book with a dozen editions is
    /// taller than the column, and a right-column pane may never grow the split
    /// view past the window it is a column of
    /// (`DetailPaneColumnHeightCensusTests`).
    private var desk: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section(DepartmentDesk.designHeading) {
                    Text(DepartmentDesk.designSummary(proposalCount: designProposalCount))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                section(DepartmentDesk.languagesHeading) {
                    if languages.isEmpty {
                        Text(DepartmentDesk.noLanguagesYet)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(languages, id: \.self) { language in
                            languageRow(language)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func section<Content: View>(
        _ heading: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One edition. Task 2 gives the row its translator, its fresh/stale/missing
    /// figures, its open queries and the door to its brief; today it is the
    /// language itself, which is the fact the desk already knows.
    private func languageRow(_ language: String) -> some View {
        HStack(spacing: 6) {
            Text(TranslationReviewIndicator.displayLabel(forLanguageTag: language))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// **What the desk says when there is little to say** (publish-department P4
/// Task 1) — the empty state's words and the two section headings, as values.
///
/// Split out of the pane's body for `ReviewBoardOpenNotes`' reason: the truth
/// table is then assertable with nothing mounted, and the words the writer reads
/// live in one place rather than three arms of a `ViewBuilder`.
enum DepartmentDesk {

    static let designHeading = "Design"
    static let languagesHeading = "Languages"

    /// What the Languages section says while the book has one edition only —
    /// the state a project is in until somebody translates a paragraph. Drawn
    /// only when the DESIGN half has something, since a desk with neither is
    /// the empty state below.
    static let noLanguagesYet = "No translations yet."

    /// The empty state's two lines: what is not here, and what would put
    /// something here.
    struct Emptiness: Equatable {
        let title: String
        let description: String
    }

    /// The desk's whole empty state, or `nil` when it has something to draw.
    ///
    /// **Both halves must be missing.** A book with a design round and no
    /// translations is a working department, and so is one with three editions
    /// and no design round — hiding either behind an "unavailable" view would
    /// tell the writer their department is empty while it is holding work.
    static func emptiness(languageCount: Int, proposalCount: Int) -> Emptiness? {
        guard languageCount == 0, proposalCount == 0 else { return nil }
        return Emptiness(
            title: "Nothing on the desk yet",
            description: "The book's design rounds and its language editions "
                + "appear here.")
    }

    /// The Design section's one line while the skeleton stands: how many rounds
    /// the designer has proposed. Task 4 replaces it with the round itself.
    static func designSummary(proposalCount: Int) -> String {
        switch proposalCount {
        case 0: return "No design round yet."
        case 1: return "1 design round proposed."
        default: return "\(proposalCount) design rounds proposed."
        }
    }
}
