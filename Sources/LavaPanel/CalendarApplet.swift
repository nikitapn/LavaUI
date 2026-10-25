import Foundation
import LavaUI
import Observation

/// Clock label. The month grid is a popup of its own — the strip is 32pt,
/// and a calendar does not fit there.
struct CalendarApplet: View {
    var clockText: String

    var body: some View {
        let theme = Theme.current

        Text(
            clockText,
            color: theme.textPrimary,
            onClick: { session.toggleCalendar() }
        )
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        .hoverBackground(PanelChrome.style.titleHover)
        .cornerRadius(6)
        .agentId("applet.calendar")
    }
}

/// Which month the calendar shows, shared with the year beside it: a month
/// picked there turns this page. Reset to today whenever the calendar opens,
/// so paging only lasts as long as the popup does.
@Observable
final class CalendarModel {
    /// First day of the month on the page.
    var visibleMonth: Date = CalendarMonth.startOfMonth(Date())
    /// The year the year window shows.
    var year: Int = Calendar.current.component(.year, from: Date())

    func reset() {
        visibleMonth = CalendarMonth.startOfMonth(Date())
        year = Calendar.current.component(.year, from: Date())
    }
}

/// The month grid.
///
/// Same glass as the volume card. `WindowBackdrop` is the whole process
/// and the panel is `.none`, so the wash has to be this view's.
struct CalendarWindow: View {
    static let width: Float = 276
    static let height: Float = 320

    var model: CalendarModel

    var body: some View {
        let theme = Theme.current
        let model = model
        let visibleMonth = model.visibleMonth
        let cal = Calendar.current
        let today = Date()
        let cells = CalendarMonth.cells(for: visibleMonth, calendar: cal)
        let title = CalendarMonth.monthTitle(visibleMonth, calendar: cal)
        let weekdays = CalendarMonth.weekdaySymbols(calendar: cal)

        VStack(padding: 2, spacing: 8) {
            // ── Header: prev / month / next ──────────────────────────────
            HStack(padding: 0, alignment: .center, spacing: 8) {
                CalendarArrow(pointing: .left, id: "calendar.prev") {
                    model.visibleMonth = CalendarMonth.shift(visibleMonth, by: -1)
                }

                Spacer()
                // The whole year, beside this window.
                let yearOpen = session.yearWindow.map { LavaApp.isWindowOpen($0) } ?? false
                Text(
                    title,
                    color: yearOpen ? theme.accent : theme.textPrimary,
                    onClick: { session.toggleYear() }
                )
                .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                .cornerRadius(4)
                .agentId("calendar.title")
                Spacer()

                CalendarArrow(pointing: .right, id: "calendar.next") {
                    model.visibleMonth = CalendarMonth.shift(visibleMonth, by: 1)
                }
            }

            // ── Weekday strip ────────────────────────────────────────────
            HStack(padding: 0, alignment: .center, spacing: 0) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, name in
                    Text(name, color: theme.textDim, align: .center)
                        .frame(width: .pt(34), height: .pt(22))
                }
            }

            // ── Day grid ─────────────────────────────────────────────────
            VStack(padding: 0, spacing: 2) {
                ForEach(Array(cells.chunked(into: 7).enumerated()), id: \.offset) { _, week in
                    HStack(padding: 0, alignment: .center, spacing: 0) {
                        ForEach(week) { cell in
                            dayCell(cell, today: today, theme: theme, calendar: cal)
                        }
                    }
                }
            }

