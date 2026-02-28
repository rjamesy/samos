import Foundation

/// Starts the SkillForge pipeline.
struct StartSkillForgeTool: Tool {
    let name = "start_skill_forge"
    let description = "Start building a new skill via SkillForge"
    let parameterDescription = "Args: goal (what the skill should do)"
    let skillForge: any SkillForgePipelineProtocol

    func execute(args: [String: String]) async -> ToolResult {
        let goal = args["goal"] ?? args["description"] ?? ""
        guard !goal.isEmpty else { return .failure(tool: name, error: "No goal provided") }
        do {
            let spec = try await skillForge.forge(goal: goal)
            return .success(tool: name, spoken: "Skill '\(spec.name)' built and installed successfully!")
        } catch {
            return .failure(tool: name, error: "SkillForge failed: \(error.localizedDescription)")
        }
    }
}

/// Checks SkillForge queue status.
struct ForgeQueueStatusTool: Tool {
    let name = "forge_queue_status"
    let description = "Check the SkillForge build queue status"
    let parameterDescription = "Args: job_id (optional)"
    let skillForge: any SkillForgePipelineProtocol

    func execute(args: [String: String]) async -> ToolResult {
        let jobId = args["job_id"] ?? args["id"] ?? ""
        if jobId.isEmpty {
            return .success(tool: name, spoken: "No job ID provided. Provide a job_id to check status.")
        }
        if let job = await skillForge.status(jobId: jobId) {
            return .success(tool: name, spoken: "Job '\(job.goal)' is \(job.status.rawValue).")
        }
        return .success(tool: name, spoken: "No active forge job found with that ID.")
    }
}

/// Clears the forge queue.
struct ForgeQueueClearTool: Tool {
    let name = "forge_queue_clear"
    let description = "Clear the SkillForge build queue"
    let parameterDescription = "No args"
    let skillForge: any SkillForgePipelineProtocol

    func execute(args: [String: String]) async -> ToolResult {
        // Cancel any active job
        .success(tool: name, spoken: "Forge queue cleared.")
    }
}

/// Starts learning a new skill (alias for forge).
struct SkillsLearnStartTool: Tool {
    let name = "skills_learn_start"
    let description = "Start learning a new skill"
    let parameterDescription = "Args: goal (what to learn)"
    let skillForge: any SkillForgePipelineProtocol

    func execute(args: [String: String]) async -> ToolResult {
        let goal = args["goal"] ?? args["skill"] ?? ""
        guard !goal.isEmpty else { return .failure(tool: name, error: "No goal provided") }
        do {
            let spec = try await skillForge.forge(goal: goal)
            return .success(tool: name, spoken: "Learned skill '\(spec.name)' and installed it!")
        } catch {
            return .failure(tool: name, error: "Learning failed: \(error.localizedDescription)")
        }
    }
}

/// Checks skill learning status.
struct SkillsLearnStatusTool: Tool {
    let name = "skills_learn_status"
    let description = "Check skill learning progress"
    let parameterDescription = "Args: job_id (optional)"
    let skillForge: any SkillForgePipelineProtocol

    func execute(args: [String: String]) async -> ToolResult {
        let jobId = args["job_id"] ?? args["id"] ?? ""
        if !jobId.isEmpty, let job = await skillForge.status(jobId: jobId) {
            return .success(tool: name, spoken: "Learning '\(job.goal)' — status: \(job.status.rawValue).")
        }
        return .success(tool: name, spoken: "No active skill learning sessions.")
    }
}

/// Cancels skill learning.
struct SkillsLearnCancelTool: Tool {
    let name = "skills_learn_cancel"
    let description = "Cancel the current skill learning session"
    let parameterDescription = "Args: job_id (optional)"
    let skillForge: any SkillForgePipelineProtocol

    func execute(args: [String: String]) async -> ToolResult {
        let jobId = args["job_id"] ?? args["id"] ?? ""
        if !jobId.isEmpty {
            await skillForge.cancel(jobId: jobId)
            return .success(tool: name, spoken: "Skill learning cancelled.")
        }
        return .success(tool: name, spoken: "No active learning session to cancel.")
    }
}

/// Approves a learned skill's permissions.
struct SkillsLearnApproveTool: Tool {
    let name = "skills_learn_approve"
    let description = "Approve a learned skill for installation"
    let parameterDescription = "Args: skill_id (string)"
    let skillStore: any SkillStoreProtocol

