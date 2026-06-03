import Foundation

/// The Mac's stable device identifier for op/inbox per-device partitioning:
/// the host name, or "unknown-host". SINGLE SOURCE — was duplicated across four
/// sites (EditorHost, InboxStore, ProjectStore, ProjectWindow); consolidating
/// prevents the device id from silently diverging per subsystem (which would
/// split one Mac's writes across device slugs).
enum MacDeviceID {
    static var current: String {
        let name = ProcessInfo.processInfo.hostName
        return name.isEmpty ? "unknown-host" : name
    }
}
