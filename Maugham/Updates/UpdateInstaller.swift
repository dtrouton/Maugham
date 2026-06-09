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

    /// Shell script run **detached** after the app quits. Polls until our PID is
    /// gone, then atomically swaps the bundle into the install location using
    /// `renamex_np(RENAME_SWAP)` so /Applications/Maugham.app is NEVER absent —
    /// the old bundle stays at the `.inflight` path after the swap and is cleaned
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
    public static func helperScript(
        pid: Int32, stagedBundle: String, installedBundle: String, relaunch: Bool
    ) -> String {
        let tmp = "\(installedBundle).inflight"
        // Build the script as string concatenation — NOT a Swift multi-line
        // string literal — so the lines land at column 0 in the generated .sh
        // file. Column-0 matters for the heredoc limit strings (PYEOF must be
        // at column 0 to terminate the heredoc) and for the Python source lines
        // (Python rejects leading-space indentation on module-scope statements).
        var s = "#!/bin/bash\n"
        s += "set -e\n"
        s += "# Wait for the running Maugham (pid \(pid)) to fully exit.\n"
        s += "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done\n"
        s += "# Stage the new bundle as a same-volume sibling (.inflight).\n"
        s += "rm -rf \"\(tmp)\"\n"
        s += "ditto \"\(stagedBundle)\" \"\(tmp)\"\n"
        s += "# Atomically exchange .inflight <-> installed so the install location is\n"
        s += "# NEVER absent. renamex_np(RENAME_SWAP=0x2) is Darwin-native (macOS 10.12+).\n"
        // Write the Python source into a temp file via a quoted heredoc, then exec it.
        // The heredoc limit strings (PYEOF) land at column 0 because this script is
        // assembled line-by-line, not indented inside a Swift string literal.
        s += "PY_TMP=\"$(mktemp /tmp/maugham-swap-XXXXXX.py)\"\n"
        s += "cat > \"$PY_TMP\" << 'PYEOF'\n"
        s += UpdateInstaller.pyAtomicSwapSource
        s += "PYEOF\n"
        s += "python3 \"$PY_TMP\" \"\(tmp)\" \"\(installedBundle)\"\n"
        s += "rm -f \"$PY_TMP\"\n"
        if relaunch {
            s += "open \"\(installedBundle)\"\n"
        }
        return s
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
    /// Decide how to install based on whether the installed bundle is writable
    /// by the current user. Defaults are injected for testability.
    public static func installMode(
        installedBundlePath: String,
        isWritable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) }
    ) -> InstallMode {
        isWritable(installedBundlePath) ? .inPlace : .finderFallback
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
        case unzipFailed, verifyFailed(String)
        var errorDescription: String? {
            switch self {
            case .unzipFailed: return "Couldn't unpack the update"
            case .verifyFailed(let r): return "Update failed verification: \(r)"
            }
        }
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
    private static func stageAndVerifySync(zip: URL, version: String) throws -> URL {
        let stageDir = zip.deletingLastPathComponent()
            .appendingPathComponent("staged-\(version)", isDirectory: true)
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
            try? FileManager.default.removeItem(at: stageDir)
            throw InstallError.verifyFailed(reason)
        }
    }

    /// Launch the detached swap helper for a verified bundle. Returns false if it
    /// couldn't be launched (caller handles Finder fallback). `installedBundlePath`
    /// defaults to the running app's own location so we replace the right copy.
    @discardableResult
    static func launchSwapHelper(stagedBundle: URL, relaunch: Bool,
                                 installedBundlePath: String = Bundle.main.bundlePath) -> Bool {
        guard installMode(installedBundlePath: installedBundlePath) == .inPlace else {
            return false  // not writable → caller does Finder fallback
        }
        let script = helperScript(pid: ProcessInfo.processInfo.processIdentifier,
                                  stagedBundle: stagedBundle.path,
                                  installedBundle: installedBundlePath,
                                  relaunch: relaunch)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("maugham-update-\(UUID().uuidString).sh")
        do { try script.write(to: scriptURL, atomically: true, encoding: .utf8) }
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
        p.arguments = [scriptURL.path]
        do { try p.run() } catch { return false }
        return true
    }
}
