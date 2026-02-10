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
        let sortedTools = ToolRegistry.shared.allTools.sorted { $0.name < $1.name }
        let toolNames = sortedTools.map { $0.name }
        let toolCatalog = sortedTools.map { "\($0.name): \($0.description)" }

        // Step 1b: Ask OpenAI for specific capability requirements.
        job.log("Asking OpenAI for specific capability requirements...")
        onProgress(job)

        let requirements: OpenAIRefinerClient.CapabilityRequirements
        do {
            requirements = try await refiner.fetchCapabilityRequirements(
                goal: goal,
                missing: missing,
                toolList: toolCatalog
            ) { exchange in
                let header: String
                switch exchange.phase {
                case .request:
                    header = "[OpenAI Request]"
                case .response:
                    header = "[OpenAI Response]"
                case .error:
                    header = "[OpenAI Error]"
                }
                job.log("\(header)\n\(exchange.content)")
                onProgress(job)
            }
        } catch {
            job.fail("OpenAI requirements step failed: \(error.localizedDescription)")
            currentJob = job
            onProgress(job)
            throw ForgeError.requirementsFailed(error.localizedDescription)
        }

        if !requirements.summary.isEmpty {
            job.log("Requirements summary: \(requirements.summary)")
        }
        if !requirements.requirements.isEmpty {
            job.log("Specific requirements:")
            for (index, requirement) in requirements.requirements.enumerated() {
                job.log("\(index + 1). \(requirement)")
            }
        }
        if !requirements.acceptanceCriteria.isEmpty {
            job.log("Acceptance criteria:")
            for criterion in requirements.acceptanceCriteria {
                job.log("- \(criterion)")
            }
        }
        if !requirements.risks.isEmpty {
            job.log("Known risks:")
            for risk in requirements.risks {
                job.log("- \(risk)")
            }
        }
        if !requirements.openQuestions.isEmpty {
            job.log("Open questions:")
            for question in requirements.openQuestions {
                job.log("- \(question)")
            }
        }
        onProgress(job)

        if requirements.requirements.isEmpty {
            let reason = "OpenAI did not provide specific requirements."
            job.fail(reason)
            currentJob = job
            onProgress(job)
            throw ForgeError.requirementsFailed(reason)
        }

        // Step 2: Refine via OpenAI
        job.log("Refining spec with OpenAI (\(OpenAISettings.model))...")
        job.status = .refining
        onProgress(job)

        var refined: SkillSpec
        do {
            refined = try await refiner.refineSkillSpec(
                goal: goal,
                draft: draft,
                requirements: requirements,
                toolList: toolCatalog
            ) { exchange in
                let header: String
                switch exchange.phase {
                case .request:
                    header = "[OpenAI Request]"
                case .response:
                    header = "[OpenAI Response]"
                case .error:
                    header = "[OpenAI Error]"
                }
                job.log("\(header)\n\(exchange.content)")
                onProgress(job)
            }
            job.log("OpenAI refined spec: \(refined.name) with \(refined.steps.count) steps")
        } catch {
            job.fail("OpenAI refinement failed: \(error.localizedDescription)")
            currentJob = job
            onProgress(job)
            throw ForgeError.refinementFailed(error.localizedDescription)
        }

        // Step 2b: Ask OpenAI for implementation verification + concrete steps.
        job.log("Requesting OpenAI implementation steps and verification...")
        onProgress(job)

        var review: OpenAIRefinerClient.ImplementationReview
        do {
            review = try await refiner.reviewSkillSpec(
                goal: goal,
                missing: missing,
                spec: refined,
                requirements: requirements,
                toolList: toolCatalog
            ) { exchange in
                let header: String
                switch exchange.phase {
                case .request:
                    header = "[OpenAI Request]"
                case .response:
                    header = "[OpenAI Response]"
                case .error:
                    header = "[OpenAI Error]"
                }
                job.log("\(header)\n\(exchange.content)")
                onProgress(job)
            }
        } catch {
            job.fail("OpenAI implementation review failed: \(error.localizedDescription)")
            currentJob = job
            onProgress(job)
            throw ForgeError.reviewFailed(error.localizedDescription)
        }

        if !review.summary.isEmpty {
            job.log("OpenAI review summary: \(review.summary)")
        }
        if !review.implementationSteps.isEmpty {
            job.log("OpenAI implementation steps:")
            for (index, step) in review.implementationSteps.enumerated() {
                job.log("\(index + 1). \(step)")
            }
        }
        if !review.blockers.isEmpty {
            job.log("OpenAI blockers:")
            for blocker in review.blockers {
                job.log("- \(blocker)")
            }
        }
        onProgress(job)

        let needsRepairRetry = !review.approved || review.implementationSteps.isEmpty
        if needsRepairRetry {
            job.log("OpenAI rejected the first spec. Asking OpenAI to plan and repair the missing parts...")
            if !review.summary.isEmpty {
                job.log("Repair target: \(review.summary)")
            }
            onProgress(job)

            do {
                refined = try await refiner.repairSkillSpecAfterReview(
                    goal: goal,
                    missing: missing,
                    draft: refined,
                    requirements: requirements,
                    review: review,
                    toolList: toolCatalog
                ) { exchange in
                    let header: String
                    switch exchange.phase {
                    case .request:
                        header = "[OpenAI Request]"
                    case .response:
                        header = "[OpenAI Response]"
                    case .error:
                        header = "[OpenAI Error]"
                    }
                    job.log("\(header)\n\(exchange.content)")
                    onProgress(job)
                }
                job.log("OpenAI repair spec: \(refined.name) with \(refined.steps.count) steps")
                onProgress(job)
            } catch {
                job.fail("OpenAI repair failed: \(error.localizedDescription)")
                currentJob = job
                onProgress(job)
                throw ForgeError.refinementFailed(error.localizedDescription)
            }

            job.log("Re-running OpenAI implementation review after repair...")
            onProgress(job)
            do {
                review = try await refiner.reviewSkillSpec(
                    goal: goal,
                    missing: missing,
                    spec: refined,
                    requirements: requirements,
                    toolList: toolCatalog
                ) { exchange in
                    let header: String
                    switch exchange.phase {
                    case .request:
                        header = "[OpenAI Request]"
                    case .response:
                        header = "[OpenAI Response]"
                    case .error:
                        header = "[OpenAI Error]"
                    }
                    job.log("\(header)\n\(exchange.content)")
                    onProgress(job)
                }
            } catch {
                job.fail("OpenAI post-repair review failed: \(error.localizedDescription)")
                currentJob = job
                onProgress(job)
                throw ForgeError.reviewFailed(error.localizedDescription)
            }

            if !review.summary.isEmpty {
                job.log("OpenAI review summary (retry): \(review.summary)")
            }
            if !review.implementationSteps.isEmpty {
                job.log("OpenAI implementation steps (retry):")
                for (index, step) in review.implementationSteps.enumerated() {
                    job.log("\(index + 1). \(step)")
                }
            }
            if !review.blockers.isEmpty {
                job.log("OpenAI blockers (retry):")
                for blocker in review.blockers {
                    job.log("- \(blocker)")
                }
            }
            onProgress(job)
        }

        if !review.approved {
            let reason = review.summary.isEmpty ? "OpenAI did not approve this capability implementation." : review.summary
            job.fail("Capability not installed: \(reason)")
            currentJob = job
            onProgress(job)
            throw ForgeError.implementationInsufficient(reason)
        }

        if review.implementationSteps.isEmpty {
            let reason = "OpenAI did not provide implementation steps."
            job.fail("Capability not installed: \(reason)")
            currentJob = job
            onProgress(job)
            throw ForgeError.implementationInsufficient(reason)
        }

        // Step 3: (Optional) Claude Code implementation
        job.status = .implementing
        onProgress(job)
        job.log("Skipping Claude Code implementation (not required for JSON-based skills)")

        // Step 4: Validate
        job.log("Validating skill spec...")
        job.status = .testing
        onProgress(job)

        if let error = validateSpec(refined, knownToolNames: Set(toolNames)) {
            job.fail("Validation failed: \(error)")
            currentJob = job
            onProgress(job)
            throw ForgeError.validationFailed(error)
        }
        job.log("Validation passed")

        job.log("Running capability verification checks...")
        let preflight = capabilityVerificationChecks(
            spec: refined,
            goal: goal,
            requirements: requirements,
            review: review,
            knownToolNames: Set(toolNames)
        )
        for check in preflight.checks {
            job.log("\(check.passed ? "PASS" : "FAIL") · \(check.name): \(check.detail)")
        }
        if !preflight.passed {
            let reason = preflight.failureReason
            job.fail("Capability verification failed: \(reason)")
            currentJob = job
            onProgress(job)
            throw ForgeError.verificationFailed(reason)
        }
        job.log("Capability verification passed (\(preflight.passedCount)/\(preflight.checks.count) checks)")

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

        let postInstall = postInstallVerification(specID: refined.id)
        for check in postInstall.checks {
            job.log("\(check.passed ? "PASS" : "FAIL") · \(check.name): \(check.detail)")
        }
        if !postInstall.passed {
            let reason = postInstall.failureReason
            _ = SkillStore.shared.remove(id: refined.id)
            job.fail("Post-install verification failed: \(reason)")
            currentJob = job
            onProgress(job)
            throw ForgeError.verificationFailed(reason)
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
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMissing = missing.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveGoal = !trimmedGoal.isEmpty ? trimmedGoal : (!trimmedMissing.isEmpty ? trimmedMissing : "new capability")
        let name = effectiveGoal.prefix(30).trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = name.isEmpty ? "New Capability" : String(name)

        return SkillSpec(
            id: id,
            name: safeName,
            version: 1,
            triggerPhrases: [effectiveGoal.lowercased()],
            slots: [],
            steps: [
                SkillSpec.StepDef(action: "talk", args: ["say": "I'm working on: \(effectiveGoal)"])
            ],
            onTrigger: nil
        )
    }

    // MARK: - Validation

    /// Returns nil if the spec is valid, or an error message.
    func validateSpec(_ spec: SkillSpec, knownToolNames: Set<String>) -> String? {
        if spec.id.isEmpty { return "Skill ID is empty" }
        if spec.name.isEmpty { return "Skill name is empty" }
        let nonEmptyTriggers = spec.triggerPhrases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if nonEmptyTriggers.isEmpty { return "No trigger phrases" }
        if spec.steps.isEmpty { return "No steps defined" }

        let executableSteps = spec.steps.filter { !$0.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.action != "talk" }
        if executableSteps.isEmpty {
            return "No executable implementation steps (only talk steps found)"
        }

        for step in executableSteps {
            let action = step.action.trimmingCharacters(in: .whitespacesAndNewlines)
            if action == "start_skillforge" {
                return "Self-referential step '\(action)' is not allowed"
            }
            if !knownToolNames.contains(action) {
                return "Unknown tool action '\(action)'"
            }

            let placeholders = extractPlaceholders(from: step.args)
            for placeholder in placeholders {
                guard spec.slots.contains(where: { $0.name == placeholder || "\($0.name)_display" == placeholder }) else {
                    return "Step '\(action)' references unknown slot placeholder '\(placeholder)'"
                }
            }

            if let tool = ToolRegistry.shared.get(action) {
                let required = requiredArgumentNames(for: tool)
                for key in required {
                    let value = step.args[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if value.isEmpty {
                        return "Tool '\(action)' is missing required arg '\(key)'"
                    }
                }
            }
        }

        let sampleSlots = sampleSlotsMap(for: spec)
        let simulatedActions = SkillEngine(forTesting: true).execute(skill: spec, slots: sampleSlots)
        if simulatedActions.isEmpty {
            return "Demo run produced no actions"
        }

        let hasExecutableDemo = simulatedActions.contains { action in
            if case .tool = action { return true }
            return false
        }
        if !hasExecutableDemo {
            return "Demo run did not produce an executable tool action"
        }

        for action in simulatedActions {
            if case .tool(let toolAction) = action {
                guard knownToolNames.contains(toolAction.name) else {
                    return "Demo run produced unknown tool '\(toolAction.name)'"
                }
                for (_, value) in toolAction.args where value.contains("{{") || value.contains("}}") {
                    return "Demo run left unresolved placeholders in tool args"
                }
            }
        }
        return nil
    }

    private struct VerificationCheck {
        let name: String
        let passed: Bool
        let detail: String
    }

    private struct VerificationReport {
        let checks: [VerificationCheck]

        var passed: Bool { checks.allSatisfy(\.passed) }
        var passedCount: Int { checks.filter(\.passed).count }
        var failureReason: String {
            checks.first(where: { !$0.passed })?.detail ?? "unknown verification failure"
        }
    }

    private func capabilityVerificationChecks(spec: SkillSpec,
                                              goal: String,
                                              requirements: OpenAIRefinerClient.CapabilityRequirements,
                                              review: OpenAIRefinerClient.ImplementationReview,
                                              knownToolNames: Set<String>) -> VerificationReport {
        var checks: [VerificationCheck] = []

        let coverage = requirementsCoverage(spec: spec, requirements: requirements, review: review)
        checks.append(
            VerificationCheck(
                name: "Requirements Coverage",
                passed: coverage.coveredCount > 0 && coverage.coverageRatio >= 0.45,
                detail: "covered \(coverage.coveredCount)/\(coverage.totalCount) requirements (\(Int((coverage.coverageRatio * 100).rounded()))%)"
            )
        )

        if let error = validateSpec(spec, knownToolNames: knownToolNames) {
            checks.append(VerificationCheck(name: "Spec + Demo Validation", passed: false, detail: error))
        } else {
            checks.append(VerificationCheck(name: "Spec + Demo Validation", passed: true, detail: "spec compiles into runnable demo actions"))
        }

        checks.append(
            VerificationCheck(
                name: "OpenAI Implementation Steps",
                passed: !review.implementationSteps.isEmpty,
                detail: review.implementationSteps.isEmpty
                    ? "OpenAI review did not provide implementation steps"
                    : "OpenAI supplied \(review.implementationSteps.count) implementation steps"
            )
        )

        let triggerCoverage = triggerAlignment(goal: goal, triggers: spec.triggerPhrases)
        checks.append(
            VerificationCheck(
                name: "Trigger Alignment",
                passed: triggerCoverage >= 0.20,
                detail: "goal-to-trigger overlap \(Int((triggerCoverage * 100).rounded()))%"
            )
        )

        return VerificationReport(checks: checks)
    }

    private func postInstallVerification(specID: String) -> VerificationReport {
        var checks: [VerificationCheck] = []

        let fileURL = SkillStore.shared.skillFileURL(id: specID)
        let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
        checks.append(
            VerificationCheck(
                name: "Skill File Written",
                passed: fileExists,
                detail: fileExists ? "wrote \(fileURL.path)" : "skill file missing at \(fileURL.path)"
            )
        )

        let installedOnDisk = SkillStore.shared.isInstalledOnDisk(id: specID)
        checks.append(
            VerificationCheck(
                name: "Installed Metadata",
                passed: installedOnDisk,
                detail: installedOnDisk
                    ? "skill status is active + approved"
                    : "skill is not active/approved on disk"
            )
        )

        return VerificationReport(checks: checks)
    }

    private func requirementsCoverage(spec: SkillSpec,
                                      requirements: OpenAIRefinerClient.CapabilityRequirements,
                                      review: OpenAIRefinerClient.ImplementationReview) -> (coveredCount: Int, totalCount: Int, coverageRatio: Double) {
        let requirementLines = (requirements.requirements + requirements.acceptanceCriteria)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !requirementLines.isEmpty else { return (0, 0, 1.0) }

        let specText = [
            spec.name,
            spec.triggerPhrases.joined(separator: " "),
            spec.steps.map { step in
                let argsText = step.args.values.joined(separator: " ")
                return "\(step.action) \(argsText)"
            }.joined(separator: " "),
            review.implementationSteps.joined(separator: " ")
        ].joined(separator: " ")
        let specTokenSet = Set(LocalKnowledgeRetriever.tokens(from: specText))

        var covered = 0
        for line in requirementLines {
            let reqTokens = Set(LocalKnowledgeRetriever.tokens(from: line))
            guard !reqTokens.isEmpty else { continue }
            let overlap = reqTokens.intersection(specTokenSet).count
            let ratio = Double(overlap) / Double(reqTokens.count)
            if ratio >= 0.25 { covered += 1 }
        }

        let total = requirementLines.count
        let ratio = total == 0 ? 1.0 : Double(covered) / Double(total)
        return (covered, total, ratio)
    }

    private func triggerAlignment(goal: String, triggers: [String]) -> Double {
        let goalTokens = Set(LocalKnowledgeRetriever.tokens(from: goal))
        guard !goalTokens.isEmpty else { return 1.0 }
        let triggerTokens = Set(LocalKnowledgeRetriever.tokens(from: triggers.joined(separator: " ")))
        guard !triggerTokens.isEmpty else { return 0.0 }
        let overlap = goalTokens.intersection(triggerTokens).count
        return Double(overlap) / Double(goalTokens.count)
    }

    private func sampleSlotsMap(for spec: SkillSpec) -> [String: String] {
        var slots: [String: String] = [:]
        let now = Date().addingTimeInterval(3_600)
        for slot in spec.slots {
            switch slot.type {
            case .date:
                slots[slot.name] = String(now.timeIntervalSince1970)
                slots["\(slot.name)_display"] = SkillEngine(forTesting: true).formatDateForDisplay(now)
            case .string:
                slots[slot.name] = "sample"
            case .number:
                slots[slot.name] = "1"
            }
        }
        return slots
    }

    private func extractPlaceholders(from args: [String: String]) -> Set<String> {
        let pattern = #"\{\{\s*([^}\s]+)\s*\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var found: Set<String> = []
        for value in args.values {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            regex.enumerateMatches(in: value, options: [], range: range) { match, _, _ in
                guard let match,
                      match.numberOfRanges > 1,
                      let captureRange = Range(match.range(at: 1), in: value)
                else { return }
                found.insert(String(value[captureRange]))
            }
        }
        return found
    }

    private func requiredArgumentNames(for tool: Tool) -> Set<String> {
        let description = tool.description
        let patterns = [
            #"'([A-Za-z0-9_]+)'\s*\(required\)"#,
            #"required\s*:\s*'([A-Za-z0-9_]+)'"#,
            #"required\s+arg[s]?\s*[:=]\s*([A-Za-z0-9_,\s]+)"#
        ]

        var required: Set<String> = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(description.startIndex..<description.endIndex, in: description)
            regex.enumerateMatches(in: description, options: [], range: range) { match, _, _ in
                guard let match else { return }
                if match.numberOfRanges > 1,
                   let capture = Range(match.range(at: 1), in: description) {
                    let raw = String(description[capture])
                    if raw.contains(",") {
                        raw.split(separator: ",").forEach { token in
                            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { required.insert(trimmed) }
                        }
                    } else {
                        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { required.insert(trimmed) }
                    }
                }
            }
        }
        return required
    }

    // MARK: - Errors

    enum ForgeError: Error, LocalizedError {
        case requirementsFailed(String)
        case refinementFailed(String)
        case reviewFailed(String)
        case implementationInsufficient(String)
        case validationFailed(String)
        case verificationFailed(String)
        case installFailed

        var errorDescription: String? {
            switch self {
            case .requirementsFailed(let msg): return "Capability requirements failed: \(msg)"
            case .refinementFailed(let msg): return "Skill refinement failed: \(msg)"
            case .reviewFailed(let msg): return "Skill review failed: \(msg)"
            case .implementationInsufficient(let msg): return "Implementation is insufficient: \(msg)"
            case .validationFailed(let msg): return "Skill validation failed: \(msg)"
            case .verificationFailed(let msg): return "Capability verification failed: \(msg)"
            case .installFailed: return "Failed to install forged skill"
            }
        }
    }
}
