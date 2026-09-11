import Foundation

/// A key fingerprint as the writer sees it: the four-character **code** a
/// device shows for itself.
///
/// **One spelling, because a code exists to be COMPARED.** The phone's Settings
/// row shows this device's code and the Mac's admission sheet shows the code of
/// the device asking to be let in; the writer's whole job at that moment is to
/// read one screen and check it against the other. Two implementations that
/// disagreed about how many characters, or about case, would fail that
/// comparison silently — the writer would see two codes for one device and
/// refuse an admission that was perfectly good. So it lives in MaughamCore
/// (tripwire 19) and every surface asks here.
///
/// Uppercased because a code is compared across screens and hex reads better in
/// capitals; four characters because that is what P2a shipped and what the
/// spec's copy says.
public enum DeviceCode {

    /// The code for a fingerprint. Shorter than four characters answers with
    /// the whole of what it was given — a code is whatever there is — and an
    /// empty fingerprint answers empty rather than inventing a name.
    nonisolated public static func short(_ fingerprint: String) -> String {
        fingerprint.prefix(4).uppercased()
    }
}
