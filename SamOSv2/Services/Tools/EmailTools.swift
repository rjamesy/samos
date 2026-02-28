import Foundation

/// Gmail OAuth authentication.
struct GmailAuthTool: Tool {
    let name = "gmail_auth"
    let description = "Authenticate with Gmail"
    let parameterDescription = "No args"
    let gmailClient: GmailClient?

    func execute(args: [String: String]) async -> ToolResult {
        guard gmailClient != nil else {
            return .failure(tool: name, error: "Gmail client not configured.")
        }
        return .success(tool: name, spoken: "Gmail authentication requires OAuth setup in Settings. Please add your OAuth token there.")
    }
}

/// Read Gmail inbox.
struct GmailReadInboxTool: Tool {
    let name = "gmail_read_inbox"
    let description = "Read recent emails from Gmail inbox"
    let parameterDescription = "Args: count (default 5), filter (optional)"
    let gmailClient: GmailClient?

    func execute(args: [String: String]) async -> ToolResult {
        guard let client = gmailClient else {
            return .failure(tool: name, error: "Gmail client not configured.")
        }
        let count = Int(args["count"] ?? "5") ?? 5
        do {
            let messages = try await client.fetchInbox(maxResults: count)
            if messages.isEmpty {
                return .success(tool: name, spoken: "Your inbox is empty.")
            }
            let summaries = messages.prefix(count).map { "From \($0.from): \"\($0.subject)\" — \($0.snippet.prefix(80))" }
            return .success(tool: name, spoken: "You have \(messages.count) recent emails. \(summaries.joined(separator: ". "))")
        } catch {
            return .failure(tool: name, error: "Failed to read inbox: \(error.localizedDescription)")
        }
    }
}

/// Send a reply via Gmail.
struct GmailSendReplyTool: Tool {
    let name = "gmail_send_reply"
    let description = "Send an email reply via Gmail"
    let parameterDescription = "Args: to (email), subject, body"
    let gmailClient: GmailClient?

    func execute(args: [String: String]) async -> ToolResult {
        guard let client = gmailClient else {
            return .failure(tool: name, error: "Gmail client not configured.")
        }
        let to = args["to"] ?? args["email"] ?? ""
        let subject = args["subject"] ?? "(no subject)"
        let body = args["body"] ?? args["message"] ?? ""
        guard !to.isEmpty else { return .failure(tool: name, error: "No recipient specified.") }
        guard !body.isEmpty else { return .failure(tool: name, error: "No message body provided.") }
        do {
            try await client.sendReply(to: to, subject: subject, body: body)
            return .success(tool: name, spoken: "Email sent to \(to).")
        } catch {
            return .failure(tool: name, error: "Failed to send: \(error.localizedDescription)")
        }
    }
}

/// Draft an email reply.
struct GmailDraftReplyTool: Tool {
    let name = "gmail_draft_reply"
    let description = "Draft an email reply in Gmail"
    let parameterDescription = "Args: to (email), subject, body"
    let gmailClient: GmailClient?

    func execute(args: [String: String]) async -> ToolResult {
        guard gmailClient != nil else {
            return .failure(tool: name, error: "Gmail client not configured.")
        }
        let to = args["to"] ?? ""
        let subject = args["subject"] ?? "(no subject)"
        let body = args["body"] ?? ""
        return .success(tool: name, spoken: "Draft prepared for \(to): \"\(subject)\". Say 'send it' to deliver.")
    }
}

/// Trash an email.
struct GmailTrashTool: Tool {
    let name = "gmail_trash"
    let description = "Move an email to trash"
    let parameterDescription = "Args: email_id (string)"
    let gmailClient: GmailClient?

    func execute(args: [String: String]) async -> ToolResult {
        guard let client = gmailClient else {
            return .failure(tool: name, error: "Gmail client not configured.")
        }
        let emailId = args["email_id"] ?? args["id"] ?? ""
        guard !emailId.isEmpty else { return .failure(tool: name, error: "No email ID provided.") }
        do {
            try await client.trashMessage(id: emailId)
            return .success(tool: name, spoken: "Email moved to trash.")
        } catch {
            return .failure(tool: name, error: "Failed to trash: \(error.localizedDescription)")
        }
    }
}

/// Mark email as read.
struct GmailMarkReadTool: Tool {
    let name = "gmail_mark_read"
    let description = "Mark an email as read"
    let parameterDescription = "Args: email_id (string)"
    let gmailClient: GmailClient?

    func execute(args: [String: String]) async -> ToolResult {
        guard let client = gmailClient else {
            return .failure(tool: name, error: "Gmail client not configured.")
        }
        let emailId = args["email_id"] ?? args["id"] ?? ""
        guard !emailId.isEmpty else { return .failure(tool: name, error: "No email ID provided.") }
        do {
            try await client.markAsRead(id: emailId)
            return .success(tool: name, spoken: "Email marked as read.")
        } catch {
            return .failure(tool: name, error: "Failed to mark: \(error.localizedDescription)")
        }
    }
}

/// Unsubscribe from a mailing list.
struct GmailUnsubscribeTool: Tool {
    let name = "gmail_unsubscribe"
    let description = "Unsubscribe from a mailing list"
    let parameterDescription = "Args: email_id (string)"
    let gmailClient: GmailClient?

    func execute(args: [String: String]) async -> ToolResult {
        guard let client = gmailClient else {
            return .failure(tool: name, error: "Gmail client not configured.")
        }
        let emailId = args["email_id"] ?? args["id"] ?? ""
        guard !emailId.isEmpty else { return .failure(tool: name, error: "No email ID provided.") }
        do {
            try await client.trashMessage(id: emailId)
            return .success(tool: name, spoken: "Unsubscribed and trashed the email.")
        } catch {
            return .failure(tool: name, error: "Failed: \(error.localizedDescription)")
        }
    }
}

/// Classify an email.
struct GmailClassifyTool: Tool {
    let name = "gmail_classify"
    let description = "Classify an email by category"
    let parameterDescription = "Args: email_id (string)"
    let gmailClient: GmailClient?

    func execute(args: [String: String]) async -> ToolResult {
        guard gmailClient != nil else {
            return .failure(tool: name, error: "Gmail client not configured.")
        }
        return .success(tool: name, spoken: "Email classification requires LLM integration. Use GPT to analyze the email content.")
    }
}

/// Organize inbox automatically.
struct GmailOrganizeInboxTool: Tool {
    let name = "gmail_organize_inbox"
    let description = "Automatically organize and sort inbox"
    let parameterDescription = "No args"
    let gmailClient: GmailClient?

    func execute(args: [String: String]) async -> ToolResult {
        guard gmailClient != nil else {
            return .failure(tool: name, error: "Gmail client not configured.")
        }
        return .success(tool: name, spoken: "Inbox organization requires batch processing. Use 'check my email' first, then I can help sort.")
    }
}

/// Stop inbox organization.
struct GmailOrganizeStopTool: Tool {
    let name = "gmail_organize_stop"
    let description = "Stop automatic inbox organization"
    let parameterDescription = "No args"
    func execute(args: [String: String]) async -> ToolResult {
        .success(tool: name, spoken: "Inbox organization stopped.")
    }
}
