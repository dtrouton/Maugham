// maugham-swap <absolute-pathA> <absolute-pathB>
//
// Atomically exchanges two directory entries (the installed app bundle and
// its verified `.inflight` copy) with ONE renamex_np(RENAME_SWAP) call. Run by
// the updater's detached helper after the app has quit, from the CURRENTLY
// INSTALLED bundle (`Contents/Helpers/`), never the incoming one. Both paths
// exist throughout: the call either swaps them or changes nothing.
//
// Exit codes (`UpdateInstaller` in Maugham/Updates/UpdateInstaller.swift
// reads 3; the helper records any other non-zero as a failed swap):
//   0   swapped
//   64  usage: not exactly two arguments, or a path that is not absolute
//   1   the call failed (the strerror text on stderr); nothing was swapped
//   3   the volume does not support swap renaming (ENOTSUP or EINVAL);
//       nothing was swapped, and nothing in between is attempted

import Darwin

func fail(_ message: String, status: Int32) -> Never {
    fputs(message + "\n", stderr)
    exit(status)
}

let arguments = CommandLine.arguments
guard arguments.count == 3,
      arguments[1].hasPrefix("/"),
      arguments[2].hasPrefix("/") else {
    fail("usage: maugham-swap <absolute-pathA> <absolute-pathB>", status: 64)
}

if renamex_np(arguments[1], arguments[2], UInt32(RENAME_SWAP)) != 0 {
    let code = errno
    let reason = String(cString: strerror(code))
    if code == ENOTSUP || code == EINVAL {
        fail("maugham-swap: this volume cannot swap entries atomically: " + reason, status: 3)
    }
    fail("maugham-swap: " + reason, status: 1)
}
exit(0)
