import Foundation

/// Runs the `claude` CLI as a subprocess for code generation.
/// Handles graceful sandbox failure — if Process() is blocked, SkillForge continues in OpenAI-only mode.
final class ClaudeCodeRunner {

    enum RunnerError: Error, LocalizedError {
        case cliNotFound
        case sandboxDenied
        case timeout
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound: return "Claude CLI not found"
            case .sandboxDenied: return "Claude CLI blocked by sandbox (expected in sandboxed app)"
            case .timeout: return "Claude CLI timed out after 120 seconds"
            case .processFailed(let msg): return "Claude CLI failed: \(msg)"
            }
        }
    }

    /// Common paths where the `claude` CLI might be installed.
    private static let searchPaths = [
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
        "\(NSHomeDirectory())/.claude/bin/claude",
        "\(NSHomeDirectory())/.local/bin/claude"
    ]

    /// Finds the claude CLI binary.
    private func findCLI() -> String? {
        for path in Self.searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Runs a prompt through the claude CLI and returns stdout.
    func run(prompt: String, workingDirectory: String? = nil) async throws -> String {
        guard let cliPath = findCLI() else {
            throw RunnerError.cliNotFound
        }

        // Validate working directory safety
        if let dir = workingDirectory {
            let allowedPrefixes = [
                NSHomeDirectory(),
                NSTemporaryDirectory()
            ]
            guard allowedPrefixes.contains(where: { dir.hasPrefix($0) }) else {
                throw RunnerError.processFailed("Working directory outside allowed paths")
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["--print", prompt]

            if let dir = workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: dir)
            }

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            // Timeout after 120s
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 120)
            timer.setEventHandler {
                process.terminate()
            }
            timer.resume()

            do {
                try process.run()
                process.waitUntilExit()
                timer.cancel()

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()

                if process.terminationStatus == 0 {
                    let output = String(data: outData, encoding: .utf8) ?? ""
                    continuation.resume(returning: output)
                } else if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: RunnerError.timeout)
                } else {
                    let errStr = String(data: errData, encoding: .utf8) ?? "exit code \(process.terminationStatus)"
                    continuation.resume(throwing: RunnerError.processFailed(errStr))
                }
            } catch {
                timer.cancel()
                // Process launch failure in sandbox
                let msg = error.localizedDescription
                if msg.contains("sandbox") || msg.contains("Operation not permitted") {
                    continuation.resume(throwing: RunnerError.sandboxDenied)
                } else {
                    continuation.resume(throwing: RunnerError.sandboxDenied)
                }
            }
        }
    }
}
