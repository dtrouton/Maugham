import Foundation
@testable import Maugham

/// **The note door's next body save fails with the new note's file still
/// empty** (#148 D1): just before the coordinated write, `folder` (where the
/// note was made) turns read-only, so the atomic write cannot make its
/// temporary file — the disk's own failure — and the door answers
/// `.notSaved`. With `cleanupCanRun`, the door's "Couldn’t save" notice
/// (posted synchronously, before the caller sees the refusal) makes the
/// folder writable again, so the caller's cleanup can take the note back;
/// without it the folder stays read-only and the cleanup fails too.
/// `end()` restores everything; call it in a `defer`.
@MainActor
final class RefusedNoteBodySave {
    private let folder: URL
    private var token: NSObjectProtocol?
    private(set) var refused = false

    init(in folder: URL, cleanupCanRun: Bool) {
        self.folder = folder
        DocumentStore.beforeCoordinatedWriteForTesting = { [folder] in
            DocumentStore.beforeCoordinatedWriteForTesting = nil
            try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        }
        token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil
        ) { [weak self, folder] note in
            guard let said = note.userInfo?[MaughamEvent.noticeMessageKey] as? String,
                  said.hasPrefix("Couldn’t save") else { return }
            MainActor.assumeIsolated { self?.refused = true }
            if cleanupCanRun {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            }
        }
    }

    func end() {
        DocumentStore.beforeCoordinatedWriteForTesting = nil
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
    }
}
