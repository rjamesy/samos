import Foundation

struct RoutePlanner {
    private let fallbackPolicy: FallbackPolicy

    init(fallbackPolicy: FallbackPolicy) {
        self.fallbackPolicy = fallbackPolicy
    }

    func plannedProviders(snapshot: SettingsSnapshot) -> [RouteProvider] {
        fallbackPolicy.routeOrder(
            snapshot: snapshot,
            openAIConfigured: OpenAISettings.apiKeyStatus == .ready
        )
    }

    func plannedProviders() -> [RouteProvider] {
        plannedProviders(snapshot: UserDefaultsSettingsStore().snapshot)
    }
}
