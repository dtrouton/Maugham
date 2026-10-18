// Maugham/Updates/UpdateInstaller.swift
import Foundation
import Security
import Darwin

/// The result of inspecting a staged bundle's code signature.
public struct VerificationVerdict: Equatable {
    public let codesignValid: Bool
    public let notarized: Bool
    public let teamID: String?
    public init(codesignValid: Bool, notarized: Bool, teamID: String?) {
        self.codesignValid = codesignValid
        self.notarized = notarized
        self.teamID = teamID
    }
}

/// What to do with a staged bundle after verification.
public enum InstallDecision: Equatable {
    case accept
    case reject(reason: String)
}

public enum InstallMode: Equatable {
    case inPlace        // swap /Applications/Maugham.app via the helper
    case finderFallback // reveal the .dmg in Finder (current behavior)
}

/// Persisted across a quit when the quit-time in-place install couldn't be
/// launched (`launchSwapHelper` returned false — the install location went
/// unwritable, python3 vanished, the running app has no team to re-check the
/// update against, or the script couldn't be written, between staging and quit). The app is already tearing down at that point, so
/// unlike `installNow`'s live Finder-fallback (`MaughamApp.swift`'s
/// `performInstall`), the reveal is deferred to next launch rather than
/// attempted mid-teardown.
///
/// Not `BuildVariant`-scoped by name: dev and stable run under distinct
/// bundle identifiers, so `UserDefaults.standard` is already a separate
/// preferences domain per variant (see `BuildVariant.swift`; mirrors
/// `UserPreferences`'s unscoped `"maugham.*"` key convention).
public enum PendingUpdateReveal {
    static let defaultsKey = "maugham.revealPendingUpdateOnNextLaunch"

    /// Record a staged bundle to reveal in Finder on next launch.
    public static func markPending(bundleURL: URL, defaults: UserDefaults = .standard) {
        defaults.set(bundleURL.path, forKey: defaultsKey)
    }

    /// Consume (clear) any pending reveal, returning the bundle URL to show
    /// if one was recorded. Clears eagerly so a crash-loop can't re-show the
    /// same stale reveal forever.
    @discardableResult
    public static func consumePending(defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: defaultsKey) else { return nil }
        defaults.removeObject(forKey: defaultsKey)
        return URL(fileURLWithPath: path)
    }
}

public enum UpdateInstaller {
    /// Pure decision: a staged bundle is trustworthy iff its signature is valid,
    /// it is notarized, and its Team ID matches the running app's Team ID.
    /// Checks are ordered most-fundamental-first so the reason is the root cause.
    public static func decide(verdict: VerificationVerdict, expectedTeamID: String) -> InstallDecision {
        guard verdict.codesignValid else { return .reject(reason: "Invalid code signature") }
        guard verdict.notarized else { return .reject(reason: "Not notarized") }
        guard verdict.teamID == expectedTeamID else { return .reject(reason: "Team ID mismatch") }
        return .accept
    }

    /// The absolute paths of the system tools the helper runs. They are the
    /// only values interpolated into the script, and they are constants: a
    /// test passes stubs (`codesign`/`spctl` that exit 0 or 1), production
    /// passes `.system`. Each must match `^[A-Za-z0-9/._-]+$`, so nothing in
    /// one can be live inside bash double quotes.
    struct HelperTools: Equatable {
        let codesign: String
        let spctl: String
        let ditto: String

        static let system = HelperTools(codesign: "/usr/bin/codesign",
                                        spctl: "/usr/sbin/spctl",
                                        ditto: "/usr/bin/ditto")

