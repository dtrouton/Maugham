import Foundation

/// Shared `{title}-v{version}{label_suffix}.{ext}` interpolation for
/// PDFCompiler and EPUBCompiler.
///
/// Title sanitization splits into two passes:
/// 1. **Always** strips characters that produce broken or unsafe macOS
///    filenames: `/` (path separator), `\0` (null), and leading `.`
///    (creates a hidden file the writer can't see in Finder). These are
///    enforced regardless of `sanitize_spaces` because the result of
///    NOT enforcing them is an unusable Exports/ entry, not a stylistic
///    preference.
/// 2. **Optional** spaces → hyphens, governed by `config.outputs.sanitize_spaces`.
///    That's a cosmetic choice the writer owns.
enum OutputFilenameBuilder {

    /// The occupied-destination refusal both compilers raise when they are not
    /// allowed to replace what is at their output path (RULING-8, M7-PB-008 —
    /// the compile path owes the republish path's refusal: whatever those
    /// bytes are, they are not this job's to destroy). One spelling, shared,
    /// because two spellings of one refusal is how the compile path came to
    /// delete where the republish path refused.
    static func occupiedDestinationRefusal(
        destination: URL, projectURL: URL
    ) -> TectonicLogParser.Diagnostic {
        let prefix = projectURL.path + "/"
        let rel = destination.path.hasPrefix(prefix)
            ? String(destination.path.dropFirst(prefix.count)) : destination.path
        return TectonicLogParser.Diagnostic(
            level: .error, file: nil, line: nil,
            message: "A file already exists at \(rel); refusing to overwrite it.",
            contextLines: [
                "This compile renders to that path, but something is already there and this compile did not put it there.",
                "Move or delete that file yourself if it is expendable — or put {version} back in filename_template so each version renders its own name."
            ])
    }

    static func make(
        config: PublishConfig,
        format: PublishConfig.Format,
        label: String?,
        language: String?
    ) -> String {
        var title = sanitizeForFilesystem(config.metadata.title)
        if config.outputs.sanitizeSpaces {
            title = title.replacingOccurrences(of: " ", with: "-")
        }
        let labelSuffix = label.map { "-\(sanitizeForFilesystem($0))" } ?? ""
        let template = config.outputs.filenameTemplate
        // The imprint comes from the resolved config, not a parameter here —
        // "resolve once, at the door" (Task 2 sets `config.imprint`; this
        // builder never takes an imprint argument of its own).
        let imprint = config.imprint

        // F7 residue: when {language} (or, as of Task 4, {imprint}) expands
        // empty, a separator immediately preceding the token would otherwise
        // dangle (e.g. "T-v0.1-.pdf"). Strip EXACTLY ONE `-`/`_`/`.` right
        // before each token occurrence before the generic replacement runs. A
        // token with no preceding separator falls through to the plain empty
        // replacement below, unchanged from today. When the value IS present,
        // the separator is meaningful and stays. (M1: single-pass
        // per-occurrence strip — the old sequential replace-all cascaded on a
        // doubled-separator template like "{title}._{language}.{ext}",
        // removing both separators instead of one.)
        var workingTemplate = template
        if language == nil || language?.isEmpty == true {
            workingTemplate = stripOneSeparatorBefore(
                token: "{language}", in: workingTemplate)
        }
        if imprint == nil || imprint?.isEmpty == true {
            workingTemplate = stripOneSeparatorBefore(
                token: "{imprint}", in: workingTemplate)
        }

        var name = workingTemplate
            .replacingOccurrences(of: "{title}",        with: title)
            .replacingOccurrences(of: "{version}",      with: config.nextVersion)
            .replacingOccurrences(of: "{label_suffix}", with: labelSuffix)
            .replacingOccurrences(of: "{language}",     with: language ?? "")
            .replacingOccurrences(of: "{imprint}",      with: imprint ?? "")
            .replacingOccurrences(of: "{ext}",          with: format.rawValue)

        // Collision guards. Order matters: the imprint guard runs BEFORE the
        // language guard, so a template with neither token produces
        // "<title>-v<version>-<imprint>-<language>.<ext>" — imprint nearer
        // the version, language nearer the extension — because each guard
        // inserts immediately before the extension and the imprint guard
        // gets there first.
        if let imprint, !template.contains("{imprint}") {
            name = insertBeforeExtension(imprint, into: name, format: format)
        }
        if let language, !template.contains("{language}") {
            name = insertBeforeExtension(language, into: name, format: format)
        }
        return name
    }

    /// Insert `-<suffix>` immediately before the format's extension — the
    /// no-token collision guard shared by `{language}` and `{imprint}`.
    private static func insertBeforeExtension(
        _ suffix: String, into name: String, format: PublishConfig.Format
    ) -> String {
        let ext = ".\(format.rawValue)"
        if name.hasSuffix(ext) {
            return "\(name.dropLast(ext.count))-\(suffix)\(ext)"
        } else {
            return name + "-\(suffix)"
        }
    }

    /// Strip a single `-`/`_`/`.` immediately preceding each occurrence of
    /// `token`, leaving any earlier separators intact. Spec: drop exactly ONE
    /// dangling separator per token, never cascade across a doubled separator.
    private static func stripOneSeparatorBefore(
        token: String, in template: String
    ) -> String {
        let separators: Set<Character> = ["-", "_", "."]
        var result = ""
        var remainder = Substring(template)
        while let range = remainder.range(of: token) {
            var prefix = remainder[remainder.startIndex..<range.lowerBound]
            if let last = prefix.last, separators.contains(last) {
                prefix = prefix.dropLast()
            }
            result += prefix
            result += token
            remainder = remainder[range.upperBound...]
        }
        result += remainder
        return result
    }

    /// Always-on sanitization: strip path separators, null bytes, and any
    /// leading dots. Other control chars are also stripped (Unicode
    /// categories `C` — formatting/control).
    static func sanitizeForFilesystem(_ input: String) -> String {
        var s = input
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "\0", with: "")
        // Drop any leading dots so the file isn't hidden on macOS.
        while s.hasPrefix(".") { s.removeFirst() }
        // Strip control characters (anything in Unicode general category C).
        s = String(s.unicodeScalars.filter { !$0.properties.generalCategory.isControl })
        return s
    }
}

private extension Unicode.GeneralCategory {
    var isControl: Bool {
        switch self {
        case .control, .format, .privateUse, .surrogate, .unassigned: return true
        default: return false
        }
    }
}
