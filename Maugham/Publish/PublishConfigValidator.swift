import Foundation

public enum PublishConfigValidator {

    /// Maximum supported `schema_version`. Bump when adding fields that older
    /// clients shouldn't silently accept.
    public static let supportedSchemaVersion = 1

    public struct ValidationError: Equatable, Sendable {
        public let field: String
        public let message: String
    }

    public static func validate(_ cfg: PublishConfig) -> [ValidationError] {
        var errs: [ValidationError] = []

        if cfg.schemaVersion < 1 || cfg.schemaVersion > supportedSchemaVersion {
            errs.append(.init(
                field: "schema_version",
                message: "Unsupported schema_version \(cfg.schemaVersion); supported: 1...\(supportedSchemaVersion)"))
        }

        if cfg.metadata.title.trimmingCharacters(in: .whitespaces).isEmpty {
            errs.append(.init(field: "metadata.title", message: "title must not be empty"))
        }

        if let y = cfg.metadata.year, y < 0 || y > 9999 {
            errs.append(.init(field: "metadata.year", message: "year must be in 0...9999"))
        }

        if cfg.outputs.directory.isEmpty {
            errs.append(.init(field: "outputs.directory", message: "directory must not be empty"))
        } else {
            // Traversal checks on outputs.directory (finding 1.5): reject leading '/',
            // and any path segment that is exactly '..'. Plain subdirs ("Exports",
            // "output/books") are fine; "../../outside" or "/absolute" are not.
            if cfg.outputs.directory.hasPrefix("/") {
                errs.append(.init(
                    field: "outputs.directory",
                    message: "directory must be a relative path (no leading '/')"))
            } else {
                let dirSegments = cfg.outputs.directory
                    .split(separator: "/", omittingEmptySubsequences: false)
                    .map(String.init)
                if dirSegments.contains("..") {
                    errs.append(.init(
                        field: "outputs.directory",
                        message: "directory must not contain '..' path traversal segments"))
                }
            }
        }

        if !cfg.outputs.filenameTemplate.contains("{title}") ||
           !cfg.outputs.filenameTemplate.contains("{version}") ||
           !cfg.outputs.filenameTemplate.contains("{ext}") {
            errs.append(.init(
                field: "outputs.filename_template",
                message: "filename_template must include {title}, {version}, and {ext}"))
        } else if cfg.outputs.filenameTemplate.contains("/") || cfg.outputs.filenameTemplate.contains("..") {
            // Traversal check on filenameTemplate (finding 1.5): a '/' or '..' in the
            // template expands to a path that escapes the outputs.directory on write.
            // The template is a filename, not a path — no separators are allowed.
            errs.append(.init(
                field: "outputs.filename_template",
                message: "filename_template must not contain '/' or '..' (path traversal)"))
        }

        if cfg.outputs.formatsEnabled.isEmpty {
            errs.append(.init(
                field: "outputs.formats_enabled",
                message: "at least one format must be enabled"))
        }

        return errs
    }

    /// Parse "X.Y" and return "X.(Y+1)". Returns "0.1" for any invalid input.
    public static func bumpedNextVersion(from current: String) -> String {
        let parts = current.split(separator: ".")
        guard parts.count == 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              major >= 0, minor >= 0
        else {
            return "0.1"
        }
        return "\(major).\(minor + 1)"
    }
}
