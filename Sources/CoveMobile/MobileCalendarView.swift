#if os(iOS)
import CoveCore
import SwiftUI

/// Calendar on iPhone: the Mac's Monday-first week and month grids sized for a phone, with the
/// selected day's agenda below. Events open their details; invitations are answered only by a tap.
struct MobileCalendarView: View {
  let auth: MobileAuth
  let workspace: MobileWorkspace
  @State private var selected = Calendar.current.startOfDay(for: Date())
  @State private var mode: Mode = .week
  @State private var detail: LocalEvent?

  enum Mode: Hashable { case workweek, week, month }
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var pageWidth: CGFloat = 0

  private var calendar: Calendar {
    var calendar = Calendar.current
    calendar.firstWeekday = 2
    return calendar
  }

  var body: some View {
    if sizeClass == .regular { wideBody } else { compactBody }
  }

  // MARK: iPad (the Mac's Workweek / Week / Month)

  private var wideBody: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 16) {
        MobileScreenHeader(title: "Calendar", detail: selected.formatted(.dateTime.month(.wide).year())) {
          Button { step(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(MobileIconButton())
            .accessibilityLabel("Previous")
          Button("Today") { select(Date()) }.buttonStyle(MobileSecondaryButton(compact: true)).fixedSize()
          Button { step(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(MobileIconButton())
            .accessibilityLabel("Next")
          Button { Task { await workspace.loadEvents(around: selected, force: true) } } label: {
            if workspace.loadingEvents { ProgressView() } else { Image(systemName: "arrow.clockwise") }
          }.buttonStyle(MobileIconButton()).accessibilityLabel("Refresh Calendar")
        }
        if !auth.calendarConnected && !auth.isSample {
          MobileConnectCard(auth: auth, title: "Connect Google Calendar",
                            detail: "See your agenda, join calls and answer invitations. Cove asks Google once for Calendar and Tasks.")
            .frame(maxWidth: 560)
          Spacer()
        } else {
          MobileSegmented(selection: $mode, options: [(.workweek, "Workweek"), (.week, "Week"), (.month, "Month")])
            .frame(maxWidth: 420)
          HStack(alignment: .top, spacing: 20) {
            Group {
              if mode == .month {
                ScrollView { MobileMonthGrid(workspace: workspace, selected: selectedBinding) { detail = $0 } }
              } else {
                let start = CalendarAgenda.weekStart(containing: selected, calendar: calendar)
                let days = (0..<(mode == .workweek ? 5 : 7)).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
                MobileWeekGrid(days: days, workspace: workspace, selected: selectedBinding) { detail = $0 }
              }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            // The selected day's agenda sits beside the grid when there's room (landscape).
            if pageWidth >= 1000 { ScrollView { agenda }.frame(width: 300) }
          }
        }
      }
      .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 20)
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
      .background(MobilePalette.canvas)
      .toolbar(.hidden, for: .navigationBar)
      .sheet(item: $detail) { event in MobileEventDetail(event: event, workspace: workspace) }
      // Workweek on weekdays, as on the Mac; on a weekend the full week, so today's events show.
      .onAppear { if mode == .week && !calendar.isDateInWeekend(Date()) { mode = .workweek } }
    }
  }

  private var selectedBinding: Binding<Date> {
    Binding(get: { selected }, set: { select($0) })
  }

  private func step(_ direction: Int) {
    if mode == .month { shiftMonth(direction) } else { shift(7 * direction) }
  }

  // MARK: iPhone

  private var compactBody: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          MobileScreenHeader(title: "Calendar", detail: selected.formatted(.dateTime.month(.wide).year())) {
            Button("Today") { select(Date()) }.buttonStyle(MobileSecondaryButton(compact: true))
            Button { Task { await workspace.loadEvents(around: selected, force: true) } } label: {
              if workspace.loadingEvents { ProgressView() } else { Image(systemName: "arrow.clockwise") }
            }.buttonStyle(MobileIconButton()).accessibilityLabel("Refresh Calendar")
          }
          if !auth.calendarConnected && !auth.isSample {
            MobileConnectCard(auth: auth, title: "Connect Google Calendar",
                              detail: "See your agenda, join calls and answer invitations. Cove asks Google once for Calendar and Tasks.")
          } else {
            MobileSegmented(selection: $mode, options: [(.week, "Week"), (.month, "Month")])
            if mode == .week { weekStrip } else { monthGrid }
            agenda
          }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        // A readable column on iPad, as the Mac keeps task pages to a reading width.
        .frame(maxWidth: 860).frame(maxWidth: .infinity)
      }
      .background(MobilePalette.canvas)
      .refreshable { await workspace.loadEvents(around: selected, force: true) }
      .toolbar(.hidden, for: .navigationBar)
      .sheet(item: $detail) { event in MobileEventDetail(event: event, workspace: workspace) }
    }
  }

  private func select(_ date: Date) {
    selected = calendar.startOfDay(for: date)
    Task { await workspace.loadEvents(around: selected) }
  }

  // MARK: Week

  private var weekStrip: some View {
    let start = CalendarAgenda.weekStart(containing: selected, calendar: calendar)
    let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    return HStack(spacing: 6) {
      Button { shift(-7) } label: { Image(systemName: "chevron.left") }
        .buttonStyle(MobileIconButton()).accessibilityLabel("Previous week")
      ForEach(days, id: \.self) { day in dayCell(day, compact: false) }
      Button { shift(7) } label: { Image(systemName: "chevron.right") }
        .buttonStyle(MobileIconButton()).accessibilityLabel("Next week")
    }
    .gesture(DragGesture(minimumDistance: 30).onEnded { value in
      if value.translation.width < -40 { shift(7) } else if value.translation.width > 40 { shift(-7) }
    })
  }

  private func shift(_ days: Int) {
    if let date = calendar.date(byAdding: .day, value: days, to: selected) { select(date) }
  }

  private func dayCell(_ day: Date, compact: Bool, inMonth: Bool = true) -> some View {
    let isSelected = calendar.isDate(day, inSameDayAs: selected)
    let isToday = calendar.isDateInToday(day)
    let count = workspace.events(on: day).count
    return Button { select(day) } label: {
      VStack(spacing: 3) {
        if !compact {
          Text(day, format: .dateTime.weekday(.narrow)).font(.mobileMetadata)
            .foregroundStyle(isSelected ? Color.white.opacity(0.8) : MobilePalette.muted)
        }
        Text(day, format: .dateTime.day()).font(.coveMobile(15, weight: isToday || isSelected ? .semibold : .regular))
          .foregroundStyle(isSelected ? Color.white : inMonth ? MobilePalette.ink : MobilePalette.disabledText)
        Circle().fill(count > 0 ? (isSelected ? Color.white : MobilePalette.ink) : .clear).frame(width: 4, height: 4)
      }
      .frame(maxWidth: .infinity, minHeight: compact ? 44 : 58)
      .background(isSelected ? MobilePalette.ink : isToday ? MobilePalette.sidebar : .clear, in: RoundedRectangle(cornerRadius: 8))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(day.formatted(date: .complete, time: .omitted) + (count > 0 ? ", \(count) events" : ""))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  // MARK: Month

  private var monthGrid: some View {
    let days = CalendarAgenda.monthDays(containing: selected, calendar: calendar)
    let month = calendar.component(.month, from: selected)
    return VStack(spacing: 6) {
      HStack {
        Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
          .buttonStyle(MobileIconButton()).accessibilityLabel("Previous month")
        Spacer()
        Text(selected.formatted(.dateTime.month(.wide).year())).font(.mobileSubheading)
        Spacer()
        Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
          .buttonStyle(MobileIconButton()).accessibilityLabel("Next month")
      }
      HStack(spacing: 4) {
        ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { index in
          Text(["M", "T", "W", "T", "F", "S", "S"][index]).font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
            .frame(maxWidth: .infinity)
        }
      }
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
        ForEach(days, id: \.self) { day in
          dayCell(day, compact: true, inMonth: calendar.component(.month, from: day) == month)
        }
      }
    }
  }

  private func shiftMonth(_ months: Int) {
    if let date = calendar.date(byAdding: .month, value: months, to: selected) { select(date) }
  }

  // MARK: Agenda

  private var agenda: some View {
    let events = workspace.events(on: selected)
    return VStack(alignment: .leading, spacing: 10) {
      MobileSectionTitle(title: calendar.isDateInToday(selected) ? "Today" : selected.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
                         detail: events.isEmpty ? nil : "\(events.count) \(events.count == 1 ? "event" : "events")")
      if let error = workspace.eventsError {
        Text(error).font(.mobileSecondary).foregroundStyle(MobilePalette.danger)
      }
      if events.isEmpty {
        Text(workspace.loadingEvents ? "Checking your calendar…" : "Nothing scheduled. A clear day.")
          .font(.mobileSecondary).foregroundStyle(MobilePalette.muted).padding(.vertical, 8)
      } else {
        ForEach(events) { event in
          Button { detail = event } label: { MobileEventRow(event: event) }.buttonStyle(.plain)
        }
      }
    }
  }
}

