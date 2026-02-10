# SamOS

A voice-first AI assistant for macOS. Talk to Sam like a person — ask questions, set alarms, remember things, search the web, learn new skills, and see through your camera. Built with SwiftUI, powered by OpenAI and local LLMs.

> *Conversation first. Tools second. Perfection never.*

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.0-orange) ![License](https://img.shields.io/badge/license-MIT-green)

---

## What Sam Can Do

### Voice Conversation
- **"Hey Sam"** wake word activates the microphone (Porcupine)
- **Speech-to-text** via bundled Whisper model (local, private) or OpenAI Realtime streaming
- **Text-to-speech** via ElevenLabs with audio caching and queue-based playback
- **Follow-up listening** — mic reopens after Sam speaks, no wake word needed
- **Barge-in** — interrupt Sam mid-sentence by saying "Hey Sam"
- **Text input** — type in the chat pane as an alternative to voice

### Dual LLM Routing
- **OpenAI** (primary) — GPT-4o-mini with structured JSON output
- **Ollama** (local fallback) — any local model, no internet required
- Adaptive token budget based on query complexity
- Sub-500ms target for basic questions

### Persistent Memory
- **Auto-save** — Sam detects and remembers facts, preferences, and notes from conversation automatically
- **4 memory types** — Facts (365d), Preferences (365d), Notes (90d), Check-ins (7d)
- **Smart deduplication** — detects near-duplicates, refinements, and high-value replacements
- **Hybrid search** — semantic similarity + BM25 lexical matching + recency boost
- 1,000 memory cap with automatic expiry and daily pruning

### Alarms & Scheduling
- **Set alarms** — "Wake me at 7am" or "Set an alarm for 3pm"
- **Set timers** — "Timer for 5 minutes"
- **Alarm cards** — orange interactive card with Dismiss/Snooze buttons
- **Voice wake-up loop** — Sam speaks until you acknowledge

### Camera & Computer Vision
- **Scene description** — "What do you see?"
- **Object search** — "Can you see my keys?"
- **Face detection** — "How many people are there?"
- **Face enrollment** — "Remember my face" (local recognition, no cloud)
- **Face recognition** — "Who is that?"
- **Visual Q&A** — "Is the door open?" or "What does that sign say?"
- **Inventory tracking** — snapshot what's visible and track changes over time
- **Camera memories** — save timestamped notes of what Sam sees

All vision runs locally via Apple's Vision framework — nothing leaves your Mac.

### Self-Learning Skills (SkillForge)
- **"Learn how to..."** — Sam builds new capabilities on demand
- **5-stage AI pipeline** — Draft, Refine, Review, Validate, Install
- Skills are JSON specs with trigger phrases, parameter slots, and executable steps
- Installed skills work like built-in tools — matched by intent and executed automatically

### Web Learning & Research
- **Learn a URL** — "Learn this article" fetches, summarizes, and indexes a webpage
- **Autonomous research** — "Research AI for 10 minutes" — Sam independently browses, reads, and saves findings
- Searches DuckDuckGo, Wikipedia, and HackerNews
- All learned content is available for future Q&A

### Search & Discovery
- **Image search** — "Find me a picture of a golden retriever"
- **Video search** — "Find a video about sourdough baking" (YouTube)
- **Recipe search** — "Find a recipe for pasta carbonara" (with ingredients and steps)
- **File search** — "Find my recent PDFs" (searches Downloads/Documents)

### Time & Weather
- **Time** — "What time is it in Tokyo?" (supports 400+ cities and IANA timezones)
- **Weather** — "What's the weather in Melbourne?" (current + 7-day forecast via Open-Meteo)

### Output Canvas
- Rich content display alongside the chat pane
- Renders markdown, images, interactive alarm cards
- Pagination, copy-all, and auto-scroll

### Self-Improvement
- **Behavioural self-learning** — Sam detects patterns (verbosity, clarity, follow-up habits) and adjusts
- **Knowledge attribution** — tracks what % of each answer came from local memory vs external AI
- Up to 120 behavioural lessons with confidence scoring

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Input                                                      │
│   "Hey Sam" (Porcupine) → AudioCapture → STT (Whisper)     │
│   Text field → direct input                                 │
├─────────────────────────────────────────────────────────────┤
│  Brain                                                      │
│   TurnOrchestrator                                          │
│   ├── Memory injection (MemoryStore + WebsiteLearning)      │
│   ├── Self-learning lessons                                 │
│   ├── OpenAI Router (primary) / Ollama Router (local)       │
│   └── Returns a Plan: [talk, tool, ask, delegate]           │
├─────────────────────────────────────────────────────────────┤
│  Execution                                                  │
│   PlanExecutor                                              │
│   ├── Tool calls → ToolsRuntime → ToolRegistry (30 tools)   │
│   ├── Skill calls → SkillEngine → slot filling → execution  │
│   └── Pending slots → follow-up question → resume           │
├─────────────────────────────────────────────────────────────┤
│  Output                                                     │
│   TTSService (ElevenLabs) → spoken response                 │
│   ChatPaneView → message bubbles with metadata              │
│   OutputCanvasView → markdown, images, alarm cards          │
├─────────────────────────────────────────────────────────────┤
│  Background Services                                        │
│   MemoryAutoSave · SelfLearning · TaskScheduler             │
│   SkillForge · AutonomousLearning · CameraVision            │
└─────────────────────────────────────────────────────────────┘
```

### Design Principles

Sam follows a strict architectural philosophy documented in [`ARCHITECTURE.md`](ARCHITECTURE.md):

- **Speech is success** — if Sam can speak an answer, it should. Tools are for side effects only.
- **No tool enforcement** — if the LLM answers a weather question conversationally, that's valid.
- **Minimal validation** — only reject responses that aren't valid JSON or are empty.
- **No semantic classifiers** — no "if question is X, use tool Y" logic.
- **Max 1 retry per provider** — no repair loops, no provider ping-pong.

### Project Structure

```
SamOS/
├── SamOSApp.swift                  # App entry point
├── ARCHITECTURE.md                 # Design principles (frozen v1.0)
│
├── Models/                         # Data structures
│   ├── Action.swift                # LLM response actions (talk, tool, delegate, gap)
│   ├── Plan.swift                  # Multi-step execution plans
│   ├── ChatMessage.swift           # Conversation messages
│   ├── OutputItem.swift            # Canvas output (markdown, image, card)
│   ├── MemoryRow.swift             # Persistent memory entries
│   ├── SkillSpec.swift             # Learned skill definitions
│   ├── PendingSlot.swift           # Awaiting user input state
│   ├── SkillForgeJob.swift         # Active skill build tracking
│   └── ForgeQueueJob.swift         # Queued skill build jobs
│
├── Views/                          # SwiftUI interface
│   ├── MainView.swift              # Root layout (HSplitView)
│   ├── ChatPaneView.swift          # Conversation bubbles
│   ├── OutputCanvasView.swift      # Rich content display
│   ├── SettingsView.swift          # Configuration panel
│   └── StatusStripView.swift       # Bottom status bar
│
├── Services/                       # Core engine (~17K LOC)
│   ├── AppState.swift              # Central state (ObservableObject)
│   ├── TurnOrchestrator.swift      # The brain — routes and executes turns
│   ├── PlanExecutor.swift          # Step-by-step plan execution
│   ├── OpenAIRouter.swift          # OpenAI API integration
│   ├── OllamaRouter.swift          # Local LLM integration
│   ├── VoicePipelineCoordinator.swift  # Voice I/O state machine
│   ├── WakeWordService.swift       # "Hey Sam" detection (Porcupine)
│   ├── AudioCaptureService.swift   # Microphone recording
│   ├── STTService.swift            # Speech-to-text (Whisper/Realtime)
│   ├── TTSService.swift            # Text-to-speech orchestration
│   ├── ElevenLabsClient.swift      # ElevenLabs API client
│   ├── MemoryStore.swift           # SQLite persistent memory
│   ├── MemoryAutoSaveService.swift # Automatic memory extraction
│   ├── KnowledgeAttributionScorer.swift  # Local vs AI attribution
│   ├── SkillEngine.swift           # Skill matching and execution
│   ├── SkillForge.swift            # AI-powered skill building
│   ├── SkillForgeQueueService.swift    # Forge job queue
│   ├── SkillStore.swift            # Skill persistence
│   ├── TaskScheduler.swift         # Alarm/timer scheduling
│   ├── AlarmSession.swift          # Alarm state machine
│   ├── CameraVisionService.swift   # Apple Vision integration
│   ├── FaceProfileStore.swift      # Encrypted face data
│   ├── KeychainStore.swift         # Secure credential storage
│   └── TimezoneMapping.swift       # City → IANA timezone lookup
│
├── Tools/                          # Tool implementations
│   ├── ToolRegistry.swift          # 30 registered tools
│   ├── ToolsRuntime.swift          # Execution dispatcher
│   ├── MemoryTools.swift           # save/list/delete/clear memory
│   ├── SchedulerTools.swift        # schedule/cancel/list tasks
│   └── SkillForgeTools.swift       # start/status/clear forge
│
├── Utils/
│   └── TextUnescaper.swift         # LLM text normalization
│
└── Vendor/                         # Vendored dependencies
    ├── Porcupine/                  # Wake word engine
    └── Whisper/                    # Local STT model
```

### Tools Reference (30 Built-in)

| Category | Tool | Description |
|----------|------|-------------|
| **Display** | `show_text` | Render markdown on canvas |
| | `show_image` | Display remote image with fallbacks |
| **Search** | `find_image` | Google image search |
| | `find_video` | YouTube video search |
| | `find_recipe` | Recipe search with ingredients & steps |
| | `find_files` | Search Downloads/Documents by name/type |
| **Camera** | `describe_camera_view` | Describe the live scene |
| | `find_camera_objects` | Find specific objects in frame |
| | `get_camera_face_presence` | Detect faces |
| | `enroll_camera_face` | Enroll face for recognition |
| | `recognize_camera_faces` | Identify enrolled faces |
| | `camera_visual_qa` | Answer visual questions |
| | `camera_inventory_snapshot` | Track visible object changes |
| | `save_camera_memory_note` | Save camera observation to memory |
| **Memory** | `save_memory` | Save a fact, preference, note, or check-in |
| | `list_memories` | List saved memories |
| | `delete_memory` | Delete a memory by ID |
| | `clear_memories` | Clear all memories |
| **Scheduler** | `schedule_task` | Set alarm or timer |
| | `cancel_task` | Cancel scheduled task |
| | `list_tasks` | List pending tasks |
| **Learning** | `learn_website` | Learn from a URL |
| | `autonomous_learn` | Self-directed research session |
| | `stop_autonomous_learn` | Stop research session |
| **Info** | `get_time` | Current time / timezone conversion |
| | `get_weather` | Weather and forecast |
| **SkillForge** | `start_skillforge` | Queue a new skill to build |
| | `forge_queue_status` | Show forge queue state |
| | `forge_queue_clear` | Stop and clear forge queue |
| **Utility** | `capability_gap_to_claude_prompt` | Generate build prompt for missing capability |

---

## Requirements

- **macOS 14.0+** (Sonoma or later)
- **Xcode 15+**
- **OpenAI API key** (for primary LLM routing and SkillForge)
- **ElevenLabs API key** (for text-to-speech)
- **Porcupine access key** (for wake word detection)

### Optional
- **Ollama** installed locally (for offline/local LLM fallback)
- **YouTube API key** (for video search)

---

## Setup

1. **Clone the repository**
   ```bash
   git clone https://github.com/rjamesy/samos.git
   cd samos
   ```

2. **Open in Xcode**
   ```bash
   open SamOS.xcodeproj
   ```

3. **Build and run** (Cmd+R)

4. **Configure API keys** in Settings:
   - **OpenAI** — required for LLM routing
   - **ElevenLabs** — required for voice output
   - **Porcupine** — required for "Hey Sam" wake word

5. **Enable microphone and camera** when prompted

All API keys are stored securely in the macOS Keychain.

---

## Usage

### Voice
Say **"Hey Sam"** followed by your request:
- *"Hey Sam, what time is it in London?"*
- *"Hey Sam, set an alarm for 7am"*
- *"Hey Sam, what do you see?"*
- *"Hey Sam, remember that my dog's name is Bailey"*
- *"Hey Sam, find me a recipe for banana bread"*
- *"Hey Sam, learn how to control my smart lights"*

### Text
Type directly into the chat field at the bottom of the window.

### Settings
Click the gear icon or press **Cmd+,** to configure:
- LLM providers and models
- Voice and TTS settings
- Wake word sensitivity
- Camera toggle
- Auto-start preferences

---

## Tech Stack

| Component | Technology |
|-----------|------------|
| UI | SwiftUI |
| Language | Swift 5 |
| LLM (Primary) | OpenAI API (GPT-4o-mini) |
| LLM (Local) | Ollama (any model) |
| Wake Word | Porcupine (Picovoice) |
| Speech-to-Text | Whisper (local) / OpenAI Realtime |
| Text-to-Speech | ElevenLabs |
| Computer Vision | Apple Vision framework |
| Database | SQLite3 (WAL mode) |
| Secrets | macOS Keychain |
| Face Data | AES-GCM encrypted local storage |
| Weather | Open-Meteo API (free, no key) |

**No CocoaPods, no SPM** — only Apple frameworks + vendored binaries.

---

## Test Suite

25 test files (~9,900 lines) covering:

- LLM routing and response parsing
- Turn orchestration and plan execution
- Memory storage, deduplication, and retrieval
- Skill matching, slot extraction, and forge queue
- Scheduling, timezone handling, and alarm state
- Text unescaping and image parsing
- Knowledge attribution calibration
- Keychain and face profile storage

---

## Privacy

- **Wake word detection** runs locally (Porcupine)
- **Speech-to-text** runs locally by default (Whisper)
- **Computer vision** runs locally (Apple Vision) — no images leave your Mac
- **Face data** is AES-GCM encrypted on disk
- **Memories** are stored locally in SQLite
- **API keys** are stored in the macOS Keychain
- Only LLM routing, TTS, and web learning make network calls

---

## License

MIT

---

Built by [@rjamesy](https://github.com/rjamesy)
