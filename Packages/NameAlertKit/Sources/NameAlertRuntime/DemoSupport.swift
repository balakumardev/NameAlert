import NameAlertCore

extension ListeningController {
    /// A controller that shows the given state and runs nothing, for SwiftUI previews and App Store screenshots.
    ///
    /// It is built on `RuntimeDependencies.inert()`, so a control used in a preview cannot capture, recognize or send
    /// anything either. Its configuration counts as loaded: `bootstrap()` keeps it. `proAccess` shows Free or Pro.
    public static func demo(
        configuration: AppConfiguration, state: ListeningState, recentHits: [Hit], liveTranscript: String, level: Double,
        proAccess: ProAccess = .pro
    ) -> ListeningController {
        let controller = ListeningController(dependencies: .inert(), proAccess: proAccess)
        controller.present(
            configuration: configuration, state: state, recentHits: recentHits, liveTranscript: liveTranscript,
            level: level)
        return controller
    }
}
