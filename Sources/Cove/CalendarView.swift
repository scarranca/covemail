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
  @State private var draggingDay: Date?
  @State private var pendingMove: PendingMove?
  @State private var moveNotice: MoveNotice?
  struct PendingMove: Identifiable {
    let id = UUID()
    let event: LocalEvent
    let start: Date
    let end: Date
  }
  struct MoveNotice: Identifiable {
    let id = UUID()
    let text: String
    var undo: (() async -> Void)?
  }
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
                eventToolbar(event)
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
                if let files = event.files?.filter({ $0.safeURL != nil }), !files.isEmpty {
                  EventFilesView(files: files)
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
              } else {
                agenda
              }
              CalendarRule()
              if !store.calendarConnected && !store.isSample {
                Button("Connect Google Calendar") { Task { await store.connectCalendar() } }
                  .buttonStyle(SecondaryButton()).disabled(store.connectingStep != nil)
                if let error = store.calendarConnectError {
                  Text(error).font(.coveSecondary).foregroundStyle(Palette.body)
                    .fixedSize(horizontal: false, vertical: true)
                }
              }
              if store.calendarConnected && !store.isSample {
                if let error = store.calendarSyncError {
                  Text("Calendar couldn’t sync. " + error).font(.coveSecondary)
                    .foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
                }
              }
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
    .confirmationDialog(
      pendingMove.map { "Move “\($0.event.title)” for everyone?" } ?? "",
      isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } }),
      presenting: pendingMove
    ) { move in
      Button("Move event") { Task { await applyMove(move.event, start: move.start, end: move.end) } }
      Button("Cancel", role: .cancel) {}
    } message: { move in
      Text("Guests’ calendars will show the new time. Google won’t email them about the change."
        + (move.event.recurringEventID == nil ? "" : " Only this occurrence moves."))
    }
    .overlay(alignment: .bottom) {
      if let notice = moveNotice {
        HStack(spacing: 14) {
          Text(notice.text).font(.coveSecondary).lineLimit(2)
          if let undo = notice.undo {
            Button("Undo") {
              moveNotice = nil
              Task { await undo() }
            }.buttonStyle(.plain).font(.coveControl).underline()
          }
        }
        .foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 12)
        .background(Palette.ink, in: RoundedRectangle(cornerRadius: 8))
        .padding(24).transition(.opacity)
        .task(id: notice.id) {
          try? await Task.sleep(for: .seconds(6))
          if moveNotice?.id == notice.id { moveNotice = nil }
        }
      }
    }
  }

  /// Dropped events save right away (with Undo); moving an event with guests asks first because
  /// it changes their calendars too.
  private func reschedule(_ event: LocalEvent, to start: Date, end: Date) {
    guard event.canReschedule, start != event.start || end != event.end else { return }
    if event.hasOtherGuests && !store.isSample {
      pendingMove = PendingMove(event: event, start: start, end: end)
    } else {
      Task { await applyMove(event, start: start, end: end) }
    }
  }
  private func applyMove(_ event: LocalEvent, start: Date, end: Date, undoable: Bool = true) async {
    guard !store.busy, !store.calendarSyncing else {
      moveNotice = MoveNotice(text: "Cove is syncing your calendar. Try moving “\(event.title)” again in a moment.")
      return
    }
    let before = (start: event.start, end: event.end)
    let saved = await store.createEvent(
      title: event.title, start: start, end: end, onGoogle: event.googleID != nil,
      editing: event, localCalendar: event.effectiveLocalCalendar)
    guard saved, let moved = store.events.first(where: { $0.id == store.calendarEventID }) else {
      moveNotice = MoveNotice(text: store.error ?? "Couldn’t move “\(event.title)”. Please try again.")
      return
    }
    let when = start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    moveNotice = MoveNotice(
      text: undoable ? "Moved “\(event.title)” to \(when)" : "Moved “\(event.title)” back",
      undo: undoable ? { await applyMove(moved, start: before.start, end: before.end, undoable: false) } : nil)
  }
  /// Event actions read like the email reader's toolbar: quiet icons with tooltips, not a stack of
  /// buttons competing for attention.
  private func eventToolbar(_ event: LocalEvent) -> some View {
    HStack(spacing: 4) {
      Button { store.calendarEventID = nil } label: { eventAction("Day agenda", icon: "chevron.left") }
        .help("Back to day agenda")
      Spacer(minLength: 8)
      if let link = event.meetURL, let url = URL(string: link), url.scheme == "https",
        url.host == "meet.google.com"
      {
        Link(destination: url) { eventAction("Join Google Meet", icon: "video") }.help("Join Google Meet")
      }
      if let mailID = event.mailID {
        Button {
          store.selectedID = mailID
          store.screen = "mail"
        } label: { eventAction("View email", icon: "envelope") }.help("View email")
      }
      if let link = event.webURL, let url = URL(string: link), url.scheme == "https",
        url.host == "google.com" || url.host?.hasSuffix(".google.com") == true
      {
        Link(destination: url) { eventAction("Open in Google Calendar", icon: "arrow.up.right.square") }
          .help("Open in Google Calendar")
      }
      if event.allDay != true {
        Button { eventDraft = CalendarEventDraft(editing: event) } label: { eventAction("Edit event", icon: "pencil") }
          .help("Edit event").disabled(store.busy || store.calendarSyncing)
      }
      Button(role: .destructive) { deleteTarget = event } label: { eventAction("Delete event", icon: "trash") }
        .help("Delete event").disabled(store.busy || store.calendarSyncing)
    }.buttonStyle(ReaderActionStyle()).foregroundStyle(Palette.body)
  }
  private func eventAction(_ title: String, icon: String) -> some View {
    Image(systemName: icon).font(.system(size: 15)).frame(minWidth: 32, minHeight: 40)
      .contentShape(Rectangle()).accessibilityLabel(title)
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
            ForEach(Array(week.enumerated()), id: \.element) { index, day in
              CalendarDayColumn(
                events: gridEvents, day: day, selectedID: store.calendarEventID,
                suggestionID: focusSuggestionID, dayRange: -index...(week.count - 1 - index),
                select: { event in
                  if event.id == focusSuggestionID {
                    reviewFocus(DateInterval(start: event.start, end: event.end))
                  } else {
                    select(event, on: day)
                  }
                },
                create: { start, end in eventDraft = CalendarEventDraft(start: start, end: end) },
                reschedule: { event, start, end in reschedule(event, to: start, end: end) },
                dragging: { active in draggingDay = active ? day : nil }
              )
              .frame(height: CalendarEventLayout.hourHeight * 24)
              .frame(maxWidth: .infinity)
              // The column being dragged from draws above its neighbours so a moved event stays visible.
              .zIndex(draggingDay == day ? 1 : 0)
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
      // + starts an event from scratch: the describe line is open, the time defaults to the next half hour.
      Button { newEvent() } label: {
        Image(systemName: "plus").font(.cove(size: 13, weight: .semibold)).foregroundStyle(.white)
          .frame(width: 30, height: 30).background(Palette.ink, in: Circle())
      }.buttonStyle(.plain).help("New event (⌘E)").accessibilityLabel("New event").keyboardShortcut("e")
      if store.calendarConnected && !store.isSample {
        Button { Task { await refresh() } } label: {
          Group {
            if store.calendarSyncing { ProgressView().controlSize(.small) }
            else { Image(systemName: "arrow.clockwise") }
          }.frame(width: 24, height: 32)
        }.buttonStyle(.plain).disabled(store.calendarSyncing)
          .help(store.calendarSyncing ? "Syncing calendar…" : "Sync calendar")
          .accessibilityLabel(store.calendarSyncing ? "Syncing calendar" : "Sync calendar")
      }
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

  private func newEvent() {
    let calendar = Calendar.current
    let now = Date()
    let hour = calendar.date(bySettingHour: calendar.component(.hour, from: now), minute: 0, second: 0, of: now) ?? now
    let half = hour.addingTimeInterval(calendar.component(.minute, from: now) < 30 ? 1_800 : 3_600)
    // On a future day the event starts at 9; today, at the next half hour.
    let start = calendar.isDate(store.calendarDay, inSameDayAs: now) || store.calendarDay < now
      ? half : calendar.date(bySettingHour: 9, minute: 0, second: 0, of: store.calendarDay) ?? half
    var draft = CalendarEventDraft(start: start, end: start.addingTimeInterval(1_800))
    draft.describeFirst = true
    eventDraft = draft
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
      Text("Focus time").font(.coveSubheading)
      if let focus {
        Text(timeRange(focus.start, focus.end)).font(.coveLabel)
        Button("Block focus time") {
          reviewFocus(focus)
        }.buttonStyle(SecondaryButton())
          .help(store.calendarConnected && !store.isSample
            ? "Free in your last sync of Google’s primary calendar and local events"
            : "Free in your saved local events")
      } else {
        Text(store.calendarAvailabilityReady ? "No free hour between 9 AM and 5 PM." : "Sync to check availability.")
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
  /// Columns this day may move an event by (negative is earlier in the visible week).
  var dayRange: ClosedRange<Int> = 0...0
  let select: (LocalEvent) -> Void
  var create: ((Date, Date) -> Void)? = nil
  var reschedule: ((LocalEvent, Date, Date) -> Void)? = nil
  var dragging: (Bool) -> Void = { _ in }

  @State private var creation: (start: Double, end: Double)?
  @State private var moving: (id: String, translation: CGSize)?
  @State private var resizing: (id: String, translation: Double)?
  private let hour = CalendarEventLayout.hourHeight

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        VStack(spacing: 0) {
          ForEach(0..<24) { _ in
            Color.clear.frame(height: hour)
              .overlay(alignment: .top) { CalendarRule() }
              .overlay { CalendarRule(secondary: true) }
          }
        }
        .contentShape(Rectangle())
        .gesture(createGesture, including: create == nil ? .none : .all)
        if let creation {
          creationPreview(creation).frame(width: max(0, geometry.size.width - CalendarEventLayout.gap * 2))
            .offset(x: CalendarEventLayout.gap, y: creation.start * hour / 60)
        }
        ForEach(CalendarEventLayout.arrange(events, on: day)) { placement in
          let columnWidth = geometry.size.width / Double(placement.columns)
          let movable = reschedule != nil && placement.event.canReschedule && placement.id != suggestionID
          let active = moving?.id == placement.id || resizing?.id == placement.id
          CalendarTimedEvent(
            event: placement.event, height: height(for: placement),
            selected: selectedID == placement.id, suggested: suggestionID == placement.id
          ) { select(placement.event) }
          .overlay(alignment: .bottom) {
            if movable { resizeHandle(placement.event) }
          }
          .overlay(alignment: .topTrailing) {
            if active, let span = proposedSpan(placement.event, columnWidth: geometry.size.width) {
              Text(span.label).font(.coveMetadata).padding(.horizontal, 6).padding(.vertical, 3)
                .background(Palette.ink, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
                .fixedSize().offset(y: -24).allowsHitTesting(false)
            }
          }
          .frame(width: max(0, columnWidth - CalendarEventLayout.gap * 2), height: height(for: placement))
          .highPriorityGesture(dragGesture(placement.event, columnWidth: geometry.size.width,
                                           bottom: placement.top + placement.height),
                               including: movable ? .all : .subviews)
          .offset(x: Double(placement.column) * columnWidth + CalendarEventLayout.gap, y: placement.top)
          .offset(offset(for: placement.event, columnWidth: geometry.size.width))
          .shadow(color: active ? .black.opacity(0.18) : .clear, radius: 8, y: 3)
          .zIndex(active ? 1 : 0)
        }
        TimelineView(.everyMinute) { context in
          if let minute = CalendarLayout.currentTimeMinute(on: day, now: context.date) {
            HStack(spacing: 0) {
              Circle().fill(Palette.ink).frame(width: 6, height: 6)
              Rectangle().fill(Palette.ink).frame(height: 1)
            }
            .offset(y: minute * hour / 60 - 3)
            .allowsHitTesting(false)
            .accessibilityLabel("Current time, " + context.date.formatted(date: .omitted, time: .shortened))
          }
        }
      }
    }
    .coordinateSpace(name: Self.space)
    .background(Palette.canvas)
    .overlay(alignment: .leading) { CalendarRule(vertical: true) }
  }

  private func date(_ minute: Double) -> Date {
    Calendar.current.startOfDay(for: day).addingTimeInterval(minute * 60)
  }
  private var createGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        if creation == nil { dragging(true) }
        creation = CalendarDrag.creation(fromY: value.startLocation.y, toY: value.location.y, hourHeight: hour)
      }
      .onEnded { value in
        let span = CalendarDrag.creation(fromY: value.startLocation.y, toY: value.location.y, hourHeight: hour)
        creation = nil
        dragging(false)
        create?(date(span.start), date(span.end))
      }
  }
  private func creationPreview(_ span: (start: Double, end: Double)) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("New event").font(.coveCaption)
      Text("\(date(span.start).formatted(date: .omitted, time: .shortened)) – \(date(span.end).formatted(date: .omitted, time: .shortened))")
        .font(.coveMetadata).foregroundStyle(Palette.body)
    }
    .padding(.horizontal, 8).padding(.vertical, 6)
    .frame(height: max(CalendarEventLayout.minimumHeight, (span.end - span.start) * hour / 60 - CalendarEventLayout.gap), alignment: .topLeading)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Palette.selection.opacity(0.7), in: RoundedRectangle(cornerRadius: 5))
    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.ink, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    .allowsHitTesting(false).accessibilityHidden(true)
  }
  /// One gesture per event: pressing within the bottom edge resizes, anywhere else moves. A click
  /// never reaches the drag's minimum distance, so it still opens the event.
  private func dragGesture(_ event: LocalEvent, columnWidth: Double, bottom: Double) -> some Gesture {
    // Measured in the column, which never moves; the event itself follows the pointer while dragging.
    DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
      .onChanged { value in
        if moving == nil && resizing == nil {
          dragging(true)
          if value.startLocation.y >= bottom - Self.edge {
            resizing = (event.id, value.translation.height)
          } else {
            moving = (event.id, value.translation)
          }
        }
        if resizing?.id == event.id { resizing = (event.id, value.translation.height) }
        else { moving = (event.id, value.translation) }
      }
      .onEnded { value in
        let resized = resizing?.id == event.id
        moving = nil
        resizing = nil
        dragging(false)
        if resized {
          let end = CalendarDrag.resizedEnd(start: event.start, end: event.end, translationY: value.translation.height, hourHeight: hour)
          reschedule?(event, event.start, end)
        } else {
          let target = CalendarDrag.moved(
            start: event.start, end: event.end, translationX: value.translation.width,
            translationY: value.translation.height, columnWidth: columnWidth, hourHeight: hour, dayRange: dayRange)
          reschedule?(event, target.start, target.end)
        }
      }
  }
  private static let edge = 8.0
  private static let space = "calendarDayColumn"
  /// Shows the resize cursor along the bottom edge; the event's own drag gesture does the work.
  private func resizeHandle(_ event: LocalEvent) -> some View {
    Color.clear.frame(height: Self.edge).contentShape(Rectangle())
      .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
      .help("Drag to change the end time").accessibilityHidden(true)
  }
  private func height(for placement: CalendarEventLayout.Placement) -> Double {
    guard let resizing, resizing.id == placement.id else { return placement.height }
    let end = CalendarDrag.resizedEnd(start: placement.event.start, end: placement.event.end,
                                      translationY: resizing.translation, hourHeight: hour)
    return max(CalendarEventLayout.minimumHeight, end.timeIntervalSince(placement.event.start) / 60 * hour / 60 - CalendarEventLayout.gap)
  }
  /// The pointer's snapped target, so the preview lands where the event will.
  private func offset(for event: LocalEvent, columnWidth: Double) -> CGSize {
    guard let moving, moving.id == event.id else { return .zero }
    let target = CalendarDrag.moved(start: event.start, end: event.end, translationX: moving.translation.width,
                                    translationY: moving.translation.height, columnWidth: columnWidth,
                                    hourHeight: hour, dayRange: dayRange)
    let calendar = Calendar.current
    let (from, to) = (calendar.startOfDay(for: event.start), calendar.startOfDay(for: target.start))
    let days = calendar.dateComponents([.day], from: from, to: to).day ?? 0
    let minutes = (target.start.timeIntervalSince(to) - event.start.timeIntervalSince(from)) / 60
    return CGSize(width: Double(days) * columnWidth, height: minutes * hour / 60)
  }
  private func proposedSpan(_ event: LocalEvent, columnWidth: Double) -> (start: Date, end: Date, label: String)? {
    var span: (start: Date, end: Date)
    if let moving, moving.id == event.id {
      span = CalendarDrag.moved(start: event.start, end: event.end, translationX: moving.translation.width,
                                translationY: moving.translation.height, columnWidth: columnWidth,
                                hourHeight: hour, dayRange: dayRange)
    } else if let resizing, resizing.id == event.id {
      span = (event.start, CalendarDrag.resizedEnd(start: event.start, end: event.end, translationY: resizing.translation, hourHeight: hour))
    } else { return nil }
    let sameDay = Calendar.current.isDate(span.start, inSameDayAs: event.start)
    let label = (sameDay ? "" : span.start.formatted(.dateTime.weekday(.abbreviated)) + " ")
      + span.start.formatted(date: .omitted, time: .shortened) + " – " + span.end.formatted(date: .omitted, time: .shortened)
    return (span.start, span.end, label)
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
  /// Guest addresses (Google Calendar only). Saving sends them Google's invitation email.
  var guests: [String]
  var addMeet = false
  /// Opened from the calendar's + : start with the describe line open.
  var describeFirst = false
  /// Whether the guest list differs from the event's, so an edit only re-invites when it changed.
  var guestsChanged: Bool {
    Set(guests.map { $0.lowercased() }) != Set((editing?.attendees ?? []).filter { $0.isSelf != true }.compactMap { $0.email?.lowercased() })
  }

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
    guests = (editing?.attendees ?? []).filter { $0.isSelf != true }.compactMap(\.email)
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

  @State private var pickingDay = false
  @State private var pickingCalendar = false
  @State private var askOpen = false
  private var describing: Bool { draft.editing == nil && !reviewingProposal }
  private var canSave: Bool {
    !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.end > draft.start
  }
  private var googleAvailable: Bool { store.calendarConnected && !store.isSample && draft.editing == nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 26) {
      HStack(alignment: .firstTextBaseline) {
        Text(reviewingProposal ? "Review your event" : draft.editing == nil ? "New event" : "Edit event")
          .font(.coveMetadata).foregroundStyle(Palette.muted)
        Spacer()
        Button { dismiss() } label: { Image(systemName: "xmark").font(.cove(size: 12)) }
          .buttonStyle(.plain).foregroundStyle(Palette.body).keyboardShortcut(.cancelAction).accessibilityLabel("Close")
      }
      TextField("Event title", text: $draft.title, prompt: Text("Add a title").foregroundStyle(Palette.muted))
        .textFieldStyle(.plain).font(.coveTitle).accessibilityLabel("Event title")
        .onSubmit { if canSave { save() } }
      VStack(alignment: .leading, spacing: 20) {
        row("clock") {
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
              chip(draft.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) { pickingDay = true }
                .popover(isPresented: $pickingDay, arrowEdge: .bottom) {
                  CoveDayPicker(selection: draft.start) { moveDay(to: $0); pickingDay = false }
                }
              EventTimeChip(title: draft.start.formatted(date: .omitted, time: .shortened),
                            choices: EventTimes.starts(on: draft.start), selected: draft.start) { setStart($0) }
              Text("–").foregroundStyle(Palette.muted)
              EventTimeChip(title: draft.end.formatted(date: .omitted, time: .shortened),
                            choices: EventTimes.ends(after: draft.start), selected: draft.end) { draft.end = $0 }
            }
            Text("\(EventTimes.duration(from: draft.start, to: draft.end)) · \(TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier)")
              .font(.coveMetadata).foregroundStyle(Palette.muted)
          }
        }
        row("calendar") {
          Button { pickingCalendar = true } label: {
            HStack(spacing: 6) {
              Text(draft.onGoogle ? "Google Calendar" : "\(draft.localCalendar.title) · on this Mac").font(.coveControl)
              Image(systemName: "chevron.down").font(.cove(size: 9))
            }.foregroundStyle(Palette.ink).padding(.horizontal, 10).frame(height: 30)
              .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
          }.buttonStyle(.plain).accessibilityLabel("Save to").accessibilityValue(draft.onGoogle ? "Google Calendar" : draft.localCalendar.title)
            .popover(isPresented: $pickingCalendar, arrowEdge: .bottom) {
              VStack(alignment: .leading, spacing: 2) {
                if googleAvailable || draft.onGoogle {
                  destination("Google Calendar", icon: "globe", selected: draft.onGoogle) { draft.onGoogle = true }
                    .disabled(!googleAvailable && !draft.onGoogle)
                  Divider().padding(.vertical, 4)
                }
                Text("On this Mac").font(.coveMetadata).foregroundStyle(Palette.muted).padding(.horizontal, 10).padding(.bottom, 2)
                ForEach(LocalCalendar.allCases, id: \.self) { calendar in
                  destination(calendar.title, icon: "laptopcomputer", selected: !draft.onGoogle && draft.localCalendar == calendar) {
                    draft.onGoogle = false; draft.localCalendar = calendar
                  }.disabled(draft.editing?.googleID != nil)
                }
              }.padding(8).frame(width: 220)
            }
        }
      }
      if draft.onGoogle, draft.editing == nil || draft.editing?.isOrganizer == true {
        row("person.2") { EventGuestsField(store: store, draft: $draft) }
      } else if draft.editing?.googleID == nil {
        row("person.2") {
          Text("To invite guests, save to Google Calendar.").font(.coveMetadata).foregroundStyle(Palette.muted)
        }
      }
      if reviewingProposal {
        Label(draft.guests.isEmpty ? "Changing the time doesn’t recheck your availability. No guests are invited."
                                   : "Changing the time doesn’t recheck your availability.", systemImage: "info.circle")
          .font(.coveMetadata).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
      }
      if let saveError {
        Text(saveError).font(.coveMetadata).foregroundStyle(Palette.danger)
          .fixedSize(horizontal: false, vertical: true)
      }
      if describing && askOpen {
        EventAskLine(store: store, draft: $draft, open: $askOpen)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
      HStack(spacing: 16) {
        if describing && !askOpen {
          // The ✦ sits by the actions, like Send in compose; it opens the describe line above.
          Button { withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { askOpen = true } } label: {
            Image(systemName: "sparkles").font(.cove(size: 16)).foregroundStyle(Palette.ink)
              .frame(width: 40, height: 40).background(Palette.sidebar, in: Circle()).contentShape(Circle())
          }.buttonStyle(.plain).help("Describe the event and Cove fills it in").accessibilityLabel("Describe the event")
        }
        Spacer()
        Button("Cancel") { dismiss() }.buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body)
        Button(draft.onGoogle && draft.guestsChanged && !draft.guests.isEmpty
               ? (draft.editing == nil ? "Add and invite" : "Save and update guests")
               : draft.editing == nil ? "Add event" : "Save changes") { save() }
          .buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction).disabled(!canSave)
      }
    }.padding(36).frame(width: 560).disabled(saving || store.busy || store.calendarSyncing)
      .interactiveDismissDisabled(saving || store.busy)
      .onAppear {
        account = store.accountEmail
        if draft.describeFirst && describing { askOpen = true }
        // New events go to Google when it's connected; the menu can still choose this Mac.
        if draft.editing == nil && googleAvailable && !reviewingProposal { draft.onGoogle = true }
      }
  }
  private func row<Content: View>(_ icon: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Image(systemName: icon).font(.cove(size: 13)).foregroundStyle(Palette.body).frame(width: 18).accessibilityHidden(true)
      content()
    }
  }
  private func destination(_ title: String, icon: String, selected: Bool, choose: @escaping () -> Void) -> some View {
    Button { choose(); pickingCalendar = false } label: {
      HStack(spacing: 8) {
        Image(systemName: icon).font(.cove(size: 12)).foregroundStyle(Palette.body).frame(width: 16)
        Text(title).font(.coveSecondary).foregroundStyle(Palette.ink)
        Spacer()
        if selected { Image(systemName: "checkmark").font(.cove(size: 11)) }
      }.padding(.horizontal, 10).frame(height: 30)
        .background(selected ? Palette.mailSelection : .clear, in: RoundedRectangle(cornerRadius: 5)).contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
  private func chip(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).font(.coveControl).foregroundStyle(Palette.ink).padding(.horizontal, 10).frame(height: 30)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
    }.buttonStyle(.plain)
  }
  /// A new start keeps the event's length, like moving it.
  private func setStart(_ start: Date) {
    let length = max(900, draft.end.timeIntervalSince(draft.start))
    draft.start = start; draft.end = start.addingTimeInterval(length)
  }
  private func moveDay(to day: Date) {
    let calendar = Calendar.current
    let time = calendar.dateComponents([.hour, .minute], from: draft.start)
    guard let start = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day) else { return }
    setStart(start); pickingDay = false
  }
  private func save() {
    guard !saving, canSave else { return }
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
        localCalendar: submitted.localCalendar,
        guests: submitted.onGoogle && submitted.guestsChanged ? submitted.guests : nil,
        addMeet: submitted.onGoogle && submitted.editing == nil && submitted.addMeet)
      {
        onSaved?(submitted)
        dismiss()
      } else {
        saveError = store.error ?? "Couldn’t save this event. Please try again."
      }
    }
  }
}

