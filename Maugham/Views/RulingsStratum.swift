import SwiftUI
import MaughamCore

/// The writer's rulings, itemized under their essay — the second stratum of a
/// statement pane (declared-world Task 6, spec §3.2).
///
/// **Every verb takes the statement's KIND** (publish department, Task 7), and
/// takes it undefaulted, before the scope — `RulingPerformer`'s own shape, for
/// its own reason: a caller that has to say which statement it is acting on
/// cannot fail to have thought about it. Until Task 7 these named `.intent` at
/// all six calls into the performer and again in `currentRows`' lookup, which
/// was true while intent was the only kind a verb wrote a ruling into and became
/// a live defect the moment the edition brief joined it. The failure would not
/// have been the refusal the trap's own note predicted: a brief is project-scope
/// and the book's craft intent is project-scope too, so `.intent` names a
/// statement that really is there, and a Revoke pressed on the Spanish brief
/// would have gone looking through the book's intent instead.
///
/// **The rules live here and the drawing lives in `RulingsStratumView`.**
/// Everything a test would want to ask — what the rows are, what a row's caption
/// says, what each verb does to the file and to the undo stack — is a static on
/// this enum taking what it touches, so it is asked directly rather than through
/// a mounted row and a synthesized click. That is `DiagnosticsPane`'s shape and
/// `TasksPane`'s, and it is what makes the undo assertions possible at all:
/// SwiftUI offers no way to press ⌘Z into a hosted view.
///
/// **Rows are addressed by INDEX, never by the id they were built with.** A
/// `Ruling.id` is a digest of its own text (`RulingsSection`), so it goes stale
/// the instant an edit lands — the row holding it would then address nothing,
/// and `RulingFailure.unknownRuling` would refuse the writer's second correction
/// of the same line. Position is what `edit` and `restore` both preserve, so the
/// verbs below take an index and re-derive the id from the statement's CURRENT
/// text at the moment they write.
/// (`test_aRowsIdenityIsReDerivedAfterAnEdit`.)
///
/// **The undo wiring is here and not in `RulingPerformer`.** A ruling arriving
/// from a run or a promotion must leave no entry on the writer's undo stack —
/// there is no gesture of theirs to reverse, and a ⌘Z that took back something
/// they did not do is worse than none. So the performer stays a verb and the
/// registration belongs to the surface where the gesture happened.
@MainActor
enum RulingsStratum {

    // MARK: - Reading

    /// The rulings a statement currently carries, in file order. Empty for a
    /// statement with no section — **and an empty list is no stratum at all**,
    /// not an empty one: `RulingsStratumView` mounts nothing, so a writer who
    /// has never ruled sees the pane exactly as it was.
    static func rows(in markdown: String) -> [Ruling] {
        RulingsSection.parse(markdown).rulings
    }

    /// The line under a ruling's text: when it was ruled and where it came
    /// from, or nil when the line carries neither.
    ///
    /// A hand-typed ruling has no date and no provenance, and says so by
    /// showing nothing. "Unknown" would be Maugham inventing a fact about the
    /// writer's own record.
    static func caption(for ruling: Ruling) -> String? {
        switch (ruling.ruledOn, ruling.provenance) {
        case let (.some(date), .some(provenance)):
            return "Ruled \(formatted(date)) · \(provenance)"
        case let (.some(date), .none):
            return "Ruled \(formatted(date))"
        case let (.none, .some(provenance)):
            return provenance
        case (.none, .none):
            return nil
        }
    }

    /// `RulingsSection`'s own `d MMM yyyy`, fixed to `en_US_POSIX`/UTC for the
    /// same reason: the caption and the line in the file must read alike, and a
    /// device-locale formatter here would show a date the file does not.
    private static func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    // MARK: - Revoke

