/// The words a table figure's card shows, once, for the Mac's drawn card and the phone's.
public enum FigureCardText {
    /// The labelled cards (ruling R7a-3) and the empty table's.
    public static let removed = "Figure removed"
    public static let ambiguous = "Two figures share this path"
    public static let parked = "In Research"
    public static let empty = "Empty table"
    /// A registered figure whose files have not reached this device yet (the
    /// phone): neutral, never `removed`, never data.
    public static let notReady = "Not downloaded yet"
    /// The amber banner on a card whose pinned Research source has changed.
    public static let pinChanged = "Research has changed"

    /// "+ N more rows" (one row: "+ 1 more row").
    public static func more(_ n: Int) -> String { n == 1 ? "+ 1 more row" : "+ \(n) more rows" }
}
