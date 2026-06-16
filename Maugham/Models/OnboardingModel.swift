import Foundation

/// Shared, app-level intent object the Help menu writes to and `WelcomeHost`
/// reads. Modeled as shared `@Observable` state (not a fire-and-forget
/// notification) so there is no listener-lifecycle race: when the singleton
/// Welcome window is (re)created, `WelcomeHost.onAppear` reads the current
/// intent and acts. This is why "Welcome to Maugham" and "Sample Projects ▸ …"
/// still work after the Welcome window has been closed.
@MainActor
@Observable
final class OnboardingModel {
    /// Set by the Help menu to request the welcome carousel be shown.
    var carouselRequested = false
    /// Set by the Help menu to request a sample project be built + opened.
    var sampleRequested: SampleProjectBuilder.Kind?
}
