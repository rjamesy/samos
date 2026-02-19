import Foundation
import CryptoKit

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
    private let useJSONSkillForgePipeline = true

    private init() {}

    // MARK: - Forge Pipeline

    /// Main forge pipeline. Builds a new skill from a goal description.
    /// The progress callback is called whenever the job updates.
    func forge(goal: String, missing: String, onProgress: @escaping (SkillForgeJob) -> Void) async throws -> SkillSpec {
        if useJSONSkillForgePipeline {
            return try await forgeViaPackagePipeline(goal: goal, missing: missing, onProgress: onProgress)
        }

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

// MARK: - Phase 5 Permission + Tool Package Stores

enum PermissionScope: String, CaseIterable, Codable {
    case webRead = "web.read"
}

final class PermissionScopeStore {
    static let shared = PermissionScopeStore()

    private let defaults: UserDefaults
    private let key = "samos.permission_scopes.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isApproved(_ scope: String) -> Bool {
        approvedScopes().contains(scope)
    }

    func set(scope: String, approved: Bool) {
        var current = approvedScopes()
        if approved {
            current.insert(scope)
        } else {
            current.remove(scope)
        }
        save(scopes: current)
    }

    func approve(scopes: [String]) {
        guard !scopes.isEmpty else { return }
        var current = approvedScopes()
        for scope in scopes where !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current.insert(scope)
        }
        save(scopes: current)
    }

    func reset() {
        defaults.removeObject(forKey: key)
    }

    func approvedScopeList() -> [String] {
        Array(approvedScopes()).sorted()
    }

    private func approvedScopes() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    private func save(scopes: Set<String>) {
        defaults.set(Array(scopes).sorted(), forKey: key)
    }
}

struct ToolPackageManifest: Codable, Equatable {
    let id: String
    let tools: [String]
    let permissions: [String]
    let installedAtISO8601: String
}

struct ToolPackageInstallResult: Equatable {
    let installed: Bool
    let reason: String
}

enum ToolPermissionCatalog {
    static func requiredPermissions(for toolName: String) -> [String] {
        switch toolName {
        case "news.fetch":
            return [PermissionScope.webRead.rawValue]
        default:
            return []
        }
    }

    static func packageID(for toolName: String) -> String? {
        switch toolName {
        case "news.fetch":
            return "news.basic"
        default:
            return nil
        }
    }
}

final class ToolPackageStore {
    static let shared = ToolPackageStore()

    private let queue = DispatchQueue(label: "SamOS.ToolPackageStore")
    private let fileURL: URL
    private let permissionStore: PermissionScopeStore
    private var cache: [String: ToolPackageManifest] = [:]

    init(fileURL: URL? = nil, permissionStore: PermissionScopeStore = .shared) {
        self.permissionStore = permissionStore
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("SamOS", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("tool_packages.json")
        }
        load()
    }

    func isInstalled(_ packageID: String) -> Bool {
        queue.sync { cache[packageID] != nil }
    }

    func listInstalled() -> [ToolPackageManifest] {
        queue.sync { Array(cache.values).sorted { $0.id < $1.id } }
    }

    @discardableResult
    func install(packageID: String,
                 tools: [String],
                 permissions: [String]) -> ToolPackageInstallResult {
        let cleanedID = packageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedID.isEmpty else {
            return ToolPackageInstallResult(installed: false, reason: "Missing package id")
        }
        let cleanTools = normalizedValues(from: tools)
        let cleanPermissions = normalizedValues(from: permissions)

        let missingPermissions = cleanPermissions.filter { !permissionStore.isApproved($0) }
        guard missingPermissions.isEmpty else {
            return ToolPackageInstallResult(
                installed: false,
                reason: "Missing approved permissions: \(missingPermissions.joined(separator: ", "))"
            )
        }
        return queue.sync {
            if let existing = cache[cleanedID] {
                let mergedTools = normalizedValues(from: existing.tools + cleanTools)
                let mergedPermissions = normalizedValues(from: existing.permissions + cleanPermissions)
                cache[cleanedID] = ToolPackageManifest(
                    id: cleanedID,
                    tools: mergedTools,
                    permissions: mergedPermissions,
                    installedAtISO8601: ISO8601DateFormatter().string(from: Date())
                )
                persistLocked()
                return ToolPackageInstallResult(installed: true, reason: "updated")
            }

            if let reusedID = equivalentInstalledPackageIDLocked(tools: cleanTools, permissions: cleanPermissions) {
                return ToolPackageInstallResult(
                    installed: true,
                    reason: "reused_existing:\(reusedID)"
                )
            }

            cache[cleanedID] = ToolPackageManifest(
                id: cleanedID,
                tools: cleanTools,
                permissions: cleanPermissions,
                installedAtISO8601: ISO8601DateFormatter().string(from: Date())
            )
            persistLocked()
            return ToolPackageInstallResult(installed: true, reason: "installed")
        }
    }

    @discardableResult
    func uninstall(_ packageID: String) -> Bool {
        queue.sync {
            guard cache.removeValue(forKey: packageID) != nil else { return false }
            persistLocked()
            return true
        }
    }

    func reset() {
        queue.sync {
            cache.removeAll()
            persistLocked()
        }
    }

