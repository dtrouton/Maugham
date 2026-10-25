import Foundation

// MARK: - Matching a working copy to its parked figure (report plan 6b Task 8)
//
// `FigureReturnDiff`'s matching: which of the copy's columns and rows are the
// parked figure's, so they keep their ids. Pure.

extension FigureReturnDiff {


    /// (base live column index, copy live column index) pairs, in copy order.
    /// With a header row in the base: equal headers (`lcs`, then out of order:
    /// `movedPairs`), then a retitled column at its unchanged position
    /// (`samePositionPairs`). Without one, or with no header in common, by
    /// position.
    static func matchColumns(base: FigureTable, copy: FigureTable) -> [(Int, Int)] {
        let b = base.columns, c = copy.columns
        let byPosition = (0..<min(b.count, c.count)).map { ($0, $0) }
        guard base.headerRows == 1, let baseHeader = base.rows.first, let copyHeader = copy.rows.first else {
            return byPosition
        }
        let bk = b.enumerated().map { i, id in matchKey(base[CellKey(row: baseHeader, column: id)], at: (0, i), in: base) }
        let ck = c.enumerated().map { i, id in matchKey(copy[CellKey(row: copyHeader, column: id)], at: (0, i), in: copy) }
        var pairs = lcs(bk, ck)
        pairs += movedPairs(bk, ck, already: pairs, blank: { $0.isEmpty })
        guard !pairs.isEmpty else { return byPosition }
        pairs += samePositionPairs(baseCount: b.count, copyCount: c.count, already: pairs)
        return pairs.sorted { $0.1 < $1.1 }
    }

    /// A column no header matched, paired with the unmatched one at the same
    /// position: its header was retitled, it did not move.
    static func samePositionPairs(baseCount: Int, copyCount: Int, already: [(Int, Int)]) -> [(Int, Int)] {
        let takenB = Set(already.map(\.0)), takenC = Set(already.map(\.1))
        return (0..<min(baseCount, copyCount)).filter { !takenB.contains($0) && !takenC.contains($0) }.map { ($0, $0) }
    }

    /// (base live row index, copy live row index) pairs, in copy order, over
    /// the matched columns: equal rows in order (`lcs`), equal rows out of
    /// order (`movedPairs`), edited rows between two of those (`editedInGaps`),
    /// then edited rows anywhere (`editedAnywhere`).
    static func matchRows(base: FigureTable, copy: FigureTable, columns: [(Int, Int)]) -> [(Int, Int)] {
        let bk = rowKeys(base, columns: columns.map(\.0)), ck = rowKeys(copy, columns: columns.map(\.1))
        let anchors = lcs(bk, ck)
        var pairs = anchors + movedPairs(bk, ck, already: anchors, blank: { $0.allSatisfy(\.isEmpty) })
        pairs += editedInGaps(bk, ck, anchors: anchors, already: pairs)
        pairs += editedAnywhere(bk, ck, already: pairs)
        return pairs.sorted { $0.1 < $1.1 }
    }

    /// Each row's cells over `columns` (live column indices), as match keys.
    static func rowKeys(_ t: FigureTable, columns: [Int]) -> [[String]] {
        let ids = t.columns
        return t.rows.enumerated().map { r, row in
            columns.map { i in matchKey(t[CellKey(row: row, column: ids[i])], at: (r, i), in: t) }
        }
    }

    /// Between two in-order anchors, an unmatched copy row takes the first
    /// unmatched base row after the last one taken there that is alike
    /// enough (`likeness`) — or that was empty, and the copy filled in (as a
    /// return that stopped part way leaves its new rows).
    static func editedInGaps(
        _ bk: [[String]], _ ck: [[String]], anchors: [(Int, Int)], already: [(Int, Int)]
    ) -> [(Int, Int)] {
        var baseTaken = Set(already.map(\.0)), copyTaken = Set(already.map(\.1))
        var out: [(Int, Int)] = []
        let fences = [(-1, -1)] + anchors + [(bk.count, ck.count)]
        for k in 1..<fences.count {
            let (b0, c0) = fences[k - 1], (b1, c1) = fences[k]
            var next = b0 + 1
            for j in (c0 + 1)..<max(c1, c0 + 1) where !copyTaken.contains(j) {
                guard let i = (next..<max(b1, next)).first(where: {
                    !baseTaken.contains($0)
                        && (likeness(bk[$0], ck[j]) != nil || bk[$0].allSatisfy(\.isEmpty))
                }) else { continue }
                out.append((i, j))
                baseTaken.insert(i); copyTaken.insert(j)
                next = i + 1
            }
        }
        return out
    }

