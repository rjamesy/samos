import Foundation

/// File-system-based skill persistence.
/// Skills are stored as individual JSON documents in ~/Library/Application Support/SamOS/Skills/<id>/skill.json.
final class SkillStore {

    static let shared = SkillStore()

    private let fileManager = FileManager.default
    private let skillsDir: URL

    /// In-memory cache, keyed by skill ID.
    private var cache: [String: SkillSpec] = [:]
    private var packageCache: [String: SkillPackage] = [:]

    /// Hard cap on installed skills to prevent prompt bloat.
    static let maxInstalledSkills = 50
    private static let runtimeBaselinePackageIDs: Set<String> = [
        "news.latest",
        "fishing.report",
        "price.woolworths",
        "price.cheapest_online",
        "timer.named"
    ]
    private static let bundledSkillDisplayNames: [String: String] = [
        "alarm_v1": "Alarm (schedule_task)",
        "file_system_access_v1": "File Search (find_files)"
    ]

    private init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        skillsDir = appSupport.appendingPathComponent("SamOS/Skills")

        // Ensure directory exists
        if !fileManager.fileExists(atPath: skillsDir.path) {
            try? fileManager.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        }

        // Purge junk skills before loading cache
        purgeJunkSkillsOnStartup()

        // Populate cache
        cache = loadAllFromDisk()
        packageCache = loadAllPackagesFromDisk()
        migrateBundledSkillDisplayNamesIfNeeded()
        migrateBaselinePackageDisplayNamesIfNeeded()
        purgeObsoleteLegacyForgedSkillsIfNeeded()
        pruneNonRuntimeBaselinePackagesIfNeeded()