    private func load() {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let manifests = try? JSONDecoder().decode([ToolPackageManifest].self, from: data) else {
                cache = [:]
                return
            }
            cache = Dictionary(uniqueKeysWithValues: manifests.map { ($0.id, $0) })
        }
    }

    private func persistLocked() {
        let manifests = Array(cache.values).sorted { $0.id < $1.id }
        guard let data = try? JSONEncoder().encode(manifests) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func equivalentInstalledPackageIDLocked(tools: [String], permissions: [String]) -> String? {
        let requestedSignature = packageSignature(tools: tools, permissions: permissions)
        guard !requestedSignature.isEmpty else { return nil }

        let matches = cache.values
            .filter { packageSignature(tools: $0.tools, permissions: $0.permissions) == requestedSignature }
            .map(\.id)
            .sorted()
        guard !matches.isEmpty else { return nil }

        let preferred = preferredPackageID(forTools: tools, among: matches)
        return preferred ?? matches.first
    }

    private func preferredPackageID(forTools tools: [String], among ids: [String]) -> String? {
        let canonicalCandidates = Set(tools.compactMap { ToolPermissionCatalog.packageID(for: $0) })
        for candidate in canonicalCandidates.sorted() where ids.contains(candidate) {
            return candidate
        }
        return nil
    }

    private func packageSignature(tools: [String], permissions: [String]) -> String {
        let normalizedTools = normalizedValues(from: tools)
        let normalizedPermissions = normalizedValues(from: permissions)
        return "\(normalizedTools.joined(separator: ","))|\(normalizedPermissions.joined(separator: ","))"
    }

    private func normalizedValues(from values: [String]) -> [String] {
        Array(
            Set(
                values
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        ).sorted()
    }
}

// MARK: - Phase 5 LearnSkillController

protocol SkillForgePipelineRunning {
    func run(requirements: SkillForgeRequirements,
             onLog: @escaping (String) -> Void,
             installOnApproval: Bool) async -> SkillForgePipelineOutcome
}

extension SkillForgePipelineV2: SkillForgePipelineRunning {}

enum LearnSkillState: String, Codable {
    case idle = "Idle"
    case intake = "Intake"
    case toolDiscovery = "ToolDiscovery"
    case gptDesignLoop = "GPTDesignLoop"
    case localValidate = "LocalValidate"
    case simulate = "Simulate"
    case userPermissionReview = "UserPermissionReview"
    case install = "Install"
    case verify = "Verify"
    case done = "Done"
    case blocked = "Blocked"
}

struct LearnSkillRequirements: Codable, Equatable {
    var goal: String
    var mustDo: [String]
    var mustNotDo: [String]
    var inputExamples: [String]
    var outputExamples: [String]
    var permissionsAllowed: [String]
    var toolsAllowed: [String]
    var constraints: [String: String]

    enum CodingKeys: String, CodingKey {
        case goal
        case mustDo = "must_do"
        case mustNotDo = "must_not_do"
        case inputExamples = "inputs_examples"
        case outputExamples = "expected_outputs_examples"
        case permissionsAllowed = "permissions_allowed"
        case toolsAllowed = "tools_allowed"
        case constraints
    }
}

struct LearnSkillSession: Codable, Equatable {
    let id: UUID
    let createdAtISO8601: String
    var updatedAtISO8601: String
    var state: LearnSkillState
    var requirements: LearnSkillRequirements
    var requestedPermissions: [String]
    var requestedTools: [String]
    var userApprovedPermissions: Bool?
    var gptApproved: Bool
    var iterationCount: Int
    var iterationHistory: [String]
    var blockedReason: String?
    var package: SkillPackage?
}

enum LearnSkillEvent {
    case message(String)
    case output(OutputItem)
    case state(LearnSkillSession)
}

@MainActor
final class LearnSkillController {
    static let shared = LearnSkillController()

    var onEvent: ((LearnSkillEvent) -> Void)?

    private(set) var activeSession: LearnSkillSession?

    private let logger: AppLogger
    private let persistenceURL: URL
    private let pipelineFactory: () -> SkillForgePipelineRunning
    private let skillStore: SkillStore
    private let toolPackageStore: ToolPackageStore
    private let permissionStore: PermissionScopeStore
    private var currentTask: Task<Void, Never>?

    init(logger: AppLogger = JSONLineLogger(),
         persistenceURL: URL? = nil,
         pipelineFactory: (() -> SkillForgePipelineRunning)? = nil,
         skillStore: SkillStore = .shared,
         toolPackageStore: ToolPackageStore = .shared,
         permissionStore: PermissionScopeStore = .shared) {
        self.logger = logger
        if let persistenceURL {
            self.persistenceURL = persistenceURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("SamOS", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.persistenceURL = dir.appendingPathComponent("learn_skill_session.json")
        }
        self.pipelineFactory = pipelineFactory ?? { SkillForgePipelineV2(gptClient: OpenAISkillArchitectClient()) }
        self.skillStore = skillStore
        self.toolPackageStore = toolPackageStore
        self.permissionStore = permissionStore
        loadPersistedSession()
        resumeIfNeeded()
    }

    @discardableResult
    func start(goalText: String,
               missing: String? = nil,
               constraints: [String] = [],
               toolsAllowed: [String] = [],
               permissionsAllowed: [String] = []) -> LearnSkillSession {
        let trimmedGoal = goalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let activeSession, activeSession.state != .done, activeSession.state != .blocked {
            emit(.message("A learning session is already active."))
            return activeSession
        }

        let id = UUID()
        let now = ISO8601DateFormatter().string(from: Date())
        let requirements = LearnSkillRequirements(
            goal: trimmedGoal.isEmpty ? "new skill requested by user" : trimmedGoal,
            mustDo: [missing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmedGoal]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            mustNotDo: [],
            inputExamples: [],
            outputExamples: [],
            permissionsAllowed: permissionsAllowed.sorted(),
            toolsAllowed: toolsAllowed.sorted(),
            constraints: constraints.isEmpty ? [:] : ["notes": constraints.joined(separator: " | ")]
        )

        let session = LearnSkillSession(
            id: id,
            createdAtISO8601: now,
            updatedAtISO8601: now,
            state: .intake,
            requirements: requirements,
            requestedPermissions: [],
            requestedTools: [],
            userApprovedPermissions: nil,
            gptApproved: false,
            iterationCount: 0,
            iterationHistory: [],
            blockedReason: nil,
            package: nil
        )
        activeSession = session
        persist()

        logger.info("learn_skill_started", metadata: [
            "skill_id": normalizedSkillID(from: requirements.goal),
            "iteration": "0",
            "stage": LearnSkillState.intake.rawValue
        ])
        emit(.state(session))
        emit(.message("I can learn that. I'll design a skill and request permissions before installing anything."))

        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.runDesignLoop(sessionID: id)
        }
        return session
    }

    func statusSummary() -> String {
        guard let session = activeSession else {
            return "No active skill-learning session."
        }
        var parts: [String] = [
            "Session `\(session.id.uuidString.prefix(8))`",
            "State: \(session.state.rawValue)",
            "Goal: \(session.requirements.goal)"
        ]
        if !session.requestedPermissions.isEmpty {
            parts.append("Requested permissions: \(session.requestedPermissions.joined(separator: ", "))")
        }
        if let approved = session.userApprovedPermissions {
            parts.append("User permissions approved: \(approved ? "yes" : "no")")
        }
        if session.iterationCount > 0 {
            parts.append("Iterations: \(session.iterationCount)")
        }
        if let reason = session.blockedReason, !reason.isEmpty {
            parts.append("Blocked: \(reason)")
        }
        return parts.joined(separator: "\n")
    }

    func approvePermissions(_ approved: Bool) -> String {
        guard var session = activeSession else {
            return "No active learning session."
        }
        guard session.state == .userPermissionReview else {
            return "Permissions are not pending in the current state (\(session.state.rawValue))."
        }

        session.userApprovedPermissions = approved
        if approved {
            logger.info("learn_skill_user_approved", metadata: [
                "skill_id": session.package?.manifest.skillID ?? normalizedSkillID(from: session.requirements.goal),
                "iteration": String(session.iterationCount),
                "stage": LearnSkillState.userPermissionReview.rawValue
            ])
            session = transition(session, to: .userPermissionReview)
            activeSession = session
            persist()
            emit(.state(session))
            return "Permissions approved. Ready to install."
        }

        logger.info("learn_skill_user_rejected", metadata: [
            "skill_id": session.package?.manifest.skillID ?? normalizedSkillID(from: session.requirements.goal),
            "iteration": String(session.iterationCount),
            "stage": LearnSkillState.blocked.rawValue
        ])
        session.blockedReason = "User rejected requested permissions"
        session = transition(session, to: .blocked)
        activeSession = session
        persist()
        emit(.state(session))
        emit(.message("Okay, I won't install that skill."))
        return "Skill install canceled because permissions were rejected."
    }

    func cancel() -> String {
        currentTask?.cancel()
        currentTask = nil
        guard var session = activeSession else {
            return "No active learning session."
        }
        session.blockedReason = "Canceled by user"
        session = transition(session, to: .blocked)
        activeSession = session
        persist()
        logger.info("learn_skill_blocked", metadata: [
            "skill_id": session.package?.manifest.skillID ?? normalizedSkillID(from: session.requirements.goal),
            "iteration": String(session.iterationCount),
            "stage": LearnSkillState.blocked.rawValue
        ])
        emit(.state(session))
        return "Learning session canceled."
    }

    func installApprovedSkill() async -> String {
        guard var session = activeSession else {
            return "No active learning session."
        }
        guard session.state == .userPermissionReview else {
            return "Install is only available from UserPermissionReview state."
        }
        guard session.userApprovedPermissions == true else {
            return "User permissions are not approved."
        }
        guard let package = session.package, package.signoff?.approved == true else {
            return "No GPT-approved package is ready to install."
        }

        session = transition(session, to: .install)
        activeSession = session
        persist()
        emit(.state(session))

        if !session.requestedPermissions.isEmpty {
            permissionStore.approve(scopes: session.requestedPermissions)
        }

        let toolInstall = installRequiredToolPackages(for: session)
        guard toolInstall.installed else {
            session.blockedReason = toolInstall.reason
            session = transition(session, to: .blocked)
            activeSession = session
            persist()
            emit(.state(session))
            logger.error("learn_skill_blocked", metadata: [
                "skill_id": package.manifest.skillID,
                "iteration": String(session.iterationCount),
                "stage": LearnSkillState.install.rawValue
            ])
            return "Install blocked: \(toolInstall.reason)"
        }

        guard skillStore.installPackage(package) else {
            session.blockedReason = "Failed to write skill package"
            session = transition(session, to: .blocked)
            activeSession = session
            persist()
            emit(.state(session))
            logger.error("learn_skill_blocked", metadata: [
                "skill_id": package.manifest.skillID,
                "iteration": String(session.iterationCount),
                "stage": LearnSkillState.install.rawValue
            ])
            return "Install blocked: failed to persist skill package."
        }

        session = transition(session, to: .verify)
        activeSession = session
        persist()
        emit(.state(session))

        let verifyResult = await verifyInstalledPackage(package)
        guard verifyResult else {
            _ = skillStore.removePackage(id: package.manifest.skillID)
            session.blockedReason = "Post-install verification failed"
            session = transition(session, to: .blocked)
            activeSession = session
            persist()
            emit(.state(session))
            logger.error("learn_skill_blocked", metadata: [
                "skill_id": package.manifest.skillID,
                "iteration": String(session.iterationCount),
                "stage": LearnSkillState.verify.rawValue
            ])
            return "Install blocked: verification failed."
        }

        let linkedCapabilities = resolveCapabilityLinks(session: session, package: package)
        if linkedCapabilities.isEmpty {
            SkillCapabilityLinkStore.shared.remove(skillID: package.manifest.skillID)
        } else {
            SkillCapabilityLinkStore.shared.setCapabilities(linkedCapabilities, forSkillID: package.manifest.skillID)
        }

        session = transition(session, to: .done)
        activeSession = session
        persist()
        logger.info("learn_skill_installed", metadata: [
            "skill_id": package.manifest.skillID,
            "iteration": String(session.iterationCount),
            "stage": LearnSkillState.done.rawValue
        ])
        emit(.state(session))
        emit(.message("Installed skill `\(package.manifest.name)`. You can use it now."))
        return "Installed `\(package.manifest.skillID)` successfully."
    }

    private func runDesignLoop(sessionID: UUID) async {
        guard var session = activeSession, session.id == sessionID else { return }

        session = transition(session, to: .toolDiscovery)
        activeSession = session
        persist()
        logger.info("learn_skill_requirements_updated", metadata: [
            "skill_id": normalizedSkillID(from: session.requirements.goal),
            "iteration": "0",
            "stage": LearnSkillState.toolDiscovery.rawValue
        ])
        emit(.state(session))

        session = transition(session, to: .gptDesignLoop)
        activeSession = session
        persist()
        emit(.state(session))

        let missingDescription = session.requirements.mustDo.joined(separator: "; ")
        let constraints = session.requirements.constraints.values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let requirements = SkillForgeRequirements(
            goal: session.requirements.goal,
            missing: missingDescription.isEmpty ? session.requirements.goal : missingDescription,
            constraints: constraints
        )

        let pipeline = pipelineFactory()
        let outcome = await pipeline.run(requirements: requirements, onLog: { [weak self] line in
            Task { @MainActor in
                guard let self, var current = self.activeSession, current.id == sessionID else { return }
                current.iterationHistory.append(line)
                if current.iterationHistory.count > 200 {
                    current.iterationHistory.removeFirst(current.iterationHistory.count - 200)
                }
                current.iterationCount = max(current.iterationCount, self.extractIteration(from: line))
                if let stage = self.stateFromPipelineLog(line) {
                    current = self.transition(current, to: stage)
                }
                self.activeSession = current
                self.persist()
                self.emit(.state(current))
            }
        }, installOnApproval: false)

        guard var finalSession = activeSession, finalSession.id == sessionID else { return }
        finalSession.iterationCount = max(finalSession.iterationCount, outcome.iterations)

        guard outcome.approved, let package = outcome.installedPackage else {
            finalSession.blockedReason = outcome.blockedReason ?? outcome.lastCritique ?? "GPT did not approve a package"
            finalSession = transition(finalSession, to: .blocked)
            activeSession = finalSession
            persist()
            emit(.state(finalSession))
            emit(.message("Skill learning blocked: \(finalSession.blockedReason ?? "Unknown reason")."))
            logger.error("learn_skill_blocked", metadata: [
                "skill_id": normalizedSkillID(from: finalSession.requirements.goal),
                "iteration": String(finalSession.iterationCount),
                "stage": LearnSkillState.blocked.rawValue
            ])
            return
        }

        var requestedTools = Set(package.plan.toolRequirements.map(\.name))
        for explicit in finalSession.requirements.toolsAllowed where !explicit.isEmpty {
            requestedTools.insert(explicit)
        }
        var requestedPermissions = Set(package.plan.toolRequirements.flatMap(\.permissions))
        for tool in requestedTools {
            for permission in ToolPermissionCatalog.requiredPermissions(for: tool) {
                requestedPermissions.insert(permission)
            }
        }
        for permission in finalSession.requirements.permissionsAllowed where !permission.isEmpty {
            requestedPermissions.insert(permission)
        }

        finalSession.package = package
        finalSession.gptApproved = package.signoff?.approved == true
        finalSession.requestedTools = Array(requestedTools).sorted()
        finalSession.requestedPermissions = Array(requestedPermissions).sorted()
        finalSession.userApprovedPermissions = nil
        finalSession.blockedReason = nil
        finalSession = transition(finalSession, to: .userPermissionReview)
        activeSession = finalSession
        persist()

        logger.info("learn_skill_permissions_requested", metadata: [
            "skill_id": package.manifest.skillID,
            "iteration": String(finalSession.iterationCount),
            "stage": LearnSkillState.userPermissionReview.rawValue
        ])
        emit(.state(finalSession))
        emit(.message("I designed `\(package.manifest.name)`. Review and approve permissions to install."))
        emit(.output(permissionReviewCard(for: finalSession, package: package)))
    }

    private func installRequiredToolPackages(for session: LearnSkillSession) -> ToolPackageInstallResult {
        for tool in session.requestedTools {
            guard let packageID = ToolPermissionCatalog.packageID(for: tool) else { continue }
            if toolPackageStore.isInstalled(packageID) {
                continue
            }
            let permissions = ToolPermissionCatalog.requiredPermissions(for: tool)
            let result = toolPackageStore.install(
                packageID: packageID,
                tools: [tool],
                permissions: permissions
            )
            if !result.installed {
                return result
            }
        }
        return ToolPackageInstallResult(installed: true, reason: "installed")
    }

    private func verifyInstalledPackage(_ package: SkillPackage) async -> Bool {
        let harness = SkillSimHarness()
        let report = await harness.run(
            package: package,
            toolRuntime: ToolRegistrySkillRuntime(),
            llmRuntime: DeterministicSkillLLMRuntime()
        )
        guard report.passed else { return false }

        let runtime = SkillPackageRuntime()
        let smokeInput = package.tests.first?.inputText ?? package.plan.intentPatterns.first ?? package.manifest.name
        let exec = await runtime.execute(
            package: package,
            inputText: smokeInput,
            toolRuntime: ToolRegistrySkillRuntime(),
            llmRuntime: DeterministicSkillLLMRuntime()
        )
        return exec.success
    }

    private func resolveCapabilityLinks(session: LearnSkillSession, package: SkillPackage) -> [String] {
        var capabilityIDs: Set<String> = Set(SkillCapabilityLinkStore.shared.capabilities(forSkillID: package.manifest.skillID))
        for tool in session.requestedTools {
            if let capabilityID = CapabilityCatalog.shared.capabilityID(forTool: tool) {
                capabilityIDs.insert(capabilityID)
            }
        }
        for tool in package.plan.toolRequirements.map(\.name) {
            if let capabilityID = CapabilityCatalog.shared.capabilityID(forTool: tool) {
                capabilityIDs.insert(capabilityID)
            }
        }
        return Array(capabilityIDs).sorted()
    }

    private func permissionReviewCard(for session: LearnSkillSession, package: SkillPackage) -> OutputItem {
        let payload: [String: Any] = [
            "type": "learn_skill_permission_review",
            "session_id": session.id.uuidString,
            "skill_id": package.manifest.skillID,
            "skill_name": package.manifest.name,
            "goal": session.requirements.goal,
            "permissions": session.requestedPermissions,
            "tools": session.requestedTools,
            "tests": package.tests.map(\.name)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return OutputItem(kind: .card, payload: "{\"type\":\"learn_skill_permission_review\"}")
        }
        return OutputItem(kind: .card, payload: json)
    }

    private func transition(_ session: LearnSkillSession, to state: LearnSkillState) -> LearnSkillSession {
        var updated = session
        updated.state = state
        updated.updatedAtISO8601 = ISO8601DateFormatter().string(from: Date())
        return updated
    }

    private func emit(_ event: LearnSkillEvent) {
        onEvent?(event)
    }

    private func persist() {
        guard let session = activeSession else {
            try? FileManager.default.removeItem(at: persistenceURL)
            return
        }
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: persistenceURL, options: .atomic)
    }

    private func loadPersistedSession() {
        guard let data = try? Data(contentsOf: persistenceURL),
              let decoded = try? JSONDecoder().decode(LearnSkillSession.self, from: data) else {
            activeSession = nil
            return
        }
        activeSession = decoded
    }

    private func resumeIfNeeded() {
        guard let session = activeSession else { return }
        switch session.state {
        case .intake, .toolDiscovery, .gptDesignLoop, .localValidate, .simulate:
            currentTask = Task { [weak self] in
                guard let self else { return }
                await self.runDesignLoop(sessionID: session.id)
            }
        default:
            break
        }
    }

    private func normalizedSkillID(from text: String) -> String {
        let lowered = text.lowercased()
        let parts = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let joined = parts.filter { !$0.isEmpty }.joined(separator: "_")
        return joined.isEmpty ? "skill" : joined
    }

    private func extractIteration(from logLine: String) -> Int {
        let pattern = #"\biteration\s+(\d+)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return 0
        }
        let range = NSRange(logLine.startIndex..<logLine.endIndex, in: logLine)
        guard let match = regex.firstMatch(in: logLine, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: logLine),
              let value = Int(logLine[valueRange]) else {
            return 0
        }
        return value
    }

    private func stateFromPipelineLog(_ line: String) -> LearnSkillState? {
        guard let start = line.firstIndex(of: "["),
              let end = line.firstIndex(of: "]"),
              start < end else {
            return nil
        }
        let stage = line[line.index(after: start)..<end]
        switch stage.lowercased() {
        case "draftplan", "draftspec", "draftpackage", "submitforgptapproval", "revise":
            return .gptDesignLoop
        case "validatelocal":
            return .localValidate
        case "simulate":
            return .simulate
        case "install":
            return .install
        case "blocked":
            return .blocked
        default:
            return nil
        }
    }
}

