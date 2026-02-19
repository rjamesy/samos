import SwiftUI
import UniformTypeIdentifiers
import Foundation

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var rootViewModel = SettingsRootViewModel()

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
    @State private var developerModeEnabled: Bool = M2Settings.developerModeEnabled
    @State private var faceRecognitionEnabled: Bool = M2Settings.faceRecognitionEnabled
    @State private var personalizedGreetingsEnabled: Bool = M2Settings.personalizedGreetingsEnabled
    @State private var useOllama: Bool = M2Settings.useOllama
    @State private var ollamaEndpoint: String = M2Settings.ollamaEndpoint
    @State private var ollamaModel: String = M2Settings.ollamaModel
    @State private var preferOpenAIPlans: Bool = M2Settings.preferOpenAIPlans
    @State private var disableAutoClosePrompts: Bool = M2Settings.disableAutoClosePrompts
    @State private var ollamaCombinedTimeoutMs: Double = Double(M2Settings.ollamaCombinedTimeoutMs)

    // Sam Gateway
    @State private var samGatewayURL: String = M2Settings.samGatewayURL

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
    @State private var openaiPreferredModel: String = OpenAISettings.generalModel
    @State private var openaiRealtimeModeEnabled: Bool = OpenAISettings.realtimeModeEnabled
    @State private var openaiRealtimeUseClassicSTT: Bool = OpenAISettings.realtimeUseClassicSTT
    @State private var openaiRealtimeModel: String = OpenAISettings.realtimeModel
    @State private var openaiRealtimeVoice: String = OpenAISettings.realtimeVoice

    // Memory
    @State private var memories: [MemoryRow] = []
    @State private var semanticEpisodes: [SemanticEpisodeRecord] = []
    @State private var selectedSemanticEpisodeID: String?
    @State private var semanticEpisodeExport: String = ""
    @State private var showClearConfirmation = false
    @State private var faceClearFeedback: String = ""

    // Skills
    @State private var skillSearchQuery: String = ""
    @State private var skillSearchResults: [SkillSearchResult] = []
    @State private var searchedSkills = false
    @State private var capabilitySearchQuery: String = ""
    @State private var capabilitySearchResults: [CapabilityDescriptor] = []
    @State private var searchedCapabilities = false
    @State private var skillEditorDraft: SkillEditorDraft?
    @State private var capabilityEditorDraft: CapabilityEditorDraft?

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

            Picker("Settings Tab", selection: $rootViewModel.selectedTab) {
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

                switch rootViewModel.selectedTab {
                case .general:
                    SettingsGeneralTabView(
                        generalSection: AnyView(generalSection),
                        toneLearningSection: AnyView(toneLearningSection),
                        securitySection: AnyView(securitySection)
                    )

                case .audioVisual:
                    SettingsAudioVisualTabView(
                        wakeWordSection: AnyView(wakeWordSection),
                        sttSection: AnyView(sttSection),
                        audioCaptureSection: AnyView(audioCaptureSection),
                        voiceOutputSection: AnyView(voiceOutputSection),
                        cameraVisionSection: AnyView(cameraVisionSection)
                    )

                case .aiLearning:
                    SettingsAILearningTabView(
                        samGatewaySection: developerModeEnabled
                            ? AnyView(samGatewaySection)
                            : AnyView(developerModeRequiredSection),
                        routingSection: AnyView(routingSection),
                        openAISection: AnyView(openAISection),
                        aiLearningSection: AnyView(aiLearningSection)
                    )

                case .skills:
                    SettingsSkillsTabView(
                        installedSkillsSection: AnyView(installedSkillsSection),
                        capabilitiesSection: AnyView(capabilitiesSection)
                    )

                case .memory:
                    SettingsMemoryTabView(memorySection: AnyView(memorySection))
                }
            }
            .formStyle(.grouped)
        }
        .sheet(item: $skillEditorDraft) { draft in
            SkillEditorSheet(
                draft: draft,
                onSave: { updated in
                    saveSkillEdit(updated)
                },
                onDelete: { deleted in
                    deleteSkill(deleted)
                }
            )
        }
        .sheet(item: $capabilityEditorDraft) { draft in
            CapabilityEditorSheet(
                draft: draft,
                onSave: { updated in
                    saveCapabilityEdit(updated)
                }
            )
        }
        .frame(minWidth: 560, minHeight: 560)
        .onAppear {
            appState.pauseListeningForSettings()
            reloadMemories()
            reloadSemanticEpisodes()
            appState.refreshWebsiteLearningDebug()
            appState.refreshAutonomousLearningDebug()
            appState.refreshCameraDebug()
            toneProfile = TonePreferenceStore.shared.loadProfile()
            useOllama = M2Settings.useOllama
            developerModeEnabled = M2Settings.developerModeEnabled
            preferOpenAIPlans = M2Settings.preferOpenAIPlans
            ollamaEndpoint = M2Settings.ollamaEndpoint
            ollamaModel = M2Settings.ollamaModel
            samGatewayURL = M2Settings.samGatewayURL
            openaiPreferredModel = OpenAISettings.generalModel
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

            Toggle("Developer mode", isOn: $developerModeEnabled)
                .onChange(of: developerModeEnabled) { _, newValue in
                    M2Settings.developerModeEnabled = newValue
                }

            Text("Developer mode reveals advanced routing and gateway controls.")
                .font(.caption)
                .foregroundColor(.secondary)

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

            if developerModeEnabled {
                Toggle("Prefer OpenAI plans (dev override)", isOn: $preferOpenAIPlans)
                    .onChange(of: preferOpenAIPlans) { _, newValue in
                        M2Settings.preferOpenAIPlans = newValue
                    }
            } else {
                Text("Enable Developer mode to access plan-routing override controls.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Toggle("Disable auto-close prompts", isOn: $disableAutoClosePrompts)
                .onChange(of: disableAutoClosePrompts) { _, newValue in
                    M2Settings.disableAutoClosePrompts = newValue
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Ollama Timeout")
                    Spacer()
                    Text("\(Int(ollamaCombinedTimeoutMs)) ms")
                        .foregroundColor(.secondary)
                }
                Slider(value: $ollamaCombinedTimeoutMs, in: 500...10000, step: 100)
                    .disabled(!useOllama)
                    .onChange(of: ollamaCombinedTimeoutMs) { _, newValue in
                        M2Settings.ollamaCombinedTimeoutMs = Int(newValue)
                    }
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

    private var samGatewaySection: some View {
        Section("Sam Gateway") {
            TextField("Gateway URL", text: $samGatewayURL)
                .onChange(of: samGatewayURL) { _, newValue in
                    M2Settings.samGatewayURL = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            if M2Settings.useSamGateway {
                if M2Settings.useOllama {
                    Text("Configured — Ollama remains primary while 'Use Ollama' is enabled.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Active — all input routed to Sam agent via gateway")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                HStack {
                    Text("Session: \(M2Settings.samSessionId.isEmpty ? "none" : M2Settings.samSessionId)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("New Session") {
                        M2Settings.samSessionId = ""
                    }
                    .font(.caption)
                }
            } else {
                Text("Empty = disabled. Set URL to route all input to the Sam gateway (e.g. http://localhost:8002)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var developerModeRequiredSection: some View {
        Section("Sam Gateway") {
            Text("Developer mode is disabled. Sam Gateway settings are hidden.")
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

            TextField("Preferred OpenAI model", text: $openaiPreferredModel)
                .textFieldStyle(.roundedBorder)
                .onChange(of: openaiPreferredModel) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    let selected = trimmed.isEmpty ? OpenAISettings.defaultPreferredModel : trimmed
                    openaiPreferredModel = selected
                    OpenAISettings.generalModel = selected
                    OpenAISettings.escalationModel = selected
                }

            Menu("Use model preset") {
                ForEach(OpenAISettings.preferredModelFallbacks, id: \.self) { model in
                    Button(model) {
                        openaiPreferredModel = model
                        OpenAISettings.generalModel = model
                        OpenAISettings.escalationModel = model
                    }
                }
            }

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
                        Text("Preferred: \(OpenAISettings.generalModel)")
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
        Group {
            Section("Skill Search") {
                TextField("Search skills (for example: news, weather, alarm)", text: $skillSearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        runSkillSearch()
                    }

                HStack {
                    Button("Search Skills") {
                        runSkillSearch()
                    }
                    .buttonStyle(.borderless)

                    if searchedSkills {
                        Text("\(skillSearchResults.count) match\(skillSearchResults.count == 1 ? "" : "es")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Text("Skills are loaded only when you search. Click a result to edit/save, and delete skills if needed.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if searchedSkills {
                Section("Skill Results") {
                    if skillSearchResults.isEmpty {
                        Text("No skills matched your search.")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(skillSearchResults) { result in
                            VStack(alignment: .leading, spacing: 6) {
                                Button {
                                    openSkillEditor(result)
                                } label: {
                                    HStack {
                                        Text(result.name)
                                        Spacer()
                                        Text(result.kind.label)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)

                                Text("ID: \(result.skillID)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)

                                Text("Keywords: \(result.keywords.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)

                                if result.capabilities.isEmpty {
                                    Text("Capabilities: none linked")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("Capabilities: \(result.capabilities.map(\.id).joined(separator: ", "))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 8) {
                                            ForEach(result.capabilities, id: \.id) { capability in
                                                Button(capability.name) {
                                                    openCapabilityEditor(capability)
                                                }
                                                .buttonStyle(.borderless)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    private var capabilitiesSection: some View {
        Group {
            Section("Capability Search") {
                TextField("Search capabilities (for example: news.basic, weather)", text: $capabilitySearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        runCapabilitySearch()
                    }

                HStack {
                    Button("Search Capabilities") {
                        runCapabilitySearch()
                    }
                    .buttonStyle(.borderless)

                    if searchedCapabilities {
                        Text("\(capabilitySearchResults.count) match\(capabilitySearchResults.count == 1 ? "" : "es")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Text("Capabilities are shared and deduplicated. Skills can link to one or many capabilities.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if searchedCapabilities {
                Section("Capability Results") {
                    if capabilitySearchResults.isEmpty {
                        Text("No capabilities matched your search.")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(capabilitySearchResults, id: \.id) { capability in
                            Button {
                                openCapabilityEditor(capability)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(capability.name)
                                        Spacer()
                                        Text(capability.id)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Text("Tools: \(capability.tools.joined(separator: ", "))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                    if !capability.permissions.isEmpty {
                                        Text("Permissions: \(capability.permissions.joined(separator: ", "))")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    private func runSkillSearch() {
        let query = skillSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchedSkills = false
            skillSearchResults = []
            return
        }

        let store = SkillStore.shared
        let catalog = CapabilityCatalog.shared
        let legacy = store.searchInstalledSkills(query: query, limit: 80).map { skill in
            let capabilities = capabilities(for: skill)
            return SkillSearchResult(
                kind: .legacy,
                skillID: skill.id,
                name: skill.name,
                keywords: skill.triggerPhrases,
                capabilities: capabilities
            )
        }
        let packages = store.searchInstalledPackages(query: query, limit: 80).map { package in
            let capabilities = capabilities(for: package)
            return SkillSearchResult(
                kind: .package,
                skillID: package.manifest.skillID,
                name: package.manifest.name,
                keywords: package.plan.intentPatterns,
                capabilities: capabilities
            )
        }

        var merged: [String: SkillSearchResult] = [:]
        for entry in legacy + packages {
            let key = "\(entry.kind.rawValue)#\(entry.skillID)"
            merged[key] = entry
        }

        let sorted = merged.values.sorted { lhs, rhs in
            if lhs.name == rhs.name { return lhs.skillID < rhs.skillID }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        skillSearchResults = sorted
        searchedSkills = true

        if capabilitySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let capabilityIDs = Set(sorted.flatMap { $0.capabilities.map(\.id) })
            capabilitySearchResults = capabilityIDs.compactMap { catalog.definition(for: $0) }.sorted { $0.name < $1.name }
            searchedCapabilities = !capabilitySearchResults.isEmpty
        }
    }

    private func runCapabilitySearch() {
        let query = capabilitySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchedCapabilities = false
            capabilitySearchResults = []
            return
        }
        capabilitySearchResults = CapabilityCatalog.shared.search(query, limit: 120)
        searchedCapabilities = true
    }

    private func capabilities(for skill: SkillSpec) -> [CapabilityDescriptor] {
        let explicit = SkillCapabilityLinkStore.shared.capabilities(forSkillID: skill.id)
        let inferredTools = skill.steps.map(\.action).filter {
            let lower = $0.lowercased()
            return lower != "talk" && lower != "ask"
        }
        var capabilityIDs = Set(explicit)
        for tool in inferredTools {
            if let capabilityID = CapabilityCatalog.shared.capabilityID(forTool: tool) {
                capabilityIDs.insert(capabilityID)
            }
        }
        return capabilityIDs.compactMap { CapabilityCatalog.shared.definition(for: $0) }.sorted { $0.name < $1.name }
    }

    private func capabilities(for package: SkillPackage) -> [CapabilityDescriptor] {
        let explicit = SkillCapabilityLinkStore.shared.capabilities(forSkillID: package.manifest.skillID)
        let inferredTools = package.plan.toolRequirements.map(\.name)
        var capabilityIDs = Set(explicit)
        for tool in inferredTools {
            if let capabilityID = CapabilityCatalog.shared.capabilityID(forTool: tool) {
                capabilityIDs.insert(capabilityID)
            }
        }
        return capabilityIDs.compactMap { CapabilityCatalog.shared.definition(for: $0) }.sorted { $0.name < $1.name }
    }

    private func openSkillEditor(_ result: SkillSearchResult) {
        let selectedCapabilityIDs = Set(result.capabilities.map(\.id))
        let draft = SkillEditorDraft(
            kind: result.kind,
            skillID: result.skillID,
            name: result.name,
            keywordsCSV: result.keywords.joined(separator: ", "),
            selectedCapabilityIDs: selectedCapabilityIDs,
            allCapabilities: CapabilityCatalog.shared.allCapabilities()
        )
        skillEditorDraft = draft
    }

    private func openCapabilityEditor(_ capability: CapabilityDescriptor) {
        let override = CapabilityMetadataStore.shared.override(for: capability.id)
        capabilityEditorDraft = CapabilityEditorDraft(
            capabilityID: capability.id,
            name: override?.name ?? capability.name,
            toolsCSV: (override?.tools ?? capability.tools).joined(separator: ", "),
            permissionsCSV: (override?.permissions ?? capability.permissions).joined(separator: ", "),
            keywordsCSV: (override?.keywords.isEmpty == false ? override?.keywords : capability.keywords)?.joined(separator: ", ") ?? ""
        )
    }

    private func saveSkillEdit(_ draft: SkillEditorDraft) {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let keywords = parseCSV(draft.keywordsCSV)
        let linkedCapabilities = Array(draft.selectedCapabilityIDs).sorted()

        switch draft.kind {
        case .legacy:
            guard let existing = SkillStore.shared.get(id: draft.skillID) else { return }
            var updated = SkillSpec(
                id: existing.id,
                name: name.isEmpty ? existing.name : name,
                version: existing.version,
                triggerPhrases: keywords.isEmpty ? existing.triggerPhrases : keywords,
                slots: existing.slots,
                steps: existing.steps,
                onTrigger: existing.onTrigger
            )
            updated.status = existing.status
            updated.approvedAt = existing.approvedAt
            updated.disabledAt = existing.disabledAt
            _ = SkillStore.shared.install(updated)

        case .package:
            guard var package = SkillStore.shared.getPackage(id: draft.skillID) else { return }
            if !name.isEmpty {
                package.manifest.name = name
                package.plan.name = name
            }
            if !keywords.isEmpty {
                package.plan.intentPatterns = keywords
            }
            var requirementsByTool: [String: SkillToolRequirement] = [:]
            for requirement in package.plan.toolRequirements {
                let mergedPermissions = Array(Set(requirement.permissions + ToolPermissionCatalog.requiredPermissions(for: requirement.name))).sorted()
                requirementsByTool[requirement.name] = SkillToolRequirement(name: requirement.name, permissions: mergedPermissions)
            }
            for capabilityID in linkedCapabilities {
                guard let capability = CapabilityCatalog.shared.definition(for: capabilityID) else { continue }
                for tool in capability.tools {
                    let existing = requirementsByTool[tool]
                    let mergedPermissions = Array(
                        Set((existing?.permissions ?? []) + capability.permissions + ToolPermissionCatalog.requiredPermissions(for: tool))
                    ).sorted()
                    requirementsByTool[tool] = SkillToolRequirement(name: tool, permissions: mergedPermissions)
                }
            }
            package.plan.toolRequirements = requirementsByTool.values.sorted { $0.name < $1.name }
            if var signoff = package.signoff {
                signoff.packageHash = SkillForgePipelineV2.packageHash(package)
                package.signoff = signoff
            }
            _ = SkillStore.shared.installPackage(package)
        }

        SkillCapabilityLinkStore.shared.setCapabilities(linkedCapabilities, forSkillID: draft.skillID)
        runSkillSearch()
        if searchedCapabilities {
            runCapabilitySearch()
        }
    }

    private func deleteSkill(_ draft: SkillEditorDraft) {
        switch draft.kind {
        case .legacy:
            _ = SkillStore.shared.remove(id: draft.skillID)
        case .package:
            _ = SkillStore.shared.removePackage(id: draft.skillID)
        }
        SkillCapabilityLinkStore.shared.remove(skillID: draft.skillID)
        runSkillSearch()
    }

    private func saveCapabilityEdit(_ draft: CapabilityEditorDraft) {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let tools = parseCSV(draft.toolsCSV)
        let permissions = parseCSV(draft.permissionsCSV)
        let keywords = parseCSV(draft.keywordsCSV)
        CapabilityMetadataStore.shared.saveOverride(
            capabilityID: draft.capabilityID,
            name: name.isEmpty ? nil : name,
            tools: tools.isEmpty ? nil : tools,
            permissions: permissions.isEmpty ? nil : permissions,
            keywords: keywords
        )
        runCapabilitySearch()
        if searchedSkills {
            runSkillSearch()
        }
    }

    private func parseCSV(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
            LabeledContent("Semantic Episodes") {
                Text("\(semanticEpisodes.count)")
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

            if semanticEpisodes.isEmpty {
                Text("No semantic episodes yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Episodes")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)

                ForEach(semanticEpisodes.prefix(10), id: \.id) { episode in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(episode.payload.title)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(SemanticMemoryStore.localDayString(episode.updatedAt))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Text(episode.payload.summary)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                        HStack {
                            Button("View") {
                                selectedSemanticEpisodeID = episode.id
                                semanticEpisodeExport = SemanticMemoryPipeline.shared.exportEpisodeJSON(id: episode.id) ?? ""
                            }
                            .buttonStyle(.borderless)

                            Button("Export JSON") {
                                semanticEpisodeExport = SemanticMemoryPipeline.shared.exportEpisodeJSON(id: episode.id) ?? ""
                            }
                            .buttonStyle(.borderless)

                            Button("Delete", role: .destructive) {
                                _ = SemanticMemoryPipeline.shared.deleteEpisode(id: episode.id)
                                reloadSemanticEpisodes()
                            }
                            .buttonStyle(.borderless)

                            Spacer()

                            Text("conf \(String(format: "%.2f", episode.payload.confidence))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if !semanticEpisodeExport.isEmpty {
                Text("Episode JSON Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                TextEditor(text: $semanticEpisodeExport)
                    .font(.caption.monospaced())
                    .frame(minHeight: 120, maxHeight: 180)
            }

            HStack {
                Button("Refresh") {
                    reloadMemories()
                    reloadSemanticEpisodes()
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("Clear All Memories", role: .destructive) {
                    showClearConfirmation = true
                }
                .confirmationDialog("Clear all memories?", isPresented: $showClearConfirmation) {
                    Button("Clear All", role: .destructive) {
                        MemoryStore.shared.clearMemories()
                        SemanticMemoryPipeline.shared.clearForTesting()
                        reloadMemories()
                        reloadSemanticEpisodes()
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

    private func reloadSemanticEpisodes() {
        semanticEpisodes = SemanticMemoryPipeline.shared.listEpisodes(limit: 80)
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

private enum SkillSearchKind: String, Codable {
    case legacy
    case package

    var label: String {
        switch self {
        case .legacy: return "Legacy Skill"
        case .package: return "JSON Skill"
        }
    }
}

private struct SkillSearchResult: Identifiable {
    var kind: SkillSearchKind
    var skillID: String
    var name: String
    var keywords: [String]
    var capabilities: [CapabilityDescriptor]

    var id: String { "\(kind.rawValue)#\(skillID)" }
}

private struct SkillEditorDraft: Identifiable {
    var kind: SkillSearchKind
    var skillID: String
    var name: String
    var keywordsCSV: String
    var selectedCapabilityIDs: Set<String>
    var allCapabilities: [CapabilityDescriptor]

    var id: String { "\(kind.rawValue)#\(skillID)" }
}

private struct CapabilityEditorDraft: Identifiable {
    var capabilityID: String
    var name: String
    var toolsCSV: String
    var permissionsCSV: String
    var keywordsCSV: String

    var id: String { capabilityID }
}

private struct SkillEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SkillEditorDraft
    let onSave: (SkillEditorDraft) -> Void
    let onDelete: (SkillEditorDraft) -> Void

    init(draft: SkillEditorDraft,
         onSave: @escaping (SkillEditorDraft) -> Void,
         onDelete: @escaping (SkillEditorDraft) -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Skill")
                .font(.title3.weight(.semibold))

            Text("ID: \(draft.skillID)")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("Skill name", text: $draft.name)
                .textFieldStyle(.roundedBorder)

            TextField("Invocation keywords (comma-separated)", text: $draft.keywordsCSV)
                .textFieldStyle(.roundedBorder)

            Text("Linked capabilities")
                .font(.subheadline.weight(.semibold))

            if draft.allCapabilities.isEmpty {
                Text("No capabilities available.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(draft.allCapabilities, id: \.id) { capability in
                            Toggle(isOn: Binding(
                                get: { draft.selectedCapabilityIDs.contains(capability.id) },
                                set: { selected in
                                    if selected {
                                        draft.selectedCapabilityIDs.insert(capability.id)
                                    } else {
                                        draft.selectedCapabilityIDs.remove(capability.id)
                                    }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(capability.name)
                                    Text(capability.id)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            HStack {
                Button("Delete Skill", role: .destructive) {
                    onDelete(draft)
                    dismiss()
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 420)
    }
}

private struct CapabilityEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CapabilityEditorDraft
    let onSave: (CapabilityEditorDraft) -> Void

    init(draft: CapabilityEditorDraft, onSave: @escaping (CapabilityEditorDraft) -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Capability")
                .font(.title3.weight(.semibold))

            Text("ID: \(draft.capabilityID)")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("Capability name", text: $draft.name)
                .textFieldStyle(.roundedBorder)

            TextField("Tools (comma-separated)", text: $draft.toolsCSV)
                .textFieldStyle(.roundedBorder)

            TextField("Permissions (comma-separated)", text: $draft.permissionsCSV)
                .textFieldStyle(.roundedBorder)

            TextField("Keywords (comma-separated)", text: $draft.keywordsCSV)
                .textFieldStyle(.roundedBorder)

            Text("Capabilities are shared and deduplicated. Skills link to these capabilities instead of cloning them.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 540, minHeight: 320)
    }
}
