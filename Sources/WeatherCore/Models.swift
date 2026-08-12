import Foundation

/// A place a forecast can be asked about.
///
/// Coordinates rather than a name, because that is what the forecast endpoint
/// takes and because "Berlin" is three different towns. The name is carried
/// along for the title bar and for remembering the choice.
public struct Place: Equatable, Sendable, Codable {
    public var name: String
    public var admin: String
    public var country: String
    public var latitude: Double
    public var longitude: Double
    public var timezone: String

    public init(
        name: String, admin: String = "", country: String = "",
        latitude: Double, longitude: Double, timezone: String = "auto"
    ) {
        self.name = name
        self.admin = admin
        self.country = country
        self.latitude = latitude
        self.longitude = longitude
        self.timezone = timezone
    }

    /// "Berlin, Germany" — or with the region where that is what tells two
    /// places of the same name apart.
    public var label: String {
        var parts = [name]
        if !admin.isEmpty, admin != name { parts.append(admin) }
        if !country.isEmpty { parts.append(country) }
        return parts.joined(separator: ", ")
    }

    /// Somewhere to point at before the user has chosen, and after a search
    /// that found nothing.
    public static let fallback = Place(
        name: "Berlin", admin: "State of Berlin", country: "Germany",
        latitude: 52.5244, longitude: 13.4105, timezone: "Europe/Berlin"
    )
}

/// What the sky is doing, coarse enough to draw.
///
/// The WMO table has twenty-eight codes and a forecast has room for about
/// eight pictures. This is the grouping the drawing uses; `WeatherCode.summary`
/// keeps the full detail for the text beside it, so nothing is lost by
/// bucketing here.
public enum Sky: Equatable, Sendable {
    case clear
    case partlyCloudy
    case cloudy
    case fog
    case drizzle
    case rain
    case snow
    case thunder
}

/// A WMO weather-interpretation code, as Open-Meteo reports it.
public struct WeatherCode: Equatable, Sendable {
    public let raw: Int

    public init(_ raw: Int) { self.raw = raw }

    public var sky: Sky {
        switch raw {
        case 0: return .clear
        case 1, 2: return .partlyCloudy
        case 3: return .cloudy
        case 45, 48: return .fog
        case 51, 53, 55, 56, 57: return .drizzle
        case 61, 63, 65, 66, 67, 80, 81, 82: return .rain
        case 71, 73, 75, 77, 85, 86: return .snow
        case 95, 96, 99: return .thunder
        default: return .cloudy
        }
    }

    /// The phrase shown next to the picture. Unknown codes say so rather than
    /// guessing: a forecast that quietly calls an unrecognised code "cloudy"
    /// is worse than one that admits it does not know.
    public var summary: String {
        switch raw {
        case 0: return "Clear"
        case 1: return "Mainly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45: return "Fog"
        case 48: return "Freezing fog"
        case 51: return "Light drizzle"
        case 53: return "Drizzle"
        case 55: return "Heavy drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61: return "Light rain"
        case 63: return "Rain"
        case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71: return "Light snow"
        case 73: return "Snow"
        case 75: return "Heavy snow"
        case 77: return "Snow grains"
        case 80: return "Light showers"
        case 81: return "Showers"
        case 82: return "Violent showers"
        case 85: return "Light snow showers"
        case 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return "Code \(raw)"
        }
    }
}

/// Right now, at the place asked about.
public struct CurrentConditions: Equatable, Sendable {
    public var temperature: Double
    public var feelsLike: Double
    public var humidity: Int
    public var precipitation: Double
    public var windSpeed: Double
    public var code: WeatherCode
    public var isDay: Bool
    /// Local wall-clock time of the observation, "HH:mm".
    public var time: String

    public init(
        temperature: Double, feelsLike: Double, humidity: Int,
        precipitation: Double, windSpeed: Double, code: WeatherCode,
        isDay: Bool, time: String
    ) {
        self.temperature = temperature
        self.feelsLike = feelsLike
        self.humidity = humidity
        self.precipitation = precipitation
        self.windSpeed = windSpeed
        self.code = code
        self.isDay = isDay
        self.time = time
    }
}

