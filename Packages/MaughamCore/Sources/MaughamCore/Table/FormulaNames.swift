import Foundation

/// **The names a formula is typed and shown with, and the hidden ids it stores**
/// (Denver's ruling R-D1). A formula keeps `RefTarget.figure(id:)` and
/// `RefTarget.research(id:)`; this directory turns the name the writer types into
/// that id when a formula is read, and the id back into the CURRENT name when it is
/// shown. A figure renamed in the registry therefore needs no formula rewritten: the
/// next render shows the new name.
///
/// - A figure's name is its `FigureRecord.name`, matched without regard to case (as
///   the registry de-duplicates them). Its table is the one refs into it resolve
///   against; a figure with no table here (an image, an unreadable stream) is refused
///   by a parse and `name!#REF!` to a render.
/// - A research item's name is its `ResearchItem.title`, matched without regard to
///   case.
/// - Two figures, or two items, answering to one name refuse the parse rather than guess.
/// - An id the directory cannot name renders `#REF!`, as a missing table did.
public struct FormulaNames: Sendable {

    /// One figure a formula may read.
    public struct Figure: Equatable, Sendable {
        public let id: String
        public let name: String
        public let table: FigureTable?
        public init(id: String, name: String, table: FigureTable?) {
            self.id = id
            self.name = name
            self.table = table
        }
    }

    /// What a name typed in a formula answers to.
    enum Lookup: Equatable {
        case found(String)      // the id
        case unknown
        case ambiguous
    }

    private var figuresById: [String: Figure] = [:]
    private var figureIdsByName: [String: [String]] = [:]          // by folded name
    private var researchTitlesById: [String: String] = [:]
    private var researchIdsByFoldedTitle: [String: [String]] = [:]

    /// No figures and no research: only refs into the table itself resolve.
    public static let empty = FormulaNames()

    public init(figures: [Figure] = [], research: [(id: String, title: String)] = []) {
        for f in figures where figuresById[f.id] == nil {
            figuresById[f.id] = f
            figureIdsByName[Self.folded(f.name), default: []].append(f.id)
        }
        for r in research where researchTitlesById[r.id] == nil {
            researchTitlesById[r.id] = r.title
            researchIdsByFoldedTitle[Self.folded(r.title), default: []].append(r.id)
        }
    }

    /// The book's directory: every registry record with its table from `tables`
    /// (keyed by figure id — `Workbook.tables`), and every research asset in the tree.
    public init(records: [FigureRecord], tables: [String: FigureTable], research: [ResearchItem]) {
        self.init(
            figures: records.map { Figure(id: $0.id, name: $0.name, table: tables[$0.id]) },
            research: TreeWalk.collect(in: research, where: { $0.type == .asset }).map { ($0.id, $0.title) })
    }

    /// The table figure `id` reads, when there is one.
    public func table(id: String) -> FigureTable? { figuresById[id]?.table }

    /// The current name of figure `id`, or nil when the directory has no such figure.
    public func figureName(id: String) -> String? { figuresById[id]?.name }

    /// The current title of research item `id`, or nil when it is not in the tree.
    public func researchTitle(id: String) -> String? { researchTitlesById[id] }

    /// A figure by the name typed, any case: a name two records share, in any case (two
    /// devices made it before either saw the other), is ambiguous, never the first found.
    func figure(named name: String) -> Lookup {
        Self.lookup(figureIdsByName[Self.folded(name)] ?? [])
    }

    /// A research item by the name typed, any case.
    func research(named name: String) -> Lookup {
        Self.lookup(researchIdsByFoldedTitle[Self.folded(name)] ?? [])
    }

    private static func lookup(_ ids: [String]) -> Lookup {
        switch ids.count {
        case 0: return .unknown
        case 1: return .found(ids[0])
        default: return .ambiguous
        }
    }

    private static func folded(_ name: String) -> String { name.lowercased() }
}
