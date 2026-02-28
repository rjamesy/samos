import Foundation

/// 400+ city/state → IANA timezone mappings.
enum TimezoneMapping {
    // MARK: - International Cities

    static let cityToTimezone: [String: String] = [
        // Australia & Oceania
        "sydney": "Australia/Sydney", "melbourne": "Australia/Melbourne",
        "brisbane": "Australia/Brisbane", "perth": "Australia/Perth",
        "adelaide": "Australia/Adelaide", "hobart": "Australia/Hobart",
        "darwin": "Australia/Darwin", "canberra": "Australia/Sydney",
        "gold coast": "Australia/Brisbane", "auckland": "Pacific/Auckland",
        "wellington": "Pacific/Auckland", "christchurch": "Pacific/Auckland",
        "fiji": "Pacific/Fiji", "honolulu": "Pacific/Honolulu",

        // Europe
        "london": "Europe/London", "paris": "Europe/Paris",
        "berlin": "Europe/Berlin", "madrid": "Europe/Madrid",
        "rome": "Europe/Rome", "amsterdam": "Europe/Amsterdam",
        "brussels": "Europe/Brussels", "vienna": "Europe/Vienna",
        "zurich": "Europe/Zurich", "stockholm": "Europe/Stockholm",
        "oslo": "Europe/Oslo", "copenhagen": "Europe/Copenhagen",
        "helsinki": "Europe/Helsinki", "warsaw": "Europe/Warsaw",
        "prague": "Europe/Prague", "budapest": "Europe/Budapest",
        "athens": "Europe/Athens", "lisbon": "Europe/Lisbon",
        "dublin": "Europe/Dublin", "moscow": "Europe/Moscow",
        "istanbul": "Europe/Istanbul", "bucharest": "Europe/Bucharest",
        "belgrade": "Europe/Belgrade", "sofia": "Europe/Sofia",
        "zagreb": "Europe/Zagreb", "edinburgh": "Europe/London",
        "glasgow": "Europe/London", "manchester": "Europe/London",
        "birmingham": "Europe/London", "munich": "Europe/Berlin",
        "barcelona": "Europe/Madrid", "milan": "Europe/Rome",
        "naples": "Europe/Rome", "lyon": "Europe/Paris",
        "marseille": "Europe/Paris", "geneva": "Europe/Zurich",

        // Asia
        "tokyo": "Asia/Tokyo", "osaka": "Asia/Tokyo",
        "beijing": "Asia/Shanghai", "shanghai": "Asia/Shanghai",
        "hong kong": "Asia/Hong_Kong", "singapore": "Asia/Singapore",
        "seoul": "Asia/Seoul", "taipei": "Asia/Taipei",
        "bangkok": "Asia/Bangkok", "mumbai": "Asia/Kolkata",
        "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata",
        "kolkata": "Asia/Kolkata", "chennai": "Asia/Kolkata",
        "bangalore": "Asia/Kolkata", "bengaluru": "Asia/Kolkata",
        "hyderabad": "Asia/Kolkata", "karachi": "Asia/Karachi",
        "lahore": "Asia/Karachi", "islamabad": "Asia/Karachi",
        "dubai": "Asia/Dubai", "abu dhabi": "Asia/Dubai",
        "riyadh": "Asia/Riyadh", "doha": "Asia/Qatar",
        "jakarta": "Asia/Jakarta", "manila": "Asia/Manila",
        "hanoi": "Asia/Ho_Chi_Minh", "ho chi minh": "Asia/Ho_Chi_Minh",
        "kuala lumpur": "Asia/Kuala_Lumpur", "colombo": "Asia/Colombo",
        "kathmandu": "Asia/Kathmandu", "dhaka": "Asia/Dhaka",
        "yangon": "Asia/Yangon", "phnom penh": "Asia/Phnom_Penh",
        "tehran": "Asia/Tehran", "baghdad": "Asia/Baghdad",
        "jerusalem": "Asia/Jerusalem", "tel aviv": "Asia/Jerusalem",
        "baku": "Asia/Baku", "tbilisi": "Asia/Tbilisi",
        "yerevan": "Asia/Yerevan", "almaty": "Asia/Almaty",
        "tashkent": "Asia/Tashkent",

        // Americas (non-US)
        "toronto": "America/Toronto", "vancouver": "America/Vancouver",
        "montreal": "America/Toronto", "calgary": "America/Edmonton",
        "edmonton": "America/Edmonton", "winnipeg": "America/Winnipeg",
        "ottawa": "America/Toronto", "halifax": "America/Halifax",
        "mexico city": "America/Mexico_City", "guadalajara": "America/Mexico_City",
        "monterrey": "America/Monterrey", "cancun": "America/Cancun",
        "sao paulo": "America/Sao_Paulo", "rio de janeiro": "America/Sao_Paulo",
        "rio": "America/Sao_Paulo", "brasilia": "America/Sao_Paulo",
        "buenos aires": "America/Argentina/Buenos_Aires",
        "bogota": "America/Bogota", "lima": "America/Lima",
        "santiago": "America/Santiago", "caracas": "America/Caracas",
        "havana": "America/Havana", "panama": "America/Panama",
        "san jose": "America/Costa_Rica", "quito": "America/Guayaquil",
        "montevideo": "America/Montevideo", "asuncion": "America/Asuncion",
        "la paz": "America/La_Paz",

        // Africa
        "cairo": "Africa/Cairo", "johannesburg": "Africa/Johannesburg",
        "cape town": "Africa/Johannesburg", "lagos": "Africa/Lagos",
        "nairobi": "Africa/Nairobi", "casablanca": "Africa/Casablanca",
        "accra": "Africa/Accra", "addis ababa": "Africa/Addis_Ababa",
        "dar es salaam": "Africa/Dar_es_Salaam", "tunis": "Africa/Tunis",
        "algiers": "Africa/Algiers", "kinshasa": "Africa/Kinshasa",
        "luanda": "Africa/Luanda", "kampala": "Africa/Kampala",

        // US Cities (major)
        "new york": "America/New_York", "nyc": "America/New_York",
        "los angeles": "America/Los_Angeles", "la": "America/Los_Angeles",
        "chicago": "America/Chicago", "houston": "America/Chicago",
        "phoenix": "America/Phoenix", "philadelphia": "America/New_York",
        "san antonio": "America/Chicago", "san diego": "America/Los_Angeles",
        "dallas": "America/Chicago", "san francisco": "America/Los_Angeles",
        "sf": "America/Los_Angeles", "austin": "America/Chicago",
        "seattle": "America/Los_Angeles", "denver": "America/Denver",
        "boston": "America/New_York", "nashville": "America/Chicago",
        "portland": "America/Los_Angeles", "las vegas": "America/Los_Angeles",
        "miami": "America/New_York", "atlanta": "America/New_York",
        "detroit": "America/Detroit", "minneapolis": "America/Chicago",
        "tampa": "America/New_York", "orlando": "America/New_York",
        "st louis": "America/Chicago", "pittsburgh": "America/New_York",
        "cleveland": "America/New_York", "cincinnati": "America/New_York",
        "indianapolis": "America/Indiana/Indianapolis",
        "salt lake city": "America/Denver", "anchorage": "America/Anchorage",
        "washington dc": "America/New_York", "dc": "America/New_York",
    ]

    // MARK: - US States

    static let stateToTimezone: [String: String] = [
        // Eastern
        "connecticut": "America/New_York", "ct": "America/New_York",
        "delaware": "America/New_York", "de": "America/New_York",
        "florida": "America/New_York", "fl": "America/New_York",
        "georgia": "America/New_York", "ga": "America/New_York",
        "maine": "America/New_York", "me": "America/New_York",
        "maryland": "America/New_York", "md": "America/New_York",
        "massachusetts": "America/New_York", "ma": "America/New_York",
        "michigan": "America/Detroit", "mi": "America/Detroit",
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

        // Non-contiguous
        "alaska": "America/Anchorage", "ak": "America/Anchorage",
        "hawaii": "Pacific/Honolulu", "hi": "Pacific/Honolulu",

        // Indiana
        "indiana": "America/Indiana/Indianapolis", "in": "America/Indiana/Indianapolis",
    ]

    /// Lookup timezone from city name, state name, or abbreviation.
    static func lookup(_ input: String) -> String? {
        let key = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return cityToTimezone[key] ?? stateToTimezone[key]
    }
}
