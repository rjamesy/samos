import Foundation

enum RouteProvider: Equatable {
    case ollama
    case openai
}

struct FallbackPolicy {
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func routeOrder(snapshot: SettingsSnapshot, openAIConfigured: Bool) -> [RouteProvider] {
        if snapshot.aiRouting.useOllama {
            return openAIConfigured ? [.ollama, .openai] : [.ollama]
        }
        return openAIConfigured ? [.openai] : []
    }

    func routeOrder(openAIConfigured: Bool) -> [RouteProvider] {
        routeOrder(snapshot: settingsStore.snapshot, openAIConfigured: openAIConfigured)
    }
}
