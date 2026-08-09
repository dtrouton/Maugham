import SwiftUI
import MaughamCore

/// The promotion sheet's state, lifted out of the view so every branch it makes
/// is reachable from a test that hosts no SwiftUI — the same discipline
/// `RegionInspector.citeAffordance` follows, and for the same reason.
///
/// `Identifiable` because `.sheet(item:)` presents it; the id is per-invocation,
/// so invoking the command twice presents two sheets rather than reusing one
/// whose state belongs to the previous selection.
@Observable
@MainActor
final class PromotionSheetModel: Identifiable {

    /// Spec §5's precedence, stated once, plainly, where it costs the writer
    /// something — which is the only place a rule like this is read.
    static let precedenceNote =
        "Canvas lines are scratch — they cost nothing to be wrong about. "
        + "[[Wiki-links]] are the durable layer, which is why a line can only "
        + "become one once both of its cards have been promoted."

    let id = UUID()
    let source: PromotionSource

    private let scene: CanvasScene
    private let scraps: [CanvasNodeID: String]
    private let artifacts: ArtifactIndex
    /// The canvas's own index, for the one question `artifacts` cannot answer:
    /// where a REFERENCED picture's file lives (`PromotionRequest.items`).
    private let items: CanvasItemIndex
    /// Where the source's piece association sends this (spec §6.2), resolved
    /// against the live manifest once, when the sheet opened — the same
    /// discipline every other property here follows.
    private let piece: PromotionPiece
    /// itemID → the artifact's body on disk. Called once per target selection.
    private let readBody: (String) -> String?

    let availableTargets: [PromotionTarget]
    let blockedReason: String?
    /// The paragraph shown BESIDE a refusal — **only where it is about the
    /// writer's situation.**
    ///
    /// `precedenceNote` is line-specific. While `blockedReason` was non-nil only
    /// for lines the pairing was right by construction; widening that to the
    /// empty scrap and the item node made it wrong, so a writer with an empty
    /// card read "There is nothing in this card to promote." followed by a
    /// paragraph about lines and wiki-links. That is finding 8's own defect — a
    /// refusal saying something untrue of the situation — one file over.
    ///
    /// A decision on the model rather than an `if` inside the view, matching
    /// everything else this sheet branches on: a `Form`'s contents are not
    /// inspectable, so a branch left in `body` is unreachable from a test.
    let blockedNote: String?

    private(set) var selectedTarget: PromotionTarget?
    private(set) var availableModes: [PromotionMode] = [.new]
    /// What the sheet shows under "Preview" — `previewSection` reads this, and
    /// only this, for the destination line and the body excerpt. It must track
    /// `mode` live: it is the thing on screen when the writer chooses Update,
    /// and a frozen `.new`-mode snapshot there is the exact lie §6.1 exists to
    /// prevent before an overwrite.
    private(set) var preview: PromotionPlan?

    var editedTitle = ""
    var linksAccepted = false
    var paletteKind: PaletteCard.Kind = .other

    /// A palette card the picture can be added to. `Identifiable` for `ForEach`;
    /// a tuple cannot be one.
    struct PaletteCardChoice: Identifiable, Equatable {
        let id: String
        let title: String
    }

    /// Every palette card the project holds, for `.paletteCardImage`'s picker.
    /// Read off `ArtifactIndex` — which already walked the manifest once when
    /// this sheet opened — rather than from the store, so the whole class stays
    /// plain values.
    let paletteCardChoices: [PaletteCardChoice]

    /// Which card an owned picture is appended to. Seeded by `select(_:)` the
    /// moment that target is chosen, so the writer never meets an empty picker
    /// over a disabled button — and re-derives the preview in place, exactly as
    /// `mode` does, because the destination line names the card.
    var paletteCardID: String? {
        didSet {
            guard oldValue != paletteCardID, selectedTarget != nil else { return }
            preview = Promotion.plan(request(), in: scene)
        }
    }

