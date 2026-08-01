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
public enum BinderSubject: Hashable {

    /// The project itself — the subject `StatementPane`'s `[chapter | Project]`
    /// switch exists to reach because the tree cannot say it.
    ///
    /// Representable from here on; the binder row that constructs it is a later
    /// task, so in this build nothing but a test produces this case. That is the
    /// intended end state of introducing the type, not an oversight.
    case project

    /// A node of `manifest.structure` — a manuscript document *or* a group.
    ///
    /// The document/group distinction is deliberately **not** encoded here. The
    /// load-bearing test is `TreeWalk.find(id:in:)` plus `item.type == .document`
    /// against a manifest this type cannot see, and a second answer baked into
    /// the case would be free to disagree with it.
    case item(String)

    /// The structure-item id this subject names, or `nil` when it names the
    /// project.
    ///
    /// One-way on purpose: there is no inverse. A caller reaching for this has
    /// to handle the `nil` that means *"the subject is the project"*, which is
    /// the decision the old `String?` let every site skip.
    public var itemID: String? {
        switch self {
        case .project: return nil
        case .item(let id): return id
        }
    }

    /// The `activeDocId` the per-document right-hand panes take when the subject
    /// is not a document — History, Tasks, the annotations arm and the
    /// translation arm all want a non-optional id and test it against this.
    ///
    /// **The one literal.** It was previously written out at six production
    /// sites; `HistoryPane`, `TasksPane`, `StatementPane` and `DetailPaneToggle`
    /// now all name this constant instead, so there is one string to change and
    /// one place to look for what it means.
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
