import AppKit

/// Pure data layer for character-name autocomplete suggestions.
/// UI integration (NSPopover, NSTableView) lands in subsequent tasks.
public final class CharacterAutocompleter {

    public init() {}

    /// Filter and rank candidate suggestions for a given prefix.
    /// - Returns: At most 8 candidates, with prefix-matches first
    ///   (alphabetical within), then substring-matches (alphabetical within),
    ///   excluding any candidates already in the prefix-match tier.
    public static func rankSuggestions(
        prefix: String,
        characterNames: Set<String>
    ) -> [String] {
        guard !prefix.isEmpty, !characterNames.isEmpty else { return [] }

        let upperPrefix = prefix.uppercased()
        let allUpper = Set(characterNames.map { $0.uppercased() })

        let prefixMatches = allUpper
            .filter { $0.hasPrefix(upperPrefix) }
            .sorted()

        let substringMatches = allUpper
            .filter { name in
                guard let range = name.range(of: upperPrefix) else { return false }
                guard !name.hasPrefix(upperPrefix) else { return false }
                // Only include if the match is not at the very end of the name
                // (i.e. there is at least one character after the matched prefix).
                return range.upperBound < name.endIndex
            }
            .sorted()

        let combined = prefixMatches + substringMatches
        return Array(combined.prefix(8))
    }
}
