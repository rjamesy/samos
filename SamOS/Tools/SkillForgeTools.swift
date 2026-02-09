import Foundation

// MARK: - Start SkillForge Tool

struct StartSkillForgeTool: Tool {
    let name = "start_skillforge"
    let description = "Queue a new capability/skill build for Sam. Use when user asks Sam to build/create/learn a capability. Args: 'goal' (required), 'constraints' (optional). Enqueues into the forge queue; processed FIFO."

    func execute(args: [String: String]) -> OutputItem {
        let goal = args["goal"] ?? ""
        guard !goal.isEmpty else {
            return OutputItem(kind: .markdown, payload: "I need a goal to learn. What should I build?")
        }

        guard OpenAISettings.isConfigured else {
            let payload: [String: Any] = [
                "spoken": "I can't learn new skills right now — OpenAI isn't configured.",
                "formatted": "SkillForge requires an OpenAI API key. Configure it in Settings."
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                return OutputItem(kind: .markdown, payload: json)
            }
            return OutputItem(kind: .markdown, payload: "SkillForge requires an OpenAI API key.")
        }

        let constraints = args["constraints"]

        if let job = SkillForgeQueueService.shared.enqueue(goal: goal, constraints: constraints) {
            let shortId = String(job.id.uuidString.prefix(8)).lowercased()
            let queueDepth = SkillForgeQueueService.shared.pendingCount
            let positionNote = queueDepth > 1 ? " (\(queueDepth) in queue)" : ""

            let payload: [String: Any] = [
                "spoken": "I've queued that up — I'll start learning it\(queueDepth > 1 ? " shortly" : " now").",
                "formatted": "Forge job `\(shortId)` queued: \(goal)\(positionNote)",
                "job_id": job.id.uuidString,
                "status": "queued"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                return OutputItem(kind: .markdown, payload: json)
            }
            return OutputItem(kind: .markdown, payload: "Queued: \(goal)")
        }

        return OutputItem(kind: .markdown, payload: "I couldn't queue that. Please try again.")
    }
}

// MARK: - Forge Queue Status Tool

struct ForgeQueueStatusTool: Tool {
    let name = "forge_queue_status"
    let description = "Show the current state of the skill forge queue"

    func execute(args: [String: String]) -> OutputItem {
        let jobs = SkillForgeQueueService.shared.allJobs()

        if jobs.isEmpty {
            let payload: [String: Any] = [
                "spoken": "The forge queue is empty.",
                "formatted": "No forge jobs."
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                return OutputItem(kind: .markdown, payload: json)
            }
            return OutputItem(kind: .markdown, payload: "No forge jobs.")
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        var md = "| Status | Goal | Created |\n"
        md += "|:-------|:-----|:--------|\n"
        for job in jobs {
            let shortId = String(job.id.uuidString.prefix(8)).lowercased()
            let statusIcon: String
            switch job.status {
            case .queued: statusIcon = "queued"
            case .running: statusIcon = "running"
            case .completed: statusIcon = "done"
            case .failed: statusIcon = "failed"
            }
            md += "| \(statusIcon) | `\(shortId)` \(job.goal) | \(formatter.string(from: job.createdAt)) |\n"
        }

        let queuedCount = jobs.filter { $0.status == .queued }.count
        let runningCount = jobs.filter { $0.status == .running }.count
        let summary = [
            runningCount > 0 ? "\(runningCount) running" : nil,
            queuedCount > 0 ? "\(queuedCount) queued" : nil,
        ].compactMap { $0 }.joined(separator: ", ")

        let spoken = summary.isEmpty ? "The forge queue is clear." : "Forge queue: \(summary)."

        let payload: [String: Any] = [
            "spoken": spoken,
            "formatted": md
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            return OutputItem(kind: .markdown, payload: json)
        }
        return OutputItem(kind: .markdown, payload: md)
    }
}

// MARK: - Forge Queue Clear Tool

struct ForgeQueueClearTool: Tool {
    let name = "forge_queue_clear"
    let description = "Stop/abort active capability learning and clear queued/running forge jobs. Optional arg: 'scope' = 'finished' to only clear completed/failed history."

    func execute(args: [String: String]) -> OutputItem {
        let scope = args["scope"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if scope == "finished" {
            SkillForgeQueueService.shared.clearFinished()
        } else {
            SkillForgeQueueService.shared.stopAll()
        }

        let payload: [String: Any] = [
            "spoken": scope == "finished"
                ? "Cleared finished forge jobs."
                : "Stopped capability learning and cleared the forge queue.",
            "formatted": scope == "finished"
                ? "Finished forge jobs cleared."
                : "Stopped active capability learning. Cleared queued and running forge jobs."
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            return OutputItem(kind: .markdown, payload: json)
        }
        return OutputItem(kind: .markdown, payload: "Capability learning queue cleared.")
    }
}
