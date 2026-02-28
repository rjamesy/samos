import Foundation

/// Character budget allocation and tracking for prompt blocks.
struct TokenBudget: Sendable {
    let totalBudget: Int
    private(set) var usedBudget: Int = 0

    var remaining: Int { totalBudget - usedBudget }

    init(totalBudget: Int = AppConfig.totalPromptBudget) {
        self.totalBudget = totalBudget
    }

    /// Returns the text trimmed to fit within the given budget allocation.
    func allocate(_ text: String, budget: Int) -> String {
        guard text.count > budget else { return text }
        return String(text.prefix(budget))
    }

    /// Track usage of a block.
    mutating func use(_ count: Int) {
        usedBudget += count
    }
}
