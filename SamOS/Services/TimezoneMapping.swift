import Foundation

/// Maps place names (US states, international cities) to IANA timezone identifiers.
/// Extracted from ClarificationResolver for reuse by GetTimeTool and system prompt.
enum TimezoneMapping {

    /// Maps a place name to an IANA timezone identifier.
    /// Checks international cities first, then US states.
    static func lookup(_ input: String) -> String? {
        let key = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return cityToTimezone[key] ?? stateToTimezone[key]
    }

    /// Returns true if the input contains a recognizable US state name (full names only, 3+ chars).
    /// Two-letter abbreviations are too ambiguous for substring matching in sentences.
    static func containsStateName(_ input: String) -> Bool {
        let lower = input.lowercased()
        for key in stateToTimezone.keys where key.count >= 3 {
            if lower.contains(key) { return true }
        }
        return false
    }

    // MARK: - International Cities & Countries → IANA timezone

    private static let cityToTimezone: [String: String] = [
        // Europe — cities
        "london": "Europe/London",
        "paris": "Europe/Paris",
        "berlin": "Europe/Berlin",
        "madrid": "Europe/Madrid",
        "rome": "Europe/Rome",
        "amsterdam": "Europe/Amsterdam",
        "brussels": "Europe/Brussels",
        "vienna": "Europe/Vienna",
        "zurich": "Europe/Zurich",
        "stockholm": "Europe/Stockholm",
        "oslo": "Europe/Oslo",
        "copenhagen": "Europe/Copenhagen",
        "helsinki": "Europe/Helsinki",
        "warsaw": "Europe/Warsaw",
        "prague": "Europe/Prague",
        "budapest": "Europe/Budapest",
        "athens": "Europe/Athens",
        "lisbon": "Europe/Lisbon",
        "dublin": "Europe/Dublin",
        "edinburgh": "Europe/London",
        "manchester": "Europe/London",
        "moscow": "Europe/Moscow",
        "istanbul": "Europe/Istanbul",
        // Europe — countries
        "uk": "Europe/London", "united kingdom": "Europe/London",
        "england": "Europe/London", "scotland": "Europe/London",
        "wales": "Europe/London", "northern ireland": "Europe/London",
        "ireland": "Europe/Dublin",
        "france": "Europe/Paris",
        "germany": "Europe/Berlin",
        "spain": "Europe/Madrid",
        "italy": "Europe/Rome",
        "netherlands": "Europe/Amsterdam", "holland": "Europe/Amsterdam",
        "belgium": "Europe/Brussels",
        "austria": "Europe/Vienna",
        "switzerland": "Europe/Zurich",
        "sweden": "Europe/Stockholm",
        "norway": "Europe/Oslo",
        "denmark": "Europe/Copenhagen",
        "finland": "Europe/Helsinki",
        "poland": "Europe/Warsaw",
        "czech republic": "Europe/Prague", "czechia": "Europe/Prague",
        "hungary": "Europe/Budapest",
        "greece": "Europe/Athens",
        "portugal": "Europe/Lisbon",
        "turkey": "Europe/Istanbul",
        "russia": "Europe/Moscow",
        // Asia — cities
        "tokyo": "Asia/Tokyo",
        "beijing": "Asia/Shanghai",
        "shanghai": "Asia/Shanghai",
        "hong kong": "Asia/Hong_Kong",
        "singapore": "Asia/Singapore",
        "seoul": "Asia/Seoul",
        "taipei": "Asia/Taipei",
        "bangkok": "Asia/Bangkok",
        "mumbai": "Asia/Kolkata",
        "delhi": "Asia/Kolkata",
        "new delhi": "Asia/Kolkata",
        "kolkata": "Asia/Kolkata",
        "chennai": "Asia/Kolkata",
        "bangalore": "Asia/Kolkata",
        "karachi": "Asia/Karachi",
        "dubai": "Asia/Dubai",
        "abu dhabi": "Asia/Dubai",
        "riyadh": "Asia/Riyadh",
        "jakarta": "Asia/Jakarta",
        "kuala lumpur": "Asia/Kuala_Lumpur",
        "manila": "Asia/Manila",
        "hanoi": "Asia/Ho_Chi_Minh",
        "ho chi minh": "Asia/Ho_Chi_Minh",
        // Asia — countries
        "japan": "Asia/Tokyo",
        "china": "Asia/Shanghai",
        "south korea": "Asia/Seoul", "korea": "Asia/Seoul",
        "taiwan": "Asia/Taipei",
        "thailand": "Asia/Bangkok",
        "india": "Asia/Kolkata",
        "pakistan": "Asia/Karachi",
        "uae": "Asia/Dubai", "united arab emirates": "Asia/Dubai",
        "saudi arabia": "Asia/Riyadh",
        "indonesia": "Asia/Jakarta",
        "malaysia": "Asia/Kuala_Lumpur",
        "philippines": "Asia/Manila",
        "vietnam": "Asia/Ho_Chi_Minh",
        // Oceania — cities
        "sydney": "Australia/Sydney",
        "melbourne": "Australia/Melbourne",
        "brisbane": "Australia/Brisbane",
        "perth": "Australia/Perth",
        "adelaide": "Australia/Adelaide",
        "auckland": "Pacific/Auckland",
        "wellington": "Pacific/Auckland",
        // Oceania — countries
        "new zealand": "Pacific/Auckland",
        // Americas — cities (non-US)
        "toronto": "America/Toronto",
        "vancouver": "America/Vancouver",
        "montreal": "America/Toronto",
        "mexico city": "America/Mexico_City",
        "são paulo": "America/Sao_Paulo",
        "sao paulo": "America/Sao_Paulo",
        "rio de janeiro": "America/Sao_Paulo",
        "buenos aires": "America/Argentina/Buenos_Aires",
        "bogota": "America/Bogota",
        "lima": "America/Lima",
        "santiago": "America/Santiago",
        // Americas — countries (single primary timezone)
        "mexico": "America/Mexico_City",
        "brazil": "America/Sao_Paulo",
        "argentina": "America/Argentina/Buenos_Aires",
        "colombia": "America/Bogota",
        "peru": "America/Lima",
        "chile": "America/Santiago",
        // Africa — cities
        "cairo": "Africa/Cairo",
        "johannesburg": "Africa/Johannesburg",
        "lagos": "Africa/Lagos",
        "nairobi": "Africa/Nairobi",
        "cape town": "Africa/Johannesburg",
        "casablanca": "Africa/Casablanca",
        // Africa — countries
        "egypt": "Africa/Cairo",
        "south africa": "Africa/Johannesburg",
        "nigeria": "Africa/Lagos",
        "kenya": "Africa/Nairobi",
        "morocco": "Africa/Casablanca",
    ]

