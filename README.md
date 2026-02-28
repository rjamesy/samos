# SamOS v2

A voice-first macOS AI assistant with real personality, long-term memory, computer vision, and 70+ tools. Sam is a conversational companion that sees, hears, remembers, learns, and speaks — not just a chatbot.

Built natively in Swift with zero external package managers. macOS 14.0+ (Sonoma).

## What Sam Can Do

**Talk naturally** — Sam has a real personality with moods, opinions, and humor. Responses are concise, spoken aloud via ElevenLabs or OpenAI TTS, with sub-1s perceived latency through streaming sentence-pipelined speech.

**Remember everything** — Hybrid memory system combining BM25 keyword search, OpenAI `text-embedding-3-small` vector search, and recency decay. Facts persist for a year, preferences for a year, notes for 90 days. Identity facts are always injected into every prompt.

**See the world** — Live camera feed processed through Apple Vision framework for object classification, face detection, emotion reading, and face enrollment. Complex scenes escalated to GPT-4o vision.

**Learn from the web** — Fetches and summarizes web pages, stores highlights in SQLite. Autonomous research mode explores topics across multiple sources.

**Manage your day** — Real alarm and timer scheduling, Gmail integration (read, reply, trash, organize), and proactive awareness that injects relevant context.

**Forge new skills** — GPT-powered skill creation pipeline: plan, build, validate, simulate, approve, install. Dual approval (GPT + user) before any skill goes live.

**Listen always** — Porcupine wake word detection ("Hey Sam") with SFSpeechRecognizer fallback. OpenAI Whisper STT for accurate transcription. Follow-up capture after Sam asks a question.

## Architecture

```
Voice/Text Input
       |
  AppState.send()
       |
  TurnOrchestrator ──── MemoryInjector (identity facts + hybrid search)
       |                 PromptBuilder (32K budget-aware assembly)
       |                 EngineScheduler (13 cognitive engines)
       |
  OpenAI GPT-4o ──────── Native function calling (tools API)
       |                  SSE streaming (AsyncThrowingStream)
       |                  Structured JSON outputs
       |
  ResponseParser / ToolCalls
       |
  PlanExecutor ────────── ToolRegistry (70 tools, 145+ aliases)
       |
  TurnResult
       |
  TTSService ──────────── ElevenLabs (primary) / OpenAI TTS (fallback)
       |                   Sentence-pipelined streaming
       |
  Voice Output
```

### Frozen Design Principles (v1.0)

These rules are immutable:

- **Speech is success** — If the LLM returns a TALK action, accept it. Never reject a correct answer because a tool "could have been used."
- **No tool enforcement** — Tools are required only for side effects (alarms, memory writes). For questions, TALK is always valid.
- **No semantic classifiers** — No "if question is X, use tool Y" logic.
- **Max 1 retry per provider** — No repair loops, no provider ping-pong.
- **Minimal validation** — Only reject responses that aren't valid JSON or are empty.

### Turn Pipeline

1. **AppState** receives user input (text or voice transcription)
2. **TurnOrchestrator** assembles context: memory block, engine context, tool manifest, conversation history, proactive/ambient context
3. **PromptBuilder** constructs the system prompt within a 32K character budget, stripping lowest-priority blocks first
4. **OpenAI GPT-4o** generates a response — either streamed (SSE) or blocking
5. **ResponseParser** extracts Plan steps, or native `tool_calls` bypass parsing entirely
6. **PlanExecutor** walks steps sequentially: executes tools, queues speech
7. **TTSService** speaks the response — sentence-pipelined when streaming is enabled
8. Post-turn hooks: **MemoryAutoSave** extracts facts, **SemanticMemoryEngine** compresses episodes

### Dependency Injection

`AppContainer` wires all services with protocol-typed dependencies. No singletons in production code. Tests use `MockLLMClient`, `MockMemoryStore`, `MockSettingsStore`, etc.

```swift
let container = await AppContainer.createDefault()
// container.orchestrator, container.ttsService, container.memoryStore, ...
```

## Tools (70 registered)

