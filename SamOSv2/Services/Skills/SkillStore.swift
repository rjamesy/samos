import Foundation

/// SQLite-backed skill persistence.
actor SkillStore: SkillStoreProtocol {
    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    func loadInstalled() async -> [SkillSpec] {
        let rows = await database.query(
            "SELECT * FROM skills WHERE approved_by_gpt = 1 AND approved_by_user = 1 ORDER BY created_at DESC"
        )
        return rows.compactMap(parseSkillRow)
    }

    func getSkill(id: String) async -> SkillSpec? {
        let rows = await database.query("SELECT * FROM skills WHERE id = ?", bindings: [id])
        return rows.first.flatMap(parseSkillRow)
    }

    func install(_ skill: SkillSpec) async throws {
        let triggerJSON = try JSONEncoder().encode(skill.triggerPhrases)
        let triggerStr = String(data: triggerJSON, encoding: .utf8) ?? "[]"
        let stepsJSON = try JSONEncoder().encode(skill.steps)
        let stepsStr = String(data: stepsJSON, encoding: .utf8) ?? "[]"
        let paramsJSON = skill.parameters.map { try? JSONEncoder().encode($0) }
            .flatMap { $0.flatMap { String(data: $0, encoding: .utf8) } }

        await database.run("""
            INSERT OR REPLACE INTO skills (id, name, trigger_phrases, parameters, steps, approved_by_gpt, approved_by_user, created_at, usage_count, last_used_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, bindings: [
            skill.id, skill.name, triggerStr, paramsJSON, stepsStr,
            skill.approvedByGPT ? 1 : 0, skill.approvedByUser ? 1 : 0,
            skill.createdAt.timeIntervalSince1970, skill.usageCount,
            skill.lastUsedAt?.timeIntervalSince1970
        ])
    }

    func remove(id: String) async throws {
        await database.run("DELETE FROM skills WHERE id = ?", bindings: [id])
    }

    func match(input: String) async -> SkillSpec? {
        let skills = await loadInstalled()
        let lower = input.lowercased()
        return skills.first { skill in
            skill.triggerPhrases.contains { trigger in
                lower.contains(trigger.lowercased())
            }
        }
    }

    func recordUsage(id: String) async {
        let now = Date().timeIntervalSince1970
        await database.run(
            "UPDATE skills SET usage_count = usage_count + 1, last_used_at = ? WHERE id = ?",
            bindings: [now, id]
        )
    }

    private func parseSkillRow(_ row: [String: Any]) -> SkillSpec? {
        guard let id = row["id"] as? String,
              let name = row["name"] as? String,
              let triggerStr = row["trigger_phrases"] as? String,
              let stepsStr = row["steps"] as? String else { return nil }

        let triggers = (try? JSONDecoder().decode([String].self, from: Data(triggerStr.utf8))) ?? []
        let steps = (try? JSONDecoder().decode([SkillStep].self, from: Data(stepsStr.utf8))) ?? []
        let params: [SkillParameter]?
        if let paramsStr = row["parameters"] as? String {
            params = try? JSONDecoder().decode([SkillParameter].self, from: Data(paramsStr.utf8))
        } else {
            params = nil
        }

        return SkillSpec(
            id: id,
            name: name,
            triggerPhrases: triggers,
            parameters: params,
            steps: steps,
            approvedByGPT: (row["approved_by_gpt"] as? Int) == 1,
            approvedByUser: (row["approved_by_user"] as? Int) == 1,
            createdAt: Date(timeIntervalSince1970: row["created_at"] as? Double ?? 0),
            usageCount: row["usage_count"] as? Int ?? 0,
            lastUsedAt: (row["last_used_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        )
    }
}
