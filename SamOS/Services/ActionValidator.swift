import Foundation

/// Structural correctness validation for LLM-produced Actions.
/// Does NOT perform intent routing — the LLM drives all tool choices.
/// Validates structure (tool exists, required args present) and prevents
/// false confirmation claims (TALK saying "here's a recipe" without a tool).
enum ActionValidator {

    /// Reasons why an action failed validation.
    struct ValidationFailure {
        let reasons: [String]
    }

    /// Validates an Action for structural correctness.
    /// Returns nil if valid, or a ValidationFailure with reasons.
    /// TALK is always accepted — the LLM is a conversational assistant first.
    static func validate(_ action: Action) -> ValidationFailure? {
        switch action {
        case .talk:
            return nil

        case .tool(let toolAction):
            return validateToolStructure(toolAction)

        case .delegateOpenAI, .capabilityGap:
            return nil
        }
    }

    // MARK: - Structural Tool Validation

    /// Validates tool name exists and required args are present/correct.
    /// Returns nil if valid, or a ValidationFailure with reasons.
    static func validateToolStructure(_ toolAction: ToolAction) -> ValidationFailure? {
        var reasons: [String] = []

        switch toolAction.name {
        case "show_image":
            // Accept either 'urls' (pipe-separated) or 'url' (single)
            let urlsList = toolAction.args["urls"] ?? ""
            let singleUrl = toolAction.args["url"] ?? ""
            var candidates: [String] = []
            if !urlsList.isEmpty {
                candidates += urlsList.components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            if !singleUrl.isEmpty && !candidates.contains(singleUrl) {
                candidates.append(singleUrl)
            }
            if candidates.isEmpty {
                reasons.append("show_image requires a 'urls' or 'url' argument.")
            } else if !candidates.contains(where: { isValidAbsoluteURL($0) }) {
                reasons.append("show_image requires at least one valid http/https URL.")
            }

        case "show_text":
            let markdown = toolAction.args["markdown"] ?? ""
            if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reasons.append("show_text requires non-empty 'markdown' argument.")
            }

        case "schedule_task":
            let runAt = toolAction.args["run_at"] ?? toolAction.args["datetime_iso"] ?? ""
            let inSeconds = toolAction.args["in_seconds"] ?? ""
            if runAt.isEmpty && inSeconds.isEmpty {
                reasons.append("schedule_task requires 'run_at' or 'in_seconds' argument.")
            }

        case "cancel_task":
            // cancel_task without id is allowed — the tool itself lists pending tasks
            break

        case "save_memory":
            let content = toolAction.args["content"] ?? ""
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reasons.append("save_memory requires non-empty 'content' argument.")
            }

        case "get_weather":
            let place = toolAction.args["place"] ?? ""
            if place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reasons.append("get_weather requires non-empty 'place' argument.")
            }

