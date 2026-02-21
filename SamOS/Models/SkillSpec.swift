import Foundation

// MARK: - Skill Specification

/// Codable definition of a learned skill. Stored as JSON documents in the Skills directory.
struct SkillSpec: Codable, Identifiable {
    let id: String              // e.g. "alarm_v1"
    let name: String            // e.g. "Alarm"
    let version: Int
    let triggerPhrases: [String]
    let slots: [SlotDef]
    let steps: [StepDef]
    let onTrigger: OnTriggerDef?

    var status: String?       // "active", "inactive", etc. nil = legacy/unreviewed
    var approvedAt: Date?     // When user approved this skill. nil = never approved
    var disabledAt: Date?     // When disabled. nil = not disabled

    struct SlotDef: Codable {
        let name: String
        let type: SlotType
        let required: Bool
        let prompt: String?

        private enum CodingKeys: String, CodingKey {
            case name, type, required, prompt
        }

        init(name: String, type: SlotType, required: Bool, prompt: String?) {
            self.name = name
            self.type = type
            self.required = required
            self.prompt = prompt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            type = try container.decode(SlotType.self, forKey: .type)
            // OpenAI often omits "required" for slot objects. Default to true.
            required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? true
            prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        }
    }

    enum SlotType: String, Codable {
        case date
        case string
        case number
    }

    struct StepDef: Codable {
        let action: String      // e.g. "schedule_task", "talk"
        let args: [String: String]  // supports {{slotName}} interpolation

        private enum CodingKeys: String, CodingKey {
            case action, args
        }

        init(action: String, args: [String: String]) {
            self.action = action
            self.args = args
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            action = try container.decode(String.self, forKey: .action)

            if let stringArgs = try? container.decode([String: String].self, forKey: .args) {
                args = stringArgs
            } else {
                let rawArgs = try container.decode([String: StepArgValue].self, forKey: .args)
                args = rawArgs.mapValues(\.stringValue)
            }
        }
    }

    struct OnTriggerDef: Codable {
        let say: String?
        let sound: String?      // macOS system sound name, e.g. "Funk"
        let showCard: Bool?
    }
}

private enum StepArgValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if container.decodeNil() {
            self = .null
        } else {
            self = .string("")
        }
    }

    var stringValue: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return ""
        }
    }
}

// MARK: - Phase 4 Skill Package Models

enum SkillPackageOrigin: String, Codable, Equatable {
    case baseline
    case forged
}

struct SkillManifest: Codable, Equatable {
    var skillID: String
    var name: String
    var version: Int
    var origin: SkillPackageOrigin
    var createdAtISO8601: String

    enum CodingKeys: String, CodingKey {
        case skillID = "skill_id"
        case name
        case version
        case origin
        case createdAtISO8601 = "created_at"
    }
}

struct SkillToolRequirement: Codable, Equatable {
    var name: String
    var permissions: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case permissions
    }

    private enum DecodingKeys: String, CodingKey {
        case name
        case permissions
        case tool
        case id
    }

    init(name: String, permissions: [String]) {
        self.name = name
        self.permissions = permissions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        let resolvedName = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .tool)
            ?? container.decodeIfPresent(String.self, forKey: .id)
            ?? "unknown_tool"
        self.name = resolvedName
        self.permissions = try container.decodeIfPresent([String].self, forKey: .permissions) ?? []
    }
}

struct SkillConversationPolicy: Codable, Equatable {
    var tone: String
    var safetyConstraints: [String]

    enum CodingKeys: String, CodingKey {
        case tone
        case safetyConstraints = "safety_constraints"
    }

    init(tone: String, safetyConstraints: [String]) {
        self.tone = tone
        self.safetyConstraints = safetyConstraints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tone = try container.decodeIfPresent(String.self, forKey: .tone) ?? "neutral"
        self.safetyConstraints = try container.decodeIfPresent([String].self, forKey: .safetyConstraints) ?? []
    }
}

enum SkillJSONScalarType: String, Codable, Equatable {
    case object
    case array
    case string
    case number
    case integer
    case boolean
    case null
}

final class SkillJSONSchemaProperty: Codable, Equatable {
    var type: SkillJSONScalarType
    var required: [String]
    var properties: [String: SkillJSONSchemaProperty]
    var items: SkillJSONSchemaProperty?
    var enumValues: [String]?
    var additionalProperties: Bool

    enum CodingKeys: String, CodingKey {
        case type
        case required
        case properties
        case items
        case enumValues = "enum"
        case additionalProperties = "additionalProperties"
    }