/// Times offered in the event editor: every 15 minutes, and end times labeled with the length.
enum EventTimes {
  struct Choice: Hashable { let date: Date; let label: String }
  static func starts(on day: Date, calendar: Calendar = .current) -> [Choice] {
    let midnight = calendar.startOfDay(for: day)
    return (0..<96).compactMap { step in
      calendar.date(byAdding: .minute, value: step * 15, to: midnight).map { Choice(date: $0, label: $0.formatted(date: .omitted, time: .shortened)) }
    }
  }
  static func ends(after start: Date) -> [Choice] {
    (1...48).map { step in
      let end = start.addingTimeInterval(Double(step) * 900)
      return Choice(date: end, label: "\(end.formatted(date: .omitted, time: .shortened))  ·  \(duration(from: start, to: end))")
    }
  }
  static func duration(from start: Date, to end: Date) -> String {
    let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
    if minutes < 60 { return "\(minutes) min" }
    let hours = Double(minutes) / 60
    return hours == hours.rounded() ? "\(Int(hours)) hr" : String(format: "%.1f hr", hours).replacingOccurrences(of: ".0", with: "")
  }
}

/// A time as a chip; the list opens scrolled to the current choice.
struct EventTimeChip: View {
  let title: String
  let choices: [EventTimes.Choice]
  let selected: Date
  let pick: (Date) -> Void
  @State private var open = false
  var body: some View {
    Button { open = true } label: {
      Text(title).font(.coveControl).foregroundStyle(Palette.ink).padding(.horizontal, 10).frame(height: 30)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
    }.buttonStyle(.plain).accessibilityHint("Choose a time")
      .popover(isPresented: $open, arrowEdge: .bottom) {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(choices, id: \.self) { choice in
                let current = abs(choice.date.timeIntervalSince(selected)) < 60
                Button { pick(choice.date); open = false } label: {
                  Text(choice.label).font(.coveSecondary).foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 30)
                    .background(current ? Palette.mailSelection : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).id(choice.date)
              }
            }.padding(6)
          }.frame(width: 200, height: 260)
            .onAppear {
              let target = choices.min { abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected)) }
              if let target { proxy.scrollTo(target.date, anchor: .center) }
            }
        }
      }
  }
}

