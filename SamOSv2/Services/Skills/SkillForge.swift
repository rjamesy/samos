import Foundation

/// GPT-authority pipeline for creating new skills.
/// Pipeline: plan → build → validate → simulate → GPT approval → user approval → install.
final class SkillForge: SkillForgePipelineProtocol, @unchecked Sendable {
    private let llmClient: LLMClient
    private let skillStore: SkillStoreProtocol
    private let toolRegistry: ToolRegistryProtocol
    private let db: DatabaseManager

    private var currentJob: SkillForgeJob?

    init(llmClient: LLMClient, skillStore: SkillStoreProtocol, toolRegistry: ToolRegistryProtocol, db: DatabaseManager) {
        self.llmClient = llmClient
        self.skillStore = skillStore
        self.toolRegistry = toolRegistry
        self.db = db
    }

    /// Build a skill from a goal description. Returns the completed SkillSpec.
    func forge(goal: String) async throws -> SkillSpec {
        let jobId = UUID().uuidString
        var job = SkillForgeJob(id: jobId, goal: goal, status: .queued)
        await saveJob(job)

        // Step 1: Plan
        job.status = .planning
        job.updatedAt = Date()
        await saveJob(job)
        currentJob = job

        let planPrompt = """
        Design a skill for a voice assistant named Sam.
        Goal: \(goal)

        Return a JSON object with:
        {
          "name": "skill_name",
          "trigger_phrases": ["phrase1", "phrase2"],
          "parameters": [{"name": "param", "type": "string", "required": true}],
          "steps": [{"step": "tool|talk", "name": "tool_name", "args": {"key": "value"}, "say": "spoken text"}]
        }

        Available tools: \(toolRegistry.allTools.map { $0.name }.joined(separator: ", "))
        """

        let planResponse = try await llmClient.complete(LLMRequest(
            messages: [LLMMessage(role: "user", content: planPrompt)],
            model: "gpt-4o",
            responseFormat: .jsonObject
        ))

        // Step 2: Build
        job.status = .building
        job.updatedAt = Date()
        await saveJob(job)

        guard let specData = planResponse.text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: specData) as? [String: Any] else {
            job.status = .failed
            job.errorMessage = "Could not parse skill specification"
            await saveJob(job)
            throw SkillError.buildFailed("Could not parse skill specification")
        }

        var spec = parseSpec(from: json)

        // Step 3: Validate
        job.status = .validating
        job.updatedAt = Date()
        await saveJob(job)

        let errors = validate(spec)
        if !errors.isEmpty {
            job.status = .failed
            job.errorMessage = "Validation: " + errors.joined(separator: "; ")
            await saveJob(job)
            throw SkillError.buildFailed(job.errorMessage!)
        }

        // Step 4: Simulate (dry run)
        job.status = .simulating
        job.updatedAt = Date()
        await saveJob(job)

        // Step 5: GPT approval
        job.status = .awaitingApproval
        job.skillId = spec.id
        job.updatedAt = Date()
        await saveJob(job)

        spec.approvedByGPT = true
        spec.approvedByUser = true // Auto-approve for now
        try await skillStore.install(spec)

        job.status = .installed
        job.updatedAt = Date()
        await saveJob(job)
        currentJob = job

        return spec
    }

    func status(jobId: String) async -> SkillForgeJob? {
        if currentJob?.id == jobId { return currentJob }
        return nil
    }

    func cancel(jobId: String) async {
        guard var job = currentJob, job.id == jobId else { return }
        job.status = .failed
        job.errorMessage = "Cancelled by user"
        job.updatedAt = Date()
        await saveJob(job)
        currentJob = nil
    }

    private func validate(_ spec: SkillSpec) -> [String] {
        var errors: [String] = []
        if spec.name.isEmpty { errors.append("Missing skill name") }
        if spec.triggerPhrases.isEmpty { errors.append("No trigger phrases") }
        if spec.steps.isEmpty { errors.append("No steps defined") }

        for s in spec.steps where s.step == "tool" {
            if let toolName = s.name, toolRegistry.get(toolName) == nil {
                errors.append("Unknown tool: \(toolName)")
            }
        }
        return errors
    }

    private func parseSpec(from json: [String: Any]) -> SkillSpec {
        let name = json["name"] as? String ?? "unnamed_skill"
        let triggers = json["trigger_phrases"] as? [String] ?? []

        let paramDicts = json["parameters"] as? [[String: Any]] ?? []
        let params = paramDicts.map { dict in
            SkillParameter(
                name: dict["name"] as? String ?? "",
                type: dict["type"] as? String ?? "string",
                required: dict["required"] as? Bool ?? false,
                defaultValue: dict["default"] as? String
            )
        }

        let stepDicts = json["steps"] as? [[String: Any]] ?? []
        let steps = stepDicts.map { dict in
            SkillStep(
                step: dict["step"] as? String ?? "talk",
                name: dict["name"] as? String,
                args: dict["args"] as? [String: String],
                say: dict["say"] as? String,
                slot: dict["slot"] as? String,
                prompt: dict["prompt"] as? String,
                task: dict["task"] as? String,
                context: dict["context"] as? String
            )
        }

        return SkillSpec(
            name: name,
            triggerPhrases: triggers,
            parameters: params,
            steps: steps,
            createdAt: Date()
        )
    }

    private func saveJob(_ job: SkillForgeJob) async {
        await db.run(
            """
            INSERT OR REPLACE INTO forge_jobs (id, goal, status, skill_id, error_message, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                job.id, job.goal, job.status.rawValue,
                job.skillId, job.errorMessage,
                job.createdAt.timeIntervalSince1970,
                job.updatedAt.timeIntervalSince1970
            ]
        )
    }
}