    /// Changing this after a target is chosen re-derives `preview` in place —
    /// see the `didSet` below. Picking Update must move what "Goes to" shows,
    /// not just what Commit would do.
    var mode: PromotionMode = .new {
        didSet {
            guard oldValue != mode, selectedTarget != nil else { return }
            preview = Promotion.plan(request(), in: scene)
            // **The name is re-seeded here, and its absence was half of one
            // defect** (M6-PR-039, RULING-22, fixed 2026-08-09). `select(_:)`
            // seeded `editedTitle` from a `.new` plan — the card's first line —
            // and nothing re-seeded it when the writer chose Rewrite. Three
            // strings were then on screen at once, the mode picker and the
            // "Goes to" line both naming the artifact by the title the writer
            // gave it, and the quietest of them — this field, which
            // `resolvedPlan` writes over `plan.title` — carried the card's first
            // line into the performer, which renamed the note and its file to
            // match. `Promotion.plannedTitle` answers the artifact's own name on
            // a rewrite, so re-seeding from the plan is all this needs.
            //
            // **And the writer's own name is kept while it does** (whole-branch
            // review, 2026-08-09). The re-seed above is one-way: a writer who
            // typed a name, looked at Rewrite and came back to New found their
            // name replaced by the card's first line, because the way back is
            // the same assignment reading a `.new` plan. Typing is the one thing
            // on this sheet the writer cannot get back by clicking again, so it
            // is what the mode picker must not cost them.
            if case .update = mode {
                titleBeforeRewrite = editedTitle
                editedTitle = preview?.title ?? editedTitle
            } else {
                editedTitle = titleBeforeRewrite ?? preview?.title ?? editedTitle
                titleBeforeRewrite = nil
            }
        }
    }

    /// What the writer had typed when they switched to Rewrite, held for the
    /// switch back. Nil whenever the mode is not `.update`.
    private var titleBeforeRewrite: String?

    /// The destination's body as of the last `select(_:)`. A SNAPSHOT — the
    /// performer checks the live file again before it writes.
    private var destinationBody: String?

    let sourceDescription: String

    /// **`piece` has no default, deliberately.** `.none` is a legitimate value —
    /// most promotions are in it — which is exactly why a default here would be
    /// invisible: omit it at the one production call site and every destination
    /// in the sheet quietly reverts to the pre-§6.2 wording with nothing red.
    /// `PromotionRequest`'s copy is defaulted because it is reached from dozens
    /// of tests that genuinely mean "no association"; this one is reached from
    /// `CanvasPromotionModifier.begin` and from tests about the piece.
    ///
    /// **`items` has none either, for the identical reason and with the
    /// identical failure** (1C-d Task 12a): `.empty` is a legitimate value — a
    /// canvas hosted without a window really has no index — so a default here
    /// would be invisible, and omitting it at the one production call site would
    /// leave every REFERENCED picture in a promoted region silently uncopied and
    /// unrecorded, with nothing red.
    init(source: PromotionSource,
         scene: CanvasScene,
         scraps: [CanvasNodeID: String],
         artifacts: ArtifactIndex,
         items: CanvasItemIndex,
         piece: PromotionPiece,
         readBody: @escaping (String) -> String?) {
        self.source = source
        self.scene = scene
        self.scraps = scraps
        self.artifacts = artifacts
        self.items = items
        self.piece = piece
        self.readBody = readBody
        self.availableTargets = Promotion.targets(for: source, in: scene, artifacts: artifacts)
        self.paletteCardChoices = artifacts.paletteCards
            .map { PaletteCardChoice(id: $0.id, title: $0.title) }
        self.blockedReason = Promotion.blockedReason(for: source, in: scene,
                                                     scraps: scraps, artifacts: artifacts)
        // Resolved here with everything else this class reads once at init, and
        // gated on the SOURCE rather than on "there is a reason": the note
        // explains the line/wiki-link precedence and says nothing to a writer
        // whose card is simply empty.
        if case .line = source {
            self.blockedNote = Self.precedenceNote
        } else {
            self.blockedNote = nil
        }
        // Resolved once here, and held as a plain value — the same discipline
        // every other property on this class follows (read the scene once at
        // init), rather than re-touching `scene`/`scraps` on every access.
        switch source {
        case .scrap(let id):
            // **An owned item node reaches this arm since 1C-d**, and it is a
            // picture rather than a card — so it gets the `.line` arm's shape (a
            // noun, no title) instead of the card sentence. `CanvasItemFacts`
            // would answer "Image" for every one of them, which read back as
            // *The card “Image”*: a false noun wrapped around a word that
            // identifies nothing. What identifies an owned card is the picture
            // drawn on it, and the writer is looking at it.
            //
            // **It destructures the PROVENANCE, like every other site that
            // differs between the two** (review M2/M3). `if case .item` alone
            // called a referenced research note "This picture" — unreachable,
            // because `isPromotable` refuses a reference and `ItemInspector`
            // withholds the button, but this was the one place in the task
            // testing the kind where the sentence is only true of one half of it.
            if case .item(.owned) = scene.node(id)?.kind {
                self.sourceDescription = "This picture"
                break
            }
            self.sourceDescription =
                // `items: .empty` is exact: every other node that reaches this
                // line is a `.scrap`, whose `chipTitle` reads its text and never
                // the index. (The item branch is reachable in principle now — it
                // simply is not reached, because the case above returns first.)
                "The card “\(CanvasRenderer.chipTitle(for: id, in: scene, scraps: scraps, items: .empty))”"
        case .region(let id):
            self.sourceDescription =
                "The region “\(scene.region(id)?.displayLabel ?? CanvasRegion.untitledLabel)”"
        case .line:
            self.sourceDescription = "This line"
        }
    }

