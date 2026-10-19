import SwiftUI

/// A calendar of appointments and deadlines from DEAN's schedule file, so the 상황판 does not have
/// to be opened just to look at it. Three weeks show at once and it scrolls a week at a time.
/// Classes are left out on purpose: they are on the timetable already.
/// The list below is one day — today unless another day is tapped — with that day's
/// appointments, deadlines and to-dos (2026-10-19).
struct CalendarPane: View {
    let schedule: ScheduleService
    let accent: Color

    /// Weeks kept above this one, to scroll back to.
    private static let weeksBefore = 8
    private static let weekCount = 30
    private static let visibleWeeks = 3
    private static let weekdays = ["월", "화", "수", "목", "금", "토", "일"]
    private static let cellHeight: CGFloat = 29
    private static let rowSpacing: CGFloat = 2

    /// The tapped day; nil is today.
    @State private var selected: Date?
    /// Monday of the week at the top of the grid.
    @State private var topWeek: Date?
    private let thisWeek: Date
    private let weeks: [[Date]]

    init(schedule: ScheduleService, accent: Color, now: Date = .now) {
        self.schedule = schedule
        self.accent = accent
        weeks = ScheduleService.weeks(from: now, before: Self.weeksBefore, count: Self.weekCount)
        thisWeek = weeks[Self.weeksBefore][0]
        _topWeek = State(initialValue: thisWeek)
    }