/// Gemini notes, transcripts and recordings Google attached to a meeting, opened in Google.
struct EventFilesView: View {
  let files: [CalendarFile]
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("From the meeting").font(.coveLabel)
      ForEach(Array(files.enumerated()), id: \.offset) { _, file in
        if let url = file.safeURL {
          Link(destination: url) {
            HStack(spacing: 10) {
              Image(systemName: Self.icon(file.kind)).font(.cove(size: 13)).foregroundStyle(Palette.body).frame(width: 18)
              VStack(alignment: .leading, spacing: 1) {
                Text(file.title).font(.coveSecondary).foregroundStyle(Palette.ink).lineLimit(1)
                Text(Self.caption(file.kind)).font(.coveMetadata).foregroundStyle(Palette.muted)
              }
              Spacer(minLength: 0)
              Image(systemName: "arrow.up.right").font(.cove(size: 10)).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
            .contentShape(Rectangle())
          }.buttonStyle(.plain).help("Open in Google")
        }
      }
    }
  }
  static func icon(_ kind: CalendarFile.Kind) -> String {
    switch kind { case .notes: "sparkles"; case .transcript: "text.quote"; case .recording: "play.rectangle"; case .file: "doc" }
  }
  static func caption(_ kind: CalendarFile.Kind) -> String {
    switch kind {
    case .notes: "Meeting notes · opens in Google Docs"
    case .transcript: "Transcript · opens in Google Docs"
    case .recording: "Recording · opens in Google Drive"
    case .file: "Opens in Google"
    }
  }
}

