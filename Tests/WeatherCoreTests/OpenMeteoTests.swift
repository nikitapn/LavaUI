import XCTest

@testable import WeatherCore

/// Decoding, against payloads recorded from the live endpoints.
///
/// Fixtures rather than the network: a test that reaches the internet fails on
/// a train, and a weather API's *shape* is what this code depends on — the
/// numbers change every hour and prove nothing.
final class OpenMeteoTests: XCTestCase {
    // Trimmed to three hours and two days; every field the decoder reads is
    // present, including the nulls the real endpoint sends for probabilities
    // it has no view on.
    private let forecastJSON = """
    {
      "latitude": 52.52, "longitude": 13.419,
      "utc_offset_seconds": 7200, "timezone": "Europe/Berlin",
      "current": {
        "time": "2026-08-12T13:30", "interval": 900,
        "temperature_2m": 23.0, "relative_humidity_2m": 33,
        "apparent_temperature": 23.4, "is_day": 1,
        "precipitation": 0.0, "weather_code": 0, "wind_speed_10m": 1.5
      },
      "hourly": {
        "time": ["2026-08-12T12:00", "2026-08-12T13:00", "2026-08-12T14:00"],
        "temperature_2m": [16.4, 15.8, 14.9],
        "weather_code": [0, 61, 95],
        "precipitation_probability": [0, null, 40]
      },
      "daily": {
        "time": ["2026-08-12", "2026-08-13"],
        "weather_code": [1, 2],
        "temperature_2m_max": [24.9, 27.5],
        "temperature_2m_min": [13.2, 15.3],
        "sunrise": ["2026-08-12T05:44", "2026-08-13T05:45"],
        "sunset": ["2026-08-12T20:38", "2026-08-13T20:36"],
        "precipitation_probability_max": [0, null]
      }
    }
    """

    private func decoded() throws -> Forecast {
        try OpenMeteo.decodeForecast(
            Data(forecastJSON.utf8),
            place: Place(name: "Berlin", latitude: 52.52, longitude: 13.41)
        )
    }

    func testCurrentConditions() throws {
        let f = try decoded()
        XCTAssertEqual(f.current.temperature, 23.0)
        XCTAssertEqual(f.current.humidity, 33)
        XCTAssertTrue(f.current.isDay)
        XCTAssertEqual(f.current.code.summary, "Clear")
        XCTAssertEqual(f.current.time, "13:30", "should keep wall clock, not the date")
    }

    /// The wire format is columnar and the app wants rows; this is the join.
    func testHourlyArraysBecomeRows() throws {
        let f = try decoded()
        XCTAssertEqual(f.hourly.count, 3)
        XCTAssertEqual(f.hourly[1].time, "13:00")
        XCTAssertEqual(f.hourly[1].day, "2026-08-12")
        XCTAssertEqual(f.hourly[1].temperature, 15.8)
        XCTAssertEqual(f.hourly[1].code.sky, .rain)
        XCTAssertEqual(f.hourly[2].code.sky, .thunder)
    }

    /// Probability is null for hours the model will not commit on, and a
    /// crash there would take the whole forecast with it.
    func testNullProbabilitiesReadAsZero() throws {
        let f = try decoded()
        XCTAssertEqual(f.hourly[1].precipitationChance, 0)
        XCTAssertEqual(f.daily[1].precipitationChance, 0)
    }

    func testDailyRows() throws {
        let f = try decoded()
        XCTAssertEqual(f.daily.count, 2)
        XCTAssertEqual(f.daily[0].high, 24.9)
        XCTAssertEqual(f.daily[0].low, 13.2)
        XCTAssertEqual(f.daily[0].sunrise, "05:44")
        XCTAssertEqual(f.daily[0].sunset, "20:38")
    }

    /// The endpoint resolves "auto" to a real zone, and the app shows wall
    /// clock times that only mean something with it.
    func testTimezoneComesBackFromTheResponse() throws {
        let f = try decoded()
        XCTAssertEqual(f.timezone, "Europe/Berlin")
        XCTAssertEqual(f.place.timezone, "Europe/Berlin")
    }

