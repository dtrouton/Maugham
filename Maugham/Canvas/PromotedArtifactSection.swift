import SwiftUI

/// What a promoted thing became, and the way to open it — **the one section,
/// used by the two arms whose subject carries a MARK: the card's and the
/// region's.**
///
/// **"Carries a mark", not "can be promoted", and the difference is the whole
/// point of naming them.** This sentence read *"both arms that can be promoted"*
/// for one commit, and that is false: a **line** is promotable too —
/// `PromotionSource` has a `.line` case and `LineInspector` mounts the same
/// `Promote…` button posting the same `.maughamPromoteCanvasSelection`. What a
/// line has is no `promotedItemID`; `CanvasLine` carries `id`, `from`, `to`,
/// `label` and `author` and nothing else, because a line promotion writes a
/// `[[wiki-link]]` into somebody else's note and produces no artifact of its own
/// to name. Its arm's own caption says so. `promotedItemID` exists on
/// `CanvasNode` and `CanvasRegion` and nowhere else, and this section renders
/// that field — so what decides who mounts it is the FIELD, never a claim about
/// what a writer may promote.
///
/// **An item node mounts it on ONE of its two provenances** (1C-d: Task 7 built
/// the arm, Task 8 gave it a promotion). An *owned* picture can produce a
/// research asset and can be added to a palette card, so it carries both records
/// and gets this section with `Subject.picture`. A *referenced* one still mounts
/// none of it, and for the original reason: it already exists as itself, so
/// `Promotion.targets` offers nothing and `Promotion.itemNodeReason` is the
/// sentence. Its node type does carry the field, which a hand-edited sidecar
/// could fill — the renderer and `CanvasAccessibility` refuse to draw or speak a
/// mark on a reference for that reason, and `ItemInspector` does not render one
/// either.
///
/// **A stale count is wrong about a number; a wrong reason is what the next
/// implementer acts on.** That is why the correction is here at length rather
/// than as a re-worded clause, in the file whose own history below is a monument
/// to a claim about another file's copy that was believed instead of checked.
///
/// **It lived in `ScrapInspector` for one slice and only cards had it.** A card
/// and a region gained the same field in 1C-c2, drew the same stripe, and were
/// announced with the same VoiceOver term; the card arm said what it produced,
/// offered **Open**, and rendered the dangling case, and the region arm said
/// nothing at all. A writer saw a permanent stripe on a region's chrome bar with
/// no way to learn what it produced, no way to open it, and no way to discover
/// that the palette card had been deleted. `ScrapInspector`'s own doc comment
/// states the rule that indicted the omission — CLAUDE.md rule 8 asks every new
/// data type for a surface that can inspect and act on it — and this is the
/// previous slice's Delete-button asymmetry recurring, so the fix is one
/// implementation those two arms are handed rather than a second copy.
struct PromotedArtifactSection: View {

    /// What the thing has produced, if anything. Lifted out of the view so the
    /// three-way decision is reachable from a test that hosts no SwiftUI.
    enum ArtifactState: Equatable {
        case notPromoted
        case promoted(itemID: String, title: String)
        /// A mark whose artifact is no longer in the project.
        case artifactMissing(itemID: String)
    }

    /// What is being described — and **it changes the noun and nothing else.**
    ///
    /// **The region arm named a kind, and 1C-c2a made that a lie.** Its sentence
    /// read *Became the palette card “…”* on the stated grounds that a region's
    /// mark could only ever name a palette card, the other half of its row being
    /// a piece binding that produced no artifact. Task 2 put `.researchNote` on
    /// that row; this file was in no task's diff, so nothing recompiled and
    /// nothing failed, and a region promoted to a research note said *Became the
    /// palette card “Act II fog”* over an **Open** button that opened a note.
    ///
    /// So `became` names no kind for either subject: both arms can now produce
    /// more than one, and neither is told which. It is deliberately not a
    /// `switch` with two identical arms — that shape invites a later edit to
    /// re-divide them, which is exactly how this broke.
    ///
    /// `noun` still differs, and that is still correct: the dangling sentence
    /// says which *thing* on the canvas was promoted, which no promotion can
    /// change. (`PromotionSource.noun` is the other spelling of that word, one
    /// layer down, where a refusal needs it for a line as well.)
    enum Subject {
        case card
        case region
        /// An **owned** item node — a picture the canvas ingested (1C-d Task 8).
        /// Never a referenced one: that arm mounts no section at all, because a
        /// reference cannot be promoted and carries neither record.
        case picture