        // Startup diagnostics
        let total = cache.count
        let installed = cache.values.filter { Self.isInstalled($0) }.count
        print("[SKILLS] installed=\(installed) total=\(total)")
        if installed > Self.maxInstalledSkills {
            print("[SKILLS] WARNING: installed count \(installed) exceeds cap \(Self.maxInstalledSkills) — will truncate")
        }
    }

    // MARK: - For testing

    /// Creates a SkillStore with a custom directory (for tests).
    init(directory: URL) {
        skillsDir = directory
        if !fileManager.fileExists(atPath: skillsDir.path) {
            try? fileManager.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        }
        cache = loadAllFromDisk()
        packageCache = loadAllPackagesFromDisk()
        migrateBundledSkillDisplayNamesIfNeeded()
        migrateBaselinePackageDisplayNamesIfNeeded()
        purgeObsoleteLegacyForgedSkillsIfNeeded()
        pruneNonRuntimeBaselinePackagesIfNeeded()
    }

    // MARK: - Public API

    /// Returns all skills (including legacy/unapproved).
    func loadAll() -> [SkillSpec] {
        Array(cache.values)
    }

    /// Returns only active, approved, non-disabled skills — capped at maxInstalledSkills.
    func loadInstalled() -> [SkillSpec] {
        let filtered = cache.values.filter { Self.isInstalled($0) }
        let result = Array(filtered.prefix(Self.maxInstalledSkills))
        if filtered.count > Self.maxInstalledSkills {
            print("[SKILLS] ERROR: \(filtered.count) installed skills exceed cap \(Self.maxInstalledSkills) — truncated")
        }
        return result
    }

    /// A skill is "installed" iff status == "active", approvedAt != nil, disabledAt == nil.
    static func isInstalled(_ skill: SkillSpec) -> Bool {
        skill.status == "active" && skill.approvedAt != nil && skill.disabledAt == nil
    }

    /// Returns a skill by ID, or nil if not installed.
    func get(id: String) -> SkillSpec? {
        cache[id]
    }

    /// Absolute path to the persisted skill.json for a skill id.
    func skillFileURL(id: String) -> URL {
        skillsDir.appendingPathComponent(id).appendingPathComponent("skill.json")
    }

    /// True when skill exists on disk and is marked installed/active.
    func isInstalledOnDisk(id: String) -> Bool {
        let file = skillFileURL(id: id)
        guard fileManager.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(SkillSpec.self, from: data) else {
            return false
        }
        return Self.isInstalled(decoded)
    }

    /// Installs (or updates) a skill. Writes to disk and updates cache.
    @discardableResult
    func install(_ skill: SkillSpec) -> Bool {
        let dir = skillsDir.appendingPathComponent(skill.id)
        let file = dir.appendingPathComponent("skill.json")

        do {
            if !fileManager.fileExists(atPath: dir.path) {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(skill)
            try data.write(to: file)
            cache[skill.id] = skill
            return true
        } catch {
            print("[SkillStore] Failed to install skill \(skill.id): \(error.localizedDescription)")
            return false
        }
    }

    /// Removes a skill from disk and cache.
    @discardableResult
    func remove(id: String) -> Bool {
        let dir = skillsDir.appendingPathComponent(id)
        do {
            if fileManager.fileExists(atPath: dir.path) {
                try fileManager.removeItem(at: dir)
            }
            cache.removeValue(forKey: id)
            return true
        } catch {
            print("[SkillStore] Failed to remove skill \(id): \(error.localizedDescription)")
            return false
        }
    }

    /// Copies bundled skills from the app bundle if they aren't already installed,
    /// or re-installs if existing copy lacks metadata (legacy upgrade).
    func installBundledSkillsIfNeeded() {
        installBundledJSONSkillIfNeeded(resource: "alarm_v1")
        installBundledFileSearchSkillIfNeeded()
        installBaselinePackagesIfNeeded()
    }

    /// Number of installed skills.
    var count: Int { cache.count }

    // MARK: - Skill Package API (Phase 4)

    func loadAllPackages() -> [SkillPackage] {
        Array(packageCache.values).sorted { $0.manifest.skillID < $1.manifest.skillID }
    }

    func loadInstalledPackages() -> [SkillPackage] {
        loadAllPackages().filter { package in
            package.signoff?.approved == true
        }
    }

    func getPackage(id: String) -> SkillPackage? {
        packageCache[id]
    }

    @discardableResult
    func installPackage(_ package: SkillPackage) -> Bool {
        let dir = skillsDir.appendingPathComponent(package.manifest.skillID)
        let manifestFile = dir.appendingPathComponent("manifest.json")
        let packageFile = dir.appendingPathComponent("package.json")
        let testsFile = dir.appendingPathComponent("tests.json")

        do {
            if !fileManager.fileExists(atPath: dir.path) {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestData = try encoder.encode(package.manifest)
            let packageData = try encoder.encode(package)
            let testsData = try encoder.encode(package.tests)
            try manifestData.write(to: manifestFile)
            try packageData.write(to: packageFile)
            try testsData.write(to: testsFile)
            packageCache[package.manifest.skillID] = package
            return true
        } catch {
            print("[SkillStore] Failed to install package \(package.manifest.skillID): \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func removePackage(id: String) -> Bool {
        let dir = skillsDir.appendingPathComponent(id)
        do {
            if fileManager.fileExists(atPath: dir.path) {
                try fileManager.removeItem(at: dir)
            }
            packageCache.removeValue(forKey: id)
            cache.removeValue(forKey: id)
            return true
        } catch {
            print("[SkillStore] Failed to remove package \(id): \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func resetPackagesToBaseline() -> Int {
        var removed = 0
        for package in loadAllPackages() where package.manifest.origin == .forged {
            if removePackage(id: package.manifest.skillID) {
                removed += 1
            }
        }
        for baseline in SkillStore.baselinePackages(includeDemoPackages: false) {
            _ = installPackage(baseline)
        }
        return removed
    }

    func packageMatchingToolName(_ raw: String) -> SkillPackage? {
        let normalizedRaw = normalizeIdentifier(raw)
        for package in loadInstalledPackages() {
            if normalizeIdentifier(package.manifest.skillID) == normalizedRaw {
                return package
            }
            if normalizeIdentifier(package.manifest.name) == normalizedRaw {
                return package
            }
            if package.plan.intentPatterns.contains(where: { normalizeIdentifier($0) == normalizedRaw }) {
                return package
            }
        }
        return nil
    }

    func searchInstalledSkills(query: String, limit: Int = 40) -> [SkillSpec] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let scored: [(SkillSpec, Double)] = cache.values.compactMap { skill in
            guard Self.isInstalled(skill) else { return nil }
            let haystack = ([skill.id, skill.name] + skill.triggerPhrases).joined(separator: " ")
            let score = Self.searchScore(query: trimmed, haystack: haystack)
            guard score > 0 else { return nil }
            return (skill, score)
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.id < rhs.0.id
                }
                return lhs.1 > rhs.1
            }
            .prefix(max(1, limit))
            .map(\.0)
    }

    func searchInstalledPackages(query: String, limit: Int = 40) -> [SkillPackage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let scored: [(SkillPackage, Double)] = packageCache.values.compactMap { package in
            guard package.signoff?.approved == true else { return nil }
            let haystack = [
                package.manifest.skillID,
                package.manifest.name,
                package.plan.name
            ] + package.plan.intentPatterns
            let score = Self.searchScore(query: trimmed, haystack: haystack.joined(separator: " "))
            guard score > 0 else { return nil }
            return (package, score)
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.manifest.skillID < rhs.0.manifest.skillID
                }
                return lhs.1 > rhs.1
            }
            .prefix(max(1, limit))
            .map(\.0)
    }

    // MARK: - Private

    /// Purges unreadable/corrupt skill directories generated by previous failed runs.
    /// Called once at startup BEFORE loading the cache.
    private func purgeJunkSkillsOnStartup() {
        guard let dirs = try? fileManager.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: nil) else { return }
        var purgedCount = 0

        for dir in dirs {
            let packageFile = dir.appendingPathComponent("package.json")
            if fileManager.fileExists(atPath: packageFile.path) {
                continue
            }

            // Content-based cleanup: remove undecodable or invalid/inactive entries.
            let file = dir.appendingPathComponent("skill.json")
            guard let data = try? Data(contentsOf: file),
                  let skill = try? JSONDecoder().decode(SkillSpec.self, from: data) else {
                // Can't decode → delete
                try? fileManager.removeItem(at: dir)
                purgedCount += 1
                continue
            }

            let isUnapproved = skill.approvedAt == nil
            let isBadStatus = skill.status != nil && skill.status != "active"
            let isDisabled = skill.disabledAt != nil

            if isUnapproved || isBadStatus || isDisabled {
                try? fileManager.removeItem(at: dir)
                purgedCount += 1
            }
        }

        if purgedCount > 0 {
            print("[SKILLS] Purged \(purgedCount) junk skill directories")
        }
    }

    private func loadAllFromDisk() -> [String: SkillSpec] {
        var result: [String: SkillSpec] = [:]
        guard let dirs = try? fileManager.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: nil) else {
            return result
        }
        for dir in dirs {
            let file = dir.appendingPathComponent("skill.json")
            guard let data = try? Data(contentsOf: file),
                  let skill = try? JSONDecoder().decode(SkillSpec.self, from: data)
            else { continue }
            result[skill.id] = skill
        }
        return result
    }

    private func loadAllPackagesFromDisk() -> [String: SkillPackage] {
        var result: [String: SkillPackage] = [:]
        guard let dirs = try? fileManager.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: nil) else {
            return result
        }
        for dir in dirs {
            let file = dir.appendingPathComponent("package.json")
            guard let data = try? Data(contentsOf: file),
                  let package = try? JSONDecoder().decode(SkillPackage.self, from: data) else {
                continue
            }
            result[package.manifest.skillID] = package
        }
        return result
    }

    private func installBundledJSONSkillIfNeeded(resource: String) {
        let needsInstall = cache[resource] == nil || cache[resource]?.approvedAt == nil
        guard needsInstall else { return }
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              var skill = try? JSONDecoder().decode(SkillSpec.self, from: data) else {
            return
        }
        if let mappedName = Self.bundledSkillDisplayNames[resource] {
            skill = Self.renamedSkill(skill, name: mappedName)
        }
        skill.status = "active"
        skill.approvedAt = Date()
        skill.disabledAt = nil
        install(skill)
        print("[SkillStore] Installed bundled skill: \(skill.name)")
    }

    private func installBundledFileSearchSkillIfNeeded() {
        let id = "file_system_access_v1"
        if let existing = cache[id], Self.isInstalled(existing) {
            return
        }

        var skill = SkillSpec(
            id: id,
            name: Self.bundledSkillDisplayNames[id] ?? "File Search (find_files)",
            version: 1,
            triggerPhrases: [
                "find that i downloaded",
                "what's in my downloads folder",
                "whats in my downloads folder",
                "what's in my documents folder",
                "find all pdfs",
                "find a word document",
                "find file",
                "find document named"
            ],
            slots: [
                SkillSpec.SlotDef(name: "query", type: .string, required: false, prompt: nil)
            ],
            steps: [
                SkillSpec.StepDef(action: "find_files", args: ["query": "{{query}}"])
            ],
            onTrigger: nil
        )
        skill.status = "active"
        skill.approvedAt = Date()
        skill.disabledAt = nil

        install(skill)
        print("[SkillStore] Installed bundled skill: \(skill.name)")
    }

    private func installBaselinePackagesIfNeeded() {
        for package in SkillStore.baselinePackages(includeDemoPackages: false) {
            let existing = packageCache[package.manifest.skillID]
            if existing?.signoff?.approved == true {
                continue
            }
            _ = installPackage(package)
        }
    }

    private func normalizeIdentifier(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let parts = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return parts.joined()
    }

    static func baselinePackages(now: Date = Date(),
                                 includeDemoPackages: Bool = true) -> [SkillPackage] {
        let nowISO = ISO8601DateFormatter().string(from: now)
        let echoPlan = SkillPlan(
            skillID: "skill.echo_format",
            name: "Echo Format",
            version: 1,
            intentPatterns: [
                "rewrite this as dot points",
                "dot points",
                "bullet this"
            ],
            inputsSchema: SkillJSONSchema(
                type: .object,
                required: ["text"],
                properties: [
                    "text": SkillJSONSchema(type: .string)
                ]
            ),
            outputsSchema: SkillJSONSchema(
                type: .object,
                required: ["formatted", "spoken"],
                properties: [
                    "formatted": SkillJSONSchema(type: .string),
                    "spoken": SkillJSONSchema(type: .string)
                ]
            ),
            toolRequirements: [],
            conversationPolicy: SkillConversationPolicy(
                tone: "neutral",
                safetyConstraints: ["No external tool calls", "Deterministic formatting only"]
            ),
            testCases: [
                SkillTestCase(
                    name: "rewrite to bullets",
                    inputText: "Rewrite this as dot points: alpha, beta, gamma",
                    expected: [
                        "formatted": .string("- alpha"),
                        "spoken": .string("Done")
                    ],
                    maxSteps: 8
                )
            ]
        )
        let echoSpec = SkillSpecV2(
            steps: [
                SkillPackageStep(
                    id: "extract_content",
                    type: .extract,
                    extract: SkillExtractStep(
                        source: "input.text",
                        pattern: "(?i)rewrite this as dot points\\s*:\\s*(.+)$",
                        outputVar: "content"
                    ),
                    format: nil,
                    toolCall: nil,
                    llmCall: nil,
                    branch: nil,
                    returnStep: nil
                ),
                SkillPackageStep(
                    id: "format_bullets",
                    type: .format,
                    extract: nil,
                    format: SkillFormatStep(
                        template: nil,
                        inputVar: "content",
                        mode: "bullets",
                        outputVar: "formatted"
                    ),
                    toolCall: nil,
                    llmCall: nil,
                    branch: nil,
                    returnStep: nil
                ),
                SkillPackageStep(
                    id: "return",
                    type: .return,
                    extract: nil,
                    format: nil,
                    toolCall: nil,
                    llmCall: nil,
                    branch: nil,
                    returnStep: SkillReturnStep(
                        output: [
                            "formatted": "{{formatted}}",
                            "spoken": "Done."
                        ]
                    )
                )
            ],
            prompts: [:],
            failureModes: [
                SkillFailureMode(code: "NO_INPUT", message: "No input provided.", action: "return")
            ],
            limits: SkillLimits(maxOutputChars: 2_000, maxOutputTokens: 256, timeoutMs: 3_000)
        )
        let echoPackage = SkillPackage(
            manifest: SkillManifest(
                skillID: echoPlan.skillID,
                name: echoPlan.name,
                version: echoPlan.version,
                origin: .baseline,
                createdAtISO8601: nowISO
            ),
            plan: echoPlan,
            spec: echoSpec,
            tests: echoPlan.testCases,
            signoff: SkillSignoff(
                approved: true,
                reason: "Bundled baseline skill",
                requiredChanges: [],
                riskNotes: [],
                packageHash: "",
                model: "baseline",
                approvedAtISO8601: nowISO
            )
        )

        let minutesPlan = SkillPlan(
            skillID: "skill.meeting_minutes_stub",
            name: "Meeting Minutes Stub",
            version: 1,
            intentPatterns: [
                "turn this into minutes",
                "meeting minutes"
            ],
            inputsSchema: SkillJSONSchema(
                type: .object,
                required: ["text"],
                properties: [
                    "text": SkillJSONSchema(type: .string)
                ]
            ),
            outputsSchema: SkillJSONSchema(
                type: .object,
                required: ["formatted", "spoken"],
                properties: [
                    "formatted": SkillJSONSchema(type: .string),
                    "spoken": SkillJSONSchema(type: .string)
                ]
            ),
            toolRequirements: [],
            conversationPolicy: SkillConversationPolicy(
                tone: "neutral",
                safetyConstraints: ["JSON-only llm_call", "Deterministic mode"]
            ),
            testCases: [
                SkillTestCase(
                    name: "minutes stub",
                    inputText: "Turn this into minutes: discussed launch date and risks",
                    expected: [
                        "formatted": .string("summary"),
                        "spoken": .string("minutes")
                    ],
                    maxSteps: 8
                )
            ]
        )
        let minutesSpec = SkillSpecV2(
            steps: [
                SkillPackageStep(
                    id: "extract_content",
                    type: .extract,
                    extract: SkillExtractStep(
                        source: "input.text",
                        pattern: "(?i)turn this into minutes\\s*:\\s*(.+)$",
                        outputVar: "content"
                    ),
                    format: nil,
                    toolCall: nil,
                    llmCall: nil,
                    branch: nil,
                    returnStep: nil
                ),
                SkillPackageStep(
                    id: "minutes_llm",
                    type: .llmCall,
                    extract: nil,
                    format: nil,
                    toolCall: nil,
                    llmCall: SkillLLMCallStep(
                        promptTemplate: "Return JSON with keys summary and actions for: {{content}}",
                        responseVar: "minutes_json",
                        temperature: 0,
                        maxOutputTokens: 200,
                        jsonOnly: true
                    ),
                    branch: nil,
                    returnStep: nil
                ),
                SkillPackageStep(
                    id: "return",
                    type: .return,
                    extract: nil,
                    format: nil,
                    toolCall: nil,
                    llmCall: nil,
                    branch: nil,
                    returnStep: SkillReturnStep(
                        output: [
                            "formatted": "{{minutes_json}}",
                            "spoken": "Here are your meeting minutes."
                        ]
                    )
                )
            ],
            prompts: [
                "minutes_prompt": "Return only JSON with summary and actions."
            ],
            failureModes: [
                SkillFailureMode(code: "LLM_JSON_INVALID", message: "LLM returned invalid JSON.", action: "fail")
            ],
            limits: SkillLimits(maxOutputChars: 2_500, maxOutputTokens: 300, timeoutMs: 4_000)
        )
        let minutesPackage = SkillPackage(
            manifest: SkillManifest(
                skillID: minutesPlan.skillID,
                name: minutesPlan.name,
                version: minutesPlan.version,
                origin: .baseline,
                createdAtISO8601: nowISO
            ),
            plan: minutesPlan,
            spec: minutesSpec,
            tests: minutesPlan.testCases,
            signoff: SkillSignoff(
                approved: true,
                reason: "Bundled baseline skill",
                requiredChanges: [],
                riskNotes: [],
                packageHash: "",
                model: "baseline",
                approvedAtISO8601: nowISO
            )
        )

        let newsPlan = SkillPlan(
            skillID: "news.latest",
            name: "Latest News (news.basic)",
            version: 1,
            intentPatterns: [
                "latest news",
                "news today",
                "what's happening",
                "what is the latest news",
                "latest ai news",
                "latest australia news"
            ],
            inputsSchema: SkillJSONSchema(
                type: .object,
                required: ["text"],
                properties: [
                    "text": SkillJSONSchema(type: .string)
                ]
            ),
            outputsSchema: SkillJSONSchema(
                type: .object,
                required: ["formatted", "spoken"],
                properties: [
                    "formatted": SkillJSONSchema(type: .string),
                    "spoken": SkillJSONSchema(type: .string)
                ]
            ),
            toolRequirements: [
                SkillToolRequirement(name: "news.fetch", permissions: [PermissionScope.webRead.rawValue])
            ],
            conversationPolicy: SkillConversationPolicy(
                tone: "neutral",
                safetyConstraints: ["Always include source and publish date in output bullets."]
            ),
            testCases: [
                SkillTestCase(
                    name: "latest news default",
                    inputText: "latest news",
                    expected: [
                        "formatted": .string("No recent items"),
                        "spoken": .string("latest news")
                    ],
                    mustCallTools: ["news.fetch"],
                    maxSteps: 10
                )
            ]
        )
        let newsSpec = SkillSpecV2(
            steps: [
                SkillPackageStep(
                    id: "extract_topic",
                    type: .extract,
                    extract: SkillExtractStep(
                        source: "input.text",
                        pattern: "(?i)(?:latest\\s+news|news\\s+today|what\\'?s\\s+happening)\\s*(?:in|about)?\\s*(.*)$",
                        outputVar: "topic"
                    ),
                    format: nil,
                    toolCall: nil,
                    llmCall: nil,
                    branch: nil,
                    returnStep: nil
                ),
                SkillPackageStep(
                    id: "extract_country",
                    type: .extract,
                    extract: SkillExtractStep(
                        source: "input.text",
                        pattern: "(?i)\\b(australia|australian|au)\\b",
                        outputVar: "country_hint"
                    ),
                    format: nil,
                    toolCall: nil,
                    llmCall: nil,
                    branch: nil,
                    returnStep: nil
                ),
                SkillPackageStep(
                    id: "fetch_news",
                    type: .toolCall,
                    extract: nil,
                    format: nil,
                    toolCall: SkillToolCallStep(
                        name: "news.fetch",
                        args: [
                            "query": "{{topic}}",
                            "country": "{{country_hint}}",
                            "time_window_hours": "24",
                            "max_items": "12"
                        ],
                        outputVar: "news_payload"
                    ),
                    llmCall: nil,
                    branch: nil,
                    returnStep: nil
                ),
                SkillPackageStep(
                    id: "format_news",
                    type: .format,
                    extract: nil,
                    format: SkillFormatStep(
                        template: nil,
                        inputVar: "news_payload",
                        mode: "news_bullets",
                        outputVar: "formatted"
                    ),
                    toolCall: nil,
                    llmCall: nil,
                    branch: nil,
                    returnStep: nil
                ),
                SkillPackageStep(
                    id: "return",
                    type: .return,
                    extract: nil,
                    format: nil,
                    toolCall: nil,
                    llmCall: nil,
                    branch: nil,
                    returnStep: SkillReturnStep(
                        output: [
                            "formatted": "{{formatted}}",
                            "spoken": "Here are the latest news headlines."
                        ]
                    )
                )
            ],
            prompts: [:],
            failureModes: [
                SkillFailureMode(code: "NEWS_FETCH_FAILED", message: "Unable to fetch latest news.", action: "fail")
            ],
            limits: SkillLimits(maxOutputChars: 5_000, maxOutputTokens: 512, timeoutMs: 7_000)
        )
        let newsPackage = SkillPackage(
            manifest: SkillManifest(
                skillID: newsPlan.skillID,
                name: newsPlan.name,
                version: newsPlan.version,
                origin: .baseline,
                createdAtISO8601: nowISO
            ),
            plan: newsPlan,
            spec: newsSpec,
            tests: newsPlan.testCases,
            signoff: SkillSignoff(
                approved: true,
                reason: "Bundled baseline skill",
                requiredChanges: [],
                riskNotes: [],
                packageHash: "",
                model: "baseline",
                approvedAtISO8601: nowISO
            )
        )

        let fishingPlan = SkillPlan(
            skillID: "fishing.report",
            name: "Fishing Report (fishing.basic)",
            version: 1,
            intentPatterns: [
                "get fishing report for moreton bay",
                "fishing report for",
                "fishing report"
            ],
            inputsSchema: SkillJSONSchema(
                type: .object,
                required: ["text"],
                properties: [
                    "text": SkillJSONSchema(type: .string)
                ]
            ),
            outputsSchema: SkillJSONSchema(
                type: .object,
                required: ["formatted", "spoken"],
                properties: [
                    "formatted": SkillJSONSchema(type: .string),
                    "spoken": SkillJSONSchema(type: .string)
                ]
            ),
            toolRequirements: [
                SkillToolRequirement(name: "fishing.report", permissions: [PermissionScope.webRead.rawValue])
            ],
            conversationPolicy: SkillConversationPolicy(
                tone: "neutral",
                safetyConstraints: ["Cite source links in the report output."]
            ),
            testCases: [
                SkillTestCase(
                    name: "moreton bay fishing report",
                    inputText: "get fishing report for moreton bay",
                    expected: [
                        "formatted": .string("Fishing Report"),
                        "spoken": .string("fishing report")
                    ],
                    mustCallTools: ["fishing.report"],
                    maxSteps: 10
                )
            ]
        )
        let fishingSpec = SkillSpecV2(
            steps: [
                SkillPackageStep(
                    id: "extract_location",
                    type: .extract,
                    extract: SkillExtractStep(
                        source: "input.text",
                        pattern: "(?i)(?:for|in)\\s+([A-Za-z][A-Za-z\\s'\\-]{2,60})",
                        outputVar: "location"
                    ),
                    format: nil,
                    toolCall: nil,
                    llmCall: nil,
                    branch: nil,
                    returnStep: nil
                ),
                SkillPackageStep(
                    id: "fetch_report",
                    type: .toolCall,
                    extract: nil,
                    format: nil,
                    toolCall: SkillToolCallStep(
                        name: "fishing.report",
                        args: [
                            "location": "{{location}}",
                            "text": "{{input.text}}"
                        ],
                        outputVar: "fishing_payload"
                    ),
                    llmCall: nil,
                    branch: nil,
                    returnStep: nil
                ),
                SkillPackageStep(
                    id: "format_report",
                    type: .format,
                    extract: nil,
                    format: SkillFormatStep(
                        template: nil,
                        inputVar: "fishing_payload",
                        mode: "tool_formatted",
                        outputVar: "formatted"
                    ),
                    toolCall: nil,
                    llmCall: nil,
                    branch: nil,
                    returnStep: nil
                ),
                SkillPackageStep(
                    id: "return",
                    type: .return,
                    extract: nil,
                    format: nil,
                    toolCall: nil,
                    llmCall: nil,
                    branch: nil,
                    returnStep: SkillReturnStep(
                        output: [
                            "formatted": "{{formatted}}",
                            "spoken": "Here is your fishing report."
                        ]
                    )
                )
            ],
            prompts: [:],
            failureModes: [
                SkillFailureMode(code: "FISHING_REPORT_FAILED", message: "Unable to fetch fishing report.", action: "fail")
            ],
            limits: SkillLimits(maxOutputChars: 5_000, maxOutputTokens: 512, timeoutMs: 8_000)
        )
        let fishingPackage = SkillPackage(
            manifest: SkillManifest(
                skillID: fishingPlan.skillID,
                name: fishingPlan.name,
                version: fishingPlan.version,
                origin: .baseline,
                createdAtISO8601: nowISO
            ),
            plan: fishingPlan,
            spec: fishingSpec,
            tests: fishingPlan.testCases,
            signoff: SkillSignoff(
                approved: true,
                reason: "Bundled baseline skill",
                requiredChanges: [],
                riskNotes: [],
                packageHash: "",
                model: "baseline",
                approvedAtISO8601: nowISO
            )
        )

        let woolworthsPricePlan = SkillPlan(
            skillID: "price.woolworths",
            name: "Woolworths Price (pricing.basic)",
            version: 1,
            intentPatterns: [
                "what is the price of",
                "price at woolworths",
                "woolworths price"
            ],
            inputsSchema: SkillJSONSchema(
                type: .object,
                required: ["text"],
                properties: [
                    "text": SkillJSONSchema(type: .string)
                ]
            ),
            outputsSchema: SkillJSONSchema(
                type: .object,
                required: ["formatted", "spoken"],
                properties: [
                    "formatted": SkillJSONSchema(type: .string),
                    "spoken": SkillJSONSchema(type: .string)
                ]
            ),
            toolRequirements: [
                SkillToolRequirement(name: "price.lookup", permissions: [PermissionScope.webRead.rawValue])
            ],
            conversationPolicy: SkillConversationPolicy(
                tone: "neutral",
                safetyConstraints: ["Return live price results with links."]
            ),
            testCases: [
                SkillTestCase(
                    name: "woolworths price lookup",
                    inputText: "what is the price of milk at woolworths",
                    expected: [
                        "formatted": .string("Price"),
                        "spoken": .string("price")
                    ],
                    mustCallTools: ["price.lookup"],
                    maxSteps: 10
                )
            ]
        )
        let woolworthsPriceSpec = SkillSpecV2(
            steps: [
                SkillPackageStep(
                    id: "lookup_price",
                    type: .toolCall,
                    extract: nil,
                    format: nil,
                    toolCall: SkillToolCallStep(
                        name: "price.lookup",
                        args: [
                            "text": "{{input.text}}",
                            "store": "woolworths"
                        ],
                        outputVar: "price_payload"
                    ),
                    llmCall: nil,
                    branch: nil,
                    returnStep: nil
                ),
                SkillPackageStep(
                    id: "format_price",
                    type: .format,
                    extract: nil,
                    format: SkillFormatStep(
                        template: nil,
                        inputVar: "price_payload",
                        mode: "tool_formatted",
                        outputVar: "formatted"
                    ),
                    toolCall: nil,
                    llmCall: nil,
                    branch: nil,
                    returnStep: nil
                ),
                SkillPackageStep(
                    id: "return",
                    type: .return,
                    extract: nil,
                    format: nil,
                    toolCall: nil,
                    llmCall: nil,
                    branch: nil,
                    returnStep: SkillReturnStep(
                        output: [
                            "formatted": "{{formatted}}",
                            "spoken": "Here is the Woolworths price result."
                        ]
                    )
                )
            ],
            prompts: [:],
            failureModes: [
                SkillFailureMode(code: "PRICE_LOOKUP_FAILED", message: "Unable to fetch price.", action: "fail")
            ],
            limits: SkillLimits(maxOutputChars: 5_000, maxOutputTokens: 512, timeoutMs: 8_000)
        )
        let woolworthsPricePackage = SkillPackage(
            manifest: SkillManifest(
                skillID: woolworthsPricePlan.skillID,
                name: woolworthsPricePlan.name,
                version: woolworthsPricePlan.version,
                origin: .baseline,
                createdAtISO8601: nowISO
            ),
            plan: woolworthsPricePlan,
            spec: woolworthsPriceSpec,
            tests: woolworthsPricePlan.testCases,
            signoff: SkillSignoff(
                approved: true,
                reason: "Bundled baseline skill",
                requiredChanges: [],
                riskNotes: [],
                packageHash: "",
                model: "baseline",
                approvedAtISO8601: nowISO
            )
        )

        let cheapestPricePlan = SkillPlan(
            skillID: "price.cheapest_online",
            name: "Cheapest Price Online (pricing.basic)",
            version: 1,
            intentPatterns: [
                "find the cheapest price for",
                "cheapest price online",
                "best price online"
            ],
            inputsSchema: SkillJSONSchema(
                type: .object,
                required: ["text"],
                properties: [
                    "text": SkillJSONSchema(type: .string)
                ]
            ),
            outputsSchema: SkillJSONSchema(
                type: .object,
                required: ["formatted", "spoken"],
                properties: [
                    "formatted": SkillJSONSchema(type: .string),
                    "spoken": SkillJSONSchema(type: .string)
                ]
            ),
            toolRequirements: [
                SkillToolRequirement(name: "price.lookup", permissions: [PermissionScope.webRead.rawValue])
            ],
            conversationPolicy: SkillConversationPolicy(
                tone: "neutral",
                safetyConstraints: ["Return online price comparison with links and prices."]
            ),
            testCases: [
                SkillTestCase(
                    name: "cheapest online price",
                    inputText: "find the cheapest price for olive oil online",
                    expected: [
                        "formatted": .string("Cheapest"),
                        "spoken": .string("price")
                    ],
                    mustCallTools: ["price.lookup"],
                    maxSteps: 10
                )
            ]
        )
        let cheapestPriceSpec = SkillSpecV2(
            steps: [
                SkillPackageStep(
                    id: "lookup_cheapest",
                    type: .toolCall,
                    extract: nil,
                    format: nil,
                    toolCall: SkillToolCallStep(
                        name: "price.lookup",
                        args: [
                            "text": "{{input.text}}",
                            "mode": "cheapest"
                        ],
                        outputVar: "price_payload"
                    ),
                    llmCall: nil,
                    branch: nil,
                    returnStep: nil
                ),
                SkillPackageStep(
                    id: "format_price",
                    type: .format,
                    extract: nil,
                    format: SkillFormatStep(
                        template: nil,
                        inputVar: "price_payload",
                        mode: "tool_formatted",
                        outputVar: "formatted"
                    ),
                    toolCall: nil,
                    llmCall: nil,
                    branch: nil,
                    returnStep: nil
                ),
                SkillPackageStep(
                    id: "return",
                    type: .return,
                    extract: nil,
                    format: nil,
                    toolCall: nil,
                    llmCall: nil,
                    branch: nil,
                    returnStep: SkillReturnStep(
                        output: [
                            "formatted": "{{formatted}}",
                            "spoken": "Here are the cheapest online price results."
                        ]
                    )
                )
            ],
            prompts: [:],
            failureModes: [
                SkillFailureMode(code: "PRICE_COMPARE_FAILED", message: "Unable to compare prices.", action: "fail")
            ],
            limits: SkillLimits(maxOutputChars: 5_000, maxOutputTokens: 512, timeoutMs: 8_000)
        )
        let cheapestPricePackage = SkillPackage(
            manifest: SkillManifest(
                skillID: cheapestPricePlan.skillID,
                name: cheapestPricePlan.name,
                version: cheapestPricePlan.version,
                origin: .baseline,
                createdAtISO8601: nowISO
            ),
            plan: cheapestPricePlan,
            spec: cheapestPriceSpec,
            tests: cheapestPricePlan.testCases,
            signoff: SkillSignoff(
                approved: true,
                reason: "Bundled baseline skill",
                requiredChanges: [],
                riskNotes: [],
                packageHash: "",
                model: "baseline",
                approvedAtISO8601: nowISO
            )
        )

        let timerPlan = SkillPlan(
            skillID: "timer.named",
            name: "Named Timers (timer.basic)",
            version: 1,
            intentPatterns: [
                "set a timer for",
                "cancel a timer by",
                "list timers by",
                "cancel timer",
                "list timers"
            ],
            inputsSchema: SkillJSONSchema(
                type: .object,
                required: ["text"],
                properties: [
                    "text": SkillJSONSchema(type: .string)
                ]
            ),
            outputsSchema: SkillJSONSchema(
                type: .object,
                required: ["formatted", "spoken"],
                properties: [
                    "formatted": SkillJSONSchema(type: .string),
                    "spoken": SkillJSONSchema(type: .string)
                ]
            ),
            toolRequirements: [
                SkillToolRequirement(name: "timer.manage", permissions: [])
            ],
            conversationPolicy: SkillConversationPolicy(
                tone: "neutral",
                safetyConstraints: ["Timers must be named before final scheduling."]
            ),
            testCases: [
                SkillTestCase(
                    name: "set timer asks for name when missing",
                    inputText: "set a timer for 10 minutes",
                    expected: [
                        "formatted": .string("timer"),
                        "spoken": .string("timer")
                    ],
                    mustCallTools: ["timer.manage"],
                    maxSteps: 10
                )
            ]
        )
        let timerSpec = SkillSpecV2(
            steps: [
                SkillPackageStep(
                    id: "manage_timer",
                    type: .toolCall,
                    extract: nil,
                    format: nil,
                    toolCall: SkillToolCallStep(
                        name: "timer.manage",
                        args: [
                            "text": "{{input.text}}"
                        ],
                        outputVar: "timer_payload"
                    ),
                    llmCall: nil,
                    branch: nil,
                    returnStep: nil
                ),
                SkillPackageStep(
                    id: "format_timer",
                    type: .format,
                    extract: nil,
                    format: SkillFormatStep(
                        template: nil,
                        inputVar: "timer_payload",
                        mode: "tool_formatted",
                        outputVar: "formatted"
                    ),
                    toolCall: nil,
                    llmCall: nil,
                    branch: nil,
                    returnStep: nil
                ),
                SkillPackageStep(
                    id: "return",
                    type: .return,
                    extract: nil,
                    format: nil,
                    toolCall: nil,
                    llmCall: nil,
                    branch: nil,
                    returnStep: SkillReturnStep(
                        output: [
                            "formatted": "{{formatted}}",
                            "spoken": "Timer update ready."
                        ]
                    )
                )
            ],
            prompts: [:],
            failureModes: [
                SkillFailureMode(code: "TIMER_MANAGE_FAILED", message: "Unable to manage timer.", action: "fail")
            ],
            limits: SkillLimits(maxOutputChars: 4_000, maxOutputTokens: 256, timeoutMs: 6_000)
        )
        let timerPackage = SkillPackage(
            manifest: SkillManifest(
                skillID: timerPlan.skillID,
                name: timerPlan.name,
                version: timerPlan.version,
                origin: .baseline,
                createdAtISO8601: nowISO
            ),
            plan: timerPlan,
            spec: timerSpec,
            tests: timerPlan.testCases,
            signoff: SkillSignoff(
                approved: true,
                reason: "Bundled baseline skill",
                requiredChanges: [],
                riskNotes: [],
                packageHash: "",
                model: "baseline",
                approvedAtISO8601: nowISO
            )
        )

        let hasher = { (package: SkillPackage) -> SkillPackage in
            var mutable = package
            let hash = SkillForgePipelineV2.packageHash(mutable)
            if var signoff = mutable.signoff {
                signoff.packageHash = hash
                mutable.signoff = signoff
            }
            return mutable
        }

        let all = [
            hasher(echoPackage),
            hasher(minutesPackage),
            hasher(newsPackage),
            hasher(fishingPackage),
            hasher(woolworthsPricePackage),
            hasher(cheapestPricePackage),
            hasher(timerPackage)
        ]
        guard includeDemoPackages else {
            return all.filter { runtimeBaselinePackageIDs.contains($0.manifest.skillID) }
        }
        return all
    }

    private func migrateBundledSkillDisplayNamesIfNeeded() {
        for (skillID, desiredName) in Self.bundledSkillDisplayNames {
            guard let existing = cache[skillID], existing.name != desiredName else { continue }
            let renamed = Self.renamedSkill(existing, name: desiredName)
            _ = install(renamed)
        }
    }

    private func purgeObsoleteLegacyForgedSkillsIfNeeded() {
        let obsoleteIDs = cache.keys.filter { $0.hasPrefix("forged_") }
        guard !obsoleteIDs.isEmpty else { return }
        for id in obsoleteIDs {
            _ = remove(id: id)
        }
        print("[SKILLS] Purged \(obsoleteIDs.count) legacy forged skills")
    }

    private func pruneNonRuntimeBaselinePackagesIfNeeded() {
        let stalePackages = loadAllPackages().filter { package in
            package.manifest.origin == .baseline
                && !Self.runtimeBaselinePackageIDs.contains(package.manifest.skillID)
        }
        guard !stalePackages.isEmpty else { return }
        for package in stalePackages {
            _ = removePackage(id: package.manifest.skillID)
        }
        print("[SKILLS] Removed \(stalePackages.count) non-runtime baseline skill packages")
    }

    private func migrateBaselinePackageDisplayNamesIfNeeded() {
        let desiredNames = Dictionary(
            uniqueKeysWithValues: Self.baselinePackages().map { ($0.manifest.skillID, $0.manifest.name) }
        )

        for package in loadAllPackages() where package.manifest.origin == .baseline {
            guard let desired = desiredNames[package.manifest.skillID],
                  package.manifest.name != desired || package.plan.name != desired else {
                continue
            }

            var updated = package
            updated.manifest.name = desired
            updated.plan.name = desired
            if var signoff = updated.signoff {
                signoff.packageHash = SkillForgePipelineV2.packageHash(updated)
                updated.signoff = signoff
            }
            _ = installPackage(updated)
        }
    }

    private static func renamedSkill(_ skill: SkillSpec, name: String) -> SkillSpec {
        var updated = SkillSpec(
            id: skill.id,
            name: name,
            version: skill.version,
            triggerPhrases: skill.triggerPhrases,
            slots: skill.slots,
            steps: skill.steps,
            onTrigger: skill.onTrigger
        )
        updated.status = skill.status
        updated.approvedAt = skill.approvedAt
        updated.disabledAt = skill.disabledAt
        return updated
    }

    private static func searchScore(query: String, haystack: String) -> Double {
        let normalizedQuery = query.lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return 0 }

        let normalizedHaystack = haystack.lowercased()
        let tokens = Set(normalizedQuery.split(separator: " ").map(String.init))
        guard !tokens.isEmpty else { return 0 }

        var score = 0.0
        if normalizedHaystack.contains(normalizedQuery) {
            score += 3.0
        }
        for token in tokens where normalizedHaystack.contains(token) {
            score += 1.0
        }
        return score
    }
}