        /// Absolute, and nothing but letters, digits, `/`, `.`, `_` and `-`.
        static func isSafePath(_ path: String) -> Bool {
            guard path.hasPrefix("/") else { return false }
            return path.unicodeScalars.allSatisfy { c in
                ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c)
                    || c == "/" || c == "." || c == "_" || c == "-"
            }
        }
    }

    /// The step a failed install names in `Updates/install-status`
    /// (`failed <version> <step>`). A refused install-time check is the other
    /// line, `refused <version>`. Next launch reads the file (#67 Task 5).
    enum HelperFailureStep: String, CaseIterable {
        /// `python3` was not on PATH (the swap needs it).
        case python3
        /// Copying the staged bundle to `<installed>.inflight` failed.
        case ditto
        /// The atomic swap (the python step, or writing its source) failed.
        case swap
    }

    /// The status file's name inside the Updates folder.
    static let installStatusFileName = "install-status"

    /// Shell script run **detached** after the app quits. Fixed text: every
    /// path, the pid, the team and the version arrive as ARGUMENTS
    /// (`helperArguments`), so a bundle path containing `"`, `$(…)` or a
    /// backtick is data, never code (#67 F13). Only `tools`' constant paths are
    /// interpolated.
    ///
    /// It polls until our PID is gone, copies the staged bundle to the
    /// `.inflight` sibling, **re-checks that copy** — `codesign --verify --deep
    /// --strict` against a requirement naming the running app's team, then
    /// `spctl -a -t exec` — and only then atomically swaps it into the install
    /// location using `renamex_np(RENAME_SWAP)` so /Applications/Maugham.app is
    /// NEVER absent (#67 F12). The re-check runs on the exact bytes the swap
    /// moves, after the app has exited, so the download-time verdict is never
    /// trusted across the hours or days the staged copy waits. A refused copy is
    /// removed and `refused <version>` written to `Updates/install-status`; any
    /// other failure after the guard writes `failed <version> <step>`. Success
    /// writes nothing.
    ///
    /// The old bundle stays at the `.inflight` path after the swap and is cleaned
    /// up last. A crash between the ditto and the rename leaves `.inflight` behind
    /// (the installed app is intact); a crash after the rename leaves `.inflight`
    /// as stale garbage (the new app is already in place). In neither case is the
    /// install location empty.
    ///
    /// `RENAME_SWAP` is a Darwin-specific flag to `renamex_np(2)` that atomically
    /// exchanges two filesystem entries. Both paths must be on the **same volume**
    /// (guaranteed: `.inflight` is a same-directory sibling of the installed
    /// bundle). We call it via Python's ctypes to avoid a compiled helper binary.
    ///
    /// Falls back to a backup-rename approach (`installed → .bak`, `inflight →
    /// installed`) if `renamex_np` is unavailable (should never happen on macOS
    /// 10.12+), which still guarantees at most one intact copy at the install
    /// location while `.bak` holds the old version.
    static func helperScript(tools: HelperTools = .system) -> String {
        precondition(HelperTools.isSafePath(tools.codesign)
                     && HelperTools.isSafePath(tools.spctl)
                     && HelperTools.isSafePath(tools.ditto),
                     "helper tool paths are constants and must be plain absolute paths")
        // Built line by line — NOT a Swift multi-line literal — so every line
        // lands at column 0 (the PYEOF limit string and the Python source need it).
        var lines: [String] = [
            "#!/bin/bash",
            "set -e",
            // Arguments: see UpdateInstaller.helperArguments. Nothing below
            // ever lets one be parsed as code: every use is double-quoted.
            #"[ "$#" -eq 7 ] || exit 2"#,
            #"PID="$1""#,
            #"STAGED="$2""#,
            #"INSTALLED="$3""#,
            #"TEAM="$4""#,
            #"RELAUNCH="$5""#,
            #"VERSION="$6""#,
            #"UPDATES="$7""#,
            #"INFLIGHT="$INSTALLED.inflight""#,
            #"STATUS="$UPDATES/\#(installStatusFileName)""#,
            // Re-validate what Swift validated. Explicit character lists, not
            // ranges, so no locale's collation can widen a match.
            #"case "$PID" in ''|*[!0123456789]*) exit 2;; esac"#,
            #"case "$TEAM" in *[!ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789]*) exit 2;; esac"#,
            #"[ "${#TEAM}" -eq 10 ] || exit 2"#,
            #"case "$RELAUNCH" in 0|1) ;; *) exit 2;; esac"#,
            #"case "$VERSION" in ''|*[!0123456789.]*) exit 2;; esac"#,
            // Absolute paths. (Tested by stripping the leading slash rather
            // than a case pattern: a slash-star in this file would open a
            // block comment for TripwireGrepTests' source scan.)
            #"for p in "$STAGED" "$INSTALLED" "$UPDATES"; do [ "${p#/}" != "$p" ] || exit 2; done"#,
            #"case "$INSTALLED" in *.app) ;; *) exit 2;; esac"#,
            // One line, overwritten (never appended), via a temp file and mv
            // so a reader never sees half of it. Its own failure changes nothing.
            #"record() { printf '%s\n' "$1" > "$STATUS.tmp" && mv -f "$STATUS.tmp" "$STATUS"; }"#,
            #"PY_TMP="""#,
            #"trap 'rm -f "$PY_TMP"' EXIT"#,
            // python3 guard (audit N2): the swap runs via python3 (ctypes →
            // renamex_np), which ships with the Command Line Tools a clean Mac
            // may lack. Probe it before the quit-wait and before any
            // destructive step, so the running app is untouched. (Swift's
            // launchSwapHelper pre-checks too; this is the backstop.) The app
            // is quitting regardless, so the failure is recorded.
            "if ! command -v python3 >/dev/null 2>&1; then",
            #"  echo "maugham-update: python3 not found; aborting in-place swap (app left untouched)" >&2"#,
            #"  record "failed $VERSION \#(HelperFailureStep.python3.rawValue)" || true"#,
            "  exit 1",
            "fi",
            "# Wait for the running Maugham to fully exit.",
            #"while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done"#,
            "# Copy the new bundle to a same-volume sibling (.inflight).",
            #"if ! { rm -rf "$INFLIGHT" && "\#(tools.ditto)" "$STAGED" "$INFLIGHT"; }; then"#,
            #"  rm -rf "$INFLIGHT" || true"#,
            #"  record "failed $VERSION \#(HelperFailureStep.ditto.rawValue)" || true"#,
            "  exit 1",
            "fi",
            "# Re-check the exact bytes about to be swapped in: signed by our team",
            "# (one codesign call checks validity AND the team), and notarized.",
            #"if ! "\#(tools.codesign)" --verify --deep --strict --test-requirement="=anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\"" "$INFLIGHT" \"#,
            #"  || ! "\#(tools.spctl)" -a -t exec "$INFLIGHT"; then"#,
            #"  rm -rf "$INFLIGHT" || true"#,
            #"  record "refused $VERSION" || true"#,
            "  exit 1",
            "fi",
            "# Atomically exchange .inflight <-> installed so the install location is",
            "# NEVER absent. renamex_np(RENAME_SWAP=0x2) is Darwin-native (macOS 10.12+).",
            "# A failed swap leaves .inflight: it may hold the only copy of the new app.",
            #"if ! PY_TMP="$(mktemp /tmp/maugham-swap-XXXXXX.py)"; then"#,
            #"  record "failed $VERSION \#(HelperFailureStep.swap.rawValue)" || true"#,
            "  exit 1",
            "fi",
            #"if ! cat > "$PY_TMP" << 'PYEOF'"#,
        ]
        var s = lines.joined(separator: "\n") + "\n"
        s += UpdateInstaller.pyAtomicSwapSource
        lines = [
            "PYEOF",
            "then",
            #"  record "failed $VERSION \#(HelperFailureStep.swap.rawValue)" || true"#,
            "  exit 1",
            "fi",
            #"if ! python3 "$PY_TMP" "$INFLIGHT" "$INSTALLED"; then"#,
            #"  record "failed $VERSION \#(HelperFailureStep.swap.rawValue)" || true"#,
            "  exit 1",
            "fi",
            #"if [ "$RELAUNCH" = 1 ]; then"#,
            #"  open "$INSTALLED""#,
            "fi",
        ]
        s += lines.joined(separator: "\n") + "\n"
        return s
    }

    /// The helper's argv, in the order `helperScript` reads it:
    /// `[script, pid, staged, installed, team, relaunch (1/0), version, updatesDir]`.
    static func helperArguments(scriptPath: String, pid: Int32, stagedBundle: String,
                                installedBundle: String, expectedTeamID: String,
                                relaunch: Bool, version: String, updatesDirectory: String) -> [String] {
        [scriptPath, String(pid), stagedBundle, installedBundle, expectedTeamID,
         relaunch ? "1" : "0", version, updatesDirectory]
    }

    /// A team ID as Apple issues them: ten upper-case letters or digits. The
    /// helper interpolates it into a code requirement, so nothing else passes.
    static func isWellFormedTeamID(_ team: String) -> Bool {
        team.count == 10 && team.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        }
    }

    /// `X.Y.Z`, digits and dots only — the status line the helper writes
    /// carries it, and the helper refuses anything else.
    static func isWellFormedVersion(_ version: String) -> Bool {
        SemanticVersion(version)?.string == version
    }

    /// Python source for the atomic bundle swap via `renamex_np(RENAME_SWAP)`.
    ///
    /// Kept as a top-level constant (not embedded inline in `helperScript`) so the
    /// lines are verbatim — no leading-space indentation from Swift multi-line
    /// string normalisation that would cause Python `IndentationError`s.
    ///
    /// The script receives `src` (`.inflight` staged bundle) and `dst` (installed
    /// bundle path) as `argv[1]`/`argv[2]`. After a successful swap the `dst` holds
    /// the new bundle and `src` is cleaned up; on `renamex_np` failure a
    /// backup-rename fallback ensures the install location is never empty.
    static let pyAtomicSwapSource: String = [
        "import sys, ctypes, ctypes.util, shutil, os",
        "src_path = sys.argv[1]",
        "dst_path = sys.argv[2]",
        "libc = ctypes.CDLL(ctypes.util.find_library('c'), use_errno=True)",
        "RENAME_SWAP = 0x00000002",
        "rc = libc.renamex_np(src_path.encode(), dst_path.encode(), RENAME_SWAP)",
        "if rc != 0:",
        "    bak = dst_path + '.bak'",
        "    shutil.rmtree(bak, ignore_errors=True)",
        "    os.rename(dst_path, bak)",
        "    os.rename(src_path, dst_path)",
        "    shutil.rmtree(bak, ignore_errors=True)",
        "    sys.exit(0)",
        "shutil.rmtree(src_path, ignore_errors=True)",
    ].joined(separator: "\n") + "\n"
}

