import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    // Pull settings from container once available
    @State private var openaiKey = ""
    @State private var openaiModel = AppConfig.defaultModel
    @State private var elevenlabsKey = ""
    @State private var elevenlabsVoiceID = ""
    @State private var elevenlabsModelID = AppConfig.defaultTTSModel
    @State private var elevenlabsStreaming = true
    @State private var porcupineKey = ""
    @State private var porcupineSensitivity = AppConfig.defaultWakeWordSensitivity
    @State private var userName = ""
    @State private var cameraEnabled = false
    @State private var ambientListening = false
    @State private var followUpTimeout = AppConfig.defaultFollowUpTimeout
    @State private var debugMemory = false
    @State private var debugPrompt = false
    @State private var debugLatency = true
    @State private var youtubeKey = ""
    @State private var gmailToken = ""
    @State private var elevenlabsMuted = false
    // Engine toggles
    @State private var engCognitiveTrace = true
    @State private var engWorldModel = true
    @State private var engCuriosity = true
    @State private var engLongitudinal = true
    @State private var engBehavior = true
    @State private var engCounterfactual = false
    @State private var engTheoryOfMind = true
    @State private var engNarrative = false
    @State private var engCausal = false
    @State private var engMetacognition = true
    @State private var engPersonality = true
    @State private var engSkillEvolution = true

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            apiKeysTab
                .tabItem { Label("API Keys", systemImage: "key") }
            voiceTab
                .tabItem { Label("Voice", systemImage: "waveform") }
            intelligenceTab
                .tabItem { Label("Intelligence", systemImage: "brain") }
            debugTab
                .tabItem { Label("Debug", systemImage: "ladybug") }
        }
        .frame(width: 500, height: 400)
        .padding()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    saveSettings()
                    dismiss()
                }
            }
        }
        .onAppear { loadSettings() }
        .onDisappear { saveSettings() }
    }

    // MARK: - Tabs

    private var generalTab: some View {
        Form {
            TextField("Your Name", text: $userName)
            TextField("OpenAI Model", text: $openaiModel)
            Toggle("Camera Enabled", isOn: $cameraEnabled)
            Toggle("Ambient Listening", isOn: $ambientListening)
            HStack {
                Text("Follow-up Timeout")
                Slider(value: $followUpTimeout, in: 3...15, step: 1)
                Text("\(Int(followUpTimeout))s")
                    .monospacedDigit()
            }
        }
        .formStyle(.grouped)
    }

    private var apiKeysTab: some View {
        Form {
            SecureField("OpenAI API Key", text: $openaiKey)
            SecureField("ElevenLabs API Key", text: $elevenlabsKey)
            TextField("ElevenLabs Voice ID", text: $elevenlabsVoiceID)
            TextField("ElevenLabs Model", text: $elevenlabsModelID)
            SecureField("Porcupine Access Key", text: $porcupineKey)
            SecureField("YouTube API Key", text: $youtubeKey)
            SecureField("Gmail OAuth Token", text: $gmailToken)
        }
        .formStyle(.grouped)
    }

    private var voiceTab: some View {
        Form {
            Toggle("Streaming TTS", isOn: $elevenlabsStreaming)
            Toggle("Mute TTS", isOn: $elevenlabsMuted)
            HStack {
                Text("Wake Word Sensitivity")
                Slider(value: $porcupineSensitivity, in: 0...1, step: 0.1)
                Text(String(format: "%.1f", porcupineSensitivity))
                    .monospacedDigit()
            }
        }
        .formStyle(.grouped)
    }

    private var intelligenceTab: some View {
        Form {
            Section("Core Engines") {
                Toggle("Cognitive Trace", isOn: $engCognitiveTrace)
                Toggle("Living World Model", isOn: $engWorldModel)
                Toggle("Active Curiosity", isOn: $engCuriosity)
                Toggle("Theory of Mind", isOn: $engTheoryOfMind)
                Toggle("Metacognition", isOn: $engMetacognition)
                Toggle("Personality", isOn: $engPersonality)
            }
            Section("Pattern Engines") {
                Toggle("Longitudinal Patterns", isOn: $engLongitudinal)
                Toggle("Behavior Patterns", isOn: $engBehavior)
                Toggle("Skill Evolution", isOn: $engSkillEvolution)
            }
            Section("Advanced (Higher CPU)") {
                Toggle("Counterfactual", isOn: $engCounterfactual)
                Toggle("Narrative Coherence", isOn: $engNarrative)
                Toggle("Causal Learning", isOn: $engCausal)
            }
        }
        .formStyle(.grouped)
    }

    private var debugTab: some View {
        Form {
            Toggle("Memory Debug", isOn: $debugMemory)
            Toggle("Prompt Debug", isOn: $debugPrompt)
            Toggle("Latency Debug", isOn: $debugLatency)
        }
        .formStyle(.grouped)
    }

    // MARK: - Persistence

    private func loadSettings() {
        guard let s = appState.container?.settings else { return }
        openaiKey = s.string(forKey: SettingsKey.openaiAPIKey) ?? ""
        openaiModel = s.string(forKey: SettingsKey.openaiModel) ?? AppConfig.defaultModel
        elevenlabsKey = s.string(forKey: SettingsKey.elevenlabsAPIKey) ?? ""
        elevenlabsVoiceID = s.string(forKey: SettingsKey.elevenlabsVoiceID) ?? ""
        elevenlabsModelID = s.string(forKey: SettingsKey.elevenlabsModelID) ?? AppConfig.defaultTTSModel
        elevenlabsStreaming = s.bool(forKey: SettingsKey.elevenlabsStreaming)
        porcupineKey = s.string(forKey: SettingsKey.porcupineAccessKey) ?? ""
        porcupineSensitivity = s.double(forKey: SettingsKey.porcupineSensitivity)
        userName = s.string(forKey: SettingsKey.userName) ?? ""
        cameraEnabled = s.bool(forKey: SettingsKey.cameraEnabled)
        ambientListening = s.bool(forKey: SettingsKey.ambientListening)
        followUpTimeout = s.double(forKey: SettingsKey.followUpTimeoutS)
        debugMemory = s.bool(forKey: SettingsKey.debugMemory)
        debugPrompt = s.bool(forKey: SettingsKey.debugPrompt)
        debugLatency = s.bool(forKey: SettingsKey.debugLatency)
        youtubeKey = s.string(forKey: SettingsKey.youtubeAPIKey) ?? ""
        gmailToken = s.string(forKey: SettingsKey.gmailOAuthToken) ?? ""
        elevenlabsMuted = s.bool(forKey: SettingsKey.elevenlabsMuted)
        engCognitiveTrace = s.bool(forKey: SettingsKey.engineCognitiveTrace)
        engWorldModel = s.bool(forKey: SettingsKey.engineWorldModel)
        engCuriosity = s.bool(forKey: SettingsKey.engineCuriosity)
        engLongitudinal = s.bool(forKey: SettingsKey.engineLongitudinal)
        engBehavior = s.bool(forKey: SettingsKey.engineBehavior)
        engCounterfactual = s.bool(forKey: SettingsKey.engineCounterfactual)
        engTheoryOfMind = s.bool(forKey: SettingsKey.engineTheoryOfMind)
        engNarrative = s.bool(forKey: SettingsKey.engineNarrative)
        engCausal = s.bool(forKey: SettingsKey.engineCausal)
        engMetacognition = s.bool(forKey: SettingsKey.engineMetacognition)
        engPersonality = s.bool(forKey: SettingsKey.enginePersonality)
        engSkillEvolution = s.bool(forKey: SettingsKey.engineSkillEvolution)
    }

    private func saveSettings() {
        guard let s = appState.container?.settings else { return }
        s.setString(openaiKey, forKey: SettingsKey.openaiAPIKey)
        s.setString(openaiModel, forKey: SettingsKey.openaiModel)
        s.setString(elevenlabsKey, forKey: SettingsKey.elevenlabsAPIKey)
        s.setString(elevenlabsVoiceID, forKey: SettingsKey.elevenlabsVoiceID)
        s.setString(elevenlabsModelID, forKey: SettingsKey.elevenlabsModelID)
        s.setBool(elevenlabsStreaming, forKey: SettingsKey.elevenlabsStreaming)
        s.setString(porcupineKey, forKey: SettingsKey.porcupineAccessKey)
        s.setDouble(porcupineSensitivity, forKey: SettingsKey.porcupineSensitivity)
        s.setString(userName, forKey: SettingsKey.userName)
        s.setBool(cameraEnabled, forKey: SettingsKey.cameraEnabled)
        s.setBool(ambientListening, forKey: SettingsKey.ambientListening)
        s.setDouble(followUpTimeout, forKey: SettingsKey.followUpTimeoutS)
        s.setBool(debugMemory, forKey: SettingsKey.debugMemory)
        s.setBool(debugPrompt, forKey: SettingsKey.debugPrompt)
        s.setBool(debugLatency, forKey: SettingsKey.debugLatency)
        s.setString(youtubeKey, forKey: SettingsKey.youtubeAPIKey)
        s.setString(gmailToken, forKey: SettingsKey.gmailOAuthToken)
        s.setBool(elevenlabsMuted, forKey: SettingsKey.elevenlabsMuted)
        s.setBool(engCognitiveTrace, forKey: SettingsKey.engineCognitiveTrace)
        s.setBool(engWorldModel, forKey: SettingsKey.engineWorldModel)
        s.setBool(engCuriosity, forKey: SettingsKey.engineCuriosity)
        s.setBool(engLongitudinal, forKey: SettingsKey.engineLongitudinal)
        s.setBool(engBehavior, forKey: SettingsKey.engineBehavior)
        s.setBool(engCounterfactual, forKey: SettingsKey.engineCounterfactual)
        s.setBool(engTheoryOfMind, forKey: SettingsKey.engineTheoryOfMind)
        s.setBool(engNarrative, forKey: SettingsKey.engineNarrative)
        s.setBool(engCausal, forKey: SettingsKey.engineCausal)
        s.setBool(engMetacognition, forKey: SettingsKey.engineMetacognition)
        s.setBool(engPersonality, forKey: SettingsKey.enginePersonality)
        s.setBool(engSkillEvolution, forKey: SettingsKey.engineSkillEvolution)
    }
}