struct CapabilityDescriptor: Identifiable, Equatable {
    var id: String
    var name: String
    var tools: [String]
    var permissions: [String]
    var keywords: [String]
    var source: String
    var manifestPath: String?
}

struct CapabilityOverrideRecord: Codable, Equatable {
    var id: String
    var name: String?
    var tools: [String]?
    var permissions: [String]?
    var keywords: [String]
}

final class CapabilityMetadataStore {
    static let shared = CapabilityMetadataStore()

    private let queue = DispatchQueue(label: "SamOS.CapabilityMetadataStore")
    private let fileURL: URL
    private var cache: [String: CapabilityOverrideRecord] = [:]

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("SamOS", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("capability_overrides.json")
        }
        load()
    }

    func override(for capabilityID: String) -> CapabilityOverrideRecord? {
        queue.sync { cache[capabilityID] }
    }

    func allOverrides() -> [String: CapabilityOverrideRecord] {
        queue.sync { cache }
    }

    func saveOverride(capabilityID: String,
                      name: String?,
                      tools: [String]?,
                      permissions: [String]?,
                      keywords: [String]) {
        let id = capabilityID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }

        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTools = tools?.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let cleanPermissions = permissions?.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let cleanKeywords = keywords.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        let record = CapabilityOverrideRecord(
            id: id,
            name: cleanName?.isEmpty == false ? cleanName : nil,
            tools: cleanTools?.isEmpty == false ? cleanTools : nil,
            permissions: cleanPermissions?.isEmpty == false ? cleanPermissions : nil,
            keywords: cleanKeywords
        )

        queue.sync {
            cache[id] = record
            persistLocked()
        }
    }

    private func load() {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let records = try? JSONDecoder().decode([CapabilityOverrideRecord].self, from: data) else {
                cache = [:]
                return
            }
            cache = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        }
    }

    private func persistLocked() {
        let records = Array(cache.values).sorted { $0.id < $1.id }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private struct SkillCapabilityLinkRecord: Codable, Equatable {
    var skillID: String
    var capabilityIDs: [String]
    var updatedAtISO8601: String

    enum CodingKeys: String, CodingKey {
        case skillID = "skill_id"
        case capabilityIDs = "capability_ids"
        case updatedAtISO8601 = "updated_at"
    }
}

final class SkillCapabilityLinkStore {
    static let shared = SkillCapabilityLinkStore()

    private let queue = DispatchQueue(label: "SamOS.SkillCapabilityLinkStore")
    private let fileURL: URL
    private var cache: [String: SkillCapabilityLinkRecord] = [:]

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("SamOS", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("skill_capability_links.json")
        }
        load()
    }

    func capabilities(forSkillID skillID: String) -> [String] {
        queue.sync {
            cache[skillID]?.capabilityIDs ?? []
        }
    }

    func allLinks() -> [String: [String]] {
        queue.sync {
            Dictionary(uniqueKeysWithValues: cache.values.map { ($0.skillID, $0.capabilityIDs) })
        }
    }

    func setCapabilities(_ capabilityIDs: [String], forSkillID skillID: String) {
        let id = skillID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        let cleaned = Array(
            Set(capabilityIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        ).sorted()
        let record = SkillCapabilityLinkRecord(
            skillID: id,
            capabilityIDs: cleaned,
            updatedAtISO8601: ISO8601DateFormatter().string(from: Date())
        )
        queue.sync {
            cache[id] = record
            persistLocked()
        }
    }

    func remove(skillID: String) {
        let id = skillID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        queue.sync {
            cache.removeValue(forKey: id)
            persistLocked()
        }
    }

    private func load() {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let records = try? JSONDecoder().decode([SkillCapabilityLinkRecord].self, from: data) else {
                cache = [:]
                return
            }
            cache = Dictionary(uniqueKeysWithValues: records.map { ($0.skillID, $0) })
        }
    }

    private func persistLocked() {
        let records = Array(cache.values).sorted { $0.skillID < $1.skillID }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private struct CapabilityManifestFile: Codable {
    var id: String
    var name: String?
    var tools: [String]?
    var permissions: [String]?
}

final class CapabilityCatalog {
    static let shared = CapabilityCatalog()

    private let metadataStore: CapabilityMetadataStore
    private let toolPackageStore: ToolPackageStore

    init(metadataStore: CapabilityMetadataStore = .shared,
         toolPackageStore: ToolPackageStore = .shared) {
        self.metadataStore = metadataStore
        self.toolPackageStore = toolPackageStore
    }

    func allCapabilities() -> [CapabilityDescriptor] {
        var byID: [String: CapabilityDescriptor] = [:]

        func upsert(_ candidate: CapabilityDescriptor) {
            if let existing = byID[candidate.id] {
                let mergedTools = Array(Set(existing.tools + candidate.tools)).sorted()
                let mergedPermissions = Array(Set(existing.permissions + candidate.permissions)).sorted()
                let mergedKeywords = Array(Set(existing.keywords + candidate.keywords)).sorted()
                let mergedName = existing.name.count >= candidate.name.count ? existing.name : candidate.name
                let mergedPath = existing.manifestPath ?? candidate.manifestPath
                byID[candidate.id] = CapabilityDescriptor(
                    id: candidate.id,
                    name: mergedName,
                    tools: mergedTools,
                    permissions: mergedPermissions,
                    keywords: mergedKeywords,
                    source: existing.source,
                    manifestPath: mergedPath
                )
                return
            }
            byID[candidate.id] = candidate
        }

        for manifest in readManifestCapabilities() {
            upsert(manifest)
        }

        for installed in toolPackageStore.listInstalled() {
            let keywords = Array(Set(tokenize(installed.id) + installed.tools))
            upsert(
                CapabilityDescriptor(
                    id: installed.id,
                    name: installed.id,
                    tools: installed.tools.sorted(),
                    permissions: installed.permissions.sorted(),
                    keywords: keywords.sorted(),
                    source: "installed",
                    manifestPath: nil
                )
            )
        }

        for tool in ToolRegistry.shared.allTools {
            guard let capabilityID = ToolPermissionCatalog.packageID(for: tool.name) else { continue }
            let permissions = ToolPermissionCatalog.requiredPermissions(for: tool.name)
            let keywords = Array(Set(tokenize(capabilityID) + tokenize(tool.name)))
            upsert(
                CapabilityDescriptor(
                    id: capabilityID,
                    name: capabilityID,
                    tools: [tool.name],
                    permissions: permissions,
                    keywords: keywords.sorted(),
                    source: "registry",
                    manifestPath: nil
                )
            )
        }

        let overrides = metadataStore.allOverrides()
        for (capabilityID, override) in overrides {
            guard var existing = byID[capabilityID] else {
                let name = override.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                let tools = override.tools ?? []
                let permissions = override.permissions ?? []
                let keywords = Array(Set((override.keywords + tools + permissions + [capabilityID]).flatMap(tokenize))).sorted()
                byID[capabilityID] = CapabilityDescriptor(
                    id: capabilityID,
                    name: name?.isEmpty == false ? name! : capabilityID,
                    tools: tools.sorted(),
                    permissions: permissions.sorted(),
                    keywords: keywords,
                    source: "override",
                    manifestPath: nil
                )
                continue
            }

            if let name = override.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                existing.name = name
            }
            if let tools = override.tools {
                existing.tools = tools.sorted()
            }
            if let permissions = override.permissions {
                existing.permissions = permissions.sorted()
            }
            let overrideKeywords = override.keywords.flatMap(tokenize)
            existing.keywords = Array(Set(existing.keywords + overrideKeywords)).sorted()
            byID[capabilityID] = existing
        }

        return dedupeByCapabilityPayload(Array(byID.values)).sorted { lhs, rhs in
            if lhs.name == rhs.name { return lhs.id < rhs.id }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func definition(for capabilityID: String) -> CapabilityDescriptor? {
        let trimmed = capabilityID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return allCapabilities().first { $0.id == trimmed }
    }

    func capabilityID(forTool toolName: String) -> String? {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = ToolPermissionCatalog.packageID(for: trimmed) {
            return direct
        }
        for capability in allCapabilities() where capability.tools.contains(trimmed) {
            return capability.id
        }
        return nil
    }

    func suggestedCapabilities(for text: String, limit: Int = 4) -> [CapabilityDescriptor] {
        search(text, limit: max(1, limit))
    }

    func search(_ query: String, limit: Int = 40) -> [CapabilityDescriptor] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let scored: [(CapabilityDescriptor, Double)] = allCapabilities().compactMap { capability in
            let haystack = [
                capability.id,
                capability.name,
                capability.tools.joined(separator: " "),
                capability.permissions.joined(separator: " "),
                capability.keywords.joined(separator: " ")
            ].joined(separator: " ")
            let score = searchScore(query: trimmed, haystack: haystack)
            guard score > 0 else { return nil }
            return (capability, score)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.id < rhs.0.id
                }
                return lhs.1 > rhs.1
            }
            .prefix(max(1, limit))
            .map(\.0)
    }

    private func readManifestCapabilities() -> [CapabilityDescriptor] {
        var results: [CapabilityDescriptor] = []
        for directory in manifestDirectories() {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                continue
            }

            for entry in entries where entry.hasDirectoryPath {
                let manifestFile = entry.appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifestFile),
                      let manifest = try? JSONDecoder().decode(CapabilityManifestFile.self, from: data) else {
                    continue
                }
                let id = manifest.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { continue }

                let tools = (manifest.tools ?? []).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                let permissions = (manifest.permissions ?? []).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                let name = manifest.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                let keywords = Array(Set(tokenize(id) + tokenize(name ?? id) + tools.flatMap(tokenize) + permissions.flatMap(tokenize))).sorted()

                results.append(
                    CapabilityDescriptor(
                        id: id,
                        name: name?.isEmpty == false ? name! : id,
                        tools: tools.sorted(),
                        permissions: permissions.sorted(),
                        keywords: keywords,
                        source: "manifest",
                        manifestPath: manifestFile.path
                    )
                )
            }
        }
        return results
    }

    private func manifestDirectories() -> [URL] {
        var directories: [URL] = []
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        directories.append(cwd.appendingPathComponent("Capabilities", isDirectory: true))
        if let bundleCapabilities = Bundle.main.resourceURL?.appendingPathComponent("Capabilities", isDirectory: true) {
            directories.append(bundleCapabilities)
        }
        return Array(Set(directories))
    }

    private func dedupeByCapabilityPayload(_ capabilities: [CapabilityDescriptor]) -> [CapabilityDescriptor] {
        var seenSignatures: [String: CapabilityDescriptor] = [:]
        for capability in capabilities.sorted(by: { $0.id < $1.id }) {
            let signature = [
                capability.tools.sorted().joined(separator: ","),
                capability.permissions.sorted().joined(separator: ",")
            ].joined(separator: "|")
            if signature == "|" {
                seenSignatures["id:\(capability.id)"] = capability
                continue
            }
            if seenSignatures[signature] == nil {
                seenSignatures[signature] = capability
            }
        }
        return Array(seenSignatures.values)
    }

    private func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func searchScore(query: String, haystack: String) -> Double {
        let normalizedQuery = query.lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return 0 }

        let normalizedHaystack = haystack.lowercased()
        let tokens = Set(normalizedQuery.split(separator: " ").map(String.init))
        guard !tokens.isEmpty else { return 0 }

        var score = 0.0
        if normalizedHaystack.contains(normalizedQuery) {
            score += 3.0
        }
        for token in tokens where normalizedHaystack.contains(token) {
            score += 1.0
        }
        return score
    }
}
