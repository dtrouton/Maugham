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
    /// Changing this after a target is chosen re-derives `preview` in place —
    /// see the `didSet` below. Picking Update must move what "Goes to" shows,
    /// not just what Commit would do.
    var mode: PromotionMode = .new {
        didSet {
            guard oldValue != mode, selectedTarget != nil else { return }
            preview = Promotion.plan(request(), in: scene)
        }
    }

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
    init(source: PromotionSource,
         scene: CanvasScene,
         scraps: [CanvasNodeID: String],
         artifacts: ArtifactIndex,
         piece: PromotionPiece,
         readBody: @escaping (String) -> String?) {
        self.source = source
        self.scene = scene
        self.scraps = scraps
        self.artifacts = artifacts
        self.piece = piece
        self.readBody = readBody
        self.availableTargets = Promotion.targets(for: source, in: scene, artifacts: artifacts)
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
            self.sourceDescription =
                "The card “\(CanvasRenderer.chipTitle(for: id, in: scene, scraps: scraps))”"
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
        return Promotion.pieceFailure(target: target, mode: mode, piece: piece)?
            .errorDescription
    }

    var canCommit: Bool {
        guard let plan = resolvedPlan else { return false }
        // **Only the targets whose artifact the writer NAMES are asked for
        // one.** A wiki-link's title is the destination note's, and the intent
        // doc's is fixed — neither performer reads `plan.title` at all, so
        // requiring it disabled Promote for an act that names nothing.
        if plan.producedKind.namesItsArtifact && plan.title.isEmpty { return false }
        if pieceRefusal != nil { return false }
        return !plan.linkAlreadyPresent
    }

    /// Why Commit is off, when the reason is not simply "choose a target".
    var refusal: String? {
        guard let plan = resolvedPlan else { return nil }
        if let why = pieceRefusal { return why }
        if plan.linkAlreadyPresent {
            return "That link is already in “\(plan.title)”."
        }
        if plan.producedKind.namesItsArtifact
            && editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "This needs a name."
        }
        return nil
    }

    /// §6.1: promotion is allowed to be lossy — and the writer is told which
    /// parts are dropped, before committing rather than after.
    var discardNotice: String? {
        guard let discards = preview?.discards, !discards.isEmpty else { return nil }
        var parts: [String] = []
        if discards.contains(.lines) { parts.append("the lines between these cards") }
        if discards.contains(.layout) { parts.append("their layout") }
        return "Not carried across: " + parts.joined(separator: " and ")
            + ". The canvas keeps them."
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
            destinationBody: destinationBody,
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
            // `PromotionTarget.namesItsArtifact`. A field for a wiki-link or a
            // craft intent was editable, seeded from somebody else's title, and
            // discarded.
            if model.selectedTarget?.namesItsArtifact == true {
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
            if let offers = model.preview?.offeredLinks, !offers.isEmpty {
                Toggle(isOn: $model.linksAccepted) {
                    Text("Also link \(offers.count) promoted card\(offers.count == 1 ? "" : "s") to it")
                    Text("A suggestion, not a rule — membership is loose and a "
                         + "wiki-link is specific.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