// MARK: - Phase 4: JSON Skill Runtime + GPT Loop

struct SkillForgeRequirements: Equatable {
    var goal: String
    var missing: String
    var constraints: [String]
}

struct SkillToolDescriptor: Equatable {
    var name: String
    var description: String
    var permissions: [String]
}

struct SkillForgeFeedback: Equatable {
    var localValidationErrors: [String]
    var simulationFailures: [String]
    var gptRequiredChanges: [String]
    var critique: String?

    static let empty = SkillForgeFeedback(
        localValidationErrors: [],
        simulationFailures: [],
        gptRequiredChanges: [],
        critique: nil
    )
}

enum SkillForgePipelineStage: String {
    case draftPlan = "DraftPlan"
    case draftSpec = "DraftSpec"
    case draftPackage = "DraftPackage"
    case validateLocal = "ValidateLocal"
    case simulate = "Simulate"
    case submitForApproval = "SubmitForGPTApproval"
    case revise = "Revise"
    case approved = "Approved"
    case install = "Install"
    case blocked = "Blocked"
}

struct SkillForgePipelineOutcome {
    var approved: Bool
    var installedPackage: SkillPackage?
    var iterations: Int
    var blockedReason: String?
    var lastCritique: String?
    var requiredChanges: [String]
}

protocol SkillForgeGPTClient {
    var modelName: String { get }
    func makePlan(requirements: SkillForgeRequirements,
                  availableTools: [SkillToolDescriptor],
                  feedback: SkillForgeFeedback) async throws -> SkillPlan
    func makeSpec(plan: SkillPlan,
                  requirements: SkillForgeRequirements,
                  feedback: SkillForgeFeedback) async throws -> SkillSpecV2
    func buildPackage(plan: SkillPlan,
                      spec: SkillSpecV2,
                      requirements: SkillForgeRequirements,
                      feedback: SkillForgeFeedback) async throws -> SkillPackage
    func approve(package: SkillPackage,
                 validation: SkillValidationResult,
                 simulation: SkillSimulationReport) async throws -> SkillApproverResponse
}