    /// Anywhere else, a row edited and moved: the most alike unmatched base
    /// row (`likeness`), the nearest on a tie. Skipped when what is left
    /// unmatched is too large to compare all against all.
    static func editedAnywhere(_ bk: [[String]], _ ck: [[String]], already: [(Int, Int)]) -> [(Int, Int)] {
        var baseTaken = Set(already.map(\.0)), copyTaken = Set(already.map(\.1))
        guard (bk.count - baseTaken.count) * (ck.count - copyTaken.count) <= 1_000_000 else { return [] }
        var out: [(Int, Int)] = []
        for j in 0..<ck.count where !copyTaken.contains(j) {
            var best: (i: Int, score: Double)?
            for i in 0..<bk.count where !baseTaken.contains(i) {
                guard let score = likeness(bk[i], ck[j]) else { continue }
                if best == nil || score > best!.score || (score == best!.score && abs(i - j) < abs(best!.i - j)) {
                    best = (i, score)
                }
            }
            guard let best else { continue }
            out.append((best.i, j))
            baseTaken.insert(best.i); copyTaken.insert(j)
        }
        return out
    }

    /// **Is one row the other edited?** The share of the cells either holds
    /// that are the same — over half, or exactly half with the same non-empty
    /// first cell (its label), so a deleted row and a new one that merely
    /// share a value are not one row. Nil when not alike enough, or when
    /// neither row holds anything (an empty row matches only an equal one).
    static func likeness(_ a: [String], _ b: [String]) -> Double? {
        var same = 0, held = 0
        for (x, y) in zip(a, b) where !x.isEmpty || !y.isEmpty {
            held += 1
            if x == y { same += 1 }
        }
        guard held > 0 else { return nil }
        if same * 2 > held { return Double(same) / Double(held) }
        if same * 2 == held, let x = a.first, !x.isEmpty, x == b.first { return 0.5 }
        return nil
    }

    /// Pairs of equal, non-blank keys left unpaired by `already`, each copy key
    /// taking the first such base key: a row or column the copy moved.
    static func movedPairs<K: Hashable>(
        _ a: [K], _ b: [K], already: [(Int, Int)], blank: (K) -> Bool
    ) -> [(Int, Int)] {
        let takenA = Set(already.map(\.0)), takenB = Set(already.map(\.1))
        var waiting: [K: [Int]] = [:]
        for (i, key) in a.enumerated() where !takenA.contains(i) && !blank(key) {
            waiting[key, default: []].append(i)
        }
        var out: [(Int, Int)] = []
        for (j, key) in b.enumerated() where !takenB.contains(j) {
            guard var list = waiting[key], !list.isEmpty else { continue }
            out.append((list.removeFirst(), j))
            waiting[key] = list
        }
        return out
    }