    /// Take one ruling out, and register the ⌘Z that puts it back **exactly** —
    /// same words, same position, same day it was ruled, same provenance. See
    /// `RulingPerformer.restore` for why `rule` could not have served as the
    /// inverse.
    ///
    /// The registration happens only on success, after the write: a refused
    /// revoke must leave no undo entry standing over a file nothing moved.
    static func revoke(_ ruling: Ruling, at index: Int, kind: Statement.Kind,
                       forScope scope: Statement.Scope,
                       store: ProjectStore, world: DeclaredWorldStore?,
                       undoManager: UndoManager?,
                       workTaskSink: @escaping (Task<Void, Never>) -> Void) async {
        do {
            try await RulingPerformer.revoke(
                rulingId: ruling.id, kind: kind, forScope: scope, store: store,
                world: world)
        } catch {
            return
        }
        OpUndoRegistrar.register(
            undoManager, actionName: "Revoke Ruling", target: store,
            workTaskSink: workTaskSink,
            undo: { s in
                try? await RulingPerformer.restore(
                    ruling, at: index, kind: kind, forScope: scope, store: s,
                    world: world)
            },
            redo: { s in
                guard let id = currentId(at: index, kind: kind, forScope: scope, store: s)
                else { return }
                try? await RulingPerformer.revoke(
                    rulingId: id, kind: kind, forScope: scope, store: s, world: world)
            })
    }

    // MARK: - Edit

    /// Change what one ruling says, in place, and register the ⌘Z back to its
    /// old words. `RulingPerformer.edit` keeps the position, the date and the
    /// provenance, so the inverse is the same verb pointed the other way and
    /// the record is unchanged either direction.
    static func edit(at index: Int, to newText: String, kind: Statement.Kind,
                     forScope scope: Statement.Scope,
                     store: ProjectStore, world: DeclaredWorldStore?,
                     undoManager: UndoManager?,
                     workTaskSink: @escaping (Task<Void, Never>) -> Void) async {
        guard let id = currentId(at: index, kind: kind, forScope: scope, store: store),
              let priorText = currentRows(kind: kind, forScope: scope,
                                          store: store)[safe: index]?.text
        else { return }
        do {
            try await RulingPerformer.edit(
                rulingId: id, newText: newText, kind: kind, forScope: scope,
                store: store, world: world)
        } catch {
            return
        }
        OpUndoRegistrar.register(
            undoManager, actionName: "Edit Ruling", target: store,
            workTaskSink: workTaskSink,
            undo: { s in
                guard let now = currentId(at: index, kind: kind, forScope: scope, store: s)
                else { return }
                try? await RulingPerformer.edit(
                    rulingId: now, newText: priorText, kind: kind, forScope: scope,
                    store: s, world: world)
            },
            redo: { s in
                guard let now = currentId(at: index, kind: kind, forScope: scope, store: s)
                else { return }
                try? await RulingPerformer.edit(
                    rulingId: now, newText: newText, kind: kind, forScope: scope,
                    store: s, world: world)
            })
    }

    // MARK: - The current file, asked at the moment of the write

    /// The rulings a `(kind, scope)` statement carries right now, through the one
    /// statement reader (`ProjectStore.statementText`, tripwire 20 — never the
    /// `.md`).
    ///
    /// **The kind is half the address**, not decoration: an edition brief and the
    /// book's craft intent are both `.project`-scoped, so a scope alone names two
    /// files and picks whichever this lookup happens to ask for.
    static func currentRows(kind: Statement.Kind, forScope scope: Statement.Scope,
                            store: ProjectStore) -> [Ruling] {
        guard let statement = store.statement(kind: kind, scope: scope) else { return [] }
        // `statementText` throws since RULING-54's strict-read slice. An
        // unreadable statement file here means the verb's premise is gone —
        // "no rulings to act on" is the same honest answer a shrunk list gets
        // one doc-comment down, so the fringe-reader pattern (try? with the
        // reason recorded) is the right shape, not a surfaced error.
        guard let text = try? store.statementText(of: statement) else { return [] }
        return rows(in: text)
    }

