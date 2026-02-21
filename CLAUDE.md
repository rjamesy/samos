# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Build (Xcode project, single scheme "SamOS")
xcodebuild -project SamOS.xcodeproj -scheme SamOS -configuration Debug build

# Run all unit tests
xcodebuild -project SamOS.xcodeproj -scheme SamOS -configuration Debug test

# Run a single test class
xcodebuild -project SamOS.xcodeproj -scheme SamOS -configuration Debug \
  test -only-testing:SamOSTests/TurnRouterTests

# Run a single test method
xcodebuild -project SamOS.xcodeproj -scheme SamOS -configuration Debug \
  test -only-testing:SamOSTests/TurnRouterTests/testSomeMethod

# Integration tests (requires Ollama running locally)
bash test_m3.sh

# sam-gateway (Python FastAPI service)
cd sam-gateway && pip install -r requirements.txt && uvicorn app.main:app
cd sam-gateway && pytest tests/
```

No CocoaPods or SPM — only Apple frameworks + vendored binaries (Porcupine, Whisper).

## Architecture Overview

SamOS is a voice-first macOS AI assistant. The core pipeline is:

```
Input (voice/text) → TurnOrchestrator → LLM Router → Plan → PlanExecutor → Output (TTS/UI)
```

### Frozen Design Principles (ARCHITECTURE.md)

These rules are **frozen v1.0** and must not be violated:

- **Speech is success** — if the LLM returns a TALK action, accept it unconditionally. Never reject a correct answer because a tool "could have been used."
- **No tool enforcement** — tools are required only for side effects (alarms, memory writes, etc.). For questions (time, weather, facts), TALK is always valid.
- **No semantic classifiers** — no "if question is X, use tool Y" logic. No question-type enforcement.
- **Max 1 retry per provider** — no repair loops, no provider ping-pong.
- **Minimal validation** — only reject responses that aren't valid JSON or are empty. Never validate tool usage or semantic correctness.

### Turn Pipeline

1. **TurnOrchestrator** (`Services/TurnOrchestrator.swift`) — the brain. Injects memory context, classifies intent, routes to LLM, returns a `TurnResult`.
2. **TurnRouter** (`Services/TurnRouter.swift`) — classifies intent (local Ollama first, OpenAI fallback), then routes to a plan provider. Uses handler closures, not direct service dependencies.
3. **OpenAIRouter** / **OllamaRouter** (`Services/`) — produce a `Plan` from user input. OpenAI uses structured JSON output; Ollama uses local models.
4. **PlanExecutor** (`Services/PlanExecutor.swift`) — walks `Plan.steps` sequentially: executes tools, speaks text, handles ask/delegate steps. Returns `PlanExecutionResult`.
5. **TurnPipeline** (`Domain/Routing/TurnPipeline.swift`) — thin wrapper composing RoutePlanner → Orchestrator → ResponsePresenter. Exposed via `RoutingService` protocol.

### Action & Plan Model

LLM responses are parsed into `Action` (legacy single-action) or `Plan` (preferred multi-step):

- **Action** types: `.talk`, `.tool`, `.delegateOpenAI`, `.capabilityGap`
- **PlanStep** types: `.talk(say:)`, `.tool(name:args:say:)`, `.ask(slot:prompt:)`, `.delegate(task:context:say:)`
- `Plan.fromAction()` bridges legacy single-action responses into the plan format.
- Tool args use `CodableValue` (handles LLM returning numbers/bools instead of strings).

### Dual LLM Routing

- **Ollama** (local-first) — used for intent classification and simple responses when `useOllama` is enabled.
- **OpenAI** (primary/fallback) — GPT-4o-mini with structured JSON. Authority for skill learning and complex tasks.
- `FallbackPolicy` determines provider order based on settings.
- Skill-learning/creation requests are forced to OpenAI (not Ollama).

### Domain Layer & DI

The codebase uses a lightweight domain layer with protocol contracts:

- `Domain/Conversation/LLMClient.swift` — `LLMClient` protocol, `LLMRequest`/`LLMResult` types
- `Domain/Routing/RoutingService.swift` — `RoutingService` protocol, `RouteResult`, `RoutingTurnContext`
- `Domain/Tools/ToolContracts.swift` — `ToolRegistryContract`, `ToolRegistryContributor`
- `Domain/Memory/MemoryContracts.swift` — `MemoryStoreContract`, `MemoryRetriever`, `MemoryCompressor`
- `Domain/Skills/SkillContracts.swift` — `SkillStoreContract`, `SkillRuntime`, `SkillForgePipeline`, `SkillPackageRuntimeContract`

**AppContainer** (`Core/DI/AppContainer.swift`) wires everything. All major services are injected via protocol, with `InMemorySettingsStore` available for tests.

### Tool System

- **Tool protocol**: `name`, `description`, `execute(args:) -> OutputItem`
- **ToolRegistry** is a singleton with alias normalization (e.g., "weather" → "get_weather", "getweather" → "get_weather").
- Tools are registered via **ToolRegistryContributor** groups: `CoreTools`, `CameraTools`, `MemoryTools`, `SchedulingTools`, `LearningTools`, `WebTools`, `SkillsTools`, `CapabilityTools`.
- Tool name normalization handles LLM variations (camelCase, missing underscores, short aliases).

### SkillForge & Capabilities

- **SkillForge** — GPT-only pipeline: plan → build → validate → simulate → approve → install.
- **SkillPackage** — higher-level skill format with inputs, steps, tools, and approval tracking.
- **Capabilities** (`Capabilities/` dir) — external capability bundles with `manifest.json` + `tools.json`. Each has a dotted ID (e.g., `news.basic`, `timer.basic`).
- Skills require dual approval: GPT approval + user permission approval before install.

### Key Services

- **AppState** (`Services/AppState.swift`) — central `@MainActor ObservableObject`. Owns system status (`idle`/`listening`/`capturing`/`thinking`/`speaking`), chat history, and latency tracing.
- **MemoryStore** — SQLite (WAL mode). 4 types: Facts (365d), Preferences (365d), Notes (90d), Check-ins (7d). Hybrid search: semantic + BM25 + recency.
- **SemanticMemoryEngine** — auto-extracts memories from conversations with deduplication.
- **VoicePipelineCoordinator** — state machine for wake word → capture → STT → route → TTS flow.
- **TaskScheduler** / **AlarmSession** — alarm/timer scheduling with state machine for alarm cards.

### sam-gateway

Python FastAPI service (`sam-gateway/`) that proxies to OpenAI Responses API (GPT-5.2). Stateful sessions with `previous_response_id` continuity. Docker-deployable.

## Testing Patterns

- Tests are in `SamOSTests/` with architecture tests in `SamOSTests/Architecture/`.
- Most services use `.shared` singletons in production but accept protocol-typed dependencies in tests.
- `MockRouter` (`Services/MockRouter.swift`) provides deterministic LLM responses for testing.
- `InMemorySettingsStore` replaces `UserDefaultsSettingsStore` in tests.
- Architecture tests verify: domain layer has no infrastructure imports, AppContainer wiring is complete, routing service contracts are met.

## What's Currently In Progress

- Modularizing so changes don't break unrelated areas
- Enforcing routing: Ollama local-first, GPT fallback, GPT authority for learning
- Semantic memory (structured, auditable, retrieval-driven)
- SkillForge reboot with strict GPT loop and dual approval
- Real capabilities (news, pricing, timer, fishing, movies) with dedup/reuse
- Timer routing fixed to not fall into alarm behavior