            // ── Today shortcut ───────────────────────────────────────────
            HStack(padding: 0, alignment: .center) {
                Spacer()
                Text(
                    "Today",
                    color: theme.accent,
                    onClick: { model.reset() }
                )
                .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                .hoverBackground(theme.hover)
                .cornerRadius(3)
                .agentId("calendar.today")
            }
        }
        .padding(12)
        .frame(width: .pt(Self.width), height: .pt(Self.height))
        .background(PanelChrome.popupWash)
        .agentId("calendar.window")
    }

    @ViewBuilder
    private func dayCell(
        _ cell: CalendarMonth.DayCell,
        today: Date,
        theme: Theme,
        calendar: Calendar
    ) -> some View {
        let isToday = cell.date.map { calendar.isDate($0, inSameDayAs: today) } ?? false
        let label = cell.day.map(String.init) ?? ""
        let color: Color = {
            if cell.day == nil { return theme.textDim.opacity(0.01) }
            if isToday { return theme.background }
            if cell.inMonth { return theme.textPrimary }
            return theme.textDim
        }()
        let fill: Color? = isToday ? theme.accent : nil

        // Fixed cell so the grid stays rectangular regardless of digit width,
        // and the number placed in the middle of it rather than at its leading
        // edge — which is where a `Text` starts, and where the highlight drawn
        // around today would otherwise catch it sitting.
        //
        // `Text(align:)` rather than `.frame(…, alignment:)`, which is what
        // this was: the frame's alignment centres by wrapping the text in a
        // box it does not own, and a month grid is forty-two of those plus
        // seven in the weekday strip. This places the glyphs inside the cell
        // that already exists and adds none.
        Text(label, color: color, align: .center)
            .frame(width: .pt(34), height: .pt(28))
            .background(fill ?? Color(r: 0, g: 0, b: 0, a: 0))
            .cornerRadius(6)
            .agentId(cell.id)
    }
}

/// Previous / next, for a month or a year: a drawn chevron, since the font's
/// "‹" is a third of the line high and sits on the baseline. The click is the
/// stack's, padded first so it is one node — the hover box and the target are
/// the same rectangle.
private struct CalendarArrow: View {
    let pointing: Chevron.Direction
    let id: String
    let action: () -> Void

    var body: some View {
        HStack(padding: 0, alignment: .center, onClick: action) {
            Chevron(pointing: pointing, color: Theme.current.accent)
        }
        .padding(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
        .hoverBackground(Theme.current.hover)
        .cornerRadius(4)
        .agentId(id)
    }
}

/// The whole year: twelve months, every day of each, in four columns. A
/// popup of the calendar window, to its left, opened from the month title.
/// Click a month's name and the calendar turns to it.
struct YearWindow: View {
    var model: CalendarModel

    static let columns = 4
    static let cell: (w: Float, h: Float) = (26, 20)
    /// The ISO week number down each month's left side.
    static let weekColumn: Float = 24
    static let padding: Float = 16
    static let columnGap: Float = 18
    static let rowGap: Float = 14
    static let headerHeight: Float = 34
    static let monthTitleHeight: Float = 24
    static let weekdayHeight: Float = 18

    static var monthWidth: Float { weekColumn + cell.w * 7 }
    /// Title, weekday strip, six weeks: every month the same height, so a
    /// row of them lines up whatever day each starts on.
    static var monthHeight: Float { monthTitleHeight + weekdayHeight + cell.h * 6 }
    static var width: Float {
        padding * 2 + monthWidth * Float(columns) + columnGap * Float(columns - 1)
    }
    static var height: Float {
        let rows = Float(12 / columns)
        return padding * 2 + headerHeight + rowGap + monthHeight * rows + rowGap * (rows - 1)
    }

    var body: some View {
        let theme = Theme.current
        let cal = Calendar.current
        let model = model
        let year = model.year
        let today = Date()
        let weekdays = CalendarMonth.weekdaySymbols(calendar: cal)
        let months = (1...12).compactMap { cal.date(from: DateComponents(year: year, month: $0)) }
        let rows = stride(from: 0, to: 12, by: Self.columns).map { Array(months[$0..<min($0 + Self.columns, 12)]) }

        VStack(padding: 0, spacing: Self.rowGap) {
            HStack(padding: 0, alignment: .center, spacing: 8) {
                CalendarArrow(pointing: .left, id: "year.prev") { model.year -= 1 }
                Spacer()
                Text(String(year), color: theme.textPrimary)
                    .agentId("year.title")
                Spacer()
                if year != cal.component(.year, from: today) {
                    Text("This year", color: theme.accent,
                         onClick: { model.year = cal.component(.year, from: Date()) })
                        .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                        .hoverBackground(theme.hover)
                        .cornerRadius(3)
                        .agentId("year.today")
                }
                CalendarArrow(pointing: .right, id: "year.next") { model.year += 1 }
            }
            .frame(height: .pt(Self.headerHeight))

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(padding: 0, alignment: .start, spacing: Self.columnGap) {
                    ForEach(row, id: \.self) { month in
                        monthBlock(month, today: today, weekdays: weekdays, calendar: cal)
                    }
                }
            }
        }
        .padding(Self.padding)
        .frame(width: .pt(Self.width), height: .pt(Self.height))
        .background(PanelChrome.popupWash)
        .agentId("year.window")
    }


