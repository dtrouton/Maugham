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
    static let firstReaderUnnamed = "Filed under \(BriefBookView.firstReaderTitle)"
    static let visualLanguage = "Filed under \(BriefBookView.visualLanguageTitle)"

    /// The sentence for `destination`, seen from the faces: the faces' own
    /// piece is "this chapter" (the noun its project gives a piece); another
    /// piece is named by its title.
    static func sentence(_ destination: FiledDestination, faces: BinderSubject,
                         structure: [StructureItem], projectType: ProjectType,
                         firstReaderName: String?) -> String {
        switch destination.kind {
        case .intent:
            switch destination.scope {
            case .project:
                return bookIntent
            case .document(let docId):
                if BriefScope.of(faces, structure: structure, projectType: projectType)
                    == .piece(docId: docId) {
                    return "Filed under this \(pieceNoun(projectType))'s intent"
                }
                let title = TreeWalk.find(id: docId, in: structure)?.title ?? pieceNoun(projectType)
                return "Filed under \u{201C}\(title)\u{201D}'s intent"
            case .unknown:
                return "Filed under an intent"
            }
        case .lessons:
            return lessons
        case .firstReader:
            guard let name = firstReaderName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return firstReaderUnnamed }
            return "Filed under \(name)'s instructions"
        case .editionBrief(let language):
            return "Filed under the "
                + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
                + " edition brief"
        case .visualLanguage:
            return visualLanguage
        case .unknown:
            return "Filed"
        }
    }

    /// The word a piece is called by in this kind of project — the noun To
    /// resolve's whole-piece group uses ("Whole chapter", "Whole script").
    static func pieceNoun(_ projectType: ProjectType) -> String {
        if projectType.primaryFormat.isScreenplay { return "script" }
        return projectType.holdsPieces ? "piece" : "chapter"
    }

    /// **The Brief that shows the destination** — what the line's click
    /// would put on the faces (Task 9 wires it; the faces move, `open` does
    /// not). A piece's intent is that piece's Brief; the book's intent, the
    /// ledger, the first reader and Visual Language are the Book's; an edition
    /// brief is its edition's.
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
/// destination's Brief. No host passes it until the right column's
/// positions are mounted (Task 9): until then the line is text alone.
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