        case "enroll_camera_face":
            let name = toolAction.args["name"] ?? ""
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reasons.append("enroll_camera_face requires non-empty 'name' argument.")
            }

        case "learn_website":
            let url = toolAction.args["url"] ?? ""
            if url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reasons.append("learn_website requires non-empty 'url' argument.")
            } else if !isValidAbsoluteURL(url) {
                reasons.append("learn_website requires a valid http/https URL.")
            }

        case "autonomous_learn":
            if let minutesRaw = toolAction.args["minutes"], !minutesRaw.isEmpty {
                guard let minutes = Int(minutesRaw), minutes >= 1 else {
                    reasons.append("autonomous_learn optional 'minutes' must be an integer greater than or equal to 1.")
                    break
                }
                _ = minutes
            }

        case "skills.learn.start":
            let goal = (toolAction.args["goal_text"] ?? toolAction.args["goal"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if goal.isEmpty {
                reasons.append("skills.learn.start requires non-empty 'goal_text' (or 'goal').")
            }

        case "skills.learn.approve_permissions":
            let approvedRaw = (toolAction.args["approved"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let accepted = ["true", "false", "1", "0", "yes", "no", "y", "n"]
            if !accepted.contains(approvedRaw) {
                reasons.append("skills.learn.approve_permissions requires 'approved' true/false.")
            }

        default:
            break
        }

        return reasons.isEmpty ? nil : ValidationFailure(reasons: reasons)
    }

    // MARK: - Plan Validation

    /// Validates a Plan for structural correctness.
    /// Returns nil if valid, or a ValidationFailure with reasons.
    static func validatePlan(_ plan: Plan) -> ValidationFailure? {
        return validatePlan(plan, userInput: nil)
    }

    /// Validates a Plan for structural correctness.
    /// Only checks tool args — TALK steps are always accepted.
    static func validatePlan(_ plan: Plan, userInput: String?) -> ValidationFailure? {
        var allReasons: [String] = []
        for step in plan.steps {
            if let failure = validatePlanStep(step) {
                allReasons.append(contentsOf: failure.reasons)
            }
        }
        return allReasons.isEmpty ? nil : ValidationFailure(reasons: allReasons)
    }

    /// Validates a single PlanStep for structural correctness.
    /// TALK steps are always accepted. Tool steps check required args.
    static func validatePlanStep(_ step: PlanStep) -> ValidationFailure? {
        switch step {
        case .talk:
            return nil

        case .tool(let name, let args, _):
            let stringArgs = args.mapValues { $0.stringValue }
            let toolAction = ToolAction(name: name, args: stringArgs)
            return validateToolStructure(toolAction)

        case .ask, .delegate:
            return nil
        }
    }

    // MARK: - Truth Guardrail

    /// Detects TALK responses that contain a time claim (e.g. "It's 9:06 PM.").
    /// Time answers MUST come from get_time tool output, not from TALK.
    static func containsTimeClaim(_ text: String) -> Bool {
        let lower = text.lowercased()
        // Pattern: digit(s):digit(s) followed by am/pm (with optional space/period)
        // Matches: "9:06 pm", "12:30 AM", "9:06pm"
        let timePattern = #"\b\d{1,2}:\d{2}\s*[ap]\.?m\.?"#
        if let regex = try? NSRegularExpression(pattern: timePattern, options: .caseInsensitive) {
            let range = NSRange(lower.startIndex..., in: lower)
            if regex.firstMatch(in: lower, range: range) != nil {
                return true
            }
        }
        return false
    }

    /// Detects TALK responses that falsely claim to show canvas content.
    /// This is NOT intent routing — it prevents the LLM from claiming
    /// it showed a recipe/image when no tool was actually used.
    static func containsFalseCanvasConfirmation(_ text: String) -> Bool {
        let lower = text.lowercased()
        let claims = [
            "here's a recipe", "here is a recipe", "here's the recipe",
            "here's a picture", "here is a picture", "here's an image", "here is an image",
            "i found a recipe", "i found an image", "i found a picture",
            "i'll show you", "let me show you",
            "here are the instructions", "here's how to", "here is how to"
        ]
        return claims.contains { lower.contains($0) }
    }

    // MARK: - Time Query Detection

    /// Detects user input that is clearly a time/date question.
    /// Patterns: "what time", "what's the time", "current time", "time in <place>",
    /// "what date", "what day", "what's the date".
    static func isTimeQuery(_ text: String) -> Bool {
        let lower = text.lowercased()
        let patterns: [String] = [
            #"\bwhat(?:'s| is)? the time\b"#,
            #"\bwhat time\b"#,
            #"\bcurrent time\b"#,
            #"\btime in \b"#,
            #"\btime is it\b"#,
            #"\bwhat(?:'s| is)? the date\b"#,
            #"\bwhat date\b"#,
            #"\bwhat day\b"#,
            #"\bcurrent date\b"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - URL Validation

    /// Validates that a URL string is a valid absolute http/https URL.
    private static func isValidAbsoluteURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil
        else { return false }
        return true
    }

}
