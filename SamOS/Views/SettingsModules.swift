import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case audioVisual = "Audio/Visual"
    case aiLearning = "AI Learning"
    case skills = "Skills"
    case memory = "Memory"

    var id: String { rawValue }
}

@MainActor
final class SettingsRootViewModel: ObservableObject {
    @Published var selectedTab: SettingsTab = .general
    let settingsStore: SettingsStore

    init(settingsStore: SettingsStore = UserDefaultsSettingsStore()) {
        self.settingsStore = settingsStore
    }
}

struct SettingsGeneralTabView: View {
    let generalSection: AnyView
    let toneLearningSection: AnyView
    let securitySection: AnyView

    var body: some View {
        generalSection
        toneLearningSection
        securitySection
    }
}

struct SettingsAudioVisualTabView: View {
    let wakeWordSection: AnyView
    let sttSection: AnyView
    let audioCaptureSection: AnyView
    let voiceOutputSection: AnyView
    let cameraVisionSection: AnyView

    var body: some View {
        wakeWordSection
        sttSection
        audioCaptureSection
        voiceOutputSection
        cameraVisionSection
    }
}

struct SettingsAILearningTabView: View {
    let samGatewaySection: AnyView
    let routingSection: AnyView
    let openAISection: AnyView
    let aiLearningSection: AnyView

    var body: some View {
        samGatewaySection
        routingSection
        openAISection
        aiLearningSection
    }
}

struct SettingsSkillsTabView: View {
    let installedSkillsSection: AnyView
    let capabilitiesSection: AnyView

    var body: some View {
        installedSkillsSection
        capabilitiesSection
    }
}

struct SettingsMemoryTabView: View {
    let memorySection: AnyView

    var body: some View {
        memorySection
    }
}
