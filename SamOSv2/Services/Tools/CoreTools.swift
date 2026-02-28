import Foundation

/// Displays markdown text on the output canvas.
struct ShowTextTool: Tool {
    let name = "show_text"
    let description = "Display markdown text on the output canvas"
    let parameterDescription = "Args: markdown|text|content (string)"

    func execute(args: [String: String]) async -> ToolResult {
        let text = args["markdown"] ?? args["text"] ?? args["content"] ?? ""
        guard !text.isEmpty else {
            return .failure(tool: name, error: "No text provided")
        }
        return .success(tool: name, output: OutputItem(kind: .markdown, payload: text))
    }
}

/// Displays an image URL on the output canvas.
struct ShowImageTool: Tool {
    let name = "show_image"
    let description = "Display an image from a URL on the output canvas"
    let parameterDescription = "Args: url (string)"

    func execute(args: [String: String]) async -> ToolResult {
        let url = args["url"] ?? args["image_url"] ?? args["src"] ?? ""
        guard !url.isEmpty else {
            return .failure(tool: name, error: "No image URL provided")
        }
        return .success(tool: name, output: OutputItem(kind: .image, payload: url))
    }
}

/// Displays a named asset image from the app bundle.
struct ShowAssetImageTool: Tool {
    let name = "show_asset_image"
    let description = "Display a named asset image from the app bundle"
    let parameterDescription = "Args: name (string)"

    func execute(args: [String: String]) async -> ToolResult {
        let assetName = args["name"] ?? args["asset"] ?? ""
        guard !assetName.isEmpty else {
            return .failure(tool: name, error: "No asset name provided")
        }
        return .success(tool: name, output: OutputItem(kind: .image, payload: "asset://\(assetName)"))
    }
}

/// Lists available asset images in the app bundle.
struct ListAssetsTool: Tool {
    let name = "list_assets"
    let description = "List available asset images in the app bundle"
    let parameterDescription = "No args"

    func execute(args: [String: String]) async -> ToolResult {
        // List assets from bundle
        let assetNames = ["sam"] // Base assets; more can be added
        let list = assetNames.map { "- \($0)" }.joined(separator: "\n")
        return .success(tool: name, output: OutputItem(kind: .markdown, payload: "**Available Assets:**\n\(list)"),
                       spoken: "I have \(assetNames.count) assets available.")
    }
}

/// Finds files on the local filesystem.
struct FindFilesTool: Tool {
    let name = "find_files"
    let description = "Search for files on the local filesystem"
    let parameterDescription = "Args: query|pattern (string), path (optional)"

    func execute(args: [String: String]) async -> ToolResult {
        let query = args["query"] ?? args["pattern"] ?? args["name"] ?? ""
        guard !query.isEmpty else {
            return .failure(tool: name, error: "No search query provided")
        }

        let searchPath = args["path"] ?? NSHomeDirectory()
        let fm = FileManager.default

        var results: [String] = []
        if let enumerator = fm.enumerator(atPath: searchPath) {
            while let file = enumerator.nextObject() as? String {
                if file.lowercased().contains(query.lowercased()) {
                    results.append(file)
                    if results.count >= 20 { break }
                }
            }
        }

        if results.isEmpty {
            return .success(tool: name, spoken: "No files found matching '\(query)'.")
        }

        let list = results.map { "- \($0)" }.joined(separator: "\n")
        return .success(tool: name,
                       output: OutputItem(kind: .markdown, payload: "**Files matching '\(query)':**\n\(list)"),
                       spoken: "Found \(results.count) files matching '\(query)'.")
    }
}