/// One event: time column, title, place and a Join action for calls.
struct MobileEventRow: View {
  let event: LocalEvent
  var body: some View {
    let past = event.end < Date()
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        if event.allDay == true {
          Text("All day").font(.mobileCaption)
        } else {
          Text(event.start.formatted(date: .omitted, time: .shortened)).font(.mobileCaption).monospacedDigit()
          Text(event.end.formatted(date: .omitted, time: .shortened)).font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
            .monospacedDigit()
        }
      }.frame(width: 64, alignment: .leading)
      Capsule().fill(event.isPendingInvitation ? MobilePalette.warm : MobilePalette.ink).frame(width: 3).frame(minHeight: 18)
      VStack(alignment: .leading, spacing: 3) {
        Text(event.title.isEmpty ? "(No title)" : event.title).font(.mobileSubheading).foregroundStyle(MobilePalette.ink)
          .lineLimit(2).multilineTextAlignment(.leading)
        if let location = event.location, !location.isEmpty {
          Label(location, systemImage: "mappin").font(.mobileMetadata).foregroundStyle(MobilePalette.muted).lineLimit(1)
        }
        if event.isPendingInvitation {
          Text("Invitation · not answered").font(.mobileMetadata).foregroundStyle(MobilePalette.body)
        }
      }
      Spacer(minLength: 4)
      if let meet = event.meetURL, let url = URL(string: meet), !past {
        Link(destination: url) { Text("Join").font(.mobileControl) }
          .buttonStyle(MobilePrimaryButton(compact: true))
      }
    }
    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
    .background(MobilePalette.surface, in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(MobilePalette.line))
    .opacity(past ? 0.6 : 1)
    .fixedSize(horizontal: false, vertical: true)
    .contentShape(Rectangle())
  }
}

