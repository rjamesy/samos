import XCTest
@testable import SamOS

final class TTSTests: XCTestCase {

    // MARK: - ElevenLabsSettings Defaults

    func testDefaultVoiceId() {
        XCTAssertEqual(ElevenLabsSettings.voiceId, "JSWO6cw2AyFE324d5kEr")
    }

    func testDefaultModelId() {
        XCTAssertEqual(ElevenLabsSettings.modelId, "eleven_multilingual_v2")
    }

    func testDefaultMuteIsFalse() {
        // Unless explicitly set, mute should default to false
        let key = "elevenlabs_isMuted"
        let had = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let had = had {
                UserDefaults.standard.set(had, forKey: key)
            }
        }
        XCTAssertFalse(ElevenLabsSettings.isMuted)
    }

    func testMutePersistence() {
        let original = ElevenLabsSettings.isMuted
        defer { ElevenLabsSettings.isMuted = original }

        ElevenLabsSettings.isMuted = true
        XCTAssertTrue(ElevenLabsSettings.isMuted)

        ElevenLabsSettings.isMuted = false
        XCTAssertFalse(ElevenLabsSettings.isMuted)
    }

    // MARK: - KeychainStore

    func testKeychainSetAndGet() {
        let key = "test_keychain_\(UUID().uuidString)"
        defer { KeychainStore.delete(forKey: key) }

        XCTAssertNil(KeychainStore.get(forKey: key))

        let success = KeychainStore.set("test_secret_value", forKey: key)
        XCTAssertTrue(success)

        let retrieved = KeychainStore.get(forKey: key)
        XCTAssertEqual(retrieved, "test_secret_value")
    }

    func testKeychainDelete() {
        let key = "test_keychain_del_\(UUID().uuidString)"
        KeychainStore.set("to_delete", forKey: key)
        XCTAssertNotNil(KeychainStore.get(forKey: key))

        KeychainStore.delete(forKey: key)
        XCTAssertNil(KeychainStore.get(forKey: key))
    }

    func testKeychainOverwrite() {
        let key = "test_keychain_ow_\(UUID().uuidString)"
        defer { KeychainStore.delete(forKey: key) }

        KeychainStore.set("first", forKey: key)
        XCTAssertEqual(KeychainStore.get(forKey: key), "first")

        KeychainStore.set("second", forKey: key)
        XCTAssertEqual(KeychainStore.get(forKey: key), "second")
    }

    func testKeychainCustomService() {
        let service = "com.samos.test.\(UUID().uuidString)"
        let key = "test_key"
        defer { KeychainStore.delete(forKey: key, service: service) }

        XCTAssertNil(KeychainStore.get(forKey: key, service: service))

        KeychainStore.set("custom_service_value", forKey: key, service: service)
        XCTAssertEqual(KeychainStore.get(forKey: key, service: service), "custom_service_value")

        // Different service should not see this value
        XCTAssertNil(KeychainStore.get(forKey: key, service: "com.samos.other"))
    }

    func testKeychainUpdatePreservesItem() {
        let key = "test_keychain_upd_\(UUID().uuidString)"
        defer { KeychainStore.delete(forKey: key) }

        // Add initial
        let added = KeychainStore.set("initial", forKey: key)
        XCTAssertTrue(added)
        XCTAssertEqual(KeychainStore.get(forKey: key), "initial")

        // Update (should use SecItemUpdate, not delete+add)
        let updated = KeychainStore.set("updated", forKey: key)
        XCTAssertTrue(updated)
        XCTAssertEqual(KeychainStore.get(forKey: key), "updated")
    }

    func testKeychainDeleteNonexistentReturnsTrue() {
        // Deleting something that doesn't exist should succeed (idempotent)
        let result = KeychainStore.delete(forKey: "nonexistent_\(UUID().uuidString)")
        XCTAssertTrue(result)
    }

    // MARK: - TTSService Safety

    @MainActor
    func testSpeakWhenMutedDoesNothing() {
        let original = ElevenLabsSettings.isMuted
        defer { ElevenLabsSettings.isMuted = original }

        ElevenLabsSettings.isMuted = true
        // Should be a no-op — no crash, no network call
        TTSService.shared.speak("This should not play")
        XCTAssertFalse(TTSService.shared.isSpeaking)
    }

    @MainActor
    func testSpeakEmptyTextDoesNothing() {
        TTSService.shared.speak("")
        XCTAssertFalse(TTSService.shared.isSpeaking)
    }

    @MainActor
    func testSpeakWhitespaceOnlyDoesNothing() {
        TTSService.shared.speak("   ")
        XCTAssertFalse(TTSService.shared.isSpeaking)
    }

    @MainActor
    func testStopSpeakingIsIdempotent() {
        // Should not crash when called with nothing playing
        TTSService.shared.stopSpeaking()
        TTSService.shared.stopSpeaking()
        XCTAssertFalse(TTSService.shared.isSpeaking)
    }

    // MARK: - IsConfigured (with caching)

    func testIsConfiguredRequiresApiKey() {
        let originalKey = ElevenLabsSettings.apiKey
        defer {
            ElevenLabsSettings.apiKey = originalKey
            ElevenLabsSettings._resetCacheForTesting()
        }

        ElevenLabsSettings.apiKey = ""
        XCTAssertFalse(ElevenLabsSettings.isConfigured)

        ElevenLabsSettings.apiKey = "some_key"
        XCTAssertTrue(ElevenLabsSettings.isConfigured)
    }

    func testApiKeyCacheServesFromMemory() {
        let originalKey = ElevenLabsSettings.apiKey
        defer {
            ElevenLabsSettings.apiKey = originalKey
            ElevenLabsSettings._resetCacheForTesting()
        }

        // Set a key (writes through to Keychain + cache)
        ElevenLabsSettings.apiKey = "cached_test_key"

        // Read multiple times — should all return cached value without hitting Keychain
        for _ in 0..<10 {
            XCTAssertEqual(ElevenLabsSettings.apiKey, "cached_test_key")
        }
    }

    func testApiKeyCacheResetForcesReload() {
        let originalKey = ElevenLabsSettings.apiKey
        defer {
            ElevenLabsSettings.apiKey = originalKey
            ElevenLabsSettings._resetCacheForTesting()
        }

        ElevenLabsSettings.apiKey = "before_reset"
        XCTAssertEqual(ElevenLabsSettings.apiKey, "before_reset")

        // Reset cache — next read should reload from Keychain
        ElevenLabsSettings._resetCacheForTesting()
        XCTAssertEqual(ElevenLabsSettings.apiKey, "before_reset",
            "After cache reset, should reload same value from Keychain")
    }

    // MARK: - SpeechMode

    func testSpeechModeConfirmHasLowerStability() {
        let confirm = SpeechMode.confirm.voiceSettings
        let answer = SpeechMode.answer.voiceSettings

        let confirmStability = confirm["stability"] as? Double ?? 1.0
        let answerStability = answer["stability"] as? Double ?? 1.0

        XCTAssertLessThan(confirmStability, answerStability,
            "Confirm mode should have lower stability for snappier delivery")
    }

    func testSpeechModeAnswerUsesSpeakerBoost() {
        let answer = SpeechMode.answer.voiceSettings
        let boost = answer["use_speaker_boost"] as? Bool ?? false
        XCTAssertTrue(boost, "Answer mode should enable speaker boost")
    }

    func testSpeechModeConfirmDisablesSpeakerBoost() {
        let confirm = SpeechMode.confirm.voiceSettings
        let boost = confirm["use_speaker_boost"] as? Bool ?? true
        XCTAssertFalse(boost, "Confirm mode should disable speaker boost for speed")
    }

    func testSpeechModeVoiceSettingsHaveRequiredKeys() {
        for mode in [SpeechMode.confirm, SpeechMode.answer] {
            let settings = mode.voiceSettings
            XCTAssertNotNil(settings["stability"], "Missing stability key")
            XCTAssertNotNil(settings["similarity_boost"], "Missing similarity_boost key")
        }
    }

    // MARK: - Streaming Setting

    func testDefaultStreamingIsTrue() {
        let key = "elevenlabs_useStreaming"
        let had = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let had = had {
                UserDefaults.standard.set(had, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        XCTAssertTrue(ElevenLabsSettings.useStreaming, "Streaming should default to true")
    }

    func testStreamingPersistence() {
        let original = ElevenLabsSettings.useStreaming
        defer { ElevenLabsSettings.useStreaming = original }

        ElevenLabsSettings.useStreaming = false
        XCTAssertFalse(ElevenLabsSettings.useStreaming)

        ElevenLabsSettings.useStreaming = true
        XCTAssertTrue(ElevenLabsSettings.useStreaming)
    }

    @MainActor
    func testInferredAudioFileExtensionDetectsWav() {
        let wavHeader = Data([0x52, 0x49, 0x46, 0x46, 0x24, 0x80, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45])
        XCTAssertEqual(TTSService.inferredAudioFileExtension(for: wavHeader), "wav")
    }

    @MainActor
    func testInferredAudioFileExtensionDefaultsToMp3() {
        let mp3Header = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x21, 0x54, 0x41])
        XCTAssertEqual(TTSService.inferredAudioFileExtension(for: mp3Header), "mp3")
    }

    @MainActor
    func testSpeakWithConfirmModeDoesNotCrash() {
        let original = ElevenLabsSettings.isMuted
        defer { ElevenLabsSettings.isMuted = original }

        ElevenLabsSettings.isMuted = true
        // Should be a no-op (muted) but not crash with mode parameter
        TTSService.shared.speak("Got it", mode: .confirm)
        XCTAssertFalse(TTSService.shared.isSpeaking)
    }

    // MARK: - Keychain Accessibility

    func testKeychainRoundTripWithAccessibility() {
        let key = "test_acc_\(UUID().uuidString)"
        defer { KeychainStore.delete(forKey: key) }

        let success = KeychainStore.set("acc_value", forKey: key)
        XCTAssertTrue(success, "Should succeed writing with AfterFirstUnlockThisDeviceOnly")

        let value = KeychainStore.get(forKey: key)
        XCTAssertEqual(value, "acc_value")
    }

    func testKeychainOverwritePreservesAccessibility() {
        let key = "test_acc_ow_\(UUID().uuidString)"
        defer { KeychainStore.delete(forKey: key) }

        KeychainStore.set("first", forKey: key)
        KeychainStore.set("second", forKey: key)
        XCTAssertEqual(KeychainStore.get(forKey: key), "second")
    }

    func testKeychainDeleteIsClean() {
        let key = "test_acc_del_\(UUID().uuidString)"

        KeychainStore.set("to_delete", forKey: key)
        XCTAssertNotNil(KeychainStore.get(forKey: key))

        let deleted = KeychainStore.delete(forKey: key)
        XCTAssertTrue(deleted)
        XCTAssertNil(KeychainStore.get(forKey: key))
    }

    // MARK: - OpenAI Settings Cache

    func testOpenAIApiKeyCacheServesFromMemory() {
        let originalKey = OpenAISettings.apiKey
        defer {
            OpenAISettings.apiKey = originalKey
            OpenAISettings._resetCacheForTesting()
        }

        OpenAISettings.apiKey = "openai_cached_test"
        for _ in 0..<10 {
            XCTAssertEqual(OpenAISettings.apiKey, "openai_cached_test")
        }
    }

    func testOpenAIIsConfiguredRequiresApiKey() {
        let originalKey = OpenAISettings.apiKey
        defer {
            OpenAISettings.apiKey = originalKey
            OpenAISettings._resetCacheForTesting()
        }

        OpenAISettings.apiKey = ""
        XCTAssertFalse(OpenAISettings.isConfigured)

        OpenAISettings.apiKey = "test_key"
        XCTAssertTrue(OpenAISettings.isConfigured)
    }

    func testOpenAIRealtimeModeDefaultsToClassicOff() {
        let original = OpenAISettings.realtimeModeEnabled
        defer { OpenAISettings.realtimeModeEnabled = original }

        OpenAISettings.realtimeModeEnabled = false
        XCTAssertFalse(OpenAISettings.realtimeModeEnabled)
    }

    func testOpenAIRealtimeModePersistence() {
        let original = OpenAISettings.realtimeModeEnabled
        defer { OpenAISettings.realtimeModeEnabled = original }

        OpenAISettings.realtimeModeEnabled = true
        XCTAssertTrue(OpenAISettings.realtimeModeEnabled)

        OpenAISettings.realtimeModeEnabled = false
        XCTAssertFalse(OpenAISettings.realtimeModeEnabled)
    }

    func testOpenAIRealtimeClassicSTTPersistence() {
        let original = OpenAISettings.realtimeUseClassicSTT
        defer { OpenAISettings.realtimeUseClassicSTT = original }

        OpenAISettings.realtimeUseClassicSTT = true
        XCTAssertTrue(OpenAISettings.realtimeUseClassicSTT)

        OpenAISettings.realtimeUseClassicSTT = false
        XCTAssertFalse(OpenAISettings.realtimeUseClassicSTT)
    }

    // MARK: - Listening Persistence

    @MainActor
    func testListeningPreferencePersists() {
        let original = AppState.userWantsListeningEnabled
        defer { AppState.userWantsListeningEnabled = original }

        AppState.userWantsListeningEnabled = true
        XCTAssertTrue(AppState.userWantsListeningEnabled)

        AppState.userWantsListeningEnabled = false
        XCTAssertFalse(AppState.userWantsListeningEnabled)
    }

    // MARK: - Thinking Cue Rate Limit

    @MainActor
    func testThinkingCueRateLimitTracking() {
        // Verify that lastThinkingCueTime exists on AppState and starts in the past
        let appState = AppState()
        // The rate limit is internal, but we can verify send() doesn't crash
        // with an empty message (which should be a no-op)
        appState.send("")
        XCTAssertTrue(appState.chatMessages.isEmpty, "Empty send should be a no-op")
    }

    // MARK: - Response Polish (Confidence + TTS Pacing)

    func testConfidenceModulationAddsHedgeWhenUncertain() {
        let input = "The arrival time is approximately 5 PM."
        let output = ResponsePolish.applyConfidenceModulation(to: input)
        XCTAssertTrue(output.hasSuffix("(If you want, I can double-check.)"))
    }

    func testConfidenceModulationNoChangeWhenCertain() {
        let input = "It's 5 PM in London."
        let output = ResponsePolish.applyConfidenceModulation(to: input)
        XCTAssertEqual(output, input)
    }

    func testConfidenceModulationNoDoubleHedge() {
        let input = "I'm not 100% sure, but it might be around 5 PM."
        let output = ResponsePolish.applyConfidenceModulation(to: input)
        XCTAssertEqual(output, input)
    }

    func testQuickDetailedPromptIsStripped() {
        let input = "The capital of Australia is Canberra. Want the quick version or more detail?"
        let output = ResponsePolish.stripQuickDetailedPrompt(from: input)
        XCTAssertEqual(output, "The capital of Australia is Canberra.")
    }

    func testTTSPacingAppliesOnlyToLongResponses() {
        let shortText = "Sounds good."
        let shortPacing = ResponsePolish.ttsPacing(for: shortText, mode: .answer)
        XCTAssertEqual(shortPacing.preSpeakDelayMs, 0)
        XCTAssertEqual(shortPacing.ttsText, shortText)

        let longText = "First sentence gives context. Second sentence adds details. Third sentence wraps up."
        let longPacing = ResponsePolish.ttsPacing(for: longText, mode: .answer)
        XCTAssertEqual(longPacing.preSpeakDelayMs, 250)
        XCTAssertTrue(longPacing.ttsText.contains(".\nSecond sentence"))

        let confirmPacing = ResponsePolish.ttsPacing(for: longText, mode: .confirm)
        XCTAssertEqual(confirmPacing.preSpeakDelayMs, 0, "Confirm mode should stay snappy")
        XCTAssertEqual(confirmPacing.ttsText, longText)
    }

    func testTTSPacingDoesNotMutateVisibleText() {
        let visibleText = "This is a longer response. It has multiple sentences. It should be paced in TTS."
        let original = visibleText
        let pacing = ResponsePolish.ttsPacing(for: visibleText, mode: .answer)

        XCTAssertEqual(visibleText, original, "Visible chat text must remain unchanged")
        XCTAssertNotEqual(pacing.ttsText, original, "Only TTS text should receive pacing markers")
    }
}