    var body: some View {
        let now = Date.now
        let day = selected ?? now

        VStack(alignment: .leading, spacing: 5) {
            header

            VStack(spacing: Self.rowSpacing) {
                HStack(spacing: 2) {
                    ForEach(Array(Self.weekdays.enumerated()), id: \.offset) { index, name in
                        Text(name)
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(index == 6 ? accent.opacity(0.7) : .white.opacity(0.3))
                            .frame(maxWidth: .infinity)
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: Self.rowSpacing) {
                            ForEach(weeks, id: \.first) { week in
                                HStack(spacing: 2) {
                                    ForEach(week, id: \.self) { date in
                                        dayCell(date, now: now)
                                    }
                                }
                                .id(week[0])
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: $topWeek, anchor: .top)
                    // The binding alone does not move a fresh scroll view; start on this week.
                    .onAppear { proxy.scrollTo(thisWeek, anchor: .top) }
                    .frame(height: Self.cellHeight * CGFloat(Self.visibleWeeks)
                           + Self.rowSpacing * CGFloat(Self.visibleWeeks - 1))
                }
            }

            Divider().overlay(.white.opacity(0.08))

            dayList(day, now: now)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .animation(.easeInOut(duration: 0.15), value: selected)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Text(Self.rangeTitle(from: topWeek ?? thisWeek, weeks: Self.visibleWeeks))
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .monospacedDigit()
            if topWeek != thisWeek || selected != nil {
                Button("오늘") {
                    selected = nil
                    withAnimation(.easeInOut(duration: 0.25)) { topWeek = thisWeek }
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(.white.opacity(0.1)))
            }
            Spacer(minLength: 0)
            if schedule.fileMissing {
                Text("일정 파일 없음")
                    .font(.system(size: 9.5))
                    .foregroundStyle(accent.opacity(0.9))
                    .help(ScheduleService.dataURL.path)
            } else if schedule.isStale {
                Text("오래된 자료")
                    .font(.system(size: 9.5))
                    .foregroundStyle(accent.opacity(0.9))
                    .help("상황판 동기화(sync_all.py)가 하루 넘게 돌지 않았습니다")
            }
            Legend(color: accent, filled: true, label: "마감")
            Legend(color: .white.opacity(0.8), filled: false, label: "약속")
        }
    }

    // MARK: Grid

    private func dayCell(_ day: Date, now: Date) -> some View {
        let calendar = Calendar.current
        let isToday = calendar.isDate(day, inSameDayAs: now)
        let isPast = day < calendar.startOfDay(for: now)
        let isSelected = selected.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let items = schedule.items(on: day)
        let deadlines = items.filter { $0.kind == .deadline }.count
        let appointments = items.filter { $0.kind == .appointment && !$0.spansDays }.count
        let period = items.contains { $0.spansDays }
        let dayNumber = calendar.component(.day, from: day)
        let isSunday = calendar.component(.weekday, from: day) == 1

        return VStack(spacing: 2) {
            Text(dayNumber == 1 ? "\(calendar.component(.month, from: day))/1" : "\(dayNumber)")
                .font(.system(size: 11, weight: isToday ? .bold : .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isToday ? .white : isSunday ? accent.opacity(isPast ? 0.3 : 0.8)
                                 : .white.opacity(isPast ? 0.25 : 0.82))
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 15)
                .background { if isToday { Capsule().fill(accent) } }

            HStack(spacing: 2.5) {
                ForEach(0..<min(deadlines, 3), id: \.self) { _ in
                    Circle().fill(accent).frame(width: 4, height: 4)
                }
                ForEach(0..<min(appointments, 3 - min(deadlines, 3)), id: \.self) { _ in
                    Circle().stroke(.white.opacity(0.8), lineWidth: 1).frame(width: 4, height: 4)
                }
            }
            .frame(height: 4)
            .opacity(isPast ? 0.35 : 1)
        }
        .frame(maxWidth: .infinity, minHeight: Self.cellHeight, maxHeight: Self.cellHeight)
        .background(alignment: .bottom) {
            // A period (application window, trip) runs as a thin line under the days it covers.
            if period {
                Rectangle().fill(.white.opacity(isPast ? 0.12 : 0.28)).frame(height: 1.5)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.white.opacity(isSelected ? 0.14 : 0.035))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(.white.opacity(0.3), lineWidth: 1)
                    }
                }
        }
        .contentShape(Rectangle())
        .onTapGesture { selected = isSelected || isToday ? nil : day }
        .help(items.isEmpty ? Self.dayTitle(day) : items.map { Self.line(for: $0) }.joined(separator: "\n"))
    }

    // MARK: Day list

    private func dayList(_ day: Date, now: Date) -> some View {
        let isToday = Calendar.current.isDate(day, inSameDayAs: now)
        let items = schedule.items(on: day)
        let todos = schedule.todos(on: day, now: now)

        return VStack(alignment: .leading, spacing: 3) {
            Text((isToday ? "오늘 · " : "") + Self.dayTitle(day))
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .tracking(0.3)
                .foregroundStyle(isToday ? accent.opacity(0.95) : .white.opacity(0.5))

            if items.isEmpty && todos.isEmpty {
                Text(isToday ? "오늘은 약속·마감·할 일 없음" : "이날은 약속·마감·할 일 없음")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(items) { item in
                            itemRow(item)
                        }
                        ForEach(todos) { todo in
                            todoRow(todo, now: now)
                        }
                    }
                }
            }
        }
    }

    private func itemRow(_ item: ScheduleService.Item) -> some View {
        HStack(spacing: 7) {
            Group {
                if item.kind == .deadline {
                    Circle().fill(accent)
                } else {
                    Circle().stroke(.white.opacity(0.8), lineWidth: 1)
                }
            }
            .frame(width: 5, height: 5)
            .frame(width: 10)

            Text(item.title)
                .font(.system(size: 11.5, weight: item.kind == .deadline ? .medium : .regular))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Text(Self.when(item))
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize()
        }
        .padding(.vertical, 2.5)
        .padding(.horizontal, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.045)))
        .help(Self.line(for: item))
    }

    private func todoRow(_ todo: ScheduleService.ToDo, now: Date) -> some View {
        let late = todo.date.map { ScheduleService.daysLeft($0, from: now) < 0 } ?? false
        return HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2)
                .stroke(.white.opacity(0.45), lineWidth: 1)
                .frame(width: 8, height: 8)
                .frame(width: 10)

            Text(todo.title)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if late, let date = todo.date {
                Text("밀림 \(Calendar.current.component(.month, from: date))/\(Calendar.current.component(.day, from: date))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(accent.opacity(0.8))
                    .fixedSize()
            }
        }
        .padding(.vertical, 2.5)
        .padding(.horizontal, 5)
        .help("[할 일] " + todo.title + " — 미리 알림 「오늘 할 일」")
    }

    // MARK: Text

    /// Time on the right of a row: "18:00", "~10/23" for a period, "" for all day.
    static func when(_ item: ScheduleService.Item) -> String {
        if item.spansDays {
            let calendar = Calendar.current
            return "~\(calendar.component(.month, from: item.end))/\(calendar.component(.day, from: item.end))"
        }
        return item.time
    }

    static func line(for item: ScheduleService.Item) -> String {
        let kind = item.kind == .deadline ? "마감" : "약속"
        let time = when(item)
        return "[\(kind)] \(item.title)" + (time.isEmpty ? "" : " · \(time)")
    }

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        return "\(calendar.component(.month, from: day))월 \(calendar.component(.day, from: day))일 \(weekday(day))요일"
    }

    /// "10/19 – 11/8" for the weeks on screen.
    static func rangeTitle(from monday: Date, weeks: Int) -> String {
        let calendar = Calendar.current
        let last = calendar.date(byAdding: .day, value: weeks * 7 - 1, to: monday) ?? monday
        return "\(calendar.component(.month, from: monday))/\(calendar.component(.day, from: monday))"
            + " – \(calendar.component(.month, from: last))/\(calendar.component(.day, from: last))"
    }

    static func weekday(_ date: Date) -> String {
        ["일", "월", "화", "수", "목", "금", "토"][Calendar.current.component(.weekday, from: date) - 1]
    }
}

private struct Legend: View {
    let color: Color
    let filled: Bool
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Group {
                if filled { Circle().fill(color) } else { Circle().stroke(color, lineWidth: 1) }
            }
            .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}