    /// The id of the ruling at `index` **as of now**. Nil when the list has
    /// shrunk under the caller — a peer's revoke, a hand edit — which every
    /// verb treats as "there is nothing there to act on" rather than acting on
    /// the neighbour.
    private static func currentId(at index: Int, kind: Statement.Kind,
                                  forScope scope: Statement.Scope,
                                  store: ProjectStore) -> String? {
        currentRows(kind: kind, forScope: scope, store: store)[safe: index]?.id
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// The three-way split a statement's rulings resolve into once directives and
/// glossary entries are recognised (translation pipeline spec §3.1, publish
/// department Task 7): a glossary entry draws as a table row, an orphaned
/// directive — its anchored paragraph no longer exists — draws with a warning
/// and a Remove affordance, and everything else draws exactly as it always
/// has.
///
/// **A directive is only ever an orphan against a KNOWN set of live ids.**
/// `liveParagraphIds == nil` means the pane has not finished resolving them
/// yet (its `.task` hasn't landed, or the read failed) — and "unknown" must
/// never read as "orphaned": a directive flashing an orphan warning for one
/// frame while a document loads would be a false alarm about a paragraph that
/// is right there.
extension RulingsStratum {
    struct Partition: Equatable {
        let glossary: [Ruling]
        let orphans: [Ruling]
        let others: [Ruling]
    }

    static let glossaryHeading = "Glossary"
    static let orphanCaption = "This paragraph no longer exists"
    static let removeTitle = "Remove"

    /// `liveParagraphIds == nil` = unknown: nothing is an orphan (never a
    /// false orphan over a doc that has not loaded).
    static func partition(_ rulings: [Ruling], liveParagraphIds: Set<String>?) -> Partition {
        var glossary: [Ruling] = []
        var orphans: [Ruling] = []
        var others: [Ruling] = []
        for ruling in rulings {
            if ruling.glossary != nil {
                glossary.append(ruling)
            } else if let paragraphId = ruling.paragraphId,
                      let live = liveParagraphIds, !live.contains(paragraphId) {
                orphans.append(ruling)
            } else {
                others.append(ruling)
            }
        }
        return Partition(glossary: glossary, orphans: orphans, others: others)
    }
}

/// The rulings stratum as the writer meets it: their own words, in their own
/// ink, itemized under the essay they were made against.
///
/// **Writer-ink, deliberately** — the contrast with `BibleStratumView` is the
/// whole information design of the pane. A ruling is a decision the writer made;
/// a bible entry is a reading Claude offered. They must not look alike.
struct RulingsStratumView: View {
    let rulings: [Ruling]
    /// Which statement these rows belong to. Undefaulted for the reason the
    /// verbs' own parameter is: `(kind, scope)` is the whole address, and a
    /// default would let a brief-side mount silently act on the craft intent.
    let kind: Statement.Kind
    let scope: Statement.Scope
    @Bindable var store: ProjectStore
    let world: DeclaredWorldStore?
    /// Which paragraph ids are currently live in this statement's scope, so a
    /// directive whose anchor no longer exists draws as an orphan rather than
    /// an ordinary row. `nil` (the default) is "not yet known" — see
    /// `RulingsStratum.partition`'s doc comment for why that must never read
    /// as "orphaned". `StatementPane` resolves this in a `.task`.
    var liveParagraphIds: Set<String>? = nil

    @Environment(\.undoManager) private var undoManager

    /// Which row's field is open, by INDEX — the id moves with the text and
    /// would leave the field pointing at nothing the moment it commits.
    @State private var editingIndex: Int?

    /// The writer's word for these rows.
    ///
    /// **"Ledger" for the lessons statement, "Rulings" everywhere else.** Under
    /// an intent or a brief a ruling is a decision itemized beneath the essay it
    /// was made against; in the lessons statement the rows ARE the artifact —
    /// the essay above them is a preamble — so calling them rulings there names
    /// the mechanism instead of the thing. Static and pure so the whole product
    /// of kinds can be asked of it.
    static func title(for kind: Statement.Kind) -> String {
        if case .lessons = kind { return "Ledger" }
        // **"Instructions" under the first reader.** Her rows are not decisions
        // made against an essay and not entries in a record — they are standing
        // instructions she reads under, which is what the writer would call them
        // if asked. Naming them rulings there would name the mechanism.
        if case .firstReader = kind { return "Instructions" }
        return "Rulings"
    }

    var body: some View {
        let partition = RulingsStratum.partition(rulings, liveParagraphIds: liveParagraphIds)
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.title(for: kind))
                .font(.caption).bold()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            if !partition.glossary.isEmpty {
                glossarySection(partition.glossary)
                Divider()
            }
            ForEach(partition.orphans) { ruling in
                orphanRow(ruling, at: index(of: ruling))
                Divider()
            }
            ForEach(partition.others) { ruling in
                row(ruling, at: index(of: ruling))
                Divider()
            }
        }
    }

