import Foundation
import LavaUI
import Observation

/// Which month the calendar shows, shared with the year beside it: a month
/// picked there turns this page. Reset to today whenever the calendar opens,
/// so paging only lasts as long as the popup does.
@Observable
final class CalendarModel {
    /// First day of the month on the page.
    var visibleMonth: Date = CalendarMonth.startOfMonth(Date())
    /// The year the year window shows.
    var year: Int = Calendar.current.component(.year, from: Date())
    /// The day picked on the page; nil is today.
    var selected: Date?

    func reset() {
        visibleMonth = CalendarMonth.startOfMonth(Date())
        year = Calendar.current.component(.year, from: Date())
        selected = nil
    }
}

/// The month: a page of days under the month's name, today on the accent,
/// a picked day on its wash, and the picked day spelled out at the foot.
struct CalendarWindow: View {
    static let padding: Float = 14
    static let cell: Float = 38
    static let gap: Float = 2
    static let dayHeight: Float = 36
    static let headerHeight: Float = 32
    static let weekdayHeight: Float = 21
    static let footerHeight: Float = 10 + 1 + 10 + 27

    static var width: Float { padding * 2 + cell * 7 + gap * 6 + 2 }
    static var height: Float {
        padding * 2 + headerHeight + 8 + weekdayHeight + gap
            + dayHeight * 6 + gap * 5 + footerHeight
    }

    var model: CalendarModel

    var body: some View {
        let palette = PopupPalette.current
        let fonts = popupFonts!
        let model = model
        let visibleMonth = model.visibleMonth
        let cal = Calendar.current
        let today = Date()
        let selected = model.selected ?? today
        let cells = CalendarMonth.cells(for: visibleMonth, calendar: cal)
        let title = CalendarMonth.monthTitle(visibleMonth, calendar: cal)
        let weekdays = CalendarMonth.weekdayColumns(calendar: cal)
        let yearOpen = session.yearWindow.map { LavaApp.isWindowOpen($0) } ?? false

        return PopupCard(padding: Self.padding) {
            // ── Header: prev / month (opens the year) / next ─────────────
            HStack(height: .pt(Self.headerHeight), padding: 0, alignment: .center, spacing: 4) {
                CardIconButton(icon: [.path(PanelIcons.chevronLeft)], size: 32, glyph: 15,
                               color: palette.accent700, hover: palette.bar.accentSoft,
                               agentId: "calendar.prev") {
                    model.visibleMonth = CalendarMonth.shift(visibleMonth, by: -1)
                }
                HStack(flexGrow: 1, height: .pt(Self.headerHeight - 2), padding: 0,
                       alignment: .center, spacing: 6, onClick: { session.toggleYear() }) {
                    Spacer()
                    Text(title, color: palette.bar.accentInk, font: fonts.heading18)
                    Icon(yearOpen ? PanelIcons.chevronLeft : PanelIcons.chevronRight,
                         size: 12, color: palette.bar.accentInk, strokeWidth: 3)
                    Spacer()
                }
                .background(yearOpen ? palette.bar.accentSoft : .clear)
                .hoverBackground(palette.bar.accentSoft)
                .cornerRadius((Self.headerHeight - 2) / 2)
                .cursor(.pointer)
                .agentId("calendar.title")
                CardIconButton(icon: [.path(PanelIcons.chevronRight)], size: 32, glyph: 15,
                               color: palette.accent700, hover: palette.bar.accentSoft,
                               agentId: "calendar.next") {
                    model.visibleMonth = CalendarMonth.shift(visibleMonth, by: 1)
                }
            }
            .padding(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))

            // ── Weekday strip ────────────────────────────────────────────
            HStack(padding: 0, alignment: .center, spacing: Self.gap) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, day in
                    Text(day.letter, color: day.weekend ? palette.accent700 : palette.neutral700,
                         font: fonts.weekday, align: .center)
                        .frame(width: .pt(Self.cell), height: .pt(Self.weekdayHeight))
                }
            }
            .padding(EdgeInsets(top: 0, leading: 0, bottom: Self.gap, trailing: 0))

            // ── Day grid ─────────────────────────────────────────────────
            VStack(padding: 0, spacing: Self.gap) {
                ForEach(Array(cells.chunked(into: 7).enumerated()), id: \.offset) { _, week in
                    HStack(padding: 0, alignment: .center, spacing: Self.gap) {
                        ForEach(week) { cell in
                            dayCell(cell, today: today, selected: selected, palette: palette,
                                    calendar: cal)
                        }
                    }
                }
            }

            // ── Footer: the picked day, and back to today ─────────────────
            VStack(padding: 0, spacing: 0) {
                CardDivider()
                HStack(padding: 0, alignment: .center, spacing: 8) {
                    Text(Self.longDate(selected, calendar: cal), color: palette.bar.textSoft,
                         font: fonts.small13)
                    Spacer()
                    PillButton(title: "Today", agentId: "calendar.today") {
                        model.reset()
                    }
                }
                .padding(EdgeInsets(top: 10, leading: 8, bottom: 0, trailing: 4))
            }
            .padding(EdgeInsets(top: 10, leading: 0, bottom: 0, trailing: 0))
        }
        .agentId("calendar.window")
    }

    @ViewBuilder
    private func dayCell(
        _ cell: CalendarMonth.DayCell, today: Date, selected: Date,
        palette: PopupPalette, calendar: Calendar
    ) -> some View {
        let fonts = popupFonts!
        let isToday = cell.date.map { calendar.isDate($0, inSameDayAs: today) } ?? false
        let isPicked = !isToday && (cell.date.map { calendar.isDate($0, inSameDayAs: selected) } ?? false)
        let weekend = cell.date.map { calendar.isDateInWeekend($0) } ?? false
        let label = cell.day.map(String.init) ?? ""
        let color: Color = {
            if cell.day == nil { return .clear }
            if isToday { return palette.bar.onAccent }
            if !cell.inMonth { return palette.neutral600 }
            if isPicked || weekend { return palette.bar.accentInk }
            return palette.bar.text
        }()
        let font = isToday || isPicked ? fonts.body14Bold
            : fonts.body14
        let fill: Color = isToday ? palette.bar.accent : isPicked ? palette.bar.accentSoft : .clear
        let hover: Color = isToday ? palette.bar.accentHover
            : isPicked ? palette.bar.accentSoft : palette.rowHover
        let model = model
        let date = cell.date

        // Fixed cell so the grid stays rectangular regardless of digit width,
        // the number placed in the middle by `Text(align:)` — which moves the
        // pen inside the cell rather than wrapping it in a box of its own.
        Text(label, color: color, font: font,
             hoverFill: date == nil ? .clear : hover,
             cornerRadius: CalendarWindow.dayHeight / 2, align: .center,
             onClick: {
                 guard let date else { return }
                 model.selected = date
                 if !cell.inMonth { model.visibleMonth = CalendarMonth.startOfMonth(date) }
             })
            .frame(width: .pt(CalendarWindow.cell), height: .pt(CalendarWindow.dayHeight))
            .background(fill)
            .cornerRadius(CalendarWindow.dayHeight / 2)
            .agentId(cell.id)
    }

    /// "Thursday, 19 November".
    static func longDate(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f.string(from: date)
    }
}

