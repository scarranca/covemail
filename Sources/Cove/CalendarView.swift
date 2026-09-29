import AppKit
import CoveCore
import SwiftUI

/// Calendar guides recede behind events; Increase Contrast restores stronger structure.
struct CalendarRule: View {
  var vertical = false
  var secondary = false
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    Rectangle()
      .fill(Palette.line.opacity(contrast == .increased ? 1 : secondary ? 0.22 : 0.5))
      .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

struct CalendarView: View {
  @Bindable var store: AppStore
  @State private var eventDraft: CalendarEventDraft?
  @State private var deleteTarget: LocalEvent?
  @State private var displayMode: CalendarDisplayMode
  @State private var scrollRequest = 0

  init(store: AppStore, mode: CalendarDisplayMode = .workweek) {
    self.store = store
    _displayMode = State(initialValue: mode)
  }
  @State private var showingSearch = false
  @AppStorage("calendar.agendaWidth") private var preferredAgendaWidth = 280.0
  private let focusSuggestionID = "cove-focus-suggestion"
  private var week: [Date] {
    let calendar = Calendar.current
    let monday = CalendarAgenda.weekStart(containing: store.calendarDay)
    return (0..<(displayMode == .week ? 7 : 5)).compactMap {
      calendar.date(byAdding: .day, value: $0, to: monday)
    }
  }
  private var visibleRange: DateInterval { displayMode.range(containing: store.calendarDay) }
  private var selected: LocalEvent? { store.events.first { $0.id == store.calendarEventID } }
  var body: some View {
    VStack(spacing: 0) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 20) {
          calendarHeading.fixedSize(horizontal: true, vertical: false)
          Spacer(minLength: 12)
          calendarControls.fixedSize(horizontal: true, vertical: false)
        }
        VStack(alignment: .leading, spacing: 18) {
          calendarHeading
          HStack {
            calendarControls
            Spacer(minLength: 0)
          }
        }
      }.padding(30).padding(.top, 22)
      CalendarRule()
      HStack {
        Label(
          focus == nil
            ? "A little breathing room. Make space for what matters."
            : "A little breathing room on \(store.calendarDay.formatted(.dateTime.month(.abbreviated).day())).",
          systemImage: "sparkles")
        Spacer()
        if let focus {
          Button {
            reviewFocus(focus)
          } label: {
            Label("Review focus time", systemImage: "arrow.right")
          }.buttonStyle(.plain).foregroundStyle(Palette.ink)
        } else {
          Text(
            store.calendarConnected && !store.isSample
              ? "Google Calendar + local" : "Local calendar"
          ).font(.coveMetadata)
        }
      }.font(.coveText).foregroundStyle(Palette.muted).padding(20).background(
        Palette.surface)
      CalendarRule()
      GeometryReader { geometry in
        let agendaWidth = CalendarLayout.agendaWidth(
          preferred: preferredAgendaWidth, available: geometry.size.width)
        HStack(spacing: 0) {
          Group {
            if displayMode == .month {
              CalendarMonthView(events: store.visibleEvents, day: store.calendarDay,
                selectedID: store.calendarEventID,
                selectDay: { store.selectCalendarDay($0) },
                selectEvent: { event, day in select(event, on: day) })
            } else {
              weekGrid
            }
          }.frame(minWidth: 340, maxWidth: .infinity)
          CalendarAgendaDivider(width: $preferredAgendaWidth, available: geometry.size.width)
          ScrollView {
            VStack(alignment: .leading, spacing: 20) {
              if let event = selected {
                Button {
                  store.calendarEventID = nil
                } label: {
                  Label("Day agenda", systemImage: "chevron.left")
                }.buttonStyle(.plain).font(.coveSecondary)
                Text(event.title).font(.coveDetailTitle)
                Label(event.calendarTitle, systemImage: "calendar")
                  .font(.coveMetadata).foregroundStyle(Palette.muted)
                Text(event.start, format: .dateTime.weekday().month().day())
                  .font(.coveText).foregroundStyle(Palette.muted)
                Text(event.allDay == true ? "All day" : timeRange(event.start, event.end))
                  .font(.coveText)
                if let location = event.location, !location.isEmpty {
                  Label(location, systemImage: "mappin.and.ellipse").font(.coveSecondary)
                }
                if let details = event.details, !details.isEmpty {
                  Text(details).font(.coveText).foregroundStyle(Palette.body)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if event.ownResponse != nil && event.isOrganizer != true {
                  InvitationResponseButtons(store: store, event: event)
                  if let error = store.invitationError { Text(error).font(.coveMetadata).foregroundStyle(Palette.danger) }
                  if let notice = store.invitationNotice { Text(notice).font(.coveMetadata).foregroundStyle(Palette.body) }
                }
                if let attendees = event.attendees, !attendees.isEmpty {
                  Text("Guests · \(attendees.count)").font(.coveLabel)
                  ForEach(Array(attendees.enumerated()), id: \.offset) { _, attendee in
                    VStack(alignment: .leading, spacing: 4) {
                      Text(attendee.name ?? attendee.email ?? "Guest").font(.coveSecondary)
                      Text(
                        attendee.response == "accepted"
                          ? "Accepted"
                          : attendee.response == "declined"
                            ? "Declined"
                            : attendee.response == "tentative" ? "Tentative" : "Awaiting response"
                      )
                      .font(.coveMetadata).foregroundStyle(Palette.muted)
                    }
                  }
                }
                if let mailID = event.mailID {
                  Button("View email") {
                    store.selectedID = mailID
                    store.screen = "mail"
                  }.buttonStyle(SecondaryButton())
                }
                if let link = event.meetURL, let url = URL(string: link), url.scheme == "https",
                  url.host == "meet.google.com"
                {
                  Link("Join Google Meet", destination: url).buttonStyle(SecondaryButton())
                }
                if let link = event.webURL, let url = URL(string: link), url.scheme == "https",
                  url.host == "google.com" || url.host?.hasSuffix(".google.com") == true
                {
                  Link("Open in Google Calendar", destination: url).buttonStyle(SecondaryButton())
                }
                if event.allDay != true {
                  Button("Edit event") { eventDraft = CalendarEventDraft(editing: event) }
                    .buttonStyle(SecondaryButton()).disabled(store.busy || store.calendarSyncing)
                }
                Button("Delete event", role: .destructive) { deleteTarget = event }
                  .buttonStyle(SecondaryButton()).disabled(store.busy || store.calendarSyncing)
              } else {
                agenda
              }
              CalendarRule()
              if !store.calendarConnected && !store.isSample {
                Button("Connect Google Calendar") { Task { await store.connectCalendar() } }
                  .buttonStyle(SecondaryButton()).disabled(store.busy)
              }
              if store.calendarConnected && !store.isSample {
                if let error = store.calendarSyncError {
                  Text("Calendar couldn’t sync. " + error).font(.coveSecondary)
                    .foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
                }
                Button(store.calendarSyncing ? "Syncing calendar…" : "Sync calendar") {
                  Task { await refresh() }
                }.buttonStyle(SecondaryButton()).disabled(store.calendarSyncing)
              }
              Label("Your time. Your call.", systemImage: "checkmark.shield")
                .font(.coveMetadata).foregroundStyle(Palette.muted)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
          }.frame(width: agendaWidth)
            .accessibilityLabel("Day agenda")
        }.coordinateSpace(name: "calendarPanes")
      }
    }
    .task(id: visibleRange) { await refresh() }
    .onChange(of: store.showNewEvent, initial: true) { _, value in
      if value {
        newEvent()
        store.showNewEvent = false
      }
    }
    .onChange(of: store.calendarDay, initial: true) { _, day in
      if displayMode == .workweek && Calendar.current.isDateInWeekend(day) { displayMode = .week }
    }
    .onChange(of: store.showLocalCalendar) { _, _ in clearHiddenSelection() }
    .onChange(of: store.hiddenLocalCalendars) { _, _ in clearHiddenSelection() }
    .onChange(of: store.showGoogleCalendar) { _, _ in clearHiddenSelection() }
    .onChange(of: displayMode) { _, value in
      if value == .workweek && Calendar.current.isDateInWeekend(store.calendarDay) {
        store.selectCalendarDay(CalendarAgenda.weekStart(containing: store.calendarDay))
      }
    }
    .onChange(of: store.calendarConnected) { _, _ in Task { await refresh() } }
    .confirmationDialog(
      "Delete this event?",
      isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    ) {
      Button("Delete event", role: .destructive) {
        if let event = deleteTarget {
          Task {
            await store.deleteEvent(event)
            store.calendarEventID = nil
          }
          deleteTarget = nil
        }
      }
    }
    .sheet(item: $eventDraft) { draft in
      CalendarEventEditor(store: store, draft: draft)
    }
  }
  private func scrollToTime(_ proxy: ScrollViewProxy) {
    proxy.scrollTo(CalendarLayout.scrollHour(now: Date(), selected: selected, on: store.calendarDay), anchor: .top)
  }
  private var weekGrid: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        Text(TimeZone.current.abbreviation() ?? "").font(.coveMetadata).foregroundStyle(
          Palette.muted
        ).frame(width: 52)
        ForEach(week, id: \.self) { day in
          Button {
            store.selectCalendarDay(day)
          } label: {
            VStack(spacing: 10) {
              Text(day, format: .dateTime.weekday(.abbreviated)).font(.coveMetadata)
                .foregroundStyle(Palette.muted)
              Text(day, format: .dateTime.day()).font(.coveDetailTitle).frame(
                width: 34, height: 34
              ).background(
                Calendar.current.isDateInToday(day) ? Palette.ink : .clear, in: Circle()
              ).foregroundStyle(Calendar.current.isDateInToday(day) ? .white : Palette.ink)
            }.frame(maxWidth: .infinity).padding(.vertical, 15)
              .background(
                Calendar.current.isDate(day, inSameDayAs: store.calendarDay)
                  ? Palette.surface : .clear)
          }.buttonStyle(.plain)
            .accessibilityLabel("Select " + day.formatted(date: .complete, time: .omitted))
        }
      }
      CalendarRule()
      HStack(spacing: 0) {
        Text("all-day").font(.coveMetadata).foregroundStyle(Palette.muted).frame(width: 52)
        ForEach(week, id: \.self) { day in
          VStack(spacing: 4) {
            ForEach(
              store.visibleEvents.filter {
                $0.allDay == true
                  && $0.start < Calendar.current.date(byAdding: .day, value: 1, to: day)!
                  && $0.end > day
              }
            ) { event in
              CalendarAllDayEvent(event: event, selected: store.calendarEventID == event.id) {
                select(event, on: day)
              }
            }
          }.frame(maxWidth: .infinity, minHeight: 32).padding(4)
            .overlay(alignment: .leading) { CalendarRule(vertical: true) }
        }
      }
      CalendarRule()
      ScrollViewReader { proxy in
        ScrollView {
          HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
              ForEach(0..<24) { hour in
                Text(
                  hour == 0
                    ? "12 AM"
                    : hour < 12 ? "\(hour) AM" : hour == 12 ? "12 PM" : "\(hour-12) PM"
                ).font(.coveMetadata).foregroundStyle(Palette.muted).frame(
                  width: 52, height: CalendarEventLayout.hourHeight, alignment: .top
                ).offset(y: 5).id(hour)
              }
            }
            ForEach(week, id: \.self) { day in
              CalendarDayColumn(
                events: gridEvents, day: day, selectedID: store.calendarEventID,
                suggestionID: focusSuggestionID
              ) { event in
                if event.id == focusSuggestionID {
                  reviewFocus(DateInterval(start: event.start, end: event.end))
                } else {
                  select(event, on: day)
                }
              }
              .frame(height: CalendarEventLayout.hourHeight * 24)
              .frame(maxWidth: .infinity)
            }
          }
        }
        .onAppear { scrollToTime(proxy) }
        .onChange(of: scrollRequest) { _, _ in
          proxy.scrollTo(CalendarLayout.scrollHour(now: Date(), on: store.calendarDay), anchor: .top)
        }
        .onChange(of: week[0]) { _, _ in scrollToTime(proxy) }
        .onChange(of: store.calendarEventID) { _, _ in
          if let selected, selected.allDay != true { scrollToTime(proxy) }
        }
      }
      CalendarRule()
      Text(
        store.calendarConnected && !store.isSample
          ? "Google Calendar · primary calendar" : "Calendar events stay on this Mac"
      ).font(.coveMetadata).foregroundStyle(Palette.muted).frame(
        maxWidth: .infinity, alignment: .leading
      ).padding(18)
    }
  }

  private var calendarHeading: some View {
    HStack(spacing: 20) {
      Text("Calendar").font(.coveTitle)
      Text(store.calendarDay, format: .dateTime.month(.wide).year()).font(.coveSection)
        .foregroundStyle(Palette.muted)
    }
  }

  private var calendarControls: some View {
    HStack(spacing: 16) {
      CoveMenuPicker(
        "Calendar view", selection: $displayMode,
        options: CalendarDisplayMode.allCases.map { ($0, $0.title) }
      )
      .frame(width: 124)
      Button("Today") {
        store.selectCalendarDay(Date())
        scrollRequest += 1
      }.buttonStyle(SecondaryButton())
      Button {
        movePeriod(-1)
      } label: {
        Image(systemName: "chevron.left")
      }.buttonStyle(.plain).help(displayMode == .month ? "Previous month" : "Previous week")
        .accessibilityLabel(displayMode == .month ? "Previous month" : "Previous week")
      Button {
        movePeriod(1)
      } label: {
        Image(systemName: "chevron.right")
      }.buttonStyle(.plain).help(displayMode == .month ? "Next month" : "Next week")
        .accessibilityLabel(displayMode == .month ? "Next month" : "Next week")
      Button {
        newEvent()
      } label: {
        Label("New event", systemImage: "plus")
      }.buttonStyle(PrimaryButton())
      Button {
        showingSearch = true
      } label: {
        Image(systemName: "magnifyingglass").frame(width: 24, height: 32)
      }.buttonStyle(.plain).help("Search saved events (⌘F)")
        .accessibilityLabel("Search calendar").keyboardShortcut("f")
        .popover(isPresented: $showingSearch) {
          CalendarSearchView(store: store) { event in
            store.revealCalendar(for: event)
            select(event, on: event.start)
            showingSearch = false
          }
        }
    }
  }

  private var dayEvents: [LocalEvent] {
    CalendarAgenda.events(store.visibleEvents, on: store.calendarDay)
  }
  private var focus: DateInterval? {
    guard store.calendarAvailabilityReady else { return nil }
    return CalendarAgenda.focusInterval(store.events, on: store.calendarDay, now: store.now)
  }
  private var gridEvents: [LocalEvent] {
    guard let focus else { return store.visibleEvents }
    var proposed = LocalEvent(
      title: "Focus time", start: focus.start, end: focus.end, localCalendar: .focus)
    proposed.id = focusSuggestionID
    return store.visibleEvents + [proposed]
  }
  private func reviewFocus(_ interval: DateInterval) {
    eventDraft = CalendarEventDraft(
      title: "Focus time", start: interval.start, end: interval.end, localCalendar: .focus)
  }
  private var agenda: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(store.calendarDay, format: .dateTime.weekday(.wide).month(.abbreviated).day())
        .font(.coveSection)
      let minutes = CalendarAgenda.scheduledMinutes(dayEvents, on: store.calendarDay)
      Text(
        "\(dayEvents.count) \(dayEvents.count == 1 ? "event" : "events") · \(minutes / 60)h \(minutes % 60)m scheduled"
      )
      .font(.coveMetadata).foregroundStyle(Palette.muted)
      if dayEvents.isEmpty {
        Text("No events in your visible calendars.").font(.coveText)
          .foregroundStyle(Palette.muted)
      }
      VStack(spacing: 0) {
        ForEach(Array(dayEvents.enumerated()), id: \.element.id) { index, event in
          CalendarAgendaEvent(
            event: event,
            status: event.id == nextEventID ? (event.start <= store.now ? "Now" : "Up next") : nil,
            time: event.allDay == true ? "All day" : timeRange(event.start, event.end)
          ) { select(event, on: store.calendarDay) }
          if index < dayEvents.count - 1 { CalendarRule() }
        }
      }
      CalendarRule()
      Text("Make room to focus").font(.coveSubheading)
      if let focus {
        Text(timeRange(focus.start, focus.end)).font(.coveLabel)
        Text(
          store.calendarConnected && !store.isSample
            ? "Available in your last sync of Google’s primary calendar and local events."
            : "Available in your saved local events."
        )
        .font(.coveSecondary).foregroundStyle(Palette.muted)
        Button("Block focus time") {
          reviewFocus(focus)
        }.buttonStyle(SecondaryButton())
      } else {
        Text(
          store.calendarAvailabilityReady
            ? "No hour-long opening left between 9 AM and 5 PM on this day."
            : "Sync this week to check availability in your primary Google calendar."
        )
        .font(.coveSecondary).foregroundStyle(Palette.muted)
      }
    }
  }
  private var nextEventID: String? {
    guard Calendar.current.isDateInToday(store.calendarDay) else { return nil }
    return dayEvents.first { $0.allDay != true && $0.end > store.now }?.id
  }
  private func timeRange(_ start: Date, _ end: Date) -> String {
    if Calendar.current.isDate(start, inSameDayAs: end) {
      return
        "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }
    return
      "\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .abbreviated, time: .shortened))"
  }
  private func select(_ event: LocalEvent, on day: Date) {
    store.selectCalendarDay(day)
    store.calendarEventID = event.id
  }
  private func clearHiddenSelection() {
    if !store.visibleEvents.contains(where: { $0.id == store.calendarEventID }) {
      store.calendarEventID = nil
    }
  }
  private func movePeriod(_ amount: Int) {
    store.selectCalendarDay(displayMode.moved(amount, from: store.calendarDay))
  }
  private func newEvent() {
    let start = Calendar.current.date(
      bySettingHour: 9, minute: 0, second: 0, of: store.calendarDay)!
    let proposed = Calendar.current.isDateInToday(store.calendarDay) ? max(start, Date()) : start
    eventDraft = CalendarEventDraft(start: proposed)
  }
  func refresh() async {
    await store.syncCalendar(
      from: visibleRange.start, to: visibleRange.end)
  }
}