extension UpdateInstaller {
    /// Errors from the atomic bundle swap.
    public enum SwapError: LocalizedError, Equatable {
        /// The two paths are on different volumes; `renamex_np` requires same-volume.
        case crossVolume
        /// The `renamex_np` syscall returned a non-zero status.
        case renamexFailed(Int32)
        /// The staged source path does not exist.
        case sourceNotFound
        public var errorDescription: String? {
            switch self {
            case .crossVolume: return "Bundle swap failed: paths are on different volumes"
            case .renamexFailed(let code): return "Bundle swap failed: renamex_np returned \(code)"
            case .sourceNotFound: return "Bundle swap failed: staged bundle not found"
            }
        }
    }

    /// Atomically exchange `stagedURL` ↔ `installedURL` using `renamex_np(RENAME_SWAP)`.
    ///
    /// - Both paths must be on the **same volume** (an `.inflight` sibling of the
    ///   install location satisfies this by construction).
    /// - After a successful swap, `installedURL` contains the new bundle and
    ///   `stagedURL` contains the old bundle (which the caller should remove).
    /// - The install location is **never absent** during this operation —
    ///   `RENAME_SWAP` exchanges the two directory entries atomically.
    /// - On failure, neither path is modified.
    ///
    /// This function is intentionally small and synchronous so it can be unit-tested
    /// against real temp-dir paths. The detached bash helper calls it indirectly via
    /// the equivalent Python ctypes call; this Swift version is used in tests and
    /// is available for any future Swift-side staging path.
    public static func atomicSwap(staged stagedURL: URL, installed installedURL: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stagedURL.path) else {
            throw SwapError.sourceNotFound
        }
        // Guard same-volume to guarantee renamex_np succeeds.
        // Use the parent directories' device IDs — they always exist and are
        // a stable proxy for the volume of their children.
        let stagedParent   = stagedURL.deletingLastPathComponent().path
        let installedParent = installedURL.deletingLastPathComponent().path
        let stagedAttrs   = try fm.attributesOfItem(atPath: stagedParent)
        let installedAttrs = try fm.attributesOfItem(atPath: installedParent)
        guard let devStaged    = stagedAttrs[.systemNumber] as? Int,
              let devInstalled  = installedAttrs[.systemNumber] as? Int,
              devStaged == devInstalled else {
            throw SwapError.crossVolume
        }
        // RENAME_SWAP (0x2): atomically exchange the two filesystem entries.
        // Both entries continue to exist throughout — no window where either is absent.
        let RENAME_SWAP: UInt32 = 0x00000002
        let rc = renamex_np(stagedURL.path, installedURL.path, RENAME_SWAP)
        guard rc == 0 else { throw SwapError.renamexFailed(rc) }
        // After swap, stagedURL holds the OLD bundle. Caller removes it.
    }
}

