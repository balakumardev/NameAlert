import NameAlertCore

extension ListeningController {
    /// A controller that shows the given state and runs nothing, for SwiftUI previews and App Store screenshots.
    ///
    /// It is built on `RuntimeDependencies.inert()`, so a control used in a preview cannot capture, recognize or send
    /// anything either. Its configuration counts as loaded: `bootstrap()` keeps it.
    public static func demo(
        configuration: AppConfiguration, state: ListeningState, recentHits: [Hit], liveTranscript: String, level: Double
    ) -> ListeningController {
        let controller = ListeningController(dependencies: .inert())
        controller.present(
            configuration: configuration, state: state, recentHits: recentHits, liveTranscript: liveTranscript,
            level: level)
        return controller
    }
}
