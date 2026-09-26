import CoveCore
import SwiftUI

struct CalendarMonthView: View {
  let events: [LocalEvent]
  let day: Date
  let selectedID: String?
  let selectDay: (Date) -> Void
  let selectEvent: (LocalEvent, Date) -> Void
  private var days: [Date] { CalendarAgenda.monthDays(containing: day) }

  private var selectedRow: Int {
    (days.firstIndex { Calendar.current.isDate($0, inSameDayAs: day) } ?? 0) / 7
  }

  var body: some View {
    GeometryReader { geometry in
      let rowHeight = max(112, (geometry.size.height - 36) / 6)
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          ForEach(Array(days.prefix(7)), id: \.self) { date in
            Text(date, format: .dateTime.weekday(.abbreviated))
              .font(.coveCaption).foregroundStyle(Palette.muted)
              .frame(maxWidth: .infinity).frame(height: 36)
          }
        }
        ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 0) {
            ForEach(0..<6) { row in
              HStack(spacing: 0) {
                ForEach(Array(days.dropFirst(row * 7).prefix(7)), id: \.self) { date in
                  CalendarMonthDay(
                    day: date, inMonth: Calendar.current.isDate(date, equalTo: day, toGranularity: .month),
                    selected: Calendar.current.isDate(date, inSameDayAs: day),
                    events: CalendarAgenda.events(events, on: date), selectedID: selectedID,
                    rowHeight: rowHeight, showTimes: geometry.size.width >= 770, selectDay: { selectDay(date) },
                    selectEvent: { selectEvent($0, date) })
                    .frame(maxWidth: .infinity).frame(height: rowHeight)
                    .overlay(alignment: .leading) { CalendarRule(vertical: true) }
                }
              }.id(row).overlay(alignment: .top) { CalendarRule() }
            }
          }
        }
        .onAppear { proxy.scrollTo(selectedRow, anchor: .center) }
        .onChange(of: day) { _, _ in proxy.scrollTo(selectedRow, anchor: .center) }
        }
      }
    }.accessibilityLabel("Month calendar")
  }
}

private struct CalendarMonthDay: View {
  let day: Date
  let inMonth: Bool
  let selected: Bool
  let events: [LocalEvent]
  let selectedID: String?
  let rowHeight: Double
  let showTimes: Bool
  let selectDay: () -> Void
  let selectEvent: (LocalEvent) -> Void
  @State private var hovered = false
  private var today: Bool { Calendar.current.isDateInToday(day) }
  private var limit: Int { max(1, min(4, Int((rowHeight - 58) / 24))) }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Button(action: selectDay) {
        HStack {
          Text(day, format: .dateTime.day())
            .font(today || selected ? .coveControl : .coveSecondary)
            .frame(width: 26, height: 26)
            .background(today ? Palette.ink : selected ? Palette.selection : .clear, in: Circle())
            .foregroundStyle(today ? .white : inMonth ? Palette.ink : Palette.muted)
          Spacer(minLength: 0)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted) + ", \(events.count) events")
        .accessibilityAddTraits(selected ? .isSelected : [])
      ForEach(Array(events.prefix(limit))) { event in
        CalendarMonthEvent(event: event, day: day, selected: selectedID == event.id,
                           showTime: showTimes) { selectEvent(event) }
      }
      if events.count > limit {
        Button("+\(events.count - limit) more", action: selectDay)
          .buttonStyle(.plain).font(.coveCaption).foregroundStyle(Palette.body)
          .padding(.horizontal, 4)
          .accessibilityLabel("Show all \(events.count) events on " + day.formatted(date: .complete, time: .omitted))
      }
      Button(action: selectDay) { Color.clear.contentShape(Rectangle()) }
        .buttonStyle(.plain).accessibilityHidden(true)
        .frame(maxHeight: .infinity)
    }.padding(5)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(selected || hovered ? Palette.surface : inMonth ? Palette.canvas : Palette.surface.opacity(0.5))
      .onHover { hovered = $0 }
  }
}

private struct CalendarMonthEvent: View {
  let event: LocalEvent
  let day: Date
  let selected: Bool
  let showTime: Bool
  let action: () -> Void
  @State private var hovered = false
  private var time: String {
    event.start < Calendar.current.startOfDay(for: day)
      ? "↳" : event.start.formatted(.dateTime.hour().minute())
  }
  private var description: String {
    event.title + ", " + (event.allDay == true ? "All day" : event.start.formatted(date: .abbreviated, time: .shortened))
  }
  private var fill: Color {
    selected ? Palette.ink : hovered ? Palette.selection : event.allDay == true ? Palette.sidebar : .clear
  }
  var body: some View {
    Button(action: action) {
      HStack(spacing: 3) {
        if event.allDay != true && showTime {
          Text(time).font(.coveMetadata).monospacedDigit()
            .foregroundStyle(selected ? Color.white : Palette.body).fixedSize()
        }
        Text(event.title).font(.coveCaption).lineLimit(1)
        Spacer(minLength: 0)
      }.padding(.horizontal, 4).frame(height: 21)
        .foregroundStyle(selected ? Color.white : Palette.ink)
        .background(fill, in: RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
    }.buttonStyle(.plain).onHover { hovered = $0 }
      .help(description).accessibilityLabel(description)
  }
}