    /// Choosing a target is the one place work happens: the mode list is
    /// rebuilt, the title is re-seeded, and the destination is read from disk
    /// exactly once.
    func select(_ target: PromotionTarget) {
        selectedTarget = target
        let existing = Promotion.existingArtifact(for: source, target: target,
                                                  in: scene, artifacts: artifacts)
        availableModes = Promotion.modes(for: target, existing: existing)
        // Never carried over: an update chosen for one target must not survive
        // into a target that cannot update. Assigned directly (not through a
        // helper) so the `didSet` above is free to fire on a later, genuine
        // mode change without this reset being mistaken for one.
        mode = .new
        destinationBody = nil
        // Seeded rather than left nil, so the writer meets a picker already
        // reading a card and a live Promote button — `Promotion.plan` returns
        // NO plan without one, so an unseeded picker would present a dead sheet
        // of the kind `blockedReason` exists to prevent. The first card by title
        // is the default because the list is sorted and a default has to be
        // stable; every card is one click away.
        //
        // Assigned before the `preview` below, and directly rather than through
        // the `didSet`'s work — the didSet fires, re-derives once, and the
        // `preview` line then re-derives the same plan; the alternative is a
        // seeded value the preview does not know about.
        paletteCardID = target == .paletteCardImage ? paletteCardChoices.first?.id : nil
        if target == .wikiLink, case .line(let id) = source, let line = scene.line(id),
           let itemID = scene.node(line.from)?.promotedItemID {
            destinationBody = readBody(itemID)
        }
        preview = Promotion.plan(request(), in: scene)
        editedTitle = preview?.title ?? ""
    }

    /// The plan as it stands with the writer's edits applied — what Commit sends.
    ///
    /// Nil until a target is chosen. `request()` would otherwise fall back to
    /// `.researchNote` for a scrap source — a valid target — and produce a
    /// plan before the writer has picked anything, which is not "the writer
    /// hasn't chosen a target" so much as it is a guess wearing that plan's
    /// shape.
    var resolvedPlan: PromotionPlan? {
        guard selectedTarget != nil else { return nil }
        guard var plan = Promotion.plan(request(), in: scene) else { return nil }
        plan.title = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        plan.linksAccepted = linksAccepted
        return plan
    }

    /// Whether the sheet asks the writer to NAME what this promotion produces.
    ///
    /// **A rewrite names nothing** (M6-PR-038/039, RULING-22, fixed 2026-08-09).
    /// The artifact already has a name — the writer's own, which they may have
    /// changed in the research pane since — and the performer no longer renames
    /// it as part of a rewrite. A field still offered here would be the editable
    /// box that changes nothing, which is the failure
    /// `PromotionTarget.namesItsArtifact` exists to prevent one row over. What
    /// the artifact is called is still on screen, twice: the mode picker reads
    /// *Rewrite “Fog, act II”* and the preview reads *Goes to: the existing
    /// “Fog, act II”*.
    ///
    /// A decision on the model rather than an `if` inside the view, matching
    /// everything else this sheet branches on: a `Form`'s contents are not
    /// inspectable, so a branch left in `body` is unreachable from a test.
    var namesTheArtifact: Bool {
        guard selectedTarget?.namesItsArtifact == true else { return false }
        if case .update = mode { return false }
        return true
    }

    /// The piece association's own refusal, in the performer's words — nil
    /// unless the association has gone stale AND this is the one act it can
    /// break. See `Promotion.pieceFailure`.
    ///
    /// **Before Commit rather than after.** Without it the writer chose a target,
    /// read a destination, pressed Promote, and met a store-shaped sentence in an
    /// alert — on a surface whose whole promise is that you can see what a
    /// command will do.
    var pieceRefusal: String? {
        guard let target = selectedTarget else { return nil }
        return Promotion.pieceFailure(
            target: target, mode: mode, piece: piece,
            // Resolved from the scene this sheet was opened over, so the sentence
            // before Commit and the performer's after it name the same control.
            canCarryItsOwnPiece: Promotion.canCarryItsOwnPiece(source, in: scene))?
            .errorDescription
    }

