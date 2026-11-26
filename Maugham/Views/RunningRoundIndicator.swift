import SwiftUI
import AppKit
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
        /// The short form a tight toolbar draws (fix round (f)): the language
        /// or the editor, and how far through the book. The full `text` is
        /// the tooltip and the VoiceOver label either way.
        var compact: String = ""
    }

    /// **The running round, or nil.** A translation round first (it has the
    /// book's one translator), then an editor's round (`RunKind.round`),
    /// named by its pass's editor when the round in flight says which pass
    /// (`roundEditor`, fix round (g)); a check is not a round, and To
    /// resolve's own head already says it runs.
    static func line(pipeline: TranslationPipeline.Status,
                     compiler: CompilerOrchestrator.RunState,
                     roundEditor: String? = nil,
                     titleOf: (String) -> String?) -> Line? {
        if case .running(let docId, let language, let leg, let book) = pipeline {
            var place = quoted(titleOf(docId))
            if let book { place += " (\(book.position) of \(book.count))" }
            let name = LanguageName.title(language)
            return Line(text: "Translating \u{00b7} \(name) \u{00b7} \(place), \(leg.verb)",
                        docId: docId, language: language,
                        compact: book.map { "\(name) \($0.position)/\($0.count)" } ?? name)
        }
        if case .running(let docId, .round, _) = compiler {
            let who = roundEditor.map { "\($0)\u{2019}s round" } ?? "Editor\u{2019}s round"
            return Line(text: "\(who) \u{00b7} \(quoted(titleOf(docId))), reading",
                        docId: docId, language: nil,
                        compact: roundEditor ?? "Round")
        }
        return nil
    }

    private static func quoted(_ title: String?) -> String {
        title.map { "\u{201C}\($0)\u{201D}" } ?? "a piece"
    }

    // MARK: - The width budget (fix round (f))

    /// What the window's chrome takes before the trailing group: the tree's
    /// column, the window buttons, the sidebar toggle, the Lock and the
    /// title's least room. An estimate — the toolbar's real layout is
    /// AppKit's — held on the generous side, so a tight window draws the
    /// short form early rather than letting the language switch overflow.
    /// `ToolbarWidthTests` measures it holding at the window's floor.
    static let leadingReserve: CGFloat = 560
    /// The right column's toggle and the gaps between the trailing items.
    static let trailingFixed: CGFloat = 72
    /// The view switch's three segments.
    static let viewSwitchWidth: CGFloat = 110
    /// The spinner and its gap; a menu button's icon, chevron and padding.
    static let spinnerWidth: CGFloat = 22
    static let menuChrome: CGFloat = 52

    /// **Whether the full sentence fits** beside everything else in the
    /// trailing group, from intrinsic sizes (`textWidth` measures a string in
    /// the indicator's font). Else the short form — so the indicator never
    /// pushes the language switch, the view switch or the right column's
    /// toggle into the toolbar's overflow.
    static func drawsFull(_ line: Line, windowWidth: CGFloat?, languageSwitchTitle: String?,
                          viewSwitch: Bool, textWidth: (String) -> CGFloat) -> Bool {
        guard let windowWidth else { return false }
        let others = trailingFixed
            + (languageSwitchTitle.map { textWidth($0) + menuChrome } ?? 0)
            + (viewSwitch ? viewSwitchWidth : 0)
        let full = min(textWidth(line.text), maxWidth) + spinnerWidth
        return full <= windowWidth - leadingReserve - others
    }

    /// The indicator's widest (it truncates in the middle past this).
    static let maxWidth: CGFloat = 320

    /// The indicator's font, measured.
    @MainActor static func measured(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [
            .font: NSFont.preferredFont(forTextStyle: .callout)]).width)
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
            reading.pending = (line.docId, line.language)
            ResolveNavigation.go(toDocId: line.docId)
        }
        MaughamEvent.postPosition(.resolve)
    }
}

/// The indicator: a small spinner and one quiet line.
struct RunningRoundIndicator: View {
    let line: RunningRound.Line
    /// The full sentence, or the short form a tight toolbar draws.
    var full: Bool = true
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(full ? line.text : line.compact)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: RunningRound.maxWidth)
        }
        .buttonStyle(.plain)
        .help(line.text + ". " + RunningRound.help)
        .accessibilityLabel(line.text)
        .accessibilityHint(RunningRound.help)
    }
}
