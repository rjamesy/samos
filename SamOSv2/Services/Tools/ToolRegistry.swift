import Foundation

/// Central registry of all available tools with alias normalization.
final class ToolRegistry: ToolRegistryProtocol, @unchecked Sendable {
    private var tools: [String: any Tool] = [:]
    private var aliases: [String: String] = [:]

    var allTools: [any Tool] {
        Array(tools.values)
    }

    func get(_ name: String) -> (any Tool)? {
        let normalized = normalizeToolName(name) ?? name
        return tools[normalized]
    }

    func register(_ tool: any Tool) {
        tools[tool.name] = tool
    }

    func normalizeToolName(_ raw: String) -> String? {
        let lower = raw.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")

        // Direct match
        if tools[lower] != nil { return lower }

        // Alias match
        if let canonical = aliases[lower] { return canonical }

        // CamelCase to snake_case
        let snake = camelToSnake(raw)
        if tools[snake] != nil { return snake }
        if let canonical = aliases[snake] { return canonical }

        return nil
    }

    /// Register a batch of tool name aliases.
    func registerAliases(_ mapping: [String: String]) {
        for (alias, canonical) in mapping {
            aliases[alias.lowercased()] = canonical
        }
    }

    /// Build the tool manifest string for the system prompt.
    /// When native function calling is active, only includes tools WITHOUT schemas.
    func buildToolManifest() -> String {
        let textOnlyTools = allTools.filter { $0.schema == nil }
        if textOnlyTools.isEmpty { return "" }
        let toolDescriptions = textOnlyTools.map { tool in
            "- \(tool.name): \(tool.description) \(tool.parameterDescription)"
        }
        return "[AVAILABLE TOOLS]\n" + toolDescriptions.joined(separator: "\n")
    }

    /// Build native OpenAI tool definitions from tools that have schemas.
    func buildToolDefinitions() -> [ToolDefinition] {
        allTools.compactMap { tool -> ToolDefinition? in
            guard let schema = tool.schema else { return nil }
            return ToolDefinition(
                name: tool.name,
                description: tool.description,
                parameters: schema.toJSON()
            )
        }
    }