    var canCommit: Bool {
        guard let plan = resolvedPlan else { return false }
        // **Only the targets whose artifact the writer NAMES are asked for
        // one.** A wiki-link's title is the destination note's, and the intent
        // doc's is fixed — neither performer reads `plan.title` at all, so
        // requiring it disabled Promote for an act that names nothing.
        //
        // **`namesTheArtifact`, which is what the REFUSAL reads** (whole-branch
        // review, 2026-08-09). This asked the target alone, and a rewrite
        // narrowed the other two halves without it: the Name field is withheld
        // (`namesTheArtifact` is false in `.update`) and the refusal is gated on
        // the same value, so a rewrite whose resolved title came back empty
        // disabled Promote and said nothing at all — the dead sheet, arrived at
        // by the two conditions disagreeing rather than by either being wrong.
        // Reading one value is what makes them unable to disagree; the
        // performers already fall back to the artifact's live name.
        if namesTheArtifact && plan.title.isEmpty { return false }
        if pieceRefusal != nil { return false }
        return !plan.linkAlreadyPresent
    }

    /// Why Commit is off, when the reason is not simply "choose a target".
    var refusal: String? {
        guard let plan = resolvedPlan else { return nil }
        if let why = pieceRefusal { return why }
        if plan.linkAlreadyPresent {
            // **The performer's own sentence, not a second spelling** — the same
            // shape `pieceRefusal` above already uses. These are two surfaces for
            // one refusal (this one before Commit, the performer's after), and the
            // two said different things: this named the destination's title alone
            // and the failure hardcoded "the note", which is false about a
            // statement. `destinationDescription` carries the noun for both.
            return PromotionFailure
                .linkAlreadyPresent(destination: plan.destinationDescription)
                .errorDescription
        }
        // `namesTheArtifact` rather than the target's own property: a refusal may
        // only name a control that is on the sheet the writer is looking at, and
        // the Name field is withheld on a rewrite.
        if namesTheArtifact
            && editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "This needs a name."
        }
        return nil
    }

    /// §6.1: promotion is allowed to be lossy — and the writer is told which
    /// parts are dropped, before committing rather than after.
    var discardNotice: String? {
        guard let plan = preview, !plan.discards.isEmpty else { return nil }
        var parts: [String] = []
        if plan.discards.contains(.lines) { parts.append("the lines between these cards") }
        if plan.discards.contains(.layout) { parts.append("their layout") }
        if plan.discards.contains(.pictures) { parts.append("the pictures in it") }
        var notice = "Not carried across: " + Self.list(parts) + ". The canvas keeps them."
        // **"Not carried across … the pictures in it" reads as a THREAT over a
        // card that already holds copies of them** (1C-d Task 12a, review Minor
        // 2). It is true of the act — this rewrite copies none — and a writer
        // re-promoting a region whose pictures went onto that card on the first
        // promotion can read it as the card about to lose them, which is the one
        // thing a rewrite is careful not to do (`performPaletteCard` carries
        // `current.imagePaths` across untouched). The positive fact was stated
        // nowhere in the sheet; it is stated here, on the one row where the
        // ambiguity exists.
        if plan.discards.contains(.pictures), plan.producedKind == .paletteCard,
           case .update = plan.mode {
            notice += " The card keeps the images it already has."
        }
        return notice
    }

    /// `a`, `a and b`, `a, b and c` — **the third element is why this exists.**
    /// The two-part case joined on `" and "`, which read correctly for as long
    /// as there were exactly two discards; 1C-d's third turned it into "the
    /// lines between these cards and their layout and the pictures in it".
    private static func list(_ parts: [String]) -> String {
        guard let last = parts.last else { return "" }
        guard parts.count > 1 else { return last }
        return parts.dropLast().joined(separator: ", ") + " and " + last
    }

    /// What a region's promotion will COPY, said before the writer commits —
    /// §6.1's "the writer sees what will be produced, and where" applied to the
    /// half of a palette card that is not prose (1C-d Task 12a).
    ///
    /// **The sheet naming joined prose while silently copying three photographs
    /// fails §6.1 on its own terms**, which is why this is not left to the body
    /// excerpt. Its opposite — a region whose pictures are NOT carried — is said
    /// by `discardNotice` through `PromotionDiscard.pictures`, so the two
    /// directions are one machine each rather than one sentence with a `not` in
    /// it.
    ///
    /// A decision on the model rather than an `if` inside the view, matching
    /// everything else this sheet branches on: a `Form`'s contents are not
    /// inspectable.
    var pictureNotice: String? {
        guard let plan = preview, plan.producedKind == .paletteCard,
              !plan.pictures.isEmpty else { return nil }
        // The `.paletteCardImage` row has a caption of its own naming the card
        // the writer picked; this one is the region's, where the card is the
        // thing being produced.
        return plan.pictures.count == 1
            ? "Also copies the picture in this region onto the card."
            : "Also copies the \(plan.pictures.count) pictures in this region onto the card."
    }

    /// Both `preview` and `resolvedPlan` build off the same live `mode` now —
    /// there is no longer a forced-`.new` variant. `preview` tracked `mode`
    /// through the `didSet` above; a second, disagreeing reading here would
    /// just move the bug rather than fix it.
    private func request() -> PromotionRequest {
        PromotionRequest(
            source: source,
            target: selectedTarget ?? .researchNote,
            mode: mode,
            scraps: scraps,
            paletteKind: paletteKind,
            artifacts: artifacts,
            items: items,
            destinationBody: destinationBody,
            paletteCardID: paletteCardID,
            piece: piece)
    }
}

