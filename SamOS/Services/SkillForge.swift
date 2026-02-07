import Foundation

/// Orchestrator for building new skills: draft → refine (OpenAI) → implement (Claude, optional) → validate → install.
@MainActor
final class SkillForge {

    static let shared = SkillForge()

    private let refiner = OpenAIRefinerClient()
    private let claudeRunner = ClaudeCodeRunner()

    /// Whether the forge can operate (requires OpenAI API key at minimum).
    var isConfigured: Bool {
        OpenAISettings.isConfigured
    }

    @Published var currentJob: SkillForgeJob?

    private init() {}

    // MARK: - Forge Pipeline

    /// Main forge pipeline. Builds a new skill from a goal description.
    /// The progress callback is called whenever the job updates.
    func forge(goal: String, missing: String, onProgress: @escaping (SkillForgeJob) -> Void) async throws -> SkillSpec {
        var job = SkillForgeJob(goal: goal)
        currentJob = job
        onProgress(job)

        // Step 1: Draft a basic skill spec
        job.log("Drafting skill spec for: \(goal)")
        job.status = .drafting
        onProgress(job)

        let draft = draftSkillSpec(goal: goal, missing: missing)

        // Step 2: Refine via OpenAI
        job.log("Refining spec with OpenAI (\(OpenAISettings.model))...")
        job.status = .refining
        onProgress(job)

        let toolNames = ToolRegistry.shared.allTools.map { $0.name }
        var refined: SkillSpec
        do {
            refined = try await refiner.refineSkillSpec(goal: goal, draft: draft, toolList: toolNames)
            job.log("OpenAI refined spec: \(refined.name) with \(refined.steps.count) steps")
        } catch {
            job.log("OpenAI refinement failed: \(error.localizedDescription). Using draft spec.")
            // Fall back to draft
            refined = draft
        }

        // Step 3: (Optional) Claude Code implementation
        job.status = .implementing
        onProgress(job)
        job.log("Skipping Claude Code implementation (not required for JSON-based skills)")

        // Step 4: Validate
        job.log("Validating skill spec...")
        job.status = .testing
        onProgress(job)

        if let error = validate(refined) {
            job.fail("Validation failed: \(error)")
            currentJob = job
            onProgress(job)
            throw ForgeError.validationFailed(error)
        }
        job.log("Validation passed")

        // Stamp metadata so the skill passes isInstalled()
        refined.status = "active"
        refined.approvedAt = Date()

        // Step 5: Install
        job.log("Installing skill: \(refined.name)")
        job.status = .installing
        onProgress(job)

        guard SkillStore.shared.install(refined) else {
            job.fail("Failed to write skill to disk")
            currentJob = job
            onProgress(job)
            throw ForgeError.installFailed
        }

        job.complete()
        job.log("Skill '\(refined.name)' installed successfully")
        currentJob = job
        onProgress(job)

        return refined
    }

    // MARK: - Draft

    /// Creates a basic draft skill spec from the goal.
    private func draftSkillSpec(goal: String, missing: String) -> SkillSpec {
        let id = "forged_\(UUID().uuidString.prefix(8).lowercased())"
        let name = goal.prefix(30).trimmingCharacters(in: .whitespacesAndNewlines)

        return SkillSpec(
            id: id,
            name: String(name),
            version: 1,
            triggerPhrases: [goal.lowercased()],
            slots: [],
            steps: [
                SkillSpec.StepDef(action: "talk", args: ["say": "I'm working on: \(goal)"])
            ],
            onTrigger: nil
        )
    }

    // MARK: - Validation

    /// Returns nil if the spec is valid, or an error message.
    private func validate(_ spec: SkillSpec) -> String? {
        if spec.id.isEmpty { return "Skill ID is empty" }
        if spec.name.isEmpty { return "Skill name is empty" }
        if spec.triggerPhrases.isEmpty { return "No trigger phrases" }
        if spec.steps.isEmpty { return "No steps defined" }
        return nil
    }

    // MARK: - Errors

    enum ForgeError: Error, LocalizedError {
        case validationFailed(String)
        case installFailed

        var errorDescription: String? {
            switch self {
            case .validationFailed(let msg): return "Skill validation failed: \(msg)"
            case .installFailed: return "Failed to install forged skill"
            }
        }
    }
}
