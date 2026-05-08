import Foundation

public enum RenamePlanError: Error, Equatable {
    case duplicateSource(String)
    case duplicateDestination(String)
    case ancestorOverlap
}

/// A validated batch of (oldRelativePath → newRelativePath) renames, classified
/// into ones that can run direct and ones that need a scratch-directory swap
/// to avoid intermediate path collisions.
///
/// "Slot collision" semantics: two siblings in the same parent directory share
/// a slot when they would occupy the same ordinal position in the binder's
/// "NN-" ordering scheme. A step needs scratch when its destination slot is
/// claimed by another step's source slot, or vice versa — even if the literal
/// path strings differ (e.g. swapping ordinals between `01-a.md` and `02-b.md`).
public struct RenamePlan: Equatable, Sendable {
    public struct Step: Equatable, Sendable, Hashable {
        public let oldRelativePath: String
        public let newRelativePath: String

        public init(oldRelativePath: String, newRelativePath: String) {
            self.oldRelativePath = oldRelativePath
            self.newRelativePath = newRelativePath
        }
    }

    /// All non-no-op steps after filtering and validation.
    public let steps: [Step]

    /// Steps whose slot collides with another step's source or destination slot.
    /// These need to go through scratch to avoid clobbering siblings.
    public let scratchSteps: [Step]

    /// Steps that can run direct (no slot-collision risk).
    public let directSteps: [Step]

    public init(steps: [Step]) throws {
        // Filter no-op renames.
        let filtered = steps.filter { $0.oldRelativePath != $0.newRelativePath }

        // Detect duplicate sources.
        var seenSources = Set<String>()
        for step in filtered {
            if !seenSources.insert(step.oldRelativePath).inserted {
                throw RenamePlanError.duplicateSource(step.oldRelativePath)
            }
        }

        // Detect duplicate destinations.
        var seenDestinations = Set<String>()
        for step in filtered {
            if !seenDestinations.insert(step.newRelativePath).inserted {
                throw RenamePlanError.duplicateDestination(step.newRelativePath)
            }
        }

        // Detect ancestor overlap: any step's path is a directory prefix of
        // another step's path. Reject; would invalidate the inner step's
        // oldRelativePath after the outer step renames.
        for a in filtered {
            for b in filtered where a != b {
                if Self.isAncestor(a.oldRelativePath, of: b.oldRelativePath) ||
                   Self.isAncestor(a.newRelativePath, of: b.newRelativePath) {
                    throw RenamePlanError.ancestorOverlap
                }
            }
        }

        // Classify scratch vs direct via slot collision detection.
        // A step is in scratch iff its destination slot is claimed by another
        // step's source slot, OR its source slot is claimed by another step's
        // destination slot. The bidirectional check catches both ends of any
        // chain or swap.
        let oldSlots = Set(filtered.map { Self.slot(for: $0.oldRelativePath) })
        let newSlots = Set(filtered.map { Self.slot(for: $0.newRelativePath) })

        var scratch: [Step] = []
        var direct: [Step] = []
        for step in filtered {
            let oldSlot = Self.slot(for: step.oldRelativePath)
            let newSlot = Self.slot(for: step.newRelativePath)

            // Other-old set excludes this step's own old slot.
            // Other-new set excludes this step's own new slot.
            // (Both are already guaranteed unique by the duplicate checks above,
            // so a "self-match" can only happen when the step's slot legitimately
            // appears in the opposing set.)
            let collidesIntoSource = oldSlots.contains(newSlot)
            let collidesFromDestination = newSlots.contains(oldSlot)

            if collidesIntoSource || collidesFromDestination {
                scratch.append(step)
            } else {
                direct.append(step)
            }
        }

        self.steps = filtered
        self.scratchSteps = scratch
        self.directSteps = direct
    }

    /// True if `prefix` is a proper directory ancestor of `path`.
    /// I.e., path == "\(prefix)/..." with prefix being a path segment match.
    private static func isAncestor(_ prefix: String, of path: String) -> Bool {
        guard prefix != path else { return false }
        return path.hasPrefix(prefix + "/")
    }

    /// Compute the "slot" identifier for a relative path. If the final path
    /// component begins with an `NN-` ordinal prefix, the slot collapses to
    /// the parent directory plus that ordinal — so `01-a.md` and `01-b.md` in
    /// the same directory share a slot. Otherwise the slot is the full path.
    private static func slot(for relativePath: String) -> String {
        let lastSlash = relativePath.lastIndex(of: "/")
        let parent: Substring
        let filename: Substring
        if let lastSlash {
            parent = relativePath[..<lastSlash]
            filename = relativePath[relativePath.index(after: lastSlash)...]
        } else {
            parent = ""
            filename = Substring(relativePath)
        }

        if let ordinal = ordinalPrefix(of: filename) {
            return parent.isEmpty ? ordinal : "\(parent)/\(ordinal)"
        }
        return relativePath
    }

    /// If `name` starts with one or more digits followed by "-", return those
    /// digits. Otherwise nil.
    private static func ordinalPrefix(of name: Substring) -> String? {
        var digits = ""
        for ch in name {
            if ch.isNumber {
                digits.append(ch)
            } else {
                if ch == "-" && !digits.isEmpty {
                    return digits
                }
                return nil
            }
        }
        return nil
    }
}
