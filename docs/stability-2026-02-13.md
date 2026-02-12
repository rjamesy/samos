# Stability Report — 2026-02-13

## Scope
Stabilization hardening after modular refactor of Router/ToolRunner/SpeechCoordinator.
No user-facing features were added.

## What was fixed
- Added a single canonical tool-name normalization/allowlist layer in `ToolRegistry` and used it from `TurnToolRunner`, `ToolsRuntime`, and routing normalization paths.
- Tightened `TurnRouter` needs-web contract:
  - normalizes tool names in routed plans,
  - requires allowed tool plans for `needsWeb` turns,
  - uses deterministic fallback asks,
  - preserves `source_url_or_site` fallback for true external-source gaps,
  - avoids source-URL gap asks when a native tool category exists.
- Kept slow-start tracking in `SpeechCoordinator` deterministic (`tts_start_deadline`) while removing AppState-visible false drop side effects.
- Removed test network flake by injecting fake transports in tests that previously could hit live OpenAI paths.

## Why it was brittle before
- Tool aliases/schema drift (`weather`, `getWeather`, malformed step shape) were handled in multiple places, allowing unknown-tool paths to leak into capability-gap prompts.
- `needsWeb` handling could produce ambiguous clarifiers and regress expected pending-slot behavior.
- Slow-start tracking leaked into generic drop-reason assertions, causing false failures.
- Some tests could use ambient network/keychain state.

## Contract protections now
- Canonical tool-name mapping and allowlist are exported by `ToolRegistry` and applied at module boundaries.
- Router’s needs-web branch now has deterministic, category-aware fallback behavior and normalized tool-step output.
- Speech coordination tracks one-turn filler and slow-start metadata without mutating unrelated global drop state.
- Module boundaries stay DI-driven; singleton access inside core modules is replaced with injected wrappers/protocols where changed.

## Tests that guarantee this
- `SamOSTests/ToolNormalizationTests.swift`
  - alias normalization (`weather` -> `get_weather`),
  - unknown-tool deterministic local rejection,
  - weather plan does not enter capability-gap source pending flow.
- `SamOSTests/TurnRouterTests.swift`
  - weather routing normalization,
  - needs-web fallback behavior for native vs non-native categories,
  - timeout-fallback normalization preservation.
- `SamOSTests/SpeechCoordinatorTests.swift`
  - one spoken line selection for tool-facing output,
  - slow-start reason tracking/clear,
  - filler one-shot per turn.
- Existing router/orchestrator pipeline tests updated to use fake transports and stay deterministic offline.

## Validation
- Baseline: `baseline-stability.log` — 849 executed, 14 skipped, 0 failures.
- Final: `final-stability.log` — 857 executed, 14 skipped, 0 failures.

Net: behavior preserved with stricter boundary contracts and reduced flake.