extension UpdateInstaller {
    /// Whether `python3` is resolvable on PATH (it backs the atomic swap via
    /// ctypes → `renamex_np`). Ships with the Command Line Tools, which a clean
    /// macOS may lack — see audit N2. Used as a pre-quit gate in `launchSwapHelper`.
    static func python3Available() -> Bool {
        let p = Process()
        // `command -v` is a bash builtin (mirrors the helper script's own guard).
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "command -v python3"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Decide how to install based on whether the installed bundle AND the
    /// folder holding it are writable by the current user: the helper creates
    /// `<installed>.inflight` beside the bundle and swaps the two entries, both
    /// of which need the folder (#67 New-4). Defaults are injected for testability.
    public static func installMode(
        installedBundlePath: String,
        isWritable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) }
    ) -> InstallMode {
        let parent = (installedBundlePath as NSString).deletingLastPathComponent
        return isWritable(installedBundlePath) && isWritable(parent) ? .inPlace : .finderFallback
    }
}

extension UpdateInstaller {
    /// The Team ID embedded in the *running* app's code signature, or nil if
    /// unsigned/ad-hoc (e.g. the test host). Self-anchoring: the staged update
    /// must be signed by the same team that signed us.
    public static func runningAppTeamID() -> String? {
        var codeRef: SecCode?
        guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let code = codeRef else { return nil }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess,
              let staticCode = staticRef else { return nil }
        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &infoRef) == errSecSuccess,
              let info = infoRef as NSDictionary? else { return nil }
        return info[kSecCodeInfoTeamIdentifier] as? String
    }
}

