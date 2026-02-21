import Foundation

struct CoreToolsRegistryContributor: ToolRegistryContributor {
    func register(into registry: ToolRegistry) {
        registry.register(ShowTextTool())
        registry.register(FindRecipeTool())
        registry.register(FindImageTool())
        registry.register(FindVideoTool())
        registry.register(FindFilesTool())
        registry.register(ShowImageTool())
    }
}

struct CameraToolsRegistryContributor: ToolRegistryContributor {
    func register(into registry: ToolRegistry) {
        registry.register(DescribeCameraViewTool())
        registry.register(CameraObjectFinderTool())
        registry.register(CameraFacePresenceTool())
        registry.register(EnrollCameraFaceTool())
        registry.register(RecognizeCameraFacesTool())
        registry.register(CameraVisualQATool())
        registry.register(CameraInventorySnapshotTool())
        registry.register(SaveCameraMemoryNoteTool())
        registry.register(DetectEmotionsTool())
        registry.register(GPTVisionAnalysisTool())
    }
}

struct MemoryToolsRegistryContributor: ToolRegistryContributor {
    func register(into registry: ToolRegistry) {
        registry.register(SaveMemoryTool())
        registry.register(ListMemoriesTool())
        registry.register(DeleteMemoryTool())
        registry.register(ClearMemoriesTool())
        registry.register(RecallAmbientTool())
    }
}

struct SchedulingToolsRegistryContributor: ToolRegistryContributor {
    func register(into registry: ToolRegistry) {
        registry.register(ScheduleTaskTool())
        registry.register(CancelTaskTool())
        registry.register(ListTasksTool())
        registry.register(TimerManageTool())
        registry.register(GetWeatherTool())
        registry.register(GetTimeTool())
    }
}

struct LearningToolsRegistryContributor: ToolRegistryContributor {
    func register(into registry: ToolRegistry) {
        registry.register(LearnWebsiteTool())
        registry.register(AutonomousLearnTool())
        registry.register(StopAutonomousLearnTool())
    }
}

struct WebToolsRegistryContributor: ToolRegistryContributor {
    func register(into registry: ToolRegistry) {
        registry.register(MovieShowtimesTool())
        registry.register(FishingReportTool())
        registry.register(PriceLookupTool())
        registry.register(NewsFetchTool())
    }
}

struct SkillsToolsRegistryContributor: ToolRegistryContributor {
    func register(into registry: ToolRegistry) {
        registry.register(StartSkillForgeTool())
        registry.register(ForgeQueueStatusTool())
        registry.register(ForgeQueueClearTool())
        registry.register(SkillsLearnStartTool())
        registry.register(SkillsLearnStatusTool())
        registry.register(SkillsLearnCancelTool())
        registry.register(SkillsLearnApprovePermissionsTool())
        registry.register(SkillsLearnRequestChangesTool())
        registry.register(SkillsLearnInstallTool())
        registry.register(SkillsListTool())
        registry.register(SkillsRunSimTool())
        registry.register(SkillsResetBaselineTool())
    }
}

struct CapabilityToolsRegistryContributor: ToolRegistryContributor {
    func register(into registry: ToolRegistry) {
        registry.register(CapabilityGapToClaudePromptTool())
    }
}