    /// Compact identifier (remove underscores): "get_time" -> "gettime"
    private func compact(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "_", with: "")
    }

    private func camelToSnake(_ text: String) -> String {
        var result = ""
        for (i, char) in text.enumerated() {
            if char.isUppercase && i > 0 {
                result += "_"
            }
            result += String(char).lowercased()
        }
        return result
    }

    // MARK: - Default Registration

    /// Register all built-in tools and aliases.
    func registerDefaults(
        memoryStore: any MemoryStoreProtocol,
        taskScheduler: TaskScheduler? = nil,
        skillForge: (any SkillForgePipelineProtocol)? = nil,
        skillStore: (any SkillStoreProtocol)? = nil,
        webLearner: WebLearningService? = nil,
        autonomousResearch: AutonomousResearchService? = nil,
        cameraService: CameraService? = nil,
        visionProcessor: VisionProcessor? = nil,
        gptVisionClient: GPTVisionClient? = nil,
        emotionDetector: EmotionDetector? = nil,
        faceEnrollment: FaceEnrollment? = nil,
        gmailClient: GmailClient? = nil
    ) {
        // Core tools
        register(ShowTextTool())
        register(ShowImageTool())
        register(ShowAssetImageTool())
        register(ListAssetsTool())
        register(FindFilesTool())

        // Search tools
        register(FindImageTool())
        register(FindVideoTool())
        register(FindRecipeTool())

        // Info tools
        register(GetTimeTool())
        register(GetWeatherTool())
        register(NewsFetchTool())
        register(MovieShowtimesTool())
        register(FishingReportTool())
        register(PriceLookupTool())

        // Memory tools
        register(SaveMemoryTool(memoryStore: memoryStore))
        register(ListMemoriesTool(memoryStore: memoryStore))
        register(DeleteMemoryTool(memoryStore: memoryStore))
        register(ClearMemoriesTool(memoryStore: memoryStore))
        register(RecallAmbientTool())

        // Scheduler tools
        if let taskScheduler {
            register(ScheduleTaskTool(taskScheduler: taskScheduler))
            register(CancelTaskTool(taskScheduler: taskScheduler))
            register(ListTasksTool(taskScheduler: taskScheduler))
            register(TimerManageTool(taskScheduler: taskScheduler))
        }

        // Camera tools
        register(DescribeCameraViewTool(cameraService: cameraService, visionProcessor: visionProcessor))
        register(CameraObjectFinderTool(cameraService: cameraService, visionProcessor: visionProcessor))
        register(CameraFacePresenceTool(cameraService: cameraService, visionProcessor: visionProcessor))
        register(EnrollCameraFaceTool(cameraService: cameraService, visionProcessor: visionProcessor, faceEnrollment: faceEnrollment))
        register(RecognizeCameraFacesTool(cameraService: cameraService, visionProcessor: visionProcessor, faceEnrollment: faceEnrollment))
        register(CameraVisualQATool(cameraService: cameraService, gptVisionClient: gptVisionClient))
        register(CameraGPTVisionTool(cameraService: cameraService, gptVisionClient: gptVisionClient))
        register(DetectEmotionsTool(cameraService: cameraService, visionProcessor: visionProcessor, emotionDetector: emotionDetector))
        register(CameraInventorySnapshotTool(cameraService: cameraService, visionProcessor: visionProcessor))
        register(SaveCameraMemoryNoteTool(cameraService: cameraService, visionProcessor: visionProcessor, memoryStore: memoryStore))

        // Email tools
        register(GmailAuthTool(gmailClient: gmailClient))
        register(GmailReadInboxTool(gmailClient: gmailClient))
        register(GmailSendReplyTool(gmailClient: gmailClient))
        register(GmailDraftReplyTool(gmailClient: gmailClient))
        register(GmailTrashTool(gmailClient: gmailClient))
        register(GmailMarkReadTool(gmailClient: gmailClient))
        register(GmailUnsubscribeTool(gmailClient: gmailClient))
        register(GmailClassifyTool(gmailClient: gmailClient))
        register(GmailOrganizeInboxTool(gmailClient: gmailClient))
        register(GmailOrganizeStopTool())

        // Learning tools
        if let webLearner {
            register(LearnWebsiteTool(webLearner: webLearner))
        }
        if let autonomousResearch {
            register(AutonomousLearnTool(research: autonomousResearch))
            register(StopAutonomousLearnTool(research: autonomousResearch))
        }

        // Skill tools
        if let skillForge {
            register(StartSkillForgeTool(skillForge: skillForge))
            register(ForgeQueueStatusTool(skillForge: skillForge))
            register(ForgeQueueClearTool(skillForge: skillForge))
            register(SkillsLearnStartTool(skillForge: skillForge))
            register(SkillsLearnStatusTool(skillForge: skillForge))
            register(SkillsLearnCancelTool(skillForge: skillForge))
        }
        if let skillStore {
            register(SkillsLearnApproveTool(skillStore: skillStore))
            register(SkillsLearnInstallTool(skillStore: skillStore))
            register(SkillsListTool(skillStore: skillStore))
            register(SkillsRunSimTool(skillStore: skillStore))
            register(SkillsResetBaselineTool(skillStore: skillStore))
        }
        register(SkillsLearnRequestChangesTool())
        register(CapabilityGapToClaudePromptTool())

        // Register all aliases
        registerAliases(Self.defaultAliases)
    }

    /// 145+ alias mappings for LLM flexibility.
    static let defaultAliases: [String: String] = [
        // Weather & Time
        "weather": "get_weather", "getweather": "get_weather",
        "time": "get_time", "gettime": "get_time",
        "what_time": "get_time", "whattime": "get_time",
        "clock": "get_time", "current_time": "get_time",

        // Text & Images
        "showtext": "show_text", "text": "show_text", "display_text": "show_text",
        "showimage": "show_image", "image": "show_image", "display_image": "show_image",
        "findimage": "find_image", "search_image": "find_image", "image_search": "find_image",
        "showassetimage": "show_asset_image", "asset_image": "show_asset_image", "assetimage": "show_asset_image",
        "listassets": "list_assets", "assets": "list_assets",

        // Search & Media
        "findvideo": "find_video", "video": "find_video", "youtube": "find_video", "search_video": "find_video",
        "findrecipe": "find_recipe", "recipe": "find_recipe", "search_recipe": "find_recipe",
        "findfiles": "find_files", "search_files": "find_files",

        // Memory
        "savememory": "save_memory", "remember": "save_memory", "memorize": "save_memory",
        "listmemories": "list_memories", "memories": "list_memories", "recall": "list_memories",
        "deletememory": "delete_memory", "forget": "delete_memory",
        "clearmemories": "clear_memories", "forget_all": "clear_memories",
        "recallambient": "recall_ambient", "whatdidyouhear": "recall_ambient", "ambient_memories": "recall_ambient",

        // Scheduling
        "scheduletask": "schedule_task", "set_alarm": "schedule_task", "alarm": "schedule_task",
        "set_timer": "schedule_task", "timer": "timer.manage",
        "canceltask": "cancel_task", "cancel_alarm": "cancel_task", "cancel_timer": "cancel_task",
        "listtasks": "list_tasks", "list_alarms": "list_tasks", "list_timers": "list_tasks",
        "timermanage": "timer.manage", "settimer": "timer.manage", "canceltimer": "timer.manage", "listtimers": "timer.manage",

        // Camera
        "describecamera": "describe_camera_view", "describe_view": "describe_camera_view", "whatdoyousee": "describe_camera_view",
        "findobjects": "find_camera_objects", "camera_objects": "find_camera_objects",
        "facecheck": "camera_face_presence", "face_presence": "camera_face_presence",
        "enrollface": "enroll_camera_face", "enrollcameraface": "enroll_camera_face", "enroll_face": "enroll_camera_face",
        "recognizefaces": "recognize_camera_faces", "recognize_face": "recognize_camera_faces",
        "visualqa": "camera_visual_qa", "visual_qa": "camera_visual_qa",
        "cameragptvision": "camera_gpt_vision", "gpt_vision": "camera_gpt_vision", "deepvision": "camera_gpt_vision", "analyze_scene": "camera_gpt_vision",
        "detectemotions": "detect_emotions", "facial_emotions": "detect_emotions", "read_emotions": "detect_emotions", "howdotheylook": "detect_emotions",
        "inventorysnapshot": "camera_inventory_snapshot", "inventory": "camera_inventory_snapshot",
        "savecameranote": "save_camera_memory_note", "camera_note": "save_camera_memory_note",

        // Email
        "gmail": "gmail_read_inbox", "readinbox": "gmail_read_inbox", "reademail": "gmail_read_inbox",
        "read_email": "gmail_read_inbox", "checkemail": "gmail_read_inbox", "check_email": "gmail_read_inbox",
        "sendemail": "gmail_send_reply", "send_email": "gmail_send_reply", "email_reply": "gmail_send_reply",
        "draftemail": "gmail_draft_reply", "draft_email": "gmail_draft_reply",
        "trashemail": "gmail_trash", "trash_email": "gmail_trash", "deleteemail": "gmail_trash", "delete_email": "gmail_trash",
        "markemail": "gmail_mark_read", "mark_email_read": "gmail_mark_read",
        "classifyemail": "gmail_classify", "classify_email": "gmail_classify",
        "unsubscribe": "gmail_unsubscribe", "unsubscribeemail": "gmail_unsubscribe",
        "organizeinbox": "gmail_organize_inbox", "organize_inbox": "gmail_organize_inbox",
        "sortinbox": "gmail_organize_inbox", "sort_inbox": "gmail_organize_inbox",
        "cleaninbox": "gmail_organize_inbox", "clean_inbox": "gmail_organize_inbox",
        "stoporganize": "gmail_organize_stop", "stop_organize": "gmail_organize_stop",

        // Learning
        "learnwebsite": "learn_website", "learn_url": "learn_website",
        "autonomouslearn": "autonomous_learn", "auto_learn": "autonomous_learn", "research": "autonomous_learn",
        "stoplearning": "stop_autonomous_learn", "stop_learn": "stop_autonomous_learn",

        // Skills
        "startforge": "start_skill_forge", "skillforge": "start_skill_forge",
        "forgestatus": "forge_queue_status",
        "forgeclear": "forge_queue_clear",
        "learnstart": "skills_learn_start", "learn_skill": "skills_learn_start",
        "learnstatus": "skills_learn_status",
        "learncancel": "skills_learn_cancel",
        "learnapprove": "skills_learn_approve",
        "learninstall": "skills_learn_install",
        "skillslist": "skills_list", "list_skills": "skills_list",
        "runsim": "skills_run_sim", "simulate": "skills_run_sim",
        "resetskills": "skills_reset_baseline",

        // News & Web
        "getnews": "news.fetch", "get_news": "news.fetch", "newsfetch": "news.fetch", "news": "news.fetch",
        "movieshowtimes": "movies.showtimes", "movie_times": "movies.showtimes", "showtimes": "movies.showtimes",
        "fishingreport": "fishing.report", "fishing": "fishing.report",
        "pricelookup": "price.lookup", "pricecheck": "price.lookup", "price": "price.lookup",
    ]
}