extension UpdateInstaller {
    enum InstallError: LocalizedError {
        case unzipFailed, verifyFailed(String), archiveTooLarge(String), archiveUnreadable
        var errorDescription: String? {
            switch self {
            case .unzipFailed: return "Couldn't unpack the update"
            case .verifyFailed(let r): return "Update failed verification: \(r)"
            case .archiveTooLarge(let r): return r
            case .archiveUnreadable: return "The downloaded update couldn't be read, so it wasn't installed."
            }
        }
    }

    // MARK: Size gate (#67 F16)

    /// Reads `zipinfo -t`'s totals line, e.g.
    /// `82 files, 92981635 bytes uncompressed, 30647535 bytes compressed:  67.0%`
    /// (singular `1 file`). Anything else is nil.
    static func parseZipinfoTotals(_ output: String) -> (files: Int, uncompressedBytes: Int64)? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ",")
            guard parts.count >= 2 else { continue }
            let head = parts[0].split(separator: " ")
            let second = parts[1].split(separator: " ")
            guard head.count == 2, head[1] == "file" || head[1] == "files",
                  let files = Int(head[0]),
                  second.count == 3, second[1] == "bytes", second[2] == "uncompressed",
                  let bytes = Int64(second[0]), files >= 0, bytes >= 0 else { continue }
            return (files, bytes)
        }
        return nil
    }

    /// What the zip's central directory declares, or nil if it can't be read.
    static func archiveTotals(zip: URL) -> (files: Int, uncompressedBytes: Int64)? {
        let (code, out) = run("/usr/bin/zipinfo", ["-t", zip.path])
        guard code == 0 else { return nil }
        return parseZipinfoTotals(out)
    }

    /// Pure: whether an archive declaring these totals may be unpacked on a
    /// volume with this much room. The reason is plain English; it reaches the
    /// update sheet on a manual check.
    static func extractionDecision(files: Int, uncompressedBytes: Int64, availableBytes: Int64?,
                                   limits: UpdateLimits = .standard) -> InstallDecision {
        if uncompressedBytes > limits.maxUncompressedBytes || files > limits.maxFiles {
            return .reject(reason: "The update is larger than expected, so it wasn't installed.")
        }
        guard let available = availableBytes else {
            return .reject(reason: "The free disk space couldn't be read, so the update wasn't installed.")
        }
        // Twice the unpacked size: the helper later copies it again beside the installed app.
        if available < uncompressedBytes * 2 + limits.freeSpaceMarginBytes {
            return .reject(reason: "There isn't enough free disk space to install the update.")
        }
        return .accept
    }

    static func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Run a tool synchronously, return (exitCode, combined stdout+stderr).
    private static func run(_ launchPath: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Inspect a staged bundle's signature via codesign + spctl.
    static func verify(bundlePath: String) -> VerificationVerdict {
        let (csCode, _) = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundlePath])
        let (_, dvOut) = run("/usr/bin/codesign", ["-dv", "--verbose=4", bundlePath])
        let teamID = dvOut.split(separator: "\n")
            .first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
            .flatMap { $0 == "not set" ? nil : $0 }
        // spctl assess: exit 0 == Gatekeeper would allow exec (our proxy for
        // "notarized + team-signed"). Caveat: if Gatekeeper is globally disabled
        // (spctl --master-disable) this returns 0 for unsigned apps too — the
        // codesign + Team-ID guards in decide() still protect against a tampered
        // or wrong-team bundle. spctl contacts Apple's OCSP servers; a network
        // timeout yields non-zero, which we conservatively treat as not-notarized.
        let (spctlCode, _) = run("/usr/sbin/spctl", ["-a", "-t", "exec", "-vv", bundlePath])
        return VerificationVerdict(codesignValid: csCode == 0,
                                   notarized: spctlCode == 0,
                                   teamID: teamID)
    }

    /// Unzip `zip` into a staging dir and return the contained Maugham.app URL,
    /// verifying it against the running app's Team ID. Throws on any failure.
    /// Runs off the calling actor — the codesign/spctl/ditto Process calls are
    /// synchronous and spctl can block for seconds on Apple's OCSP servers, so
    /// this must never run on the main actor.
    static func stageAndVerify(zip: URL, version: String) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try stageAndVerifySync(zip: zip, version: version)
        }.value
    }

    /// Synchronous worker. MUST be called off the main actor (see stageAndVerify).
    ///
    /// Every refusal (`InstallError`) goes through `discardRefusedArchive`, which
    /// removes the staged folder AND the downloaded zip: the checker reuses a
    /// zip already at `Maugham-<ver>.zip`, so a bad one left there would be
    /// re-staged and re-refused on every later check, silently on a background
    /// poll, and that version could never install. A new kind of refusal joins
    /// as an `InstallError` case and gets the same cleanup.
    static func stageAndVerifySync(zip: URL, version: String,
                                           availableBytes: (URL) -> Int64? = UpdateInstaller.availableBytes(at:)) throws -> URL {
        let stageDir = zip.deletingLastPathComponent()
            .appendingPathComponent("staged-\(version)", isDirectory: true)
        do {
            return try stageAndVerifyUnchecked(zip: zip, stageDir: stageDir, availableBytes: availableBytes)
        } catch let refusal as InstallError {
            discardRefusedArchive(zip: zip, stageDir: stageDir)
            throw refusal
        }
    }

    private static func stageAndVerifyUnchecked(zip: URL, stageDir: URL,
                                                availableBytes: (URL) -> Int64?) throws -> URL {
        guard let totals = archiveTotals(zip: zip) else {
            throw InstallError.archiveUnreadable
        }
        guard let available = availableBytes(zip.deletingLastPathComponent()) else {
            throw InstallError.archiveUnreadable
        }
        if case .reject(let reason) = extractionDecision(
            files: totals.files, uncompressedBytes: totals.uncompressedBytes,
            availableBytes: available) {
            throw InstallError.archiveTooLarge(reason)
        }
        try? FileManager.default.removeItem(at: stageDir)
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        let (code, _) = run("/usr/bin/ditto", ["-x", "-k", zip.path, stageDir.path])
        guard code == 0 else { throw InstallError.unzipFailed }
        let bundle = stageDir.appendingPathComponent("Maugham.app")
        guard FileManager.default.fileExists(atPath: bundle.path) else { throw InstallError.unzipFailed }
        // Strip quarantine so the swapped-in copy launches clean.
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", bundle.path])
        let verdict = verify(bundlePath: bundle.path)
        let expected = runningAppTeamID() ?? ""
        switch decide(verdict: verdict, expectedTeamID: expected) {
        case .accept:
            return bundle
        case .reject(let reason):
            throw InstallError.verifyFailed(reason)
        }
    }

    /// The one cleanup for a refused archive: the staged folder and the zip it
    /// came from, so the next check downloads afresh.
    static func discardRefusedArchive(zip: URL, stageDir: URL) {
        try? FileManager.default.removeItem(at: stageDir)
        try? FileManager.default.removeItem(at: zip)
    }

    /// Launch the detached swap helper for a verified bundle. Returns false if it
    /// couldn't be launched (caller handles Finder fallback). `installedBundlePath`
    /// defaults to the running app's own location so we replace the right copy.
    /// `expectedTeamID` is the team the helper re-checks the copy against at
    /// install time; with none (an ad-hoc or unsigned build) or a malformed one
    /// there is nothing to check against, so nothing is swapped. `version` and
    /// `updatesDirectory` tell the helper where to write `install-status`.
    @discardableResult
    static func launchSwapHelper(stagedBundle: URL, version: String, updatesDirectory: URL,
                                 relaunch: Bool,
                                 installedBundlePath: String = Bundle.main.bundlePath,
                                 expectedTeamID: String? = UpdateInstaller.runningAppTeamID(),
                                 python3Available: () -> Bool = UpdateInstaller.python3Available) -> Bool {
        guard installMode(installedBundlePath: installedBundlePath) == .inPlace else {
            return false  // not writable → caller does Finder fallback
        }
        guard let team = expectedTeamID, isWellFormedTeamID(team) else { return false }
        guard isWellFormedVersion(version) else { return false }
        // The detached swap depends on python3 (ctypes → renamex_np). If it's
        // missing (CLT-less Mac), don't quit into a doomed helper — return false
        // now, while the app is still alive, so the caller takes the Finder-reveal
        // fallback (audit N2). The helper script also guards as a backstop.
        guard python3Available() else { return false }
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("maugham-update-\(UUID().uuidString).sh")
        do { try helperScript().write(to: scriptURL, atomically: true, encoding: .utf8) }
        catch { return false }
        let p = Process()
        // Launch detached: the child reparents to launchd when we terminate and
        // keeps running (no controlling TTY → no SIGHUP). The script polls our
        // pid and only swaps after we've fully exited.
        // NOTE: on a normal Finder/Dock launch the orphaned child reparents to
        // launchd and survives our exit. When launched from Xcode/lldb, the
        // debugger kills the process group on app exit — so the in-place swap
        // won't apply in a debug session. Production launch only.
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = helperArguments(scriptPath: scriptURL.path,
                                      pid: ProcessInfo.processInfo.processIdentifier,
                                      stagedBundle: stagedBundle.path,
                                      installedBundle: installedBundlePath,
                                      expectedTeamID: team,
                                      relaunch: relaunch,
                                      version: version,
                                      updatesDirectory: updatesDirectory.path)
        do { try p.run() } catch { return false }
        return true
    }
}
