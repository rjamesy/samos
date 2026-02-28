import Foundation

/// Result of running a single intelligence engine.
struct EngineRunResult: Sendable {
    let name: String
    let output: String
    let durationMs: Int
    let status: EngineRunStatus
}

enum EngineRunStatus: String, Sendable {
    case success
    case empty      // ran but produced no output
    case timeout
    case error
    case disabled
}

/// Aggregated results from running all engines.
struct EngineSchedulerResult: Sendable {
    let results: [EngineRunResult]
    let contextBlock: String  // combined output for prompt injection

    var activeNames: [String] {
        results.filter { $0.status == .success }.map(\.name)
    }

    var summary: String {
        let active = results.filter { $0.status == .success }
        let empty = results.filter { $0.status == .empty }
        let failed = results.filter { $0.status == .timeout || $0.status == .error }
        var parts: [String] = []
        if !active.isEmpty {
            parts.append("active: \(active.map { "\($0.name)(\($0.durationMs)ms)" }.joined(separator: ", "))")
        }
        if !empty.isEmpty {
            parts.append("idle: \(empty.map(\.name).joined(separator: ", "))")
        }
        if !failed.isEmpty {
            parts.append("failed: \(failed.map { "\($0.name)(\($0.status.rawValue))" }.joined(separator: ", "))")
        }
        return parts.joined(separator: " | ")
    }
}

/// Actor that schedules intelligence engines with concurrency limits and timeouts.
actor EngineScheduler {
    private var engines: [any IntelligenceEngine] = []
    private let maxConcurrent: Int
    private let timeoutSeconds: TimeInterval
    private let settings: SettingsStoreProtocol

    init(settings: SettingsStoreProtocol, maxConcurrent: Int = 2, timeoutSeconds: TimeInterval = 10) {
        self.settings = settings
        self.maxConcurrent = maxConcurrent
        self.timeoutSeconds = timeoutSeconds
    }

    func registerEngine(_ engine: any IntelligenceEngine) {
        engines.append(engine)
    }

    func registerEngines(_ list: [any IntelligenceEngine]) {
        engines.append(contentsOf: list)
    }

    /// Run all enabled engines and return detailed results.
    func runEngines(context: EngineTurnContext) async -> EngineSchedulerResult {
        var allResults: [EngineRunResult] = []

        // Mark disabled engines
        let disabled = engines.filter { !isEnabled($0) }
        for engine in disabled {
            allResults.append(EngineRunResult(name: engine.name, output: "", durationMs: 0, status: .disabled))
        }

        let enabled = engines.filter { isEnabled($0) }
        guard !enabled.isEmpty else {
            return EngineSchedulerResult(results: allResults, contextBlock: "")
        }

        // Process in batches of maxConcurrent
        for batch in enabled.chunked(into: maxConcurrent) {
            let batchResults = await withTaskGroup(of: EngineRunResult.self) { group in
                for engine in batch {
                    group.addTask { [timeoutSeconds] in
                        let engineStart = Date()
                        do {
                            let output = try await withThrowingTaskGroup(of: String.self) { inner in
                                inner.addTask {
                                    try await engine.run(context: context)
                                }
                                inner.addTask {
                                    try await Task.sleep(for: .seconds(timeoutSeconds))
                                    throw EngineTimeoutError()
                                }
                                let result = try await inner.next()!
                                inner.cancelAll()
                                return result
                            }
                            let ms = Int(Date().timeIntervalSince(engineStart) * 1000)
                            if output.isEmpty {
                                return EngineRunResult(name: engine.name, output: "", durationMs: ms, status: .empty)
                            }
                            return EngineRunResult(name: engine.name, output: output, durationMs: ms, status: .success)
                        } catch is EngineTimeoutError {
                            let ms = Int(Date().timeIntervalSince(engineStart) * 1000)
                            return EngineRunResult(name: engine.name, output: "", durationMs: ms, status: .timeout)
                        } catch {
                            let ms = Int(Date().timeIntervalSince(engineStart) * 1000)
                            return EngineRunResult(name: engine.name, output: "", durationMs: ms, status: .error)
                        }
                    }
                }
                var collected: [EngineRunResult] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }
            allResults.append(contentsOf: batchResults)
        }

        // Build combined context block
        let outputs = allResults.filter { $0.status == .success }.map(\.output)
        let contextBlock = outputs.isEmpty ? "" : "[INTELLIGENCE CONTEXT]\n" + outputs.joined(separator: "\n")

        return EngineSchedulerResult(results: allResults, contextBlock: contextBlock)
    }

    private func isEnabled(_ engine: any IntelligenceEngine) -> Bool {
        settings.bool(forKey: engine.settingsKey)
    }
}

private struct EngineTimeoutError: Error {}

// MARK: - Array chunking helper
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
