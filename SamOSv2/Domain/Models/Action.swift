import Foundation

// MARK: - Action Envelope

/// The top-level action envelope returned by the router.
/// Exactly one variant is populated per response.
enum Action: Decodable, Sendable {
    case talk(Talk)
    case tool(ToolAction)
    case delegateOpenAI(DelegateOpenAI)
    case capabilityGap(CapabilityGap)

    private enum CodingKeys: String, CodingKey {
        case action
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawAction = try container.decode(String.self, forKey: .action)
        let actionType = rawAction.uppercased()

        switch actionType {
        case "TALK":
            self = .talk(try Talk(from: decoder))
        case "TOOL":
            self = .tool(try ToolAction(from: decoder))
        case "DELEGATE_OPENAI", "DELEGATE":
            self = .delegateOpenAI(try DelegateOpenAI(from: decoder))
        case "CAPABILITY_GAP":
            self = .capabilityGap(try CapabilityGap(from: decoder))
        default:
            // LLM sometimes returns the tool name directly as the action value
            // e.g. {"action":"save_memory","args":{...},"say":"..."}
            // Treat as a tool call where action = tool name
            self = .tool(try ToolAction(name: rawAction, from: decoder))
        }
    }
}

// MARK: - Action Payloads

struct Talk: Decodable, Sendable {
    let say: String

    private enum CodingKeys: String, CodingKey {
        case action, say
    }

    init(say: String) {
        self.say = say
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.say = try container.decode(String.self, forKey: .say)
    }
}

struct ToolAction: Decodable, Sendable {
    let name: String
    let args: [String: String]
    let say: String?

    private enum CodingKeys: String, CodingKey {
        case action, name, args, say
    }

    init(name: String, args: [String: String], say: String? = nil) {
        self.name = name
        self.args = args
        self.say = say
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        if let stringArgs = try? container.decode([String: String].self, forKey: .args) {
            self.args = stringArgs
        } else {
            let rawArgs = try container.decode([String: CodableValue].self, forKey: .args)
            self.args = rawArgs.mapValues { $0.stringValue }
        }
        self.say = try container.decodeIfPresent(String.self, forKey: .say)
    }

    /// Decode when the action field IS the tool name (no separate "name" key).
    init(name toolName: String, from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = (try? container.decode(String.self, forKey: .name)) ?? toolName
        if let stringArgs = try? container.decode([String: String].self, forKey: .args) {
            self.args = stringArgs
        } else if let rawArgs = try? container.decode([String: CodableValue].self, forKey: .args) {
            self.args = rawArgs.mapValues { $0.stringValue }
        } else {
            self.args = [:]
        }
        self.say = try container.decodeIfPresent(String.self, forKey: .say)
    }
}

struct DelegateOpenAI: Decodable, Sendable {
    let task: String
    let context: String?
    let say: String?

    private enum CodingKeys: String, CodingKey {
        case action, task, context, say
    }

    init(task: String, context: String? = nil, say: String? = nil) {
        self.task = task
        self.context = context
        self.say = say
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.task = try container.decode(String.self, forKey: .task)
        self.context = try container.decodeIfPresent(String.self, forKey: .context)
        self.say = try container.decodeIfPresent(String.self, forKey: .say)
    }
}

struct CapabilityGap: Decodable, Sendable {
    let goal: String
    let missing: String
    let proposedCapabilityId: String?
    let say: String?

    private enum CodingKeys: String, CodingKey {
        case action, goal, missing
        case proposedCapabilityId = "proposed_capability_id"
        case say
    }

    init(goal: String, missing: String, proposedCapabilityId: String? = nil, say: String? = nil) {
        self.goal = goal
        self.missing = missing
        self.proposedCapabilityId = proposedCapabilityId
        self.say = say
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.goal = try container.decode(String.self, forKey: .goal)
        self.missing = try container.decode(String.self, forKey: .missing)
        self.proposedCapabilityId = try container.decodeIfPresent(String.self, forKey: .proposedCapabilityId)
        self.say = try container.decodeIfPresent(String.self, forKey: .say)
    }
}