        var noun: String {
            switch self {
            case .card: return "card"
            case .region: return "region"
            case .picture: return "picture"
            }
        }

        func became(_ title: String) -> String { "Became “\(title)”" }

        /// What a subject's content is *in*, along with whatever else is —
        /// the contribution record's sentence.
        ///
        /// **Visibly different from `became`**, and that is the whole point: one
        /// produced an artifact, the other's content went into somebody else's.
        /// One sentence for both would be the pane inviting a rewrite §6.3
        /// forbids.
        ///
        /// **It names no count.** A region's contributors are whoever had text
        /// at promotion time — sometimes one card — so "along with the others"
        /// would be false exactly when the region was smallest.
        ///
        /// **A picture has no words**, which is why this is a method on the
        /// subject rather than the one static string it was until 1C-d: a
        /// photograph appended to a palette card told *Its words are in “Colour:
        /// October”* is the false-noun class this file's own history is a
        /// monument to.
        func wordsAreIn(_ title: String) -> String {
            switch self {
            case .card, .region: return "Its words are in “\(title)”"
            case .picture: return "This picture is in “\(title)”"
            }
        }

        /// What Promote… will do from *here*, which is the fact the writer needs
        /// at the moment they are looking at this line — and the two subjects
        /// need different warnings because the two acts differ. A card's
        /// promotion makes something NEW; a picture's makes another COPY on the
        /// card it names, which is the thing a writer would otherwise discover
        /// by doing it twice.
        var contributionCaption: String {
            switch self {
            case .card, .region:
                return "A region's promotion folded this card's text into that. "
                    + "Promoting this card on its own makes something new — it "
                    + "never rewrites it."
            case .picture:
                return "Promoting this picture onto that card again adds a second "
                    + "copy — it never replaces what is already there."
            }
        }

        /// The dangling record's sentence. It carries no id: an id is not
        /// something the writer can read, and the mark's own dangling case set
        /// that precedent.
        var contributionArtifactMissing: String {
            switch self {
            case .card, .region:
                return "This card's words went into something that is no longer "
                    + "in the project."
            case .picture:
                return "This picture was added to something that is no longer in "
                    + "the project."
            }
        }
    }

    /// What a card's words are *in*, along with others' — the **contribution
    /// record** of spec §6.3, and deliberately not a second spelling of
    /// `ArtifactState`.
    ///
    /// **It is not the mark, and that is what stops the two being merged.**
    /// `promotedItemID` means *"I am this artifact"*, and
    /// `Promotion.existingArtifact` reads it — and only it — to offer
    /// **Rewrite**. A contributor carrying the mark would therefore offer to
    /// rewrite a six-card note with one card's text: the 1C-c2 Critical (a mark
    /// that did not record its artifact's *kind*) returning as a mark that does
    /// not record its *cardinality*. So this state has its own type, its own
    /// sentences, and no route into `existingArtifact`.
    ///
    /// Only a card can be in it. A region promoted to a note is the thing that
    /// *writes* these records, onto the cards whose text went in.
    enum ContributionState: Equatable {
        case none
        case contributed(itemID: String, title: String)
        /// A record whose artifact is no longer in the project. Reachable:
        /// records persist through the codec and are never rebuilt on load, so
        /// a card can name a note the writer has since deleted.
        case artifactMissing(itemID: String)
    }

    /// **Both records at once, because they are not two independent lines.**
    ///
    /// A card may carry a mark of its own *and* a contribution record, and §6.3
    /// says show both rather than choosing. The one place they genuinely
    /// interact is `saysNotPromotedYet` — which is the reported bug — so that
    /// combination is a value here rather than an `if` inside `body`, where no
    /// test could reach it (`_ConditionalContent` is branch-invariant and a
    /// `Form`'s contents are not inspectable).
    ///
    /// **No default on `contribution`**, deliberately, for the reason
    /// `RegionInspector`'s `artifactTitle` has none: a default is how the card
    /// arm would lose its half with nothing red. The region arm names `.none`
    /// and says why.
    struct Provenance: Equatable {
        let artifact: ArtifactState
        let contribution: ContributionState

