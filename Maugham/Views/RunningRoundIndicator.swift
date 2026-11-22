import SwiftUI
import MaughamCore

/// **A running round, in the toolbar** (shell p4 Task 8; the design's
/// standing indicator). One round runs at a time across the book — the
/// project's windows share one roster (`ProjectSession`) — and the desk that
/// showed it is gone, so the toolbar says what is running, in every window on
/// the project, and a press opens the running piece's To resolve. It reads
/// the pipeline's and the compiler's existing state; nothing new is stored.
/// Hidden when nothing runs; focus mode hides it with the rest of the chrome.
enum RunningRound {

    /// What the indicator says, and where a press goes.
    struct Line: Equatable {
        let text: String
        /// The piece the round is on.
        let docId: String
        /// The language a translation round is in, read in on arrival; nil
        /// for an editor's round.
        let language: String?
    }

    /// **The running round, or nil.** A translation round first (it has the
    /// book's one translator), then an editor's round (`RunKind.round`); a
    /// check is not a round, and To resolve's own head already says it runs.
    static func line(pipeline: TranslationPipeline.Status,
                     compiler: CompilerOrchestrator.RunState,
                     titleOf: (String) -> String?) -> Line? {
        if case .running(let docId, let language, let leg, let book) = pipeline {
            var place = quoted(titleOf(docId))
            if let book { place += " (\(book.position) of \(book.count))" }
            return Line(text: "Translating \u{00b7} \(LanguageName.title(language)) \u{00b7} \(place), \(leg.verb)",
                        docId: docId, language: language)
        }
        if case .running(let docId, .round, _) = compiler {
            return Line(text: "Editor\u{2019}s round \u{00b7} \(quoted(titleOf(docId))), reading",
                        docId: docId, language: nil)
        }
        return nil
    }

    private static func quoted(_ title: String?) -> String {
        title.map { "\u{201C}\($0)\u{201D}" } ?? "a piece"
    }

    static let help = "A round is running. Click to see its piece\u{2019}s To resolve."

    /// **Where a press goes**: the running piece, opened in the round's
    /// language (taken on arrival by the reading modifier), with To resolve
    /// shown. Already on the piece, the language is chosen in place.
    @MainActor
    static func open(_ line: Line, openDocId: String, reading: ReadingLanguageModel) {
        if line.docId == openDocId {
            if let language = line.language { LanguageSwitch.choose(language) }
        } else {
            reading.pending = line.language
            ResolveNavigation.go(toDocId: line.docId)
        }
        MaughamEvent.postPosition(.resolve)
    }
}

/// The indicator: a small spinner and one quiet line.
struct RunningRoundIndicator: View {
    let line: RunningRound.Line
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(line.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 320)
        }
        .buttonStyle(.plain)
        .help(line.text + ". " + RunningRound.help)
        .accessibilityLabel(line.text)
        .accessibilityHint(RunningRound.help)
    }
}