    private func monthBlock(
        _ month: Date, today: Date, weekdays: [String], calendar: Calendar
    ) -> some View {
        let theme = Theme.current
        let model = model
        let shown = calendar.isDate(month, equalTo: model.visibleMonth, toGranularity: .month)
        let current = calendar.isDate(month, equalTo: today, toGranularity: .month)
        let f = DateFormatter()
        f.locale = .current
        f.calendar = calendar
        f.dateFormat = "LLLL"
        // Days outside the month are left out: in a page of twelve, the
        // neighbours' days are noise, where a single month uses them to fill
        // its first and last week.
        let cells = CalendarMonth.cells(for: month, calendar: calendar)
        let weeks = cells.chunked(into: 7)
        return VStack(padding: 0, spacing: 0) {
            HStack(padding: 0, alignment: .center) {
                Text(
                    f.string(from: month),
                    color: shown || current ? theme.accent : theme.textPrimary,
                    onClick: {
                        model.visibleMonth = month
                        session.closeYear()
                    }
                )
                .padding(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
                .cornerRadius(4)
                .agentId("year.month.\(calendar.component(.month, from: month))")
                Spacer()
            }
            .frame(height: .pt(Self.monthTitleHeight))
            HStack(padding: 0, alignment: .center, spacing: 0) {
                Text("", color: theme.textDim)
                    .frame(width: .pt(Self.weekColumn), height: .pt(Self.weekdayHeight))
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, name in
                    Text(name, color: theme.textDim, align: .center)
                        .frame(width: .pt(Self.cell.w), height: .pt(Self.weekdayHeight))
                }
            }
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(padding: 0, alignment: .center, spacing: 0) {
                    Text(CalendarMonth.isoWeek(of: week).map(String.init) ?? "",
                         color: theme.textDim.opacity(0.7), align: .center)
                        .frame(width: .pt(Self.weekColumn), height: .pt(Self.cell.h))
                    ForEach(week) { cell in
                        miniDay(cell, today: today, calendar: calendar)
                    }
                }
            }
        }
        .frame(width: .pt(Self.monthWidth), height: .pt(Self.monthHeight))
    }

    private func miniDay(_ cell: CalendarMonth.DayCell, today: Date, calendar: Calendar) -> some View {
        let theme = Theme.current
        let isToday = cell.inMonth && (cell.date.map { calendar.isDate($0, inSameDayAs: today) } ?? false)
        let label = cell.inMonth ? cell.day.map(String.init) ?? "" : ""
        return Text(label, color: isToday ? theme.background : theme.textPrimary, align: .center)
            .frame(width: .pt(Self.cell.w), height: .pt(Self.cell.h))
            .background(isToday ? theme.accent : Color(r: 0, g: 0, b: 0, a: 0))
            .cornerRadius(5)
    }
}

// MARK: - Month math

enum CalendarMonth {
    struct DayCell: Identifiable {
        var id: String
        var day: Int?
        var date: Date?
        var inMonth: Bool
    }

