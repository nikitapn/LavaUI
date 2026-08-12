import Foundation

/// Open-Meteo: the forecast and the place search.
///
/// Chosen because it needs no API key and no account. That is not a detail —
/// every other free weather API wants a key, which would mean this app either
/// ships a secret in the repository or refuses to start until the user has
/// signed up for something. Neither is a weather app.
///
/// Building the URL and reading the response are separate from performing it,
/// so both can be tested against a recorded payload with no network. See
/// `WeatherService` for the half that actually goes out.
public enum OpenMeteo {
    public static let forecastHost = "https://api.open-meteo.com/v1/forecast"
    public static let geocodingHost = "https://geocoding-api.open-meteo.com/v1/search"

    /// Days of outlook requested. Seven is what fits a week strip; the API
    /// will give sixteen, most of which is a guess.
    public static let forecastDays = 7

    public static func forecastURL(for place: Place) -> URL? {
        var components = URLComponents(string: forecastHost)
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(place.latitude)),
            URLQueryItem(name: "longitude", value: String(place.longitude)),
            URLQueryItem(
                name: "current",
                value: "temperature_2m,relative_humidity_2m,apparent_temperature,"
                    + "is_day,precipitation,weather_code,wind_speed_10m"
            ),
            URLQueryItem(
                name: "hourly",
                value: "temperature_2m,weather_code,precipitation_probability"
            ),
            URLQueryItem(
                name: "daily",
                value: "weather_code,temperature_2m_max,temperature_2m_min,"
                    + "sunrise,sunset,precipitation_probability_max"
            ),
            // Wall-clock times in the *forecast's* zone, which is what a
            // reader means by "3pm" for a city they are not standing in.
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: String(forecastDays)),
        ]
        return components?.url
    }

    public static func searchURL(name: String, count: Int = 8) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents(string: geocodingHost)
        components?.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components?.url
    }

    // MARK: - Decoding

    /// What the endpoint actually sends: parallel arrays, one per field.
    ///
    /// Mirrored exactly and then transposed into rows, rather than decoded
    /// straight into the model. The wire format is columnar because it
    /// compresses well, and the app wants an hour at a time; doing the
    /// transpose here means every consumer gets rows and only this file ever
    /// has to know the arrays might disagree in length.
    private struct ForecastPayload: Decodable {
        struct Current: Decodable {
            let time: String
            let temperature_2m: Double
            let relative_humidity_2m: Int
            let apparent_temperature: Double
            let is_day: Int
            let precipitation: Double
            let weather_code: Int
            let wind_speed_10m: Double
        }
        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double]
            let weather_code: [Int]
            let precipitation_probability: [Int?]
        }
        struct Daily: Decodable {
            let time: [String]
            let weather_code: [Int]
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
            let sunrise: [String]
            let sunset: [String]
            let precipitation_probability_max: [Int?]
        }
        let timezone: String?
        let current: Current
        let hourly: Hourly
        let daily: Daily
    }

    private struct SearchPayload: Decodable {
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let country: String?
            let admin1: String?
            let timezone: String?
        }
        // Absent entirely when nothing matched, rather than an empty array.
        let results: [Result]?
    }

    public static func decodeForecast(_ data: Data, place: Place) throws -> Forecast {
        let payload = try JSONDecoder().decode(ForecastPayload.self, from: data)

        // The shortest array wins. They are always the same length in practice,
        // and "in practice" is not a thing to index an array on.
        let hourCount = min(
            payload.hourly.time.count,
            payload.hourly.temperature_2m.count,
            payload.hourly.weather_code.count
        )
        var hourly: [HourPoint] = []
        hourly.reserveCapacity(hourCount)
        for i in 0..<hourCount {
            let stamp = payload.hourly.time[i]
            hourly.append(HourPoint(
                time: String(stamp.suffix(5)),
                day: String(stamp.prefix(10)),
                temperature: payload.hourly.temperature_2m[i],
                code: WeatherCode(payload.hourly.weather_code[i]),
                precipitationChance: value(payload.hourly.precipitation_probability, i)
            ))
        }

        let dayCount = min(
            payload.daily.time.count,
            payload.daily.weather_code.count,
            payload.daily.temperature_2m_max.count,
            payload.daily.temperature_2m_min.count
        )
        var daily: [DayForecast] = []
        daily.reserveCapacity(dayCount)
        for i in 0..<dayCount {
            daily.append(DayForecast(
                day: payload.daily.time[i],
                high: payload.daily.temperature_2m_max[i],
                low: payload.daily.temperature_2m_min[i],
                code: WeatherCode(payload.daily.weather_code[i]),
                precipitationChance: value(
                    payload.daily.precipitation_probability_max, i
                ),
                sunrise: clock(payload.daily.sunrise, i),
                sunset: clock(payload.daily.sunset, i)
            ))
        }

        let current = CurrentConditions(
            temperature: payload.current.temperature_2m,
            feelsLike: payload.current.apparent_temperature,
            humidity: payload.current.relative_humidity_2m,
            precipitation: payload.current.precipitation,
            windSpeed: payload.current.wind_speed_10m,
            code: WeatherCode(payload.current.weather_code),
            isDay: payload.current.is_day != 0,
            time: String(payload.current.time.suffix(5))
        )

        // The endpoint knows the real zone; `place` may only have said "auto".
        var resolved = place
        if let zone = payload.timezone, !zone.isEmpty { resolved.timezone = zone }

        return Forecast(
            place: resolved, current: current, hourly: hourly, daily: daily,
            timezone: resolved.timezone
        )
    }

    public static func decodePlaces(_ data: Data) throws -> [Place] {
        let payload = try JSONDecoder().decode(SearchPayload.self, from: data)
        return (payload.results ?? []).map { result in
            Place(
                name: result.name,
                admin: result.admin1 ?? "",
                country: result.country ?? "",
                latitude: result.latitude,
                longitude: result.longitude,
                timezone: result.timezone ?? "auto"
            )
        }
    }

    /// Precipitation probability is null for hours the model has no view on.
    private static func value(_ array: [Int?], _ index: Int) -> Int {
        index < array.count ? (array[index] ?? 0) : 0
    }

    /// "2026-08-12T05:44" → "05:44".
    private static func clock(_ array: [String], _ index: Int) -> String {
        index < array.count ? String(array[index].suffix(5)) : ""
    }
}
