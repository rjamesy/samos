import Foundation

/// Searches Wikimedia Commons and returns image URLs.
struct FindImageTool: Tool {
    let name = "find_image"
    let description = "Search for images on the web"
    let parameterDescription = "Args: query|q|search (string)"

    func execute(args: [String: String]) async -> ToolResult {
        let query = args["query"] ?? args["q"] ?? args["search"] ?? args["search_term"] ?? args["term"] ?? args["topic"] ?? args["text"] ?? args["input"] ?? ""
        guard !query.isEmpty else {
            return .failure(tool: name, error: "No search query provided")
        }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let apiURL = "https://commons.wikimedia.org/w/api.php?action=query&generator=search&gsrsearch=\(encoded)&gsrnamespace=6&gsrlimit=3&prop=imageinfo&iiprop=url&iiurlwidth=800&format=json"

        guard let url = URL(string: apiURL) else {
            return .failure(tool: name, error: "Invalid search URL")
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let queryResult = json["query"] as? [String: Any],
               let pages = queryResult["pages"] as? [String: Any] {
                // Find the first page with an image URL
                for (_, pageValue) in pages {
                    if let page = pageValue as? [String: Any],
                       let imageinfo = page["imageinfo"] as? [[String: Any]],
                       let info = imageinfo.first,
                       let thumbURL = info["thumburl"] as? String {
                        return .success(tool: name,
                                       output: OutputItem(kind: .image, payload: thumbURL),
                                       spoken: "Here's an image of '\(query)'.")
                    }
                }
            }
            return .failure(tool: name, error: "No images found for '\(query)'")
        } catch {
            return .failure(tool: name, error: "Image search failed: \(error.localizedDescription)")
        }
    }
}

/// Searches YouTube for videos.
struct FindVideoTool: Tool {
    let name = "find_video"
    let description = "Search for videos on YouTube"
    let parameterDescription = "Args: query|q (string)"

    func execute(args: [String: String]) async -> ToolResult {
        let query = args["query"] ?? args["q"] ?? args["search"] ?? ""
        guard !query.isEmpty else {
            return .failure(tool: name, error: "No search query provided")
        }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = "https://www.youtube.com/results?search_query=\(encoded)"
        return .success(tool: name,
                       output: OutputItem(kind: .markdown, payload: "**YouTube Search:** [\(query)](\(url))"),
                       spoken: "Here's a YouTube search for '\(query)'.")
    }
}

/// Searches for recipes.
struct FindRecipeTool: Tool {
    let name = "find_recipe"
    let description = "Search for recipes"
    let parameterDescription = "Args: query|dish|recipe (string)"

    func execute(args: [String: String]) async -> ToolResult {
        let query = args["query"] ?? args["dish"] ?? args["recipe"] ?? args["q"] ?? ""
        guard !query.isEmpty else {
            return .failure(tool: name, error: "No recipe query provided")
        }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = "https://www.google.com/search?q=\(encoded)+recipe"
        return .success(tool: name,
                       output: OutputItem(kind: .markdown, payload: "**Recipe Search:** [\(query)](\(url))"),
                       spoken: "Here's a recipe search for '\(query)'.")
    }
}
