import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

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
    @State private var useOllama: Bool = M2Settings.useOllama
    @State private var ollamaEndpoint: String = M2Settings.ollamaEndpoint
    @State private var ollamaModel: String = M2Settings.ollamaModel

    // Voice Output (ElevenLabs)
    @State private var elevenLabsApiKey: String = ElevenLabsSettings.apiKey
    @State private var elevenLabsVoiceId: String = ElevenLabsSettings.voiceId
    @State private var elevenLabsMuted: Bool = ElevenLabsSettings.isMuted
    @State private var elevenLabsStreaming: Bool = ElevenLabsSettings.useStreaming
    @State private var testVoiceInProgress: Bool = false

    // OpenAI (SkillForge)
    @State private var openaiApiKey: String = OpenAISettings.apiKey
    @State private var openaiModel: String = OpenAISettings.model

    // Memory
    @State private var memories: [MemoryRow] = []
    @State private var showClearConfirmation = false

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

            Form {
                // Show banner if listening was paused
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

                // MARK: - General

                Section("General") {
                    TextField("Your name", text: $userName, prompt: Text("Used in alarm greetings"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: userName) { _, newValue in
                            M2Settings.userName = newValue
                        }
                }

                // MARK: - Wake Word

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
                            && FileManager.default.fileExists(atPath: porcupineKeywordPath)
                        {
                            Text("Configured")
                                .foregroundColor(.green)
                        } else {
                            Text("Not configured")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // MARK: - STT

                Section("Speech-to-Text (Whisper)") {
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
                        if !whisperModelPath.isEmpty
                            && FileManager.default.fileExists(atPath: whisperModelPath)
                        {
                            Text("Configured")
                                .foregroundColor(.green)
                        } else {
                            Text("Not configured")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // MARK: - Audio Capture

                Section("Audio Capture") {
                    HStack {
                        Text("Silence threshold: \(Int(silenceThresholdDB)) dB")
                        Slider(value: $silenceThresholdDB, in: -60...(-20), step: 1)
                            .onChange(of: silenceThresholdDB) { _, newValue in
                                M2Settings.silenceThresholdDB = newValue
                            }
                    }

                    HStack {
                        Text("Silence duration: \(Int(silenceDurationMs)) ms")
                        Slider(value: $silenceDurationMs, in: 500...5000, step: 100)
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
                            Text("Granted")
                                .foregroundColor(.green)
                        case .denied:
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("Denied")
                                    .foregroundColor(.red)
                                Button("Open System Settings") {
                                    MicrophonePermission.openSystemSettings()
                                }
                                .font(.caption)
                            }
                        case .undetermined:
                            Text("Not yet requested")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // MARK: - Routing

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

                    LabeledContent("Status") {
                        if useOllama {
                            Text("Ollama (active)")
                                .foregroundColor(.green)
                        } else {
                            Text("Mock (active)")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // MARK: - Voice Output

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
                            // Reset after a few seconds
                            Task {
                                try? await Task.sleep(nanoseconds: 3_000_000_000)
                                testVoiceInProgress = false
                            }
                        }
                        .disabled(!ElevenLabsSettings.isConfigured || testVoiceInProgress)

                        if testVoiceInProgress {
                            ProgressView()
                                .scaleEffect(0.5)
                        }
                    }

                    LabeledContent("Status") {
                        if ElevenLabsSettings.isConfigured {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Configured")
                                    .foregroundColor(.green)
                                if let savedAt = ElevenLabsSettings.keySavedAt {
                                    Text("Key saved \(savedAt, style: .relative) ago")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        } else {
                            Text("API key required")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // MARK: - OpenAI (SkillForge)

                Section("OpenAI (SkillForge)") {
                    SecureField("API Key", text: $openaiApiKey)
                        .onChange(of: openaiApiKey) { _, newValue in
                            OpenAISettings.apiKey = newValue
                        }

                    TextField("Model", text: $openaiModel)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: openaiModel) { _, newValue in
                            OpenAISettings.model = newValue
                        }

                    LabeledContent("Status") {
                        if OpenAISettings.isConfigured {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Configured")
                                    .foregroundColor(.green)
                                if let savedAt = OpenAISettings.keySavedAt {
                                    Text("Key saved \(savedAt, style: .relative) ago")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        } else {
                            Text("API key required")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // MARK: - Security

                Section("Security") {
                    Toggle("Store API keys in Keychain (recommended)", isOn: $useKeychainStorage)
                        .onChange(of: useKeychainStorage) { _, newValue in
                            KeychainStore.useKeychain = newValue
                        }

                    Text(useKeychainStorage
                         ? "API keys are stored securely in the macOS Keychain."
                         : "API keys are kept in memory only and will be lost when the app quits.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // MARK: - Forge Queue

                Section("Forge Queue") {
                    let jobs = SkillForgeQueueService.shared.allJobs()
                    if jobs.isEmpty {
                        Text("No forge jobs")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(jobs) { job in
                            LabeledContent(job.goal) {
                                Text(job.status.rawValue)
                                    .foregroundColor(forgeStatusColor(job.status))
                                    .font(.caption)
                            }
                        }

                        if jobs.contains(where: { $0.status == .completed || $0.status == .failed }) {
                            Button("Clear Finished") {
                                SkillForgeQueueService.shared.clearFinished()
                            }
                        }
                    }

                    LabeledContent("Status") {
                        if SkillForgeQueueService.shared.isAvailable {
                            Text("SQLite (active)")
                                .foregroundColor(.green)
                        } else {
                            Text("Unavailable")
                                .foregroundColor(.red)
                        }
                    }
                }

                // MARK: - Installed Skills

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

                // MARK: - Memory

                Section("Memory") {
                    if memories.isEmpty {
                        Text("No memories saved yet")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(memories) { mem in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(mem.type.rawValue)
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(memoryTypeColor(mem.type).opacity(0.15))
                                            .foregroundColor(memoryTypeColor(mem.type))
                                            .cornerRadius(4)
                                        Text(mem.shortID)
                                            .font(.caption2.monospaced())
                                            .foregroundColor(.secondary)
                                    }
                                    Text(mem.content)
                                        .font(.callout)
                                    Text(mem.createdAt, style: .date)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    MemoryStore.shared.deleteMemory(idOrPrefix: mem.id.uuidString)
                                    reloadMemories()
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                            }
                        }

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

                    LabeledContent("Storage") {
                        Text(MemoryStore.shared.isAvailable ? "SQLite (active)" : "Unavailable")
                            .foregroundColor(MemoryStore.shared.isAvailable ? .green : .red)
                    }
                }

                // MARK: - Capabilities

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
            .formStyle(.grouped)
        }
        .frame(minWidth: 450, minHeight: 500)
        .onAppear {
            appState.pauseListeningForSettings()
            reloadMemories()
            installedSkills = SkillStore.shared.loadInstalled()
        }
        .onDisappear {
            appState.resumeListeningAfterSettings()
        }
    }

    // MARK: - Memory Helpers

    private func reloadMemories() {
        memories = MemoryStore.shared.listMemories()
    }

    private func forgeStatusColor(_ status: ForgeQueueJob.Status) -> Color {
        switch status {
        case .queued: return .secondary
        case .running: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }

    private func memoryTypeColor(_ type: MemoryType) -> Color {
        switch type {
        case .fact: return .blue
        case .preference: return .purple
        case .note: return .orange
        }
    }

    // MARK: - File Picker

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
