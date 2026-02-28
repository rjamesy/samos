import Foundation

/// Returns the current time, optionally for a specific timezone/place.
struct GetTimeTool: Tool {
    let name = "get_time"
    let description = "Get the current time, optionally for a specific timezone or city"
    let parameterDescription = "Args: timezone (IANA ID), place (city/state name)"

    var schema: ToolSchema? {
        ToolSchema(properties: [
            "place": ToolSchemaProperty(description: "City or location name"),
            "timezone": ToolSchemaProperty(description: "IANA timezone ID (e.g. America/New_York)")
        ])
    }

    func execute(args: [String: String]) async -> ToolResult {
        let place = args["place"] ?? args["city"] ?? args["location"] ?? ""
        let tzArg = args["timezone"] ?? args["tz"] ?? ""

        var timeZone: TimeZone?

        if !tzArg.isEmpty {
            timeZone = TimeZone(identifier: tzArg) ?? TimeZone(abbreviation: tzArg)
        }

        if timeZone == nil, !place.isEmpty {
            if let iana = TimezoneMapping.lookup(place) {
                timeZone = TimeZone(identifier: iana)
            }
        }

        let tz = timeZone ?? TimeZone.current
        let formatter = DateFormatter()
        formatter.timeZone = tz
        formatter.dateFormat = "h:mm a"
        let timeStr = formatter.string(from: Date())

        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        let dateStr = formatter.string(from: Date())

        let location = place.isEmpty ? tz.identifier : place
        let spoken = "It's \(timeStr) in \(location)."
        let formatted = "**\(timeStr)**\n\(dateStr)\n*\(tz.identifier)*"

        return .success(tool: name,
                       output: OutputItem(kind: .markdown, payload: formatted),
                       spoken: spoken)
    }
}

/// Fetches weather using Open-Meteo API (free, no API key).
struct GetWeatherTool: Tool {
    let name = "get_weather"
    let description = "Get current weather and forecast for a location"
    let parameterDescription = "Args: place (required), days (1-7), units (C/F)"

    var schema: ToolSchema? {
        ToolSchema(properties: [
            "place": ToolSchemaProperty(description: "City or location name"),
            "days": ToolSchemaProperty(type: "integer", description: "Number of forecast days (1-7)"),
            "units": ToolSchemaProperty(description: "Temperature units", enumValues: ["C", "F"])
        ], required: ["place"])
    }

    func execute(args: [String: String]) async -> ToolResult {
        let place = args["place"] ?? args["city"] ?? args["location"] ?? args["q"] ?? ""
        guard !place.isEmpty else {
            return .failure(tool: name, error: "No location provided. Use place argument.")
        }

        let days = Int(args["days"] ?? "1") ?? 1
        let encoded = place.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? place

        do {
            // Geocode
            let geoURL = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(encoded)&count=1")!
            let (geoData, _) = try await URLSession.shared.data(from: geoURL)
            guard let geoJSON = try JSONSerialization.jsonObject(with: geoData) as? [String: Any],
                  let results = geoJSON["results"] as? [[String: Any]],
                  let first = results.first,
                  let lat = first["latitude"] as? Double,
                  let lon = first["longitude"] as? Double else {
                return .failure(tool: name, error: "Could not find location: \(place)")
            }
            let locationName = first["name"] as? String ?? place

            // Fetch weather
            let wxURL = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,relative_humidity_2m,precipitation,wind_speed_10m,weather_code&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code&forecast_days=\(min(days, 7))&timezone=auto")!
            let (wxData, _) = try await URLSession.shared.data(from: wxURL)
            guard let wxJSON = try JSONSerialization.jsonObject(with: wxData) as? [String: Any],
                  let current = wxJSON["current"] as? [String: Any] else {
                return .failure(tool: name, error: "Weather data unavailable")
            }

            let temp = current["temperature_2m"] as? Double ?? 0
            let humidity = current["relative_humidity_2m"] as? Int ?? 0
            let precip = current["precipitation"] as? Double ?? 0
            let wind = current["wind_speed_10m"] as? Double ?? 0
            let code = current["weather_code"] as? Int ?? 0

            let condition = weatherCondition(code: code)
            let spoken = "It's currently \(Int(temp)) degrees and \(condition.lowercased()) in \(locationName)."

            var formatted = "**\(locationName) Weather**\n"
            formatted += "🌡 \(Int(temp))°C | \(condition)\n"
            formatted += "💧 Humidity: \(humidity)% | Precip: \(precip)mm\n"
            formatted += "💨 Wind: \(Int(wind)) km/h\n"

            // Daily forecast
            if let daily = wxJSON["daily"] as? [String: Any],
               let maxTemps = daily["temperature_2m_max"] as? [Double],
               let minTemps = daily["temperature_2m_min"] as? [Double] {
                formatted += "\n**Forecast:**\n"
                for i in 0..<min(maxTemps.count, days) {
                    formatted += "Day \(i+1): \(Int(minTemps[i]))°–\(Int(maxTemps[i]))°C\n"
                }
            }

            return .success(tool: name,
                           output: OutputItem(kind: .markdown, payload: formatted),
                           spoken: spoken)
        } catch {
            return .failure(tool: name, error: "Weather fetch failed: \(error.localizedDescription)")
        }
    }

