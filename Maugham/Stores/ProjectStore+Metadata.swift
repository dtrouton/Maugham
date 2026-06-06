import Foundation
import MaughamCore

// MARK: - Inspector + project metadata

extension ProjectStore {

    /// Update an item's inspector fields. `nil` arguments mean "leave unchanged";
    /// to explicitly clear a field, pass an empty string for synopsis/status,
    /// an empty array for tags/links, or `0` for wordTarget.
    public func updateInspector(
        id: String,
        synopsis: String? = nil,
        status: String? = nil,
        tags: [String]? = nil,
        wordTarget: Int? = nil,
        pageTarget: Int? = nil,
        links: [String]? = nil
    ) async throws {
        guard findItem(id: id, in: manifest.structure) != nil else {
            throw ProjectStoreError.structureMissing
        }
        mutateItem(id: id) { item in
            if let synopsis { item.synopsis = synopsis }
            if let status { item.status = status }
            if let tags { item.tags = tags.isEmpty ? nil : tags }
            if let wordTarget {
                // Treat 0 as "clear the target."
                item.wordTarget = wordTarget == 0 ? nil : wordTarget
            }
            if let pageTarget {
                item.pageTarget = pageTarget == 0 ? nil : pageTarget
            }
            if let links { item.links = links.isEmpty ? nil : links }
        }
        manifest.modified = Date()
        try await saveManifest()
    }

    /// Update project-level targets. Currently surfaces 3a's page target;
    /// future expansion can add total-words / deadline editing through the
    /// same path. Treat 0 as "clear the target" — mirrors per-document word
    /// target convention.
    public func updateProjectTargets(pageTarget: Int) async throws {
        var targets = manifest.targets ?? ProjectTargets()
        targets.pageTarget = pageTarget == 0 ? nil : pageTarget
        manifest.targets = targets
        manifest.modified = Date()
        try await saveManifest()
    }

    /// Toggle the per-project element gutter. nil = default (show); false =
    /// hide. The screenplay editor reads this on each layout pass.
    public func setShowElementGutter(_ value: Bool?) async throws {
        manifest.showElementGutter = value
        manifest.modified = Date()
        try await saveManifest()
    }

    /// Set or clear the per-project typography override.
    /// Pass `nil` to clear (fall back to user-level defaults).
    public func setProjectTypography(_ override: TypographySettings?) async throws {
        manifest.typography = override
        manifest.modified = Date()
        try await saveManifest()
    }

    /// Resolve the effective typography for an editor: prefer the
    /// project-level override, otherwise fall back to the user default.
    public static func effectiveTypography(
        override: TypographySettings?,
        userDefault: TypographySettings
    ) -> TypographySettings {
        override ?? userDefault
    }

}
