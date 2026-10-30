import Foundation

/// The shared check behind `AnnotationsPaneSource` and `DiagnosticsPaneSource`:
/// every `<prefix>*.swift` in a folder is either one of the pane's files or
/// named as not the pane, the two lists do not overlap, and every listed file
/// exists. Returns the problems as sentences; empty means classified.
enum PaneSurfaceClassification {
    static func problems(
        prefix: String, dir: URL, surface: [String], notThePane: [String]
    ) throws -> [String] {
        var problems: [String] = []
        let onDisk = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".swift") })
        if onDisk.isEmpty { problems.append("control: no \(prefix)*.swift found in \(dir.path)") }
        let listed = surface + notThePane
        for name in Set(listed) where listed.filter({ $0 == name }).count > 1 {
            problems.append("\(name) is listed twice")
        }
        for name in listed where !FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(name).path) {
            problems.append("\(name) is listed but does not exist")
        }
        for name in onDisk.subtracting(listed).sorted() {
            problems.append("\(name) is neither the pane's nor named as not the pane")
        }
        return problems
    }
}
