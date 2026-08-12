import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct WeatherError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Temperature the way the reader wants to see it.
///
/// The request is always metric and the conversion happens here, so switching
/// units is a redraw rather than a round trip — and so a unit change while the
/// network is down still works.
public enum UnitSystem: String, Sendable, Codable, CaseIterable {
    case metric
    case imperial

    public var temperatureSuffix: String { self == .metric ? "°C" : "°F" }
    public var speedSuffix: String { self == .metric ? "km/h" : "mph" }

    public func temperature(_ celsius: Double) -> Double {
        self == .metric ? celsius : celsius * 9 / 5 + 32
    }

    public func speed(_ kmh: Double) -> Double {
        self == .metric ? kmh : kmh * 0.621371
    }

    /// Rounded to whole degrees, which is all the accuracy a forecast has.
    public func temperatureLabel(_ celsius: Double) -> String {
        "\(Int(temperature(celsius).rounded()))°"
    }
}

/// The half that goes out to the network.
///
/// Synchronous and blocking on purpose: the callers run it on a worker thread
/// and hand the result back through the frame loop, which is the pattern the
/// rest of this codebase uses and is far easier to reason about than an async
/// context that has to be bridged into a UI that has no await points.
public struct WeatherService: Sendable {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 15) {
        self.timeout = timeout
    }

    public func forecast(for place: Place) throws -> Forecast {
        guard let url = OpenMeteo.forecastURL(for: place) else {
            throw WeatherError("Could not build a forecast URL for \(place.label)")
        }
        let data = try get(url)
        do {
            return try OpenMeteo.decodeForecast(data, place: place)
        } catch {
            throw WeatherError("The forecast service sent something unexpected")
        }
    }

    public func search(_ name: String) throws -> [Place] {
        guard let url = OpenMeteo.searchURL(name: name) else { return [] }
        let data = try get(url)
        do {
            return try OpenMeteo.decodePlaces(data)
        } catch {
            throw WeatherError("The place search sent something unexpected")
        }
    }

    /// Holds the callback's results so the `@Sendable` closure has somewhere
    /// to write them — the same shape `SpotifyCore.HTTP` uses, and for the
    /// same reason: Linux Foundation has no async `URLSession`.
    private final class Box: @unchecked Sendable {
        var data: Data?
        var status = 0
        var error: Error?
    }

    private func get(_ url: URL) throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("LavaWeather", forHTTPHeaderField: "User-Agent")

        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            box.error = error
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw WeatherError("The weather service did not answer")
        }
        if box.error != nil {
            // The system message here is "The Internet connection appears to
            // be offline", which is both long and usually wrong about the
            // cause. What the reader can act on is that it did not arrive.
            throw WeatherError("Could not reach the weather service")
        }
        guard let data = box.data, !data.isEmpty else {
            throw WeatherError("The weather service sent an empty answer")
        }
        guard (200..<300).contains(box.status) else {
            throw WeatherError("The weather service answered \(box.status)")
        }
        return data
    }
}
