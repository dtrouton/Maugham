import Foundation

/// Computes filenames for new structure items: `NN-slug.ext` for documents,
/// `NN-slug` for group folders. NN is monotonically increasing within a
/// parent folder; slug collisions get a numeric suffix.
public enum FileNaming {

    /// `siblingFilenames` is the list of existing files/folders in the parent.
    /// Returns a name guaranteed not to collide.
    public static func nextDocumentFilename(
        title: String,
        extension ext: String,
        siblingFilenames: [String]
    ) -> String {
        let base = Slugifier.slug(from: title)
        let nn = nextNN(in: siblingFilenames)
        let slug = uniqueSlug(base: base, ext: ext, isFolder: false,
                              siblings: siblingFilenames)
        return "\(nn)-\(slug).\(ext)"
    }

    public static func nextGroupFolderName(
        title: String,
        siblingFilenames: [String]
    ) -> String {
        let base = Slugifier.slug(from: title)
        let nn = nextNN(in: siblingFilenames)
        let slug = uniqueSlug(base: base, ext: nil, isFolder: true,
                              siblings: siblingFilenames)
        return "\(nn)-\(slug)"
    }

    // MARK: - Helpers

    /// Parse `NN-...` from each sibling. NN must be a 2-digit prefix
    /// followed by a dash. Files that don't match are ignored.
    private static func nextNN(in siblings: [String]) -> String {
        let regex = try? NSRegularExpression(pattern: #"^(\d{2})-"#)
        var maxNN = 0
        for name in siblings {
            let range = NSRange(name.startIndex..., in: name)
            guard let regex,
                  let match = regex.firstMatch(in: name, range: range),
                  let nnRange = Range(match.range(at: 1), in: name),
                  let n = Int(name[nnRange]) else { continue }
            if n > maxNN { maxNN = n }
        }
        return String(format: "%02d", maxNN + 1)
    }

    private static func uniqueSlug(
        base: String,
        ext: String?,
        isFolder: Bool,
        siblings: [String]
    ) -> String {
        // Extract the post-NN slug part of each sibling (with same extension or folder type).
        // Two sets are built:
        //   • fullSlugs  — the complete extracted slug (e.g. "chapter-1-2")
        //   • baseSlugs  — the slug with any trailing collision suffix stripped
        //                  (e.g. "chapter-1-2" → "chapter-1"; "chapter-1" stays "chapter-1"
        //                   because trailing "-1" uses suffix ≥ 2 rule, see below)
        // Collision detection uses baseSlugs; suffix selection uses fullSlugs.
        let regex = try? NSRegularExpression(pattern: #"^\d{2}-(.+?)(\.[^.]+)?$"#)
        // Matches a trailing collision suffix: dash followed by an integer ≥ 2.
        let suffixRegex = try? NSRegularExpression(pattern: #"-(\d+)$"#)

        var fullSlugs = Set<String>()
        var baseSlugs = Set<String>()

        for name in siblings {
            let range = NSRange(name.startIndex..., in: name)
            guard let regex,
                  let match = regex.firstMatch(in: name, range: range),
                  let slugRange = Range(match.range(at: 1), in: name) else { continue }
            // Match if extension matches (for documents) or no extension (for folders)
            let extPart = match.range(at: 2).location != NSNotFound
                ? Range(match.range(at: 2), in: name).map { String(name[$0]) }
                : nil
            let shouldInclude: Bool
            if isFolder {
                shouldInclude = extPart == nil
            } else if let ext {
                shouldInclude = extPart == ".\(ext)"
            } else {
                shouldInclude = false
            }
            guard shouldInclude else { continue }

            let slug = String(name[slugRange])
            fullSlugs.insert(slug)

            // Strip trailing "-N" (N ≥ 2) to get the canonical base slug.
            let stripped: String
            let slugNSRange = NSRange(slug.startIndex..., in: slug)
            if let suffixRegex,
               let suffixMatch = suffixRegex.firstMatch(in: slug, range: slugNSRange),
               let nRange = Range(suffixMatch.range(at: 1), in: slug),
               let n = Int(slug[nRange]),
               n >= 2 {
                stripped = String(slug[slug.startIndex ..< slug.index(slug.endIndex, offsetBy: -suffixMatch.range(at: 0).length)])
            } else {
                stripped = slug
            }
            baseSlugs.insert(stripped)
        }

        // If the base slug doesn't appear among canonical (stripped) slugs, no collision.
        if !baseSlugs.contains(base) {
            return base
        }
        // Find lowest suffix N ≥ 2 not already taken (checked against full slugs).
        var n = 2
        while fullSlugs.contains("\(base)-\(n)") {
            n += 1
        }
        return "\(base)-\(n)"
    }
}
