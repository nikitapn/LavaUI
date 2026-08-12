import Foundation
import LavaUI
import Observation
import WeatherCore

/// Everything the window shows, and the one place that talks to the network.
///
/// The rule here is the one the rest of the codebase uses: fetches block on a
/// worker thread and results land back on the frame loop through
/// `MainQueue.async`, so every property below is only ever written from the
/// thread that draws. Observation then turns that write into a frame.
@Observable
final class WeatherSession: @unchecked Sendable {
    enum Status: Equatable {
        case idle
        case loading
        case failed(String)
    }

    private(set) var forecast: Forecast?
    private(set) var status: Status = .idle
    private(set) var place: Place
    var units: UnitSystem {
        didSet {
            guard units != oldValue else { return }
            AppSettings.set(units.rawValue, forKey: "units")
        }
    }

    /// The search field, and what it found. Empty results with a non-empty
    /// query is a real answer — "no such place" — and is shown as one.
    var query = ""
    private(set) var searchResults: [Place] = []
    private(set) var isSearching = false
    private(set) var searchedFor = ""

    var isSearchPresented = false

    private let service = WeatherService()
    /// Bumped on every request so a slow answer to an old question cannot
    /// overwrite a fast answer to the current one — the user changes city
    /// twice in a second and the first reply arrives last.
    private var generation = 0

    init() {
        let saved = AppSettings.value(forKey: "place", as: Place.self)
        place = saved ?? .fallback
        units = AppSettings.string(forKey: "units")
            .flatMap(UnitSystem.init(rawValue:)) ?? .metric
    }

    // MARK: - Loading

    func reload() {
        load(place)
    }

    func select(_ next: Place) {
        query = ""
        searchResults = []
        searchedFor = ""
        isSearchPresented = false
        AppSettings.set(next, forKey: "place")
        load(next)
    }

    private func load(_ next: Place) {
        place = next
        status = .loading
        generation += 1
        let token = generation
        let service = self.service
        Thread.detachNewThread { [service] in
            do {
                let result = try service.forecast(for: next)
                MainQueue.async { [weak self] in
                    self?.finish(token, .success(result))
                }
            } catch {
                let message = (error as? WeatherError)?.description
                    ?? "Could not load the forecast"
                MainQueue.async { [weak self] in self?.fail(token, message) }
            }
        }
    }

    private func finish(_ token: Int, _ result: Result<Forecast, Never>) {
        // A reply to a question nobody is asking any more.
        guard token == generation, case .success(let value) = result else { return }
        forecast = value
        place = value.place
        status = .idle
    }

    /// The previous forecast stays on screen: stale weather with a visible
    /// warning beats an empty window, and the reader can tell the difference
    /// because the message says so.
    private func fail(_ token: Int, _ message: String) {
        guard token == generation else { return }
        status = .failed(message)
    }

    // MARK: - Searching

    func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            searchResults = []
            searchedFor = ""
            return
        }
        isSearching = true
        generation += 1
        let token = generation
        let service = self.service
        Thread.detachNewThread { [service] in
            let found = (try? service.search(term)) ?? []
            MainQueue.async { [weak self] in
                guard let self, token == self.generation else { return }
                self.searchResults = found
                self.searchedFor = term
                self.isSearching = false
            }
        }
    }

    // MARK: - Derived

    var hours: [HourPoint] { forecast?.upcomingHours(24) ?? [] }
    var days: [DayForecast] { forecast?.daily ?? [] }

    var isStale: Bool {
        if case .failed = status { return forecast != nil }
        return false
    }

    var errorMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }
}
