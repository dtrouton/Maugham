import SwiftUI
import MaughamCore

/// The writer's signature line above the prose — M2 spec §6.1.
///
/// A running head in a book, not chrome: one line in the status footer's
/// register, dimmed, with no material behind it, sitting on the editor's own
/// paper. It shows the first real line of the intent that applies to the
/// document being written — the piece's own if it has one, else the project's —
/// with markdown headings skipped, so `# Intent` never becomes the signature.
///
/// **No intent → no strip.** Absence is valid (M1A's rule, and
/// `read_craft_intent` says so to Claude in as many words), and an empty bar is
/// a nag wearing typography. The mounting site asks for a line and mounts
/// nothing when there is none; there is no empty state to design.
///
/// **ADR 0027 §1 is what this file is really holding.** The constitution's
/// must-not #2 — no AI inside the editor — is an *output-location* invariant:
/// nothing model-produced may render in the editor or its chrome. This strip is
/// the one AI-adjacent surface that sits physically above the prose, and it is
/// not a counterexample only because what it draws is the writer's own
/// op-logged statement text. That is structural rather than promised: the view
/// stores a single `String`, the only thing that produces one is `line(from:)`,
/// and the only thing that feeds *that* is `ProjectStore.statementText(of:)`.
/// A future version showing a diagnostic, a summary, or any other model output
/// would violate ADR 0027 and must-not #2 together, and no argument about
/// convenience reaches it. `IntentStripTests` is the census that says so.
struct IntentStrip: View {

    /// The line to draw. A `String`, never a statement, a store or a diagnostic
    /// — see the type doc: the narrow input is the invariant.
    let line: String

    /// Roughly a running head's worth. Past this the line is cut on a word
    /// boundary and ellipsised.
    static let maximumLength = 90

    /// `EditorStatusFooter`'s size, deliberately: the strip is the running head
    /// at the other end of the same page, and two dimmed one-liners bracketing
    /// the prose at different sizes read as an accident.
    static let fontSize: CGFloat = 11

    /// `.secondary` is already dimmed; this takes it further, because the
    /// footer reports *state* the writer may want to check and this only has to
    /// be legible when looked at.
    static let restingOpacity: Double = 0.7

    /// The affordance appears on hover and not before — the strip is something
    /// the writer reads, and a permanently underlined line is a control sitting
    /// over the prose.
    @State private var isHovering = false

    var body: some View {
        Button {
            // Scope follows the binder selection, which the Intent pane already
            // reads (`StatementPane.effectiveScope`) — see the mounting site in
            // `ProjectWindow` for the one case where the two can differ and why
            // that is left alone rather than fixed here.
            MaughamEvent.postDetailSegment(.intent)
        } label: {
            Text(line)
                .font(.system(size: Self.fontSize))
                .foregroundStyle(.secondary)
                .opacity(Self.restingOpacity)
                .underline(isHovering)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 2)
                .frame(maxWidth: .infinity, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Open Intent")
        .accessibilityHint("Opens the Intent pane")
    }

    // MARK: - Whether there is a strip at all

    /// The mounting decision, given the window's state and the statement's
    /// text: a line to draw, or nothing to mount.
    ///
    /// Pure and asked over the product of its inputs rather than the one path
    /// the plan named. Author alone, because the strip is a writing surface's
    /// running head and the other three personas are not writing; and it goes
    /// with the chrome under ⌘\, because a writer who asked for nothing but
    /// their prose asked for that too.
    static func line(
        persona: Persona, isNoChromeOn: Bool, statementText: String?
    ) -> String? {
        guard persona == .author, !isNoChromeOn else { return nil }
        return line(from: statementText)
    }

    /// The same decision, resolved against a project: the intent that applies
    /// to `docId`, as the writer's own words.
    ///
    /// **`ProjectStore.effectiveIntent(forDocId:)`, which the compiler's run
    /// briefing also calls** — one spelling of piece-first/project-fallback, or
    /// the strip and the run can disagree about which intent is in force with
    /// nothing on screen saying so.
    ///
    /// **The freshness comes from `statementText(of:)` and nothing here polls.**
    /// That reader prefers the statement's *live* `Document` — the same
    /// `@Observable` `displayText` the Intent pane binds — so a change made in
    /// the pane invalidates this body through SwiftUI's own observation, with
    /// no event, no timer and no save in between. The gates are checked first so
    /// a persona with no strip reads no statement at all.
    @MainActor
    static func line(
        store: ProjectStore, docId: String, persona: Persona, isNoChromeOn: Bool
    ) -> String? {
        guard persona == .author, !isNoChromeOn else { return nil }
        guard let statement = store.effectiveIntent(forDocId: docId) else { return nil }
        return line(from: store.statementText(of: statement))
    }

    // MARK: - The line rule (pure)

    /// The first real line of a statement, or nil.
    ///
    /// **Headings are skipped through `MarkdownBlockParser`, not through a
    /// leading-`#` test of this file's own.** A fourth answer to "what is a
    /// heading" is exactly the drift the shared block parser was extracted to
    /// end, and the parser already knows the two cases a hand-rolled predicate
    /// gets wrong: `###` alone is a scene-break ornament, and `#3 in the
    /// sequence` is prose.
    ///
    /// What counts as a *real* line is the writer's words: a paragraph, a list
    /// item, a quoted line. A fence, a table and a solo image are skipped along
    /// with headings and ornaments — none of them is a sentence about what the
    /// piece is going for, and a strip showing ```` ``` ```` would be a
    /// rendering bug the writer cannot fix from the pane.
    static func line(from statementText: String?) -> String? {
        guard let text = statementText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        guard let raw = firstProseLine(in: MarkdownBlockParser.parse(text)) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : truncated(trimmed)
    }

    /// The first line the writer would call a sentence, walking blocks in order.
    private static func firstProseLine(in blocks: [MarkdownBlock]) -> String? {
        for block in blocks {
            switch block {
            case .paragraph(let lines):
                if let first = lines.first(where: {
                    !$0.trimmingCharacters(in: .whitespaces).isEmpty
                }) { return first }
            case .list(_, let items):
                if let first = items.first?.first { return first }
            case .blockquote(let inner):
                if let found = firstProseLine(in: inner) { return found }
            case .heading, .thematicBreak, .fence, .table, .soloImage:
                continue
            }
        }
        return nil
    }

    /// `line` if it fits, else cut at the last word boundary inside the budget
    /// and ellipsised. A single word longer than the budget is cut where it
    /// falls — there is no boundary, and a strip that grew to fit would push
    /// the prose down.
    private static func truncated(_ line: String) -> String {
        guard line.count > maximumLength else { return line }
        let head = String(line.prefix(maximumLength))
        guard let lastSpace = head.lastIndex(of: " ") else { return head + "…" }
        let cut = String(head[head.startIndex..<lastSpace])
            .trimmingCharacters(in: .whitespaces)
        return (cut.isEmpty ? head : cut) + "…"
    }
}
