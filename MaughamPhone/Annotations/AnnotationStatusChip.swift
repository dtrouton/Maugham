import MaughamCore

/// Pure status → chip vocabulary for resolved annotation rows (All mode). Phone-
/// local presentation: MaughamCore owns the *kind* icon (`AnnotationKind.systemImageName`,
/// a cross-surface contract) but there is no shared *status* chip, so this stays
/// here. Out of a view body so it is trivially testable and the vocabulary lives
/// in one place.
enum AnnotationStatusChip {
    /// Human label for a resolved status; nil for `.open` (open rows show no chip).
    static func label(_ status: AnnotationStatus) -> String? {
        switch status {
        case .open:     return nil
        case .accepted: return "Accepted"
        case .rejected: return "Rejected"
        case .archived: return "Archived"
        }
    }

    /// SF Symbol for a resolved status; nil for `.open`.
    static func symbol(_ status: AnnotationStatus) -> String? {
        switch status {
        case .open:     return nil
        case .accepted: return "checkmark.circle"
        case .rejected: return "xmark.circle"
        case .archived: return "archivebox"
        }
    }
}
