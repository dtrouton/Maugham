import SwiftUI
import MaughamCore

/// **Where an answer went, in the writer's words** (shell plan 3 Task 6).
///
/// The verbs that take something raised in To resolve and file it under what
/// the subject is held to — Answer, Add to intent, Keep as lesson, a choice,
/// Make it a rule, Confirm — write into a statement that may be out of sight.
/// Each hands its caller the `FiledDestination` the write itself returned
/// (`RulingPerformer.rule`), and the caller says it here, in one quiet line.
///
/// The sentence is the app's words about the writer's own act: it names the
/// destination and nothing else — never the check's or Claude's prose.
///
/// **One family** (shell p4 Task 6a): what lands in a piece's or the Book's
/// intent — its Decided, or Going for — is "Filed in Brief" (the faces' own
/// Brief) or "Filed in “Breakfast”'s Brief" / "Filed in the Book's Brief"
/// (another's): the writer knows that place as Brief, and the line is the
/// button that shows it. What has a name of its own keeps it: "Filed under
/// What I've Learned", "Filed under the Spanish edition brief". Nothing
/// written says "Already in" either way.
enum FiledUnder {
    /// How long the line stays where it lingers (Brief's own Confirm, a
    /// round report), unless the next filing replaces it. To resolve's line
    /// never lingers on a timer: it stands until the writer's next act in
    /// the list (`FiledNotice.Event.listPressed`).
    static let lingers: Duration = .seconds(6)

    /// What an answer filed into the faces' own Brief says (Task 6a).
    static let inBrief = "Filed in Brief"
    static let lessons = "Filed under \(BriefBookView.lessonsTitle)"
    static let alreadyInLessons = "Already in \(BriefBookView.lessonsTitle)"
    static let firstReaderUnnamed = "Filed under \(BriefBookView.firstReaderTitle)"
    static let visualLanguage = "Filed under \(BriefBookView.visualLanguageTitle)"

    /// The sentence for `destination`, seen from the faces: the faces' own
    /// piece is "this chapter" (the noun its project gives a piece); another
    /// piece is named by its title. A destination the write found the words
    /// already standing in (`FiledDestination.alreadyStood`) says "Already
    /// in", not "Filed under": nothing was written.
    static func sentence(_ destination: FiledDestination, faces: BinderSubject,
                         structure: [StructureItem], projectType: ProjectType,
                         firstReaderName: String?) -> String {
        if let brief = briefPlace(destination, faces: faces, structure: structure,
                                  projectType: projectType) {
            return (destination.alreadyStood ? "Already in " : "Filed in ") + brief
        }
        let place = place(destination, firstReaderName: firstReaderName)
        guard let place else { return destination.alreadyStood ? "Already there" : "Filed" }
        return (destination.alreadyStood ? "Already in " : "Filed under ") + place
    }

    /// **Which Brief an intent filing is in, as the sentence names it**:
    /// "Brief" when it is the faces' own Brief (or a piece the structure no
    /// longer names), else "“Title”'s Brief" or "the Book's Brief"; nil for
    /// every other kind, which keeps its own name. Pure.
    static func briefPlace(_ destination: FiledDestination, faces: BinderSubject,
                           structure: [StructureItem], projectType: ProjectType) -> String? {
        guard destination.kind == .intent else { return nil }
        let facesBrief = BriefScope.of(faces, structure: structure, projectType: projectType)
        switch destination.scope {
        case .project:
            return facesBrief == .book ? "Brief" : "the Book's Brief"
        case .document(let docId):
            guard let item = TreeWalk.find(id: docId, in: structure),
                  facesBrief != .piece(docId: docId) else { return "Brief" }
            return "\u{201C}\(item.title)\u{201D}'s Brief"
        case .unknown:
            return nil
        }
    }