/// The whole year: twelve months, every day of each, in four columns, the
/// ISO week down each month's side. A popup of the calendar, to its left,
/// opened from the month title; a month's name turns the calendar to it.
struct YearWindow: View {
    var model: CalendarModel

    static let columns = 4
    static let paddingX: Float = 18
    static let paddingTop: Float = 14
    static let paddingBottom: Float = 18
    static let columnGap: Float = 14
    static let rowGap: Float = 6
    static let headerHeight: Float = 32
    static let cell: (w: Float, h: Float) = (19.5, 20)
    static let monthPadding: Float = 6
    static let monthTitleHeight: Float = 23

    static var monthWidth: Float { monthPadding * 2 + cell.w * 8 }
    /// Title, weekday strip, six weeks: every month the same height, so a
    /// row of them lines up whatever day each starts on.
    static var monthHeight: Float { monthPadding * 2 + monthTitleHeight + cell.h * 7 }
    static var width: Float {
        paddingX * 2 + monthWidth * Float(columns) + columnGap * Float(columns - 1) + 2
    }
    static var height: Float {
        let rows = Float(12 / columns)
        return paddingTop + paddingBottom + headerHeight + 10
            + monthHeight * rows + rowGap * (rows - 1) + 2
    }

    var body: some View {
        let palette = PopupPalette.current
        let fonts = popupFonts!
        let cal = Calendar.current
        let model = model
        let year = model.year
        let today = Date()
        let weekdays = CalendarMonth.weekdayColumns(calendar: cal)
        let months = (1...12).compactMap { cal.date(from: DateComponents(year: year, month: $0)) }
        let rows = stride(from: 0, to: 12, by: Self.columns).map {
            Array(months[$0..<min($0 + Self.columns, 12)])
        }

        return PopupCard(padding: 0) {
            VStack(padding: 0, spacing: Self.rowGap) {
                HStack(height: .pt(Self.headerHeight), padding: 0, alignment: .center, spacing: 8) {
                    CardIconButton(icon: [.path(PanelIcons.chevronLeft)], size: 32, glyph: 15,
                                   color: palette.accent700, hover: palette.bar.accentSoft,
                                   agentId: "year.prev") { model.year -= 1 }
                    Text(String(year), color: palette.bar.text, font: fonts.heading22,
                         align: .center)
                        .flexGrow(1)
                        .agentId("year.title")
                    CardIconButton(icon: [.path(PanelIcons.chevronRight)], size: 32, glyph: 15,
                                   color: palette.accent700, hover: palette.bar.accentSoft,
                                   agentId: "year.next") { model.year += 1 }
                }
                .padding(EdgeInsets(top: 0, leading: 0, bottom: 10 - Self.rowGap, trailing: 0))

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(padding: 0, alignment: .start, spacing: Self.columnGap) {
                        ForEach(row, id: \.self) { month in
                            monthBlock(month, today: today, weekdays: weekdays,
                                       palette: palette, calendar: cal)
                        }
                    }
                }
            }
            .padding(EdgeInsets(top: Self.paddingTop, leading: Self.paddingX,
                                bottom: Self.paddingBottom, trailing: Self.paddingX))
        }
        .agentId("year.window")
    }

    private func monthBlock(
        _ month: Date, today: Date, weekdays: [CalendarMonth.WeekdayColumn],
        palette: PopupPalette, calendar: Calendar
    ) -> some View {
        let fonts = popupFonts!
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
        let weeks = CalendarMonth.cells(for: month, calendar: calendar).chunked(into: 7)
        return VStack(padding: Self.monthPadding, spacing: 0) {
            HStack(height: .pt(Self.monthTitleHeight), padding: 0, alignment: .center) {
                Text(f.string(from: month),
                     color: shown || current ? palette.accent700 : palette.bar.text,
                     font: fonts.body14Bold, hoverFill: palette.rowHover,
                     onClick: {
                         model.visibleMonth = month
                         session.closeYear()
                     })
                    .padding(EdgeInsets(top: 2, leading: 6, bottom: 4, trailing: 6))
                    .cornerRadius(10)
                    .agentId("year.month.\(calendar.component(.month, from: month))")
                Spacer()
            }
            HStack(padding: 0, alignment: .center, spacing: 0) {
                Text("", color: palette.neutral700)
                    .frame(width: .pt(Self.cell.w), height: .pt(Self.cell.h))
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, day in
                    Text(day.letter, color: palette.neutral700, font: fonts.weekday, align: .center)
                        .frame(width: .pt(Self.cell.w), height: .pt(Self.cell.h))
                }
            }
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(padding: 0, alignment: .center, spacing: 0) {
                    Text(CalendarMonth.isoWeek(of: week).map(String.init) ?? "",
                         color: palette.neutral700, font: fonts.week10, align: .center)
                        .frame(width: .pt(Self.cell.w), height: .pt(Self.cell.h))
                    ForEach(week) { cell in
                        miniDay(cell, today: today, palette: palette, calendar: calendar)
                    }
                }
            }
            Spacer()
        }
        .frame(width: .pt(Self.monthWidth), height: .pt(Self.monthHeight))
        .background(shown ? palette.rowHover : .clear)
        .cornerRadius(16)
    }

    private func miniDay(
        _ cell: CalendarMonth.DayCell, today: Date, palette: PopupPalette, calendar: Calendar
    ) -> some View {
        let fonts = popupFonts!
        let isToday = cell.inMonth && (cell.date.map { calendar.isDate($0, inSameDayAs: today) } ?? false)
        let weekend = cell.date.map { calendar.isDateInWeekend($0) } ?? false
        let label = cell.inMonth ? cell.day.map(String.init) ?? "" : ""
        let color = isToday ? palette.bar.onAccent : weekend ? palette.bar.accentInk : palette.bar.text
        return Text(label, color: color, font: isToday ? fonts.small13Semi : fonts.caption12Tabular,
                    align: .center)
            .frame(width: .pt(Self.cell.w), height: .pt(Self.cell.h))
            .background(isToday ? palette.bar.accent : .clear)
            .cornerRadius(Self.cell.h / 2)
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

    /// A column of the week: its letter, and whether it is the weekend.
    struct WeekdayColumn {
        var letter: String
        var weekend: Bool
    }

    /// The week's columns in calendar order, weekends marked by the
    /// calendar's own idea of them rather than by position.
    static func weekdayColumns(calendar: Calendar = .current) -> [WeekdayColumn] {
        let letters = weekdaySymbols(calendar: calendar)
        // Any week will do: a Sunday-first one, rotated as the letters are.
        let sunday = calendar.date(from: DateComponents(year: 2023, month: 1, day: 1)) ?? Date()
        return letters.enumerated().map { index, letter in
            let weekday = (calendar.firstWeekday - 1 + index) % 7
            let day = calendar.date(byAdding: .day, value: weekday, to: sunday) ?? sunday
            return WeekdayColumn(letter: letter, weekend: calendar.isDateInWeekend(day))
        }
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