    init(type: SkillJSONScalarType,
         required: [String] = [],
         properties: [String: SkillJSONSchemaProperty] = [:],
         items: SkillJSONSchemaProperty? = nil,
         enumValues: [String]? = nil,
         additionalProperties: Bool = false) {
        self.type = type
        self.required = required
        self.properties = properties
        self.items = items
        self.enumValues = enumValues
        self.additionalProperties = additionalProperties
    }

    required convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(SkillJSONScalarType.self, forKey: .type) ?? .object
        let required = try container.decodeIfPresent([String].self, forKey: .required) ?? []
        let properties = try container.decodeIfPresent([String: SkillJSONSchemaProperty].self, forKey: .properties) ?? [:]
        let items = try container.decodeIfPresent(SkillJSONSchemaProperty.self, forKey: .items)
        let enumValues = try container.decodeIfPresent([String].self, forKey: .enumValues)
        let additionalProperties = try container.decodeIfPresent(Bool.self, forKey: .additionalProperties) ?? false
        self.init(
            type: type,
            required: required,
            properties: properties,
            items: items,
            enumValues: enumValues,
            additionalProperties: additionalProperties
        )
    }

    static func == (lhs: SkillJSONSchemaProperty, rhs: SkillJSONSchemaProperty) -> Bool {
        lhs.type == rhs.type &&
            lhs.required == rhs.required &&
            lhs.properties == rhs.properties &&
            lhs.items == rhs.items &&
            lhs.enumValues == rhs.enumValues &&
            lhs.additionalProperties == rhs.additionalProperties
    }
}

typealias SkillJSONSchema = SkillJSONSchemaProperty

struct SkillTestCase: Codable, Equatable {
    var name: String
    var inputText: String
    var expected: [String: SkillJSONValue]
    var mustCallTools: [String]
    var mustNotCallTools: [String]
    var maxSteps: Int?
    var shouldFail: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case inputText = "input_text"
        case expected
        case mustCallTools = "must_call_tools"
        case mustNotCallTools = "must_not_call_tools"
        case maxSteps = "max_steps"
        case shouldFail = "should_fail"
    }

    private enum DecodingKeys: String, CodingKey {
        case name
        case inputText = "input_text"
        case input
        case expected
        case mustCallTools = "must_call_tools"
        case mustNotCallTools = "must_not_call_tools"
        case maxSteps = "max_steps"
        case shouldFail = "should_fail"
    }

    init(name: String,
         inputText: String,
         expected: [String: SkillJSONValue] = [:],
         mustCallTools: [String] = [],
         mustNotCallTools: [String] = [],
         maxSteps: Int? = nil,
         shouldFail: Bool = false) {
        self.name = name
        self.inputText = inputText
        self.expected = expected
        self.mustCallTools = mustCallTools
        self.mustNotCallTools = mustNotCallTools
        self.maxSteps = maxSteps
        self.shouldFail = shouldFail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "case"
        self.inputText = try container.decodeIfPresent(String.self, forKey: .inputText)
            ?? container.decodeIfPresent(String.self, forKey: .input)
            ?? ""
        self.expected = try container.decodeIfPresent([String: SkillJSONValue].self, forKey: .expected) ?? [:]
        self.mustCallTools = try container.decodeIfPresent([String].self, forKey: .mustCallTools) ?? []
        self.mustNotCallTools = try container.decodeIfPresent([String].self, forKey: .mustNotCallTools) ?? []
        self.maxSteps = try container.decodeIfPresent(Int.self, forKey: .maxSteps)
        self.shouldFail = try container.decodeIfPresent(Bool.self, forKey: .shouldFail) ?? false
    }
}

struct SkillPlan: Codable, Equatable {
    var skillID: String
    var name: String
    var version: Int
    var intentPatterns: [String]
    var inputsSchema: SkillJSONSchema
    var outputsSchema: SkillJSONSchema
    var toolRequirements: [SkillToolRequirement]
    var conversationPolicy: SkillConversationPolicy
    var testCases: [SkillTestCase]

    init(skillID: String,
         name: String,
         version: Int,
         intentPatterns: [String],
         inputsSchema: SkillJSONSchema,
         outputsSchema: SkillJSONSchema,
         toolRequirements: [SkillToolRequirement],
         conversationPolicy: SkillConversationPolicy,
         testCases: [SkillTestCase]) {
        self.skillID = skillID
        self.name = name
        self.version = version
        self.intentPatterns = intentPatterns
        self.inputsSchema = inputsSchema
        self.outputsSchema = outputsSchema
        self.toolRequirements = toolRequirements
        self.conversationPolicy = conversationPolicy
        self.testCases = testCases
    }

    enum CodingKeys: String, CodingKey {
        case skillID = "skill_id"
        case name
        case version
        case intentPatterns = "intent_patterns"
        case inputsSchema = "inputs_schema"
        case outputsSchema = "outputs_schema"
        case toolRequirements = "tool_requirements"
        case conversationPolicy = "conversation_policy"
        case testCases = "test_cases"
    }

