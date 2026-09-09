import Foundation
import MaughamCore

/// **Which set-aside records this device has already told the writer about**
/// (signed op log P2a, D2).
///
/// The sentence a pane draws about set-aside lines used to sum EVERY `.lines`
/// record forever: one foreign line found once became a standing accusation
/// that could only be put down by deleting the forensics it was about. Denver's
/// ruling is that the sentence is acknowledged per DEVICE per RECORD — the
/// writer says "I've seen this", the archive stays exactly where it is, and the
/// sentence comes back, counting only what is new, the next time something
/// writes a line Maugham did not.
///
/// **Per device on purpose.** The names are held in
/// `UIState.acknowledgedSetAsideRecords`, which is this machine's derived state
/// under `.maugham/` — acknowledging here says nothing about the phone, and
/// each device tells its own writer once.
///
/// **One predicate, two panes.** History asks it of a document's records, the
/// Inbox of the manifest stream's, and both hand the RESULT to
/// `OpLogQuarantine.setAsideLineCount`, which is unchanged and still counts
/// LINES rather than records. Two copies of the filter would be two answers to
/// one question — the same reasoning that put `setAsideLineCount` in
/// MaughamCore rather than on a pane.
///
/// **The archives are never touched.** Acknowledging is a UI-state write and
/// nothing else; the History pane's disclosure goes on listing every record
/// whether it has been acknowledged or not, because what the writer put down is
/// the sentence, not the evidence.
enum SetAsideAcknowledgement {

    /// The name a record is acknowledged under: its archive file's own name
    /// under `.maugham/conflicts/quarantined-ops/`.
    ///
    /// Not `originalName`, which several records share — one op-log file can be
    /// found carrying foreign lines more than once, and each finding is its own
    /// content-deduped archive — and not the timestamp, which is not what the
    /// disclosure shows the writer. The name is what they can see, so it is
    /// what they acknowledge.
    ///
    /// Resolving it reads the quarantine directory
    /// (`OpLogQuarantine.quarantinedFileURL`), so a pane calls this on its
    /// refresh and holds the answer — never per row and never from `body`
    /// (tripwire 4).
    static func name(for record: QuarantineRecord, in projectURL: URL) -> String {
        OpLogQuarantine.quarantinedFileURL(for: record, in: projectURL)
            .lastPathComponent
    }

    /// The records this device has not yet been told the writer has seen.
    ///
    /// A name in `acknowledged` that no record on disk carries is harmless and
    /// is deliberately never swept: the archive it named may live on another
    /// device, or may have been read and deleted by hand, and forgetting an
    /// acknowledgement would resurrect a sentence the writer already put down.
    static func unacknowledged(
        records: [QuarantineRecord],
        acknowledged: Set<String>,
        in projectURL: URL
    ) -> [QuarantineRecord] {
        guard !acknowledged.isEmpty else { return records }
        return records.filter { !acknowledged.contains(name(for: $0, in: projectURL)) }
    }
}