struct SkillToolCallResult {
    var success: Bool
    var output: [String: SkillJSONValue]
    var error: String?
}

protocol SkillPackageToolRuntime {
    func callTool(name: String, args: [String: String]) -> SkillToolCallResult
}

protocol SkillPackageLLMRuntime {
    func run(prompt: String,
             temperature: Double,
             maxOutputTokens: Int,
             jsonOnly: Bool) async throws -> String
}

struct SkillSchemaValidator {
    static func compile(_ schema: SkillJSONSchema, path: String) -> [String] {
        var errors: [String] = []
        switch schema.type {
        case .object:
            for requiredKey in schema.required where schema.properties[requiredKey] == nil {
                errors.append("\(path) missing required property declaration for '\(requiredKey)'")
            }
            for (key, property) in schema.properties {
                errors.append(contentsOf: compile(property, path: "\(path).\(key)"))
            }
        case .array:
            if let items = schema.items {
                errors.append(contentsOf: compile(items, path: "\(path)[]"))
            } else {
                errors.append("\(path) array schema is missing items schema")
            }
        case .string, .number, .integer, .boolean, .null:
            break
        }
        return errors
    }

    static func validate(value: SkillJSONValue, schema: SkillJSONSchema, path: String) -> [String] {
        var errors: [String] = []
        switch (schema.type, value) {
        case (.object, .object(let object)):
            for key in schema.required where object[key] == nil {
                errors.append("\(path) missing required key '\(key)'")
            }
            for (key, item) in object {
                guard let propertySchema = schema.properties[key] else {
                    if !schema.additionalProperties {
                        errors.append("\(path).\(key) is not allowed by schema")
                    }
                    continue
                }
                errors.append(contentsOf: validate(value: item, schema: propertySchema, path: "\(path).\(key)"))
            }
        case (.array, .array(let array)):
            if let itemSchema = schema.items {
                for (index, item) in array.enumerated() {
                    errors.append(contentsOf: validate(value: item, schema: itemSchema, path: "\(path)[\(index)]"))
                }
            } else {
                errors.append("\(path) array schema is missing items schema")
            }
        case (.string, .string(let text)):
            if let allowed = schema.enumValues, !allowed.isEmpty, !allowed.contains(text) {
                errors.append("\(path) value '\(text)' is not in enum \(allowed)")
            }
        case (.number, .number):
            break
        case (.integer, .number(let value)):
            if floor(value) != value {
                errors.append("\(path) expected integer but received \(value)")
            }
        case (.boolean, .bool):
            break
        case (.null, .null):
            break
        default:
            errors.append("\(path) has type mismatch (expected \(schema.type.rawValue))")
        }
        return errors
    }
}

struct SkillPackageValidator {
    func validate(package: SkillPackage, availableToolNames: Set<String>) -> SkillValidationResult {
        var errors: [String] = []
        var warnings: [String] = []

        if package.manifest.skillID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("manifest.skill_id is required")
        }
        if package.plan.skillID != package.manifest.skillID {
            errors.append("plan.skill_id must match manifest.skill_id")
        }
        if package.spec.steps.isEmpty {
            errors.append("spec.steps must not be empty")
        }
        if package.tests.isEmpty {
            errors.append("tests must not be empty")
        }
        if package.plan.testCases.isEmpty {
            errors.append("plan.test_cases must not be empty")
        }

        errors.append(contentsOf: SkillSchemaValidator.compile(package.plan.inputsSchema, path: "plan.inputs_schema"))
        errors.append(contentsOf: SkillSchemaValidator.compile(package.plan.outputsSchema, path: "plan.outputs_schema"))

        if package.spec.limits.maxOutputChars <= 0 || package.spec.limits.maxOutputChars > 5_000 {
            errors.append("spec.limits.max_output_chars must be in 1...5000")
        }
        if package.spec.limits.maxOutputTokens <= 0 || package.spec.limits.maxOutputTokens > 2_000 {
            errors.append("spec.limits.max_output_tokens must be in 1...2000")
        }
        if package.spec.limits.timeoutMs <= 0 || package.spec.limits.timeoutMs > 120_000 {
            errors.append("spec.limits.timeout_ms must be in 1...120000")
        }

        let declaredTools = Set(package.plan.toolRequirements.map(\.name))
        for requirement in package.plan.toolRequirements {
            if requirement.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("tool_requirements contains an empty tool name")
            }
        }

        for step in package.spec.steps {
            switch step.type {
            case .extract:
                if step.extract == nil { errors.append("step \(step.id) type extract is missing payload") }
            case .format:
                if step.format == nil { errors.append("step \(step.id) type format is missing payload") }
            case .toolCall:
                guard let call = step.toolCall else {
                    errors.append("step \(step.id) type tool_call is missing payload")
                    continue
                }
                if !declaredTools.contains(call.name) {
                    errors.append("tool_call '\(call.name)' is not declared in tool_requirements")
                }
                if !availableToolNames.contains(call.name) {
                    errors.append("tool_call '\(call.name)' is not available in runtime registry")
                }
            case .llmCall:
                guard let call = step.llmCall else {
                    errors.append("step \(step.id) type llm_call is missing payload")
                    continue
                }
                if call.temperature != 0 {
                    errors.append("llm_call '\(step.id)' must use deterministic temperature 0")
                }
                if call.maxOutputTokens <= 0 {
                    errors.append("llm_call '\(step.id)' must set max_output_tokens > 0")
                }
                if !call.jsonOnly {
                    errors.append("llm_call '\(step.id)' must enforce json_only=true")
                }
            case .branch:
                if step.branch == nil { errors.append("step \(step.id) type branch is missing payload") }
            case .return:
                if step.returnStep == nil { errors.append("step \(step.id) type return is missing payload") }
            }
        }

        let promptText = package.spec.prompts.values.joined(separator: "\n").lowercased()
        let disallowedPromptFragments = [
            "reveal secrets",
            "ignore safety",
            "bypass constraints",
            "leak api key",
            "ignore previous instructions"
        ]
        for fragment in disallowedPromptFragments where promptText.contains(fragment) {
            errors.append("prompt policy violation: contains '\(fragment)'")
        }

        if package.signoff?.approved == true {
            warnings.append("package already includes signoff; forge loop should normally sign after approval")
        }

        return SkillValidationResult(errors: errors, warnings: warnings)
    }
}