        init(artifact: ArtifactState, contribution: ContributionState) {
            self.artifact = artifact
            self.contribution = contribution
        }

        /// **The one sentence that is a decision rather than a rendering.**
        /// "Not promoted yet." is true only when *neither* record exists. Said
        /// beside a contribution it is the bug 1C-c2b closes: the writer
        /// promoted a region, every card's text turned up in the note, and the
        /// cards they had not promoted individually reported that nothing had
        /// happened to them.
        var saysNotPromotedYet: Bool {
            artifact == .notPromoted && contribution == .none
        }
    }

    let state: Provenance
    let subject: Subject
    let onOpen: (String) -> Void

    static func artifactState(promotedItemID: String?, title: String?) -> ArtifactState {
        guard let itemID = promotedItemID else { return .notPromoted }
        guard let title else { return .artifactMissing(itemID: itemID) }
        return .promoted(itemID: itemID, title: title)
    }

    static func contributionState(contributedToItemID: String?,
                                  title: String?) -> ContributionState {
        guard let itemID = contributedToItemID else { return .none }
        guard let title else { return .artifactMissing(itemID: itemID) }
        return .contributed(itemID: itemID, title: title)
    }

    /// Resolve **both** records through the pane's artifact index, in one place.
    ///
    /// `title` is the deferred manifest lookup the inspector already holds, and
    /// it is asked once per record that exists — never for a card carrying
    /// neither, which is most of them.
    static func provenance(promotedItemID: String?,
                           contributedToItemID: String?,
                           title: (String) -> String?) -> Provenance {
        Provenance(artifact: artifactState(promotedItemID: promotedItemID,
                                           title: promotedItemID.flatMap(title)),
                   contribution: contributionState(
                    contributedToItemID: contributedToItemID,
                    title: contributedToItemID.flatMap(title)))
    }

    // MARK: - The contribution's own words
    //
    // **All three moved onto `Subject` in 1C-d.** They were statics while every
    // contributor was a card of text; an owned picture appended to a palette
    // card carries the same record and none of the three sentences was true of
    // it. See `Subject.wordsAreIn(_:)`.

    var body: some View {
        // **The heading names the TOPIC, not the state.** It read "Promoted"
        // while the section said only what a thing became; it now also says a
        // card's words are IN something it did not produce, and "Promoted" over
        // a contribution-only card asserts the one thing §6.3 spends its length
        // denying. "Promotion" sits beside "Card" and "Piece" as a noun for what
        // this part of the pane is about, and every sentence inside stays exact.
        Section("Promotion") {
            if state.saysNotPromotedYet {
                Text("Not promoted yet.").font(.caption).foregroundStyle(.secondary)
            }
            // **Two independent statements, never an `if`/`else`.** §6.3: a card
            // may carry both and they say different things, so the shape that
            // shows both is two straight-line switches rather than a choice
            // somebody could later "tidy" into picking one.
            switch state.artifact {
            case .notPromoted:
                EmptyView()
            case .promoted(let itemID, let title):
                openableLine(subject.became(title), itemID: itemID)
            case .artifactMissing:
                Text("This \(subject.noun) was promoted, and what it produced is no "
                     + "longer in the project.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            switch state.contribution {
            case .none:
                EmptyView()
            case .contributed(let itemID, let title):
                openableLine(subject.wordsAreIn(title), itemID: itemID)
                Text(subject.contributionCaption)
                    .font(.caption).foregroundStyle(.secondary)
            case .artifactMissing:
                Text(subject.contributionArtifactMissing)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// One row shape for both records — a sentence and the **Open** that reaches
    /// what it names. A second copy is how the two came to be spelled
    /// differently in the first place.
    private func openableLine(_ sentence: String, itemID: String) -> some View {
        HStack(spacing: 6) {
            Text(sentence).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Button("Open") { onOpen(itemID) }
                .buttonStyle(.borderless)
        }
    }
}
