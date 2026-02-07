import Foundation

/// File-system-based skill persistence.
/// Skills are stored as individual JSON documents in ~/Library/Application Support/SamOS/Skills/<id>/skill.json.
final class SkillStore {

    static let shared = SkillStore()

    private let fileManager = FileManager.default
    private let skillsDir: URL

    /// In-memory cache, keyed by skill ID.
    private var cache: [String: SkillSpec] = [:]

    /// Hard cap on installed skills to prevent prompt bloat.
    static let maxInstalledSkills = 50

    private init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        skillsDir = appSupport.appendingPathComponent("SamOS/Skills")

        // Ensure directory exists
        if !fileManager.fileExists(atPath: skillsDir.path) {
            try? fileManager.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        }

        // Populate cache
        cache = loadAllFromDisk()

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
        let needsInstall = cache["alarm_v1"] == nil || cache["alarm_v1"]?.approvedAt == nil
        if needsInstall {
            if let url = Bundle.main.url(forResource: "alarm_v1", withExtension: "json"),
               let data = try? Data(contentsOf: url),
               var skill = try? JSONDecoder().decode(SkillSpec.self, from: data) {
                skill.status = "active"
                skill.approvedAt = Date()
                install(skill)
                print("[SkillStore] Installed bundled skill: \(skill.name)")
            }
        }
    }

    /// Number of installed skills.
    var count: Int { cache.count }

    // MARK: - Private

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
}
