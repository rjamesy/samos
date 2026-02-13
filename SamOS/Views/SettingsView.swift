import SwiftUI
import UniformTypeIdentifiers
import Foundation

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case audioVisual = "Audio/Visual"
        case aiLearning = "AI Learning"
        case skills = "Skills"
        case memory = "Memory"

        var id: String { rawValue }
    }

    @State private var selectedTab: SettingsTab = .general

    // Wake Word
    @State private var porcupineAccessKey: String = M2Settings.porcupineAccessKey
    @State private var porcupineKeywordPath: String = M2Settings.porcupineKeywordDisplayPath
    @State private var porcupineSensitivity: Float = M2Settings.porcupineSensitivity

    // STT
    @State private var whisperModelPath: String = M2Settings.whisperModelDisplayPath

    // Audio Capture
    @State private var silenceThresholdDB: Float = M2Settings.silenceThresholdDB
    @State private var silenceDurationMs: Double = Double(M2Settings.silenceDurationMs)

    // Sound Cues
    @State private var captureBeepEnabled: Bool = M2Settings.captureBeepEnabled

    // Router
    @State private var useEmotionalTone: Bool = M2Settings.useEmotionalTone
    @State private var faceRecognitionEnabled: Bool = M2Settings.faceRecognitionEnabled
    @State private var personalizedGreetingsEnabled: Bool = M2Settings.personalizedGreetingsEnabled
    @State private var useOllama: Bool = M2Settings.useOllama
    @State private var ollamaEndpoint: String = M2Settings.ollamaEndpoint
    @State private var ollamaModel: String = M2Settings.ollamaModel
    @State private var preferOpenAIPlans: Bool = M2Settings.preferOpenAIPlans
    @State private var disableAutoClosePrompts: Bool = M2Settings.disableAutoClosePrompts

    // Tone learning
    @State private var toneProfile: TonePreferenceProfile = TonePreferenceStore.shared.loadProfile()
    @State private var showToneLearningNote = false

    // Voice Output (ElevenLabs)
    @State private var elevenLabsApiKey: String = ElevenLabsSettings.apiKey
    @State private var elevenLabsVoiceId: String = ElevenLabsSettings.voiceId
    @State private var elevenLabsMuted: Bool = ElevenLabsSettings.isMuted
    @State private var elevenLabsStreaming: Bool = ElevenLabsSettings.useStreaming
    @State private var testVoiceInProgress: Bool = false

    // OpenAI
    @State private var openaiApiKey: String = OpenAISettings.apiKey
    @State private var youtubeApiKey: String = OpenAISettings.youtubeAPIKey
    @State private var openaiGeneralModel: String = OpenAISettings.generalModel
    @State private var openaiEscalationModel: String = OpenAISettings.escalationModel
    @State private var openaiRealtimeModeEnabled: Bool = OpenAISettings.realtimeModeEnabled
    @State private var openaiRealtimeUseClassicSTT: Bool = OpenAISettings.realtimeUseClassicSTT
    @State private var openaiRealtimeModel: String = OpenAISettings.realtimeModel
    @State private var openaiRealtimeVoice: String = OpenAISettings.realtimeVoice

    // Memory
    @State private var memories: [MemoryRow] = []
    @State private var showClearConfirmation = false
    @State private var faceClearFeedback: String = ""

    // Skills
    @State private var installedSkills: [SkillSpec] = []

    // User
    @State private var userName: String = M2Settings.userName

    // Keychain
    @State private var useKeychainStorage: Bool = KeychainStore.useKeychain

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.title2.bold())
                Spacer()
                Button(action: { appState.showSettings = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            Picker("Settings Tab", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Form {
                if appState.wasListeningPausedForSettings {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.slash")
                        Text("Listening paused while Settings is open")
                    }
                    .font(.caption)
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }

                switch selectedTab {
                case .general:
                    generalSection
                    toneLearningSection
                    securitySection

                case .audioVisual:
                    wakeWordSection
                    sttSection
                    audioCaptureSection
                    voiceOutputSection
                    cameraVisionSection

                case .aiLearning:
                    routingSection
                    openAISection
                    aiLearningSection

                case .skills:
                    installedSkillsSection
                    capabilitiesSection

                case .memory:
                    memorySection
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 560, minHeight: 560)
        .onAppear {
            appState.pauseListeningForSettings()
            reloadMemories()
            appState.refreshWebsiteLearningDebug()
            appState.refreshAutonomousLearningDebug()
            appState.refreshCameraDebug()
            installedSkills = SkillStore.shared.loadInstalled()
            toneProfile = TonePreferenceStore.shared.loadProfile()
            useOllama = M2Settings.useOllama
            preferOpenAIPlans = M2Settings.preferOpenAIPlans
            ollamaEndpoint = M2Settings.ollamaEndpoint
            ollamaModel = M2Settings.ollamaModel
        }
        .onDisappear {
            appState.resumeListeningAfterSettings()
        }
        .alert("Tone Learning Enabled", isPresented: $showToneLearningNote) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Sam can adapt to your preferred style (direct vs warm). Stored locally. You can reset anytime.")
        }
    }

    private var generalSection: some View {
        Section("General") {
            TextField("Your name", text: $userName, prompt: Text("Used in alarm greetings"))
                .textFieldStyle(.roundedBorder)
                .onChange(of: userName) { _, newValue in
                    M2Settings.userName = newValue
                }

            Toggle("Use emotional tone", isOn: $useEmotionalTone)
                .onChange(of: useEmotionalTone) { _, newValue in
                    M2Settings.useEmotionalTone = newValue
                }

            if !M2Settings.affectMirroringEnabled {
                Text("Emotional mirroring rollout is currently off. This preference will apply once enabled.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var toneLearningSection: some View {
        Section("Tone Learning") {
            Toggle("Enable tone learning", isOn: Binding(
                get: { toneProfile.enabled },
                set: { newValue in
                    toneProfile.enabled = newValue
                    toneProfile = TonePreferenceStore.shared.updateEnabled(newValue)
                    if newValue && !M2Settings.toneLearningNoticeShown {
                        M2Settings.toneLearningNoticeShown = true
                        showToneLearningNote = true
                    }
                }
            ))

            Button("Reset tone preferences", role: .destructive) {
                toneProfile = TonePreferenceStore.shared.resetProfile()
            }

            LabeledContent("Directness") { Text(String(format: "%.2f", toneProfile.directness)) }
            LabeledContent("Warmth") { Text(String(format: "%.2f", toneProfile.warmth)) }
            LabeledContent("Curiosity") { Text(String(format: "%.2f", toneProfile.curiosity)) }
            LabeledContent("Reassurance") { Text(String(format: "%.2f", toneProfile.reassurance)) }
            LabeledContent("Humor") { Text(String(format: "%.2f", toneProfile.humor)) }
            LabeledContent("Formality") { Text(String(format: "%.2f", toneProfile.formality)) }
            LabeledContent("Hedging") { Text(String(format: "%.2f", toneProfile.hedging)) }
            LabeledContent("Avoid cheerful when upset") { Text(toneProfile.avoidCheerfulWhenUpset ? "On" : "Off") }
            LabeledContent("Avoid therapy language") { Text(toneProfile.avoidTherapyLanguage ? "On" : "Off") }
            LabeledContent("Prefer bullet steps") { Text(toneProfile.preferBulletSteps ? "On" : "Off") }
            LabeledContent("Prefer short openers") { Text(toneProfile.preferShortOpeners ? "On" : "Off") }
            LabeledContent("Prefer one question max") { Text(toneProfile.preferOneQuestionMax ? "On" : "Off") }

            Text("Stored locally on this Mac. No cloud sync.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var wakeWordSection: some View {
        Section("Wake Word (Porcupine)") {
            SecureField("AccessKey", text: $porcupineAccessKey)
                .onChange(of: porcupineAccessKey) { _, newValue in
                    M2Settings.porcupineAccessKey = newValue
                }

            HStack {
                TextField("Keyword (.ppn) file", text: $porcupineKeywordPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
                Button("Browse...") {
                    selectFile(title: "Select Porcupine Keyword File", types: [UTType(filenameExtension: "ppn")].compactMap { $0 }) { url in
                        M2Settings.setPorcupineKeywordURL(url)
                        porcupineKeywordPath = url.path
                    }
                }
            }

            HStack {
                Text("Sensitivity: \(porcupineSensitivity, specifier: "%.2f")")
                Slider(value: $porcupineSensitivity, in: 0...1, step: 0.05)
                    .onChange(of: porcupineSensitivity) { _, newValue in
                        M2Settings.porcupineSensitivity = newValue
                    }
            }

            LabeledContent("Status") {
                if !porcupineAccessKey.isEmpty && !porcupineKeywordPath.isEmpty
                    && FileManager.default.fileExists(atPath: porcupineKeywordPath) {
                    Text("Configured").foregroundColor(.green)
                } else {
                    Text("Not configured").foregroundColor(.secondary)
                }
            }
        }
    }

    private var sttSection: some View {
        let diagnostics = STTDiagnosticsStore.shared.snapshot()
        return Section("Speech-to-Text (Whisper)") {
            HStack {
                TextField("Whisper model (.bin) file", text: $whisperModelPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
                Button("Browse...") {
                    selectFile(title: "Select Whisper Model File", types: [UTType(filenameExtension: "bin")].compactMap { $0 }) { url in
                        M2Settings.setWhisperModelURL(url)
                        whisperModelPath = url.path
                    }
                }
            }

            LabeledContent("Status") {
                if !whisperModelPath.isEmpty && FileManager.default.fileExists(atPath: whisperModelPath) {
                    Text("Configured").foregroundColor(.green)
                } else {
                    Text("Not configured").foregroundColor(.secondary)
                }
            }

            Divider()

            LabeledContent("Diagnostics • Engine") {
                Text(diagnostics.selectedEngine).foregroundColor(.secondary)
            }
            LabeledContent("Diagnostics • Model Found") {
                Text(diagnostics.modelFound ? "Yes" : "No")
                    .foregroundColor(diagnostics.modelFound ? .green : .secondary)
            }
            LabeledContent("Diagnostics • Prewarmed") {
                Text(diagnostics.prewarmed ? "Yes" : "No")
                    .foregroundColor(diagnostics.prewarmed ? .green : .secondary)
            }
            LabeledContent("Diagnostics • Last Error") {
                Text(diagnostics.lastError ?? "None")
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            if let fallbackNote = diagnostics.launchFallbackNote {
                LabeledContent("Diagnostics • Model Fallback") {
                    Text(fallbackNote)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var audioCaptureSection: some View {
        Section("Audio Capture") {
            HStack {
                Text("Silence threshold: \(Int(silenceThresholdDB)) dB")
                Slider(value: $silenceThresholdDB, in: -50...(-20), step: 1)
                    .onChange(of: silenceThresholdDB) { _, newValue in
                        M2Settings.silenceThresholdDB = newValue
                    }
            }

            HStack {
                Text("Silence duration: \(Int(silenceDurationMs)) ms")
                Slider(value: $silenceDurationMs, in: 400...2000, step: 100)
                    .onChange(of: silenceDurationMs) { _, newValue in
                        M2Settings.silenceDurationMs = Int(newValue)
                    }
            }

            Toggle("Play capture beep", isOn: $captureBeepEnabled)
                .onChange(of: captureBeepEnabled) { _, newValue in
                    M2Settings.captureBeepEnabled = newValue
                }

            LabeledContent("Microphone") {
                switch MicrophonePermission.currentStatus {
                case .granted:
                    Text("Granted").foregroundColor(.green)
                case .denied:
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Denied").foregroundColor(.red)
                        Button("Open System Settings") {
                            MicrophonePermission.openSystemSettings()
                        }
                        .font(.caption)
                    }
                case .undetermined:
                    Text("Not yet requested").foregroundColor(.secondary)
                }
            }
        }
    }

    private var routingSection: some View {
        Section("Routing") {
            Toggle("Use Ollama", isOn: $useOllama)
                .onChange(of: useOllama) { _, newValue in
                    M2Settings.useOllama = newValue
                }

            TextField("Endpoint", text: $ollamaEndpoint)
                .textFieldStyle(.roundedBorder)
                .disabled(!useOllama)
                .onChange(of: ollamaEndpoint) { _, newValue in
                    M2Settings.ollamaEndpoint = newValue
                }

            TextField("Model", text: $ollamaModel)
                .textFieldStyle(.roundedBorder)
                .disabled(!useOllama)
                .onChange(of: ollamaModel) { _, newValue in
                    M2Settings.ollamaModel = newValue
                }

            Toggle("Prefer OpenAI plans (dev override)", isOn: $preferOpenAIPlans)
                .onChange(of: preferOpenAIPlans) { _, newValue in
                    M2Settings.preferOpenAIPlans = newValue
                }

            Toggle("Disable auto-close prompts", isOn: $disableAutoClosePrompts)
                .onChange(of: disableAutoClosePrompts) { _, newValue in
                    M2Settings.disableAutoClosePrompts = newValue
                }

            LabeledContent("Status") {
                if useOllama {
                    Text("Ollama (active)").foregroundColor(.green)
                } else {
                    Text("Mock (active)").foregroundColor(.secondary)
                }
            }
        }
    }

    private var voiceOutputSection: some View {
        Section("Voice Output (ElevenLabs)") {
            SecureField("API Key", text: $elevenLabsApiKey)
                .onChange(of: elevenLabsApiKey) { _, newValue in
                    ElevenLabsSettings.apiKey = newValue
                }

            TextField("Voice ID", text: $elevenLabsVoiceId)
                .textFieldStyle(.roundedBorder)
                .onChange(of: elevenLabsVoiceId) { _, newValue in
                    ElevenLabsSettings.voiceId = newValue
                }

            Toggle("Mute voice", isOn: $elevenLabsMuted)
                .onChange(of: elevenLabsMuted) { _, newValue in
                    ElevenLabsSettings.isMuted = newValue
                    appState.isMuted = newValue
                    if newValue {
                        TTSService.shared.stopSpeaking()
                    }
                }

            Toggle("Use streaming voice", isOn: $elevenLabsStreaming)
                .onChange(of: elevenLabsStreaming) { _, newValue in
                    ElevenLabsSettings.useStreaming = newValue
                }

            HStack {
                Button("Test Voice") {
                    testVoiceInProgress = true
                    TTSService.shared.speak("Hi Richard, voice is working.")
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        testVoiceInProgress = false
                    }
                }
                .disabled(!ElevenLabsSettings.isConfigured || testVoiceInProgress)

                if testVoiceInProgress {
                    ProgressView().scaleEffect(0.5)
                }
            }

            LabeledContent("Status") {
                if ElevenLabsSettings.isConfigured {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Configured").foregroundColor(.green)
                        if let savedAt = ElevenLabsSettings.keySavedAt {
                            Text("Key saved \(savedAt, style: .relative) ago")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text("API key required").foregroundColor(.secondary)
                }
            }
        }
    }

    private var cameraVisionSection: some View {
        Section("Camera Vision") {
            Toggle("Enable camera", isOn: Binding(
                get: { appState.isCameraEnabled },
                set: { appState.setCameraEnabled($0) }
            ))

            Toggle("Enable face recognition", isOn: $faceRecognitionEnabled)
                .onChange(of: faceRecognitionEnabled) { _, newValue in
                    M2Settings.faceRecognitionEnabled = newValue
                    if !newValue {
                        personalizedGreetingsEnabled = false
                        M2Settings.personalizedGreetingsEnabled = false
                    }
                }

            Toggle("Personalized greetings", isOn: $personalizedGreetingsEnabled)
                .disabled(!faceRecognitionEnabled)
                .onChange(of: personalizedGreetingsEnabled) { _, newValue in
                    M2Settings.personalizedGreetingsEnabled = newValue
                }

            LabeledContent("Permission") {
                switch appState.cameraPermissionStatus {
                case .granted:
                    Text("Granted").foregroundColor(.green)
                case .denied:
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Denied").foregroundColor(.red)
                        Button("Open System Settings") {
                            CameraPermission.openSystemSettings()
                        }
                        .font(.caption)
                    }
                case .undetermined:
                    Text("Not yet requested").foregroundColor(.secondary)
                }
            }

            if let frameAt = appState.cameraLastFrameAt {
                LabeledContent("Last frame") {
                    Text(frameAt, style: .relative)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("No camera frame yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let preview = appState.cameraPreviewImage {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 180)
                    .cornerRadius(8)
            }

            if let cameraError = appState.cameraErrorMessage, !cameraError.isEmpty {
                Text(cameraError)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Button("Describe Current View") {
                    appState.describeCurrentCameraView()
                }
                .disabled(!appState.isCameraEnabled)

                Button("Clear Saved Faces", role: .destructive) {
                    let didClear = appState.clearSavedFaces()
                    faceClearFeedback = didClear
                        ? "Saved faces cleared locally."
                        : "Saved faces cleared from active memory."
                }

                Spacer()

                Button("Refresh Status") {
                    appState.refreshCameraDebug()
                }
                .buttonStyle(.borderless)
            }

            if !faceClearFeedback.isEmpty {
                Text(faceClearFeedback)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("When camera is enabled, Sam can describe the scene, find objects, detect face presence, enroll and recognize named faces, answer visual questions, capture inventory snapshots, and save camera memory notes. Face profiles stay local in encrypted storage.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var openAISection: some View {
        Section("OpenAI") {
            SecureField("API Key", text: $openaiApiKey)
                .onChange(of: openaiApiKey) { _, newValue in
                    OpenAISettings.apiKey = newValue
                }

            SecureField("YouTube Data API Key (optional)", text: $youtubeApiKey)
                .onChange(of: youtubeApiKey) { _, newValue in
                    OpenAISettings.youtubeAPIKey = newValue
                }

            Picker("General Model", selection: $openaiGeneralModel) {
                ForEach(OpenAISettings.generalModelOptions, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: openaiGeneralModel) { _, newValue in
                OpenAISettings.generalModel = newValue
            }

            Picker("Escalation Model (Complex Tasks)", selection: $openaiEscalationModel) {
                ForEach(OpenAISettings.escalationModelOptions, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: openaiEscalationModel) { _, newValue in
                OpenAISettings.escalationModel = newValue
            }

            Text("Complex requests automatically use the escalation model.")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Realtime Mode (WebSocket transcription)", isOn: $openaiRealtimeModeEnabled)
                .onChange(of: openaiRealtimeModeEnabled) { _, newValue in
                    OpenAISettings.realtimeModeEnabled = newValue
                    appState.reconfigureVoicePipelineForCurrentMode()
                }

            Toggle("Classic STT in Realtime Mode (faster)", isOn: $openaiRealtimeUseClassicSTT)
                .disabled(!openaiRealtimeModeEnabled)
                .onChange(of: openaiRealtimeUseClassicSTT) { _, newValue in
                    OpenAISettings.realtimeUseClassicSTT = newValue
                    appState.reconfigureVoicePipelineForCurrentMode()
                }

            TextField("Realtime Model", text: $openaiRealtimeModel)
                .textFieldStyle(.roundedBorder)
                .disabled(!openaiRealtimeModeEnabled)
                .onChange(of: openaiRealtimeModel) { _, newValue in
                    OpenAISettings.realtimeModel = newValue
                }

            TextField("Realtime Voice", text: $openaiRealtimeVoice)
                .textFieldStyle(.roundedBorder)
                .disabled(!openaiRealtimeModeEnabled)
                .onChange(of: openaiRealtimeVoice) { _, newValue in
                    OpenAISettings.realtimeVoice = newValue
                }

            LabeledContent("Status") {
                let keyStatus = OpenAISettings.apiKeyStatus
                if keyStatus == .ready {
                    VStack(alignment: .trailing, spacing: 2) {
                        if openaiRealtimeModeEnabled {
                            let sttMode = openaiRealtimeUseClassicSTT ? "Classic STT" : "Realtime STT"
                            Text("Configured (\(sttMode) + ElevenLabs TTS)")
                                .foregroundColor(.green)
                        } else {
                            Text("Configured (Classic STT + ElevenLabs TTS)")
                                .foregroundColor(.green)
                        }
                        if let savedAt = OpenAISettings.keySavedAt {
                            Text("Key saved \(savedAt, style: .relative) ago")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Text("General: \(OpenAISettings.generalModel)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("Escalation: \(OpenAISettings.escalationModel)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(OpenAISettings.isYouTubeConfigured ? "YouTube API configured" : "YouTube API not configured")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else if keyStatus == .invalid {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text("API key rejected (401/403)")
                            .foregroundColor(.orange)
                        Button("Re-check Key") {
                            OpenAISettings.retryInvalidatedAPIKey()
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    Text("API key required").foregroundColor(.secondary)
                }
            }
        }
        .onAppear {
            if !OpenAISettings.generalModelOptions.contains(openaiGeneralModel) {
                openaiGeneralModel = OpenAISettings.generalModelOptions.first ?? "gpt-4o-mini"
                OpenAISettings.generalModel = openaiGeneralModel
            }
            if !OpenAISettings.escalationModelOptions.contains(openaiEscalationModel) {
                openaiEscalationModel = OpenAISettings.escalationModelOptions.first ?? "gpt-4o"
                OpenAISettings.escalationModel = openaiEscalationModel
            }
        }
    }

    private var aiLearningSection: some View {
        Section("AI Learning") {
            LabeledContent("Websites Learned") {
                Text("\(appState.learnedWebsiteCount)")
                    .font(.body.monospacedDigit())
            }

            LabeledContent("Learning Sessions") {
                Text("\(appState.autonomousLearningReportCount)")
                    .font(.body.monospacedDigit())
            }

            if let active = appState.activeAutonomousLearningSession {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Active session")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.orange)
                    Text("Topic: \(active.topic)")
                        .font(.caption)
                    Text("Duration: \(active.requestedMinutes) minute\(active.requestedMinutes == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("Expected finish: \(active.expectedFinishAt, style: .time)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("No active autonomous learning session")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("Settings only shows learning counts and status. Full learning logs stay out of Settings, but Sam still uses learned data in future answers.")
                .font(.caption)
                .foregroundColor(.secondary)

            Button("Refresh Learning Status") {
                appState.refreshWebsiteLearningDebug()
                appState.refreshAutonomousLearningDebug()
            }
            .buttonStyle(.borderless)
        }
    }

    private var installedSkillsSection: some View {
        Section("Installed Skills") {
            if installedSkills.isEmpty {
                Text("No skills installed")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                ForEach(installedSkills) { skill in
                    LabeledContent(skill.name) {
                        Text(skill.triggerPhrases.prefix(3).joined(separator: ", "))
                            .foregroundColor(.secondary)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
            }

            LabeledContent("Count") {
                Text("\(installedSkills.count)")
            }
        }
    }

    private var capabilitiesSection: some View {
        Section("Capabilities") {
            LabeledContent("Registered Tools") {
                Text("\(ToolRegistry.shared.allTools.count)")
            }
            ForEach(ToolRegistry.shared.allTools, id: \.name) { tool in
                LabeledContent(tool.name) {
                    Text(tool.description)
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
        }
    }

    private var memorySection: some View {
        Section("Memory") {
            let facts = memories.filter { $0.type == .fact }.count
            let preferences = memories.filter { $0.type == .preference }.count
            let notes = memories.filter { $0.type == .note }.count
            let checkins = memories.filter { $0.type == .checkin }.count

            LabeledContent("Total") {
                Text("\(memories.count)")
                    .font(.body.monospacedDigit())
            }
            LabeledContent("Facts") {
                Text("\(facts)")
                    .font(.body.monospacedDigit())
            }
            LabeledContent("Preferences") {
                Text("\(preferences)")
                    .font(.body.monospacedDigit())
            }
            LabeledContent("Notes") {
                Text("\(notes)")
                    .font(.body.monospacedDigit())
            }
            LabeledContent("Check-ins") {
                Text("\(checkins)")
                    .font(.body.monospacedDigit())
            }

            LabeledContent("Storage") {
                Text(MemoryStore.shared.isAvailable ? "SQLite (active)" : "Unavailable")
                    .foregroundColor(MemoryStore.shared.isAvailable ? .green : .red)
            }

            HStack {
                Button("Refresh") {
                    reloadMemories()
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("Clear All Memories", role: .destructive) {
                    showClearConfirmation = true
                }
                .confirmationDialog("Clear all memories?", isPresented: $showClearConfirmation) {
                    Button("Clear All", role: .destructive) {
                        MemoryStore.shared.clearMemories()
                        reloadMemories()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will remove all saved memories. This cannot be undone.")
                }
            }
        }
    }

    private var securitySection: some View {
        Section("Security") {
            #if DEBUG
            Text("Dev mode: API keys are stored locally in app preferences (Keychain disabled).")
                .font(.caption)
                .foregroundColor(.secondary)
            #else
            Toggle("Store API keys in Keychain (recommended)", isOn: $useKeychainStorage)
                .onChange(of: useKeychainStorage) { _, newValue in
                    KeychainStore.useKeychain = newValue
                }

            Text(useKeychainStorage
                 ? "API keys are stored securely in the macOS Keychain."
                 : "API keys are kept in memory only and will be lost when the app quits.")
                .font(.caption)
                .foregroundColor(.secondary)
            #endif
        }
    }

    private func reloadMemories() {
        memories = MemoryStore.shared.listMemories()
    }

    private func selectFile(title: String, types: [UTType], completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }
}
