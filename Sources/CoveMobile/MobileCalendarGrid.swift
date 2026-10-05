#if os(iOS)
import CoveCore
import SwiftUI

/// The Mac's week grid on iPad: day columns, an hour gutter, quiet guides (line at 50%, half hours at
/// 22%), an all-day row, overlapping events side by side and the current-time marker. It opens near
/// the current hour; scrolling stays with the user afterwards.
struct MobileWeekGrid: View {
  let days: [Date]
  let workspace: MobileWorkspace
  @Binding var selected: Date
  let open: (LocalEvent) -> Void

  private let hourHeight: CGFloat = 54
  private let gutter: CGFloat = 54
  private var calendar: Calendar { Calendar.current }

  var body: some View {
    VStack(spacing: 0) {
      header
      allDayRow
      Divider().overlay(MobilePalette.line)
      ScrollViewReader { proxy in
        ScrollView {
          TimelineView(.everyMinute) { context in
            grid(now: context.date)
          }
        }
        // Opens near the current hour; the user scrolls freely from there.
        .defaultScrollAnchor(UnitPoint(x: 0.5, y: min(1, max(0, Double(calendar.component(.hour, from: Date()) - 2) / 18))))
      }
    }
    .background(MobilePalette.canvas)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(MobilePalette.line))
  }

  private var header: some View {
    HStack(spacing: 0) {
      Color.clear.frame(width: gutter, height: 48)
      ForEach(days, id: \.self) { day in
        let today = calendar.isDateInToday(day)
        let isSelected = calendar.isDate(day, inSameDayAs: selected)
        Button { selected = calendar.startOfDay(for: day) } label: {
          HStack(spacing: 6) {
            Text(day, format: .dateTime.weekday(.abbreviated)).font(.mobileSecondary)
              .foregroundStyle(MobilePalette.body)
            Text(day, format: .dateTime.day()).font(.coveMobile(15, weight: today ? .semibold : .medium))
              .foregroundStyle(today ? Color.white : MobilePalette.ink)
              .frame(minWidth: 28, minHeight: 28)
              .background(today ? MobilePalette.ink : .clear, in: Circle())
          }
          .frame(maxWidth: .infinity).frame(height: 48)
          .background(isSelected && !today ? MobilePalette.surface : .clear)
          .contentShape(Rectangle())
        }.buttonStyle(.plain)
          .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
      }
    }
    .overlay(alignment: .bottom) { Divider().overlay(MobilePalette.line) }
  }

  @ViewBuilder private var allDayRow: some View {
    let hasAllDay = days.contains { day in workspace.events(on: day).contains { $0.allDay == true } }
    if hasAllDay {
      HStack(alignment: .top, spacing: 0) {
        Text("All day").font(.mobileMetadata).foregroundStyle(MobilePalette.muted).frame(width: gutter)
        ForEach(days, id: \.self) { day in
          VStack(spacing: 3) {
            ForEach(workspace.events(on: day).filter { $0.allDay == true }) { event in
              Button { open(event) } label: {
                Text(event.title).font(.mobileCaption).lineLimit(1).foregroundStyle(MobilePalette.ink)
                  .padding(.horizontal, 6).padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading)
                  .background(MobilePalette.sidebar, in: RoundedRectangle(cornerRadius: 4))
              }.buttonStyle(.plain)
            }
          }.padding(3).frame(maxWidth: .infinity)
        }
      }.padding(.vertical, 4)
    }
  }

  private func grid(now: Date) -> some View {
    HStack(alignment: .top, spacing: 0) {
      VStack(spacing: 0) {
        ForEach(0..<24, id: \.self) { hour in
          Text(hour == 0 ? "" : (calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date())
                .formatted(.dateTime.hour()))
            .font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
            .frame(width: gutter - 8, height: hourHeight, alignment: .topTrailing)
            .offset(y: -7).id(hour)
        }
      }.frame(width: gutter)
      ForEach(days, id: \.self) { day in
        dayColumn(day, now: now)
      }
    }
  }

  private func dayColumn(_ day: Date, now: Date) -> some View {
    let start = calendar.startOfDay(for: day)
    let events = workspace.events(on: day).filter { $0.allDay != true }
    let lanes = Self.lanes(events)
    return GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        // Guides
        ForEach(0..<24, id: \.self) { hour in
          Rectangle().fill(MobilePalette.line.opacity(0.5)).frame(height: 1).offset(y: CGFloat(hour) * hourHeight)
          Rectangle().fill(MobilePalette.line.opacity(0.22)).frame(height: 1).offset(y: CGFloat(hour) * hourHeight + hourHeight / 2)
        }
        Rectangle().fill(MobilePalette.line.opacity(0.5)).frame(width: 1, height: hourHeight * 24)
        // Events
        ForEach(events) { event in
          let lane = lanes[event.id] ?? (0, 1)
          let top = max(0, event.start.timeIntervalSince(start)) / 3600 * hourHeight
          let bottom = min(24 * 3600, event.end.timeIntervalSince(start)) / 3600 * hourHeight
          let width = (geometry.size.width - 6) / CGFloat(lane.1)
          Button { open(event) } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(event.title.isEmpty ? "(No title)" : event.title).font(.mobileCaption).foregroundStyle(MobilePalette.ink)
                .lineLimit(bottom - top > 40 ? 2 : 1)
              if bottom - top > 34 {
                Text(event.start.formatted(date: .omitted, time: .shortened)).font(.mobileMetadata).foregroundStyle(MobilePalette.body)
              }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .frame(width: max(20, width - 4), height: max(22, bottom - top - 2), alignment: .topLeading)
            .background(event.isPendingInvitation ? MobilePalette.canvas : MobilePalette.mailSelection,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(event.isPendingInvitation ? MobilePalette.inputBorder : MobilePalette.line,
                                                              style: StrokeStyle(lineWidth: 1, dash: event.isPendingInvitation ? [3, 2] : [])))
            .opacity(event.end < now ? 0.6 : 1)
          }
          .buttonStyle(.plain)
          .offset(x: 3 + CGFloat(lane.0) * width, y: top + 1)
          .accessibilityLabel("\(event.title), \(event.start.formatted(date: .omitted, time: .shortened))")
        }
        // Current time
        if calendar.isDate(day, inSameDayAs: now) {
          let y = now.timeIntervalSince(start) / 3600 * hourHeight
          HStack(spacing: 0) {
            Circle().fill(MobilePalette.ink).frame(width: 7, height: 7)
            Rectangle().fill(MobilePalette.ink).frame(height: 1.5)
          }.offset(x: -3, y: y - 3.5).accessibilityHidden(true)
        }
      }
    }
    .frame(height: hourHeight * 24)
    .frame(maxWidth: .infinity)
  }

  /// Overlapping events share the column side by side: (lane, lane count) per event.
  static func lanes(_ events: [LocalEvent]) -> [String: (Int, Int)] {
    let sorted = events.sorted { $0.start < $1.start }
    var result: [String: (Int, Int)] = [:]
    var cluster: [LocalEvent] = []
    var laneEnds: [Date] = []
    var clusterEnd = Date.distantPast
    func flush() {
      for event in cluster { if let lane = result[event.id] { result[event.id] = (lane.0, laneEnds.count) } }
      cluster = []
      laneEnds = []
    }
    for event in sorted {
      if event.start >= clusterEnd { flush() }
      if let free = laneEnds.firstIndex(where: { $0 <= event.start }) {
        laneEnds[free] = event.end
        result[event.id] = (free, 0)
      } else {
        laneEnds.append(event.end)
        result[event.id] = (laneEnds.count - 1, 0)
      }
      cluster.append(event)
      clusterEnd = max(clusterEnd, event.end)
    }
    flush()
    return result
  }
}