/// One hour of the hourly strip.
public struct HourPoint: Equatable, Sendable {
    /// Local wall clock, "HH:mm".
    public var time: String
    /// Local calendar day, "yyyy-MM-dd" — the strip spans midnight.
    public var day: String
    public var temperature: Double
    public var code: WeatherCode
    /// Chance of precipitation, 0…100.
    public var precipitationChance: Int

    public init(
        time: String, day: String, temperature: Double, code: WeatherCode,
        precipitationChance: Int
    ) {
        self.time = time
        self.day = day
        self.temperature = temperature
        self.code = code
        self.precipitationChance = precipitationChance
    }

    /// "14" — the strip is dense and the minutes are always zero.
    public var hourLabel: String { String(time.prefix(2)) }
}

/// One day of the outlook.
public struct DayForecast: Equatable, Sendable {
    /// Local calendar day, "yyyy-MM-dd".
    public var day: String
    public var high: Double
    public var low: Double
    public var code: WeatherCode
    public var precipitationChance: Int
    public var sunrise: String
    public var sunset: String

    public init(
        day: String, high: Double, low: Double, code: WeatherCode,
        precipitationChance: Int, sunrise: String, sunset: String
    ) {
        self.day = day
        self.high = high
        self.low = low
        self.code = code
        self.precipitationChance = precipitationChance
        self.sunrise = sunrise
        self.sunset = sunset
    }

    /// "Mon". Computed from the date rather than from the system clock, so a
    /// forecast fetched in one timezone and read in another still names its
    /// own days correctly.
    public var weekdayLabel: String { CalendarLabels.weekday(forISODay: day) }
}

/// Everything one fetch produces.
public struct Forecast: Equatable, Sendable {
    public var place: Place
    public var current: CurrentConditions
    public var hourly: [HourPoint]
    public var daily: [DayForecast]
    /// IANA zone the wall-clock strings above are in.
    public var timezone: String

    public init(
        place: Place, current: CurrentConditions, hourly: [HourPoint],
        daily: [DayForecast], timezone: String
    ) {
        self.place = place
        self.current = current
        self.hourly = hourly
        self.daily = daily
        self.timezone = timezone
    }

    /// The hours from `current` onward, which is the only part of a 168-hour
    /// array anybody wants to look at. Falls back to the head of the array
    /// when the current hour is not in it, so a clock skew shows *something*
    /// rather than an empty strip.
    public func upcomingHours(_ count: Int = 24) -> [HourPoint] {
        let day = String(currentDay)
        let hour = String(current.time.prefix(2))
        let start = hourly.firstIndex {
            $0.day > day || ($0.day == day && $0.hourLabel >= hour)
        }
        let from = start ?? 0
        return Array(hourly[from..<min(hourly.count, from + count)])
    }

    /// The day `current` belongs to, taken from the daily array rather than
    /// the clock: they came from the same response and agree by construction.
    public var currentDay: String { daily.first?.day ?? "" }
}

/// Weekday names without a `Calendar`, which on Linux would drag the system
/// locale and timezone into a string that is neither.
public enum CalendarLabels {
    static let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// Day of week for an ISO "yyyy-MM-dd", by Sakamoto's method.
    ///
    /// Arithmetic rather than `DateFormatter` on purpose. The date is already
    /// *local to the forecast*, so converting it through a `Date` — which is
    /// an instant, not a day — would shift it by the difference between the
    /// forecast's timezone and the machine's, and name the wrong day for
    /// exactly the users who travel.
    public static func weekday(forISODay iso: String) -> String {
        let parts = iso.split(separator: "-")
        guard parts.count >= 3,
              var y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m)
        else { return "" }
        let offsets = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
        if m < 3 { y -= 1 }
        let index = (y + y / 4 - y / 100 + y / 400 + offsets[m - 1] + d) % 7
        return names[(index + 7) % 7]
    }
}
