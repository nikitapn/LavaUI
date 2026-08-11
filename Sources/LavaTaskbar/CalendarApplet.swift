import Foundation
import LavaUI

/// Clock label that opens a month calendar. Same popover + input-region
/// contract as the volume applet — `isOpen` is owned by the panel.
struct CalendarApplet: View {
    var clockText: String
    var isOpen: Binding<Bool>

    /// First day of the month currently shown. Local `@State` so paging does
    /// not force the panel session to know about calendars.
    @State private var visibleMonth: Date = CalendarMonth.startOfMonth(Date())

    var body: some View {
        let theme = Theme.current
        let open = isOpen

        Text(
            clockText,
            color: theme.textPrimary,
            onClick: {
                if !open.wrappedValue {
                    // Re-open on "today" so a left-over page is not sticky.
                    visibleMonth = CalendarMonth.startOfMonth(Date())
                }
                open.wrappedValue.toggle()
            }
        )
        .padding(4)
        .hoverBackground(theme.hover)
        .cornerRadius(3)
        .agentId("applet.calendar")
        .overlay(
            isPresented: isOpen,
            alignment: .below,
            style: OverlayStyle(padding: 12, minWidth: 260)
        ) {
            calendarPopover
        }
    }

    @ViewBuilder
    private var calendarPopover: some View {
        let theme = Theme.current
        let cal = Calendar.current
        let today = Date()
        let cells = CalendarMonth.cells(for: visibleMonth, calendar: cal)
        let title = CalendarMonth.monthTitle(visibleMonth, calendar: cal)
        let weekdays = CalendarMonth.weekdaySymbols(calendar: cal)

        VStack(padding: 2, spacing: 8) {
            // ── Header: prev / month / next ──────────────────────────────
            HStack(padding: 0, alignment: .center, spacing: 8) {
                Text(
                    "‹",
                    color: theme.accent,
                    onClick: {
                        visibleMonth = CalendarMonth.shift(visibleMonth, by: -1)
                    }
                )
                .padding(6)
                .hoverBackground(theme.hover)
                .cornerRadius(4)
                .agentId("calendar.prev")

                Spacer()
                Text(title, color: theme.textPrimary)
                Spacer()

                Text(
                    "›",
                    color: theme.accent,
                    onClick: {
                        visibleMonth = CalendarMonth.shift(visibleMonth, by: 1)
                    }
                )
                .padding(6)
                .hoverBackground(theme.hover)
                .cornerRadius(4)
                .agentId("calendar.next")
            }

            // ── Weekday strip ────────────────────────────────────────────
            HStack(padding: 0, alignment: .center, spacing: 0) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, name in
                    Text(name, color: theme.textDim)
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
                    onClick: {
                        visibleMonth = CalendarMonth.startOfMonth(Date())
                    }
                )
                .padding(4)
                .hoverBackground(theme.hover)
                .cornerRadius(3)
                .agentId("calendar.today")
            }
        }
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

        // Fixed cell so the grid stays rectangular regardless of digit width.
        Text(label, color: color)
            .frame(width: .pt(34), height: .pt(28))
            .background(fill ?? Color(r: 0, g: 0, b: 0, a: 0))
            .cornerRadius(6)
            .agentId(cell.id)
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