/// Presentation geometry includes the minimum clickable height when assigning lanes.
/// This prevents a five-minute appointment from covering the appointment immediately after it.
enum CalendarEventLayout {
  static let hourHeight = 80.0
  static let gap = 4.0
  static let minimumHeight = 28.0
  struct Placement: Identifiable {
    var id: String { event.id }
    let event: LocalEvent
    let top: Double
    let height: Double
    var column: Int
    var columns: Int
  }
  static func arrange(_ events: [LocalEvent], on day: Date) -> [Placement] {
    let timed = CalendarLayout.arrange(events, on: day).sorted {
      $0.startMinute == $1.startMinute ? $0.id < $1.id : $0.startMinute < $1.startMinute
    }
    var output: [Placement] = []
    var group: [Placement] = []
    var ends: [Double] = []
    var groupEnd = -Double.infinity
    func flush() {
      output += group.map { var value = $0; value.columns = ends.count; return value }
      group = []; ends = []
    }
    for item in timed {
      let top = min(item.startMinute * hourHeight / 60, hourHeight * 24 - minimumHeight - gap)
      let height = max(minimumHeight, (item.endMinute - item.startMinute) * hourHeight / 60 - gap)
      if top >= groupEnd && !group.isEmpty { flush() }
      let column = ends.firstIndex { $0 <= top } ?? ends.count
      let end = top + height + gap
      if column == ends.count { ends.append(end) } else { ends[column] = end }
      group.append(Placement(event: item.event, top: top, height: height, column: column, columns: 1))
      groupEnd = max(groupEnd, end)
    }
    flush()
    return output
  }
}