    private enum DecodingKeys: String, CodingKey {
        case skillID = "skill_id"
        case id
        case name
        case title
        case version
        case intentPatterns = "intent_patterns"
        case triggerPhrases = "trigger_phrases"
        case inputsSchema = "inputs_schema"
        case inputSchema = "input_schema"
        case outputsSchema = "outputs_schema"
        case outputSchema = "output_schema"
        case toolRequirements = "tool_requirements"
        case tools
        case conversationPolicy = "conversation_policy"
        case testCases = "test_cases"
        case tests
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        let rawName = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .title)
            ?? "Skill"
        let rawID = try container.decodeIfPresent(String.self, forKey: .skillID)
            ?? container.decodeIfPresent(String.self, forKey: .id)
            ?? rawName
        self.skillID = SkillPlan.normalizedSkillID(rawID)
        self.name = rawName
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.intentPatterns = try container.decodeIfPresent([String].self, forKey: .intentPatterns)
            ?? container.decodeIfPresent([String].self, forKey: .triggerPhrases)
            ?? []
        self.inputsSchema = try container.decodeIfPresent(SkillJSONSchema.self, forKey: .inputsSchema)
            ?? container.decodeIfPresent(SkillJSONSchema.self, forKey: .inputSchema)
            ?? SkillPlan.defaultInputSchema()
        self.outputsSchema = try container.decodeIfPresent(SkillJSONSchema.self, forKey: .outputsSchema)
            ?? container.decodeIfPresent(SkillJSONSchema.self, forKey: .outputSchema)
            ?? SkillPlan.defaultOutputSchema()
        if let toolRequirements = try container.decodeIfPresent([SkillToolRequirement].self, forKey: .toolRequirements) {
            self.toolRequirements = toolRequirements
        } else if let toolRequirements = try container.decodeIfPresent([SkillToolRequirement].self, forKey: .tools) {
            self.toolRequirements = toolRequirements
        } else if let toolNames = try container.decodeIfPresent([String].self, forKey: .tools) {
            self.toolRequirements = toolNames.map { SkillToolRequirement(name: $0, permissions: []) }
        } else {
            self.toolRequirements = []
        }
        self.conversationPolicy = try container.decodeIfPresent(SkillConversationPolicy.self, forKey: .conversationPolicy)
            ?? SkillConversationPolicy(tone: "neutral", safetyConstraints: [])
        self.testCases = try container.decodeIfPresent([SkillTestCase].self, forKey: .testCases)
            ?? container.decodeIfPresent([SkillTestCase].self, forKey: .tests)
            ?? []
    }

    private static func defaultInputSchema() -> SkillJSONSchema {
        SkillJSONSchema(
            type: .object,
            required: ["text"],
            properties: [
                "text": SkillJSONSchema(type: .string)
            ],
            additionalProperties: false
        )
    }

    private static func defaultOutputSchema() -> SkillJSONSchema {
        SkillJSONSchema(
            type: .object,
            required: ["text"],
            properties: [
                "text": SkillJSONSchema(type: .string)
            ],
            additionalProperties: false
        )
    }

    private static func normalizedSkillID(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let pieces = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let joined = pieces.filter { !$0.isEmpty }.joined(separator: "_")
        return joined.isEmpty ? "skill_generated" : joined
    }
}

enum SkillStepType: String, Codable, Equatable {
    case extract
    case format
    case toolCall = "tool_call"
    case llmCall = "llm_call"
    case branch
    case `return`
}

struct SkillExtractStep: Codable, Equatable {
    var source: String
    var pattern: String
    var outputVar: String

    enum CodingKeys: String, CodingKey {
        case source
        case pattern
        case outputVar = "output_var"
    }
}

struct SkillFormatStep: Codable, Equatable {
    var template: String?
    var inputVar: String?
    var mode: String?
    var outputVar: String

    enum CodingKeys: String, CodingKey {
        case template
        case inputVar = "input_var"
        case mode
        case outputVar = "output_var"
    }
}

struct SkillToolCallStep: Codable, Equatable {
    var name: String
    var args: [String: String]
    var outputVar: String?

    enum CodingKeys: String, CodingKey {
        case name
        case args
        case outputVar = "output_var"
    }
}

struct SkillLLMCallStep: Codable, Equatable {
    var promptTemplate: String
    var responseVar: String
    var temperature: Double
    var maxOutputTokens: Int
    var jsonOnly: Bool

    enum CodingKeys: String, CodingKey {
        case promptTemplate = "prompt_template"
        case responseVar = "response_var"
        case temperature
        case maxOutputTokens = "max_output_tokens"
        case jsonOnly = "json_only"
    }
}

