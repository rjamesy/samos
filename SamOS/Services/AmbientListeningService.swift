import AVFoundation
import Foundation

/// Passive ambient listening service.
/// Receives audio from WakeWordService's tap, detects speech via lightweight VAD,
/// chunks speech segments, transcribes via Whisper, categorizes via LLM,
/// and stores ALL overheard content into SemanticMemoryEngine.
/// Never triggers a response — learning only.
import Combine

@MainActor
final class AmbientListeningService: ObservableObject {

    static let shared = AmbientListeningService()

    // MARK: - State

    private(set) var isRunning = false

    /// Current audio level (0.0-1.0) for UI display. Updated every tap callback.
    @Published private(set) var audioLevel: Float = 0

    /// Count of stored ambient memories this session (for debug/UI)
    @Published private(set) var storedCount: Int = 0

    // MARK: - Pre-Speech Ring Buffer

    /// Circular buffer holding the last ~0.5s of audio BEFORE speech is detected.
    /// When speech starts, this is prepended so we never clip the beginning.
    private var ringBuffer: [Float] = []
    private var ringWriteIndex = 0
    private var ringCapacity = 0 // set in start() based on sample rate

    // MARK: - Audio Accumulation

    private var floatBuffer: [Float] = []
    private var hardwareSampleRate: Double = 48000
    private var speechDetected = false
    private var consecutiveSpeechFrames = 0
    private let minSpeechFrames = 1 // Single frame = immediate detection
    private var lastSpeechTime: Date?
    private var chunkStartTime: Date?

    // MARK: - Noise Floor Calibration

    private var noiseFloorDB: Float = -100
    private var calibrationFrameCount = 0
    private let calibrationFrameLimit = 10 // ~10 tap callbacks (~0.25s) — faster startup

    // MARK: - Chunking Parameters

    private let silenceTimeoutSeconds: TimeInterval = 1.5 // Shorter gap = tighter chunks
    private let maxChunkDurationSeconds: TimeInterval = 30
    private let minChunkSamples = 16000 // ~1s at 16kHz, ~0.33s at 48kHz — accept shorter

    // MARK: - Throttling

    private var lastChunkProcessedAt: Date?
    private let minChunkIntervalSeconds: TimeInterval = 2 // Reduced from 5 — faster throughput
    private var processingTaskCount = 0
    private let maxConcurrentProcessing = 3 // Increased from 2

    // MARK: - Services

    private let stt = STTService()
    private let llm: SemanticMemoryLLMClient = HybridSemanticMemoryLLMClient()

    private init() {}

    // MARK: - Public API

    func start() {
        guard !isRunning else { return }
        isRunning = true
        resetAccumulation()
        // Ring buffer: ~0.6s of pre-speech audio at hardware rate
        ringCapacity = Int(hardwareSampleRate * 0.6)
        ringBuffer = [Float](repeating: 0, count: ringCapacity)
        ringWriteIndex = 0
        floatBuffer.reserveCapacity(Int(hardwareSampleRate) * 35) // ~35s headroom
        try? stt.loadModel()
        #if DEBUG
        print("[AMBIENT] started (sensitive mode, ring buffer \(ringCapacity) samples)")
        #endif
    }

    func stop() {
        isRunning = false
        audioLevel = 0
        // If we have accumulated speech, try to finalize it
        if speechDetected && floatBuffer.count >= minChunkSamples {
            finalizeChunk()
        }
        resetAccumulation()
        #if DEBUG
        print("[AMBIENT] stopped (\(storedCount) memories stored this session)")
        #endif
    }

    /// Called from WakeWordService's audio tap. Buffer is at hardware format (Float32).
    /// MUST be lightweight — runs on the audio thread.
    nonisolated func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        let samples = UnsafeBufferPointer(start: floatData[0], count: count)
        let sampleArray = Array(samples)
        let sampleRate = buffer.format.sampleRate