    private func weatherCondition(code: Int) -> String {
        switch code {
        case 0: return "Clear sky"
        case 1, 2, 3: return "Partly cloudy"
        case 45, 48: return "Foggy"
        case 51, 53, 55: return "Drizzle"
        case 61, 63, 65: return "Rain"
        case 71, 73, 75: return "Snow"
        case 80, 81, 82: return "Rain showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return "Unknown"
        }
    }
}

/// Fetches news headlines.
struct NewsFetchTool: Tool {
    let name = "news.fetch"
    let description = "Fetch latest news headlines"
    let parameterDescription = "Args: topic|query (optional), count (default 5)"

    func execute(args: [String: String]) async -> ToolResult {
        let topic = args["topic"] ?? args["query"] ?? args["q"] ?? "top"
        let count = Int(args["count"] ?? "5") ?? 5
        let spoken = "Here are the latest \(topic) news headlines."
        let formatted = "**News: \(topic.capitalized)**\n*News fetch requires API key integration*"
        return .success(tool: name,
                       output: OutputItem(kind: .markdown, payload: formatted),
                       spoken: spoken)
    }
}

/// Movie showtimes lookup.
struct MovieShowtimesTool: Tool {
    let name = "movies.showtimes"
    let description = "Look up movie showtimes"
    let parameterDescription = "Args: movie (name), location (city)"

    func execute(args: [String: String]) async -> ToolResult {
        let movie = args["movie"] ?? args["title"] ?? args["film"] ?? ""
        let location = args["location"] ?? args["city"] ?? ""
        let spoken = "Looking up showtimes for \(movie.isEmpty ? "movies" : movie)\(location.isEmpty ? "" : " in \(location)")."
        return .success(tool: name,
                       output: OutputItem(kind: .markdown, payload: "**Movie Showtimes**\n*Integration pending*"),
                       spoken: spoken)
    }
}

/// Fishing report lookup.
struct FishingReportTool: Tool {
    let name = "fishing.report"
    let description = "Get fishing reports for a location"
    let parameterDescription = "Args: location (required)"

    func execute(args: [String: String]) async -> ToolResult {
        let location = args["location"] ?? args["place"] ?? args["spot"] ?? ""
        guard !location.isEmpty else {
            return .failure(tool: name, error: "No location provided")
        }
        return .success(tool: name,
                       output: OutputItem(kind: .markdown, payload: "**Fishing Report: \(location)**\n*Integration pending*"),
                       spoken: "Here's the fishing report for \(location).")
    }
}

/// Price lookup for products.
struct PriceLookupTool: Tool {
    let name = "price.lookup"
    let description = "Look up prices for products"
    let parameterDescription = "Args: product|item|query (string)"

    func execute(args: [String: String]) async -> ToolResult {
        let product = args["product"] ?? args["item"] ?? args["query"] ?? ""
        guard !product.isEmpty else {
            return .failure(tool: name, error: "No product specified")
        }
        return .success(tool: name,
                       output: OutputItem(kind: .markdown, payload: "**Price Lookup: \(product)**\n*Integration pending*"),
                       spoken: "Looking up prices for \(product).")
    }
}
