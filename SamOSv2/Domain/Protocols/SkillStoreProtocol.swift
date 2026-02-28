import Foundation

/// Contract for skill persistence and retrieval.
protocol SkillStoreProtocol: Sendable {
    func loadInstalled() async -> [SkillSpec]
    func getSkill(id: String) async -> SkillSpec?
    func install(_ skill: SkillSpec) async throws
    func remove(id: String) async throws
    func match(input: String) async -> SkillSpec?
    func recordUsage(id: String) async
}

/// Contract for the SkillForge build pipeline.
protocol SkillForgePipelineProtocol: Sendable {
    func forge(goal: String) async throws -> SkillSpec
    func status(jobId: String) async -> SkillForgeJob?
    func cancel(jobId: String) async
}