| Category | Tools | Count |
|----------|-------|-------|
| **Core** | show_text, show_image, show_asset_image, list_assets, find_files | 5 |
| **Search** | find_image, find_video, find_recipe | 3 |
| **Info** | get_time, get_weather, news.fetch, movies.showtimes, fishing.report, price.lookup | 6 |
| **Memory** | save_memory, list_memories, delete_memory, clear_memories, recall_ambient | 5 |
| **Scheduling** | schedule_task, cancel_task, list_tasks, timer.manage | 4 |
| **Camera** | describe_camera_view, camera_visual_qa, camera_gpt_vision, find_camera_objects, camera_face_presence, enroll_camera_face, recognize_camera_faces, detect_emotions, camera_inventory_snapshot, save_camera_memory_note | 10 |
| **Email** | gmail_auth, gmail_read_inbox, gmail_send_reply, gmail_draft_reply, gmail_trash, gmail_mark_read, gmail_unsubscribe, gmail_classify, gmail_organize_inbox, gmail_organize_stop | 10 |
| **Learning** | learn_website, autonomous_learn, stop_autonomous_learn | 3 |
| **Skills** | start_skill_forge, forge_queue_status, forge_queue_clear, skills_learn_start, skills_learn_status, skills_learn_cancel, skills_learn_approve, skills_learn_install, skills_list, skills_run_sim, skills_reset_baseline, skills_learn_request_changes, capability_gap_to_claude_prompt | 13 |

All tools support **alias normalization** — the LLM can say "weather", "get_weather", "getWeather", or "get weather" and it resolves correctly. 145+ aliases mapped.

Tools with **native function calling schemas** (bypass text manifest, use OpenAI `tools` API parameter): `get_time`, `get_weather`, `save_memory`, `schedule_task`, `learn_website`.

## Intelligence Engines

12 cognitive engines run in the background (max 3 concurrent, serialized via `EngineScheduler`):

| Engine | Purpose |
|--------|---------|
| CognitiveTrace | Tracks reasoning chains and decision paths |
| LivingWorldModel | Maintains a dynamic model of the user's world |
| ActiveCuriosity | Generates follow-up questions and exploration topics |
| SkillEvolution | Evolves and improves learned skills over time |
| LongitudinalPattern | Detects patterns across long time spans |
| Personality | Manages Sam's mood, tone, and personality shifts |
| Counterfactual | Explores "what if" scenarios for better reasoning |
| TheoryOfMind | Models the user's mental state and intentions |
| MetaCognition | Self-reflects on Sam's own reasoning quality |
| NarrativeCoherence | Maintains story continuity across conversations |
| CausalLearning | Learns cause-and-effect relationships |
| BehaviorPattern | Detects user behavioral patterns (9 types) |

## Memory System

### Storage
- **SQLite** with WAL mode, FTS5 full-text search
- **4 memory types**: Facts (365d TTL), Preferences (365d), Notes (90d), Check-ins (7d)
- **Profile facts**: Key-value identity attributes (name, location, pets, job) with confidence scores
- **Embeddings**: 1536-dim vectors stored as BLOBs, generated via `text-embedding-3-small`

### Retrieval
**Hybrid search** combining three signals:
- **BM25** (0.4 weight) — keyword relevance via simplified TF-IDF
- **Cosine similarity** (0.4 weight) — semantic matching via embeddings
- **Recency** (0.2 weight) — exponential decay with 30-day half-life

Falls back to keyword-only when embeddings are unavailable.

### Auto-extraction
`MemoryAutoSave` detects patterns in user messages:
- Explicit: "remember that...", "note that...", "don't forget..."
- Implicit facts: "my name is...", "I live in...", "my dog..."
- Preferences: "I prefer...", "I love...", "my favorite..."

Deduplication via Jaccard similarity (>0.80 threshold).

## Speech Pipeline

```
Wake Word (Porcupine "Hey Sam")
       |
  Audio Capture (VAD + ring buffer)
       |
  Whisper STT (OpenAI API)
       |
  TurnOrchestrator
       |
  TTS: ElevenLabs (primary) → OpenAI TTS (fallback)
       |
  Streaming: tokens → sentence buffer → synthesize per sentence → play back-to-back
```

- **Wake word**: Porcupine v4 with custom "Hey Sam" model, SFSpeechRecognizer fallback
- **STT**: OpenAI Whisper API (`whisper-1` model)
- **TTS**: ElevenLabs Turbo v2 (primary), OpenAI `tts-1` with "nova" voice (fallback)
- **Streaming TTS**: Tokens accumulate until sentence boundary (`.!?\n`), each sentence synthesized and played independently for sub-1s perceived latency

## Vision Pipeline