    /// Arrays that disagree in length must truncate, not trap.
    func testMismatchedArrayLengthsAreTruncated() throws {
        let ragged = """
        {
          "timezone": "UTC",
          "current": {
            "time": "2026-08-12T13:30", "interval": 900,
            "temperature_2m": 1, "relative_humidity_2m": 1,
            "apparent_temperature": 1, "is_day": 0,
            "precipitation": 0, "weather_code": 3, "wind_speed_10m": 1
          },
          "hourly": {
            "time": ["2026-08-12T12:00", "2026-08-12T13:00"],
            "temperature_2m": [1.0],
            "weather_code": [0, 0],
            "precipitation_probability": []
          },
          "daily": {
            "time": ["2026-08-12"], "weather_code": [],
            "temperature_2m_max": [2.0], "temperature_2m_min": [1.0],
            "sunrise": [], "sunset": [], "precipitation_probability_max": []
          }
        }
        """
        let f = try OpenMeteo.decodeForecast(
            Data(ragged.utf8), place: .fallback
        )
        XCTAssertEqual(f.hourly.count, 1)
        XCTAssertEqual(f.daily.count, 0)
    }

    // MARK: - Place search

    func testDecodingSearchResults() throws {
        let json = """
        {"results": [
          {"name": "Berlin", "latitude": 52.52437, "longitude": 13.41053,
           "country": "Germany", "admin1": "State of Berlin",
           "timezone": "Europe/Berlin"},
          {"name": "Berlin", "latitude": 44.46867, "longitude": -71.18508,
           "country": "United States", "admin1": "New Hampshire",
           "timezone": "America/New_York"}
        ]}
        """
        let places = try OpenMeteo.decodePlaces(Data(json.utf8))
        XCTAssertEqual(places.count, 2)
        XCTAssertEqual(places[0].label, "Berlin, State of Berlin, Germany")
        XCTAssertEqual(places[1].country, "United States")
    }

    /// No match omits the key entirely rather than sending an empty array.
    func testEmptySearchIsNotAnError() throws {
        let places = try OpenMeteo.decodePlaces(Data(#"{"generationtime_ms":0.1}"#.utf8))
        XCTAssertTrue(places.isEmpty)
    }

    func testSearchURLRefusesAnEmptyQuery() {
        XCTAssertNil(OpenMeteo.searchURL(name: "   "))
        XCTAssertNotNil(OpenMeteo.searchURL(name: "Oslo"))
    }

    // MARK: - Presentation helpers

    /// The strip starts at the current hour, not at midnight — the first
    /// twelve entries of the response are already in the past.
    func testUpcomingHoursStartsAtTheCurrentHour() throws {
        let f = try decoded()
        let upcoming = f.upcomingHours(2)
        XCTAssertEqual(upcoming.first?.time, "13:00")
        XCTAssertEqual(upcoming.count, 2)
    }

    func testWeekdayIsComputedFromTheDateNotTheClock() {
        // 2026-08-12 is a Wednesday.
        XCTAssertEqual(CalendarLabels.weekday(forISODay: "2026-08-12"), "Wed")
        XCTAssertEqual(CalendarLabels.weekday(forISODay: "2000-01-01"), "Sat")
        XCTAssertEqual(CalendarLabels.weekday(forISODay: "2026-03-01"), "Sun")
        XCTAssertEqual(CalendarLabels.weekday(forISODay: "nonsense"), "")
    }

    func testUnitConversion() {
        XCTAssertEqual(UnitSystem.metric.temperatureLabel(23.4), "23°")
        XCTAssertEqual(UnitSystem.imperial.temperatureLabel(0), "32°")
        XCTAssertEqual(Int(UnitSystem.imperial.speed(100).rounded()), 62)
    }

    /// Unknown codes say so instead of being quietly called cloudy.
    func testUnknownWeatherCodeIsAdmitted() {
        XCTAssertEqual(WeatherCode(0).summary, "Clear")
        XCTAssertEqual(WeatherCode(199).summary, "Code 199")
        XCTAssertEqual(WeatherCode(199).sky, .cloudy)
    }
}
