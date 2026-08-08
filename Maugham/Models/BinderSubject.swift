import Foundation

/// What the window's tree names — the single subject the persona shell works
/// over (spec `2026-08-01-persona-shell-workflow-design.md` §3).
///
/// **A typed value rather than a second magic string.** The `String?` this
/// replaces carried three meanings at once: `nil` for no selection, a
/// `StructureItem.id` that may name a document *or* a group, and — after a
/// `?? "__no-selection__"` at three call sites and at a fourth with no
/// substitution at all — a sentinel. Every site that had to answer *"is this a
/// manuscript document?"* was free to answer with a sentinel compare, a
/// `TreeWalk.find` + `type` test, a registry lookup, or nothing. A row naming
/// the project would have made it five meanings on one `String?`.
///
/// The precedent is `DeviceSlug` (tripwire 24), where *"enforcement = the
/// compiler"*. There is deliberately **no `rawValue` and no `init(String)`**:
/// a site that wants a bare id has to say, where it asks, what the project
/// means to it. `itemID` and `activeDocId(for:)` are those two answers and are
/// the only way out of the type.
public enum BinderSubject: Hashable, Sendable {

    /// The project itself — the subject `StatementPane`'s `[chapter | Project]`
    /// switch existed to reach because the tree could not say it.
    ///
    /// **Both halves of that sentence are now history.** A head row at the top
    /// of the tree constructs this case, and the pane's switch was deleted once
    /// it did (slice 1, task 7) — a second subject-picker beside the tree is two
    /// controls that can disagree about what the window is about.
    ///
    /// **"The tree" is one control per project type, and every one of them needs
    /// the row.** A sentence here naming two of them stood for the length of a
    /// slice while a screenplay had none — its manuscript home is the Scenes
    /// navigator, and with the pane's switch gone that made this case
    /// unconstructible in a whole project type, with a legacy craft-intent note
    /// adopted into exactly this scope and nothing left to show it. So the count
    /// is not written down here: `ProjectSubjectReachabilityTests` mounts the
    /// surface production mounts for each `ProjectType` and drives a real
    /// selection through it, which is the form of the claim that cannot go
    /// quietly stale.
    case project

    /// A node of `manifest.structure` — a manuscript document *or* a group.
    ///
    /// The document/group distinction is deliberately **not** encoded here. The
    /// load-bearing test is `TreeWalk.find(id:in:)` plus `item.type == .document`
    /// against a manifest this type cannot see, and a second answer baked into
    /// the case would be free to disagree with it.
    case item(String)

    /// A research item, by id — the tree's other kind of leaf (stage-2a Task 1,
    /// the shell-finish "tree grows" milestone). `itemID` returns `nil` for
    /// this case, same as `.project`: every existing reader of `itemID`
    /// assumes structure (`activeItemID`, `OutlineTable`, `CanvasSubject.resolve`
    /// among them), and a research id answering there would be a document id
    /// no `TreeWalk` can find. `researchID` is this case's own one-way
    /// accessor, the mirror of `itemID`.
    case research(String)

    /// The structure-item id this subject names, or `nil` when it names the
    /// project or a research item.
    ///
    /// One-way on purpose: there is no inverse. A caller reaching for this has
    /// to handle the `nil` that means *"the subject is not a structure item"*,
    /// which is the decision the old `String?` let every site skip.
    public var itemID: String? {
        switch self {
        case .project: return nil
        case .item(let id): return id
        case .research: return nil
        }
    }

    /// The research-item id this subject names, or `nil` when it names the
    /// project or a structure item. The mirror of `itemID`.
    public var researchID: String? {
        switch self {
        case .project, .item: return nil
        case .research(let id): return id
        }
    }

    /// The `activeDocId` the per-document right-hand panes take when the subject
    /// is not a document — History, Tasks, the annotations arm and the
    /// translation arm all want a non-optional id and test it against this.
    ///
    /// **The one literal.** It was previously written out at six production
    /// sites; every one of them names this constant instead, so there is one
    /// string to change and one place to look for what it means.
    ///
    /// **Who reads it is deliberately not listed here.** The sentence that stood
    /// in this place named four panes and was wrong in the commit that wrote it —
    /// a fifth reader (`ProjectWindow`'s `TranslationReviewModifier`) arrived in
    /// the same slice, and no test guards a list in prose
    /// (`memory/feedback_prose_counts_are_unmaintainable.md`). What is guarded is
    /// the property that actually matters, and by a scan rather than a sentence:
    /// `BinderSubjectTests.test_theSentinelLiteralIsWrittenInExactlyOnePlace`
    /// fails the moment a site spells `"__no-selection__"` instead of naming this
    /// constant, and has a planted-offender companion so it cannot pass
    /// vacuously. For the readers themselves, ask the compiler — they are the
    /// references to this symbol.
    public static let noDocumentSubject = "__no-selection__"

    /// The bare document id for a subject, for the consumers that legitimately
    /// want one.
    ///
    /// **The conversion happens here and nowhere else.** Before this there were
    /// three spellings of the same defaulting rule three hops apart — a `??` in
    /// `ProjectWindow`'s checkpoint sheet, a second in its inspector column, a
    /// raw un-substituted value handed to a parameter of the same name, and a
    /// *fourth* re-substitution inside `DetailPaneToggle` on a value already
    /// substituted upstream. A pane's behaviour depended on which hop it hung
    /// off.
    ///
    /// Note what this does **not** promise: the id it returns may name a group.
    /// Deciding a group is not a document is `TreeWalk` + `item.type`'s job
    /// against the manifest, exactly as it was.
    public static func activeDocId(for subject: BinderSubject?) -> String {
        subject?.itemID ?? noDocumentSubject
    }
}
