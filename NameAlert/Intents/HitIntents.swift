import AppIntents

struct GetRecentHitsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Recent Hits"
    static let description = IntentDescription("Get the latest times someone said one of your words.")
    static let openAppWhenRun = false

    private static let limitRange = 1...20

    static var parameterSummary: some ParameterSummary {
        Summary("Get the last \(\.$limit) mentions")
    }

    @Parameter(title: "Number of mentions", default: 5, inclusiveRange: (1, 20))
    var limit: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[HitEntity]> {
        let controller = await IntentEnvironment.controller()
        let count = min(max(limit, Self.limitRange.lowerBound), Self.limitRange.upperBound)
        let hits = await controller.history().prefix(count).map(HitEntity.init)
        return .result(value: hits)
    }
}
