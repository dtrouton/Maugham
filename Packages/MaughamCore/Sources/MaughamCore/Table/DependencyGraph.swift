import Foundation

/// One cell in a workbook: the table's name and the cell's id pair.
public struct CellAddress: Hashable, Codable, Sendable {
    public let table: String
    public let key: CellKey
    public init(table: String, key: CellKey) { self.table = table; self.key = key }
}

/// Which formula cells read which cells. Edges run from a formula to each cell it reads
/// (its precedents), with the reverse kept for "what must recalculate". Every walk is
/// iterative, so neither a long chain nor a large table deepens the stack.
struct DependencyGraph: Sendable {
    private(set) var precedents: [CellAddress: Set<CellAddress>] = [:]
    private(set) var dependents: [CellAddress: Set<CellAddress>] = [:]

    /// Replaces the cells `formula` reads.
    mutating func setPrecedents(_ cells: Set<CellAddress>, of formula: CellAddress) {
        removePrecedents(of: formula)
        guard !cells.isEmpty else { return }
        precedents[formula] = cells
        for c in cells { dependents[c, default: []].insert(formula) }
    }

    /// Forgets what `formula` reads; cells that read it keep their edges.
    mutating func removePrecedents(of formula: CellAddress) {
        guard let old = precedents.removeValue(forKey: formula) else { return }
        for c in old {
            dependents[c]?.remove(formula)
            if dependents[c]?.isEmpty == true { dependents[c] = nil }
        }
    }

    /// `seeds` and every cell that reads one of them, directly or transitively.
    func closure<S: Sequence>(from seeds: S) -> Set<CellAddress> where S.Element == CellAddress {
        var seen = Set(seeds)
        var queue = Array(seen)
        while let next = queue.popLast() {
            for d in dependents[next] ?? [] where seen.insert(d).inserted { queue.append(d) }
        }
        return seen
    }

    /// The strongly connected components of the graph restricted to `nodes`, each one
    /// after every component it reads (an evaluation order). `cyclic` is a component of
    /// several cells, or one cell that reads itself. Tarjan's algorithm on an explicit stack.
    func components(of nodes: Set<CellAddress>) -> [(members: [CellAddress], cyclic: Bool)] {
        let list = Array(nodes)
        var number = [CellAddress: Int](minimumCapacity: list.count)
        for (i, a) in list.enumerated() { number[a] = i }
        let successors: [[Int]] = list.map { a in (precedents[a] ?? []).compactMap { number[$0] } }

        var index = [Int](repeating: -1, count: list.count)
        var low = [Int](repeating: 0, count: list.count)
        var onStack = [Bool](repeating: false, count: list.count)
        var stack = [Int]()
        var counter = 0
        var out = [(members: [CellAddress], cyclic: Bool)]()

        for root in list.indices where index[root] < 0 {
            var work: [(node: Int, next: Int)] = [(root, 0)]
            index[root] = counter; low[root] = counter; counter += 1
            stack.append(root); onStack[root] = true
            while let top = work.last {
                let v = top.node
                if top.next < successors[v].count {
                    let w = successors[v][top.next]
                    work[work.count - 1].next += 1
                    if index[w] < 0 {
                        index[w] = counter; low[w] = counter; counter += 1
                        stack.append(w); onStack[w] = true
                        work.append((w, 0))
                    } else if onStack[w] {
                        low[v] = min(low[v], index[w])
                    }
                    continue
                }
                work.removeLast()
                if let parent = work.last?.node { low[parent] = min(low[parent], low[v]) }
                guard low[v] == index[v] else { continue }
                var members = [CellAddress]()
                while let w = stack.popLast() {
                    onStack[w] = false
                    members.append(list[w])
                    if w == v { break }
                }
                let cyclic = members.count > 1 || successors[v].contains(v)
                out.append((members, cyclic))
            }
        }
        return out
    }
}
