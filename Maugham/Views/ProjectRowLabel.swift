import SwiftUI

/// The label every project row draws — the head row that names the project
/// itself (persona shell spec §3.3).
///
/// **One definition because there are three of them.** `BinderView`,
/// `CollectionPiecesPane` and `SceneNavigatorPane` each carry a project row,
/// because each is the manuscript home of a different project type
/// (`BinderSegment.documentHome(for:)` decides which), and a writer only ever
/// sees one of the three. That is exactly the situation in which three copies
/// drift apart unseen — the glyph, the truncation mode and the spacing here are
/// the whole visual identity of *"this row is the project"*, and it must not
/// depend on which project type the writer opened.
///
/// **What is deliberately NOT here: the `.tag`.** A tag is how a particular
/// `List(selection:)` matches a particular row against a particular binding, and
/// the three lists do not agree about what else is selectable in them — the
/// scene navigator's rows are not subjects at all. Each site tags its own row,
/// and each site's doc comment says why its row is a row and not a control
/// (tripwire 9).
struct ProjectRowLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "books.vertical")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .contentShape(Rectangle())
    }
}