    /// Where, as the sentence names it, for a destination outside a piece's
    /// or the Book's Brief; nil for a kind no verb files to.
    private static func place(_ destination: FiledDestination, firstReaderName: String?) -> String? {
        switch destination.kind {
        case .intent:
            // A piece's or the Book's is `briefPlace`'s; this is the unknown
            // scope a newer build may write.
            return "an intent"
        case .lessons:
            return BriefBookView.lessonsTitle
        case .firstReader:
            guard let name = firstReaderName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return BriefBookView.firstReaderTitle }
            return "\(name)'s instructions"
        case .editionBrief(let language):
            return "the " + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
                + " edition brief"
        case .visualLanguage:
            return BriefBookView.visualLanguageTitle
        case .unknown:
            return nil
        }
    }

    /// The word a piece is called by — To resolve's own
    /// (`ResolveGrouping.pieceNoun`): a script for a screenplay or a piece
    /// written in a screenplay format, a piece in a Collection, else a
    /// chapter.
    static func pieceNoun(_ item: StructureItem?, projectType: ProjectType) -> String {
        let isScript = DocumentFormat.ofManuscript(path: item?.path).isScreenplay
        return ResolveGrouping.pieceNoun(isScript: isScript, projectType: projectType)
    }

    /// **The Brief that shows the destination** — what the line's click
    /// would put on the faces (`ProjectWindow.openBrief`; the faces move,
    /// `open` does not). A piece's intent is that piece's Brief; the book's intent, the
    /// ledger, the first reader and Visual Language are the Book's; an edition
    /// brief is its edition's.
    ///
    /// **It ignores the faces on purpose** (controller ruling, 2026-11-19):
    /// the line is a link whenever it names a Brief, including from the
    /// Book's list to a piece's intent — the click then moves the faces to
    /// that piece. It is not limited to the faces' own Brief.
    static func brief(of destination: FiledDestination) -> BinderSubject? {
        switch destination.kind {
        case .intent:
            switch destination.scope {
            case .document(let docId): return .item(docId)
            case .project: return .project
            case .unknown: return nil
            }
        case .lessons, .firstReader, .visualLanguage: return .project
        case .editionBrief(let language): return .edition(language: language)
        case .unknown: return nil
        }
    }

    /// One filing, ready to draw, from the window's own values.
    @MainActor
    static func filing(_ destination: FiledDestination, faces: BinderSubject,
                       store: ProjectStore) -> FiledNotice.Filing {
        FiledNotice.Filing(
            sentence: sentence(destination, faces: faces,
                               structure: store.manifest.structure,
                               projectType: store.manifest.type,
                               firstReaderName: FirstReaderRuling.readerName(in: store.manifest)),
            brief: brief(of: destination))
    }
}

/// **One quiet, transient line** saying where the writer's last answer was
/// filed. Drawn where the verb was pressed; never a modal, never a banner to
/// dismiss. Where it `lingers` it stays `FiledUnder.lingers`; in To resolve
/// it stands until the writer's next act in the list (Task 6a: never on a
/// timer). Either way the next filing replaces it, and it knows nothing
/// about the list: a row the next read removes does not take the line with
/// it.
///
/// Where `onOpenBrief` is given the line is a button that shows the
/// destination's Brief (`ProjectWindow.openBrief`); without it the line is
/// text alone.
struct FiledNotice: View {
    struct Filing: Equatable, Identifiable {
        let id = UUID()
        let sentence: String
        /// The Brief that shows the destination (`FiledUnder.brief(of:)`).
        let brief: BinderSubject?
    }

    /// What can happen to the line.
    enum Event: Equatable {
        case filed(Filing)
        case lingered(UUID)
        /// To resolve re-read or regrouped — the row may be gone.
        case listChanged
        /// The writer pressed somewhere in To resolve's list, while
        /// `over` was the line standing (nil: none was). A press that
        /// itself filed has already replaced the line, so it is kept.
        case listPressed(over: UUID?)
    }

    /// The line after `event`. Pure: a new filing replaces the old; the
    /// linger ends only the filing it was started for; a change of the list
    /// leaves the line alone.
    static func after(_ event: Event, current: Filing?) -> Filing? {
        switch event {
        case .filed(let filing): return filing
        case .lingered(let id): return current?.id == id ? nil : current
        case .listChanged: return current
        case .listPressed(let pressedOver):
            return pressedOver != nil && current?.id == pressedOver ? nil : current
        }
    }

    @Binding var filing: Filing?
    var onOpenBrief: ((BinderSubject) -> Void)? = nil
    /// False in To resolve: the line stands until the writer's next act in
    /// the list, never ended by a timer.
    var lingers: Bool = true

    var body: some View {
        if let filing {
            Group {
                if let onOpenBrief, let brief = filing.brief {
                    // A link in the accent ink: it shows where the answer
                    // went (`ProjectWindow.openBrief` — the faces move to
                    // that Brief and the column shows Brief).
                    Button { onOpenBrief(brief) } label: { line(filing.sentence, opens: true) }
                        .buttonStyle(.plain)
                        .help("Show it")
                        .accessibilityHint("Shows where it was filed")
                } else {
                    line(filing.sentence, opens: false)
                }
            }
            .task(id: filing.id) {
                guard lingers else { return }
                do { try await Task.sleep(for: FiledUnder.lingers) } catch { return }
                self.filing = Self.after(.lingered(filing.id), current: self.filing)
            }
        }
    }

    private func line(_ sentence: String, opens: Bool) -> some View {
        Label(sentence, systemImage: "checkmark")
            .font(.caption)
            .foregroundStyle(opens ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("filed.notice")
    }
}