/// Guests for a Google Calendar event: chips, plus a field that suggests the user's contacts.
struct EventGuestsField: View {
  @Bindable var store: AppStore
  @Binding var draft: CalendarEventDraft
  @State private var text = ""
  @State private var problem: String?
  @FocusState private var focused: Bool

  private var suggestions: [MailContact] {
    let query = text.trimmingCharacters(in: .whitespaces)
    guard query.count >= 2 else { return [] }
    let taken = Set(draft.guests.map { $0.lowercased() } + [store.accountEmail.lowercased()])
    return store.contacts.filter { contact in
      !taken.contains(contact.email.lowercased())
        && (contact.name.localizedStandardContains(query) || contact.email.localizedStandardContains(query))
    }.prefix(4).map { $0 }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !draft.guests.isEmpty {
        MailChipLayout(spacing: 6) {
          ForEach(draft.guests, id: \.self) { guest in
            HStack(spacing: 5) {
              Text(name(for: guest)).font(.coveControl).lineLimit(1)
              Button { draft.guests.removeAll { $0 == guest } } label: { Image(systemName: "xmark").font(.cove(size: 8, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(Palette.muted).accessibilityLabel("Remove \(guest)")
            }.padding(.leading, 10).padding(.trailing, 8).frame(height: 28)
              .background(Palette.surface, in: Capsule()).help(guest)
          }
        }
      }
      TextField("Add guests", text: $text, prompt: Text("Add guests by name or email").foregroundStyle(Palette.muted))
        .textFieldStyle(.plain).font(.coveSecondary).focused($focused)
        .padding(.horizontal, 12).frame(height: 36)
        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Palette.inputBorder : Palette.line))
        .onSubmit { add(suggestions.first?.email ?? text) }
        .onChange(of: text) { _, value in
          problem = nil
          // Typing or pasting a comma or space finishes an address.
          if let last = value.last, last == "," || last == " " || last == ";" {
            let typed = String(value.dropLast()).trimmingCharacters(in: .whitespaces)
            if ContactDirectory.isValidEmail(typed) { add(typed) }
          }
        }
        .accessibilityLabel("Add guests")
      if !suggestions.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(suggestions, id: \.email) { contact in
            Button { add(contact.email) } label: {
              HStack(spacing: 8) {
                Text(contact.name).font(.coveSecondary).foregroundStyle(Palette.ink).lineLimit(1)
                Text(contact.email).font(.coveMetadata).foregroundStyle(Palette.muted).lineLimit(1)
                Spacer(minLength: 0)
              }.padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain)
          }
        }.padding(4).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
      }
      if let problem { Text(problem).font(.coveMetadata).foregroundStyle(Palette.danger) }
      if draft.editing == nil {
        Toggle(isOn: $draft.addMeet) {
          Label("Add a Google Meet link", systemImage: "video").font(.coveSecondary).foregroundStyle(Palette.body)
            .padding(.leading, 4)
        }.toggleStyle(.checkbox).padding(.top, 4)
      }
      if !draft.guests.isEmpty && draft.guestsChanged {
        Text("Guests get Google’s invitation email when you save.").font(.coveMetadata).foregroundStyle(Palette.muted)
      }
    }
  }
  private func name(for email: String) -> String {
    store.contacts.first { $0.email.caseInsensitiveCompare(email) == .orderedSame }.map { $0.name == $0.email ? email : $0.name } ?? email
  }
  private func add(_ value: String) {
    let email = value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;")))
    guard !email.isEmpty else { return }
    guard ContactDirectory.isValidEmail(email) else { problem = "Type a full email address, or pick a contact."; return }
    guard !draft.guests.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }),
      email.caseInsensitiveCompare(store.accountEmail) != .orderedSame else { text = ""; return }
    draft.guests.append(email)
    // New events with guests usually want a call link.
    if draft.editing == nil && draft.guests.count == 1 { draft.addMeet = true }
    text = ""
  }
}

