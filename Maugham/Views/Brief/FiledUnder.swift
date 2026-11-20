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
enum FiledUnder {
    /// How long the line stays, unless the next filing replaces it.
    static let lingers: Duration = .seconds(6)

    static let bookIntent = "Filed under the book's intent"
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
        let place = place(destination, faces: faces, structure: structure,
                          projectType: projectType, firstReaderName: firstReaderName)
        guard let place else { return destination.alreadyStood ? "Already there" : "Filed" }
        return (destination.alreadyStood ? "Already in " : "Filed under ") + place
    }

    /// Where, as the sentence names it; nil for a kind no verb files to.
    private static func place(_ destination: FiledDestination, faces: BinderSubject,
                              structure: [StructureItem], projectType: ProjectType,
                              firstReaderName: String?) -> String? {
        switch destination.kind {
        case .intent:
            switch destination.scope {
            case .project:
                return "the book's intent"
            case .document(let docId):
                let item = TreeWalk.find(id: docId, in: structure)
                // A piece missing from the structure is never called by its
                // noun in quotes: it is "this chapter" too.
                guard let item, BriefScope.of(faces, structure: structure, projectType: projectType)
                        != .piece(docId: docId) else {
                    return "this \(pieceNoun(item, projectType: projectType))'s intent"
                }
                return "\u{201C}\(item.title)\u{201D}'s intent"
            case .unknown:
                return "an intent"
            }
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
/// dismiss. It stays `FiledUnder.lingers`, or until the next filing replaces
/// it, and it knows nothing about the list: a row the next read removes does
/// not take the line with it.
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
    }

    /// The line after `event`. Pure: a new filing replaces the old; the
    /// linger ends only the filing it was started for; a change of the list
    /// leaves the line alone.
    static func after(_ event: Event, current: Filing?) -> Filing? {
        switch event {
        case .filed(let filing): return filing
        case .lingered(let id): return current?.id == id ? nil : current
        case .listChanged: return current
        }
    }

    @Binding var filing: Filing?
    var onOpenBrief: ((BinderSubject) -> Void)? = nil

    var body: some View {
        if let filing {
            Group {
                if let onOpenBrief, let brief = filing.brief {
                    Button { onOpenBrief(brief) } label: { line(filing.sentence) }
                        .buttonStyle(.plain)
                } else {
                    line(filing.sentence)
                }
            }
            .task(id: filing.id) {
                do { try await Task.sleep(for: FiledUnder.lingers) } catch { return }
                self.filing = Self.after(.lingered(filing.id), current: self.filing)
            }
        }
    }

    private func line(_ sentence: String) -> some View {
        Label(sentence, systemImage: "checkmark")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("filed.notice")
    }
}