    /// `partition` hands back plain `[Ruling]` buckets, so a row drawn from one
    /// re-derives its ORIGINAL position in `rulings` for the verbs below — the
    /// same index-not-id rule the type doc states, applied across the split.
    /// Ids are unique within one parse (`RulingsSection`'s own dedup), so the
    /// lookup is exact.
    private func index(of ruling: Ruling) -> Int {
        rulings.firstIndex(where: { $0.id == ruling.id }) ?? 0
    }

    /// Every recognised glossary entry, as one table — Term / Rendering / Note
    /// — rather than itemized rows, because the whole point of pulling these
    /// out of `others` is to let a translator scan the book's vocabulary at a
    /// glance instead of hunting through plain-prose rulings for it.
    @ViewBuilder
    private func glossarySection(_ entries: [Ruling]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(RulingsStratum.glossaryHeading)
                .font(.caption).bold()
                .foregroundStyle(.secondary)
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(entries) { ruling in
                    if let parsed = ruling.glossary {
                        GridRow {
                            Text(parsed.term).font(.callout)
                            Text(parsed.rendering).font(.callout)
                            Text(parsed.note ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Revoke") { revoke(ruling, at: index(of: ruling)) }
                                .buttonStyle(.plain)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// A directive whose anchor no longer resolves. Drawn distinctly from an
    /// ordinary row — writer-ink dimmed to `.secondary`, the reason stated
    /// plainly, and `Remove` rather than `Edit`/`Revoke`: there is no paragraph
    /// left for an edited instruction to be about, so the only honest verb is
    /// taking the line out. It is the same `revoke` the ordinary row uses —
    /// "Remove" is this row's name for it, not a second verb.
    @ViewBuilder
    private func orphanRow(_ ruling: Ruling, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ruling.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(RulingsStratum.orphanCaption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button(RulingsStratum.removeTitle) { revoke(ruling, at: index) }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func row(_ ruling: Ruling, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if editingIndex == index {
                StratumEditField(
                    seed: ruling.text,
                    isOpen: Binding(get: { editingIndex == index },
                                    set: { if !$0 { editingIndex = nil } }),
                    onCommit: { text in
                        editingIndex = nil
                        commitEdit(text, at: index)
                    })
            } else {
                Text(ruling.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caption = RulingsStratum.caption(for: ruling) {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 12) {
                // `Button(.plain)` and never `.onTapGesture` (tripwire 9).
                Button("Edit") { editingIndex = index }
                    .buttonStyle(.plain)
                Button("Revoke") { revoke(ruling, at: index) }
                    .buttonStyle(.plain)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func revoke(_ ruling: Ruling, at index: Int) {
        let um = undoManager
        Task { @MainActor in
            await RulingsStratum.revoke(
                ruling, at: index, kind: kind, forScope: scope, store: store,
                world: world, undoManager: um, workTaskSink: { _ in })
        }
    }

    private func commitEdit(_ text: String, at index: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An edit that empties a ruling is a revocation wearing the wrong verb;
        // `RulingPerformer.edit` refuses it, and closing the field without
        // asking is the honest UI half of that refusal.
        guard !trimmed.isEmpty else { return }
        let um = undoManager
        Task { @MainActor in
            await RulingsStratum.edit(
                at: index, to: trimmed, kind: kind, forScope: scope, store: store,
                world: world, undoManager: um, workTaskSink: { _ in })
        }
    }
}

/// One inline field, shared by both strata's amend affordances.
///
/// **Tripwire 16 lives here once**, rather than in each row that needs it: the
/// focus claim is deferred 30 ms and wired from BOTH `.onAppear` and
/// `.onChange`, because a single `DispatchQueue.main.async` tick loses the race
/// with the enclosing list's own focus pass. `BinderRow.claimFocus()` is the
/// canonical version and this is its shape, not a second answer.
struct StratumEditField: View {
    let seed: String
    @Binding var isOpen: Bool
    let onCommit: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $draft, onCommit: { onCommit(draft) })
            .textFieldStyle(.plain)
            .font(.callout)
            .focused($isFocused)
            .onAppear {
                draft = seed
                claimFocus()
            }
            .onChange(of: isOpen) { _, open in
                if open {
                    draft = seed
                    claimFocus()
                }
            }
            .onExitCommand { isOpen = false }
    }

    private func claimFocus() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            isFocused = true
        }
    }
}