struct CalendarDayColumn: View {
  let events: [LocalEvent]
  let day: Date
  let selectedID: String?
  var suggestionID: String = "cove-focus-suggestion"
  let select: (LocalEvent) -> Void

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        VStack(spacing: 0) {
          ForEach(0..<24) { _ in
            Color.clear.frame(height: CalendarEventLayout.hourHeight)
              .overlay(alignment: .top) { CalendarRule() }
              .overlay { CalendarRule(secondary: true) }
          }
        }
        ForEach(CalendarEventLayout.arrange(events, on: day)) { placement in
          let columnWidth = geometry.size.width / Double(placement.columns)
          CalendarTimedEvent(
            event: placement.event, height: placement.height,
            selected: selectedID == placement.id, suggested: suggestionID == placement.id
          ) { select(placement.event) }
          .frame(width: max(0, columnWidth - CalendarEventLayout.gap * 2), height: placement.height)
          .offset(x: Double(placement.column) * columnWidth + CalendarEventLayout.gap, y: placement.top)
        }
        TimelineView(.everyMinute) { context in
          if let minute = CalendarLayout.currentTimeMinute(on: day, now: context.date) {
            HStack(spacing: 0) {
              Circle().fill(Palette.ink).frame(width: 6, height: 6)
              Rectangle().fill(Palette.ink).frame(height: 1)
            }
            .offset(y: minute * CalendarEventLayout.hourHeight / 60 - 3)
            .allowsHitTesting(false)
            .accessibilityLabel("Current time, " + context.date.formatted(date: .omitted, time: .shortened))
          }
        }
      }
    }
    .background(Palette.canvas)
    .overlay(alignment: .leading) { CalendarRule(vertical: true) }
  }
}