/// The Mac's month grid on iPad: Monday first, six weeks, event titles in each day and the selected
/// day's agenda beside it.
struct MobileMonthGrid: View {
  let workspace: MobileWorkspace
  @Binding var selected: Date
  let open: (LocalEvent) -> Void

  private var calendar: Calendar {
    var calendar = Calendar.current
    calendar.firstWeekday = 2
    return calendar
  }

  var body: some View {
    let days = CalendarAgenda.monthDays(containing: selected, calendar: calendar)
    let month = calendar.component(.month, from: selected)
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) {
          Text($0).font(.mobileMetadata).foregroundStyle(MobilePalette.muted).frame(maxWidth: .infinity).padding(.vertical, 8)
        }
      }
      Divider().overlay(MobilePalette.line)
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
        ForEach(days, id: \.self) { day in
          cell(day, inMonth: calendar.component(.month, from: day) == month)
        }
      }
    }
    .background(MobilePalette.canvas)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(MobilePalette.line))
  }

  private func cell(_ day: Date, inMonth: Bool) -> some View {
    let events = workspace.events(on: day)
    let today = calendar.isDateInToday(day)
    let isSelected = calendar.isDate(day, inSameDayAs: selected)
    return Button { selected = calendar.startOfDay(for: day) } label: {
      VStack(alignment: .leading, spacing: 3) {
        Text(day, format: .dateTime.day()).font(.coveMobile(13, weight: today ? .semibold : .regular))
          .foregroundStyle(today ? Color.white : inMonth ? MobilePalette.ink : MobilePalette.disabledText)
          .frame(minWidth: 24, minHeight: 24)
          .background(today ? MobilePalette.ink : .clear, in: Circle())
        ForEach(events.prefix(3)) { event in
          Text(event.title).font(.mobileMetadata).lineLimit(1).foregroundStyle(MobilePalette.ink)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(event.allDay == true ? MobilePalette.sidebar : .clear, in: RoundedRectangle(cornerRadius: 3))
            .onTapGesture { open(event) }
        }
        if events.count > 3 {
          Text("+\(events.count - 3) more").font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
        }
        Spacer(minLength: 0)
      }
      .padding(6)
      .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
      .background(isSelected ? MobilePalette.surface : MobilePalette.canvas)
      .overlay(Rectangle().stroke(MobilePalette.line.opacity(0.6), lineWidth: 0.5))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(day.formatted(date: .complete, time: .omitted) + (events.isEmpty ? "" : ", \(events.count) events"))
  }
}
#endif
