import CoveCore
import SwiftUI

struct AssistantAgenda {
  struct Day: Identifiable {
    let date: Date
    let events: [LocalEvent]
    var id: Date { date }
  }
  let start: Date
  let end: Date
  let events: [LocalEvent]
  let totalCount: Int
  let now: Date
  let timeZone: TimeZone
  var sample = false
  var calendar: Calendar { var value = Calendar.current; value.timeZone = timeZone; return value }
  var days: [Day] {
    var date = calendar.startOfDay(for: start)
    var result: [Day] = []
    while date < end, result.count < 32 {
      let items = CalendarAgenda.events(events, on: date, calendar: calendar)
      if !items.isEmpty { result.append(Day(date: date, events: items)) }
      guard let next = calendar.date(byAdding: .day, value: 1, to: date), next > date else { break }
      date = next
    }
    return result
  }
  var singleDay: Bool { calendar.isDate(start, inSameDayAs: end.addingTimeInterval(-0.001)) }
  var title: String {
    if singleDay {
      if calendar.isDate(start, inSameDayAs: now) { return "Today’s schedule" }
      if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(start, inSameDayAs: tomorrow) { return "Tomorrow’s schedule" }
      return "Your schedule"
    }
    return "Your schedule"
  }
  var dateLabel: String {
    if singleDay { return format(start, template: "EEEE MMM d") }
    return format(start, template: "MMM d") + " – " + format(end.addingTimeInterval(-0.001), template: "MMM d yyyy")
  }
  var zoneLabel: String {
    timeZone.secondsFromGMT(for: start) == timeZone.secondsFromGMT(for: end.addingTimeInterval(-0.001))
      ? timeZone.abbreviation(for: start) ?? timeZone.identifier : timeZone.identifier
  }
  var rangeLabel: String? {
    guard singleDay, let interval = calendar.dateInterval(of: .day, for: start), start != interval.start || end != interval.end else { return nil }
    return format(start, template: "jmm") + " – " + format(end, template: "jmm")
  }
  var summary: String {
    let allDay = events.filter { $0.allDay == true }.count
    return "\(totalCount) \(totalCount == 1 ? "event" : "events")" + (allDay > 0 ? " · \(allDay) all day" : "")
  }
  var coverage: String { sample ? "Sample calendar · on this Mac" : "Checked your primary Google Calendar and events saved in Cove." }
  var plainText: String {
    let sections = days.map { day in
      let rows = day.events.map { "• \(timeLabel($0, on: day.date)) — \($0.title)\(overlaps($0, on: day) ? " (overlaps another event)" : "")" }.joined(separator: "\n")
      return (singleDay ? "" : format(day.date, template: "EEEE MMM d") + "\n") + rows
    }
    return ([title + " · " + dateLabel + " · " + zoneLabel, rangeLabel, summary,
             events.isEmpty ? "No events found in this range." : sections.joined(separator: "\n\n"),
             totalCount > events.count ? "Showing the first \(events.count) of \(totalCount) events." : nil, coverage]
      .compactMap { $0 }).joined(separator: "\n\n")
  }
  func format(_ date: Date, template: String) -> String {
    let formatter = DateFormatter(); formatter.timeZone = timeZone
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter.string(from: date)
  }
  func timeLabel(_ event: LocalEvent, on day: Date) -> String {
    if event.allDay == true { return "All day" }
    let dayStart = calendar.startOfDay(for: day)
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? event.end
    if event.start < dayStart {
      return event.end >= dayEnd ? "Continues all day" : "Until " + format(event.end, template: "jmm")
    }
    let from = format(event.start, template: "jmm")
    if event.end > dayEnd { return from + " onward" }
    if event.end == dayEnd { return from + " – midnight" }
    if timeZone.secondsFromGMT(for: event.start) != timeZone.secondsFromGMT(for: event.end) {
      return format(event.start, template: "jmmz") + " – " + format(event.end, template: "jmmz")
    }
    let interval = DateIntervalFormatter()
    interval.timeZone = timeZone; interval.dateStyle = .none; interval.timeStyle = .short
    return interval.string(from: event.start, to: event.end)
  }
  func overlaps(_ event: LocalEvent, on day: Day) -> Bool {
    guard event.allDay != true, event.blocksTime != false, event.ownResponse != "declined" else { return false }
    return day.events.contains {
      $0.id != event.id && $0.allDay != true && $0.blocksTime != false && $0.ownResponse != "declined"
        && $0.start < event.end && $0.end > event.start
    }
  }
}

struct AssistantAgendaView: View {
  let agenda: AssistantAgenda
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 6) {
        Text(agenda.title).font(.coveDetailTitle).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
        Text(agenda.dateLabel + " · " + agenda.zoneLabel).font(.coveText).foregroundStyle(Palette.body)
        if let range = agenda.rangeLabel { Text(range).font(.coveSecondary).foregroundStyle(Palette.body) }
        Text(agenda.summary).font(.coveSecondary).foregroundStyle(Palette.muted)
      }
      if agenda.events.isEmpty {
        Label("No events found in this range.", systemImage: "calendar")
          .font(.coveBody).foregroundStyle(Palette.body).padding(.vertical, 16)
      }
      ForEach(agenda.days) { day in
        VStack(alignment: .leading, spacing: 0) {
          if !agenda.singleDay {
            Text(agenda.format(day.date, template: "EEEE MMM d")).font(.coveSubheading)
              .padding(.bottom, 10).accessibilityAddTraits(.isHeader)
          }
          ForEach(day.events) { event in
            eventRow(event, day: day)
            Divider()
          }
        }
      }
      if agenda.totalCount > agenda.events.count {
        Text("Showing the first \(agenda.events.count) of \(agenda.totalCount) events. Ask about a shorter range to see more.")
          .font(.coveMetadata).foregroundStyle(Palette.body)
      }
      Label(agenda.coverage, systemImage: "checkmark.circle")
        .font(.coveMetadata).foregroundStyle(Palette.muted)
    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
  }
  private func eventRow(_ event: LocalEvent, day: AssistantAgenda.Day) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 18) {
        time(event, day: day).frame(width: 146, alignment: .leading)
        details(event, day: day).frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
      }
      VStack(alignment: .leading, spacing: 7) { time(event, day: day); details(event, day: day) }
    }.padding(.vertical, 13).frame(maxWidth: .infinity, alignment: .leading)
  }
  private func time(_ event: LocalEvent, day: AssistantAgenda.Day) -> some View {
    Text(agenda.timeLabel(event, on: day.date)).font(.coveControl).monospacedDigit()
      .foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
  }
  private func details(_ event: LocalEvent, day: AssistantAgenda.Day) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(event.title.isEmpty ? "Untitled event" : event.title).font(.coveSubheading)
        .foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
      if agenda.overlaps(event, on: day) {
        Label("Overlaps another event", systemImage: "rectangle.on.rectangle")
          .font(.coveMetadata).foregroundStyle(Palette.body)
      }
      if event.ownResponse == "needsAction" { Text("Awaiting your response").font(.coveMetadata).foregroundStyle(Palette.muted) }
      if event.ownResponse == "declined" { Text("Declined").font(.coveMetadata).foregroundStyle(Palette.muted) }
    }
  }
}