struct SkillBranchStep: Codable, Equatable {
    var variable: String
    var equals: String?
    var exists: Bool?
    var thenIndex: Int
    var elseIndex: Int?

    enum CodingKeys: String, CodingKey {
        case variable
        case equals
        case exists
        case thenIndex = "then_index"
        case elseIndex = "else_index"
    }
}

struct SkillReturnStep: Codable, Equatable {
    var output: [String: String]
}

struct SkillPackageStep: Codable, Equatable {
    var id: String
    var type: SkillStepType
    var extract: SkillExtractStep?
    var format: SkillFormatStep?
    var toolCall: SkillToolCallStep?
    var llmCall: SkillLLMCallStep?
    var branch: SkillBranchStep?
    var returnStep: SkillReturnStep?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case extract
        case format
        case toolCall = "tool_call"
        case llmCall = "llm_call"
        case branch
        case returnStep = "return"
    }
}

struct SkillFailureMode: Codable, Equatable {
    var code: String
    var message: String
    var action: String
}

struct SkillLimits: Codable, Equatable {
    var maxOutputChars: Int
    var maxOutputTokens: Int
    var timeoutMs: Int

    enum CodingKeys: String, CodingKey {
        case maxOutputChars = "max_output_chars"
        case maxOutputTokens = "max_output_tokens"
        case timeoutMs = "timeout_ms"
    }
}

struct SkillSpecV2: Codable, Equatable {
    var steps: [SkillPackageStep]
    var prompts: [String: String]
    var failureModes: [SkillFailureMode]
    var limits: SkillLimits

    enum CodingKeys: String, CodingKey {
        case steps
        case prompts
        case failureModes = "failure_modes"
        case limits
    }
}

struct SkillApproverResponse: Codable, Equatable {
    var approved: Bool
    var reason: String
    var requiredChanges: [String]
    var riskNotes: [String]
    var packageHash: String?

    enum CodingKeys: String, CodingKey {
        case approved
        case reason
        case requiredChanges = "required_changes"
        case riskNotes = "risk_notes"
        case packageHash = "package_hash"
    }
}

struct SkillSignoff: Codable, Equatable {
    var approved: Bool
    var reason: String
    var requiredChanges: [String]
    var riskNotes: [String]
    var packageHash: String
    var model: String
    var approvedAtISO8601: String

    enum CodingKeys: String, CodingKey {
        case approved
        case reason
        case requiredChanges = "required_changes"
        case riskNotes = "risk_notes"
        case packageHash = "package_hash"
        case model
        case approvedAtISO8601 = "approved_at"
    }
}

struct SkillPackage: Codable, Equatable {
    var manifest: SkillManifest
    var plan: SkillPlan
    var spec: SkillSpecV2
    var tests: [SkillTestCase]
    var signoff: SkillSignoff?
}

struct SkillValidationResult: Equatable {
    var errors: [String]
    var warnings: [String]

    var isValid: Bool { errors.isEmpty }
}

struct SkillInstallResult: Equatable {
    var installed: Bool
    var skillID: String
    var reason: String
}

struct SkillExecutionResult: Equatable {
    var success: Bool
    var output: [String: SkillJSONValue]
    var error: String?
    var toolCalls: [String]
    var stepsExecuted: Int
    var trace: [String]
}

struct SkillSimulationCaseResult: Equatable {
    var name: String
    var passed: Bool
    var failureReason: String?
    var execution: SkillExecutionResult
}

struct SkillSimulationReport: Equatable {
    var skillID: String
    var passed: Bool
    var cases: [SkillSimulationCaseResult]

    var passedCount: Int { cases.filter(\.passed).count }
}

enum SkillJSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: SkillJSONValue])
    case array([SkillJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: SkillJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([SkillJSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String {
        switch self {
        case .string(let value): return value
        case .number(let value):
            if floor(value) == value { return String(Int(value)) }
            return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .object(let value):
            if let data = try? JSONEncoder().encode(value),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return "{}"
        case .array(let value):
            if let data = try? JSONEncoder().encode(value),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return "[]"
        case .null:
            return ""
        }
    }

    static func fromAny(_ raw: Any) -> SkillJSONValue {
        switch raw {
        case let value as String:
            return .string(value)
        case let value as Int:
            return .number(Double(value))
        case let value as Double:
            return .number(value)
        case let value as Bool:
            return .bool(value)
        case let value as [String: Any]:
            let mapped = value.mapValues { SkillJSONValue.fromAny($0) }
            return .object(mapped)
        case let value as [Any]:
            return .array(value.map { SkillJSONValue.fromAny($0) })
        default:
            return .null
        }
    }
}
