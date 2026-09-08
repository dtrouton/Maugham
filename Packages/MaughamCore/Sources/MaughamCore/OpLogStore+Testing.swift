import Foundation

/// The single-identity `OpLogStore`, kept for the suites that predate the
/// actors.
///
/// P1's store held one `DeviceIdentity` and the ~40 suites written against it
/// say `OpLogStore(projectURL:identity:state:)` and mean *this is the device*.
/// That sentence is still true — it is the AUTHOR — so the convenience init
/// wraps it as the author beside three software keys for the other actors,
/// distinct from it and from each other. A test that appends under the author's
/// id therefore chains, seals and verifies exactly as it did before P1b, while a
/// test that wants to say something about the assistant or the translator builds
/// a real `LocalIdentities` and says it.
///
/// `internal`, so it is reachable only through `@testable import MaughamCore`;
/// production says `identities:` and means all four.
extension OpLogStore {
    convenience init(
        projectURL: URL,
        presenter: NSFilePresenter? = nil,
        identity: DeviceIdentity,
        state: OpLogDeviceState = .shared
    ) {
        self.init(
            projectURL: projectURL, presenter: presenter,
            identities: .forTesting(author: identity), state: state)
    }
}