/// The ✦ on a new event (by Cancel / Add): it opens one line where the user describes the event in their own words,
/// and the writing model fills the editor below. Nothing is saved or sent until the user clicks Add.
struct EventAskLine: View {
  @Bindable var store: AppStore
  @Binding var draft: CalendarEventDraft
  @Binding var open: Bool
  @State var text = ""
  @State private var task: Task<Void, Never>?
  @State private var notes: [String] = []
  @State private var filled = false
  @State private var found: String?
  @State private var stage = "Reading your event…"
  @FocusState private var focused: Bool
  private var settings: AIProviderSettings { .shared }
  private var canAsk: Bool {
    task == nil && settings.hasWorkingDefault && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let found {
        Label(found, systemImage: "calendar.badge.checkmark").font(.coveMetadata).foregroundStyle(Palette.body)
          .fixedSize(horizontal: false, vertical: true)
      } else if filled && notes.isEmpty {
        Label("Filled in from your description. Review it before adding.", systemImage: "checkmark.circle")
          .font(.coveMetadata).foregroundStyle(Palette.body)
      }
      ForEach(notes, id: \.self) { note in
        Label(note, systemImage: "info.circle").font(.coveMetadata).foregroundStyle(Palette.body)
          .fixedSize(horizontal: false, vertical: true)
      }
      if !settings.hasWorkingDefault {
        Text("Connect a writing model in Connections to describe events in your own words.")
          .font(.coveMetadata).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
      }
      if task != nil { WritingThinkingBar(stage: stage).transition(.opacity) }
      HStack(alignment: .center, spacing: 10) {
        Image(systemName: "sparkles").font(.cove(size: 14)).foregroundStyle(Palette.body)
          .frame(width: 24, height: 28).accessibilityHidden(true)
        // A one-line prompt: a wrapped placeholder makes the field taller and pushes the text above the icons.
        TextField("", text: $text, prompt: Text("Describe it… “30 min with Manuel, first open spot”").foregroundStyle(Palette.muted), axis: .vertical)
          .lineLimit(1...3).textFieldStyle(.plain).font(.coveBody).focused($focused)
          .help("For example: lunch with Maya Friday at 1 · 30 min with Manuel at the first open spot tomorrow")
          .onSubmit { ask() }.onExitCommand { if task == nil { close() } }
          .disabled(task != nil).accessibilityLabel("Describe the event")
        if task != nil {
          Button { task?.cancel(); task = nil } label: {
            Image(systemName: "stop.fill").font(.cove(size: 10)).frame(width: 28, height: 28)
              .background(Palette.ink, in: Circle()).foregroundStyle(.white)
          }.buttonStyle(.plain).accessibilityLabel("Stop")
        } else {
          Button(action: ask) {
            Image(systemName: "arrow.up").font(.cove(size: 12, weight: .semibold)).frame(width: 28, height: 28)
              .background(canAsk ? Palette.ink : Palette.disabled, in: Circle())
              .foregroundStyle(canAsk ? Color.white : Palette.disabledText)
          }.buttonStyle(.plain).disabled(!canAsk).help("Fill in the event (Return)").accessibilityLabel("Fill in the event")
          Button(action: close) { Image(systemName: "xmark").font(.cove(size: 10)).frame(width: 24, height: 28) }
            .buttonStyle(.plain).foregroundStyle(Palette.muted).help("Close (Esc)").accessibilityLabel("Close")
        }
      }
      .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 6).frame(minHeight: 44)
      .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(task != nil ? Palette.inputBorder : Palette.line))
    }
    .onAppear { focused = true }
  }
  private func close() {
    withAnimation(.easeOut(duration: 0.2)) { open = false }
  }

  private func ask() {
    guard canAsk, settings.hasWorkingDefault else { return }
    let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let now = Date(), zone = TimeZone.current
    let clock = ISO8601DateFormatter(); clock.timeZone = zone
    notes = []; filled = false; found = nil; stage = "Reading your event…"
    task = Task {
      defer { task = nil }
      do {
        let prompt = try AIPrompt(intent: .describeEvent,
          instruction: request + "\nCurrent LOCAL date/time: \(clock.string(from: now)) (\(now.formatted(.dateTime.weekday(.wide)))); time zone: \(zone.identifier).",
          mails: [])
        let reply = try await settings.complete(prompt)
        try Task.checkCancellation()
        await apply(try EventDescription.parse(reply, now: now, timeZone: zone), request: request)
      } catch is CancellationError {
      } catch {
        notes = [(error as? CoveError)?.localizedDescription ?? error.localizedDescription]
      }
    }
  }

  /// Fills the editor. Guests come only from the user's words: names must match exactly one contact.
  private func apply(_ event: EventDescription, request: String) async {
    if !event.title.isEmpty { draft.title = event.title }
    if let start = event.start, let end = event.end { draft.start = start; draft.end = end }
    var problems: [String] = []
    found = nil
    if let spot = event.free {
      if store.calendarConnected || store.isSample {
        stage = "Finding your first open \(spot.durationMinutes) minutes…"
        do {
          if let slot = try await store.firstOpenSpot(spot) {
            draft.start = slot.start; draft.end = slot.end
            found = "First open spot: " + slot.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute())
              + ". Checked your Google Calendar and Cove’s events."
          } else {
            problems.append(spot.day == nil ? "No open \(spot.durationMinutes) minutes in the next seven weekdays. Pick a time below."
                                            : "No open \(spot.durationMinutes) minutes that day. Pick a time below or ask for another day.")
          }
        } catch is CancellationError { return
        } catch { problems.append((error as? CoveError)?.localizedDescription ?? "Couldn’t check your calendar. Pick a time below.") }
      } else {
        problems.append("Connect Google Calendar to find an open spot. Pick a time below for now.")
      }
    }
    if let question = event.question { problems.append(question) }
    if !event.guests.isEmpty {
      // Guests need Google Calendar; switch to it when it's connected.
      if !draft.onGoogle, store.calendarConnected, !store.isSample { draft.onGoogle = true }
      for guest in event.guests {
        switch RecipientResolver.resolve([guest], contacts: store.contacts, question: request, accountEmail: store.accountEmail) {
        case .resolved(let people):
          for person in people where !draft.guests.contains(where: { $0.caseInsensitiveCompare(person.email) == .orderedSame }) {
            draft.guests.append(person.email)
          }
        case .ambiguous(let name, let candidates):
          problems.append("Which “\(name)”? " + candidates.prefix(3).map { "\($0.name) <\($0.email)>" }.joined(separator: ", ") + ". Add them below.")
        case .missing(let name):
          problems.append("“\(name)” isn’t in your contacts. Add their email below.")
        }
      }
      if !draft.onGoogle { problems.append("To invite guests, save to Google Calendar.") }
    }
    if event.meet && draft.onGoogle { draft.addMeet = true }
    notes = problems
    filled = true
    text = ""
  }
}
