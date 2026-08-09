import Foundation
import MaughamCore

// MARK: - Minimal TreeNode conformers for the experiment

/// The plainest possible conformer — id and children only.
struct XNode: TreeNode, Equatable {
    var id: String
    var children: [XNode]?

    init(_ id: String, _ children: [XNode]? = nil) {
        self.id = id
        self.children = children
    }
}

/// A conformer carrying the out-of-protocol `path` that `rewritePaths` and
/// `idsByPath` reach through closures.
struct XPathNode: TreeNode, Equatable {
    var id: String
    var path: String?
    var children: [XPathNode]?

    init(_ id: String, path: String? = nil, children: [XPathNode]? = nil) {
        self.id = id
        self.path = path
        self.children = children
    }
}

extension XPathNode {
    static let readPath: (XPathNode) -> String? = { $0.path }
    static let writePath: (inout XPathNode, String) -> Void = { $0.path = $1 }
}

// MARK: - A deterministic, seeded generator (Phase 4 leans on this too)

/// SplitMix64. Deterministic across runs and platforms, so a shattered property
/// reproduces from its seed alone. Deliberately not `SystemRandomNumberGenerator`.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    mutating func bool(_ pTrue: Double = 0.5) -> Bool {
        Double.random(in: 0..<1, using: &self) < pTrue
    }

    mutating func pick<T>(_ xs: [T]) -> T {
        xs[int(0...(xs.count - 1))]
    }
}
