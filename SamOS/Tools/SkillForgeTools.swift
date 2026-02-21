import Foundation

// MARK: - Start SkillForge Tool

struct StartSkillForgeTool: Tool {
    let name = "start_skillforge"
    let description = "Start the learn-skill pipeline for a new capability. Args: 'goal' (required), 'constraints' (optional)."

    func execute(args: [String: String]) -> OutputItem {
        let goal = (args["goal"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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

        let constraints = args["constraints"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerConstraints = constraints?.lowercased() ?? ""
        var toolsAllowed: [String] = []
        var permissionsAllowed: [String] = []
        let discoveryText = [goal, constraints]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let suggestedCapabilities = CapabilityCatalog.shared.suggestedCapabilities(for: discoveryText, limit: 5)
        for capability in suggestedCapabilities {
            toolsAllowed.append(contentsOf: capability.tools)
            permissionsAllowed.append(contentsOf: capability.permissions)
        }
        if lowerConstraints.contains(PermissionScope.webRead.rawValue) {
            permissionsAllowed.append(PermissionScope.webRead.rawValue)
        }
        var session: LearnSkillSession?
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            session = LearnSkillController.shared.start(
                goalText: goal,
                missing: constraints?.isEmpty == false ? constraints : nil,
                constraints: constraints?.isEmpty == false ? [constraints!] : [],
                toolsAllowed: Array(Set(toolsAllowed)).sorted(),
                permissionsAllowed: Array(Set(permissionsAllowed)).sorted()
            )
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        guard let session else {
            return OutputItem(kind: .markdown, payload: "I couldn't start skill learning right now.")
        }

        let reusedCapabilities = suggestedCapabilities.map(\.id).sorted()
        let reusedLine: String
        if reusedCapabilities.isEmpty {
            reusedLine = "No existing capability matched yet."
        } else {
            reusedLine = "Reusing capabilities: \(reusedCapabilities.joined(separator: ", "))"
        }
        let payload: [String: Any] = [
            "spoken": "I can learn that. I'll design the skill and ask for permission before installing.",
            "formatted": "Started skill learning session `\(session.id.uuidString.prefix(8))` for: \(goal)\n\(reusedLine)",
            "session_id": session.id.uuidString,
            "status": session.state.rawValue
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            return OutputItem(kind: .markdown, payload: json)
        }
        return OutputItem(kind: .markdown, payload: "Started skill learning for: \(goal)")
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

// MARK: - Skills List Tool (Phase 4)

struct SkillsListTool: Tool {
    let name = "skills.list"
    let description = "List installed JSON skill packages and versions."

    func execute(args: [String: String]) -> OutputItem {
        let packages = SkillStore.shared.loadInstalledPackages()
        if packages.isEmpty {
            return OutputItem(kind: .markdown, payload: "No approved skill packages installed.")
        }
        var lines: [String] = ["| Skill ID | Name | Version | Origin |", "|:--|:--|:--:|:--|"]
        for package in packages.sorted(by: { $0.manifest.skillID < $1.manifest.skillID }) {
            lines.append(
                "| `\(package.manifest.skillID)` | \(package.manifest.name) | \(package.manifest.version) | \(package.manifest.origin.rawValue) |"
            )
        }
        return OutputItem(kind: .markdown, payload: lines.joined(separator: "\n"))
    }
}

// MARK: - Skills Sim Tool (Phase 4)

struct SkillsRunSimTool: Tool {
    let name = "skills.run_sim"
    let description = "Run SkillSim tests for a package by skill_id."

    func execute(args: [String: String]) -> OutputItem {
        let skillID = (args["skill_id"] ?? args["id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !skillID.isEmpty else {
            return OutputItem(kind: .markdown, payload: "Missing required arg `skill_id`.")
        }
        guard let package = SkillStore.shared.getPackage(id: skillID) else {
            return OutputItem(kind: .markdown, payload: "Skill package `\(skillID)` not found.")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var report: SkillSimulationReport?
        Task {
            let harness = SkillSimHarness()
            let sim = await harness.run(
                package: package,
                toolRuntime: SandboxSkillToolRuntime(declaredTools: Set(package.plan.toolRequirements.map(\.name))),
                llmRuntime: DeterministicSkillLLMRuntime()
            )
            report = sim
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)

        guard let report else {
            return OutputItem(kind: .markdown, payload: "Skill simulation timed out.")
        }

        var lines: [String] = []
        lines.append("SkillSim for `\(report.skillID)`: \(report.passed ? "PASS" : "FAIL")")
        lines.append("Passed \(report.passedCount)/\(report.cases.count)")
        for result in report.cases {
            let icon = result.passed ? "PASS" : "FAIL"
            lines.append("- \(icon) `\(result.name)`")
            if let reason = result.failureReason, !reason.isEmpty {
                lines.append("  - \(reason)")
            }
        }
        return OutputItem(kind: .markdown, payload: lines.joined(separator: "\n"))
    }
}

// MARK: - Skills Reset Baseline Tool (Phase 4)

struct SkillsResetBaselineTool: Tool {
    let name = "skills.reset_baseline"
    let description = "Reset forged JSON skills and restore bundled baseline skill packages."

    func execute(args: [String: String]) -> OutputItem {
        let removed = SkillStore.shared.resetPackagesToBaseline()
        SkillForgeQueueService.shared.clearAll()
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            _ = LearnSkillController.shared.cancel()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        ToolPackageStore.shared.reset()
        PermissionScopeStore.shared.reset()
        let baselineCount = SkillStore.shared.loadInstalledPackages().count
        let payload = """
        Reset complete.
        - Removed forged packages: \(removed)
        - Removed installed tool packages: all
        - Restored baseline packages: \(baselineCount)
        """
        return OutputItem(kind: .markdown, payload: payload)
    }
}

// MARK: - Phase 5 Skills Learn Tools

struct SkillsLearnStartTool: Tool {
    let name = "skills.learn.start"
    let description = "Start learning a skill for a capability gap. Args: goal_text (required), constraints (optional), tools_allowed (optional comma list), permissions_allowed (optional comma list)."

    func execute(args: [String: String]) -> OutputItem {
        guard OpenAISettings.isConfigured else {
            return OutputItem(kind: .markdown, payload: "Skill learning requires OpenAI to be configured.")
        }
        let goal = (args["goal_text"] ?? args["goal"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else {
            return OutputItem(kind: .markdown, payload: "Missing required arg `goal_text`.")
        }
        let constraints = splitCSV(args["constraints"])
        var toolsAllowed = splitCSV(args["tools_allowed"])
        var permissionsAllowed = splitCSV(args["permissions_allowed"])
        let discoveryText = ([goal] + constraints).joined(separator: " ")
        let suggestedCapabilities = CapabilityCatalog.shared.suggestedCapabilities(for: discoveryText, limit: 5)
        for capability in suggestedCapabilities {
            toolsAllowed.append(contentsOf: capability.tools)
            permissionsAllowed.append(contentsOf: capability.permissions)
        }
        toolsAllowed = Array(Set(toolsAllowed)).sorted()
        permissionsAllowed = Array(Set(permissionsAllowed)).sorted()
        var session: LearnSkillSession?
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            session = LearnSkillController.shared.start(
                goalText: goal,
                missing: args["missing"],
                constraints: constraints,
                toolsAllowed: toolsAllowed,
                permissionsAllowed: permissionsAllowed
            )
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        guard let session else {
            return OutputItem(kind: .markdown, payload: "Failed to start learning session.")
        }
        let reusedCapabilities = suggestedCapabilities.map(\.id).sorted()
        let reusedLine: String
        if reusedCapabilities.isEmpty {
            reusedLine = "No existing capability match found yet."
        } else {
            reusedLine = "Reusing capabilities: \(reusedCapabilities.joined(separator: ", "))"
        }
        let payload: [String: Any] = [
            "spoken": "I started learning that capability.",
            "formatted": "Learning session `\(session.id.uuidString.prefix(8))` started for: \(session.requirements.goal)\n\(reusedLine)",
            "session_id": session.id.uuidString,
            "state": session.state.rawValue
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return OutputItem(kind: .markdown, payload: "Started learning: \(goal)")
        }
        return OutputItem(kind: .markdown, payload: json)
    }
}

struct SkillsLearnStatusTool: Tool {
    let name = "skills.learn.status"
    let description = "Show status of the active skill-learning session."

    func execute(args: [String: String]) -> OutputItem {
        _ = args
        let semaphore = DispatchSemaphore(value: 0)
        var text = "No active learning session."
        Task { @MainActor in
            text = LearnSkillController.shared.statusSummary()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return OutputItem(kind: .markdown, payload: text)
    }
}

struct SkillsLearnCancelTool: Tool {
    let name = "skills.learn.cancel"
    let description = "Cancel the active skill-learning session."

    func execute(args: [String: String]) -> OutputItem {
        _ = args
        let semaphore = DispatchSemaphore(value: 0)
        var text = "No active learning session."
        Task { @MainActor in
            text = LearnSkillController.shared.cancel()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return OutputItem(kind: .markdown, payload: text)
    }
}

struct SkillsLearnApprovePermissionsTool: Tool {
    let name = "skills.learn.approve_permissions"
    let description = "Approve or reject permissions for the active learning session. Args: approved=true|false."

    func execute(args: [String: String]) -> OutputItem {
        let approvedRaw = (args["approved"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let approved = ["1", "true", "yes", "y"].contains(approvedRaw)
        let rejected = ["0", "false", "no", "n"].contains(approvedRaw)
        guard approved || rejected else {
            return OutputItem(kind: .markdown, payload: "Missing or invalid `approved` arg (use true/false).")
        }
        let semaphore = DispatchSemaphore(value: 0)
        var text = "No active learning session."
        Task { @MainActor in
            text = LearnSkillController.shared.approvePermissions(approved)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return OutputItem(kind: .markdown, payload: text)
    }
}

struct SkillsLearnRequestChangesTool: Tool {
    let name = "skills.learn.request_changes"
    let description = "Request revisions to the pending skill review before install. Optional arg: notes."

    func execute(args: [String: String]) -> OutputItem {
        let notes = args["notes"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let semaphore = DispatchSemaphore(value: 0)
        var text = "No active learning session."
        Task { @MainActor in
            text = LearnSkillController.shared.requestChanges(notes)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
        return OutputItem(kind: .markdown, payload: text)
    }
}

struct SkillsLearnInstallTool: Tool {
    let name = "skills.learn.install"
    let description = "Install the GPT-approved skill after permission approval."

    func execute(args: [String: String]) -> OutputItem {
        _ = args
        let semaphore = DispatchSemaphore(value: 0)
        var message = "Install did not complete."
        Task { @MainActor in
            message = await LearnSkillController.shared.installApprovedSkill()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 20)
        return OutputItem(kind: .markdown, payload: message)
    }
}

private func splitCSV(_ raw: String?) -> [String] {
    guard let raw = raw else { return [] }
    return raw
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}
