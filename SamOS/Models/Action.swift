import Foundation

// MARK: - Action Envelope

/// The top-level action envelope returned by the router.
/// Exactly one variant is populated per response.
enum Action: Decodable {
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
            throw DecodingError.dataCorruptedError(
                forKey: .action,
                in: container,
                debugDescription: "Unknown action type: \(rawAction)"
            )
        }
    }
}

// MARK: - Action Payloads

struct Talk: Decodable {
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

struct ToolAction: Decodable {
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
        // LLMs sometimes return non-string values (numbers, bools) in args.
        // Coerce everything to String for downstream compatibility.
        if let stringArgs = try? container.decode([String: String].self, forKey: .args) {
            self.args = stringArgs
        } else {
            let rawArgs = try container.decode([String: JSONValue].self, forKey: .args)
            self.args = rawArgs.mapValues { $0.stringValue }
        }
        self.say = try container.decodeIfPresent(String.self, forKey: .say)
    }
}

/// Helper to decode arbitrary JSON values and coerce to String.
private enum JSONValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .string(s) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if container.decodeNil() { self = .null }
        else { self = .string("") }
    }

    var stringValue: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return ""
        }
    }
}

struct DelegateOpenAI: Decodable {
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

struct CapabilityGap: Decodable {
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
