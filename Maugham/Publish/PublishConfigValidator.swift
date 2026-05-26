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
        }

        if !cfg.outputs.filenameTemplate.contains("{title}") ||
           !cfg.outputs.filenameTemplate.contains("{version}") ||
           !cfg.outputs.filenameTemplate.contains("{ext}") {
            errs.append(.init(
                field: "outputs.filename_template",
                message: "filename_template must include {title}, {version}, and {ext}"))
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