```
AVCaptureSession → CVPixelBuffer
       |
  VisionProcessor ─── VNClassifyImageRequest (object classification)
       |               VNDetectFaceRectanglesRequest (face detection)
       |               VNDetectFaceLandmarksRequest (emotion detection)
       |               VNGenerateImageFeaturePrintRequest (face enrollment)
       |               VNRecognizeTextRequest (OCR)
       |
  EmotionDetector ─── Geometric classifier from facial landmarks
       |
  GPTVisionClient ─── GPT-4o vision for complex scene analysis
       |
  FaceEnrollment ──── Feature print storage and recognition
```

## OpenAI Integration

- **Chat Completions**: GPT-4o with structured JSON output
- **SSE Streaming**: `session.bytes(for:)` → parse `data:` lines → yield tokens via `AsyncThrowingStream`
- **Native Function Calling**: Tools with `ToolSchema` are passed via the `tools` API parameter. LLM returns `tool_calls` directly — no text parsing needed.
- **Whisper STT**: `POST /v1/audio/transcriptions` with multipart form data
- **TTS**: `POST /v1/audio/speech` with `tts-1` model
- **Embeddings**: `POST /v1/embeddings` with `text-embedding-3-small` (1536-dim), LRU cache (200 entries)

## Project Structure

```
SamOSv2/
  Core/
    AppContainer.swift          DI container — wires all services
    AppState.swift              @Observable state, chat, voice callbacks
    Configuration.swift         AppConfig constants and budgets
  Domain/
    Models/                     Action, Plan, ChatMessage, MemoryRow, OutputItem, etc.
    Protocols/                  LLMClient, MemoryStoreProtocol, ToolProtocol, etc.
    Errors/                     SamErrors (LLM, TTS, STT, Skill errors)
  Services/
    Pipeline/                   TurnOrchestrator, PlanExecutor, IntentClassifier, etc.
    LLM/                        OpenAIClient, OpenAIEmbeddingClient, PromptBuilder, ResponseParser
    Memory/                     MemoryStore, MemorySearch, MemoryInjector, MemoryAutoSave
    Speech/                     TTSService, STTService, WakeWordService, VoicePipeline
    Vision/                     CameraService, VisionProcessor, EmotionDetector, FaceEnrollment
    Tools/                      ToolRegistry + all tool implementations (10 files)
    Engines/                    12 intelligence engines + EngineScheduler
    Skills/                     SkillForge, SkillStore, SkillEngine
    Scheduling/                 TaskScheduler, AlarmSession
    Email/                      GmailClient, GoogleAuthService
    Web/                        WebLearningService, AutonomousResearchService
    Ambient/                    ProactiveAwareness, AmbientListeningService
    Persistence/                DatabaseManager, ChatHistoryStore, DebugLogStore
  Views/                        MainView, ChatPaneView, SettingsView, DebugPanelView, etc.
  Vendor/Porcupine/             Wake word detection (vendored dylib)
SamOSv2Tests/                   137 tests across 19 test classes
```

## Building

```bash
# Build
xcodebuild -project SamOSv2.xcodeproj -scheme SamOSv2 -configuration Debug build

# Test (137 tests)
xcodebuild -project SamOSv2.xcodeproj -scheme SamOSv2 -configuration Debug test
```

Requirements:
- macOS 14.0+ (Sonoma)
- Xcode 16.0+
- Swift 5.9
- No CocoaPods, no SPM — only Apple frameworks + vendored Porcupine binary

### API Keys Required

| Service | Setting Key | Purpose |
|---------|------------|---------|
| OpenAI | `openai_api_key` | LLM, STT, TTS fallback, embeddings |
| ElevenLabs | `elevenlabs_api_key` | Primary TTS (optional — falls back to OpenAI) |
| Picovoice | `picovoice_api_key` | Porcupine wake word (optional — falls back to SFSpeech) |
| Google OAuth | `google_client_id` | Gmail integration (optional) |

## Stats

| Metric | Value |
|--------|-------|
| Swift files | 122 |
| Lines of code | 12,145 |
| Registered tools | 70 |
| Tool aliases | 145+ |
| Intelligence engines | 12 |
| Test classes | 19 |
| Tests | 137 |
| Memory types | 4 |
| SQLite tables | 15 |
| Entitlements | Audio, Camera, Network, Files |

## License

Private repository. All rights reserved.