struct CalendarTimedEvent: View {
  let event: LocalEvent
  let height: Double
  let selected: Bool
  let suggested: Bool
  let action: () -> Void
  @State private var hovered = false
  @Environment(\.colorSchemeContrast) private var contrast
  private var compact: Bool { height < 48 }
  private var description: String {
    "\(suggested ? "Suggested focus time" : event.title), \(event.start.formatted(date: .omitted, time: .shortened)) to \(event.end.formatted(date: .omitted, time: .shortened))"
  }
  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 3) {
        Text(event.title).font(.coveCaption)
          .lineLimit(height < 64 ? 1 : 2).multilineTextAlignment(.leading)
        if !compact {
          Text("\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))")
            .font(.coveMetadata).foregroundStyle(selected ? Color.white.opacity(0.85) : Palette.body)
            .lineLimit(height >= 72 ? 2 : 1)
        }
        if suggested && height >= 76 {
          Text("Suggested").font(.coveMetadata)
            .foregroundStyle(selected ? Color.white.opacity(0.85) : Palette.body)
        }
      }
      .padding(.horizontal, 8).padding(.vertical, compact ? 5 : 7)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .leading : .topLeading)
      .foregroundStyle(selected ? Color.white : Palette.ink)
      .background(selected ? Palette.ink : hovered ? Palette.selection : Palette.sidebar,
                  in: RoundedRectangle(cornerRadius: 5))
      .overlay {
        RoundedRectangle(cornerRadius: 5).strokeBorder(
          selected ? Palette.ink : suggested ? Palette.muted : hovered || contrast == .increased ? Palette.inputBorder : Palette.line,
          style: StrokeStyle(lineWidth: 1, dash: suggested ? [4, 3] : []))
      }
      .contentShape(RoundedRectangle(cornerRadius: 5))
      .clipped()
    }
    .buttonStyle(.plain).onHover { hovered = $0 }
    .help(description).accessibilityLabel(description)
  }
}

