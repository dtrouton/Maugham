import Foundation

/// The book's language, read from the publish config: the one place that names the file and the
/// key, so the Mac's card and the phone's card agree on the tongue a table's dates read in.
///
/// Reading the bytes stays with each caller (the Mac reads plainly; the phone reads coordinated
/// after `ensureDownloaded`); this only says where, and what the bytes mean.
public enum BookLanguage {
    /// The config's path, spelled once. `PublishConfigStore.fileURL(in:)` is this.
    public static func configURL(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(".maugham/publish/config.json")
    }

    /// `metadata.language` of a config's bytes as a normalised tag, or nil when the bytes do not
    /// parse, there is no `metadata.language`, or it is blank. Every other key is ignored.
    public static func tag(fromConfigData data: Data) -> String? {
        struct Config: Decodable {
            struct Metadata: Decodable { var language: String? }
            var metadata: Metadata?
        }
        guard let config = try? JSONDecoder().decode(Config.self, from: data),
              let language = config.metadata?.language else { return nil }
        return TableLocale.languageTag(fromStored: language)
    }
}
