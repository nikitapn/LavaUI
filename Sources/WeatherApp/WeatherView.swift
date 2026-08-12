import LavaUI
import WeatherCore

/// The window: a headline, the next twenty-four hours, and the week.
///
/// Three bands rather than a dashboard of tiles, because a forecast is read in
/// that order — what is it doing now, what is it doing later today, what about
/// the rest of the week — and each answer is wanted at a different glance
/// distance. The hero is large enough to read from across the room; the week
/// is a list you lean in for.
struct WeatherView: View {
    @Bindable var session: WeatherSession

    // A column stack that states its own width gets a panel fill from
    // `StackNode.apply` — the rule that makes a sidebar look like a sidebar.
    // Every container here is full width, so stating it would paint the whole
    // window `panel` and bury everything meant to sit on top of it. They
    // stretch to their parent instead, which is what a column does by default.
    var body: some View {
        VStack(flexGrow: 1, padding: 0, spacing: 0) {
            TitleBar(session: session)
            ScrollView {
                VStack(padding: 20, spacing: 18) {
                    Hero(session: session)
                    if !session.hours.isEmpty {
                        Section("NEXT 24 HOURS") { HourStrip(session: session) }
                    }
                    if !session.days.isEmpty {
                        Section("THIS WEEK") { WeekList(session: session) }
                    }
                }
            }
            .flexGrow(1)
        }
        .background(Theme.current.background)
        .overlay(
            isPresented: $session.isSearchPresented,
            placement: .viewport(inset: 64),
            style: OverlayStyle(
                background: Theme.current.panel.opacity(0.96),
                cornerRadius: 14,
                padding: 16,
                minWidth: 360,
                backdropBlurRadius: 10
            )
        ) {
            SearchPanel(session: session)
        }
    }
}

// MARK: - Chrome

private struct TitleBar: View {
    @Bindable var session: WeatherSession

    var body: some View {
        HStack(padding: 10, alignment: .center, spacing: 10) {
            if WindowBridge.drawsOwnChrome {
                WindowControls()
            }
            Text(session.place.name, color: Theme.current.textPrimary)
                .agentId("place-name")
            Text(session.place.country, color: Theme.current.textDim)
            Spacer()
            if session.status == .loading {
                Text("Updating…", color: Theme.current.textDim)
            }
            Text(
                session.units == .metric ? "°C" : "°F",
                color: Theme.current.textSecondary,
                onClick: { session.units = session.units == .metric ? .imperial : .metric }
            )
            .padding(6)
            .hoverBackground(Theme.current.hover)
            .cornerRadius(6)
            .agentId("units-toggle")
            Text("Search", color: .accent, onClick: { session.isSearchPresented = true })
                .padding(6)
                .hoverBackground(Theme.current.hover)
                .cornerRadius(6)
                .agentId("open-search")
            Text("Refresh", color: Theme.current.textSecondary, onClick: { session.reload() })
                .padding(6)
                .hoverBackground(Theme.current.hover)
                .cornerRadius(6)
                .agentId("refresh")
        }
        .frame(height: .pt(44))
        .background(Theme.current.panel)
        .windowDrag()
    }
}

/// A labelled band. One definition so the two lists cannot drift apart.
private struct Section<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(padding: 0, spacing: 8) {
            Text(title, color: Theme.current.textDim)
            content
        }
    }
}

// MARK: - Now

private struct Hero: View {
    @Bindable var session: WeatherSession