struct CalendarAllDayEvent: View {
  @Environment(\.colorSchemeContrast) private var contrast
  let event: LocalEvent
  let selected: Bool
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Text(event.title).font(.coveCaption).lineLimit(1)
        .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .foregroundStyle(selected ? Color.white : Palette.ink)
        .background(selected ? Palette.ink : Palette.sidebar, in: RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(
          selected ? Palette.ink : contrast == .increased ? Palette.inputBorder : Palette.line, lineWidth: 1) }
        .contentShape(RoundedRectangle(cornerRadius: 5))
    }.buttonStyle(.plain).help(event.title + " · All day")
      .accessibilityLabel(event.title + ", all day")
  }
}

struct CalendarAgendaEvent: View {
  let event: LocalEvent
  let status: String?
  let time: String
  let action: () -> Void
  @State private var hovered = false
  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 6) {
        if let status { Text(status).font(.coveCaption) }
        Text(time).font(.coveMetadata).monospacedDigit().foregroundStyle(Palette.body)
        Text(event.title).font(.coveLabel)
          .lineLimit(3).multilineTextAlignment(.leading)
      }
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .padding(.vertical, 14).padding(.horizontal, 8)
      .background(hovered ? Palette.surface : Palette.canvas, in: RoundedRectangle(cornerRadius: 4))
      .contentShape(Rectangle())
    }.buttonStyle(.plain).onHover { hovered = $0 }
  }
}

