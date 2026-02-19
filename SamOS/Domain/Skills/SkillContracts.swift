import Foundation

protocol SkillStoreContract {
    func loadInstalled() -> [SkillSpec]
    @discardableResult
    func install(_ skill: SkillSpec) -> Bool
    @discardableResult
    func remove(id: String) -> Bool
}

protocol SkillRuntime {
    func execute(skill: SkillSpec, slots: [String: String]) -> [Action]
}

protocol SkillForgePipeline {
    @MainActor
    func forge(goal: String, missing: String, onProgress: @escaping (SkillForgeJob) -> Void) async throws -> SkillSpec
}

protocol SkillPackageStoreContract {
    func loadInstalledPackages() -> [SkillPackage]
    func getPackage(id: String) -> SkillPackage?
    @discardableResult
    func installPackage(_ package: SkillPackage) -> Bool
    @discardableResult
    func resetPackagesToBaseline() -> Int
}

protocol SkillPackageRuntimeContract {
    func execute(package: SkillPackage,
                 inputText: String,
                 providedInputs: [String: SkillJSONValue],
                 toolRuntime: SkillPackageToolRuntime,
                 llmRuntime: SkillPackageLLMRuntime,
                 maxStepsOverride: Int?) async -> SkillExecutionResult
}

extension SkillStore: SkillStoreContract {}
extension SkillEngine: SkillRuntime {}
extension SkillForge: SkillForgePipeline {}
extension SkillStore: SkillPackageStoreContract {}
extension SkillPackageRuntime: SkillPackageRuntimeContract {}