    /// The pairs of a longest common subsequence of `a` and `b`, in order. Common
    /// ends are matched first; a middle too large for the table (over 4 million
    /// cells) is matched greedily in order instead.
    static func lcs<K: Hashable>(_ a: [K], _ b: [K]) -> [(Int, Int)] {
        var lo = 0
        while lo < a.count, lo < b.count, a[lo] == b[lo] { lo += 1 }
        var ha = a.count, hb = b.count
        while ha > lo, hb > lo, a[ha - 1] == b[hb - 1] { ha -= 1; hb -= 1 }
        var out = (0..<lo).map { ($0, $0) }
        let n = ha - lo, m = hb - lo
        if n > 0, m > 0 {
            if n * m <= 4_000_000 {
                // dp[i][j] = LCS length of a[lo+i..<ha] and b[lo+j..<hb].
                var dp = [Int32](repeating: 0, count: (n + 1) * (m + 1))
                func at(_ i: Int, _ j: Int) -> Int { i * (m + 1) + j }
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        dp[at(i, j)] = a[lo + i] == b[lo + j]
                            ? dp[at(i + 1, j + 1)] + 1 : max(dp[at(i + 1, j)], dp[at(i, j + 1)])
                    }
                }
                var i = 0, j = 0
                while i < n, j < m {
                    if a[lo + i] == b[lo + j] { out.append((lo + i, lo + j)); i += 1; j += 1 }
                    else if dp[at(i + 1, j)] >= dp[at(i, j + 1)] { i += 1 }
                    else { j += 1 }
                }
            } else {
                var next: [K: [Int]] = [:]
                for i in lo..<ha { next[a[i], default: []].append(i) }
                var floor = lo
                for j in lo..<hb {
                    guard let i = next[b[j]]?.first(where: { $0 >= floor }) else { continue }
                    out.append((i, j))
                    floor = i + 1
                }
            }
        }
        out += (0..<(a.count - ha)).map { (ha + $0, hb + $0) }
        return out
    }

    /// Indices into `values` of one longest strictly increasing subsequence.
    static func longestIncreasing(_ values: [Int]) -> [Int] {
        var tails: [Int] = []          // index into values of the smallest tail per length
        var previous = [Int](repeating: -1, count: values.count)
        for (i, v) in values.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if values[tails[mid]] < v { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { previous[i] = tails[lo - 1] }
            if lo == tails.count { tails.append(i) } else { tails[lo] = i }
        }
        var out: [Int] = []
        var k = tails.last ?? -1
        while k >= 0 { out.append(k); k = previous[k] }
        return out.reversed()
    }

    // MARK: - Comparing cells

    /// What a cell is for matching: its value, or its formula's shape relative
    /// to the cell (`(row, column)` its live position in `table`).
    static func matchKey(_ cell: Cell?, at position: (Int, Int), in table: FigureTable) -> String {
        guard let cell else { return "" }
        switch cell.content {
        case .value(let v): return valueKey(v)
        case .formula(let f): return "=" + shape(f.expr, at: position, in: table)
        }
    }

    static func valueKey(_ v: CellValue) -> String {
        switch v {
        case .empty: return ""
        case .number(let x): return "n" + FormulaParser.numberText(x)
        case .date(let s): return "d\(s)"
        case .text(let s): return s.isEmpty ? "" : "t" + s
        case .bool(let b): return b ? "bT" : "bF"
        case .error(let e): return "e" + e.rawValue
        }
    }

    static func shape(_ e: FormulaExpr, at here: (Int, Int), in table: FigureTable) -> String {
        func ref(_ r: FormulaRef) -> String {
            var out: String
            switch r.target {
            case .this: out = ""
            case .figure(let id): out = "f" + id
            case .research(let id): out = "r" + id
            }
            switch (r.target, r.anchor) {
            case let (.this, .id(row, column)):
                let rr = table.rowIndex(of: row).map { r.rowAbsolute ? "R\($0)" : "r\($0 - here.0)" } ?? "#"
                let cc = table.columnIndex(of: column).map { r.columnAbsolute ? "C\($0)" : "c\($0 - here.1)" } ?? "#"
                out += rr + cc
            case let (_, .id(row, column)):
                out += "@" + row.raw + "," + column.raw
            case let (_, .position(row, column)):
                out += "p\(row),\(column)"
            }
            return out
        }
        switch e {
        case .number(let x): return FormulaParser.numberText(x)
        case .text(let s): return "\"" + s + "\""
        case .bool(let b): return b ? "T" : "F"
        case .missing: return "_"
        case .error(let err): return err.rawValue
        case .ref(let r): return ref(r)
        case .range(let g): return ref(g.start) + ":" + ref(g.end)
        case .unary(let op, let x): return op.rawValue + "(" + shape(x, at: here, in: table) + ")"
        case .binary(let op, let l, let r):
            return op.rawValue + "(" + shape(l, at: here, in: table) + "," + shape(r, at: here, in: table) + ")"
        case .call(let name, let args):
            return name + "(" + args.map { shape($0, at: here, in: table) }.joined(separator: ",") + ")"
        }
    }

}