/// A visible, keyboard-accessible handle avoids SwiftUI/NSSplitView's disabled splitter state.
private struct CalendarAgendaDivider: View {
  @Binding var width: Double
  let available: Double
  @State private var startWidth: Double?
  @State private var hovered = false
  @FocusState private var focused: Bool

  private var effectiveWidth: Double {
    CalendarLayout.agendaWidth(preferred: width, available: available)
  }

  var body: some View {
    ZStack {
      Rectangle().fill(hovered || focused ? Palette.sidebar : Palette.canvas)
      CalendarRule(vertical: true)
      RoundedRectangle(cornerRadius: 2)
        .fill(hovered || focused ? Palette.ink : Palette.inputBorder)
        .frame(width: 3, height: 32)
    }
    .frame(width: CalendarLayout.agendaDividerWidth)
    .frame(maxHeight: .infinity)
    .contentShape(Rectangle())
    .focusable().focused($focused).focusEffectDisabled()
    .gesture(
      DragGesture(minimumDistance: 0, coordinateSpace: .named("calendarPanes"))
        .onChanged { drag in
          if startWidth == nil {
            startWidth = effectiveWidth
            focused = true
          }
          width = CalendarLayout.agendaWidth(
            preferred: (startWidth ?? effectiveWidth) - drag.translation.width, available: available
          )
        }
        .onEnded { _ in startWidth = nil }
    )
    .onContinuousHover { phase in
      switch phase {
      case .active:
        hovered = true
        NSCursor.resizeLeftRight.set()
      case .ended:
        hovered = false
        NSCursor.arrow.set()
      }
    }
    .onDisappear { if hovered { NSCursor.arrow.set() } }
    .onKeyPress(.leftArrow) {
      adjust(by: 24)
      return .handled
    }
    .onKeyPress(.rightArrow) {
      adjust(by: -24)
      return .handled
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Resize day agenda")
    .accessibilityValue("\(Int(effectiveWidth)) points wide")
    .accessibilityHint("Drag left to widen the agenda, or use the left and right arrow keys.")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: adjust(by: 24)
      case .decrement: adjust(by: -24)
      @unknown default: break
      }
    }
    .help("Drag to resize day agenda · Left and right arrows when focused")
  }

  private func adjust(by amount: Double) {
    width = CalendarLayout.agendaWidth(preferred: effectiveWidth + amount, available: available)
  }
}