struct SandboxSkillToolRuntime: SkillPackageToolRuntime {
    let declaredTools: Set<String>

    func callTool(name: String, args: [String: String]) -> SkillToolCallResult {
        guard declaredTools.contains(name) else {
            return SkillToolCallResult(success: false, output: [:], error: "MissingTool(\(name))")
        }
        let mappedArgs = args.mapValues { SkillJSONValue.string($0) }
        return SkillToolCallResult(
            success: true,
            output: [
                "tool": .string(name),
                "args": .object(mappedArgs),
                "ok": .bool(true)
            ],
            error: nil
        )
    }
}

struct ToolRegistrySkillRuntime: SkillPackageToolRuntime {
    func callTool(name: String, args: [String: String]) -> SkillToolCallResult {
        guard let canonical = ToolRegistry.shared.normalizeToolName(name),
              let tool = ToolRegistry.shared.get(canonical) else {
            return SkillToolCallResult(success: false, output: [:], error: "MissingTool(\(name))")
        }
        let item = tool.execute(args: args)
        let payload = item.payload
        if let data = payload.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return SkillToolCallResult(success: true, output: object.mapValues(SkillJSONValue.fromAny), error: nil)
        }
        return SkillToolCallResult(success: true, output: ["text": .string(payload)], error: nil)
    }
}

struct DeterministicSkillLLMRuntime: SkillPackageLLMRuntime {
    func run(prompt: String,
             temperature: Double,
             maxOutputTokens: Int,
             jsonOnly: Bool) async throws -> String {
        if jsonOnly {
            let body: [String: Any] = [
                "summary": "Deterministic summary generated in sandbox mode.",
                "actions": [],
                "prompt_preview": String(prompt.prefix(120))
            ]
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        return String(prompt.prefix(max(10, min(maxOutputTokens, 200))))
    }
}

final class SkillPackageRuntime {
    private let validator = SkillPackageValidator()

    func execute(package: SkillPackage,
                 inputText: String,
                 providedInputs: [String: SkillJSONValue] = [:],
                 toolRuntime: SkillPackageToolRuntime,
                 llmRuntime: SkillPackageLLMRuntime,
                 maxStepsOverride: Int? = nil) async -> SkillExecutionResult {
        let availability = Set(ToolRegistry.shared.canonicalToolNames)
        let validation = validator.validate(package: package, availableToolNames: availability)
        if !validation.isValid {
            return SkillExecutionResult(
                success: false,
                output: [:],
                error: "ValidationFailed: \(validation.errors.joined(separator: "; "))",
                toolCalls: [],
                stepsExecuted: 0,
                trace: []
            )
        }

        var inputPayload = providedInputs
        inputPayload["text"] = .string(inputText)
        let inputErrors = SkillSchemaValidator.validate(
            value: .object(inputPayload),
            schema: package.plan.inputsSchema,
            path: "input"
        )
        if !inputErrors.isEmpty {
            return SkillExecutionResult(
                success: false,
                output: [:],
                error: "InputValidationFailed: \(inputErrors.joined(separator: "; "))",
                toolCalls: [],
                stepsExecuted: 0,
                trace: []
            )
        }

        var vars: [String: SkillJSONValue] = ["input.text": .string(inputText)]
        for (key, value) in inputPayload {
            vars["input.\(key)"] = value
            vars[key] = value
        }

        var pc = 0
        var stepsExecuted = 0
        var trace: [String] = []
        var toolCalls: [String] = []
        let stepLimit = max(1, min(maxStepsOverride ?? 64, 512))

        func fail(_ message: String) -> SkillExecutionResult {
            SkillExecutionResult(
                success: false,
                output: [:],
                error: message,
                toolCalls: toolCalls,
                stepsExecuted: stepsExecuted,
                trace: trace
            )
        }

        while pc >= 0 && pc < package.spec.steps.count {
            if stepsExecuted >= stepLimit {
                return fail("MaxStepsExceeded(\(stepLimit))")
            }
            let step = package.spec.steps[pc]
            stepsExecuted += 1
            trace.append("step=\(step.id) type=\(step.type.rawValue)")

            switch step.type {
            case .extract:
                guard let payload = step.extract else {
                    return fail("StepPayloadMissing(\(step.id))")
                }
                let source = valueForVariable(payload.source, vars: vars).stringValue
                let extracted = extractFirstCapture(pattern: payload.pattern, source: source)
                vars[payload.outputVar] = .string(extracted ?? "")
                pc += 1

            case .format:
                guard let payload = step.format else {
                    return fail("StepPayloadMissing(\(step.id))")
                }
                let mode = payload.mode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let outputValue: SkillJSONValue
                if mode == "bullets" {
                    let sourceValue = valueForVariable(payload.inputVar ?? "input.text", vars: vars).stringValue
                    let bullets = bulletize(sourceValue)
                    outputValue = .string(bullets)
                } else if mode == "news_bullets" {
                    let sourceValue = valueForVariable(payload.inputVar ?? "input.text", vars: vars)
                    outputValue = .string(newsBulletize(sourceValue))
                } else if let template = payload.template {
                    outputValue = resolveTemplateValue(template, vars: vars)
                } else {
                    outputValue = valueForVariable(payload.inputVar ?? "input.text", vars: vars)
                }
                vars[payload.outputVar] = outputValue
                pc += 1

            case .toolCall:
                guard let payload = step.toolCall else {
                    return fail("StepPayloadMissing(\(step.id))")
                }
                let resolved = payload.args.mapValues { interpolateText($0, vars: vars) }
                let result = toolRuntime.callTool(name: payload.name, args: resolved)
                toolCalls.append(payload.name)
                if !result.success {
                    return fail(result.error ?? "ToolCallFailed(\(payload.name))")
                }
                if let outputVar = payload.outputVar {
                    vars[outputVar] = .object(result.output)
                }
                pc += 1

            case .llmCall:
                guard let payload = step.llmCall else {
                    return fail("StepPayloadMissing(\(step.id))")
                }
                let prompt = interpolateText(payload.promptTemplate, vars: vars)
                let response: String
                do {
                    response = try await llmRuntime.run(
                        prompt: prompt,
                        temperature: payload.temperature,
                        maxOutputTokens: payload.maxOutputTokens,
                        jsonOnly: payload.jsonOnly
                    )
                } catch {
                    return fail("LLMCallFailed(\(error.localizedDescription))")
                }
                if payload.jsonOnly {
                    guard let data = response.data(using: .utf8),
                          let parsed = try? JSONSerialization.jsonObject(with: data) else {
                        return fail("LLMCallInvalidJSON(\(step.id))")
                    }
                    vars["\(payload.responseVar)_json"] = SkillJSONValue.fromAny(parsed)
                }
                vars[payload.responseVar] = .string(response)
                pc += 1

            case .branch:
                guard let payload = step.branch else {
                    return fail("StepPayloadMissing(\(step.id))")
                }
                let current = vars[payload.variable]
                let condition: Bool
                if let exists = payload.exists {
                    let hasValue: Bool
                    if let current {
                        let text = current.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        hasValue = !text.isEmpty
                    } else {
                        hasValue = false
                    }
                    condition = exists ? hasValue : !hasValue
                } else if let equals = payload.equals {
                    condition = current?.stringValue == equals
                } else {
                    condition = current != nil
                }
                if condition {
                    pc = payload.thenIndex
                } else if let elseIndex = payload.elseIndex {
                    pc = elseIndex
                } else {
                    pc += 1
                }

            case .return:
                guard let payload = step.returnStep else {
                    return fail("StepPayloadMissing(\(step.id))")
                }
                var output: [String: SkillJSONValue] = [:]
                for (key, template) in payload.output {
                    output[key] = resolveTemplateValue(template, vars: vars)
                }
                let outputErrors = SkillSchemaValidator.validate(
                    value: .object(output),
                    schema: package.plan.outputsSchema,
                    path: "output"
                )
                if !outputErrors.isEmpty {
                    return fail("OutputValidationFailed: \(outputErrors.joined(separator: "; "))")
                }
                if let data = try? JSONEncoder().encode(output),
                   data.count > package.spec.limits.maxOutputChars {
                    return fail("OutputTooLarge(\(data.count) > \(package.spec.limits.maxOutputChars))")
                }
                return SkillExecutionResult(
                    success: true,
                    output: output,
                    error: nil,
                    toolCalls: toolCalls,
                    stepsExecuted: stepsExecuted,
                    trace: trace
                )
            }
        }

        return fail("NoReturnStepReached")
    }

