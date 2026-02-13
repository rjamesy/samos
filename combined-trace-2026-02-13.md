# Combined Routing + Deterministic Trace Report (2026-02-13)

## Scope
Stability hardening only. No new user features, tools, or UI behavior changes.

## What was hardened
- Voice turns now use combined routing on the voice path (`inputMode == .voice`) so intent+plan are produced together from local first.
- Local combined routing is guarded by a single centralized deadline.
- Fallback to OpenAI combined routing happens only for local timeout/schema-invalid outcomes.
- Turn timing trace is emitted as one compact, chronological ms timeline per turn.
- Weather arg normalization and retry are deterministic at module boundaries (`location -> place`, one in-turn retry when place is present in user text).
- Ollama routing toggle now respects stored user preference on app load (including legacy key migration).

## Timeout values
- `RouterTimeouts.localCombinedDeadlineMs = 3500`
- `RouterTimeouts.localCombinedDeadlineSeconds = 3.5`
- OpenAI provider retry policy (outside Router):
  - intent retry backoff: `250ms`
  - plan retry backoff: `750ms`
  - single retry on timeout-like failures

## Example trace output
From `final-combined.log` (combined local timeout -> OpenAI fallback):

```text
[TURN_TRACE] turn_id=turn_1 total_ms=3952
  0ms TURN_START
  0ms ROUTE_LOCAL_START
  3500ms ROUTE_LOCAL_END ok=false router_ms=3500 outcome=timeout
  3500ms ROUTE_OPENAI_START
  3920ms ROUTE_OPENAI_END router_ms=420
  3920ms PLAN_EXEC_START tools=0
  3944ms SPEECH_SELECT_START
  3952ms PLAN_EXEC_END tool_ms_total=14 tool_count=0
  3952ms SPEECH_SELECT_END speech_ms=8
  3952ms TURN_END total_ms=3952
```

From `final-combined.log` (voice turn with capture + STT + local success):

```text
[TURN_TRACE] turn_id=turn_1 total_ms=164
  0ms TURN_START
  0ms CAPTURE_START
  6ms CAPTURE_END capture_ms=6
  6ms STT_START
  12ms STT_END stt_ms=6 text_chars=16
  12ms ROUTE_LOCAL_START
  132ms ROUTE_LOCAL_END ok=true router_ms=120 outcome=ok
  132ms PLAN_EXEC_START tools=0
  156ms SPEECH_SELECT_START
  164ms PLAN_EXEC_END tool_ms_total=14 tool_count=0
  164ms SPEECH_SELECT_END speech_ms=8
  164ms TURN_END total_ms=164
```

## Tests added/updated
Added:
- `SamOSTests/TurnRouterCombinedContractTests.swift`
  - local combined success path
  - schema-fail fallback to OpenAI
  - deadline/timeout fallback to OpenAI
  - local-disabled path (`useOllama = false`) skips local
- `SamOSTests/TurnTraceTests.swift`
  - required trace phases present and monotonic
  - OpenAI fallback route events present when fallback timing exists

Updated:
- `SamOSTests/ToolNormalizationTests.swift`
  - `weather` alias normalization
  - unknown tool deterministic reject prompt
  - weather plan does not trigger capability-gap pending state
  - `location -> place` normalization for weather args
  - in-turn weather place auto-fill retry
- `SamOSTests/FaceGreetingManagerTests.swift`
  - voice-turn fixture aligned with combined OpenAI intent+plan contract

## Behavior change statement
- Intended behavior changes: none.
- Stability change only: local combined routing/fallback path is faster and less flaky under local timeout/schema drift.