/// A pending invitation with the Mac's compact Accept / Maybe / Decline controls.
struct MobileInvitationCard: View {
  let event: LocalEvent
  let workspace: MobileWorkspace
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(event.title.isEmpty ? "(No title)" : event.title).font(.mobileSubheading)
      Text(event.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute())
           + (event.organizerName.map { " · from \($0)" } ?? ""))
        .font(.mobileSecondary).foregroundStyle(MobilePalette.body)
      HStack(spacing: 8) {
        ForEach(CalendarRSVP.allCases, id: \.self) { answer in
          Button(answer.title) { Task { await workspace.respond(event, answer) } }
            .buttonStyle(MobileSecondaryButton(compact: true, expands: true))
            .disabled(workspace.responding.contains(event.id))
        }
      }
      if workspace.responding.contains(event.id) {
        HStack(spacing: 6) { ProgressView(); Text("Sending your answer…") }.font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
      }
    }
    .foregroundStyle(MobilePalette.ink)
    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    .background(MobilePalette.canvas, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(MobilePalette.line))
  }
}

/// Event details, as the Mac's event panel: time, place, call link, guests, description and files.
struct MobileEventDetail: View {
  let event: LocalEvent
  let workspace: MobileWorkspace
  @Environment(\.dismiss) private var dismiss