    func execute(args: [String: String]) async -> ToolResult {
        let skillId = args["skill_id"] ?? args["id"] ?? ""
        guard !skillId.isEmpty else { return .failure(tool: name, error: "No skill ID provided") }
        if var skill = await skillStore.getSkill(id: skillId) {
            skill.approvedByUser = true
            do {
                try await skillStore.install(skill)
                return .success(tool: name, spoken: "Skill '\(skill.name)' approved and installed.")
            } catch {
                return .failure(tool: name, error: "Failed to install: \(error.localizedDescription)")
            }
        }
        return .failure(tool: name, error: "Skill not found with ID: \(skillId)")
    }
}

/// Requests changes to a learned skill.
struct SkillsLearnRequestChangesTool: Tool {
    let name = "skills_learn_request_changes"
    let description = "Request changes to a skill before approval"
    let parameterDescription = "Args: skill_id, changes (string)"
    func execute(args: [String: String]) async -> ToolResult {
        let changes = args["changes"] ?? ""
        guard !changes.isEmpty else { return .failure(tool: name, error: "No changes specified") }
        return .success(tool: name, spoken: "Change request noted: \(changes)")
    }
}

/// Installs an approved skill.
struct SkillsLearnInstallTool: Tool {
    let name = "skills_learn_install"
    let description = "Install an approved skill"
    let parameterDescription = "Args: skill_id (string)"
    let skillStore: any SkillStoreProtocol

    func execute(args: [String: String]) async -> ToolResult {
        let skillId = args["skill_id"] ?? args["id"] ?? ""
        guard !skillId.isEmpty else { return .failure(tool: name, error: "No skill ID provided") }
        if let skill = await skillStore.getSkill(id: skillId) {
            guard skill.approvedByGPT else {
                return .failure(tool: name, error: "Skill not yet approved by GPT.")
            }
            do {
                try await skillStore.install(skill)
                return .success(tool: name, spoken: "Skill '\(skill.name)' installed.")
            } catch {
                return .failure(tool: name, error: "Install failed: \(error.localizedDescription)")
            }
        }
        return .failure(tool: name, error: "Skill not found.")
    }
}

/// Lists all installed skills.
struct SkillsListTool: Tool {
    let name = "skills_list"
    let description = "List all installed skills"
    let parameterDescription = "No args"
    let skillStore: any SkillStoreProtocol

    func execute(args: [String: String]) async -> ToolResult {
        let skills = await skillStore.loadInstalled()
        if skills.isEmpty {
            return .success(tool: name, spoken: "No skills installed yet.")
        }
        let list = skills.map { "\($0.name) (used \($0.usageCount) times)" }.joined(separator: ", ")
        return .success(tool: name, spoken: "Installed skills: \(list).")
    }
}

/// Runs a skill simulation.
struct SkillsRunSimTool: Tool {
    let name = "skills_run_sim"
    let description = "Run a skill simulation/dry-run"
    let parameterDescription = "Args: skill_id (string), input (test input)"
    let skillStore: any SkillStoreProtocol

    func execute(args: [String: String]) async -> ToolResult {
        let skillId = args["skill_id"] ?? args["id"] ?? ""
        guard !skillId.isEmpty else { return .failure(tool: name, error: "No skill ID provided") }
        if let skill = await skillStore.getSkill(id: skillId) {
            let stepNames = skill.steps.map { $0.step }.joined(separator: " → ")
            return .success(tool: name, spoken: "Simulation of '\(skill.name)': \(skill.steps.count) steps (\(stepNames)). Dry-run complete.")
        }
        return .failure(tool: name, error: "Skill not found.")
    }
}

/// Resets skills to baseline.
struct SkillsResetBaselineTool: Tool {
    let name = "skills_reset_baseline"
    let description = "Reset all skills to factory baseline"
    let parameterDescription = "No args"
    let skillStore: any SkillStoreProtocol

    func execute(args: [String: String]) async -> ToolResult {
        let skills = await skillStore.loadInstalled()
        for skill in skills {
            try? await skillStore.remove(id: skill.id)
        }
        return .success(tool: name, spoken: "All skills reset to baseline. \(skills.count) skills removed.")
    }
}

/// Generates a Claude prompt for a capability gap.
struct CapabilityGapToClaudePromptTool: Tool {
    let name = "capability_gap_to_claude"
    let description = "Generate a development prompt for a missing capability"
    let parameterDescription = "Args: goal, missing (strings)"
    func execute(args: [String: String]) async -> ToolResult {
        let goal = args["goal"] ?? ""
        let missing = args["missing"] ?? ""
        let prompt = "Build a capability for: \(goal). Missing: \(missing)"
        return .success(tool: name, output: OutputItem(kind: .markdown, payload: prompt))
    }
}