/// One verb, previewed. Scrivener's Commit is the model: a named command with a
/// stated rule and a predictable outcome (§6.1).
struct PromotionSheet: View {

    @Bindable var model: PromotionSheetModel
    let onCommit: (PromotionPlan) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Promote").font(.headline).padding([.top, .horizontal], 20)
            Text(model.sourceDescription)
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.top, 2)

            Form {
                if let why = model.blockedReason {
                    Section {
                        Text(why)
                        if let note = model.blockedNote {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    targetSection
                    if model.selectedTarget != nil { previewSection }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Promote") {
                    if let plan = model.resolvedPlan { onCommit(plan) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canCommit)
            }
            .padding(20)
        }
        .frame(width: 460)
    }

    @ViewBuilder
    private var targetSection: some View {
        Section("Produce") {
            ForEach(model.availableTargets) { target in
                Button {
                    model.select(target)
                } label: {
                    HStack {
                        Text(target.writerFacingName)
                        Spacer()
                        if model.selectedTarget == target {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        Section("Preview") {
            // Shown only where the writer's typing reaches the artifact — see
            // `PromotionSheetModel.namesTheArtifact`, which folds in the target
            // (a wiki-link and a craft intent name nothing) and the mode (a
            // rewrite writes into an artifact that is already named).
            if model.namesTheArtifact {
                TextField("Name", text: $model.editedTitle)
            }
            if let plan = model.preview {
                LabeledContent("Goes to", value: plan.destinationDescription)
                if !plan.body.isEmpty {
                    Text(plan.body)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            }
            if model.availableModes.count > 1 {
                Picker("When it exists", selection: $model.mode) {
                    ForEach(model.availableModes) { mode in
                        switch mode {
                        case .new: Text("Make a new one").tag(mode)
                        case .update(_, let title): Text("Rewrite “\(title)”").tag(mode)
                        }
                    }
                }
            }
            if model.selectedTarget == .paletteCard {
                Picker("Kind", selection: $model.paletteKind) {
                    ForEach(PaletteCard.Kind.allCases, id: \.self) {
                        Text($0.rawValue.capitalized).tag($0)
                    }
                }
            }
            // Which card the picture is added to. Offered only on that row, and
            // only ever populated — `Promotion.targets` withholds the row from a
            // project with no palette cards, so this picker cannot be empty.
            if model.selectedTarget == .paletteCardImage {
                Picker("Card", selection: $model.paletteCardID) {
                    ForEach(model.paletteCardChoices) { Text($0.title).tag(Optional($0.id)) }
                }
                Text("The picture is copied onto that card. Nothing already on it "
                     + "is replaced.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let offers = model.preview?.offeredLinks, !offers.isEmpty {
                Toggle(isOn: $model.linksAccepted) {
                    Text("Also link \(offers.count) promoted card\(offers.count == 1 ? "" : "s") to it")
                    Text("A suggestion, not a rule — membership is loose and a "
                         + "wiki-link is specific.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let notice = model.pictureNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if let notice = model.discardNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if let refusal = model.refusal {
                Text(refusal).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