        Task { @MainActor [weak self] in
            self?.handleAudioFrame(sampleArray, sampleRate: sampleRate)
        }
    }

    // MARK: - Ring Buffer

    /// Write samples into circular pre-speech buffer.
    private func writeToRingBuffer(_ samples: [Float]) {
        guard ringCapacity > 0 else { return }
        for sample in samples {
            ringBuffer[ringWriteIndex] = sample
            ringWriteIndex = (ringWriteIndex + 1) % ringCapacity
        }
    }

    /// Read the ring buffer contents in order (oldest to newest).
    private func drainRingBuffer() -> [Float] {
        guard ringCapacity > 0 else { return [] }
        var result = [Float]()
        result.reserveCapacity(ringCapacity)
        for i in 0..<ringCapacity {
            result.append(ringBuffer[(ringWriteIndex + i) % ringCapacity])
        }
        return result
    }

    // MARK: - VAD (more sensitive than AudioCaptureService for ambient)

    private func handleAudioFrame(_ samples: [Float], sampleRate: Double) {
        guard isRunning else { return }
        hardwareSampleRate = sampleRate
        let count = samples.count

        // Fast RMS in dB
        var sumSquares: Float = 0
        for s in samples { sumSquares += s * s }
        let rms = sqrtf(sumSquares / Float(count))
        let rmsDB: Float = rms > 0 ? 20 * log10f(rms) : -100

        // Update audio level for UI (normalize RMS dB to 0.0-1.0 range)
        // -60dB = silence (0.0), -10dB = loud (1.0)
        let normalized = max(0, min(1, (rmsDB + 60) / 50))
        audioLevel = audioLevel * 0.6 + normalized * 0.4 // Smooth

        // Peak and ZCR
        var peak: Float = 0
        var zeroCrossings = 0
        var prev = samples[0]
        for i in 0..<count {
            let magnitude = abs(samples[i])
            if magnitude > peak { peak = magnitude }
            if i > 0 {
                let curr = samples[i]
                if (prev >= 0 && curr < 0) || (prev < 0 && curr >= 0) {
                    zeroCrossings += 1
                }
                prev = curr
            }
        }
        let zcr = Float(zeroCrossings) / Float(max(1, count - 1))

        // Always write to ring buffer when not in speech (pre-speech capture)
        if !speechDetected {
            writeToRingBuffer(samples)
        }

        // Noise floor calibration (first ~0.25s)
        if calibrationFrameCount < calibrationFrameLimit {
            calibrationFrameCount += 1
            if noiseFloorDB <= -99 {
                noiseFloorDB = rmsDB
            } else {
                noiseFloorDB = (noiseFloorDB * 0.85) + (rmsDB * 0.15)
            }
            return // Don't process during calibration
        }

        // Continuously update noise floor (slow adaptation)
        if !speechDetected {
            noiseFloorDB = (noiseFloorDB * 0.97) + (rmsDB * 0.03)
        }

        // Dynamic threshold — MORE SENSITIVE than main pipeline
        let adaptiveFloor = min(Float(-35), noiseFloorDB + 6) // Lower floor (-35 vs -30), smaller margin (6 vs 8)
        let effectiveThreshold = max(M2Settings.silenceThresholdDB - 4, adaptiveFloor) // 4dB more sensitive
        let marginOverNoise = rmsDB - noiseFloorDB

        // Relaxed speech detection: lower peak, lower margin, wider ZCR
        let speechCandidate =
            rmsDB > effectiveThreshold
            && peak > 0.004 // Halved from 0.009
            && marginOverNoise > 2 // Lowered from 3
            && zcr > 0.002 // Lowered from 0.004
            && zcr < 0.50 // Widened from 0.45

        if speechCandidate {
            consecutiveSpeechFrames += 1
            if !speechDetected && consecutiveSpeechFrames >= minSpeechFrames {
                speechDetected = true
                chunkStartTime = Date()
                // Prepend ring buffer (pre-speech audio) so we don't clip the start
                let preSpeech = drainRingBuffer()
                floatBuffer.append(contentsOf: preSpeech)
                #if DEBUG
                print("[AMBIENT] speech detected, prepended \(preSpeech.count) pre-speech samples")
                #endif
            }
            lastSpeechTime = Date()
        } else {
            consecutiveSpeechFrames = 0
        }

        // Accumulate samples during speech
        if speechDetected {
            floatBuffer.append(contentsOf: samples)
        }

        // Check for chunk finalization
        if speechDetected {
            // Silence timeout
            if let lastSpeech = lastSpeechTime,
               Date().timeIntervalSince(lastSpeech) >= silenceTimeoutSeconds {
                finalizeChunk()
                return
            }
            // Max duration
            if let start = chunkStartTime,
               Date().timeIntervalSince(start) >= maxChunkDurationSeconds {
                finalizeChunk()
                return
            }
        }
    }

    // MARK: - Chunk Finalization

    private func finalizeChunk() {
        guard floatBuffer.count >= minChunkSamples else {
            resetAccumulation()
            return
        }

        // Throttle: skip if too soon after last chunk
        if let last = lastChunkProcessedAt,
           Date().timeIntervalSince(last) < minChunkIntervalSeconds {
            resetAccumulation()
            return
        }

        // Backpressure: skip if too many in flight
        guard processingTaskCount < maxConcurrentProcessing else {
            resetAccumulation()
            return
        }

        let samples = floatBuffer
        let hwRate = hardwareSampleRate
        resetAccumulation()
        lastChunkProcessedAt = Date()
        processingTaskCount += 1

        #if DEBUG
        let durationSec = Double(samples.count) / hwRate
        print("[AMBIENT] finalizing chunk: \(String(format: "%.1f", durationSec))s, \(samples.count) samples")
        #endif

        Task { [weak self] in
            defer { Task { @MainActor in self?.processingTaskCount -= 1 } }
            await self?.processChunk(samples: samples, hardwareSampleRate: hwRate)
        }
    }

    private func resetAccumulation() {
        floatBuffer.removeAll(keepingCapacity: true)
        speechDetected = false
        consecutiveSpeechFrames = 0
        lastSpeechTime = nil
        chunkStartTime = nil
    }

    // MARK: - Chunk Processing Pipeline

    private func processChunk(samples: [Float], hardwareSampleRate: Double) async {
        // 1. Convert to 16kHz WAV (reuse AudioCaptureService's offline converter)
        let hwFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hardwareSampleRate,
            channels: 1,
            interleaved: false
        )

        let wavURL: URL
        do {
            wavURL = try AudioCaptureService.writeWAVOffline(samples: samples, hardwareFormat: hwFormat)
        } catch {
            #if DEBUG
            print("[AMBIENT] WAV conversion failed: \(error)")
            #endif
            return
        }

        // 2. Transcribe
        let transcript: String
        do {
            transcript = try await stt.transcribe(wavURL: wavURL)
        } catch {
            #if DEBUG
            print("[AMBIENT] transcription failed: \(error)")
            #endif
            return
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        #if DEBUG
        print("[AMBIENT] transcript: \"\(trimmed.prefix(100))\"")
        #endif

        // 3. Filter only obvious garbage — accept everything else
        guard trimmed.count >= 8 else { return } // Lowered from 20 — accept short phrases
        guard !isGarbage(trimmed) else { return }

        // 4. Categorize via LLM (importance scoring still runs but doesn't gate storage)
        let categorization = await categorizeAmbient(transcript: trimmed)

        #if DEBUG
        print("[AMBIENT] category=\(categorization.category) importance=\(String(format: "%.2f", categorization.importance)) for: \"\(trimmed.prefix(60))\"")
        #endif

        // 5. Store EVERYTHING that passes garbage filter — storage is cheap
        await storeAmbientMemory(
            transcript: trimmed,
            importance: categorization.importance,
            category: categorization.category
        )
    }

    // MARK: - Filtering (only removes true garbage)

    private func isGarbage(_ text: String) -> Bool {
        let lower = text.lowercased()

        // Whisper hallucination patterns
        let hallucinations = [
            "[music]", "(music)", "[blank_audio]", "[silence]",
            "thank you for watching", "subscribe", "please like",
            "[applause]", "[laughter]", "thanks for watching",
            "the end", "you", "bye", "no."
        ]
        for pattern in hallucinations {
            if lower == pattern || lower.trimmingCharacters(in: .punctuationCharacters) == pattern {
                return true
            }
        }

        // Very short and all filler
        let words = lower.split(separator: " ")
        if words.count <= 2 { return true } // Need at least 3 words

        let fillerWords: Set<String> = [
            "um", "uh", "hmm", "huh", "oh", "ah", "eh",
            "like", "so", "well", "yeah", "yep", "nah",
            "okay", "ok", "right", "sure"
        ]
        let fillerCount = words.filter { fillerWords.contains(String($0)) }.count
        return Double(fillerCount) / Double(words.count) > 0.8 // Relaxed from 0.7
    }

    // MARK: - Categorization (replaces importance-gated scoring)

    private struct AmbientCategorization {
        let category: String
        let importance: Double
    }

    private func categorizeAmbient(transcript: String) async -> AmbientCategorization {
        let systemPrompt = """
        Categorize this overheard ambient speech and rate its importance for a personal knowledge base.
        Return ONLY valid JSON: {"category": "string", "importance": 0.0}

        Categories: "personal_info", "preference", "plan", "opinion", "story", "instruction", "observation", "social", "small_talk", "background_noise"

        Importance scale (be GENEROUS — lean toward storing):
        0.1-0.2 = background noise, unintelligible fragments
        0.3-0.5 = casual conversation, small talk, general observations
        0.6-0.8 = preferences, plans, opinions, stories, instructions
        0.9-1.0 = names, important decisions, schedules, personal facts

        IMPORTANT: Default to 0.5 if unsure. Err on the side of higher importance.
        Most real human speech should score 0.4-0.8.
        """
        let userPrompt = "Speech: \"\(transcript.prefix(500))\""

        do {
            let raw = try await llm.completeJSON(systemPrompt: systemPrompt, userPrompt: userPrompt)
            guard let data = raw.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return AmbientCategorization(category: "uncategorized", importance: 0.5)
            }
            let category = (dict["category"] as? String) ?? "uncategorized"
            let score = (dict["importance"] as? NSNumber)?.doubleValue ?? 0.5
            return AmbientCategorization(
                category: category,
                importance: min(1.0, max(0.0, score))
            )
        } catch {
            #if DEBUG
            print("[AMBIENT] categorization failed: \(error)")
            #endif
            // Still store with default categorization
            return AmbientCategorization(category: "uncategorized", importance: 0.5)
        }
    }

    // MARK: - Memory Storage

    private func storeAmbientMemory(transcript: String, importance: Double, category: String) async {
        let store = SemanticMemoryStore.shared
        let sessionID = "ambient_\(Self.localDayString(Date()))"

        // Store raw message with ambient role
        let metaJSON = """
        {"source":"ambient","importance":\(String(format: "%.2f", importance)),"category":"\(category)"}
        """
        guard let messageID = store.appendMessage(
            role: .ambient,
            text: transcript,
            sessionID: sessionID,
            turnID: nil,
            metaJSON: metaJSON
        ) else {
            #if DEBUG
            print("[AMBIENT] failed to store message")
            #endif
            return
        }

        // Create episode tagged with category
        let payload = SemanticEpisodePayload(
            title: "Ambient [\(category)]: \(String(transcript.prefix(60)))",
            summary: transcript,
            entities: .empty,
            facts: .empty,
            decisions: [],
            actions: [],
            tags: ["ambient", category],
            importance: importance,
            confidence: 0.6
        )

        _ = store.upsertEpisode(
            id: nil,
            sessionID: sessionID,
            payload: payload,
            sourceMessageIDs: [messageID]
        )

        storedCount += 1

        #if DEBUG
        print("[AMBIENT] stored #\(storedCount): [\(category)] \"\(transcript.prefix(60))\" importance=\(String(format: "%.2f", importance))")
        #endif
    }

    // MARK: - Helpers

    private static func localDayString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }
}