  private var current: LocalEvent { workspace.events.first { $0.id == event.id } ?? event }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text(current.title.isEmpty ? "(No title)" : current.title).font(.mobileDetailTitle)
          VStack(alignment: .leading, spacing: 10) {
            row("clock", current.allDay == true
                ? current.start.formatted(.dateTime.weekday(.wide).month(.wide).day()) + " · All day"
                : current.start.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute()) + " – "
                  + current.end.formatted(date: .omitted, time: .shortened))
            if let location = current.location, !location.isEmpty { row("mappin.and.ellipse", location) }
            if let organizer = current.organizerName ?? current.organizerEmail { row("person", "Organized by \(organizer)") }
            row("calendar", "Google · primary")
          }
          HStack(spacing: 10) {
            if let meet = current.meetURL, let url = URL(string: meet) {
              Link(destination: url) { Label("Join call", systemImage: "video") }.buttonStyle(MobilePrimaryButton())
            }
            if let web = current.webURL, let url = URL(string: web) {
              Link(destination: url) { Label("Open in Google Calendar", systemImage: "arrow.up.right.square") }
                .buttonStyle(MobileSecondaryButton())
            }
          }
          if current.isPendingInvitation || current.ownResponse != nil {
            VStack(alignment: .leading, spacing: 8) {
              Text("Your answer").font(.mobileSection)
              HStack(spacing: 8) {
                ForEach(CalendarRSVP.allCases, id: \.self) { answer in
                  let chosen = current.ownResponse == answer.rawValue
                  Button(chosen ? answer.confirmation : answer.title) { Task { await workspace.respond(current, answer) } }
                    .buttonStyle(chosenStyle(chosen))
                    .disabled(workspace.responding.contains(current.id) || chosen)
                }
              }
            }
          }
          if let guests = current.attendees, !guests.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Text("Guests · \(guests.count)").font(.mobileSection)
              ForEach(Array(guests.enumerated()), id: \.offset) { _, guest in
                HStack(spacing: 10) {
                  MobileAvatar(name: guest.name ?? guest.email ?? "?", size: 28)
                  VStack(alignment: .leading, spacing: 1) {
                    Text(guest.name ?? guest.email ?? "Guest").font(.mobileLabel)
                    Text(Self.response(guest.response)).font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
                  }
                }
              }
            }
          }
          if let details = current.details, !details.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Text("Description").font(.mobileSection)
              Text(details).font(.mobileText).foregroundStyle(MobilePalette.body).lineSpacing(4).textSelection(.enabled)
            }
          }
          if let files = current.files, !files.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Text("Files").font(.mobileSection)
              ForEach(files, id: \.url) { file in
                if let url = URL(string: file.url) {
                  Link(destination: url) { Label(file.title, systemImage: "doc.text") }.font(.mobileLabel)
                }
              }
            }
          }
          if let error = workspace.eventsError { Text(error).font(.mobileSecondary).foregroundStyle(MobilePalette.danger) }
        }
        .foregroundStyle(MobilePalette.ink)
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(MobilePalette.canvas)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    .presentationDetents([.medium, .large])
  }

  private func chosenStyle(_ chosen: Bool) -> AnyButtonStyleBox {
    AnyButtonStyleBox(chosen: chosen)
  }

  private func row(_ icon: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon).frame(width: 20).foregroundStyle(MobilePalette.body)
      Text(text).font(.mobileText).foregroundStyle(MobilePalette.ink)
    }
  }

  static func response(_ value: String?) -> String {
    switch value {
    case "accepted": "Going"
    case "tentative": "Maybe"
    case "declined": "Not going"
    default: "No answer yet"
    }
  }
}

/// Primary when chosen, outlined otherwise.
struct AnyButtonStyleBox: ButtonStyle {
  let chosen: Bool
  func makeBody(configuration: Configuration) -> some View {
    if chosen {
      MobilePrimaryButton(compact: true, expands: true).makeBody(configuration: configuration)
    } else {
      MobileSecondaryButton(compact: true, expands: true).makeBody(configuration: configuration)
    }
  }
}

/// Adds Calendar and Tasks to the signed-in Google account.
struct MobileConnectCard: View {
  let auth: MobileAuth
  let title: String
  let detail: String
  @State private var connecting = false
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.mobileSection)
      Text(detail).font(.mobileSecondary).foregroundStyle(MobilePalette.body).fixedSize(horizontal: false, vertical: true)
      Button {
        connecting = true
        error = nil
        Task {
          do { try await auth.signIn(hint: auth.email) } catch { self.error = error.localizedDescription }
          connecting = false
        }
      } label: { Text(connecting ? "Connecting…" : "Connect with Google") }
        .buttonStyle(MobilePrimaryButton()).disabled(connecting || !auth.isConfigured)
      if let error { Text(error).font(.mobileMetadata).foregroundStyle(MobilePalette.danger) }
      Text("On Google Workspace, an admin may need to allow Cove first.").font(.mobileMetadata).foregroundStyle(MobilePalette.muted)
    }
    .foregroundStyle(MobilePalette.ink)
    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
    .background(MobilePalette.surface, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(MobilePalette.line))
  }
}
#endif