struct CalendarEventDraft: Identifiable {
  let id = UUID()
  let editing: LocalEvent?
  var title: String
  var start: Date
  var end: Date
  var onGoogle: Bool
  var localCalendar: LocalCalendar

  init(
    title: String = "", editing: LocalEvent? = nil, start: Date = Date(), end: Date? = nil,
    localCalendar: LocalCalendar = .personal
  ) {
    self.editing = editing
    self.title = editing?.title ?? title
    self.start = editing?.start ?? start
    self.end = editing?.end ?? end ?? start.addingTimeInterval(3600)
    onGoogle = editing?.googleID != nil
    self.localCalendar = editing?.effectiveLocalCalendar ?? localCalendar
  }
}

struct CalendarEventEditor: View {
  @Bindable var store: AppStore
  @State var draft: CalendarEventDraft
  var reviewingProposal = false
  var onSaved: ((CalendarEventDraft) -> Void)? = nil
  @State private var saveError: String?
  @State private var saving = false
  @State private var account: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(reviewingProposal ? "Review your event" : draft.editing == nil ? "Make a little space" : "Edit event")
        .font(.coveTitle)
      TextField(
        "Event title", text: $draft.title,
        prompt: Text("Event title").foregroundStyle(Palette.muted)
      ).textFieldStyle(CoveFieldStyle())
      DatePicker("Starts", selection: $draft.start)
      DatePicker("Ends", selection: $draft.end)
      Text(TimeZone.current.identifier).font(.coveMetadata).foregroundStyle(Palette.muted)
      if reviewingProposal {
        Text("Review the date, time, and destination. Changing the time doesn’t recheck availability. No guests will be invited.")
          .font(.coveMetadata).foregroundStyle(Palette.body)
      }
      if store.calendarConnected && !store.isSample && draft.editing == nil {
        Toggle("Save to Google Calendar", isOn: $draft.onGoogle).toggleStyle(CoveToggleStyle())
      }
      if !draft.onGoogle {
        HStack {
          Text("Calendar").font(.coveBody)
          Spacer()
          CoveMenuPicker(
            "Calendar", selection: $draft.localCalendar,
            options: LocalCalendar.allCases.map { ($0, $0.title) })
        }
      }
      Text(
        draft.onGoogle
          ? (draft.editing == nil
            ? "Creates an event in your primary Google Calendar."
            : "Updates this event in your Google Calendar.")
          : "Saved to \(draft.localCalendar.title) on this Mac."
      ).font(.coveSecondary).foregroundStyle(Palette.muted)
      if let saveError {
        Text(saveError).font(.coveMetadata).foregroundStyle(Palette.danger)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Button("Cancel") { dismiss() }.buttonStyle(SecondaryButton()).keyboardShortcut(
          .cancelAction)
        Spacer()
        Button(draft.editing == nil ? "Add event" : "Save changes") {
          guard !saving else { return }
          let submitted = draft
          saveError = nil
          guard store.entered, account == store.accountEmail else {
            saveError = "Your account changed. Close this review and ask again."
            return
          }
          guard !reviewingProposal || submitted.start > Date().addingTimeInterval(-120) else {
            saveError = "That start time has passed. Choose a new time before adding the event."
            return
          }
          guard !submitted.onGoogle || store.calendarConnected else {
            saveError = "Reconnect Google Calendar or choose to save on this Mac."
            return
          }
          saving = true
          Task {
            defer { saving = false }
            if await store.createEvent(
              title: submitted.title, start: submitted.start, end: submitted.end,
              onGoogle: submitted.onGoogle, editing: submitted.editing,
              localCalendar: submitted.localCalendar)
            {
              onSaved?(submitted)
              dismiss()
            } else {
              saveError = store.error ?? "Couldn’t save this event. Please try again."
            }
          }
        }.buttonStyle(PrimaryButton()).disabled(
          draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draft.end <= draft.start)
      }
    }.padding(30).frame(width: 440).disabled(saving || store.busy || store.calendarSyncing)
      .interactiveDismissDisabled(saving || store.busy)
      .onAppear { account = store.accountEmail }
  }
}