    var body: some View {
        let units = session.units
        return VStack(padding: 20, spacing: 10) {
            if let message = session.errorMessage {
                // Kept above the reading rather than replacing it: a stale
                // forecast is still worth something, and hiding it would make
                // a flaky connection look like a broken app.
                Text(
                    session.isStale ? "\(message) — showing the last reading" : message,
                    color: Color(r: 1.0, g: 0.55, b: 0.45)
                )
                .agentId("error")
            }
            if let current = session.forecast?.current {
                HStack(padding: 0, alignment: .center, spacing: 18) {
                    SkyIcon(sky: current.code.sky, isDay: current.isDay, size: 96)
                    VStack(padding: 0, spacing: 4) {
                        Text(
                            units.temperatureLabel(current.temperature),
                            color: Theme.current.textPrimary, font: Fonts.hero
                        )
                        .agentId("current-temp")
                        Text(current.code.summary, color: Theme.current.textSecondary)
                        Text(
                            "Feels like \(units.temperatureLabel(current.feelsLike))",
                            color: Theme.current.textDim
                        )
                    }
                    Spacer()
                    VStack(padding: 0, alignment: .end, spacing: 6) {
                        Detail("Humidity", "\(current.humidity)%")
                        Detail(
                            "Wind",
                            "\(Int(units.speed(current.windSpeed).rounded())) \(units.speedSuffix)"
                        )
                        Detail("Rain", String(format: "%.1f mm", current.precipitation))
                        if let today = session.days.first {
                            Detail("Sun", "\(today.sunrise) – \(today.sunset)")
                        }
                    }
                }
            } else if session.status == .loading {
                Text("Loading the forecast…", color: Theme.current.textSecondary)
            }
        }
        .background(Theme.current.panel)
        .cornerRadius(14)
    }
}

private struct Detail: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(padding: 0, alignment: .center, spacing: 8) {
            Text(label, color: Theme.current.textDim)
            Text(value, color: Theme.current.textSecondary)
        }
    }
}

// MARK: - Later today

private struct HourStrip: View {
    @Bindable var session: WeatherSession

    private static let iconSize: Float = 28
    private static let cardPadding: Float = 10
    private static let cardSpacing: Float = 6

    /// Tall enough for what is in a card, computed rather than guessed.
    ///
    /// A number picked by eye is right at one content scale and wrong at every
    /// other, and the way it fails is the last row silently clipped — which is
    /// exactly what it did: the chance-of-rain line lost its bottom half at
    /// 124pt while looking perfectly fine in the layout dump, because clipping
    /// happens in the scroll container and nothing above it is any the wiser.
    private var cardHeight: Float {
        let line = Environment.current.font?.lineHeight
            ?? FontStore.default?.lineHeight ?? 20
        // Three text rows, the icon, the gaps between the four, and the padding.
        return line * 3 + Self.iconSize + Self.cardSpacing * 3
            + Self.cardPadding * 2
    }

    var body: some View {
        let units = session.units
        // Horizontal scroll rather than squeezing twenty-four columns into the
        // width: at that size the numbers stop being readable, which is the
        // only thing the strip is for.
        return ScrollView(.horizontal, showsIndicator: false) {
            HStack(padding: 0, spacing: 6) {
                ForEach(Array(session.hours.enumerated()), id: \.offset) { entry in
                    let hour = entry.element
                    VStack(
                        width: .pt(64), height: .pt(cardHeight),
                        padding: Self.cardPadding, alignment: .center,
                        spacing: Self.cardSpacing
                    ) {
                        Text(hour.hourLabel, color: Theme.current.textDim)
                        SkyIcon(
                            sky: hour.code.sky,
                            isDay: isDaylight(hour),
                            size: Self.iconSize
                        )
                        Text(
                            units.temperatureLabel(hour.temperature),
                            color: Theme.current.textPrimary
                        )
                        Text(
                            hour.precipitationChance > 0 ? "\(hour.precipitationChance)%" : " ",
                            color: Color(r: 0.45, g: 0.72, b: 0.98)
                        )
                    }
                    .background(Theme.current.panel)
                    .cornerRadius(10)
                }
            }
        }
        .frame(height: .pt(cardHeight))
    }

    /// Daylight from the day's own sunrise and sunset rather than a fixed
    /// 6am–6pm: this app is as likely to be pointed at Tromsø as at Berlin.
    private func isDaylight(_ hour: HourPoint) -> Bool {
        guard let day = session.days.first(where: { $0.day == hour.day }),
              !day.sunrise.isEmpty, !day.sunset.isEmpty
        else { return true }
        return hour.time >= day.sunrise && hour.time <= day.sunset
    }
}

// MARK: - The week