    // 50 US states + DC + common abbreviations → IANA timezone
    // Uses the most populous timezone for states with multiple zones
    private static let stateToTimezone: [String: String] = [
        // Eastern
        "connecticut": "America/New_York", "ct": "America/New_York",
        "delaware": "America/New_York", "de": "America/New_York",
        "georgia": "America/New_York", "ga": "America/New_York",
        "maine": "America/New_York", "me": "America/New_York",
        "maryland": "America/New_York", "md": "America/New_York",
        "massachusetts": "America/New_York", "ma": "America/New_York",
        "new hampshire": "America/New_York", "nh": "America/New_York",
        "new jersey": "America/New_York", "nj": "America/New_York",
        "new york": "America/New_York", "ny": "America/New_York",
        "north carolina": "America/New_York", "nc": "America/New_York",
        "ohio": "America/New_York", "oh": "America/New_York",
        "pennsylvania": "America/New_York", "pa": "America/New_York",
        "rhode island": "America/New_York", "ri": "America/New_York",
        "south carolina": "America/New_York", "sc": "America/New_York",
        "vermont": "America/New_York", "vt": "America/New_York",
        "virginia": "America/New_York", "va": "America/New_York",
        "west virginia": "America/New_York", "wv": "America/New_York",
        "district of columbia": "America/New_York", "dc": "America/New_York",
        "washington dc": "America/New_York",
        // Central
        "alabama": "America/Chicago", "al": "America/Chicago",
        "arkansas": "America/Chicago", "ar": "America/Chicago",
        "illinois": "America/Chicago", "il": "America/Chicago",
        "iowa": "America/Chicago", "ia": "America/Chicago",
        "kansas": "America/Chicago", "ks": "America/Chicago",
        "louisiana": "America/Chicago", "la": "America/Chicago",
        "minnesota": "America/Chicago", "mn": "America/Chicago",
        "mississippi": "America/Chicago", "ms": "America/Chicago",
        "missouri": "America/Chicago", "mo": "America/Chicago",
        "nebraska": "America/Chicago", "ne": "America/Chicago",
        "north dakota": "America/Chicago", "nd": "America/Chicago",
        "oklahoma": "America/Chicago", "ok": "America/Chicago",
        "south dakota": "America/Chicago", "sd": "America/Chicago",
        "tennessee": "America/Chicago", "tn": "America/Chicago",
        "texas": "America/Chicago", "tx": "America/Chicago",
        "wisconsin": "America/Chicago", "wi": "America/Chicago",
        // Mountain
        "arizona": "America/Phoenix", "az": "America/Phoenix",
        "colorado": "America/Denver", "co": "America/Denver",
        "idaho": "America/Boise", "id": "America/Boise",
        "montana": "America/Denver", "mt": "America/Denver",
        "new mexico": "America/Denver", "nm": "America/Denver",
        "utah": "America/Denver", "ut": "America/Denver",
        "wyoming": "America/Denver", "wy": "America/Denver",
        // Pacific
        "california": "America/Los_Angeles", "ca": "America/Los_Angeles",
        "nevada": "America/Los_Angeles", "nv": "America/Los_Angeles",
        "oregon": "America/Los_Angeles", "or": "America/Los_Angeles",
        "washington": "America/Los_Angeles", "wa": "America/Los_Angeles",
        // Alaska / Hawaii
        "alaska": "America/Anchorage", "ak": "America/Anchorage",
        "hawaii": "Pacific/Honolulu", "hi": "Pacific/Honolulu",
        // Territories
        "florida": "America/New_York", "fl": "America/New_York",
        "indiana": "America/Indiana/Indianapolis", "in": "America/Indiana/Indianapolis",
        "kentucky": "America/Kentucky/Louisville", "ky": "America/Kentucky/Louisville",
        "michigan": "America/Detroit", "mi": "America/Detroit",
    ]
}