    /// The ISO 8601 week a row of the grid is, for the column beside it:
    /// that of its Monday, which in a Sunday-first grid is the second cell.
    /// Nil for a row with no day of the month in it — the sixth row of a
    /// short month, left blank in the year view.
    static func isoWeek(of week: [DayCell]) -> Int? {
        guard week.contains(where: \.inMonth) else { return nil }
        let iso = Calendar(identifier: .iso8601)
        let monday = week.compactMap(\.date).first { iso.component(.weekday, from: $0) == 2 }
        guard let day = monday ?? week.compactMap(\.date).first else { return nil }
        return iso.component(.weekOfYear, from: day)
    }

    static func startOfMonth(_ date: Date, calendar: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: parts) ?? date
    }

    static func shift(_ month: Date, by months: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .month, value: months, to: startOfMonth(month, calendar: calendar))
            ?? month
    }

    static func monthTitle(_ month: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = .current
        f.dateFormat = "LLLL yyyy"
        return f.string(from: startOfMonth(month, calendar: calendar))
    }

    /// Short weekday names in calendar order (locale firstWeekday).
    static func weekdaySymbols(calendar: Calendar = .current) -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        // `veryShortWeekdaySymbols` is Sunday-first; rotate to firstWeekday.
        let first = calendar.firstWeekday - 1 // 0-based
        guard first > 0, first < symbols.count else { return symbols }
        return Array(symbols[first...]) + Array(symbols[..<first])
    }

    /// Six weeks × 7 days covering `month`, including leading/trailing days
    /// from adjacent months so the grid is always a full rectangle.
    static func cells(for month: Date, calendar: Calendar = .current) -> [DayCell] {
        let start = startOfMonth(month, calendar: calendar)
        guard let dayRange = calendar.range(of: .day, in: .month, for: start),
              let firstWeekday = calendar.dateComponents([.weekday], from: start).weekday
        else { return [] }

        // Offset from the grid's first column (locale firstWeekday).
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7

        var cells: [DayCell] = []
        // Leading padding from previous month.
        if leading > 0, let prev = calendar.date(byAdding: .day, value: -leading, to: start) {
            for i in 0..<leading {
                if let d = calendar.date(byAdding: .day, value: i, to: prev) {
                    let day = calendar.component(.day, from: d)
                    cells.append(DayCell(
                        id: "pad-\(day)-\(i)",
                        day: day, date: d, inMonth: false
                    ))
                }
            }
        } else {
            for i in 0..<leading {
                cells.append(DayCell(id: "empty-\(i)", day: nil, date: nil, inMonth: false))
            }
        }

        for day in dayRange {
            guard let d = calendar.date(byAdding: .day, value: day - 1, to: start) else {
                continue
            }
            cells.append(DayCell(
                id: "d-\(day)",
                day: day, date: d, inMonth: true
            ))
        }

        // Trailing padding to complete whole weeks (at least 5 or 6 rows).
        while cells.count % 7 != 0 {
            let i = cells.count
            if let last = cells.last?.date,
               let d = calendar.date(byAdding: .day, value: 1, to: last)
            {
                let day = calendar.component(.day, from: d)
                cells.append(DayCell(
                    id: "trail-\(day)-\(i)",
                    day: day, date: d, inMonth: false
                ))
            } else {
                cells.append(DayCell(id: "trail-empty-\(i)", day: nil, date: nil, inMonth: false))
            }
        }
        // Prefer a stable 6-row grid when the month only fills 5 — matches
        // most desktop calendars and avoids the panel jumping height.
        while cells.count < 42 {
            let i = cells.count
            if let last = cells.last?.date,
               let d = calendar.date(byAdding: .day, value: 1, to: last)
            {
                let day = calendar.component(.day, from: d)
                cells.append(DayCell(
                    id: "trail2-\(day)-\(i)",
                    day: day, date: d, inMonth: false
                ))
            } else {
                cells.append(DayCell(id: "trail2-empty-\(i)", day: nil, date: nil, inMonth: false))
                break
            }
        }

        return cells
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        var out: [[Element]] = []
        var i = startIndex
        while i < endIndex {
            let j = index(i, offsetBy: size, limitedBy: endIndex) ?? endIndex
            out.append(Array(self[i..<j]))
            i = j
        }
        return out
    }
}