private struct WeekList: View {
    @Bindable var session: WeatherSession

    var body: some View {
        let units = session.units
        let range = session.days.reduce(into: (lo: 99.0, hi: -99.0)) { acc, day in
            acc.lo = min(acc.lo, day.low)
            acc.hi = max(acc.hi, day.high)
        }
        return VStack(padding: 0, spacing: 4) {
            ForEach(Array(session.days.enumerated()), id: \.offset) { entry in
                let day = entry.element
                HStack(padding: 10, alignment: .center, spacing: 12) {
                    Text(
                        entry.offset == 0 ? "Today" : day.weekdayLabel,
                        color: Theme.current.textPrimary
                    )
                    .frame(width: .pt(56))
                    SkyIcon(sky: day.code.sky, size: 26)
                    Text(
                        day.precipitationChance > 0 ? "\(day.precipitationChance)%" : " ",
                        color: Color(r: 0.45, g: 0.72, b: 0.98)
                    )
                    .frame(width: .pt(44))
                    Text(day.code.summary, color: Theme.current.textDim)
                    Spacer()
                    Text(units.temperatureLabel(day.low), color: Theme.current.textDim)
                    TemperatureBar(day: day, lo: range.lo, hi: range.hi)
                    Text(units.temperatureLabel(day.high), color: Theme.current.textPrimary)
                }
                .background(Theme.current.panel)
                .cornerRadius(10)
            }
        }
    }
}

/// Where this day's low–high sits inside the week's own range.
///
/// The bar is the reason the week reads at a glance: seven pairs of numbers
/// are a table, and the same seven as offset bars are a shape you can see the
/// cold snap in.
private struct TemperatureBar: View {
    let day: DayForecast
    let lo: Double
    let hi: Double

    var body: some View {
        Canvas(
            label: "range \(day.day)",
            width: .pt(120),
            height: .pt(8),
            paint: { draw, frame in
                let span = max(1, hi - lo)
                let x0 = frame.x + Float((day.low - lo) / span) * frame.w
                let x1 = frame.x + Float((day.high - lo) / span) * frame.w
                draw.roundedRect(
                    x: frame.x, y: frame.y + 2, w: frame.w, h: 4,
                    color: Theme.current.inset, radius: 2
                )
                draw.roundedRect(
                    x: x0, y: frame.y, w: max(4, x1 - x0), h: 8,
                    color: Color(r: 0.98, g: 0.68, b: 0.32), radius: 4
                )
            }
        )
    }
}

// MARK: - Choosing a place

private struct SearchPanel: View {
    @Bindable var session: WeatherSession

    var body: some View {
        VStack(padding: 0, spacing: 10) {
            Text("Find a place", color: Theme.current.textPrimary)
            TextField(
                text: $session.query,
                placeholder: "City name",
                autoFocus: true,
                onSubmit: { session.search() }
            )
            .frame(width: .pct(100))
            .agentId("search-field")

            if session.isSearching {
                Text("Searching…", color: Theme.current.textDim)
            } else if session.searchResults.isEmpty, !session.searchedFor.isEmpty {
                Text("Nothing called “\(session.searchedFor)”.", color: Theme.current.textDim)
            }

            ScrollView {
                VStack(padding: 0, spacing: 2) {
                    ForEach(Array(session.searchResults.enumerated()), id: \.offset) { entry in
                        let found = entry.element
                        Text(
                            found.label, color: Theme.current.textSecondary,
                            onClick: { session.select(found) }
                        )
                        .frame(width: .pct(100))
                        .padding(8)
                        .hoverBackground(Theme.current.hover)
                        .cornerRadius(6)
                    }
                }
            }
            .flexGrow(1)

            HStack(padding: 0, spacing: 8) {
                Spacer()
                Text("Close", color: Theme.current.textDim, onClick: {
                    session.isSearchPresented = false
                })
                .padding(6)
            }
        }
    }
}

enum Fonts {
    /// The one place a size is named, so the headline cannot drift from what
    /// the rest of the window assumes about it.
    nonisolated(unsafe) static var hero: UIFont? = nil
}