    private func extractFirstCapture(pattern: String, source: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, options: [], range: range) else {
            return nil
        }
        if match.numberOfRanges > 1,
           let captureRange = Range(match.range(at: 1), in: source) {
            return String(source[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let fullRange = Range(match.range(at: 0), in: source) {
            return String(source[fullRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func bulletize(_ text: String) -> String {
        let parts = text
            .components(separatedBy: CharacterSet(charactersIn: "\n.;,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parts.isEmpty {
            return "- \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return parts.map { "- \($0)" }.joined(separator: "\n")
    }

    private func newsBulletize(_ value: SkillJSONValue) -> String {
        let itemsValue: [SkillJSONValue]
        switch value {
        case .object(let dict):
            if case .array(let items)? = dict["items"] {
                itemsValue = items
            } else {
                itemsValue = []
            }
        case .array(let items):
            itemsValue = items
        default:
            itemsValue = []
        }
        guard !itemsValue.isEmpty else {
            return "- No recent items found."
        }

        struct RuntimeNewsItem {
            let title: String
            let source: String
            let publishedAt: Date?
            let publishedRaw: String?
        }

        let parsed: [RuntimeNewsItem] = itemsValue.compactMap { item in
            guard case .object(let obj) = item else { return nil }
            let title = obj["title"]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            let source = obj["source"]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
            let publishedRaw = obj["published_at"]?.stringValue
            let publishedAt = NewsDateParser.parse(publishedRaw)
            return RuntimeNewsItem(
                title: title,
                source: source.isEmpty ? "Unknown" : source,
                publishedAt: publishedAt,
                publishedRaw: publishedRaw
            )
        }

        let cutoff = Date().addingTimeInterval(-72 * 3600)
        var filtered = parsed.filter { item in
            guard let publishedAt = item.publishedAt else { return true }
            return publishedAt >= cutoff
        }

        var deduped: [RuntimeNewsItem] = []
        for item in filtered {
            if let idx = deduped.firstIndex(where: { newsTitleSimilarity($0.title, item.title) >= 0.90 }) {
                let existing = deduped[idx]
                switch (item.publishedAt, existing.publishedAt) {
                case let (lhs?, rhs?) where lhs > rhs:
                    deduped[idx] = item
                case (.some, .none):
                    deduped[idx] = item
                default:
                    break
                }
            } else {
                deduped.append(item)
            }
        }
        filtered = deduped.sorted { lhs, rhs in
            switch (lhs.publishedAt, rhs.publishedAt) {
            case let (l?, r?):
                return l > r
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.title < rhs.title
            }
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        return filtered.prefix(10).map { item in
            let dateText: String
            if let publishedAt = item.publishedAt {
                dateText = dateFormatter.string(from: publishedAt)
            } else if let raw = item.publishedRaw, !raw.isEmpty {
                dateText = raw
            } else {
                dateText = "date unknown"
            }
            return "- [\(dateText)] \(item.title) — \(item.source)"
        }.joined(separator: "\n")
    }

    private func newsTitleSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(lhs.lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init))
        let right = Set(rhs.lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        let union = left.union(right).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    private func valueForVariable(_ variable: String, vars: [String: SkillJSONValue]) -> SkillJSONValue {
        if let value = vars[variable] {
            return value
        }
        if let value = vars["input.\(variable)"] {
            return value
        }
        return .null
    }

    private func interpolateText(_ template: String, vars: [String: SkillJSONValue]) -> String {
        var result = template
        let pattern = #"\{\{\s*([^}\s]+)\s*\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return result
        }
        let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
        let matches = regex.matches(in: result, options: [], range: nsRange).reversed()
        for match in matches {
            guard match.numberOfRanges > 1,
                  let nameRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range(at: 0), in: result) else {
                continue
            }
            let name = String(result[nameRange])
            let replacement = valueForVariable(name, vars: vars).stringValue
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }

    private func resolveTemplateValue(_ template: String, vars: [String: SkillJSONValue]) -> SkillJSONValue {
        let exactPattern = #"^\{\{\s*([^}\s]+)\s*\}\}$"#
        if let regex = try? NSRegularExpression(pattern: exactPattern),
           let match = regex.firstMatch(in: template, range: NSRange(template.startIndex..<template.endIndex, in: template)),
           match.numberOfRanges > 1,
           let nameRange = Range(match.range(at: 1), in: template) {
            let variable = String(template[nameRange])
            return valueForVariable(variable, vars: vars)
        }
        return .string(interpolateText(template, vars: vars))
    }
}

final class SkillSimHarness {
    private let runtime: SkillPackageRuntime

    init(runtime: SkillPackageRuntime = SkillPackageRuntime()) {
        self.runtime = runtime
    }

    func run(package: SkillPackage,
             toolRuntime: SkillPackageToolRuntime,
             llmRuntime: SkillPackageLLMRuntime) async -> SkillSimulationReport {
        var results: [SkillSimulationCaseResult] = []
        for testCase in package.tests {
            let execution = await runtime.execute(
                package: package,
                inputText: testCase.inputText,
                toolRuntime: toolRuntime,
                llmRuntime: llmRuntime,
                maxStepsOverride: testCase.maxSteps
            )

            var failures: [String] = []
            if testCase.shouldFail {
                if execution.success {
                    failures.append("expected failure but execution succeeded")
                }
            } else if !execution.success {
                failures.append("execution failed: \(execution.error ?? "unknown")")
            }

            if !testCase.expected.isEmpty {
                for (key, expected) in testCase.expected {
                    guard let actual = execution.output[key] else {
                        failures.append("missing expected output key '\(key)'")
                        continue
                    }
                    if !actual.matchesExpectedSubset(expected) {
                        failures.append("output mismatch for key '\(key)'")
                    }
                }
            }

            for requiredTool in testCase.mustCallTools where !execution.toolCalls.contains(requiredTool) {
                failures.append("expected tool '\(requiredTool)' was not called")
            }
            for forbiddenTool in testCase.mustNotCallTools where execution.toolCalls.contains(forbiddenTool) {
                failures.append("forbidden tool '\(forbiddenTool)' was called")
            }

            let passed = failures.isEmpty
            results.append(
                SkillSimulationCaseResult(
                    name: testCase.name,
                    passed: passed,
                    failureReason: passed ? nil : failures.joined(separator: "; "),
                    execution: execution
                )
            )
        }
        let allPassed = results.allSatisfy(\.passed)
        return SkillSimulationReport(skillID: package.manifest.skillID, passed: allPassed, cases: results)
    }
}

extension SkillJSONValue {
    fileprivate func matchesExpectedSubset(_ expected: SkillJSONValue) -> Bool {
        switch (self, expected) {
        case (.string(let actual), .string(let expectedText)):
            return actual.localizedCaseInsensitiveContains(expectedText)
        case (.number(let actual), .number(let expectedNumber)):
            return abs(actual - expectedNumber) < 0.000_1
        case (.bool(let actual), .bool(let expectedBool)):
            return actual == expectedBool
        case (.null, .null):
            return true
        case (.object(let actualObject), .object(let expectedObject)):
            for (key, expectedValue) in expectedObject {
                guard let actualValue = actualObject[key], actualValue.matchesExpectedSubset(expectedValue) else {
                    return false
                }
            }
            return true
        case (.array(let actualArray), .array(let expectedArray)):
            guard expectedArray.count <= actualArray.count else { return false }
            for index in expectedArray.indices {
                if !actualArray[index].matchesExpectedSubset(expectedArray[index]) {
                    return false
                }
            }
            return true
        default:
            return false
        }
    }
}

final class SkillForgePipelineV2 {
    private let gptClient: SkillForgeGPTClient
    private let validator: SkillPackageValidator
    private let simHarness: SkillSimHarness
    private let store: SkillStore
    private let logger: AppLogger
    private let llmRuntime: SkillPackageLLMRuntime
    private let maxIterations: Int
    private let iterationDelayMs: Int

    init(gptClient: SkillForgeGPTClient,
         validator: SkillPackageValidator = SkillPackageValidator(),
         simHarness: SkillSimHarness = SkillSimHarness(),
         store: SkillStore = .shared,
         logger: AppLogger = JSONLineLogger(),
         llmRuntime: SkillPackageLLMRuntime = DeterministicSkillLLMRuntime(),
         maxIterations: Int = 100,
         iterationDelayMs: Int = 0) {
        self.gptClient = gptClient
        self.validator = validator
        self.simHarness = simHarness
        self.store = store
        self.logger = logger
        self.llmRuntime = llmRuntime
        self.maxIterations = max(1, maxIterations)
        self.iterationDelayMs = max(0, iterationDelayMs)
    }

    func run(requirements: SkillForgeRequirements,
             onLog: @escaping (String) -> Void,
             installOnApproval: Bool = true) async -> SkillForgePipelineOutcome {
        logger.info("skill_forge_started", metadata: [
            "skill_id": normalizeSkillID(from: requirements.goal),
            "iteration": "0",
            "stage": SkillForgePipelineStage.draftPlan.rawValue,
            "gpt_model": gptClient.modelName
        ])

        let availableTools = ToolRegistry.shared.allTools
            .map { tool in
                let permissions = (tool as? PermissionScopedTool)?.requiredPermissions ?? []
                return SkillToolDescriptor(name: tool.name, description: tool.description, permissions: permissions)
            }
            .sorted { $0.name < $1.name }
        let availableToolNames = Set(availableTools.map(\.name))

        var feedback = SkillForgeFeedback.empty
        var lastCritique: String?
        var lastRequiredChanges: [String] = []

        for iteration in 1...maxIterations {
            if iterationDelayMs > 0 {
                let nanos = UInt64(iterationDelayMs) * 1_000_000
                try? await Task.sleep(nanoseconds: nanos)
            }

            func emit(_ stage: SkillForgePipelineStage, _ message: String, latencyMs: Int? = nil) {
                let latencyValue = latencyMs.map(String.init) ?? "0"
                logger.info("learn_skill_iteration", metadata: [
                    "skill_id": normalizeSkillID(from: requirements.goal),
                    "iteration": String(iteration),
                    "stage": stage.rawValue,
                    "gpt_model": gptClient.modelName,
                    "latency_ms": latencyValue
                ])
                onLog("[\(stage.rawValue)] \(message)")
            }

            do {
                let planStart = Date()
                let plan = try await gptClient.makePlan(
                    requirements: requirements,
                    availableTools: availableTools,
                    feedback: feedback
                )
                emit(.draftPlan, "Plan generated for \(plan.skillID)", latencyMs: ms(since: planStart))
                logger.info("skill_plan_created", metadata: [
                    "skill_id": plan.skillID,
                    "iteration": String(iteration),
                    "gpt_model": gptClient.modelName,
                    "latency_ms": String(ms(since: planStart))
                ])

                let specStart = Date()
                let spec = try await gptClient.makeSpec(
                    plan: plan,
                    requirements: requirements,
                    feedback: feedback
                )
                emit(.draftSpec, "Spec generated with \(spec.steps.count) steps", latencyMs: ms(since: specStart))
                logger.info("skill_spec_created", metadata: [
                    "skill_id": plan.skillID,
                    "iteration": String(iteration),
                    "gpt_model": gptClient.modelName,
                    "latency_ms": String(ms(since: specStart))
                ])

                let packageStart = Date()
                var package = try await gptClient.buildPackage(
                    plan: plan,
                    spec: spec,
                    requirements: requirements,
                    feedback: feedback
                )
                package.manifest.skillID = plan.skillID
                package.manifest.name = plan.name
                package.manifest.version = plan.version
                package.manifest.origin = .forged
                package.manifest.createdAtISO8601 = ISO8601DateFormatter().string(from: Date())
                package.plan = plan
                package.spec = spec
                if package.tests.isEmpty {
                    package.tests = plan.testCases
                }
                emit(.draftPackage, "Package assembled", latencyMs: ms(since: packageStart))
                logger.info("skill_package_built", metadata: [
                    "skill_id": plan.skillID,
                    "iteration": String(iteration),
                    "gpt_model": gptClient.modelName,
                    "latency_ms": String(ms(since: packageStart))
                ])

                let validation = validator.validate(package: package, availableToolNames: availableToolNames)
                if !validation.isValid {
                    feedback.localValidationErrors = validation.errors
                    feedback.simulationFailures = []
                    feedback.critique = "Local validation failed"
                    emit(.validateLocal, "Validation failed: \(validation.errors.joined(separator: " | "))")
                    logger.error("skill_validate_failed", metadata: [
                        "skill_id": plan.skillID,
                        "iteration": String(iteration),
                        "error_count": String(validation.errors.count)
                    ])
                    continue
                }
                emit(.validateLocal, "Validation passed")

                let simStart = Date()
                let simReport = await simHarness.run(
                    package: package,
                    toolRuntime: SandboxSkillToolRuntime(declaredTools: Set(plan.toolRequirements.map(\.name))),
                    llmRuntime: llmRuntime
                )
                if !simReport.passed {
                    let failed = simReport.cases.filter { !$0.passed }.map { $0.failureReason ?? $0.name }
                    feedback.localValidationErrors = []
                    feedback.simulationFailures = failed
                    feedback.critique = "Simulation failed"
                    emit(.simulate, "Simulation failed: \(failed.joined(separator: " | "))", latencyMs: ms(since: simStart))
                    logger.error("skill_sim_failed", metadata: [
                        "skill_id": plan.skillID,
                        "iteration": String(iteration),
                        "failed_cases": String(simReport.cases.filter { !$0.passed }.count)
                    ])
                    continue
                }
                emit(.simulate, "Simulation passed (\(simReport.passedCount)/\(simReport.cases.count))", latencyMs: ms(since: simStart))

                let approvalStart = Date()
                let approval = try await gptClient.approve(
                    package: package,
                    validation: validation,
                    simulation: simReport
                )
                if !approval.approved {
                    feedback.localValidationErrors = []
                    feedback.simulationFailures = []
                    feedback.gptRequiredChanges = approval.requiredChanges
                    feedback.critique = approval.reason
                    lastCritique = approval.reason
                    lastRequiredChanges = approval.requiredChanges
                    emit(.submitForApproval, "GPT rejected package: \(approval.reason)", latencyMs: ms(since: approvalStart))
                    logger.info("skill_gpt_rejected", metadata: [
                        "skill_id": plan.skillID,
                        "iteration": String(iteration),
                        "gpt_model": gptClient.modelName,
                        "latency_ms": String(ms(since: approvalStart))
                    ])
                    continue
                }

                let hash = Self.packageHash(package)
                if let requestedHash = approval.packageHash, !requestedHash.isEmpty, requestedHash != hash {
                    feedback.gptRequiredChanges = ["approver package_hash mismatch: expected \(requestedHash), computed \(hash)"]
                    feedback.critique = "Approver hash mismatch"
                    lastCritique = feedback.critique
                    lastRequiredChanges = feedback.gptRequiredChanges
                    emit(.revise, "Approver hash mismatch. Sending package back for revision.")
                    continue
                }

                package.signoff = SkillSignoff(
                    approved: true,
                    reason: approval.reason,
                    requiredChanges: approval.requiredChanges,
                    riskNotes: approval.riskNotes,
                    packageHash: hash,
                    model: gptClient.modelName,
                    approvedAtISO8601: ISO8601DateFormatter().string(from: Date())
                )

                emit(.approved, "GPT approved package", latencyMs: ms(since: approvalStart))
                logger.info("skill_gpt_approved", metadata: [
                    "skill_id": plan.skillID,
                    "iteration": String(iteration),
                    "hash": hash,
                    "gpt_model": gptClient.modelName,
                    "latency_ms": String(ms(since: approvalStart))
                ])

                if installOnApproval {
                    let installStart = Date()
                    guard store.installPackage(package) else {
                        let reason = "Failed to install skill package on disk"
                        emit(.blocked, reason, latencyMs: ms(since: installStart))
                        return SkillForgePipelineOutcome(
                            approved: false,
                            installedPackage: nil,
                            iterations: iteration,
                            blockedReason: reason,
                            lastCritique: approval.reason,
                            requiredChanges: approval.requiredChanges
                        )
                    }

                    emit(.install, "Installed \(package.manifest.skillID)", latencyMs: ms(since: installStart))
                    logger.info("skill_installed", metadata: [
                        "skill_id": package.manifest.skillID,
                        "iteration": String(iteration),
                        "hash": hash,
                        "latency_ms": String(ms(since: installStart))
                    ])
                }

                return SkillForgePipelineOutcome(
                    approved: true,
                    installedPackage: package,
                    iterations: iteration,
                    blockedReason: nil,
                    lastCritique: nil,
                    requiredChanges: []
                )
            } catch {
                lastCritique = error.localizedDescription
                feedback.critique = error.localizedDescription
                emit(.revise, "Loop error: \(error.localizedDescription)")
            }
        }

        logger.error("learn_skill_blocked", metadata: [
            "skill_id": normalizeSkillID(from: requirements.goal),
            "iteration": String(maxIterations),
            "stage": SkillForgePipelineStage.blocked.rawValue,
            "gpt_model": gptClient.modelName
        ])
        return SkillForgePipelineOutcome(
            approved: false,
            installedPackage: nil,
            iterations: maxIterations,
            blockedReason: "Reached max iterations (\(maxIterations))",
            lastCritique: lastCritique,
            requiredChanges: lastRequiredChanges
        )
    }

    static func packageHash(_ package: SkillPackage) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(package)) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private func normalizeSkillID(from text: String) -> String {
        let lowered = text.lowercased()
        let pieces = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let joined = pieces.filter { !$0.isEmpty }.joined(separator: "_")
        return joined.isEmpty ? "skill" : joined
    }
}

final class OpenAISkillArchitectClient: SkillForgeGPTClient {
    var modelName: String {
        let configured = OpenAISettings.generalModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? OpenAISettings.defaultPreferredModel : configured
    }

    func makePlan(requirements: SkillForgeRequirements,
                  availableTools: [SkillToolDescriptor],
                  feedback: SkillForgeFeedback) async throws -> SkillPlan {
        let system = """
        You are PlannerGPT for SamOS SkillForge.
        Return ONLY valid JSON matching SkillPlan.
        """
        let user = """
        Build a SkillPlan JSON for:
        goal: \(requirements.goal)
        missing: \(requirements.missing)
        constraints: \(requirements.constraints.joined(separator: ", "))
        available_tools: \(toolCatalog(availableTools))
        feedback: \(feedbackJSON(feedback))
        """
        return try await requestJSON(systemPrompt: system, userPrompt: user, type: SkillPlan.self)
    }

    func makeSpec(plan: SkillPlan,
                  requirements: SkillForgeRequirements,
                  feedback: SkillForgeFeedback) async throws -> SkillSpecV2 {
        let system = """
        You are SpecGPT for SamOS SkillForge.
        Return ONLY valid JSON matching SkillSpecV2.
        """
        let user = """
        Build SkillSpec JSON for plan:
        \(jsonString(plan))
        requirements: goal=\(requirements.goal), missing=\(requirements.missing)
        feedback: \(feedbackJSON(feedback))
        """
        return try await requestJSON(systemPrompt: system, userPrompt: user, type: SkillSpecV2.self)
    }

    func buildPackage(plan: SkillPlan,
                      spec: SkillSpecV2,
                      requirements: SkillForgeRequirements,
                      feedback: SkillForgeFeedback) async throws -> SkillPackage {
        let system = """
        You are BuilderGPT for SamOS SkillForge.
        Return ONLY valid JSON matching SkillPackage.
        """
        let user = """
        Assemble a SkillPackage using this plan and spec.
        plan: \(jsonString(plan))
        spec: \(jsonString(spec))
        requirements: goal=\(requirements.goal), missing=\(requirements.missing)
        feedback: \(feedbackJSON(feedback))
        """
        return try await requestJSON(systemPrompt: system, userPrompt: user, type: SkillPackage.self)
    }

    func approve(package: SkillPackage,
                 validation: SkillValidationResult,
                 simulation: SkillSimulationReport) async throws -> SkillApproverResponse {
        let system = """
        You are ApproverGPT for SamOS SkillForge.
        Return ONLY JSON:
        {
          "approved": true|false,
          "reason": "string",
          "required_changes": ["string"],
          "risk_notes": ["string"],
          "package_hash": "sha256..."
        }
        """
        let hash = SkillForgePipelineV2.packageHash(package)
        let user = """
        Evaluate this package for safety and correctness.
        package_hash: \(hash)
        package: \(jsonString(package))
        validation: \(jsonObjectString([
            "errors": validation.errors,
            "warnings": validation.warnings
        ]))
        simulation: \(jsonObjectString([
            "passed": simulation.passed,
            "passed_count": simulation.passedCount,
            "total": simulation.cases.count,
            "failed": simulation.cases.filter { !$0.passed }.map { $0.failureReason ?? $0.name }
        ]))
        """
        return try await requestJSON(systemPrompt: system, userPrompt: user, type: SkillApproverResponse.self)
    }

    private func requestJSON<T: Decodable>(systemPrompt: String,
                                           userPrompt: String,
                                           type: T.Type) async throws -> T {
        let raw = try await callOpenAI(systemPrompt: systemPrompt, userPrompt: userPrompt)
        if let parsed: T = decodeJSON(raw, as: T.self) {
            return parsed
        }
        let fixed = try await callOpenAI(
            systemPrompt: "FIX JSON ONLY. Return valid JSON. No commentary.",
            userPrompt: raw
        )
        if let parsed: T = decodeJSON(fixed, as: T.self) {
            return parsed
        }
        throw SkillForge.ForgeError.refinementFailed("Failed to decode structured JSON from OpenAI response")
    }

    private func decodeJSON<T: Decodable>(_ raw: String, as type: T.Type) -> T? {
        if let data = raw.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(T.self, from: data) {
            return parsed
        }
        if let start = raw.firstIndex(of: "{"),
           let end = raw.lastIndex(of: "}") {
            let object = String(raw[start...end])
            if let data = object.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(T.self, from: data) {
                return parsed
            }
        }
        if let start = raw.firstIndex(of: "["),
           let end = raw.lastIndex(of: "]") {
            let array = String(raw[start...end])
            if let data = array.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(T.self, from: data) {
                return parsed
            }
        }
        return nil
    }

    private func callOpenAI(systemPrompt: String, userPrompt: String) async throws -> String {
        guard OpenAISettings.isConfigured else {
            throw SkillForge.ForgeError.requirementsFailed("OpenAI API key not configured")
        }
        let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
        let payload: [String: Any] = [
            "model": modelName,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.0,
            "max_tokens": 1_800
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(OpenAISettings.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SkillForge.ForgeError.reviewFailed("OpenAI request failed for skill architecture")
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw SkillForge.ForgeError.reviewFailed("OpenAI returned an invalid completion envelope")
        }
        return content
    }

    private func jsonString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func toolCatalog(_ tools: [SkillToolDescriptor]) -> String {
        let lines = tools.map { tool in
            let permissions = tool.permissions.isEmpty ? "none" : tool.permissions.joined(separator: ",")
            return "\(tool.name): \(tool.description) | permissions=\(permissions)"
        }
        return lines.joined(separator: "\n")
    }

    private func feedbackJSON(_ feedback: SkillForgeFeedback) -> String {
        jsonObjectString([
            "local_validation_errors": feedback.localValidationErrors,
            "simulation_failures": feedback.simulationFailures,
            "gpt_required_changes": feedback.gptRequiredChanges,
            "critique": feedback.critique ?? ""
        ])
    }

    private func jsonObjectString(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

extension SkillForge {
    private func forgeViaPackagePipeline(goal: String,
                                         missing: String,
                                         onProgress: @escaping (SkillForgeJob) -> Void) async throws -> SkillSpec {
        var job = SkillForgeJob(goal: goal)
        currentJob = job
        onProgress(job)

        guard OpenAISettings.isConfigured else {
            let reason = "OpenAI API key not configured"
            job.fail(reason)
            currentJob = job
            onProgress(job)
            throw ForgeError.requirementsFailed(reason)
        }

        let requirements = SkillForgeRequirements(
            goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
            missing: missing.trimmingCharacters(in: .whitespacesAndNewlines),
            constraints: []
        )

        let pipeline = SkillForgePipelineV2(gptClient: OpenAISkillArchitectClient())
        let outcome = await pipeline.run(requirements: requirements) { line in
            job.log(line)
            onProgress(job)
        }

        guard outcome.approved, let installed = outcome.installedPackage else {
            let reason = outcome.blockedReason ?? outcome.lastCritique ?? "SkillForge blocked without approval"
            job.fail(reason)
            currentJob = job
            onProgress(job)
            throw ForgeError.implementationInsufficient(reason)
        }

        let shim = compatibilitySkill(from: installed)
        guard SkillStore.shared.install(shim) else {
            job.fail("Failed to install compatibility skill shim")
            currentJob = job
            onProgress(job)
            throw ForgeError.installFailed
        }

        job.complete()
        job.log("Skill package approved and installed after \(outcome.iterations) iterations")
        currentJob = job
        onProgress(job)
        return shim
    }

    private func compatibilitySkill(from package: SkillPackage) -> SkillSpec {
        var steps: [SkillSpec.StepDef] = []
        if let firstTool = package.plan.toolRequirements.first?.name {
            steps.append(SkillSpec.StepDef(action: firstTool, args: [:]))
        } else {
            let prompt = "Use skill package \(package.manifest.skillID)"
            steps.append(SkillSpec.StepDef(action: "talk", args: ["say": prompt]))
        }
        var skill = SkillSpec(
            id: package.manifest.skillID,
            name: package.manifest.name,
            version: package.manifest.version,
            triggerPhrases: package.plan.intentPatterns,
            slots: [
                SkillSpec.SlotDef(name: "text", type: .string, required: true, prompt: nil)
            ],
            steps: steps,
            onTrigger: nil
        )
        skill.status = "active"
        skill.approvedAt = Date()
        skill.disabledAt = nil
        return skill
    }
}
