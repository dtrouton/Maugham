import Foundation

/// Terminal action dispatched from the Rewind modal. The dispatcher (in
/// `ProjectWindow.swift` via the `RewindWindow` onDismiss callback)
/// switches over this exhaustively; adding a future action becomes a
/// compile error rather than a missed case.
internal enum RewindAction: Equatable {
    case cancel
    case snapshotHere(label: String)
    case restoreHere(opId: String)
}
